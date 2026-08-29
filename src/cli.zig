//! cli.zig — new / test / dev / where.
//!
//! Design rule from docs/cli.md: hardware, network and toolchains are
//! never required. `new` writes embedded templates, `test` runs in
//! process against the dispatcher, `dev` supervises a child `run`.

const std = @import("std");
const builtin = @import("builtin");
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

/// `new --gesture` — the first-touch scaffold: one file of plain
/// functions and the yaml beside it, served as-is by `ringserv serve`.
/// The full scaffold below stays the default: the page that calls its
/// own services is the fullstack moment, and the gesture is for the
/// moment BEFORE that one.
pub fn newGesture(arena: std.mem.Allocator, name: []const u8) !u8 {
    if (name.len == 0) {
        std.debug.print("ringserv new: a name is required" ++ .{10}, .{});
        return 2;
    }
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            std.debug.print("ringserv new --gesture: '{s}' becomes the service name, so letters, digits and _ only" ++ .{10}, .{name});
            return 2;
        }
    }
    if (std.fs.cwd().access(name, .{})) |_| {
        std.debug.print("ringserv new: '{s}' already exists" ++ .{10}, .{name});
        return 1;
    } else |_| {}
    var dir = try std.fs.cwd().makeOpenPath(name, .{});
    defer dir.close();
    const app = try std.fmt.allocPrint(arena, tpl_gesture, .{name});
    const file = try std.fmt.allocPrint(arena, "{s}.ring", .{name});
    try dir.writeFile(.{ .sub_path = file, .data = app });
    try dir.writeFile(.{ .sub_path = "ringserv.yaml", .data = tpl_gesture_yaml });
    std.debug.print(
        "Created {s}/" ++ .{10} ++
            "  {s}.ring        plain functions - each one is already an action" ++ .{10} ++
            "  ringserv.yaml   port and workers, outside the code" ++ .{10} ++ .{10} ++
            "Serve it:   ringserv serve {s}/{s}.ring" ++ .{10} ++
            "See the mapping first:   ringserv serve --explain {s}/{s}.ring" ++ .{10},
        .{ name, name, name, name, name, name },
    );
    return 0;
}

const tpl_gesture =
    "# {s}.ring - plain functions. No declarations: `ringserv serve` exposes" ++ .{10} ++
    "# every top-level function as an action (names starting with _ stay" ++ .{10} ++
    "# private), mapping payload keys to parameters by name." ++ .{10} ++ .{10} ++
    "func hello name" ++ .{10} ++
    .{9} ++ "return \"Hello, \" + name + \"!\"" ++ .{10} ++ .{10} ++
    "func add a, b" ++ .{10} ++
    .{9} ++ "return a + b" ++ .{10};

const tpl_gesture_yaml =
    "# ringserv.yaml - configuration, outside the code. The declaration" ++ .{10} ++
    "# (or --port) wins over this file, and collisions are reported." ++ .{10} ++
    "port: 8080" ++ .{10} ++
    "workers: 2" ++ .{10};

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

/// The verbs `testing.ring` puts into the application's namespace under
/// `ringserv test`, and only there. Kept beside the check that uses them
/// so adding a verb and forgetting the diagnostic is one edit, not two.
const test_vocabulary = [_][]const u8{
    "ask", "expect", "expectok", "expectcode",
    "expectstatus", "expecttrue", "laststatus",
};

