//! serve.zig — the HTTP core: httpz in front, N VM workers behind a queue.
//!
//! The architecture WORKERS.md proved and the blueprint describes: HTTP
//! threads never touch the VM. A fixed pool of worker threads each owns a
//! private resident RingState (threadlocal bridge state), evals the app
//! once at boot, and then serves `rs_call("__dispatch", body)` jobs from a
//! queue. Decoupling matters doubly on Windows, where httpz falls back to
//! thread-per-connection: connections come and go, workers are forever.

const std = @import("std");
const httpz = @import("httpz");
const bridge = @import("bridge");

const alloc = std.heap.c_allocator;

pub const StaticRoute = struct { prefix: []const u8, dir: []const u8 };

pub const Config = struct {
    port: u16,
    /// The address to bind. Loopback unless the application asked
    /// otherwise AND acknowledged what that means — see main.zig.
    host: []const u8 = "127.0.0.1",
    workers: u32,
    app_source: [:0]const u8,
    statics: []const StaticRoute = &.{},
};

var g_statics: []const StaticRoute = &.{};

/// A unit of VM work. `entry` names the Ring function a worker calls;
/// `body` is its single argument, always handed over as a JSON string so
/// the decode happens in Ring inside a catch. `__dispatch_raw` is the
/// service path; `__rs_topology_public` is the placement seam. Adding an
/// endpoint is adding a Ring function and a route, not a second pipeline.
const Job = struct {
    entry: [:0]const u8 = "__dispatch_raw",
    body: []const u8,
    /// The request's bearer token, if it carried one. Travels beside the
    /// body rather than inside it, because it is transport, not payload —
    /// and because a token inside the body would be logged by anything
    /// that logs bodies.
    auth: []const u8 = "",
    /// The body is already valid JSON for the entry point's single
    /// argument, so it must NOT be quoted again. Used where the Zig side
    /// composes the argument rather than forwarding a request body.
    raw_arg: bool = false,
    done: std.Thread.ResetEvent = .{},
    status: u16 = 500,
    response: std.ArrayList(u8) = .empty,
};

var g_queue: std.ArrayList(*Job) = .empty;
var g_mutex: std.Thread.Mutex = .{};
var g_cond: std.Thread.Condition = .{};
var g_app_source: [:0]const u8 = "";
var g_workers_alive = std.atomic.Value(u32).init(0);

// --------------------------------------------------------- HOT RELOAD
//
// A reload is a GENERATION COUNTER and nothing else, which is the whole
// reason it can be simple here: every worker owns its own resident VM,
// so no worker has to agree with any other about when to change. Bump
// the counter, and each worker re-evaluates the application before its
// NEXT job — on its own thread, between two requests, where it is
// already alone with its own state.
//
// The listener is never touched. HTTP threads do not learn that a reload
// happened; open connections stay open; the port is never rebound. That
// is the whole difference between reloading and restarting.
var g_app_generation = std.atomic.Value(u32).init(0);
var g_reload_mutex: std.Thread.Mutex = .{};
/// How many workers are serving the current generation — read by the
/// reload endpoint so a PARTIAL reload is reported as partial. N workers
/// disagreeing about which code they run is the failure this exists to
/// make visible, and a 200 would hide it perfectly.
var g_gen_workers = std.atomic.Value(u32).init(0);
var g_reload_failures = std.atomic.Value(u32).init(0);
/// The last source known to evaluate, so a worker that chokes on a new
/// one has something to go back to.
var g_prev_app_source: [:0]const u8 = "";
/// Where the application was read from. Empty when the source did not
/// come from a file (`ringserv eval`), and a reload then refuses BY NAME
/// rather than quietly reloading nothing.
var g_app_path: []const u8 = "";

pub fn setAppPath(p: []const u8) void {
    g_app_path = p;
}

/// Enqueue, and report how many jobs were ALREADY waiting.
///
/// The caller uses that number to decide whether to spin: a queue that was
/// empty means a worker is probably idle and about to pick this up in
/// microseconds; a queue with work in it means parking is the honest
/// choice, because nobody is coming soon.
fn enqueueDepth(job: *Job) usize {
    g_mutex.lock();
    defer g_mutex.unlock();
    const depth = g_queue.items.len;
    g_queue.append(alloc, job) catch {
        job.status = 503;
        job.response.appendSlice(alloc, "{\"code\":1,\"message\":\"queue full\",\"data\":\"\"}") catch {};
        job.done.set();
        return depth;
    };
    g_cond.signal();
    return depth;
}

fn enqueue(job: *Job) void {
    _ = enqueueDepth(job);
}

// A SPIN-BEFORE-PARK WAS TRIED HERE AND REMOVED, 2026-08-26, because it
// bought nothing: 0.72 ms before, 0.77 ms after, which is noise pointing
// the wrong way. The reasoning had been that parking a thread around an
// 80-microsecond job costs two context switches -- true, and not where
// the time goes. Recorded so the next person with the same good idea
// spends five minutes reading this instead of an hour measuring it.

