const std = @import("std");

// RingServ — the vendored Ring VM compiled natively, with the resident
// bridge (src/bridge.zig) and the CLI (src/main.zig). Phase 1 of
// docs/roadmap.md. The source lists and flags mirror RingScript's
// build.zig (the wasm sibling), minus everything WASI.

const vm_hot_sources = [_][]const u8{
    "ringvm/src/vm.c",
    "ringvm/src/vmexpr.c",
    "ringvm/src/vmstack.c",
    "ringvm/src/vmvars.c",
    "ringvm/src/ritem.c",
    "ringvm/src/ritems.c",
    "ringvm/src/rlist.c",
    "ringvm/src/rstring.c",
    "ringvm/src/rhtable.c",
    "ringvm/src/scanner.c",
    "ringvm/src/parser.c",
    "ringvm/src/codegen.c",
    "ringvm/src/stmt.c",
    "ringvm/src/expr.c",
};

const vm_sources = [_][]const u8{
    "ringvm/src/ext.c",
    "ringvm/src/file_e.c",
    "ringvm/src/general.c",
    "ringvm/src/genlib_e.c",
    "ringvm/src/hashlib.c",
    "ringvm/src/list_e.c",
    "ringvm/src/math_e.c",
    "ringvm/src/meta_e.c",
    "ringvm/src/objfile.c",
    "ringvm/src/os_e.c",
    "ringvm/src/ringapi.c",
    "ringvm/src/state.c",
    "ringvm/src/vmerror.c",
    "ringvm/src/vmeval.c",
    "ringvm/src/vmexit.c",
    "ringvm/src/vmfuncs.c",
    "ringvm/src/vmgc.c",
    "ringvm/src/vminfo_e.c",
    "ringvm/src/vmjump.c",
    "ringvm/src/vmlists.c",
    "ringvm/src/vmoop.c",
    "ringvm/src/vmperf.c",
    "ringvm/src/vmrange.c",
    "ringvm/src/vmstate.c",
    "ringvm/src/vmstr.c",
    "ringvm/src/vmthread.c",
    "ringvm/src/vmtry.c",
    // Excluded on purpose:
    //   ring.c / ringw.c — CLI entry points (the bridge is the entry)
    //   dll_e.c          — dynamic library loading (RING_NODLL=1 for now;
    //                      extensions are a later, deliberate decision)
};

const vm_cflags = [_][]const u8{
    // No dynamic extension loading yet — a server security decision to make
    // deliberately (phase 8), not a default inherited silently.
    "-DRING_NODLL=1",
    // Disables system() and chdir()/getcwd() Ring functions — same
    // conservative default as the browser runtime until the sandboxing
    // story for services is designed (phase 2).
    "-DRING_LIMITEDSYS=1",
    // Route VM file access through native_stubs.c: embedded ringlib first,
    // real filesystem second (the server HAS one — the browser did not).
    "-Dfopen=rs_fopen",
    "-Dstat(a,b)=rs_stat(a,b)",
    // Dispatch through the computed-goto loop (RINGSCRIPT PATCH 5 in vm.c).
    "-DRING_VM_COMPUTEDGOTO",
    "-fno-sanitize=undefined",
};

const stub_cflags = [_][]const u8{
    "-DRING_NODLL=1",
    "-DRING_LIMITEDSYS=1",
    "-fno-sanitize=undefined",
};

// SQLite, vendored as the amalgamation (vendor/VENDOR.md records the
// version). Defines chosen for a server: one connection per worker
// thread, never shared, so THREADSAFE=2 (serialized per connection) is
// both correct and faster than the default full mutexing.
const sqlite_cflags = [_][]const u8{
    "-DSQLITE_THREADSAFE=2",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_ENABLE_JSON1",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION", // no dlopen surface in the server
    "-DSQLITE_DQS=0", // double-quoted strings are errors, not fallbacks
    "-fno-sanitize=undefined",
};

// tree-sitter: the C runtime plus the Ring grammar (generated parser +
// external scanner). Both vendored and pinned — vendor/VENDOR.md.
const ts_cflags = [_][]const u8{
    "-std=c11",
    "-fno-sanitize=undefined",
};

fn addTreeSitter(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("vendor/treesitter/lib/include"));
    mod.addIncludePath(b.path("vendor/treesitter/lib/src"));
    mod.addIncludePath(b.path("vendor/tsring/src"));
    mod.addCSourceFiles(.{
        .files = &.{
            "vendor/treesitter/lib/src/lib.c",
            "vendor/tsring/src/parser.c",
            "vendor/tsring/src/scanner.c",
        },
        .flags = &ts_cflags,
    });
}

