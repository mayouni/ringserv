//! ringserv panel — the admin panel: one place to see and drive apps.
//!
//! `ringserv panel [dir]` scans a directory for applications — a
//! subdirectory holding `app.ring` runs with `run`; a bare `<name>.ring`
//! file serves with `serve` (the phase-10 gesture) — and puts them behind
//! one clean page: status, start, stop, logs, and a call box that speaks
//! to each app's /api/v1 through the panel (same origin, no CORS dance).
//!
//! Decisions worth stating:
//!  - LOOPBACK ONLY, not configurable. A panel that can start and stop
//!    processes is an operations surface; docs/TLS.md's doctrine applies
//!    twice over. Reaching it remotely is a reverse proxy's business.
//!  - The panel NEVER guesses an app is healthy — it reports what it can
//!    see: the process is alive (its pipes are open) and, when the port
//!    is known, whether /health answers. A port it cannot determine is
//!    shown as unknown, not invented.
//!  - Logs are a bounded tail per app (64 KB). The panel is a window,
//!    not an archive — the archive is the operator's job (docs/PLAN.md,
//!    phase 15).

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const bridge = @import("bridge");

/// Not in std's kernel32 bindings; the one Win32 call the panel needs.
extern "kernel32" fn GetProcessId(h: std.os.windows.HANDLE) callconv(.winapi) u32;

const MAX_APPS = 64;
const LOG_CAP = 64 * 1024;

const Mode = enum { run, serve };
const Status = enum { stopped, running };

const App = struct {
    name: []const u8,
    /// The file handed to `ringserv run` / `ringserv serve`.
    path: []const u8,
    mode: Mode,
    /// From ringserv.yaml or a `:port =` scan; 0 = unknown, and shown so.
    port: u16,
    status: Status = .stopped,
    child: ?std.process.Child = null,
    pid: i64 = 0,
    started_at: i64 = 0,
    log: [LOG_CAP]u8 = undefined,
    log_len: usize = 0,
    /// Readers still attached to a (possibly dead) child's pipes.
    readers: u32 = 0,
};

var g_alloc: std.mem.Allocator = undefined;
var g_exe: []const u8 = "";
var g_apps: [MAX_APPS]App = undefined;
var g_napps: usize = 0;
var g_mu: std.Thread.Mutex = .{};
var g_started_at: i64 = 0;
var g_shutdown = std.atomic.Value(bool).init(false);

// ------------------------------------------------------------- scanning

fn guessPortFromYaml(arena: std.mem.Allocator, dir_path: []const u8) u16 {
    const yaml_path = std.fs.path.join(arena, &.{ dir_path, "ringserv.yaml" }) catch return 0;
    const f = std.fs.cwd().openFile(yaml_path, .{}) catch return 0;
    defer f.close();
    const text = f.readToEndAlloc(arena, 64 * 1024) catch return 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "port:")) {
            const v = std.mem.trim(u8, t["port:".len..], " \t");
            return std.fmt.parseInt(u16, v, 10) catch 0;
        }
    }
    return 0;
}

fn guessPortFromRing(arena: std.mem.Allocator, file_path: []const u8) u16 {
    const f = std.fs.cwd().openFile(file_path, .{}) catch return 0;
    defer f.close();
    const text = f.readToEndAlloc(arena, 4 * 1024 * 1024) catch return 0;
    // `:port = 8086` — a textual scan, and honestly a guess: the truth is
    // whatever the declaration computes. Unknown beats invented, so any
    // doubt returns 0.
    if (std.mem.indexOf(u8, text, ":port")) |at| {
        var i = at + ":port".len;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '=')) i += 1;
        var end = i;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end > i) return std.fmt.parseInt(u16, text[i..end], 10) catch 0;
    }
    return 0;
}

/// One directory, two shapes: `<sub>/app.ring` is an application (run);
/// `<name>.ring` at the top is a gesture file (serve).
fn scan(arena: std.mem.Allocator, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
        std.debug.print("ringserv panel: cannot open {s}: {s}\n", .{ root, @errorName(e) });
        return e;
    };
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (g_napps >= MAX_APPS) break;
        if (entry.kind == .directory) {
            const app_path = try std.fs.path.join(arena, &.{ root, entry.name, "app.ring" });
            std.fs.cwd().access(app_path, .{}) catch continue;
            var port = guessPortFromYaml(arena, try std.fs.path.join(arena, &.{ root, entry.name }));
            if (port == 0) port = guessPortFromRing(arena, app_path);
            g_apps[g_napps] = .{
                .name = try arena.dupe(u8, entry.name),
                .path = app_path,
                .mode = .run,
                .port = port,
            };
            g_napps += 1;
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".ring")) {
            const stem = entry.name[0 .. entry.name.len - ".ring".len];
            const file_path = try std.fs.path.join(arena, &.{ root, entry.name });
            var port = guessPortFromYaml(arena, root);
            if (port == 0) port = guessPortFromRing(arena, file_path);
            g_apps[g_napps] = .{
                .name = try arena.dupe(u8, stem),
                .path = file_path,
                .mode = .serve,
                .port = port,
            };
            g_napps += 1;
        }
    }
}

