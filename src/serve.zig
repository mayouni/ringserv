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

fn enqueue(job: *Job) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_queue.append(alloc, job) catch {
        job.status = 503;
        job.response.appendSlice(alloc, "{\"code\":1,\"message\":\"queue full\",\"data\":\"\"}") catch {};
        job.done.set();
        return;
    };
    g_cond.signal();
}

fn dequeue() *Job {
    g_mutex.lock();
    defer g_mutex.unlock();
    while (g_queue.items.len == 0) g_cond.wait(&g_mutex);
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
    if (rc != 0) {
        // The main thread already validated the app, so this is unexpected —
        // keep serving (dispatch will answer with clean 500 envelopes), but
        // say so.
        std.debug.print("ringserv: worker {d}: app eval failed: {s}\n", .{ id, bridge.rs_last_error() });
    }
    _ = g_workers_alive.fetchAdd(1, .monotonic);
    while (true) {
        const job = dequeue();
        serveJob(job);
        job.done.set();
    }
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