// TWO SPIN EXPERIMENTS WERE RUN HERE AND BOTH REMOVED, 2026-08-26.
// Recorded because the reasoning is the useful part, and because the idea
// is good enough that somebody will have it again.
//
// The measurement that prompted them: a dispatch costs 0.08 ms INSIDE the
// VM and ~0.73 ms over HTTP, so Ring is not the cost -- the transport and
// the handoff are. Parking and waking a thread around an 80-microsecond
// job is two context switches, and they are on the critical path.
//
//   Spinning on the HTTP THREAD before parking on the completion event:
//   0.72 ms before, 0.77 ms after. Nothing, pointing the wrong way.
//
//   Spinning HERE, on the worker, before parking on the condition
//   variable -- the wake that is genuinely on the critical path: 0.73 ms
//   before, 0.69-0.70 ms after. Real, about 4-5%, and INSIDE the
//   run-to-run spread already seen across three runs (0.73 / 0.73 / 0.76).
//
// The 4% was dropped anyway, and not because it was small: A SPINNING
// WORKER BURNS A CORE TO SAVE A CONTEXT SWITCH, and this server is meant
// to run on a Raspberry Pi, a phone, and a laptop under a shop counter.
// On a one-core machine the spin takes the core away from the very HTTP
// thread that is waiting for it. A win measured on a 12-core desktop that
// becomes a loss on the target hardware is not a win.

// How often an idle worker wakes on its own to re-check the generation,
// with no job and no signal. This is a BOUNDED WAIT, not the spin
// rejected above -- one atomic load every 50 ms costs nothing measurable
// and is the ordinary cost of any timed condition variable, on a
// Raspberry Pi as much as a desktop. What it buys is correctness that
// does not depend on delivery: see the note on postAdminReload below.
const RELOAD_POLL_NS: u64 = 50 * std.time.ns_per_ms;

/// A job if one was queued, or null if this worker woke on its own to
/// check whether the world changed while it was asleep.
fn dequeue() ?*Job {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_queue.items.len == 0) {
        g_cond.timedWait(&g_mutex, RELOAD_POLL_NS) catch {};
    }
    if (g_queue.items.len == 0) return null;
    return g_queue.orderedRemove(0);
}

/// Minimal JSON string escaper for error messages built on the Zig side.
fn appendJsonString(out: *std.ArrayList(u8), s: []const u8) void {
    out.append(alloc, '"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(alloc, "\\\"") catch return,
            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            '\n' => out.appendSlice(alloc, "\\n") catch return,
            '\r' => out.appendSlice(alloc, "\\r") catch return,
            '\t' => out.appendSlice(alloc, "\\t") catch return,
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    out.appendSlice(alloc, hex) catch return;
                } else {
                    out.append(alloc, c) catch return;
                }
            },
        }
    }
    out.append(alloc, '"') catch return;
}

fn serveJob(job: *Job) void {
    // The token is scoped to THIS dispatch and cleared after it, so it can
    // never be read by the next request this worker serves.
    bridge.setAuthToken(job.auth);
    defer bridge.setAuthToken("");

    // The body travels as a JSON STRING argument: rs_call's machinery
    // JsonDecodes its argument, so this quoting hands servlib the raw
    // body text — and the real decode happens in Ring, inside a catch,
    // where "not JSON" is a 400 by contract.
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(alloc);
    if (job.raw_arg) {
        quoted.appendSlice(alloc, job.body) catch {};
    } else {
        appendJsonString(&quoted, job.body);
    }
    const body_z = alloc.dupeZ(u8, quoted.items) catch {
        job.status = 500;
        job.response.appendSlice(alloc, "{\"code\":1,\"message\":\"out of memory\",\"data\":\"\"}") catch {};
        return;
    };
    defer alloc.free(body_z);

    const result = std.mem.span(bridge.rs_call(job.entry, body_z));
    const err = std.mem.span(bridge.rs_last_error());
    if (err.len != 0) {
        // A servlib-level failure the Ring-side catch nets did not cover —
        // the state survived (that is the bridge's contract); report 500.
        job.status = 500;
        job.response.appendSlice(alloc, "{\"code\":1,\"message\":") catch {};
        appendJsonString(&job.response, err);
        job.response.appendSlice(alloc, ",\"data\":\"\"}") catch {};
        return;
    }
    job.status = bridge.rs_last_status();
    job.response.appendSlice(alloc, result) catch {};
}