/// Does this source define one of those names? Ring function names are
/// case-insensitive, so the comparison is too.
fn definesVocabulary(src: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "func ")) |at| {
        i = at + 5;
        var j = i;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
        var k = j;
        while (k < src.len and (std.ascii.isAlphanumeric(src[k]) or src[k] == '_')) k += 1;
        if (k > j) {
            for (test_vocabulary) |v| {
                if (std.ascii.eqlIgnoreCase(src[j..k], v)) return true;
            }
        }
    }
    return false;
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

    bridge.setAppDir(std.fs.path.dirname(app_path) orelse ".");
    // The ONE command that gets the test vocabulary. Asked for before
    // rs_init, because that is when ringlib is loaded — see the
    // `testing_only` note in bridge.zig for why `Ask` may not exist in a
    // served application's namespace.
    bridge.enableTestVocabulary();
    try bridge.db.configure(":memory:");
    bridge.db.setDisplayPath(":memory:");
    bridge.rs_set_echo(1);
    if (bridge.rs_init() != 0) {
        std.debug.print("ringserv test: runtime init failed: {s}\n", .{bridge.rs_init_error()});
        return 1;
    }
    if (bridge.rs_eval(app_src) != 0) {
        const err = std.mem.span(bridge.rs_last_error());
        std.debug.print("ringserv test: {s}\n", .{err});
        // The one collision the scoping ruling deliberately leaves standing.
        // `Ask` and the Expect verbs exist ONLY under this command, so an
        // application that defines one of them serves perfectly and fails
        // here — and Ring reports that as a bare "Function redefinition"
        // with nothing saying where the other definition came from. Naming
        // it is the difference between a diagnosis and an afternoon.
        // Detected from the APP'S OWN SOURCE, not from the error text: the
        // C22 message is printed by the VM's C parser straight to stdout,
        // so it reaches neither rs_last_error nor the output buffer. A
        // source scan is deterministic, and this is a hint — a false
        // positive costs a paragraph nobody needed, which is cheap beside
        // the afternoon a missing one costs.
        if (definesVocabulary(app_src)) {
            std.debug.print(
                \\
                \\  `ringserv test` loads the test vocabulary into your application's
                \\  namespace: Ask, Expect, ExpectOk, ExpectCode, ExpectStatus,
                \\  ExpectTrue. Your app defines one of those names itself.
                \\
                \\  It is a problem only HERE — `run`, `dev` and `serve` never load
                \\  the vocabulary, so the application itself is fine. Rename yours
                \\  for the tests to run.
                \\
                \\
            , .{});
        }
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

/// Not in std's kernel32 bindings; the three Win32 calls the orphan
/// guard below needs.
extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    hJob: std.os.windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *const anyopaque,
    cbJobObjectInformationLength: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(
    hJob: std.os.windows.HANDLE,
    hProcess: std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.BOOL;

const JobObjectExtendedLimitInformation: c_int = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: std.os.windows.DWORD = 0x2000;

// Layout matches JOBOBJECT_BASIC_LIMIT_INFORMATION / _EXTENDED_ / IO_COUNTERS
// from winnt.h exactly — this is an ABI struct, not ours to reshape.
const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: std.os.windows.LARGE_INTEGER = 0,
    PerJobUserTimeLimit: std.os.windows.LARGE_INTEGER = 0,
    LimitFlags: std.os.windows.DWORD = 0,
    MinimumWorkingSetSize: std.os.windows.SIZE_T = 0,
    MaximumWorkingSetSize: std.os.windows.SIZE_T = 0,
    ActiveProcessLimit: std.os.windows.DWORD = 0,
    Affinity: std.os.windows.ULONG_PTR = 0,
    PriorityClass: std.os.windows.DWORD = 0,
    SchedulingClass: std.os.windows.DWORD = 0,
};
const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};
const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: std.os.windows.SIZE_T = 0,
    JobMemoryLimit: std.os.windows.SIZE_T = 0,
    PeakProcessMemoryUsed: std.os.windows.SIZE_T = 0,
    PeakJobMemoryUsed: std.os.windows.SIZE_T = 0,
};

/// Windows only: a Job Object with KILL_ON_JOB_CLOSE, so the OS itself
/// kills every child assigned to it the moment THIS process's handle to
/// the job closes — which Windows does unconditionally on exit, including
/// a hard kill nothing in this process could have caught to clean up
/// after. Returns null on any failure; the caller treats that as "no
/// guard available" rather than a reason to refuse to serve.
fn makeKillOnCloseJob() ?std.os.windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return null;
    var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) {
        return null;
    }
    return job;
}

/// Serve the app and restart it whenever a .ring file changes.
///
/// A supervisor over a child `run`, deliberately: a reload gets a
/// genuinely fresh VM and a genuinely fresh database connection, so
/// what you see after saving is what a cold start would give you.
/// Residency is for production; honesty is for development.
///
/// ORPHAN GUARD (found 2026-08-28: docs/GATES.md had named this gap
/// since phase 4). Killing `dev` the ordinary way — Ctrl-C, SIGTERM —
/// already worked: the loop above catches nothing, but the process exit
/// takes the child down with it via the OS's normal cleanup on some
/// platforms and via the explicit kill below on the rest. The gap was
/// an ABRUPT kill: SIGKILL, or `taskkill /F` without `/T`, leaves no
/// userspace code in `dev` to run at all — reproduced by hand before
/// writing this: killing only the `dev` process on Windows left the
/// child `run` alive and still answering `/health`, forever, with the
/// port still held. Two different mechanisms, because there is no
/// single one both platforms share:
///
///   WINDOWS: a Job Object (below) — the OS kills the child when
///   THIS process's last handle to the job closes, which Windows does
///   unconditionally on any exit, including one nothing here saw coming.
///
///   POSIX: the CHILD watches for the ORIGINAL parent's death itself,
///   armed only when `RINGSERV_DEV_CHILD` says it was launched by `dev`
///   (see main.zig's armOrphanGuard — a bare `ringserv run` must never
///   die just because its shell did, which is the normal, supported way
///   to run it as a daemon).
pub fn dev(arena: std.mem.Allocator, app_path: []const u8) !u8 {
    const exe = try std.fs.selfExePathAlloc(arena);
    const dir_path = std.fs.path.dirname(app_path) orelse ".";

    std.debug.print("ringserv dev — watching {s}/*.ring (Ctrl-C to stop)\n", .{dir_path});

    const job: ?std.os.windows.HANDLE = if (builtin.os.tag == .windows) makeKillOnCloseJob() else null;

    var env = try std.process.getEnvMap(arena);
    try env.put("RINGSERV_DEV_CHILD", "1");
    var ppid_buf: [32]u8 = undefined;
    const own_pid = if (builtin.os.tag != .windows) std.c.getpid() else 0;
    try env.put("RINGSERV_DEV_PPID", try std.fmt.bufPrint(&ppid_buf, "{d}", .{own_pid}));

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
            c.env_map = &env;
            c.spawn() catch |e| {
                std.debug.print("ringserv dev: cannot start server: {s}\n", .{@errorName(e)});
                return 1;
            };
            if (job) |j| _ = AssignProcessToJobObject(j, c.id);
            child = c;
            last_stamp = stamp;
        }
        std.Thread.sleep(400 * std.time.ns_per_ms);
    }
}