// ------------------------------------------------- children and their logs

fn appendLog(app: *App, bytes: []const u8) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (bytes.len >= LOG_CAP) {
        @memcpy(app.log[0..LOG_CAP], bytes[bytes.len - LOG_CAP ..]);
        app.log_len = LOG_CAP;
        return;
    }
    if (app.log_len + bytes.len > LOG_CAP) {
        const keep = LOG_CAP - bytes.len;
        std.mem.copyForwards(u8, app.log[0..keep], app.log[app.log_len - keep .. app.log_len]);
        app.log_len = keep;
    }
    @memcpy(app.log[app.log_len .. app.log_len + bytes.len], bytes);
    app.log_len += bytes.len;
}

/// Drains one pipe into the app's log; the LAST reader to finish reaps
/// the child and marks the app stopped — EOF on both pipes is the one
/// portable, poll-free signal that a process is gone.
fn readerMain(app: *App, file: std.fs.File) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch 0;
        if (n == 0) break;
        appendLog(app, buf[0..n]);
    }
    g_mu.lock();
    app.readers -= 1;
    const last = app.readers == 0;
    g_mu.unlock();
    if (last) {
        if (app.child) |*c| _ = c.wait() catch {};
        g_mu.lock();
        app.child = null;
        app.status = .stopped;
        app.pid = 0;
        g_mu.unlock();
        appendLog(app, "\n[panel] process ended\n");
    }
}

fn startApp(app: *App) ![]const u8 {
    g_mu.lock();
    if (app.status == .running) {
        g_mu.unlock();
        return "already running";
    }
    g_mu.unlock();

    const verb: []const u8 = if (app.mode == .run) "run" else "serve";
    var child = std.process.Child.init(&.{ g_exe, verb, app.path }, g_alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |e| {
        appendLog(app, "[panel] start failed\n");
        return @errorName(e);
    };

    g_mu.lock();
    app.child = child;
    app.status = .running;
    app.pid = if (builtin.os.tag == .windows)
        @intCast(GetProcessId(child.id))
    else
        @intCast(child.id);
    app.started_at = std.time.timestamp();
    app.log_len = 0;
    app.readers = 2;
    g_mu.unlock();

    const t1 = try std.Thread.spawn(.{}, readerMain, .{ app, child.stdout.? });
    t1.detach();
    const t2 = try std.Thread.spawn(.{}, readerMain, .{ app, child.stderr.? });
    t2.detach();
    return "";
}

fn stopApp(app: *App) []const u8 {
    g_mu.lock();
    if (app.status != .running or app.child == null) {
        g_mu.unlock();
        return "not running";
    }
    var child = app.child.?;
    g_mu.unlock();
    // Kill, and let the pipe readers observe EOF and reap — one reaping
    // path, not two racing ones.
    _ = child.kill() catch {};
    return "";
}

fn findApp(name: []const u8) ?*App {
    for (g_apps[0..g_napps]) |*a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}

// -------------------------------------------------------- the call proxy

/// One plain HTTP/1.1 POST to a hosted app, hand-rolled over a TCP
/// socket with Connection: close — small, dependency-free, and immune to
/// std.http API drift. The panel page calls apps THROUGH this, so the
/// whole demo is same-origin.
fn proxyCall(arena: std.mem.Allocator, port: u16, body: []const u8) ![]const u8 {
    const stream = try std.net.tcpConnectToHost(arena, "127.0.0.1", port);
    defer stream.close();
    // The Reader/Writer interfaces, not Stream.read/write: on Windows the
    // deprecated direct read path drives ReadFile on a WSA socket and
    // returns nothing -- measured here, not theorized.
    var wbuf: [1024]u8 = undefined;
    var sw = stream.writer(&wbuf);
    const req = try std.fmt.allocPrint(arena,
        "POST /api/v1 HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n{s}", .{ port, body.len, body });
    try sw.interface.writeAll(req);
    try sw.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(&rbuf);
    const r = sr.interface();
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const chunk = r.peekGreedy(1) catch break;
        if (chunk.len == 0) break;
        try out.appendSlice(arena, chunk);
        r.toss(chunk.len);
        if (out.items.len > 4 * 1024 * 1024) break;
    }
    const full = out.items;
    const split = std.mem.indexOf(u8, full, "\r\n\r\n") orelse return full;
    var payload = full[split + 4 ..];
    if (std.mem.indexOf(u8, full[0..split], "chunked") != null) {
        if (std.mem.indexOf(u8, payload, "\r\n")) |cl| {
            const rest = payload[cl + 2 ..];
            if (std.mem.lastIndexOf(u8, rest, "\r\n0\r\n")) |endz| {
                payload = rest[0..endz];
            } else payload = rest;
        }
    }
    return payload;
}

