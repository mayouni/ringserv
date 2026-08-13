//! RingServ bridge — resident Ring VM, native. Ported from RingScript's
//! browser bridge (the wasm32-wasi original); the API and the machinery —
//! error trapping with real line numbers, the region terminator, the
//! auto-main pass, the input queue — carry over unchanged. What changed:
//! no JS imports (the host is this process, not a page), the embedded-map
//! file layer falls through to the real filesystem, and output can be
//! echoed live to stdout for CLI use.
//!
//! API (same names as RingScript, same contracts):
//!   rs_init()          -> i32     create the resident RingState once (0 = ok)
//!   rs_reset()         -> i32     destroy + recreate (explicit, never implicit)
//!   rs_eval(code)      -> i32     run code IN the resident state; 0 = ok
//!   rs_call(f, json)   -> ptr     call f(JsonDecode(json)), JSON result
//!   rs_last_output()   -> ptr     accumulated output since last eval
//!   rs_last_error()    -> ptr     "" or "line N: message"
//!   rs_set_input(s)               queue input lines for `give`
//!   rs_set_echo(b)                also stream output to C stdout (CLI mode)

const std = @import("std");

const alloc = std.heap.c_allocator;

pub const RINGSERV_VERSION = "0.1-dev";

pub export fn rs_version() [*:0]const u8 {
    return RINGSERV_VERSION;
}

// ---------------------------------------------------------------- Ring C API

const RingState = opaque {};
const List = opaque {};

extern fn ring_state_init() ?*RingState;
extern fn ring_state_delete(pState: ?*RingState) ?*RingState;
extern fn ring_state_runcode(pState: ?*RingState, cCode: [*:0]const u8) void;
extern fn ring_vm_funcregister2(
    pState: ?*RingState,
    cName: [*:0]const u8,
    pFunc: *const fn (?*anyopaque) callconv(.c) void,
) void;