fn addVm(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("ringvm/include"));
    mod.addIncludePath(b.path("vendor/sqlite"));
    mod.addCSourceFiles(.{ .files = &vm_sources, .flags = &vm_cflags });
    mod.addCSourceFiles(.{
        .files = &vm_hot_sources,
        .flags = &(vm_cflags ++ [_][]const u8{"-O2"}),
    });
    mod.addCSourceFiles(.{ .files = &.{ "src/native_stubs.c", "src/rs_oop.c" }, .flags = &stub_cflags });
    mod.addCSourceFiles(.{ .files = &.{"vendor/sqlite/sqlite3.c"}, .flags = &sqlite_cflags });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode =
        if (b.option(bool, "debug", "Build in Debug mode") orelse false)
            .Debug
        else
            .ReleaseFast;

    // The bridge module carries the vendored VM's C sources; the CLI and
    // the gates both import it, so the VM is attached exactly once per
    // artifact and the bridge API is called as Zig, not re-declared.
    const bridge_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addVm(bridge_mod, b);

    // Vendored HTTP stack (vendor/VENDOR.md records the pins): httpz and
    // its two deps as local modules — no build.zig.zon, nothing fetched.
    const metrics_mod = b.createModule(.{
        .root_source_file = b.path("vendor/metrics/src/metrics.zig"),
        .target = target,
        .optimize = optimize,
    });
    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("vendor/websocket/src/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    const httpz_mod = b.createModule(.{
        .root_source_file = b.path("vendor/httpz/src/httpz.zig"),
        .target = target,
        .optimize = optimize,
    });
    httpz_mod.addImport("metrics", metrics_mod);
    httpz_mod.addImport("websocket", websocket_mod);
    // httpz and websocket each read an options module named "build"
    // (httpz_blocking / websocket_blocking); their own build.zigs generate
    // it — we do the same, defaults kept (non-blocking where the OS allows,
    // httpz falls back by itself on Windows).
    const vendor_opts = b.addOptions();
    vendor_opts.addOption(bool, "httpz_blocking", false);
    vendor_opts.addOption(bool, "websocket_blocking", false);
    const vendor_opts_mod = vendor_opts.createModule();
    httpz_mod.addImport("build", vendor_opts_mod);
    websocket_mod.addImport("build", vendor_opts_mod);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_mod.addImport("bridge", bridge_mod);
    main_mod.addImport("httpz", httpz_mod);
    addTreeSitter(main_mod, b);

    const exe = b.addExecutable(.{ .name = "ringserv", .root_module = main_mod });
    // Deep C recursion happens in the parser and in recursive list
    // operations; match RingScript's proven headroom.
    exe.stack_size = 8 * 1024 * 1024;
    b.installArtifact(exe);

    // `zig build test` — the phase-1 gates (tests/gates.zig) against the
    // resident bridge, in-process.
    const gates_mod = b.createModule(.{
        .root_source_file = b.path("tests/gates.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gates_mod.addImport("bridge", bridge_mod);
    const gates = b.addTest(.{ .root_module = gates_mod });
    const run_gates = b.addRunArtifact(gates);
    const test_step = b.step("test", "Run the bridge gates (in-process)");
    test_step.dependOn(&run_gates.step);

    // `zig build gates` — every suite, one command. Six suites are easy
    // to run five of, and phase 5 adds more.
    const all = b.addSystemCommand(&.{ "node", "tests/all.js" });
    all.setCwd(b.path("."));
    if (b.args) |args| all.addArgs(args);
    all.step.dependOn(b.getInstallStep());
    const gates_step = b.step("gates", "Run EVERY gate suite (add -- --full for soak + oracle)");
    gates_step.dependOn(&all.step);

    // `zig build dist` — cross-compile the CLI for every shipped
    // platform into bin/. These are committed: installing RingServ is
    // downloading one file, with no Zig, no Ring, and no toolchain on
    // the user's machine (the RingScript convention).
    const dist_step = b.step("dist", "Cross-compile ringserv for all shipped platforms into bin/");
    const dist_targets = [_]struct { q: std.Target.Query, name: []const u8 }{
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "ringserv-windows-x64.exe" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "ringserv-linux-x64" },
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "ringserv-linux-arm64" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "ringserv-macos-x64" },
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "ringserv-macos-arm64" },
    };
    for (dist_targets) |t| {
        const dt = b.resolveTargetQuery(t.q);
        const d_bridge = b.createModule(.{
            .root_source_file = b.path("src/bridge.zig"),
            .target = dt,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        addVm(d_bridge, b);
        const d_metrics = b.createModule(.{
            .root_source_file = b.path("vendor/metrics/src/metrics.zig"),
            .target = dt,
            .optimize = .ReleaseFast,
        });
        const d_ws = b.createModule(.{
            .root_source_file = b.path("vendor/websocket/src/websocket.zig"),
            .target = dt,
            .optimize = .ReleaseFast,
        });
        const d_httpz = b.createModule(.{
            .root_source_file = b.path("vendor/httpz/src/httpz.zig"),
            .target = dt,
            .optimize = .ReleaseFast,
        });
        d_httpz.addImport("metrics", d_metrics);
        d_httpz.addImport("websocket", d_ws);
        d_httpz.addImport("build", vendor_opts_mod);
        d_ws.addImport("build", vendor_opts_mod);
        const d_main = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = dt,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        d_main.addImport("bridge", d_bridge);
        d_main.addImport("httpz", d_httpz);
        const e = b.addExecutable(.{ .name = "ringserv", .root_module = d_main });
        e.stack_size = 8 * 1024 * 1024;
        const install = b.addInstallFile(e.getEmittedBin(), b.fmt("../bin/{s}", .{t.name}));
        dist_step.dependOn(&install.step);
    }
}