fn workerMain(id: u32) void {
    bridge.rs_set_echo(0);
    if (bridge.rs_init() != 0) {
        std.debug.print("ringserv: worker {d}: runtime init failed: {s}\n", .{ id, bridge.rs_init_error() });
        return;
    }
    const rc = bridge.rs_eval(g_app_source);
    // The app's RingServ() ran in THIS worker, so its :data declaration
    // is materialized against this worker's own connection. Idempotent
    // by construction (CREATE TABLE IF NOT EXISTS), so N workers racing
    // to create the same tables is safe — and the first one to win also
    // creates the file.
    _ = bridge.rs_call("__rs_data_apply", "0");
    // THE RESULT OF THAT CALL WAS DISCARDED UNTIL 2026-08-28, and a
    // worker marked itself "alive" whether or not it could actually reach
    // its own database. Measured: a `:database` naming a directory that
    // does not exist printed "serving on http://..." and answered
    // /health 200, while every request that touched data failed 500 —
    // a server reporting healthy while structurally unable to do the one
    // thing it exists for. `rs_call`'s own contract already carries the
    // failure (`rs_last_error()`); nothing here was checking it.
    const data_err = std.mem.span(bridge.rs_last_error());
    if (rc != 0) {
        // The main thread already validated the app, so this is unexpected —
        // keep serving (dispatch will answer with clean 500 envelopes), but
        // say so.
        std.debug.print("ringserv: worker {d}: app eval failed: {s}\n", .{ id, bridge.rs_last_error() });
    } else if (data_err.len != 0) {
        // A worker that cannot open its own database will fail every
        // future request that touches data, for as long as the process
        // runs — the same shape of failure as `rc != 0` above, so it is
        // treated the same way: named loudly, and NOT counted as alive.
        // If every worker hits this, start() below refuses to serve at
        // all rather than bind a port that can only ever answer 500.
        std.debug.print("ringserv: worker {d}: cannot reach its database, refusing to serve: {s}\n", .{ id, data_err });
        return;
    }
    _ = g_workers_alive.fetchAdd(1, .monotonic);
    _ = g_gen_workers.fetchAdd(1, .monotonic);
    var my_generation: u32 = g_app_generation.load(.monotonic);
    while (true) {
        // dequeue() returns null when this worker woke on its own with
        // nothing queued -- itself the point, not a condition to filter
        // out. See RELOAD_POLL_NS: this is what makes reload correct
        // regardless of which worker a wake-up job happens to reach.
        const maybe_job = dequeue();

        // BETWEEN TWO JOBS is the only safe moment to change the code a
        // worker runs, and it is exactly here -- and now it is checked on
        // EVERY loop iteration, job or none, so no worker can go longer
        // than RELOAD_POLL_NS without noticing a reload even if it is
        // never handed a job again. A request already begun keeps the
        // application it began under, because this runs only between jobs.
        const gen = g_app_generation.load(.acquire);
        if (gen != my_generation) reloadThisWorker(id, gen, &my_generation);

        if (maybe_job) |job| {
            serveJob(job);
            job.done.set();
        }
    }
}

/// Re-evaluate the application in THIS worker, falling back to the code
/// it was already running if the new source will not evaluate.
///
/// A reload that half-succeeds is worse than one that refuses: some
/// requests would answer with the new behaviour and some with the old,
/// and nothing in either response would say which. So a worker that
/// cannot take the new code goes back to the old and is COUNTED.
fn reloadThisWorker(id: u32, gen: u32, my_generation: *u32) void {
    g_reload_mutex.lock();
    const src = g_app_source;
    const prev = g_prev_app_source;
    g_reload_mutex.unlock();

    _ = bridge.rs_reset();
    if (bridge.rs_eval(src) == 0) {
        _ = bridge.rs_call("__rs_data_apply", "0");
        my_generation.* = gen;
        _ = g_gen_workers.fetchAdd(1, .monotonic);
        return;
    }

    // It may have evaluated in the validation pass and still fail HERE —
    // a worker holds its own state — so this is reported, never assumed
    // impossible.
    std.debug.print("ringserv: worker {d}: reload refused, keeping the running application: {s}\n", .{ id, bridge.rs_last_error() });
    _ = g_reload_failures.fetchAdd(1, .monotonic);
    _ = bridge.rs_reset();
    if (bridge.rs_eval(prev) != 0) {
        // Both failed in this worker. Serving still beats dying: dispatch
        // answers clean 500 envelopes, and the count above already told
        // the operator not to trust this run.
        std.debug.print("ringserv: worker {d}: the PREVIOUS application no longer evaluates either: {s}\n", .{ id, bridge.rs_last_error() });
    } else {
        _ = bridge.rs_call("__rs_data_apply", "0");
    }
    // Take the generation regardless, or this worker retries the broken
    // source before every job it will ever serve.
    my_generation.* = gen;
}

// ------------------------------------------------------------- handlers

fn postApiV1(req: *httpz.Request, res: *httpz.Response) !void {
    return runInVm(res, "__dispatch_raw", req.body() orelse "", bearerOf(req));
}

/// The bearer token of a request, or "". Only the `Bearer` scheme is
/// read: Basic would mean holding a password in memory, and this server
/// has no business doing that when a token is what it verifies.
fn bearerOf(req: *httpz.Request) []const u8 {
    const h = req.header("authorization") orelse return "";
    if (h.len < 7) return "";
    if (!std.ascii.eqlIgnoreCase(h[0..7], "bearer ")) return "";
    return std.mem.trim(u8, h[7..], " ");
}

/// The placement seam a page reads to compile `serv.call`. A GET, because
/// it is a fact about the deployment rather than a request to do
/// something — cacheable, proxyable, and answerable before the page has
/// made a single call.
fn getTopology(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    return runInVm(res, "__rs_topology_public", "0", "");
}

/// GET /sync/shape?shape=notes&offset=N&limit=M&live=true
///
/// Paged reads from the shape log. `live=true` long-polls: the request
/// parks HERE, on an HTTP thread, asking the VM only for the shape's head
/// offset — because parking a VM worker for 20 seconds would take a
/// twelfth of the server's capacity out of service per waiting client.
fn getSyncShape(req: *httpz.Request, res: *httpz.Response) !void {
    const q = try req.query();
    const shape = q.get("shape") orelse "";
    const offset = q.get("offset") orelse "0";
    const limit = q.get("limit") orelse "500";
    const live = std.mem.eql(u8, q.get("live") orelse "", "true");

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"shape\":");
    appendJsonString(&body, shape);
    try body.appendSlice(alloc, ",\"offset\":");
    appendJsonString(&body, offset);
    try body.appendSlice(alloc, ",\"limit\":");
    appendJsonString(&body, limit);
    try body.append(alloc, '}');

    if (live) {
        // Wait for the head to move past the client's offset. A poll
        // rather than a condition variable, deliberately: writes arrive
        // through SQLite triggers on any connection, including a future
        // second process, so there is no in-process event to wait on that
        // would still be true tomorrow.
        const from = std.fmt.parseInt(i64, offset, 10) catch 0;
        var waited: u32 = 0;
        while (waited < 20_000) : (waited += 200) {
            if (try headOf(shape) > from) break;
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    }
    return runInVm(res, "__rs_sync_shape", body.items, "");
}