extern fn ring_vm_api_isstring(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getstring(p: ?*anyopaque, n: c_int) ?[*:0]u8;
extern fn ring_vm_api_getstringsize(p: ?*anyopaque, n: c_int) c_uint;
extern fn ring_vm_api_isnumber(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getnumber(p: ?*anyopaque, n: c_int) f64;
extern fn ring_vm_api_islist(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getlist(p: ?*anyopaque, n: c_int) ?*List;
extern fn ring_vm_api_ispointer(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getpointer(p: ?*anyopaque, n: c_int) ?*anyopaque;
extern fn ring_vm_api_retstring2(p: ?*anyopaque, s: [*]const u8, n: c_uint) void;
extern fn ring_vm_api_retnumber(p: ?*anyopaque, n: f64) void;
extern fn ring_vm_error(pVM: ?*anyopaque, cStr: [*:0]const u8) void;

/// Line number captured at error time by the RINGSCRIPT PATCH in
/// ringvm/src/vmerror.c (catch-time state restore rewinds pVM->nLineNumber,
/// so it cannot be read from the VM once the catch block runs). Thread-local
/// on both sides (RINGSERV extension of the patch): N workers error
/// independently.
extern threadlocal var rs_error_line: c_uint;
extern fn rs_vm_decimals(p: ?*anyopaque) c_uint;
extern fn rs_vm_maincalled(p: ?*anyopaque) c_uint;
extern fn ring_general_numtostring(nNum: f64, cStr: [*]u8, nDecimals: c_int) [*:0]u8;

// Exact-mirror value printers in native_stubs.c.
extern fn rs_print_value_list(p: ?*anyopaque, pList: ?*List) void;
extern fn rs_print_pointer(p: ?*anyopaque, pValue: ?*anyopaque) void;

// C-side stdout writer (native_stubs.c is compiled against real libc stdio,
// so its writes share one FILE* buffer with the VM's own print()/puts —
// interleaving stays in true order).
extern fn rs_echo_write(pData: [*]const u8, nLen: usize) void;

// The object template cache (src/rs_oop.c) borrows pointers into the
// state's class lists and bytecode; both die on reset, so it must too.
extern fn rs_objcache_clear() void;

// ---------------------------------------------------------------- state

threadlocal var g_state: ?*RingState = null;
threadlocal var g_out: std.ArrayList(u8) = .empty;
threadlocal var g_err: std.ArrayList(u8) = .empty;
threadlocal var g_result: std.ArrayList(u8) = .empty;
threadlocal var g_callcode: std.ArrayList(u8) = .empty;
threadlocal var g_arg: []const u8 = "";
threadlocal var g_input: std.ArrayList(u8) = .empty;
threadlocal var g_input_pos: usize = 0;
threadlocal var g_evalcode: std.ArrayList(u8) = .empty;
threadlocal var g_eval_counter: u64 = 0;
/// Sticky: once any eval renames keywords, `class` may no longer be spelled
/// "class", so every later eval gets a terminator regardless of its text.
threadlocal var g_keywords_changed: bool = false;
/// Re-entry guard — same contract as RingScript's (see that bridge for the
/// full story): entering the VM while it runs would corrupt the buffers of
/// the outer run, so it is refused before anything is cleared.
threadlocal var g_running: u32 = 0;
threadlocal var g_main_called: bool = false;
/// CLI mode: stream output to stdout as it is produced.
threadlocal var g_echo: bool = false;
/// Transport status for the current dispatch — servlib sets it through
/// the __rs_status hook (404 unknown, 400 malformed, 422 contract, 500
/// trapped); the HTTP core reads it after rs_call. Business status lives
/// in the envelope, never here.
threadlocal var g_http_status: u16 = 200;

pub export fn rs_busy() u32 {
    return g_running;
}

pub export fn rs_end_run() void {
    g_running = 0;
}

pub export fn rs_set_echo(on: u32) void {
    g_echo = on != 0;
}

fn appendOut(bytes: []const u8) void {
    g_out.appendSlice(alloc, bytes) catch {};
    if (g_echo) rs_echo_write(bytes.ptr, bytes.len);
}

/// Format a number exactly like native `see`: through the VM's own
/// ring_general_numtostring with the state's live decimals() setting.
fn appendNumber(p: ?*anyopaque, n: f64) void {
    var buf: [160]u8 = undefined; // RING_MEDIUMBUF is 128
    const s = ring_general_numtostring(n, &buf, @intCast(rs_vm_decimals(p)));
    appendOut(std.mem.span(s));
}

/// C hook the VM calls for every `see` (wired to the Ring-level
/// `ringvm_see` override in rs_init).
fn seeHook(p: ?*anyopaque) callconv(.c) void {
    if (ring_vm_api_isstring(p, 1) != 0) {
        if (ring_vm_api_getstring(p, 1)) |s| {
            const len: usize = @intCast(ring_vm_api_getstringsize(p, 1));
            appendOut(s[0..len]);
        }
    } else if (ring_vm_api_isnumber(p, 1) != 0) {
        appendNumber(p, ring_vm_api_getnumber(p, 1));
    } else if (ring_vm_api_islist(p, 1) != 0) {
        rs_print_value_list(p, ring_vm_api_getlist(p, 1));
    } else if (ring_vm_api_ispointer(p, 1) != 0) {
        rs_print_pointer(p, ring_vm_api_getpointer(p, 1));
    }
}

/// The code passed to the current rs_eval, valid for its duration; the eval
/// shim pulls it through the rs_getcode hook so no string escaping exists
/// anywhere in the pipeline.
threadlocal var g_code: []const u8 = "";

fn getCodeHook(p: ?*anyopaque) callconv(.c) void {
    ring_vm_api_retstring2(p, g_code.ptr, @intCast(g_code.len));
}

/// C hook: the catch block reports the trapped error here. The line comes
/// from the vendor patch in vmerror.c — captured when the error fired.
fn reportErrorHook(p: ?*anyopaque) callconv(.c) void {
    g_err.clearRetainingCapacity();
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "line {d}: ", .{rs_error_line}) catch "line ?: ";
    g_err.appendSlice(alloc, line) catch {};
    if (ring_vm_api_isstring(p, 1) != 0) {
        if (ring_vm_api_getstring(p, 1)) |s| {
            const len: usize = @intCast(ring_vm_api_getstringsize(p, 1));
            g_err.appendSlice(alloc, s[0..len]) catch {};
        }
    }
}

// ------------------------------------------------------------ embedded files
//
// The pure-Ring payload baked into the binary. Unlike the browser bridge,
// this map is a FIRST resolver, not the only one: rs_fopen/rs_stat in
// native_stubs.c try it and then fall through to the real filesystem.

const EmbeddedFile = struct { name: []const u8, data: []const u8 };

const embedded_files = [_]EmbeddedFile{
    .{ .name = "ringlib/json.ring", .data = @embedFile("ringlib/json.ring") },
    .{ .name = "ringlib/serv.ring", .data = @embedFile("ringlib/serv.ring") },
};

fn baseName(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.lastIndexOfAny(u8, p, "/\\")) |i| p = p[i + 1 ..];
    return p;
}

/// Resolve a path against the embedded map: exact (case-insensitive) match
/// first, then suffix match, then basename match. Called from the fopen
/// override in native_stubs.c; a null return means "use the real fs".
pub export fn rs_find_embedded(path: [*:0]const u8, out_len: *usize) ?[*]const u8 {
    var p = std.mem.span(path);
    while (p.len > 0 and (p[0] == '/' or p[0] == '\\')) p = p[1..];
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    for (embedded_files) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, p)) {
            out_len.* = e.data.len;
            return e.data.ptr;
        }
    }
    for (embedded_files) |e| {
        if (p.len > e.name.len and std.ascii.eqlIgnoreCase(p[p.len - e.name.len ..], e.name)) {
            out_len.* = e.data.len;
            return e.data.ptr;
        }
    }
    const base = baseName(p);
    for (embedded_files) |e| {
        if (std.ascii.eqlIgnoreCase(baseName(e.name), base)) {
            out_len.* = e.data.len;
            return e.data.ptr;
        }
    }
    return null;
}

