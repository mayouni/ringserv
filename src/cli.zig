//! cli.zig — new / test / dev / where.
//!
//! Design rule from docs/cli.md: hardware, network and toolchains are
//! never required. `new` writes embedded templates, `test` runs in
//! process against the dispatcher, `dev` supervises a child `run`.

const std = @import("std");
const bridge = @import("bridge");

const tpl_app = @embedFile("templates/app.ring");
const tpl_test = @embedFile("templates/test.ring");
const tpl_index = @embedFile("templates/index.html");

extern fn fflush(stream: ?*anyopaque) c_int;

/// Replace every __APPNAME__ with the app's name.
fn render(arena: std.mem.Allocator, template: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, "__APPNAME__")) |i| {
        try out.appendSlice(arena, rest[0..i]);
        try out.appendSlice(arena, name);
        rest = rest[i + "__APPNAME__".len ..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

// ------------------------------------------------------------------ new

pub fn new(arena: std.mem.Allocator, name: []const u8) !u8 {
    if (name.len == 0) {
        std.debug.print("ringserv new: a name is required\n", .{});
        return 2;
    }
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') {
            std.debug.print("ringserv new: '{s}' — use letters, digits, - or _\n", .{name});
            return 2;
        }
    }
    // Refuse to write into an existing folder: a scaffold that can
    // overwrite someone's work is a scaffold nobody trusts.
    if (std.fs.cwd().access(name, .{})) |_| {
        std.debug.print("ringserv new: '{s}' already exists\n", .{name});
        return 1;
    } else |_| {}

    var dir = try std.fs.cwd().makeOpenPath(name, .{});
    defer dir.close();
    try dir.makePath("public");
    try dir.makePath("tests");

    try dir.writeFile(.{ .sub_path = "app.ring", .data = try render(arena, tpl_app, name) });
    try dir.writeFile(.{ .sub_path = "tests/app.ring", .data = try render(arena, tpl_test, name) });
    try dir.writeFile(.{ .sub_path = "public/index.html", .data = try render(arena, tpl_index, name) });

    std.debug.print(
        \\Created {s}/
        \\  app.ring            your services, data and contracts
        \\  public/index.html   a page that calls them
        \\  tests/app.ring      tests that already pass
        \\
        \\  cd {s}
        \\  ringserv dev        serve it, reload on save
        \\  ringserv test       run the tests
        \\
    , .{ name, name });
    return 0;
}

// ----------------------------------------------------------------- test

/// Run every tests/*.ring against the app, in process. The database is
/// forced to :memory: no matter what the app declares — tests must
/// never touch real data, and that is not the test author's job to
/// remember.
pub fn runTests(arena: std.mem.Allocator, app_path: []const u8) !u8 {
    const app_src = readFileZ(arena, app_path) catch {
        std.debug.print("ringserv test: cannot read {s}\n", .{app_path});
        return 1;
    };

    try bridge.db.configure(":memory:");
    bridge.db.setDisplayPath(":memory:");
    bridge.rs_set_echo(1);
    if (bridge.rs_init() != 0) {
        std.debug.print("ringserv test: VM init failed\n", .{});
        return 1;
    }
    if (bridge.rs_eval(app_src) != 0) {
        std.debug.print("ringserv test: {s}\n", .{bridge.rs_last_error()});
        return 1;
    }
    // Materialize the declared schema against this process's connection.
    _ = bridge.rs_call("__rs_data_apply", "0");

    const dir_path = std.fs.path.dirname(app_path) orelse ".";
    const tests_path = try std.fs.path.join(arena, &.{ dir_path, "tests" });
    var tests_dir = std.fs.cwd().openDir(tests_path, .{ .iterate = true }) catch {
        std.debug.print("ringserv test: no tests/ folder next to {s}\n", .{app_path});
        return 1;
    };
    defer tests_dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    var it = tests_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ring")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0) {
        std.debug.print("ringserv test: no .ring files in {s}\n", .{tests_path});
        return 1;
    }
    // Stable order: a test run that shuffles itself is a test run that
    // cannot be compared to the last one.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |name| {
        const full = try std.fs.path.join(arena, &.{ tests_path, name });
        const src = readFileZ(arena, full) catch continue;
        const header = try std.fmt.allocPrintSentinel(arena, "RsTestBegin(\"{s}\")", .{name}, 0);
        _ = bridge.rs_eval(header);
        if (bridge.rs_eval(src) != 0) {
            std.debug.print("  ERROR in {s}: {s}\n", .{ name, bridge.rs_last_error() });
            _ = bridge.rs_eval("RsTestFail(\"the test file ran to completion\", \"it raised an error\")");
        }
    }

    // One call: it prints the report and returns the failure count.
    const failed = std.mem.span(bridge.rs_call("RsTestReport", "0"));
    _ = fflush(null);
    if (std.mem.span(bridge.rs_last_error()).len != 0) {
        std.debug.print("ringserv test: {s}\n", .{bridge.rs_last_error()});
        return 1;
    }
    return if (std.mem.eql(u8, std.mem.trim(u8, failed, " \r\n\""), "0")) 0 else 1;
}