// ------------------------------------------------------------ the routes

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.appendSlice(g_alloc, "\\\""),
            '\\' => try w.appendSlice(g_alloc, "\\\\"),
            '\n' => try w.appendSlice(g_alloc, "\\n"),
            '\r' => {},
            '\t' => try w.appendSlice(g_alloc, "\\t"),
            else => {
                if (c < 0x20) continue;
                try w.append(g_alloc, c);
            },
        }
    }
}

fn getState(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    var out: std.ArrayList(u8) = .empty;
    const now = std.time.timestamp();
    var running: usize = 0;
    for (g_apps[0..g_napps]) |*a| {
        if (a.status == .running) running += 1;
    }
    try out.writer(g_alloc).print(
        "{{\"version\":\"{s}\",\"uptime\":{d},\"running\":{d},\"apps\":[", .{ bridge.RINGSERV_VERSION, now - g_started_at, running });
    g_mu.lock();
    for (g_apps[0..g_napps], 0..) |*a, i| {
        if (i > 0) try out.append(g_alloc, ',');
        try out.writer(g_alloc).print(
            "{{\"name\":\"{s}\",\"mode\":\"{s}\",\"port\":{d},\"status\":\"{s}\"," ++
                "\"pid\":{d},\"uptime\":{d}}}",
            .{
                a.name,
                @tagName(a.mode),
                a.port,
                @tagName(a.status),
                a.pid,
                if (a.status == .running) now - a.started_at else 0,
            },
        );
    }
    g_mu.unlock();
    try out.appendSlice(g_alloc, "]}");
    res.content_type = .JSON;
    res.body = out.items;
}

fn nameOf(req: *httpz.Request) ?[]const u8 {
    const body = req.body() orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch return null;
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("name") orelse return null;
    return if (v == .string) v.string else null;
}

fn postStart(req: *httpz.Request, res: *httpz.Response) !void {
    const name = nameOf(req) orelse {
        res.status = 400;
        res.body = "{\"error\":\"which app? — {\\\"name\\\": ...}\"}";
        return;
    };
    const app = findApp(name) orelse {
        res.status = 404;
        res.body = "{\"error\":\"no such app\"}";
        return;
    };
    const err = startApp(app) catch |e| @errorName(e);
    res.content_type = .JSON;
    if (err.len == 0) {
        res.body = "{\"ok\":1}";
    } else {
        res.status = 409;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(g_alloc, "{\"error\":\"");
        try jsonEscape(&out, err);
        try out.appendSlice(g_alloc, "\"}");
        res.body = out.items;
    }
}

fn postStop(req: *httpz.Request, res: *httpz.Response) !void {
    const name = nameOf(req) orelse {
        res.status = 400;
        res.body = "{\"error\":\"which app? — {\\\"name\\\": ...}\"}";
        return;
    };
    const app = findApp(name) orelse {
        res.status = 404;
        res.body = "{\"error\":\"no such app\"}";
        return;
    };
    const err = stopApp(app);
    res.content_type = .JSON;
    if (err.len == 0) {
        res.body = "{\"ok\":1}";
    } else {
        res.status = 409;
        res.body = "{\"error\":\"not running\"}";
    }
}

fn getLogs(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const name = query.get("app") orelse {
        res.status = 400;
        res.body = "which app? — /panel/logs?app=name";
        return;
    };
    const app = findApp(name) orelse {
        res.status = 404;
        res.body = "no such app";
        return;
    };
    g_mu.lock();
    const copy = res.arena.dupe(u8, app.log[0..app.log_len]) catch app.log[0..0];
    g_mu.unlock();
    res.content_type = .TEXT;
    res.body = copy;
}