/// C hook: return the pending rs_call JSON argument to Ring.
fn getArgHook(p: ?*anyopaque) callconv(.c) void {
    ring_vm_api_retstring2(p, g_arg.ptr, @intCast(g_arg.len));
}

/// C hook: the rs_call wrapper stores the encoded result here.
fn setResultHook(p: ?*anyopaque) callconv(.c) void {
    g_result.clearRetainingCapacity();
    if (ring_vm_api_isstring(p, 1) != 0) {
        if (ring_vm_api_getstring(p, 1)) |s| {
            const len: usize = @intCast(ring_vm_api_getstringsize(p, 1));
            g_result.appendSlice(alloc, s[0..len]) catch {};
        }
    }
}

/// Live-input handler — the native mirror of RingScript's js_give import.
/// Set by the host (the CLI wires stdin here, lazily: nothing is read until
/// a `give` actually runs dry). Returns one line without its newline, or
/// null when the source is exhausted; `echo` says whether the bridge should
/// echo the line into the output (a terminal already shows typed input; a
/// pipe does not).
pub const LiveGive = struct {
    read_line: *const fn () ?[]const u8,
    echo: bool,
};
pub threadlocal var live_give: ?LiveGive = null;

/// C hook registered AS "ringvm_give": hand the next queued input line to
/// Ring's give, echoing it the way a terminal would; when the queue runs
/// dry, ask the live handler (interactive programs stay interactive); when
/// there is none — or it is exhausted — raise a clean Ring error (a `give`
/// returning "" silently could spin interactive loops forever).
///
/// Deliberately a C hook, not a Ring-level override — a Ring-level
/// ringvm_give corrupts later attribute-only class regions (reproduced on
/// native Ring 1.27).
fn giveHook(p: ?*anyopaque) callconv(.c) void {
    const buf = g_input.items;
    if (g_input_pos >= buf.len) {
        if (live_give) |lg| {
            if (lg.read_line()) |line| {
                if (lg.echo) {
                    appendOut(line);
                    appendOut("\n");
                }
                ring_vm_api_retstring2(p, line.ptr, @intCast(line.len));
                return;
            }
        }
        ring_vm_error(p, "Give needs input but the input is exhausted");
        return;
    }
    var end = g_input_pos;
    while (end < buf.len and buf[end] != '\n') end += 1;
    var line = buf[g_input_pos..end];
    g_input_pos = if (end < buf.len) end + 1 else buf.len;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    appendOut(line);
    appendOut("\n");
    ring_vm_api_retstring2(p, line.ptr, @intCast(line.len));
}

