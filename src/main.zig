//! ringserv — the CLI. Phase 1 surface: run, eval, version, bench-workers.
//! (dev/check/test/docs/build arrive in their roadmap phases.)

const std = @import("std");
const bridge = @import("bridge");
const bench = @import("bench.zig");

extern fn fflush(stream: ?*anyopaque) c_int;

const usage =
    \\ringserv — the Ring language, resident on your server (phase 1)
    \\
    \\  ringserv run <file.ring>     run a Ring program (stdin feeds `give`)
    \\  ringserv eval "<code>"       evaluate Ring code
    \\  ringserv bench-workers [n]   phase-1 gate: N-worker throughput probe
    \\  ringserv version             versions of everything inside
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
            break :blk try arena.dupeZ(u8, src);
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
            std.debug.print("ringserv: VM init failed\n", .{});
            return 1;
        }
        const rc = bridge.rs_eval(code);
        _ = fflush(null); // drain C stdio before stderr reporting
        if (rc != 0) {
            const err = std.mem.span(bridge.rs_last_error());
            std.debug.print("\nringserv: {s}\n", .{err});
            return 1;
        }
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