/// The browser half of the unified model, served from the binary so a
/// page needs no build step and no package: one <script> tag brings
/// serv.call() and serv.subscribe(). Embedded rather than read from
/// disk, because an application that moved its public/ directory should
/// not lose the client library with it.
const CLIENT_JS = @embedFile("client.js");

fn getClientJs(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .JS;
    // REVALIDATE, do not cache. The file changes only when the binary
    // does — but that is exactly the moment a stale copy hurts: a browser
    // holding an hour-old client after an upgrade runs code the server no
    // longer ships, and the symptom appears in the page rather than here.
    // Observed while testing this very change. It is 7 KB; correctness
    // after an upgrade is worth more than the request.
    res.header("Cache-Control", "no-cache");
    res.body = CLIENT_JS;
}

/// POST /admin/reload — re-read the application and change it under the
/// running server, without dropping the port or a single connection.
///
/// LOOPBACK ONLY, and not negotiable. This is the one route in the binary
/// where "who may ask" cannot be the application's decision, because the
/// application is the thing being replaced. A remote reload is a
/// different product with a different threat model, refused by name in
/// docs/PLAN.md phase 20.
fn postAdminReload(req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;

    if (!isLoopback(req)) {
        res.status = 403;
        res.body =
            \\{"code":1,"message":"reload is loopback-only - run it on the machine the server runs on","data":""}
        ;
        return;
    }
    if (g_app_path.len == 0) {
        res.status = 409;
        res.body =
            \\{"code":1,"message":"this server was not started from a file, so there is nothing to re-read","data":""}
        ;
        return;
    }

    const raw = std.fs.cwd().readFileAlloc(alloc, g_app_path, 64 * 1024 * 1024) catch |e| {
        res.status = 404;
        var m: std.ArrayList(u8) = .empty;
        defer m.deinit(alloc);
        try m.writer(alloc).writeAll("{\"code\":1,\"message\":");
        var detail: std.ArrayList(u8) = .empty;
        defer detail.deinit(alloc);
        try detail.writer(alloc).print("cannot re-read {s}: {s}", .{ g_app_path, @errorName(e) });
        appendJsonString(&m, detail.items);
        try m.writer(alloc).writeAll(",\"data\":\"\"}");
        res.body = try res.arena.dupe(u8, m.items);
        return;
    };
    defer alloc.free(raw);

    // Native ring normalises CRLF as it reads, and so does `run` at boot.
    // A reload that handed the VM different bytes than a restart would
    // be a reload that behaves differently from a restart.
    var norm: std.ArrayList(u8) = .empty;
    errdefer norm.deinit(alloc);
    for (raw) |c| {
        if (c != '\r') try norm.append(alloc, c);
    }
    const src = try norm.toOwnedSliceSentinel(alloc, 0);

    const workers = g_workers_alive.load(.monotonic);

    g_reload_mutex.lock();
    g_prev_app_source = g_app_source;
    g_app_source = src;
    g_reload_mutex.unlock();

    g_gen_workers.store(0, .monotonic);
    g_reload_failures.store(0, .monotonic);
    _ = g_app_generation.fetchAdd(1, .release);

    // WHY THIS IS NOT "ENQUEUE ONE NO-OP JOB PER WORKER" ANY MORE
    // (found on macOS CI, 2026-08-27, two days after this shipped: the
    // gates reported "2 of 3 workers took the new application" every
    // single run, never all three).
    //
    // Jobs sit in ONE shared queue that any idle worker may take, and
    // nothing pairs a job with a particular worker. Enqueueing N jobs
    // sequentially -- wait for one, THEN enqueue the next -- lets a fast
    // worker answer twice before a slower one wakes at all: worker A
    // takes job 1, finishes, is idle again before job 2 is even
    // enqueued, and takes that one too. A worker that never receives a
    // job never reloads, and no amount of waiting fixes that, because
    // there is nothing left in the queue to wait FOR. On Windows the
    // three worker threads happened to interleave often enough that
    // each got one; that was luck, not a guarantee, and macOS's
    // scheduler simply did not oblige.
    //
    // The actual fix is not here -- it is that every worker now polls
    // its own generation on a bounded wait regardless of whether a job
    // ever reaches it (RELOAD_POLL_NS, in dequeue()/workerMain()). This
    // broadcast is only the FAST PATH: it wakes any worker that is
    // currently asleep so reload does not wait out a full poll interval
    // in the common case. Correctness does not depend on it succeeding.
    g_mutex.lock();
    g_cond.broadcast();
    g_mutex.unlock();

    // Bounded, not indefinite: every worker is guaranteed to notice
    // within RELOAD_POLL_NS of finishing whatever it is doing, so a
    // wait many times that long is generous rather than hopeful. A
    // worker that is mid-way through a genuinely slow request is not a
    // failure to wait for -- it will reload the moment that request
    // ends, which is the one guarantee this endpoint makes.
    var waited_ns: u64 = 0;
    const budget_ns: u64 = 2 * std.time.ns_per_s;
    while (waited_ns < budget_ns) {
        if (g_gen_workers.load(.monotonic) + g_reload_failures.load(.monotonic) >= workers) break;
        std.Thread.sleep(2 * std.time.ns_per_ms);
        waited_ns += 2 * std.time.ns_per_ms;
    }

    const took = g_gen_workers.load(.monotonic);
    const failed = g_reload_failures.load(.monotonic);

    var m: std.ArrayList(u8) = .empty;
    defer m.deinit(alloc);
    if (failed == 0 and took >= workers) {
        res.status = 200;
        try m.writer(alloc).print("{{\"code\":0,\"message\":\"OK\",\"data\":{{\"reloaded\":{d},\"workers\":{d},\"failed\":0,\"generation\":{d}}}}}", .{ took, workers, g_app_generation.load(.monotonic) });
    } else if (took == 0) {
        // NOTHING CHANGED, and that is the SAFE failure — every worker is
        // still serving the application that was already working. It must
        // not read like the dangerous one below: an operator who cannot
        // tell "nothing happened" from "half of it happened" will treat
        // them the same, and only one of them is an emergency.
        res.status = 422;
        try m.writer(alloc).print("{{\"code\":1,\"message\":\"RELOAD REFUSED - the new application would not evaluate, so all {d} workers kept the one they were running. Nothing changed and the server is unaffected; fix the application and reload again.\",\"data\":{{\"reloaded\":0,\"workers\":{d},\"failed\":{d}}}}}", .{ workers, workers, failed });
    } else {
        // PARTIAL IS THE DANGEROUS ONE, and it is why the count exists:
        // some requests now answer with the new code and some with the
        // old, and nothing in either response says which.
        res.status = 500;
        try m.writer(alloc).print("{{\"code\":1,\"message\":\"PARTIAL RELOAD - {d} of {d} workers took the new application and {d} kept the old one. THIS SERVER IS NOW ANSWERING WITH TWO VERSIONS. Fix the application and reload again, or restart to be certain.\",\"data\":{{\"reloaded\":{d},\"workers\":{d},\"failed\":{d}}}}}", .{ took, workers, failed, took, workers, failed });
    }
    res.body = try res.arena.dupe(u8, m.items);
}