/// C hook: servlib's __rs_status(n) — transport status for this dispatch.
fn httpStatusHook(p: ?*anyopaque) callconv(.c) void {
    if (ring_vm_api_isnumber(p, 1) != 0) {
        const n = ring_vm_api_getnumber(p, 1);
        if (n >= 100 and n <= 599) g_http_status = @intFromFloat(n);
    }
}

/// Transport status set by the last rs_call's dispatch (200 when untouched).
pub export fn rs_last_status() u16 {
    return g_http_status;
}

/// C hook for the auto-main pass — see RingScript's bridge for the story.
fn mainFoundHook(p: ?*anyopaque) callconv(.c) void {
    if (g_main_called or rs_vm_maincalled(p) != 0) {
        g_main_called = true;
        ring_vm_api_retnumber(p, 1);
        return;
    }
    g_main_called = true;
    ring_vm_api_retnumber(p, 0);
}

const see_shim = "func ringvm_see cData ring_vm_see(cData)";
/// The pure-Ring JSON codec — the reference implementation RingScript's C
/// codec is held byte-identical to. Run straight from the embedded source
/// at init (no file layer involved); the embedded map above additionally
/// serves `load "ringlib/json.ring"` from user code.
const json_ring_src = @embedFile("ringlib/json.ring");
/// servlib — the service model (Serv, __dispatch, Reply), pure Ring.
const serv_ring_src = @embedFile("ringlib/serv.ring");

/// Every eval runs through this wrapper: errors land in rs_reporterror and
/// the resident state survives. Line numbers are real thanks to the two
/// marked vendor patches (vmeval.c, vmerror.c).
const eval_shim = "try eval(rs_getcode()) catch rs_reporterror(cCatchError) done";

// ---------------------------------------------------------------- exports

pub export fn rs_init() i32 {
    if (g_state != null) return 0;
    const st = ring_state_init() orelse return -1;
    ring_vm_funcregister2(st, "ring_vm_see", &seeHook);
    ring_vm_funcregister2(st, "rs_getcode", &getCodeHook);
    ring_vm_funcregister2(st, "rs_reporterror", &reportErrorHook);
    ring_vm_funcregister2(st, "rs_getarg", &getArgHook);
    ring_vm_funcregister2(st, "rs_setresult", &setResultHook);
    ring_vm_funcregister2(st, "ringvm_give", &giveHook);
    ring_vm_funcregister2(st, "rs_notemain", &mainFoundHook);
    ring_vm_funcregister2(st, "__rs_status", &httpStatusHook);
    ring_state_runcode(st, see_shim);
    ring_state_runcode(st, json_ring_src);
    ring_state_runcode(st, serv_ring_src);
    g_state = st;
    return 0;
}

pub export fn rs_reset() i32 {
    if (g_running != 0) return -3;
    rs_objcache_clear();
    if (g_state) |st| {
        _ = ring_state_delete(st);
        g_state = null;
    }
    g_main_called = false;
    return rs_init();
}

/// Auto-main pass: if the eval defined main() and it never ran, call it —
/// matching native Ring's end-of-program behavior, unreachable via eval.
const call_main_shim = "if isfunction(\"main\") and rs_notemain() = 0 main() ok";

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when `kw` appears in `src` as a whole word — Ring keywords are whole
/// tokens, and a plain substring test would fire on `classify`, `default`…
fn hasKeyword(src: []const u8, kw: []const u8) bool {
    var from: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(src, from, kw)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(src[pos - 1]);
        const end = pos + kw.len;
        const after_ok = end >= src.len or !isIdentChar(src[end]);
        if (before_ok and after_ok) return true;
        from = pos + 1;
    }
    return false;
}

