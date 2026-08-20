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

// ---------------------------------------------------------------------
// Load integrity — the class of bug that hid `func Call` (call is a Ring
// keyword, so testing.ring silently defined nothing and rs_init said OK).
// ring_state_runcode reports no failure, so the runtime must prove for
// itself that every embedded file actually defined what it promises.

test "gate: rs_init reports no error on a healthy runtime" {
    try fresh();
    try std.testing.expectEqualStrings("", std.mem.span(bridge.rs_init_error()));
}

test "gate: every SERVED ringlib file is loaded and callable" {
    try fresh();
    // One live call per file — not merely isfunction(), which a stub
    // would also satisfy. If a file failed to compile, these raise.
    try std.testing.expectEqualStrings("[1,2]", try evalOk("see JsonEncode([1,2])"));
    _ = try evalOk("aRs = __dispatch([ :service = \"x\", :action = \"y\", :payload = [] ])");
    try std.testing.expectEqualStrings("1", try evalOk("see len(__dispatch([]))>0"));
    _ = try evalOk("Data([ :probe = [ :a = :string ] ])");
    try std.testing.expectEqualStrings("1", try evalOk("see len(DataQuery(\"select 1\", []))"));
    try std.testing.expectEqualStrings("1", try evalOk("see RsHasGeneric([ :table = \"probe\" ], \"list\")"));
    try std.testing.expectEqualStrings("", try evalOk("see RsContractCheck(\"nope\", \"nope\", [])"));

    // `Ask` is DELIBERATELY ABSENT here. testing.ring loads for
    // `ringserv test` only (RINGSERV-RINGLIBNS-01, ruled 2026-08-20):
    // every ringlib file occupies the APPLICATION's namespace, and an app
    // with its own `Ask` — an ordinary English word — could not otherwise
    // define one. The next gate holds the other half of that ruling.
}

test "gate: the test vocabulary is absent when serving and present under test" {
    try fresh();
    // Absent: this is the half that makes an application's own `Ask` legal.
    try std.testing.expect(!bridge.probeFunction("ask"));
    try std.testing.expect(!bridge.probeFunction("expectok"));

    // Present: and this is the half that keeps `ringserv test` working.
    // Same process, same bridge — only the host's request differs.
    bridge.enableTestVocabulary();
    try fresh();
    try std.testing.expect(bridge.probeFunction("ask"));
    _ = try evalOk("aRs = Ask(:x, :y, [])");
    try std.testing.expectEqualStrings("", std.mem.span(bridge.rs_init_error()));
}

test "gate: the region-terminator counter does not grow on plain evals" {
    try fresh();
    // A long-lived server evaluates constantly; the class list must not
    // grow for code that opens no declaration region.
    const before = try std.testing.allocator.dupe(u8, try evalOk("see len(ringvm_classeslist())"));
    defer std.testing.allocator.free(before);
    var i: usize = 0;
    while (i < 200) : (i += 1) _ = try evalOk("nRs = 1 + 1");
    try std.testing.expectEqualStrings(before, try evalOk("see len(ringvm_classeslist())"));
}

test "gate: the load detector discriminates present from absent" {
    try fresh();
    // Every file's sentinel is really there...
    // `ask` is not in this list on purpose — see the scoping gate above.
    for ([_][]const u8{ "jsonencode", "__dispatch", "dataquery", "rsrungeneric", "rscontractcheck" }) |name| {
        try std.testing.expect(bridge.probeFunction(name));
    }
    // ...and the check would notice if one were not. Without this, a
    // detector that always answered "yes" would look identical.
    try std.testing.expect(!bridge.probeFunction("rs_no_such_function_xyz"));
}

// ---------------------------------------------------------------------
// The C JSON codec must be BYTE-IDENTICAL to the pure-Ring reference.
//
// src/rs_json.c is the shipped codec — it sits on the response path of
// every request — while src/ringlib/json.ring stays as the reference and
// is what native Ring runs. These gates load the reference under renamed
// entry points and diff the two, outputs AND error texts, so they cannot
// drift apart. Technique carried over from RingScript, where the codec
// was written and the same contract was held.

/// Load the pure codec into the live VM under PureJsonEncode /
/// PureJsonDecode, so both implementations exist side by side.
fn loadPureReference() !void {
    const a = std.mem.replaceOwned(u8, std.testing.allocator, bridge.json_pure_src, "func JsonEncode v", "func PureJsonEncode v") catch return error.OutOfMemory;
    defer std.testing.allocator.free(a);
    const b = std.mem.replaceOwned(u8, std.testing.allocator, a, "func JsonDecode cJson", "func PureJsonDecode cJson") catch return error.OutOfMemory;
    defer std.testing.allocator.free(b);
    const code = try std.testing.allocator.dupeZ(u8, b);
    defer std.testing.allocator.free(code);
    if (bridge.rs_eval(code) != 0) {
        std.debug.print("pure reference failed to load: {s}\n", .{bridge.rs_last_error()});
        return error.ReferenceLoadFailed;
    }
}