/// Is this request from this machine? Judged on the ADDRESS, never on a
/// header — `X-Forwarded-For` is whatever the last hop chose to write.
fn isLoopback(req: *httpz.Request) bool {
    return switch (req.address.any.family) {
        std.posix.AF.INET => req.address.in.sa.addr == 0x0100007f,
        std.posix.AF.INET6 => blk: {
            const a = req.address.in6.sa.addr;
            if (std.mem.eql(u8, &a, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })) break :blk true;
            // ::ffff:127.x.x.x — an IPv4 loopback arriving on a dual stack
            if (std.mem.eql(u8, a[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) and a[12] == 127) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// How many streams this server will hold open at once.
///
/// A held-open connection is a real resource and a browser tab is free to
/// open one, so the cap is part of the feature rather than a follow-up.
/// The refusal NAMES the cap: a client told "busy" learns nothing, and a
/// client told the number can decide whether to wait or to poll.
const STREAM_CAP: u32 = 64;
/// A stream lives ten minutes, then closes cleanly and the browser
/// reconnects by itself with Last-Event-ID. Bounded on purpose: a
/// forgotten tab must not hold a thread for a week, and a client that
/// resumes from its own offset loses nothing by being recycled.
const STREAM_MAX_MS: u32 = 600_000;
var g_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// GET /sync/stream?shape=<name>&offset=<n> - Server-Sent Events.
///
/// WHAT CROSSES THE WIRE IS AN OFFSET, NEVER A PAYLOAD. The event says
/// "shape `menu` advanced to 47" and the client fetches through the same
/// /sync/shape path it already uses. Two things are bought by that
/// constraint and both are load-bearing:
///
///   ONE CODE PATH FOR DATA - paging, must-refetch and the placement rules
///   keep working, because the data still travels the way it did.
///
///   A DROPPED NOTIFICATION COSTS LATENCY, NEVER CORRECTNESS - the
///   client's existing poll still converges, so a browser that missed an
///   event, a proxy that buffered one, and a server that never sent one
///   all end at the same state. That is what makes this safe to ship
///   rather than a second source of truth.
///
/// SSE and not WebSocket, for the reasons in docs/PLAN.md phase 18: the
/// flow is one-way, plain HTTP survives the reverse proxy this server
/// MANDATES for TLS, and Last-Event-ID maps onto the shape-log offset
/// exactly - so a reconnecting browser resumes by itself.
///
/// Like the long poll above, this parks on an HTTP THREAD and asks the VM
/// only for a cheap indexed max(). It never holds a VM worker.
fn getSyncStream(req: *httpz.Request, res: *httpz.Response) !void {
    const q = try req.query();
    const shape = q.get("shape") orelse "";
    if (shape.len == 0) {
        res.status = 400;
        res.content_type = .JSON;
        res.body =
            \\{"code":1,"message":"name the shape: /sync/stream?shape=<name>","data":""}
        ;
        return;
    }

    // The browser's own resume token wins over the query string: on a
    // reconnect the browser replays Last-Event-ID by itself, and that is a
    // more recent fact than whatever offset the page first opened with.
    var from: i64 = std.fmt.parseInt(i64, q.get("offset") orelse "0", 10) catch 0;
    if (req.header("last-event-id")) |lei| {
        from = std.fmt.parseInt(i64, lei, 10) catch from;
    }

    // ASK BEFORE HOLDING A CONNECTION OPEN (phase 19). Until 2026-08-25
    // this handler asked nobody: an unknown shape got a 200, an `open`
    // frame and offset -1, so a page with a typo was told it was
    // connected and then waited forever -- while the poll path had been
    // refusing the same name 404 since phase 8. The refusal now comes
    // from the same function the poll path uses, and the placement
    // refusal is the same sentence a CALL gets, because a caller told
    // `no` in two different sentences learns that the rule is two rules.
    if (streamRefusal(res.arena, shape)) |ref| {
        res.status = ref.status;
        res.content_type = .JSON;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(alloc);
        try msg.writer(alloc).writeAll("{\"code\":1,\"message\":");
        appendJsonString(&msg, ref.message);
        try msg.writer(alloc).writeAll(",\"data\":\"\"}");
        res.body = try res.arena.dupe(u8, msg.items);
        return;
    }

    if (g_streams.fetchAdd(1, .monotonic) >= STREAM_CAP) {
        _ = g_streams.fetchSub(1, .monotonic);
        res.status = 503;
        res.content_type = .JSON;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(alloc);
        try msg.writer(alloc).print(
            "{{\"code\":1,\"message\":\"this server holds at most {d} live streams and all are in use - poll /sync/shape instead, which always works\",\"data\":\"\"}}",
            .{STREAM_CAP});
        res.body = try res.arena.dupe(u8, msg.items);
        return;
    }
    defer _ = g_streams.fetchSub(1, .monotonic);

    // SSE's own headers. `X-Accel-Buffering: no` is the one people forget:
    // nginx buffers a proxied response by default, so events arrive in
    // clumps or not at all until the buffer fills -- and this server
    // MANDATES a proxy for TLS, which makes the header a requirement here
    // rather than a nicety. `no-transform` asks intermediaries not to
    // compress, since a compressor with its own buffer reintroduces the
    // same delay a different way.
    res.content_type = .EVENTS;
    res.header("Cache-Control", "no-cache, no-transform");
    res.header("X-Accel-Buffering", "no");
    res.header("Connection", "keep-alive");

    // THE STREAM RUNS ON THIS THREAD, by res.chunk(), and does NOT use
    // httpz's disown/startEventStream path. Both of those were tried
    // first and both answered error.Unexpected on Windows: they hand the
    // socket to a spawned thread, and the worker loop that owns it does
    // not survive being disowned on every platform. Holding the HTTP
    // thread is also the shape this server already chose for the long
    // poll above -- an HTTP thread is cheap, a VM WORKER is what must
    // never be parked, and neither of these parks one.
    //
    // Chunked transfer is ordinary for SSE; EventSource reads it happily.
    var buf: [256]u8 = undefined;

    // An opening event, so a page knows it is connected rather than
    // inferring it from silence - and it carries the head, so a client
    // that subscribed while behind catches up at once.
    {
        const head = headOf(shape) catch 0;
        const msg = std.fmt.bufPrint(&buf,
            "retry: 2000\nevent: open\nid: {d}\ndata: {{\"shape\":\"{s}\",\"offset\":{d}}}\n\n",
            .{ head, shape, head }) catch return;
        res.chunk(msg) catch return;
        if (head > from) from = head;
    }

    // The loop. A heartbeat every 15 s doubles as dead-peer detection:
    // the write fails on a closed socket, which is the only reliable
    // signal a server gets that a browser tab is gone. It also keeps
    // proxies from closing an idle connection they think is dead.
    var since_beat: u32 = 0;
    var lived: u32 = 0;
    while (lived < STREAM_MAX_MS) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        since_beat += 200;
        lived += 200;

        const head = headOf(shape) catch 0;
        if (head > from) {
            from = head;
            since_beat = 0;
            const msg = std.fmt.bufPrint(&buf,
                "event: advanced\nid: {d}\ndata: {{\"shape\":\"{s}\",\"offset\":{d}}}\n\n",
                .{ head, shape, head }) catch return;
            res.chunk(msg) catch return;
        } else if (since_beat >= 15_000) {
            since_beat = 0;
            // A comment line: valid SSE, ignored by every client, and it
            // fails to write exactly when the peer is gone.
            res.chunk(": beat\n\n") catch return;
        }
    }
    // A bounded life, then a clean close. The browser reconnects by
    // itself with Last-Event-ID -- which is the whole reason SSE was
    // chosen -- so a recycled connection costs nothing and stops a
    // forgotten tab from holding a thread for a week.
    res.chunk("event: bye\ndata: {}\n\n") catch {};
}
/// What the server owes a subscriber before it opens a stream, or null
/// to proceed. The VM answers `status|message`; "0|" means yes.
///
/// A refusal is worth a VM round trip and an acceptance is too: the
/// alternative is caching a topology that a `ringserv reload` can change
/// under us, and a stale yes is exactly the failure this endpoint was
/// just fixed for.
const StreamRefusal = struct { status: u16, message: []const u8 };

fn streamRefusal(arena: std.mem.Allocator, shape: []const u8) ?StreamRefusal {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    appendJsonString(&body, shape);

    // No workers means no topology to consult. Proceeding is right: the
    // stream will then answer offset 0 and the page falls back, which is
    // strictly better than refusing a shape that may well exist.
    if (g_workers_alive.load(.monotonic) == 0) return null;
    var job = Job{ .entry = "__rs_stream_check", .body = body.items, .raw_arg = true };
    defer job.response.deinit(alloc);
    enqueue(&job);
    job.done.timedWait(10 * std.time.ns_per_s) catch return null;

    // The VM hands back a JSON-encoded value, so a STRING return arrives
    // QUOTED AND ESCAPED — unlike __rs_sync_head below, which returns a
    // number and therefore arrives bare. Measured, after this function
    // silently returned null for every shape and let the handler fall
    // straight through to the streaming path it exists to guard. A guard
    // that fails open is worse than no guard, because it tests green
    // everywhere the thing it guards already works.
    var out = std.mem.trim(u8, job.response.items, " \t\r\n");
    var unescaped: std.ArrayList(u8) = .empty;
    defer unescaped.deinit(alloc);
    if (out.len >= 2 and out[0] == '"' and out[out.len - 1] == '"') {
        var i: usize = 1;
        while (i < out.len - 1) : (i += 1) {
            if (out[i] == '\\' and i + 1 < out.len - 1) {
                i += 1;
                unescaped.append(alloc, switch (out[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => out[i],
                }) catch return null;
            } else {
                unescaped.append(alloc, out[i]) catch return null;
            }
        }
        out = unescaped.items;
    }

    const bar = std.mem.indexOfScalar(u8, out, '|') orelse return null;
    const status = std.fmt.parseInt(u16, out[0..bar], 10) catch return null;
    if (status == 0) return null;
    // The message is duped into THIS REQUEST'S arena, never a shared
    // buffer: several HTTP threads can be refused at the same moment, and
    // a static buffer would hand one of them the other's sentence.
    const text = arena.dupe(u8, out[bar + 1 ..]) catch return null;
    return .{ .status = status, .message = text };
}

/// The shape's highest offset, asked of a worker. Cheap — one indexed
/// max() — which is what makes polling for it affordable.
fn headOf(shape: []const u8) !i64 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    appendJsonString(&body, shape);

    if (g_workers_alive.load(.monotonic) == 0) return 0;
    var job = Job{ .entry = "__rs_sync_head", .body = body.items, .raw_arg = true };
    defer job.response.deinit(alloc);
    enqueue(&job);
    job.done.timedWait(10 * std.time.ns_per_s) catch return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, job.response.items, " \t\r\n"), 10) catch 0;
}