pub export fn rs_eval(code: [*:0]const u8) i32 {
    if (g_running != 0) return -3;
    if (g_state == null and rs_init() != 0) return -1;
    g_running += 1;
    defer g_running -= 1;
    g_out.clearRetainingCapacity();
    g_err.clearRetainingCapacity();

    // Region terminator — the full reasoning lives in RingScript's bridge
    // (docs/architecture.md §2 there): a uniquely-named, never-instantiated
    // class appended ONLY when the source could open a declaration region,
    // so attribute-only classes at end-of-eval close correctly and the class
    // list does not grow on declaration-free evals.
    const src = std.mem.span(code);
    if (hasKeyword(src, "changeringkeyword")) g_keywords_changed = true;
    const needs_terminator = g_keywords_changed or
        hasKeyword(src, "class") or
        hasKeyword(src, "func") or
        hasKeyword(src, "def") or
        hasKeyword(src, "package");

    g_evalcode.clearRetainingCapacity();
    g_evalcode.appendSlice(alloc, src) catch return -1;
    if (needs_terminator) {
        g_eval_counter += 1;
        var buf: [48]u8 = undefined;
        const term = std.fmt.bufPrint(&buf, "\nclass __rs_end_{d}", .{g_eval_counter}) catch return -1;
        g_evalcode.appendSlice(alloc, term) catch return -1;
    }

    // Auto-main is only attempted when this source could have defined main —
    // the shim costs a full compile of itself on every eval otherwise.
    const could_define_main = hasKeyword(src, "main") or hasKeyword(src, "eval");

    g_code = g_evalcode.items;
    defer g_code = "";
    ring_state_runcode(g_state, eval_shim);
    if (g_err.items.len != 0) return 1;

    if (!g_main_called and could_define_main) {
        g_code = call_main_shim;
        ring_state_runcode(g_state, eval_shim);
        if (g_err.items.len != 0) return 1;
    }
    return 0;
}

/// Call a Ring function with one JSON argument; returns its result as a
/// NUL-terminated JSON string ("" + rs_last_error set on failure).
pub export fn rs_call(fname: [*:0]const u8, json: [*:0]const u8) [*:0]const u8 {
    if (g_running != 0) return "";
    if (g_state == null and rs_init() != 0) return "";
    g_running += 1;
    defer g_running -= 1;
    g_out.clearRetainingCapacity();
    g_err.clearRetainingCapacity();
    g_result.clearRetainingCapacity();
    g_http_status = 200;

    const name = std.mem.span(fname);
    if (name.len == 0) {
        g_err.appendSlice(alloc, "rs_call: empty function name") catch {};
        return "";
    }
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            g_err.appendSlice(alloc, "rs_call: invalid function name") catch {};
            return "";
        }
    }

    g_arg = std.mem.span(json);
    defer g_arg = "";
    g_callcode.clearRetainingCapacity();
    g_callcode.appendSlice(alloc, "rs_setresult(JsonEncode(") catch return "";
    g_callcode.appendSlice(alloc, name) catch return "";
    g_callcode.appendSlice(alloc, "(JsonDecode(rs_getarg()))))") catch return "";
    g_code = g_callcode.items;
    defer g_code = "";
    ring_state_runcode(g_state, eval_shim);
    if (g_err.items.len != 0) return "";

    g_result.append(alloc, 0) catch return "";
    defer _ = g_result.pop();
    return @ptrCast(g_result.items.ptr);
}

pub export fn rs_last_output() [*:0]const u8 {
    g_out.append(alloc, 0) catch return "";
    defer _ = g_out.pop();
    return @ptrCast(g_out.items.ptr);
}

/// Byte length of the last output — Ring strings may contain NUL bytes.
pub export fn rs_last_output_size() usize {
    return g_out.items.len;
}

pub export fn rs_last_error() [*:0]const u8 {
    g_err.append(alloc, 0) catch return "";
    defer _ = g_err.pop();
    return @ptrCast(g_err.items.ptr);
}

/// Queue input for `give`: the whole text, split into lines as `give`
/// consumes it. Replaces any previous queue. Pass "" to clear.
pub export fn rs_set_input(text: [*:0]const u8) void {
    g_input.clearRetainingCapacity();
    g_input.appendSlice(alloc, std.mem.span(text)) catch {};
    g_input_pos = 0;
}

/// Append raw bytes to the eval output buffer (called by the C printers).
pub export fn rs_append_output(ptr: [*]const u8, len: usize) void {
    appendOut(ptr[0..len]);
}
