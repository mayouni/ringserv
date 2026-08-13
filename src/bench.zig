//! bench-workers — the phase-1 risk gate, executable.
//!
//! The blueprint's concurrency model is N isolated RingStates, one per
//! worker thread, no sharing (architecture.md §2). The Ring VM has no
//! global-free guarantee in writing, so the model is *proven or replaced
//! here*: each thread owns a private state, runs the same workload, and
//! verifies its own results; the harness then reports scaling.
//!
//! What a pass means: no crash, no cross-thread result corruption, and
//! near-linear throughput up to the core count. What it cannot prove:
//! absence of every data race — this is an empirical gate, run long.

const std = @import("std");

const RingState = opaque {};
extern fn ring_state_init() ?*RingState;
extern fn ring_state_delete(pState: ?*RingState) ?*RingState;
extern fn ring_state_runcode(pState: ?*RingState, cCode: [*:0]const u8) void;
extern fn ring_vm_funcregister2(
    pState: ?*RingState,
    cName: [*:0]const u8,
    pFunc: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern fn ring_vm_api_isnumber(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getnumber(p: ?*anyopaque, n: c_int) f64;

threadlocal var t_result: f64 = 0;

fn resultHook(p: ?*anyopaque) callconv(.c) void {
    if (ring_vm_api_isnumber(p, 1) != 0) {
        t_result = ring_vm_api_getnumber(p, 1);
    }
}

/// The workload: mixed compute + list + string work, ~1 eval unit.
/// Ends by handing its checksum to the hook.
const workload =
    \\nSum = 0
    \\aList = []
    \\for i = 1 to 2000
    \\    nSum += i
    \\    add(aList, i * 2)
    \\next
    \\cStr = ""
    \\for i = 1 to 200
    \\    cStr += string(i)
    \\next
    \\nSum += len(cStr) + aList[2000]
    \\rsb_result(nSum)
;
/// Expected checksum: 1+..+2000 = 2001000; len("12..200") = 492; 2*2000.
const expected: f64 = 2001000 + 492 + 4000;

const evals_per_round = 200;

const WorkerOut = struct {
    ok: bool = false,
    evals: u64 = 0,
};

fn worker(out: *WorkerOut) void {
    const st = ring_state_init() orelse return;
    defer _ = ring_state_delete(st);
    ring_vm_funcregister2(st, "rsb_result", &resultHook);
    var n: u64 = 0;
    var ok = true;
    while (n < evals_per_round) : (n += 1) {
        t_result = -1;
        ring_state_runcode(st, workload);
        if (t_result != expected) ok = false;
    }
    out.ok = ok;
    out.evals = n;
}

pub fn run(max_threads: u32) !void {
    var stdout_buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buf);
    const out = &w.interface;

    try out.print("ringserv bench-workers — N isolated RingStates, {d} evals each\n", .{evals_per_round});
    try out.print("cores: {d}\n\n", .{std.Thread.getCpuCount() catch 0});
    try out.print("{s:>8} {s:>12} {s:>14} {s:>10}\n", .{ "threads", "wall ms", "evals/sec", "verified" });

    var base_rate: f64 = 0;
    var n: u32 = 1;
    while (n <= max_threads) : (n *= 2) {
        const outs = try std.heap.page_allocator.alloc(WorkerOut, n);
        defer std.heap.page_allocator.free(outs);
        for (outs) |*o| o.* = .{};

        var timer = try std.time.Timer.start();
        const threads = try std.heap.page_allocator.alloc(std.Thread, n);
        defer std.heap.page_allocator.free(threads);
        for (threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, worker, .{&outs[i]});
        }
        for (threads) |t| t.join();
        const ns = timer.read();

        var all_ok = true;
        var total: u64 = 0;
        for (outs) |o| {
            if (!o.ok) all_ok = false;
            total += o.evals;
        }
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        const rate = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(ns)) / 1_000_000_000.0);
        if (n == 1) base_rate = rate;
        try out.print("{d:>8} {d:>12.1} {d:>14.0} {s:>10}  (x{d:.2})\n", .{
            n, ms, rate, if (all_ok) "OK" else "CORRUPT", rate / base_rate,
        });
        if (!all_ok) {
            try out.print("\nRESULT CORRUPTION at {d} threads — the isolated-states model FAILED.\n", .{n});
            try out.flush();
            return;
        }
    }
    try out.print("\nAll rounds verified: isolated RingStates ran concurrently without\n", .{});
    try out.print("cross-thread corruption at up to {d} threads.\n", .{max_threads});
    try out.flush();
}