fn postSyncPush(req: *httpz.Request, res: *httpz.Response) !void {
    return runInVm(res, "__rs_sync_push", req.body() orelse "", bearerOf(req));
}

fn postSyncState(req: *httpz.Request, res: *httpz.Response) !void {
    return runInVm(res, "__rs_sync_state", req.body() orelse "", bearerOf(req));
}

/// One VM round trip, on the worker pool, with the same timeouts and the
/// same liveness check for every endpoint that needs Ring.
fn runInVm(
    res: *httpz.Response,
    entry: [:0]const u8,
    body: []const u8,
    auth: []const u8,
) !void {
    if (g_workers_alive.load(.monotonic) == 0) {
        res.status = 503;
        res.content_type = .JSON;
        res.body = "{\"code\":1,\"message\":\"no workers available\",\"data\":\"\"}";
        return;
    }
    // JSON is UTF-8 by definition (RFC 8259 §8.1), so a body that is not
    // valid UTF-8 is refused AT THE DOOR — found the expensive way: a
    // Latin-1 byte (a Windows curl sending "crème" unconverted) sailed
    // through into the JOURNAL, where nothing may ever be deleted, and
    // permanently broke every strict JSON consumer of that record. The
    // journal kept its promise; the door had not kept its. Validating
    // here protects every store at once, for one scan per request.
    if (!std.unicode.utf8ValidateSlice(body)) {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"code\":1,\"message\":\"malformed request: the body is not " ++
            "valid UTF-8 — JSON is UTF-8 by definition (RFC 8259), and a byte " ++
            "accepted here would poison durable records\",\"data\":\"\"}";
        return;
    }
    var job = Job{ .entry = entry, .body = body, .auth = auth };
    defer job.response.deinit(alloc);
    enqueue(&job);
    job.done.timedWait(120 * std.time.ns_per_s) catch {
        // The job may still be queued or running; it must not write into a
        // dead frame. Leak-by-design is unacceptable, so: mark it served by
        // waiting forever is worse — phase 2 keeps this simple and honest:
        // a worker stuck 120s is a server bug; say so loudly and exit.
        std.debug.print("ringserv: dispatch exceeded 120s — a worker is stuck; exiting\n", .{});
        std.process.exit(1);
    };
    res.status = job.status;
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, job.response.items);
}

