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
    workers: u32,
    app_source: [:0]const u8,
    statics: []const StaticRoute = &.{},
};

var g_statics: []const StaticRoute = &.{};

const Job = struct {
    body: []const u8,
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
    // The body travels as a JSON STRING argument: rs_call's machinery
    // JsonDecodes its argument, so this quoting hands servlib the raw
    // body text — and the real decode happens in Ring, inside a catch,
    // where "not JSON" is a 400 by contract.
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(alloc);
    appendJsonString(&quoted, job.body);
    const body_z = alloc.dupeZ(u8, quoted.items) catch {
        job.status = 500;
        job.response.appendSlice(alloc, "{\"code\":1,\"message\":\"out of memory\",\"data\":\"\"}") catch {};
        return;
    };
    defer alloc.free(body_z);

    const result = std.mem.span(bridge.rs_call("__dispatch_raw", body_z));
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
    if (g_workers_alive.load(.monotonic) == 0) {
        res.status = 503;
        res.content_type = .JSON;
        res.body = "{\"code\":1,\"message\":\"no workers available\",\"data\":\"\"}";
        return;
    }
    var job = Job{ .body = req.body() orelse "" };
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
        .address = .localhost(config.port),
        .request = .{ .max_body_size = 4 * 1024 * 1024 },
    }, {});
    var router = try server.router(.{});
    router.post("/api/v1", postApiV1, .{});
    router.get("/health", getHealth, .{});
    if (g_statics.len > 0) {
        // Both: "/*" does not match the bare root.
        router.get("/", serveStatic, .{});
        router.get("/*", serveStatic, .{});
    }

    std.debug.print(
        "RingServ {s} — serving on http://127.0.0.1:{d}/api/v1  ({d} workers)\n",
        .{ bridge.RINGSERV_VERSION, config.port, config.workers },
    );
    try server.listen();
}