/// POSIX half of the orphan guard (see the doc comment on `dev` above
/// for the whole picture, Windows included). A no-op unless
/// RINGSERV_DEV_CHILD says `dev` spawned this very process — an
/// ordinary `ringserv run app.ring` must keep serving if the shell that
/// started it exits, which is the normal, supported way to run it as a
/// daemon, and must not be punished for sharing a mechanism with `dev`.
pub fn armOrphanGuard() void {
    if (builtin.os.tag == .windows) return; // the Job Object does this instead
    if (std.posix.getenv("RINGSERV_DEV_CHILD") == null) return;
    const ppid_str = std.posix.getenv("RINGSERV_DEV_PPID") orelse return;
    const ppid = std.fmt.parseInt(std.posix.pid_t, ppid_str, 10) catch return;

    if (builtin.os.tag == .linux) {
        // Event-driven: the kernel signals THIS thread the instant its
        // parent dies, by any means, including SIGKILL -- nothing here
        // has to run for it to fire.
        _ = std.posix.prctl(.SET_PDEATHSIG, .{std.posix.SIG.TERM}) catch {};
        // Closes the race where the parent was already gone (and this
        // process already reparented) before prctl above had a chance
        // to arm — one immediate check is enough; the poll loop below
        // isn't needed on Linux because prctl already covers every
        // later death.
        std.posix.kill(ppid, 0) catch std.process.exit(0);
        return;
    }

    // macOS/BSD have no PDEATHSIG equivalent, so this polls instead —
    // checking the ORIGINAL parent's liveness (recorded at spawn time),
    // never getppid(), because getppid() changes the moment this
    // process is reparented, which is precisely the event being waited
    // for.
    const watch = struct {
        fn run(pid: std.posix.pid_t) void {
            while (true) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                std.posix.kill(pid, 0) catch std.process.exit(0);
            }
        }
    }.run;
    const t = std.Thread.spawn(.{}, watch, .{ppid}) catch return;
    t.detach();
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
    // The build mode, beside the versions — same estate rule as `version`.
    std.debug.print("Build     {s}\n", .{@tagName(builtin.mode)});
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

    // The library search root, if one was found. A search root nobody can
    // see is a search root nobody can debug — and this one is OPTIONAL, so
    // its absence has to read as a fact rather than as a fault.
    const home = std.mem.span(bridge.ringHome());
    if (home.len == 0) {
        try out.print("Ring home (none — no RINGSERV_RING_HOME, no `ring` on PATH)\n", .{});
    } else {
        try out.print("Ring home {s}\n", .{home});
    }

    try out.print(
        \\
        \\Nothing else is required to RUN an application: no Ring install, no
        \\runtime, no toolchain. A Ring installation is needed only to `load`
        \\Ring's own bundled libraries — and even then `loadlib` is absent, so
        \\see docs/LOADING.md for both halves.
        \\
    , .{});
    try out.flush();
    return 0;
}

// -------------------------------------------------------------- helpers

/// Read a Ring source file the way the native interpreter does.
///
/// Native `ring` normalizes CRLF to LF as it reads, so a multi-line
/// string literal in a Windows-saved file contains bare newlines. We
/// passed the raw bytes and a literal came out two characters longer per
/// line — found by the wide sample sweep, invisible to every hand-written
/// gate. Every path that loads a .ring file goes through here.
pub fn readSourceZ(arena: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const src = try f.readToEndAlloc(arena, 64 * 1024 * 1024);
    return normalizeZ(arena, src);
}

pub fn normalizeZ(arena: std.mem.Allocator, src: []const u8) ![:0]const u8 {
    if (std.mem.indexOf(u8, src, "\r\n") == null) return arena.dupeZ(u8, src);
    var out = try std.ArrayList(u8).initCapacity(arena, src.len);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
        out.appendAssumeCapacity(src[i]);
    }
    return out.toOwnedSliceSentinel(arena, 0);
}

fn readFileZ(arena: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    return readSourceZ(arena, path);
}