/// Ring source with Q standing in for a double quote, so the cases below
/// stay readable instead of drowning in escapes.
fn evalQ(comptime fmt: []const u8, args: anytype) ![]const u8 {
    const raw = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
    defer std.testing.allocator.free(raw);
    const quoted = try std.mem.replaceOwned(u8, std.testing.allocator, raw, "Q", "\" + char(34) + \"");
    defer std.testing.allocator.free(quoted);
    const code = try std.testing.allocator.dupeZ(u8, quoted);
    defer std.testing.allocator.free(code);
    return evalOk(code);
}

test "gate: the C JSON codec decodes exactly what the pure reference decodes" {
    try fresh();
    try loadPureReference();

    // Both results are re-encoded through the SAME encoder, so a
    // difference means the DECODERS disagree. Error texts are compared
    // verbatim, because json.ring's raise() messages carry 1-based
    // positions the C codec must reproduce rather than approximate.
    _ = try evalOk("func DiffOne cJson\n" ++
        "  cPerr = \"\"  cCerr = \"\"  cPval = \"\"  cCval = \"\"\n" ++
        "  try  cPval = PureJsonEncode(PureJsonDecode(cJson))  catch  cPerr = cCatchError  done\n" ++
        "  try  cCval = PureJsonEncode(JsonDecode(cJson))      catch  cCerr = cCatchError  done\n" ++
        "  if cPerr != cCerr  return \"ERR P<\" + cPerr + \"> C<\" + cCerr + \">\"  ok\n" ++
        "  if cPval != cCval  return \"VAL P<\" + cPval + \"> C<\" + cCval + \">\"  ok\n" ++
        "  return \"SAME\"");

    // Well-formed values first, then every malformed shape json.ring has
    // an opinion about — including the quirks it TOLERATES (a lone "+"
    // is number 0), which an imitation would be most likely to miss.
    const cases = [_][]const u8{
        "[1.5,{QaQ:QcafeQ},null,true,[0.1,1e-7,-0,9007199254740991]]",
        "QaQ", "{", "{QaQ}", "tru", "[1e999]", "[+]", "[--1]", "[.5]",
        "", "[]", "{}", "[[[[[1]]]]]", "  [ 1 , 2 ]  ", "[1,]", "{QaQ:}",
        "123abc", "-", "[01]", "QunterminatedQQ", "[1 2]", "nul", "[tru]",
    };
    for (cases) |c| {
        const got = try evalQ("see DiffOne(\"{s}\")", .{c});
        if (!std.mem.eql(u8, got, "SAME")) {
            std.debug.print("decoders differ on `{s}`: {s}\n", .{ c, got });
            return error.CodecsDiverge;
        }
    }
}

test "gate: the C JSON codec encodes exactly what the pure reference encodes" {
    try fresh();
    try loadPureReference();

    // Values the decoder never produces: embedded control bytes, deep
    // nesting, and number formatting — which must go through the VM's own
    // decimals() setting rather than any C default.
    // Written as plain Ring expressions — no Q substitution here, because
    // these are bare values rather than text inside a string literal.
    const values = [_][]const u8{
        "[1,2,3]",
        "[ :a = 1, :b = [ :c = [1,2] ] ]",
        // Note: no `1e-7` — that is not a Ring numeric literal (the scanner
        // reads `1e` as a variable). Exponent forms are exercised on the
        // DECODE side, where they arrive as JSON text.
        "[ 0.1, 0.0000001, -0, 1000000, 3.14159 ]",
        "[ char(9) + char(10) + char(13) ]",
        "[ char(0) + char(1) + char(31) ]",
        "[[[[[[[[[[1]]]]]]]]]]",
        "[]",
        "[ \"\" ]",
        "[ \"café\" ]",
        "[ \"a\" + char(34) + \"b\" ]",
        "[ \"back\" + char(92) + \"slash\" ]",
    };
    for (values) |v| {
        const code = try std.fmt.allocPrintSentinel(std.testing.allocator,
            "vX = {s}\nsee JsonEncode(vX) = PureJsonEncode(vX)", .{v}, 0);
        defer std.testing.allocator.free(code);
        const same = try evalOk(code);
        if (!std.mem.eql(u8, same, "1")) {
            const show = try std.fmt.allocPrintSentinel(std.testing.allocator,
                "vX = {s}\nsee JsonEncode(vX) + \" != \" + PureJsonEncode(vX)", .{v}, 0);
            defer std.testing.allocator.free(show);
            std.debug.print("encoders differ on {s}: {s}\n", .{ v, try evalOk(show) });
            return error.EncodersDiverge;
        }
    }
}
