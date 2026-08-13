//! Phase-1 gates — the RingScript gate culture, in-process against the
//! native bridge. Each test resets the resident state first, so reset
//! itself is exercised constantly. `zig build test` runs them all.

const std = @import("std");
const bridge = @import("bridge");

fn fresh() !void {
    try std.testing.expectEqual(@as(i32, 0), bridge.rs_reset());
}

fn evalOk(code: [*:0]const u8) ![]const u8 {
    const rc = bridge.rs_eval(code);
    if (rc != 0) {
        std.debug.print("eval failed: {s}\n", .{bridge.rs_last_error()});
        return error.EvalFailed;
    }
    return std.mem.span(bridge.rs_last_output());
}

test "gate: init and arithmetic output" {
    try fresh();
    try std.testing.expectEqualStrings("3", try evalOk("see 1+2"));
}

test "gate: state is resident across evals" {
    try fresh();
    _ = try evalOk("x = 5");
    try std.testing.expectEqualStrings("5", try evalOk("see x"));
}

test "gate: errors carry real line numbers and the state survives" {
    try fresh();
    const rc = bridge.rs_eval("see 99\nnosuchfunction()");
    try std.testing.expectEqual(@as(i32, 1), rc);
    const err = std.mem.span(bridge.rs_last_error());
    try std.testing.expect(std.mem.startsWith(u8, err, "line 2:"));
    // The resident state survived the error:
    try std.testing.expectEqualStrings("42", try evalOk("see 42"));
}

test "gate: reset really clears state" {
    try fresh();
    _ = try evalOk("y = 7");
    try std.testing.expectEqual(@as(i32, 0), bridge.rs_reset());
    // y is gone: seeing it is now an error, and the error is trapped.
    try std.testing.expectEqual(@as(i32, 1), bridge.rs_eval("see y"));
}

test "gate: attribute-only class at end of eval (region terminator)" {
    try fresh();
    _ = try evalOk("class point x y z");
    try std.testing.expectEqualStrings("7", try evalOk("p = new point\np.x = 7\nsee p.x"));
}

test "gate: declaration-free evals do not grow the class list" {
    try fresh();
    const before = try std.testing.allocator.dupe(u8, try evalOk("see len(ringvm_classeslist())"));
    defer std.testing.allocator.free(before);
    _ = try evalOk("a = 1");
    _ = try evalOk("b = a + 1");
    const after = try evalOk("see len(ringvm_classeslist())");
    try std.testing.expectEqualStrings(before, after);
}

test "gate: give consumes the input queue and echoes like a terminal" {
    try fresh();
    bridge.rs_set_input("Mansour\n");
    const out = try evalOk("give cName\nsee \"Ahlan \" + cName");
    try std.testing.expectEqualStrings("Mansour\nAhlan Mansour", out);
}

test "gate: give beyond the queue is a clean trapped error" {
    try fresh();
    bridge.rs_set_input("");
    try std.testing.expectEqual(@as(i32, 1), bridge.rs_eval("give cX"));
    const err = std.mem.span(bridge.rs_last_error());
    try std.testing.expect(std.mem.indexOf(u8, err, "exhausted") != null);
    // And the state still answers:
    try std.testing.expectEqualStrings("1", try evalOk("see 1"));
}

test "gate: rs_call round-trips JSON through a Ring function" {
    try fresh();
    _ = try evalOk("func addpair aPair return aPair[1] + aPair[2]");
    const res = std.mem.span(bridge.rs_call("addpair", "[3, 4]"));
    const err = std.mem.span(bridge.rs_last_error());
    try std.testing.expectEqualStrings("", err);
    const n = try std.fmt.parseFloat(f64, std.mem.trim(u8, res, " \r\n"));
    try std.testing.expectEqual(@as(f64, 7), n);
}

test "gate: rs_call refuses hostile function names" {
    try fresh();
    _ = bridge.rs_call("x; system(", "{}");
    const err = std.mem.span(bridge.rs_last_error());
    try std.testing.expect(std.mem.indexOf(u8, err, "invalid function name") != null);
}

test "gate: load reaches the real filesystem" {
    try fresh();
    // Write a real file, load it, call its function.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "helper.ring", .data = "func triple n return 3*n" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "helper.ring");
    defer std.testing.allocator.free(path);
    const code = try std.fmt.allocPrintSentinel(std.testing.allocator, "load \"{s}\"\nsee triple(14)", .{path}, 0);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualStrings("42", try evalOk(code));
}

test "gate: embedded ringlib json survives reset" {
    try fresh();
    const out = try evalOk("see JsonEncode([1,2,3])");
    try std.testing.expect(out.len > 0);
}