fn postCall(req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse "";
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"body must be {name, request}\"}";
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "{\"error\":\"body must be {name, request}\"}";
        return;
    }
    const namev = parsed.value.object.get("name") orelse .null;
    if (namev != .string) {
        res.status = 400;
        res.body = "{\"error\":\"name is required\"}";
        return;
    }
    const app = findApp(namev.string) orelse {
        res.status = 404;
        res.body = "{\"error\":\"no such app\"}";
        return;
    };
    if (app.status != .running or app.port == 0) {
        res.status = 409;
        res.body = "{\"error\":\"the app is not running (or its port is unknown)\"}";
        return;
    }
    const reqv = parsed.value.object.get("request") orelse .null;
    const payload = try std.fmt.allocPrint(req.arena, "{f}", .{std.json.fmt(reqv, .{})});
    const answer = proxyCall(req.arena, app.port, payload) catch {
        res.status = 502;
        res.body = "{\"error\":\"the app did not answer\"}";
        return;
    };
    res.content_type = .JSON;
    res.body = answer;
}

/// Start every stopped app — the page's "Start server". The panel stays
/// resident either way: a stop button that kills the only thing able to
/// start again is a trap, which is why these exist beside /panel/shutdown
/// rather than replacing it (shutdown remains for the terminal and gates).
fn postServerStart(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    var started: u32 = 0;
    for (g_apps[0..g_napps]) |*a| {
        if (a.status == .stopped) {
            const err = startApp(a) catch "spawn failed";
            if (err.len == 0) started += 1;
        }
    }
    res.content_type = .JSON;
    var out: std.ArrayList(u8) = .empty;
    try out.writer(g_alloc).print("{{\"ok\":1,\"started\":{d}}}", .{started});
    res.body = out.items;
}

/// Stop every running app; the panel keeps listening.
fn postServerStop(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    var stopped: u32 = 0;
    for (g_apps[0..g_napps]) |*a| {
        if (a.status == .running) {
            if (stopApp(a).len == 0) stopped += 1;
        }
    }
    res.content_type = .JSON;
    var out: std.ArrayList(u8) = .empty;
    try out.writer(g_alloc).print("{{\"ok\":1,\"stopped\":{d}}}", .{stopped});
    res.body = out.items;
}

fn postShutdown(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    for (g_apps[0..g_napps]) |*a| _ = stopApp(a);
    res.body = "{\"ok\":1,\"bye\":1}";
    g_shutdown.store(true, .release);
    // Answer first, then leave: a shutdown that hangs the reply looks
    // like a crash from the page's side.
    const t = try std.Thread.spawn(.{}, struct {
        fn f() void {
            std.Thread.sleep(300 * std.time.ns_per_ms);
            std.process.exit(0);
        }
    }.f, .{});
    t.detach();
}

fn getIndex(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.content_type = .HTML;
    res.body = panel_html;
}

fn getPanelHealth(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.body = "{\"panel\":1}";
}

// -------------------------------------------------------------- the page

const panel_html = @embedFile("panel.html");

// ---------------------------------------------------------------- entry

/// Hidden probe: `ringserv __proxy <port> <body>` — the proxy alone.
pub fn probe(arena: std.mem.Allocator, port: u16, body: []const u8) !u8 {
    const out = proxyCall(arena, port, body) catch |e| {
        std.debug.print("proxy error: {s}\n", .{@errorName(e)});
        return 1;
    };
    std.debug.print("got {d}: {s}\n", .{ out.len, out });
    return 0;
}

pub fn run(arena: std.mem.Allocator, dir: []const u8, port: u16, exe: []const u8) !u8 {
    g_alloc = std.heap.page_allocator;
    g_exe = exe;
    g_started_at = std.time.timestamp();
    scan(arena, dir) catch return 1;
    if (g_napps == 0) {
        std.debug.print(
            "ringserv panel: nothing to host in {s} — an app is a subdirectory " ++
                "with app.ring, or a bare <name>.ring file (the gesture)\n", .{dir});
        return 1;
    }

    var server = try httpz.Server(void).init(g_alloc, .{
        .address = .localhost(port),
        .request = .{ .max_body_size = 1024 * 1024 },
    }, {});
    var router = try server.router(.{});
    router.get("/", getIndex, .{});
    router.get("/health", getPanelHealth, .{});
    router.get("/panel/state", getState, .{});
    router.post("/panel/start", postStart, .{});
    router.post("/panel/stop", postStop, .{});
    router.get("/panel/logs", getLogs, .{});
    router.post("/panel/call", postCall, .{});
    router.post("/panel/server/start", postServerStart, .{});
    router.post("/panel/server/stop", postServerStop, .{});
    router.post("/panel/shutdown", postShutdown, .{});

    std.debug.print(
        "RingServ {s} — panel on http://127.0.0.1:{d}/  ({d} app{s} in {s})\n",
        .{ bridge.RINGSERV_VERSION, port, g_napps, if (g_napps == 1) "" else "s", dir });
    try server.listen();
    return 0;
}
