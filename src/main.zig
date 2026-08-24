//! ringserv — the CLI: new, dev, test, check, docs, run, eval, where.
//! (`build` — a single self-contained executable — is still ahead.)

const std = @import("std");
const builtin = @import("builtin");
const bridge = @import("bridge");
const bench = @import("bench.zig");
const serve = @import("serve.zig");
const cli = @import("cli.zig");
const check = @import("check.zig");
const topology_cmd = @import("topology.zig");
const journal_cmd = @import("journal.zig");
const panel = @import("panel.zig");
const js = bridge.js;

extern fn fflush(stream: ?*anyopaque) c_int;

/// Is this address only reachable from this machine?
///
/// The TLS decision (docs/TLS.md) in one predicate. RingServ speaks plain
/// HTTP and terminates no TLS, so binding anything a network can reach is
/// a decision about exposure — and it is made HERE, once, rather than
/// left to whoever writes the deployment.
fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "localhost")) return true;
    // The whole 127/8 block, since 127.0.0.2 is as local as 127.0.0.1.
    return std.mem.startsWith(u8, host, "127.");
}

const ServDecl = struct {
    port: u16,
    host: []const u8,
    behind_proxy: bool,
    workers: u32,
    database: []const u8,
    statics: []const serve.StaticRoute,
    announce: bool = true,
    app: []const u8 = "app",
    custody: []const u8 = "L0",
    alg: []const u8 = "none",
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
    const host = switch (obj.get("host") orelse std.json.Value{ .string = "127.0.0.1" }) {
        .string => |h| if (h.len == 0) "127.0.0.1" else h,
        else => "127.0.0.1",
    };
    const app_name = switch (obj.get("app") orelse std.json.Value{ .string = "app" }) {
        .string => |a| if (a.len == 0) "app" else a,
        else => "app",
    };
    const custody = switch (obj.get("custody") orelse std.json.Value{ .string = "L0" }) {
        .string => |a| a,
        else => "L0",
    };
    const alg = switch (obj.get("alg") orelse std.json.Value{ .string = "none" }) {
        .string => |a| a,
        else => "none",
    };
    return .{
        .port = if (port_f >= 1 and port_f <= 65535) @intFromFloat(port_f) else 8080,
        .host = host,
        .behind_proxy = (jsonNum(obj.get("behindproxy")) orelse 0) != 0,
        .workers = @intFromFloat(@max(1, @min(64, workers_f))),
        .database = database,
        .statics = statics.items,
        .announce = (jsonNum(obj.get("announce")) orelse 1) != 0,
        .app = app_name,
        .custody = custody,
        .alg = alg,
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
    \\  ringserv topology [--emit]   the placement map; --emit writes zing.json
    \\  ringserv journal <verb>      list / verify / export the fiscal record
    \\  ringserv serve <file.ring>   serve a file of plain functions, as-is
    \\  ringserv panel [dir]         the admin panel: apps, start/stop, logs
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

    // A hidden probe used only by the phase-7 gates: prove the JS guest
    // is alive and behaving before anything is built on it.
    //
    //   ringserv js-eval "<code>"                    evaluate
    //   ringserv js-eval "<code>" <fn> <json-arg>    ...then call fn(arg)
    //
    // The second form is the one that matters: it exercises js_call, whose
    // contract must equal rs_call's exactly, because the dispatcher is
    // about to stop knowing which guest it is talking to.
    if (std.mem.eql(u8, cmd, "js-eval")) {
        if (args.len < 3) return 2;
        js.js_set_echo(1);
        if (js.js_init() != 0) {
            std.debug.print("ringserv: {s}\n", .{js.js_last_error()});
            return 1;
        }
        const code = try arena.dupeZ(u8, args[2]);
        if (js.js_eval(code) != 0) {
            std.debug.print("ringserv: {s}\n", .{js.js_last_error()});
            return 1;
        }
        if (args.len >= 5) {
            const fname = try arena.dupeZ(u8, args[3]);
            const jarg = try arena.dupeZ(u8, args[4]);
            const out = std.mem.span(js.js_call(fname, jarg));
            const err = std.mem.span(js.js_last_error());
            if (err.len != 0) {
                std.debug.print("ringserv: {s}\n", .{err});
                return 1;
            }
            std.debug.print("{s}\n", .{out});
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "version")) {
        // THE BUILD MODE IS PRINTED, ALWAYS. Estate rule (decisions/LEDGER
        // line 106): a repository publishing benchmark numbers names the
        // mode WHERE THE NUMBERS ARE READ. This binary defaults to
        // ReleaseFast and `-Ddebug` is opt-in — but a safe default
        // satisfies the condition, not the rule: a correct measurement
        // published with no mode named is still a number a later reader
        // cannot check. So the binary answers for itself, in every mode.
        std.debug.print("RingServ {s} (Ring 1.27, resident, {s})\n",
            .{ bridge.RINGSERV_VERSION, @tagName(builtin.mode) });
        return 0;
    }

    if (std.mem.eql(u8, cmd, "where")) return cli.where(arena);

    if (std.mem.eql(u8, cmd, "new")) {
        var name: []const u8 = "";
        var gesture = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--gesture")) gesture = true else name = a;
        }
        if (gesture) return cli.newGesture(arena, name);
        return cli.new(arena, name);
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

    if (std.mem.eql(u8, cmd, "topology")) {
        var app: []const u8 = "app.ring";
        var do_emit = false;
        var as_json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--emit")) {
                do_emit = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                as_json = true;
            } else app = a;
        }
        return topology_cmd.topology(arena, app, do_emit, as_json);
    }

    // The journal has its own verbs, so its arguments are passed through
    // whole rather than pre-parsed here: `list`, `verify` and `export` do
    // not take the same flags, and a dispatcher that flattens them would
    // have to know which flag belongs to which verb.
    if (std.mem.eql(u8, cmd, "journal")) {
        return journal_cmd.journal(arena, args[2..]);
    }

    if (std.mem.eql(u8, cmd, "docs")) {
        var app: []const u8 = "app.ring";
        var as_json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) as_json = true else app = a;
        }
        return check.docs(arena, app, as_json);
    }

    if (std.mem.eql(u8, cmd, "__proxy")) {
        if (args.len < 4) return 2;
        const pport = std.fmt.parseInt(u16, args[2], 10) catch return 2;
        return panel.probe(arena, pport, args[3]);
    }

    if (std.mem.eql(u8, cmd, "panel")) {
        var dir: []const u8 = ".";
        var port: u16 = 8079;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                if (i >= args.len) return 2;
                port = std.fmt.parseInt(u16, args[i], 10) catch 8079;
            } else dir = args[i];
        }
        const exe = try std.fs.selfExePathAlloc(arena);
        return panel.run(arena, dir, port, exe);
    }

    if (std.mem.eql(u8, cmd, "bench-workers")) {
        const n: u32 = if (args.len > 2)
            std.fmt.parseInt(u32, args[2], 10) catch 8
        else
            8;
        try bench.run(n);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "eval") or
        std.mem.eql(u8, cmd, "serve"))
    {
        if (args.len < 3) {
            std.debug.print("{s}", .{usage});
            return 2;
        }
        var serve_code: ?[:0]const u8 = null;
        // THE GESTURE (docs/PLAN.md phase 10): `serve file.ring` turns a
        // file of plain functions into a service. The Zig side only
        // composes — a trailer calling RsGestureBoot is prepended to the
        // user's source (BEFORE it, because Ring executes top-level
        // statements only until the first `func`), and everything else
        // rides the ordinary run path below. The mapping itself lives in
        // src/ringlib/gesture.ring, where --explain can print it.
        if (std.mem.eql(u8, cmd, "serve")) {
            var file: []const u8 = "";
            var port: u32 = 0;
            var explain = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                const a = args[i];
                if (std.mem.eql(u8, a, "--explain")) {
                    explain = true;
                } else if (std.mem.eql(u8, a, "--port")) {
                    i += 1;
                    if (i >= args.len) {
                        std.debug.print("ringserv serve: --port needs a number\n", .{});
                        return 2;
                    }
                    port = std.fmt.parseInt(u32, args[i], 10) catch {
                        std.debug.print("ringserv serve: --port needs a number, got {s}\n", .{args[i]});
                        return 2;
                    };
                } else {
                    file = a;
                }
            }
            if (file.len == 0) {
                std.debug.print("ringserv serve: which file? — ringserv serve <file.ring>\n", .{});
                return 2;
            }
            const f = std.fs.cwd().openFile(file, .{}) catch |e| {
                std.debug.print("ringserv: cannot open {s}: {s}\n", .{ file, @errorName(e) });
                return 1;
            };
            const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
            f.close();
            // A file that already declares a server has outgrown the
            // gesture — refusing beats booting it twice.
            if (std.mem.indexOf(u8, src, "RingServ(") != null) {
                std.debug.print(
                    "ringserv serve: {s} already declares RingServ([...]) — " ++
                        "it is a full application; use `ringserv run {s}`\n",
                    .{ file, file },
                );
                return 2;
            }
            // The service name is the file's base name — stated, and
            // validated the same way service names always are.
            const base = std.fs.path.stem(std.fs.path.basename(file));
            var name_ok = base.len > 0 and (std.ascii.isAlphabetic(base[0]) or base[0] == '_');
            for (base) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) name_ok = false;
            }
            if (!name_ok) {
                std.debug.print(
                    "ringserv serve: the file name becomes the service name, and " ++
                        "`{s}` is not a valid one (letters, digits, _ — starting " ++
                        "with a letter). Rename the file, or declare the service " ++
                        "with RingServ([...]).\n",
                    .{base},
                );
                return 2;
            }
            // The path reaches Ring as a string literal: absolute, with
            // forward slashes, and refused outright if it holds a quote.
            const abs = std.fs.cwd().realpathAlloc(arena, file) catch file;
            const abs_fwd = try arena.dupe(u8, abs);
            for (abs_fwd) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            if (std.mem.indexOfScalar(u8, abs_fwd, '"') != null) {
                std.debug.print("ringserv serve: a path containing a quote cannot be served\n", .{});
                return 2;
            }
            bridge.setAppDir(std.fs.path.dirname(abs_fwd) orelse ".");
            if (explain) {
                bridge.rs_set_echo(1);
                if (bridge.rs_init() != 0) {
                    std.debug.print("ringserv: runtime init failed: {s}\n", .{bridge.rs_init_error()});
                    return 1;
                }
                const one = try std.fmt.allocPrintSentinel(arena, "RsGestureExplain(\"{s}\", \"{s}\")", .{ abs_fwd, base }, 0);
                if (bridge.rs_eval(one) != 0) {
                    std.debug.print("ringserv: {s}\n", .{std.mem.span(bridge.rs_last_error())});
                    return 1;
                }
                return 0;
            }
            const norm = try cli.normalizeZ(arena, src);
            const composed = try std.fmt.allocPrintSentinel(
                arena,
                "RsGestureBoot(\"{s}\", \"{s}\", {d})\n{s}",
                .{ abs_fwd, base, port, norm },
                0,
            );
            serve_code = composed;
        }
        const code: [:0]const u8 = if (serve_code) |sc| sc else if (std.mem.eql(u8, cmd, "run")) blk: {
            const f = std.fs.cwd().openFile(args[2], .{}) catch |e| {
                std.debug.print("ringserv: cannot open {s}: {s}\n", .{ args[2], @errorName(e) });
                return 1;
            };
            defer f.close();
            const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
            // A `:js` path is resolved against the application, so the
            // application's own directory has to be known before it runs.
            bridge.setAppDir(std.fs.path.dirname(args[2]) orelse ".");
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

        // THE TLS DECISION, ENFORCED (docs/TLS.md). RingServ terminates no
        // TLS: it speaks plain HTTP and expects a reverse proxy in front.
        // A decision that lives only in a document is a decision somebody
        // will miss at 2am, so binding an address a network can reach
        // requires saying out loud that TLS is handled — and the refusal
        // names the two ways forward rather than only the problem.
        if (!isLoopback(cfg.host) and !cfg.behind_proxy) {
            std.debug.print(
                \\ringserv: refusing to serve plain HTTP on {s}:{d}.
                \\
                \\RingServ terminates no TLS. Binding an address the network can
                \\reach would publish every request and every token in clear text.
                \\
                \\Either put a TLS-terminating proxy in front — caddy, nginx,
                \\traefik — and tell RingServ you have:
                \\
                \\    RingServ([ :host = "{s}", :behindproxy = true, ... ])
                \\
                \\or leave :host alone and reach it through the proxy on loopback,
                \\which is the arrangement docs/TLS.md recommends.
                \\
            , .{ cfg.host, cfg.port, cfg.host });
            return 1;
        }
        if (!isLoopback(cfg.host)) {
            std.debug.print(
                "ringserv: serving plain HTTP on {s}:{d} — :behindproxy is set, " ++
                    "so TLS is the proxy's job.\n",
                .{ cfg.host, cfg.port },
            );
        }

        // The family handshake, ON by default (docs/PLAN.md phase 12):
        // zero-config symbiosis is the point, and refusing is one word.
        // Started before serve.start because serve.start blocks.
        if (cfg.announce) {
            bridge.family.start(
                try arena.dupe(u8, cfg.app),
                try arena.dupe(u8, cfg.host),
                cfg.port,
                try arena.dupe(u8, cfg.custody),
                try arena.dupe(u8, cfg.alg),
            );
        }

        try serve.start(.{
            .port = cfg.port,
            .host = try arena.dupe(u8, cfg.host),
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