// ------------------------------------------------------------------ dev

/// Serve the app and restart it whenever a .ring file changes.
///
/// A supervisor over a child `run`, deliberately: a reload gets a
/// genuinely fresh VM and a genuinely fresh database connection, so
/// what you see after saving is what a cold start would give you.
/// Residency is for production; honesty is for development.
pub fn dev(arena: std.mem.Allocator, app_path: []const u8) !u8 {
    const exe = try std.fs.selfExePathAlloc(arena);
    const dir_path = std.fs.path.dirname(app_path) orelse ".";

    std.debug.print("ringserv dev — watching {s}/*.ring (Ctrl-C to stop)\n", .{dir_path});

    var last_stamp: i128 = 0;
    var child: ?std.process.Child = null;
    while (true) {
        const stamp = newestRingMtime(arena, dir_path) catch 0;
        if (stamp != last_stamp) {
            if (child) |*c| {
                _ = c.kill() catch {};
                std.debug.print("\n— change detected, restarting —\n", .{});
                // Let the socket close before the child rebinds it.
                std.Thread.sleep(400 * std.time.ns_per_ms);
            }
            var c = std.process.Child.init(&.{ exe, "run", app_path }, arena);
            c.stdin_behavior = .Ignore;
            c.spawn() catch |e| {
                std.debug.print("ringserv dev: cannot start server: {s}\n", .{@errorName(e)});
                return 1;
            };
            child = c;
            last_stamp = stamp;
        }
        std.Thread.sleep(400 * std.time.ns_per_ms);
    }
}

/// Newest mtime among the app's .ring files and its public/ folder.
fn newestRingMtime(arena: std.mem.Allocator, dir_path: []const u8) !i128 {
    var newest: i128 = 0;
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ring")) continue;
        const full = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        defer arena.free(full);
        const st = std.fs.cwd().statFile(full) catch continue;
        if (st.mtime > newest) newest = st.mtime;
    }
    return newest;
}

// ---------------------------------------------------------------- where

pub fn where(arena: std.mem.Allocator) !u8 {
    const exe = std.fs.selfExePathAlloc(arena) catch "?";
    const cwd = std.process.getCwdAlloc(arena) catch "?";
    var stdout_buf: [2048]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buf);
    const out = &w.interface;
    try out.print("RingServ  {s}\n", .{bridge.RINGSERV_VERSION});
    try out.print("Ring VM   1.27 (vendored, compiled in)\n", .{});
    try out.print("SQLite    {s} (vendored, compiled in)\n", .{bridge.db.versionString()});
    try out.print("binary    {s}\n", .{exe});
    try out.print("cwd       {s}\n", .{cwd});
    try out.print("\nNothing else is required: no Ring install, no runtime, no toolchain.\n", .{});
    try out.flush();
    return 0;
}

// -------------------------------------------------------------- helpers

fn readFileZ(arena: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
    return try arena.dupeZ(u8, src);
}