fn getHealth(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.status = 200;
    res.content_type = .JSON;
    res.body = "{\"code\":0,\"message\":\"OK\",\"data\":{\"up\":true}}";
}

fn mimeFor(p: []const u8) httpz.ContentType {
    const dot = std.mem.lastIndexOfScalar(u8, p, '.') orelse return .BINARY;
    const ext = p[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(ext, "html") or std.ascii.eqlIgnoreCase(ext, "htm")) return .HTML;
    if (std.ascii.eqlIgnoreCase(ext, "css")) return .CSS;
    if (std.ascii.eqlIgnoreCase(ext, "js") or std.ascii.eqlIgnoreCase(ext, "mjs")) return .JS;
    if (std.ascii.eqlIgnoreCase(ext, "json")) return .JSON;
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return .SVG;
    if (std.ascii.eqlIgnoreCase(ext, "png")) return .PNG;
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return .JPG;
    if (std.ascii.eqlIgnoreCase(ext, "gif")) return .GIF;
    if (std.ascii.eqlIgnoreCase(ext, "ico")) return .ICO;
    if (std.ascii.eqlIgnoreCase(ext, "wasm")) return .WASM;
    if (std.ascii.eqlIgnoreCase(ext, "txt") or std.ascii.eqlIgnoreCase(ext, "ring")) return .TEXT;
    return .BINARY;
}

