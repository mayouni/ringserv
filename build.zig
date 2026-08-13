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

fn addVm(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("ringvm/include"));
    mod.addCSourceFiles(.{ .files = &vm_sources, .flags = &vm_cflags });
    mod.addCSourceFiles(.{
        .files = &vm_hot_sources,
        .flags = &(vm_cflags ++ [_][]const u8{"-O2"}),
    });
    mod.addCSourceFiles(.{ .files = &.{ "src/native_stubs.c", "src/rs_oop.c" }, .flags = &stub_cflags });
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

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_mod.addImport("bridge", bridge_mod);

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
    const test_step = b.step("test", "Run the phase-1 gates");
    test_step.dependOn(&run_gates.step);
}
