//! ringserv — the CLI: new, dev, test, check, docs, run, eval, where.
//! (`build` — a single self-contained executable — is still ahead.)

const std = @import("std");
const bridge = @import("bridge");
const bench = @import("bench.zig");
const serve = @import("serve.zig");
const cli = @import("cli.zig");
const check = @import("check.zig");

extern fn fflush(stream: ?*anyopaque) c_int;

const ServDecl = struct {
    port: u16,
    workers: u32,
    database: []const u8,
    statics: []const serve.StaticRoute,
};

/// Ask the (already evaluated) app whether it declared Serv(), and with
/// what. Answers null for plain programs — `run` then ends as before.
fn servConfig(arena: std.mem.Allocator) ?ServDecl {
    const raw = std.mem.span(bridge.rs_call("__rs_serv_config", "{}"));
    if (std.mem.span(bridge.rs_last_error()).len != 0 or raw.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (jsonNum(obj.get("serv")) orelse 0 != 1) return null;
    const port_f = jsonNum(obj.get("port")) orelse 8080;
    var workers_f = jsonNum(obj.get("workers")) orelse 0;
    if (workers_f <= 0) {
        const cpus: f64 = @floatFromInt(std.Thread.getCpuCount() catch 4);
        workers_f = @min(4, @max(1, cpus / 2));
    }
    const database = switch (obj.get("database") orelse std.json.Value{ .string = ":memory:" }) {
        .string => |s| s,
        else => ":memory:",
    };
    var statics: std.ArrayList(serve.StaticRoute) = .empty;
    if (obj.get("static")) |s| {
        if (s == .array) {
            for (s.array.items) |entry| {
                if (entry != .object) continue;
                const pfx = entry.object.get("prefix") orelse continue;
                const dir = entry.object.get("dir") orelse continue;
                if (pfx != .string or dir != .string) continue;
                statics.append(arena, .{ .prefix = pfx.string, .dir = dir.string }) catch {};
            }
        }
    }
    return .{
        .port = if (port_f >= 1 and port_f <= 65535) @intFromFloat(port_f) else 8080,
        .workers = @intFromFloat(@max(1, @min(64, workers_f))),
        .database = database,
        .statics = statics.items,
    };
}

fn jsonNum(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

const usage =
    \\ringserv — the Ring language, resident on your server
    \\
    \\  ringserv new <name>          scaffold an app that already runs
    \\  ringserv dev [app.ring]      serve it, reload on save
    \\  ringserv test [app.ring]     run tests/ against a scratch database
    \\  ringserv check [app.ring]    syntax + contract agreement, before running
    \\  ringserv docs [--json]       the API catalog, from the declarations
    \\  ringserv run <app.ring>      run for real (or run a plain program)
    \\  ringserv eval "<code>"       evaluate Ring code
    \\  ringserv where               versions and paths
    \\  ringserv version             the short version
    \\  ringserv bench-workers [n]   N-worker throughput probe
    \\
;

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("RingServ {s} (Ring 1.27, resident)\n", .{bridge.RINGSERV_VERSION});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "where")) return cli.where(arena);

    if (std.mem.eql(u8, cmd, "new")) {
        return cli.new(arena, if (args.len > 2) args[2] else "");
    }

    if (std.mem.eql(u8, cmd, "test")) {
        return cli.runTests(arena, if (args.len > 2) args[2] else "app.ring");
    }

    if (std.mem.eql(u8, cmd, "dev")) {
        return cli.dev(arena, if (args.len > 2) args[2] else "app.ring");
    }

    if (std.mem.eql(u8, cmd, "check")) {
        var app: []const u8 = "app.ring";
        var as_json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) as_json = true else app = a;
        }
        return check.checkMode(arena, app, as_json);
    }

    if (std.mem.eql(u8, cmd, "docs")) {
        var app: []const u8 = "app.ring";
        var as_json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) as_json = true else app = a;
        }
        return check.docs(arena, app, as_json);
    }

    if (std.mem.eql(u8, cmd, "bench-workers")) {
        const n: u32 = if (args.len > 2)
            std.fmt.parseInt(u32, args[2], 10) catch 8
        else
            8;
        try bench.run(n);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "eval")) {
        if (args.len < 3) {
            std.debug.print("{s}", .{usage});
            return 2;
        }
        const code: [:0]const u8 = if (std.mem.eql(u8, cmd, "run")) blk: {
            const f = std.fs.cwd().openFile(args[2], .{}) catch |e| {
                std.debug.print("ringserv: cannot open {s}: {s}\n", .{ args[2], @errorName(e) });
                return 1;
            };
            defer f.close();
            const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
            // Native ring normalizes CRLF as it reads; so must we.
            break :blk try cli.normalizeZ(arena, src);
        } else try arena.dupeZ(u8, args[2]);

        // `give` reads stdin LAZILY, one line per request, only when the
        // program actually asks — never slurped up front (a service manager
        // may hold stdin open forever, and most programs never give).
        // Echo only when stdin is not a terminal: a terminal already shows
        // what was typed; a piped transcript should show it like a
        // terminal would — the shape native `ring prog < answers` has.
        bridge.live_give = .{
            .read_line = &readStdinLine,
            .echo = !std.fs.File.stdin().isTty(),
        };

        bridge.rs_set_echo(1);
        if (bridge.rs_init() != 0) {
            std.debug.print("ringserv: runtime init failed: {s}\n", .{bridge.rs_init_error()});
            return 1;
        }
        const rc = bridge.rs_eval(code);
        _ = fflush(null); // drain C stdio before stderr reporting
        if (rc != 0) {
            const err = std.mem.span(bridge.rs_last_error());
            std.debug.print("\nringserv: {s}\n", .{err});
            return 1;
        }

        // If the program declared Serv(), the run continues as a server.
        const cfg = servConfig(arena) orelse return 0;
        // Configure the database BEFORE any worker starts: each worker
        // opens its own connection to this path, which is read-only from
        // then on (no lock needed, per db.zig).
        const db_path = try arena.dupe(u8, cfg.database);
        bridge.db.setDisplayPath(db_path);
        try bridge.db.configure(db_path);
        try serve.start(.{
            .port = cfg.port,
            .workers = cfg.workers,
            .app_source = code,
            .statics = cfg.statics,
        });
        return 0;
    }

    std.debug.print("{s}", .{usage});
    return 2;
}

/// One line from stdin, newline and CR stripped; null at EOF. The line
/// lives in a static buffer valid until the next call — the bridge copies
/// it into Ring before returning from the hook.
fn readStdinLine() ?[]const u8 {
    const S = struct {
        var buf: [64 * 1024]u8 = undefined;
    };
    const stdin = std.fs.File.stdin();
    var n: usize = 0;
    while (n < S.buf.len) {
        var one: [1]u8 = undefined;
        const got = stdin.read(&one) catch 0;
        if (got == 0) {
            if (n == 0) return null;
            break;
        }
        if (one[0] == '\n') break;
        S.buf[n] = one[0];
        n += 1;
    }
    var line: []const u8 = S.buf[0..n];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}