/// Static files declared as [ :static, prefix, dir ]. Files are files:
/// the VM has no business in this path, so Zig serves them directly.
fn serveStatic(req: *httpz.Request, res: *httpz.Response) !void {
    const url = req.url.path;
    for (g_statics) |route| {
        if (!std.mem.startsWith(u8, url, route.prefix)) continue;
        var rel = url[route.prefix.len..];
        while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
        if (rel.len == 0) rel = "index.html";

        // Refuse traversal outright rather than trying to normalize it:
        // any "..", any absolute path, any backslash, and the request is
        // simply not served. Cheap, total, and impossible to get subtly
        // wrong.
        if (std.mem.indexOf(u8, rel, "..") != null or
            std.mem.indexOfScalar(u8, rel, '\\') != null or
            std.mem.indexOfScalar(u8, rel, ':') != null or
            rel[0] == '/')
        {
            res.status = 403;
            res.body = "forbidden";
            return;
        }

        const full = try std.fs.path.join(res.arena, &.{ route.dir, rel });
        const file = std.fs.cwd().openFile(full, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        if (stat.kind == .directory) continue;
        if (stat.size > 64 * 1024 * 1024) {
            res.status = 413;
            res.body = "file too large";
            return;
        }
        const bytes = file.readToEndAlloc(res.arena, 64 * 1024 * 1024) catch continue;
        res.status = 200;
        res.content_type = mimeFor(rel);
        res.body = bytes;
        return;
    }
    res.status = 404;
    res.content_type = .TEXT;
    res.body = "not found";
}

// --------------------------------------------------------------- entry

pub fn start(config: Config) !void {
    g_app_source = config.app_source;
    g_statics = config.statics;

    var i: u32 = 0;
    while (i < config.workers) : (i += 1) {
        const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, workerMain, .{i});
        t.detach();
    }
    // Give workers a moment to boot their VMs before accepting traffic.
    var waited: u32 = 0;
    while (g_workers_alive.load(.monotonic) == 0 and waited < 100) : (waited += 1) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    // REFUSE TO SERVE ON ZERO WORKERS, rather than binding the port
    // anyway once the wait above times out.
    //
    // Until 2026-08-28 this loop had no exit condition of its own: it
    // simply stopped waiting after two seconds, success or not, and fell
    // straight through to print "serving on http://..." and bind the
    // port regardless. A deployment whose database directory does not
    // exist -- every worker refusing in the fix just above this one --
    // used to look exactly like a healthy server: 200 on /health, and a
    // 500 on the very first real request, forever, with nothing in
    // between to say why. Found by deploying a config that could never
    // have worked, not by a report from someone it happened to.
    if (g_workers_alive.load(.monotonic) == 0) {
        std.debug.print(
            "ringserv: no worker came up after {d} ms -- refusing to serve. " ++
                "Each worker's own line above names why (an unreachable database " ++
                "is the common case); this is not a hang to wait out.\n",
            .{waited * 20},
        );
        return error.NoWorkerAvailable;
    }

    var server = try httpz.Server(void).init(alloc, .{
        .address = if (std.mem.eql(u8, config.host, "127.0.0.1"))
            .localhost(config.port)
        else
            .{ .ip = .{ .host = config.host, .port = config.port } },
        .request = .{ .max_body_size = 4 * 1024 * 1024 },
    }, {});
    var router = try server.router(.{});
    router.post("/api/v1", postApiV1, .{});
    router.get("/health", getHealth, .{});
    router.get("/topology", getTopology, .{});
    router.get("/sync/shape", getSyncShape, .{});
    router.get("/sync/stream", getSyncStream, .{});
    router.get("/ringserv.js", getClientJs, .{});
    router.post("/admin/reload", postAdminReload, .{});
    router.post("/sync/push", postSyncPush, .{});
    router.post("/sync/state", postSyncState, .{});
    if (g_statics.len > 0) {
        // Both: "/*" does not match the bare root.
        router.get("/", serveStatic, .{});
        router.get("/*", serveStatic, .{});
    }

    std.debug.print(
        "RingServ {s} — serving on http://{s}:{d}/api/v1  ({d} workers)\n",
        .{ bridge.RINGSERV_VERSION, config.host, config.port, config.workers },
    );
    try server.listen();
}
