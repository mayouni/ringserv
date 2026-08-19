//! js.zig — the second guest: a resident QuickJS runtime per worker.
//!
//! Same shape as bridge.zig, on purpose. A worker owns one JS runtime and
//! one context for its whole life, threadlocal like the RingState beside
//! it, and the entry points mirror the Ring ones name for name:
//!
//!   js_init()          create this worker's runtime (0 = ok)
//!   js_eval(code)      evaluate in it; 0 = ok
//!   js_call(f, json)   call f(JSON.parse(json)) and JSON-encode the result
//!   js_last_error()    "" or "line N: message"
//!   js_reset()         destroy + recreate, explicitly
//!
//! Two guests, one dispatcher: servlib decides *which* guest answers a
//! service, and everything else about a request — the envelope, the
//! contract, the placement — is identical either way. A programmer who
//! moves a service from Ring to JS should have to change the service and
//! nothing around it.

const std = @import("std");

const alloc = std.heap.c_allocator;

const c = @cImport({
    @cInclude("quickjs.h");
});

/// QuickJS expresses its sentinel values as macros over `JS_MKVAL`, which
/// builds a JSValue by initialising a union — and Zig's translate-c
/// refuses that at comptime. `src/rs_js.c` re-exports them as real
/// functions; see that file for why a shim beats open-coding a vendor's
/// internal representation in Zig.
extern fn rs_js_undefined() c.JSValue;
extern fn rs_js_null() c.JSValue;
extern fn rs_js_dup_value(ctx: *c.JSContext, v: c.JSValue) c.JSValue;

/// This worker's runtime and context. Created once, destroyed only by an
/// explicit reset — a worker lives as long as the process.
threadlocal var g_rt: ?*c.JSRuntime = null;
threadlocal var g_ctx: ?*c.JSContext = null;
threadlocal var g_err: std.ArrayList(u8) = .empty;
threadlocal var g_result: std.ArrayList(u8) = .empty;
threadlocal var g_out: std.ArrayList(u8) = .empty;

/// CLI mode: stream `console.log` to stdout as it is produced, the way
/// the Ring side streams `see`.
threadlocal var g_echo: bool = false;

extern fn rs_echo_write(pData: [*]const u8, nLen: usize) void;

pub export fn js_set_echo(on: u32) void {
    g_echo = on != 0;
}

fn appendOut(bytes: []const u8) void {
    g_out.appendSlice(alloc, bytes) catch {};
    if (g_echo) rs_echo_write(bytes.ptr, bytes.len);
}

// ------------------------------------------------------------- errors

fn setError(comptime fmt: []const u8, args: anytype) void {
    g_err.clearRetainingCapacity();
    g_err.writer(alloc).print(fmt, args) catch {};
}

/// Turn a pending JS exception into the same "line N: message" shape the
/// Ring bridge produces, so a caller handling one handles both.
fn captureException(ctx: *c.JSContext) void {
    const exc = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exc);

    var line: i32 = 0;
    var message: []const u8 = "";
    var owned_msg: ?[*:0]const u8 = null;
    var owned_stack: ?[*:0]const u8 = null;

    if (c.JS_IsError(exc)) {
        const msg_v = c.JS_GetPropertyStr(ctx, exc, "message");
        defer c.JS_FreeValue(ctx, msg_v);
        if (c.JS_ToCString(ctx, msg_v)) |s| {
            owned_msg = s;
            message = std.mem.span(s);
        }
        // The line number lives in the stack string's first frame, which
        // is the only place QuickJS exposes it without a debugger API.
        const stack_v = c.JS_GetPropertyStr(ctx, exc, "stack");
        defer c.JS_FreeValue(ctx, stack_v);
        if (!(c.JS_IsUndefined(stack_v))) {
            if (c.JS_ToCString(ctx, stack_v)) |s| {
                owned_stack = s;
                line = lineFromStack(std.mem.span(s));
            }
        }
    } else {
        if (c.JS_ToCString(ctx, exc)) |s| {
            owned_msg = s;
            message = std.mem.span(s);
        }
    }
    defer if (owned_msg) |s| c.JS_FreeCString(ctx, s);
    defer if (owned_stack) |s| c.JS_FreeCString(ctx, s);

    if (line > 0) {
        setError("line {d}: {s}", .{ line, message });
    } else {
        setError("{s}", .{message});
    }
}

/// `    at <fn> (file.js:12:5)` → 12. Returns 0 when the frame carries no
/// position, which happens for exceptions raised inside native code.
fn lineFromStack(stack: []const u8) i32 {
    const first = std.mem.sliceTo(stack, '\n');
    var i = first.len;
    // Walk back over ":col)" to find the line number before it.
    var seen_colon: usize = 0;
    var end: usize = 0;
    while (i > 0) : (i -= 1) {
        const ch = first[i - 1];
        if (ch == ':') {
            seen_colon += 1;
            if (seen_colon == 1) {
                // everything after this colon is the column
                continue;
            }
            const num = first[i..end];
            return std.fmt.parseInt(i32, num, 10) catch 0;
        }
        if (seen_colon == 1 and end == 0) end = i;
    }
    return 0;
}

pub export fn js_last_error() [*:0]const u8 {
    g_err.append(alloc, 0) catch return "";
    defer _ = g_err.pop();
    return @ptrCast(g_err.items.ptr);
}

pub export fn js_last_output() [*:0]const u8 {
    g_out.append(alloc, 0) catch return "";
    defer _ = g_out.pop();
    return @ptrCast(g_out.items.ptr);
}

// ------------------------------------------------------------ lifetime

pub export fn js_init() i32 {
    if (g_ctx != null) return 0;
    const rt = c.JS_NewRuntime() orelse {
        setError("cannot create a JS runtime", .{});
        return 1;
    };
    // A guest must not be able to hang or exhaust a worker: both limits
    // are the server's, not the application's.
    c.JS_SetMemoryLimit(rt, 128 * 1024 * 1024);
    c.JS_SetMaxStackSize(rt, 4 * 1024 * 1024);

    const ctx = c.JS_NewContext(rt) orelse {
        c.JS_FreeRuntime(rt);
        setError("cannot create a JS context", .{});
        return 1;
    };
    g_rt = rt;
    g_ctx = ctx;
    if (installHost(ctx) != 0) {
        setError("cannot install the host surface", .{});
        return 1;
    }
    return 0;
}

pub export fn js_reset() i32 {
    if (g_ctx) |ctx| c.JS_FreeContext(ctx);
    if (g_rt) |rt| c.JS_FreeRuntime(rt);
    g_ctx = null;
    g_rt = null;
    g_err.clearRetainingCapacity();
    g_out.clearRetainingCapacity();
    return js_init();
}

/// True once this worker has a live JS context — so a server with no JS
/// services never pays for one.
pub export fn js_ready() u32 {
    return if (g_ctx != null) 1 else 0;
}

// ------------------------------------------------------------ evaluate

pub export fn js_eval(code: [*:0]const u8) i32 {
    const ctx = g_ctx orelse {
        setError("no JS context (js_init first)", .{});
        return 1;
    };
    g_err.clearRetainingCapacity();
    const src = std.mem.span(code);
    const val = c.JS_Eval(ctx, src.ptr, src.len, "app.js", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) {
        captureException(ctx);
        return 1;
    }
    drainJobs(ctx);
    return 0;
}

/// Run whatever promises the guest left pending. Without this a service
/// that awaits anything would answer before its own work finished — the
/// kind of bug that only appears under load.
fn drainJobs(ctx: *c.JSContext) void {
    const rt = c.JS_GetRuntime(ctx);
    var guard: u32 = 0;
    while (guard < 10_000) : (guard += 1) {
        var pctx: ?*c.JSContext = null;
        const rc = c.JS_ExecutePendingJob(rt, &pctx);
        // No promise job left, but a timer may still be owed one — and a
        // timer callback can queue further promises, which is why this
        // loops rather than draining each once.
        if (rc == 0 and runTimers(ctx)) continue;
        if (rc <= 0) {
            if (rc < 0 and pctx != null) captureException(pctx.?);
            return;
        }
    }
}

// ---------------------------------------------------------------- call

/// Resolve a returned value to the thing worth encoding.
///
/// A plain value is itself. A promise is its fulfilment — and a REJECTED
/// promise becomes the error, because `async function f() { throw }` must
/// fail exactly like `function f() { throw }`. Anything else would make
/// "may I write this service as async?" a question with consequences,
/// when the whole point is that it is not one.
///
/// Returns a value the caller owns, or null with the error already set.
fn settle(ctx: *c.JSContext, v: c.JSValue) ?c.JSValue {
    switch (c.JS_PromiseState(ctx, v)) {
        c.JS_PROMISE_NOT_A_PROMISE => return rs_js_dup_value(ctx, v),
        c.JS_PROMISE_FULFILLED => return c.JS_PromiseResult(ctx, v),
        c.JS_PROMISE_REJECTED => {
            const reason = c.JS_PromiseResult(ctx, v);
            defer c.JS_FreeValue(ctx, reason);
            _ = c.JS_Throw(ctx, rs_js_dup_value(ctx, reason));
            captureException(ctx);
            return null;
        },
        else => {
            // Still pending after every queued job ran: nothing left in
            // this host will ever resolve it.
            setError("the service returned a promise that never settled — " ++
                "it is awaiting something this host does not provide", .{});
            return null;
        },
    }
}

/// Call a global function with one JSON argument, and JSON-encode what it
/// returns. Exactly `rs_call`'s contract, so the dispatcher does not have
/// to know which guest it is talking to.
pub export fn js_call(name: [*:0]const u8, json_arg: [*:0]const u8) [*:0]const u8 {
    g_result.clearRetainingCapacity();
    g_err.clearRetainingCapacity();

    const ctx = g_ctx orelse {
        setError("no JS context (js_init first)", .{});
        return "";
    };

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    const fn_val = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, fn_val);
    if (!c.JS_IsFunction(ctx, fn_val)) {
        setError("no JS function named {s}", .{name});
        return "";
    }

    const arg_src = std.mem.span(json_arg);
    var arg = c.JS_ParseJSON(ctx, arg_src.ptr, arg_src.len, "<arg>");
    if (c.JS_IsException(arg)) {
        captureException(ctx);
        c.JS_FreeValue(ctx, arg);
        return "";
    }
    defer c.JS_FreeValue(ctx, arg);

    const ret = c.JS_Call(ctx, fn_val, global, 1, @ptrCast(&arg));
    defer c.JS_FreeValue(ctx, ret);
    if (c.JS_IsException(ret)) {
        captureException(ctx);
        return "";
    }
    drainJobs(ctx);
    if (g_err.items.len != 0) return "";

    // An `async function` returns a PROMISE, and JSON-encoding a promise
    // yields `{}` — a service that answered correctly and reported
    // nothing. Settle it here instead: the jobs are drained above, so a
    // promise that is still pending after that is genuinely waiting on
    // something this host does not provide, which is a service bug and
    // is reported as one rather than silently becoming `{}`.
    const settled = settle(ctx, ret) orelse return "";
    defer c.JS_FreeValue(ctx, settled);

    const encoded = c.JS_JSONStringify(ctx, settled, rs_js_undefined(), rs_js_undefined());
    defer c.JS_FreeValue(ctx, encoded);
    if (c.JS_IsException(encoded)) {
        captureException(ctx);
        return "";
    }
    if (c.JS_ToCString(ctx, encoded)) |s| {
        defer c.JS_FreeCString(ctx, s);
        g_result.appendSlice(alloc, std.mem.span(s)) catch {};
    }
    g_result.append(alloc, 0) catch return "";
    defer _ = g_result.pop();
    return @ptrCast(g_result.items.ptr);
}

/// True when the guest defines a global function of this name — the JS
/// twin of the Ring side's `probeFunction`, and how the dispatcher learns
/// which guest owns a service.
pub export fn js_has_function(name: [*:0]const u8) u32 {
    const ctx = g_ctx orelse return 0;
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    return if (c.JS_IsFunction(ctx, v)) 1 else 0;
}

// -------------------------------------------------------- host surface

/// `console.log(...)` — the one host function phase 7 installs directly.
/// The rest of the ECMA-429 surface arrives in the next step; this exists
/// now because a guest you cannot print from is a guest you cannot debug.
fn hostConsoleLog(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) appendOut(" ");
        if (c.JS_ToCString(ctx, argv[@intCast(i)])) |s| {
            defer c.JS_FreeCString(ctx, s);
            appendOut(std.mem.span(s));
        }
    }
    appendOut("\n");
    return rs_js_undefined();
}

fn installHost(ctx: *c.JSContext) i32 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    const console = c.JS_NewObject(ctx);
    const log = c.JS_NewCFunction(ctx, hostConsoleLog, "log", 1);
    _ = c.JS_SetPropertyStr(ctx, console, "log", log);
    // info/warn/error all land in the same place: a server's stdout is
    // one stream, and pretending otherwise invents levels the host does
    // not actually route differently.
    _ = c.JS_SetPropertyStr(ctx, console, "info", c.JS_DupValue(ctx, log));
    _ = c.JS_SetPropertyStr(ctx, console, "warn", c.JS_DupValue(ctx, log));
    _ = c.JS_SetPropertyStr(ctx, console, "error", c.JS_DupValue(ctx, log));
    _ = c.JS_SetPropertyStr(ctx, global, "console", console);

    // The one door out of the guest. Narrow on purpose — see the host
    // surface section below for what that buys and how it is kept true.
    const host = c.JS_NewObject(ctx);
    installOne(ctx, host, "utf8Encode", hostUtf8Encode, 1);
    installOne(ctx, host, "utf8Decode", hostUtf8Decode, 1);
    installOne(ctx, host, "b64Encode", hostB64Encode, 1);
    installOne(ctx, host, "b64Decode", hostB64Decode, 1);
    installOne(ctx, host, "randomBytes", hostRandomBytes, 1);
    installOne(ctx, host, "nowMs", hostNowMs, 0);
    installOne(ctx, host, "setTimeout", hostSetTimeout, 2);
    installOne(ctx, host, "clearTimeout", hostClearTimeout, 1);
    installOne(ctx, host, "servCall", hostServCall, 3);
    _ = c.JS_SetPropertyStr(ctx, global, "__host", host);

    // The platform surface itself, written once in ringlib/prelude.js and
    // evaluated into every context. A failure here is a build defect, not
    // an application error, so it is reported as loudly as one.
    const pv = c.JS_Eval(ctx, prelude_src, prelude_src.len, "prelude.js", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, pv);
    if (c.JS_IsException(pv)) {
        captureException(ctx);
        return 1;
    }
    return 0;
}

// ------------------------------------------------------------- services
//
// A JS service is a file that assigns a `service` object:
//
//     const service = {
//         greet(p) { return { code: 0, message: "OK", data: {...} }; },
//     };
//
// Its methods are the actions; anything else in the file is private.
// That is the JS analogue of the Ring class form's Action suffix, and it
// gives privacy for free rather than by naming convention.
//
// Each file is evaluated INSIDE A FUNCTION rather than at global scope,
// so two services can both declare `service` — and a helper named `fmt`
// in one cannot be reached, or clobbered, by the other. What they DO
// share is the host surface, which is the point of one guest per worker.

/// Evaluate a service file and register what it exported.
///
/// The SOURCE arrives from the Ring side, never a path: the guest has no
/// filesystem and this is the seam that keeps that true. Ring already
/// knows where the application lives, so resolution belongs there.
pub export fn js_load_service(name: [*:0]const u8, source: [*:0]const u8) i32 {
    const ctx = g_ctx orelse {
        setError("no JS context (js_init first)", .{});
        return 1;
    };
    g_err.clearRetainingCapacity();

    const sname = std.mem.span(name);
    const src = std.mem.span(source);

    // The wrapper: run the file as a function body and hand back whatever
    // `service` it bound. `typeof` rather than a bare reference, so a file
    // that forgot to declare one gets a clean diagnostic instead of a
    // ReferenceError from somewhere inside the wrapper.
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(alloc);
    wrapped.appendSlice(alloc, "globalThis.__rs_services = globalThis.__rs_services || {};") catch return 1;
    wrapped.appendSlice(alloc, "globalThis.__rs_services[") catch return 1;
    appendJsString(&wrapped, sname);
    wrapped.appendSlice(alloc, "] = (function(){\n") catch return 1;
    wrapped.appendSlice(alloc, src) catch return 1;
    wrapped.appendSlice(alloc, "\n;return typeof service !== 'undefined' ? service : null;})();") catch return 1;
    wrapped.append(alloc, 0) catch return 1;

    const z: [*:0]const u8 = @ptrCast(wrapped.items.ptr);
    const val = c.JS_Eval(ctx, z, wrapped.items.len - 1, name, c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, val);
    if (c.JS_IsException(val)) {
        captureException(ctx);
        return 1;
    }
    drainJobs(ctx);

    if (serviceObject(ctx, sname)) |obj| {
        c.JS_FreeValue(ctx, obj);
        return 0;
    }
    setError("{s} declares no `service` object — a JS service is a file that " ++
        "assigns `const service = {{ action(payload) {{ … }} }}`", .{sname});
    return 1;
}

/// The registered service object, or null. Caller owns the value.
fn serviceObject(ctx: *c.JSContext, name: []const u8) ?c.JSValue {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const reg = c.JS_GetPropertyStr(ctx, global, "__rs_services");
    defer c.JS_FreeValue(ctx, reg);
    if (c.JS_IsUndefined(reg)) return null;

    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return null;
    const obj = c.JS_GetPropertyStr(ctx, reg, key);
    if (c.JS_IsUndefined(obj) or c.JS_IsNull(obj)) {
        c.JS_FreeValue(ctx, obj);
        return null;
    }
    return obj;
}

/// True when a loaded service answers this action.
pub export fn js_service_has(name: [*:0]const u8, action: [*:0]const u8) u32 {
    const ctx = g_ctx orelse return 0;
    const obj = serviceObject(ctx, std.mem.span(name)) orelse return 0;
    defer c.JS_FreeValue(ctx, obj);
    const m = c.JS_GetPropertyStr(ctx, obj, action);
    defer c.JS_FreeValue(ctx, m);
    return if (c.JS_IsFunction(ctx, m)) 1 else 0;
}

/// The action names a loaded service answers, as a JSON array — so the
/// catalog that `check` and `docs` read is computed from the guest rather
/// than reconstructed from the file. Same principle as the Ring side:
/// runtime truth stays with the runtime.
pub export fn js_service_actions(name: [*:0]const u8) [*:0]const u8 {
    g_result.clearRetainingCapacity();
    const ctx = g_ctx orelse return "[]";
    const obj = serviceObject(ctx, std.mem.span(name)) orelse return "[]";
    defer c.JS_FreeValue(ctx, obj);

    const expr = "(function(o){return Object.keys(o).filter(function(k){return typeof o[k]==='function'})})";
    const keys = c.JS_Eval(ctx, expr, expr.len, "<actions>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, keys);
    if (c.JS_IsException(keys)) {
        captureException(ctx);
        return "[]";
    }
    var arg = rs_js_dup_value(ctx, obj);
    const list = c.JS_Call(ctx, keys, rs_js_undefined(), 1, @ptrCast(&arg));
    c.JS_FreeValue(ctx, arg);
    defer c.JS_FreeValue(ctx, list);
    if (c.JS_IsException(list)) {
        captureException(ctx);
        return "[]";
    }
    const encoded = c.JS_JSONStringify(ctx, list, rs_js_undefined(), rs_js_undefined());
    defer c.JS_FreeValue(ctx, encoded);
    if (c.JS_ToCString(ctx, encoded)) |s| {
        defer c.JS_FreeCString(ctx, s);
        g_result.appendSlice(alloc, std.mem.span(s)) catch {};
    }
    g_result.append(alloc, 0) catch return "[]";
    defer _ = g_result.pop();
    return @ptrCast(g_result.items.ptr);
}

/// Call `service.action(payload)` and JSON-encode the reply.
///
/// The same contract as `js_call` — including promise settling, so an
/// action may be `async` without anything upstream noticing.
pub export fn js_service_call(
    name: [*:0]const u8,
    action: [*:0]const u8,
    json_arg: [*:0]const u8,
) [*:0]const u8 {
    g_result.clearRetainingCapacity();
    g_err.clearRetainingCapacity();

    const ctx = g_ctx orelse {
        setError("no JS context (js_init first)", .{});
        return "";
    };
    const obj = serviceObject(ctx, std.mem.span(name)) orelse {
        setError("no JS service named {s}", .{name});
        return "";
    };
    defer c.JS_FreeValue(ctx, obj);

    const fn_val = c.JS_GetPropertyStr(ctx, obj, action);
    defer c.JS_FreeValue(ctx, fn_val);
    if (!c.JS_IsFunction(ctx, fn_val)) {
        setError("JS service {s} does not answer {s}", .{ name, action });
        return "";
    }

    const arg_src = std.mem.span(json_arg);
    var arg = c.JS_ParseJSON(ctx, arg_src.ptr, arg_src.len, "<payload>");
    if (c.JS_IsException(arg)) {
        captureException(ctx);
        c.JS_FreeValue(ctx, arg);
        return "";
    }
    defer c.JS_FreeValue(ctx, arg);

    // The frame is opened BEFORE the action runs, because `serv.call`
    // happens DURING it: a frame pushed afterwards would not exist at the
    // moment the guest needs somewhere to queue its request. It is closed
    // again below if the action turns out to be synchronous.
    g_frames.append(alloc, .{ .promise = rs_js_undefined() }) catch {
        setError("out of memory opening a service frame", .{});
        return "";
    };

    // `this` is the service object, so an action may call a sibling as
    // `this.other(...)` — the same reach a Ring class-form service has.
    const ret = c.JS_Call(ctx, fn_val, obj, 1, @ptrCast(&arg));
    defer c.JS_FreeValue(ctx, ret);
    if (c.JS_IsException(ret)) {
        clearAwaited(ctx);
        captureException(ctx);
        return "";
    }
    drainJobs(ctx);
    if (g_err.items.len != 0) {
        clearAwaited(ctx);
        return "";
    }

    // A plain value is done here, and its frame closes with it. A promise
    // goes through the trampoline, because it may be waiting on a
    // `serv.call` that only Ring can perform.
    if (c.JS_PromiseState(ctx, ret) == c.JS_PROMISE_NOT_A_PROMISE) {
        clearAwaited(ctx);
        return encodeValue(ctx, ret);
    }
    if (topFrame()) |frame| {
        c.JS_FreeValue(ctx, frame.promise);
        frame.promise = rs_js_dup_value(ctx, ret);
    }
    return finishAwaited(ctx);
}

/// A JS string literal, for building the wrapper safely. The service name
/// is validated upstream, but a codec that only works on trusted input is
/// a codec waiting for untrusted input.
fn appendJsString(out: *std.ArrayList(u8), s: []const u8) void {
    out.append(alloc, '"') catch return;
    for (s) |ch| switch (ch) {
        '"' => out.appendSlice(alloc, "\\\"") catch return,
        '\\' => out.appendSlice(alloc, "\\\\") catch return,
        '\n' => out.appendSlice(alloc, "\\n") catch return,
        '\r' => out.appendSlice(alloc, "\\r") catch return,
        else => {
            if (ch < 0x20) {
                var buf: [8]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch return;
                out.appendSlice(alloc, hex) catch return;
            } else out.append(alloc, ch) catch return;
        },
    };
    out.append(alloc, '"') catch return;
}

// -------------------------------------------------------- the host surface
//
// `__host` is the ONLY door out of the guest, and it is deliberately
// narrow: randomness, base64, UTF-8 transcoding, a clock and timers.
// Everything else in the platform surface — URL, Headers, Request,
// Response, structuredClone, events — is pure computation over those, and
// lives in ringlib/prelude.js where it is written once and shared by every
// worker.
//
// The rule that keeps this honest: if a capability is not here, the guest
// cannot have it. There is no path-taking function, no process, no socket,
// so "the JS guest cannot reach the machine" is checkable by reading this
// one section rather than by auditing a library.

/// The prelude, evaluated into every context at creation.
const prelude_src = @embedFile("ringlib/prelude.js");

fn hostUtf8Encode(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return rs_js_undefined();
    const s = c.JS_ToCString(ctx, argv[0]) orelse return rs_js_undefined();
    defer c.JS_FreeCString(ctx, s);
    const bytes = std.mem.span(s);

    // A plain array; the prelude wraps it in a Uint8Array. Building the
    // typed array here would tie this file to QuickJS's buffer API for no
    // gain — the copy is one pass over a string that was already copied.
    const arr = c.JS_NewArray(ctx);
    for (bytes, 0..) |b, i| {
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), c.JS_NewInt32(ctx, b));
    }
    return arr;
}

fn hostUtf8Decode(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_NewString(ctx, "");
    var len: u32 = 0;
    const len_v = c.JS_GetPropertyStr(ctx, argv[0], "length");
    defer c.JS_FreeValue(ctx, len_v);
    _ = c.JS_ToUint32(ctx, &len, len_v);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const v = c.JS_GetPropertyUint32(ctx, argv[0], i);
        defer c.JS_FreeValue(ctx, v);
        var n: u32 = 0;
        _ = c.JS_ToUint32(ctx, &n, v);
        buf.append(alloc, @truncate(n)) catch return rs_js_undefined();
    }
    // Invalid UTF-8 is replaced rather than refused: a decoder that throws
    // on a truncated multi-byte sequence turns a partial read into a
    // crash, which is the opposite of what a decoder is for.
    return c.JS_NewStringLen(ctx, buf.items.ptr, buf.items.len);
}

const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn hostB64Encode(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return c.JS_NewString(ctx, "");
    const s = c.JS_ToCString(ctx, argv[0]) orelse return rs_js_undefined();
    defer c.JS_FreeCString(ctx, s);
    const in = std.mem.span(s);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i + 2 < in.len) : (i += 3) {
        const n = (@as(u32, in[i]) << 16) | (@as(u32, in[i + 1]) << 8) | in[i + 2];
        out.appendSlice(alloc, &.{
            b64_alphabet[(n >> 18) & 63], b64_alphabet[(n >> 12) & 63],
            b64_alphabet[(n >> 6) & 63],  b64_alphabet[n & 63],
        }) catch return rs_js_undefined();
    }
    if (i < in.len) {
        const rem = in.len - i;
        var n: u32 = @as(u32, in[i]) << 16;
        if (rem == 2) n |= @as(u32, in[i + 1]) << 8;
        out.appendSlice(alloc, &.{
            b64_alphabet[(n >> 18) & 63],
            b64_alphabet[(n >> 12) & 63],
            if (rem == 2) b64_alphabet[(n >> 6) & 63] else '=',
            '=',
        }) catch return rs_js_undefined();
    }
    return c.JS_NewStringLen(ctx, out.items.ptr, out.items.len);
}

fn b64Value(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn hostB64Decode(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return rs_js_null();
    const s = c.JS_ToCString(ctx, argv[0]) orelse return rs_js_null();
    defer c.JS_FreeCString(ctx, s);

    var quad: [4]u8 = undefined;
    var have: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    for (std.mem.span(s)) |ch| {
        if (ch == '=' or ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') continue;
        const v = b64Value(ch) orelse return rs_js_null(); // the prelude throws
        quad[have] = v;
        have += 1;
        if (have == 4) {
            const n = (@as(u32, quad[0]) << 18) | (@as(u32, quad[1]) << 12) |
                (@as(u32, quad[2]) << 6) | quad[3];
            out.appendSlice(alloc, &.{
                @truncate(n >> 16), @truncate(n >> 8), @truncate(n),
            }) catch return rs_js_null();
            have = 0;
        }
    }
    if (have == 1) return rs_js_null(); // a single leftover sextet is never valid
    if (have >= 2) {
        const n = (@as(u32, quad[0]) << 18) | (@as(u32, quad[1]) << 12) |
            (@as(u32, if (have > 2) quad[2] else 0) << 6);
        out.append(alloc, @truncate(n >> 16)) catch return rs_js_null();
        if (have == 3) out.append(alloc, @truncate(n >> 8)) catch return rs_js_null();
    }
    return c.JS_NewStringLen(ctx, out.items.ptr, out.items.len);
}

fn hostRandomBytes(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    var n: u32 = 0;
    if (argc >= 1) _ = c.JS_ToUint32(ctx, &n, argv[0]);
    if (n > 65536) n = 65536;

    var buf: [65536]u8 = undefined;
    // The OS CSPRNG, never a seeded PRNG: a guest whose randomness is
    // reproducible by anyone who can read the application is worse than
    // no randomness, because it looks like randomness.
    std.crypto.random.bytes(buf[0..n]);

    const arr = c.JS_NewArray(ctx);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = c.JS_SetPropertyUint32(ctx, arr, i, c.JS_NewInt32(ctx, buf[i]));
    }
    return arr;
}

fn hostNowMs(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    const ns = std.time.nanoTimestamp();
    return c.JS_NewFloat64(ctx, @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms);
}

// ------------------------------------------------------------- timers
//
// A timer here does not mean a thread. The guest runs inside one request
// on one worker, so a timer is a callback held until the host drains
// jobs — `setTimeout(fn, 0)` yields, and a longer delay is honoured by
// ORDER, not by sleeping. A server that actually slept would be a server
// holding a worker hostage on a guest's say-so.
//
// docs/JS.md states this plainly rather than letting someone discover it
// from a stopwatch.

const Timer = struct { id: u32, due_ms: f64, fn_val: c.JSValue };
threadlocal var g_timers: std.ArrayList(Timer) = .empty;
threadlocal var g_timer_seq: u32 = 0;

fn hostSetTimeout(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1 or !c.JS_IsFunction(ctx, argv[0])) return c.JS_NewInt32(ctx, 0);
    var ms: f64 = 0;
    if (argc >= 2) _ = c.JS_ToFloat64(ctx, &ms, argv[1]);
    g_timer_seq += 1;
    g_timers.append(alloc, .{
        .id = g_timer_seq,
        .due_ms = ms,
        .fn_val = rs_js_dup_value(ctx.?, argv[0]),
    }) catch return c.JS_NewInt32(ctx, 0);
    return c.JS_NewInt32(ctx, @intCast(g_timer_seq));
}

fn hostClearTimeout(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return rs_js_undefined();
    var id: u32 = 0;
    _ = c.JS_ToUint32(ctx, &id, argv[0]);
    var i: usize = 0;
    while (i < g_timers.items.len) : (i += 1) {
        if (g_timers.items[i].id == id) {
            c.JS_FreeValue(ctx, g_timers.items[i].fn_val);
            _ = g_timers.orderedRemove(i);
            return rs_js_undefined();
        }
    }
    return rs_js_undefined();
}

/// Run every due timer, earliest delay first. Called from drainJobs, so a
/// timer and a promise settle in the same drain and neither starves.
fn runTimers(ctx: *c.JSContext) bool {
    if (g_timers.items.len == 0) return false;
    // Earliest first; ties keep insertion order, which is what setTimeout
    // guarantees and what a test will notice if it is wrong.
    var best: usize = 0;
    for (g_timers.items, 0..) |t, i| {
        if (t.due_ms < g_timers.items[best].due_ms) best = i;
    }
    const t = g_timers.orderedRemove(best);
    defer c.JS_FreeValue(ctx, t.fn_val);
    const r = c.JS_Call(ctx, t.fn_val, rs_js_undefined(), 0, null);
    defer c.JS_FreeValue(ctx, r);
    if (c.JS_IsException(r)) captureException(ctx);
    return true;
}

fn installOne(
    ctx: *c.JSContext,
    host: c.JSValue,
    name: [*:0]const u8,
    f: *const fn (?*c.JSContext, c.JSValue, c_int, [*c]c.JSValue) callconv(.c) c.JSValue,
    argc: c_int,
) void {
    _ = c.JS_SetPropertyStr(ctx, host, name, c.JS_NewCFunction(ctx, f, name, argc));
}

// ------------------------------------------------- serv.call, by trampoline
//
// A JS service must be able to call other services — that is what makes
// the guest a citizen rather than a leaf. The obstacle is that dispatch
// lives in RING, and by the time JS is running we are already INSIDE a
// Ring VM call. Calling back into the VM from here would be re-entrancy
// on a runtime that guards against exactly that, and the guard exists
// because the buffers of the outer call would be clobbered.
//
// So the control flow is inverted, and Ring stays the outer loop:
//
//   1. JS calls `serv.call(...)`, which returns a PROMISE and queues a
//      request. Nothing re-enters anything.
//   2. The action returns; its promise is still pending. Instead of
//      reporting "never settled", the host answers the sentinel below.
//   3. Ring sees the sentinel, drains the queued requests, dispatches
//      each ONE AT A TIME through its own ordinary `__dispatch` — with
//      contracts, placement and everything else intact — and hands each
//      result back.
//   4. Ring asks the host to continue. Promises resume, the action may
//      queue more calls, and the loop repeats until the action settles.
//
// The guest never sees the trampoline: it awaits a promise, like anything
// else. What it buys is that `serv.call` from JS is the SAME dispatch a
// Ring service gets, rather than a second, weaker path that would drift.

/// What `js_service_call` answers when the action is waiting on a
/// `serv.call`. Not JSON, and not a value any service could return —
/// JSON.stringify never produces a bare identifier.
pub const PENDING = "__RS_PENDING__";

const PendingCall = struct {
    id: u32,
    service: []u8,
    action: []u8,
    payload: []u8,
    resolve: c.JSValue,
    reject: c.JSValue,
};

/// One suspended action: its own promise, and the calls it is waiting on.
///
/// A STACK, not a slot, and a gate is why. A JS service may call another
/// JS service, which suspends in turn — so while the inner one is being
/// dispatched there are two actions in flight on this worker. A single
/// slot let the inner action overwrite the outer one's promise, and the
/// outer call then waited forever on something nobody held. Frames make
/// the nesting explicit and make the lifetime obvious: the top frame is
/// always the one Ring is currently trampolining.
const Frame = struct {
    promise: c.JSValue,
    calls: std.ArrayList(PendingCall) = .empty,
};

threadlocal var g_frames: std.ArrayList(Frame) = .empty;
threadlocal var g_call_seq: u32 = 0;

fn topFrame() ?*Frame {
    if (g_frames.items.len == 0) return null;
    return &g_frames.items[g_frames.items.len - 1];
}

fn hostServCall(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this_val;
    const cx = ctx.?;
    if (argc < 2) {
        return c.JS_Throw(cx, c.JS_NewString(cx, "serv.call(service, action, payload)"));
    }

    var funcs: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(cx, &funcs);
    if (c.JS_IsException(promise)) return promise;

    const svc = dupArgString(cx, argv[0]) orelse return promise;
    const act = dupArgString(cx, argv[1]) orelse return promise;
    // The payload crosses as JSON, exactly as it does on the wire — so a
    // value that could not survive the wire cannot survive this either,
    // and a service cannot accidentally depend on being called in-process.
    const payload = if (argc >= 3) blk: {
        const enc = c.JS_JSONStringify(cx, argv[2], rs_js_undefined(), rs_js_undefined());
        defer c.JS_FreeValue(cx, enc);
        break :blk dupArgString(cx, enc) orelse alloc.dupe(u8, "{}") catch return promise;
    } else alloc.dupe(u8, "{}") catch return promise;

    const frame = topFrame() orelse {
        // A `serv.call` outside any service action — from `js-eval`, say.
        // There is no trampoline to run it, and saying so beats a promise
        // that never settles.
        alloc.free(svc);
        alloc.free(act);
        alloc.free(payload);
        c.JS_FreeValue(cx, funcs[0]);
        c.JS_FreeValue(cx, funcs[1]);
        c.JS_FreeValue(cx, promise);
        return c.JS_Throw(cx, c.JS_NewString(cx,
            "serv.call is only available inside a service action"));
    };

    g_call_seq += 1;
    frame.calls.append(alloc, .{
        .id = g_call_seq,
        .service = svc,
        .action = act,
        .payload = payload,
        .resolve = funcs[0],
        .reject = funcs[1],
    }) catch return promise;

    return promise;
}

fn dupArgString(ctx: *c.JSContext, v: c.JSValue) ?[]u8 {
    const s = c.JS_ToCString(ctx, v) orelse return null;
    defer c.JS_FreeCString(ctx, s);
    return alloc.dupe(u8, std.mem.span(s)) catch null;
}

/// How many service actions are suspended on this worker right now.
///
/// The nesting counter the Ring side needs, kept HERE because here is
/// where it is already correct: every frame is pushed and popped by
/// js_service_call itself, including on the error paths, so it cannot
/// drift the way a counter maintained across a `raise` would.
pub export fn js_depth() u32 {
    return @intCast(g_frames.items.len);
}

/// The queued requests, as JSON, and the queue is emptied. Ring dispatches
/// them and hands each result back through `js_resolve_call`.
pub export fn js_pending_calls() [*:0]const u8 {
    g_result.clearRetainingCapacity();
    g_result.appendSlice(alloc, "[") catch return "[]";
    const frame = topFrame() orelse {
        g_result.appendSlice(alloc, "]") catch {};
        g_result.append(alloc, 0) catch return "[]";
        defer _ = g_result.pop();
        return @ptrCast(g_result.items.ptr);
    };
    for (frame.calls.items, 0..) |call, i| {
        if (i > 0) g_result.appendSlice(alloc, ",") catch {};
        g_result.writer(alloc).print(
            "{{\"id\":{d},\"service\":\"{s}\",\"action\":\"{s}\",\"payload\":{s}}}",
            .{ call.id, call.service, call.action, call.payload },
        ) catch {};
    }
    g_result.appendSlice(alloc, "]") catch {};
    g_result.append(alloc, 0) catch return "[]";
    defer _ = g_result.pop();
    return @ptrCast(g_result.items.ptr);
}

fn takeCall(id: u32) ?PendingCall {
    // Searched across every frame, not just the top one: a result may
    // arrive for an outer frame while an inner one is still open, and an
    // id is unique for the life of the worker.
    for (g_frames.items) |*frame| {
        for (frame.calls.items, 0..) |call, i| {
            if (call.id == id) return frame.calls.orderedRemove(i);
        }
    }
    return null;
}

fn freeCall(ctx: *c.JSContext, call: PendingCall) void {
    alloc.free(call.service);
    alloc.free(call.action);
    alloc.free(call.payload);
    c.JS_FreeValue(ctx, call.resolve);
    c.JS_FreeValue(ctx, call.reject);
}

/// Hand one dispatch result back to the guest.
pub export fn js_resolve_call(id: u32, json: [*:0]const u8) i32 {
    const ctx = g_ctx orelse return 1;
    const call = takeCall(id) orelse return 1;
    defer freeCall(ctx, call);

    const src = std.mem.span(json);
    var value = c.JS_ParseJSON(ctx, src.ptr, src.len, "<reply>");
    if (c.JS_IsException(value)) {
        c.JS_FreeValue(ctx, value);
        value = c.JS_NewString(ctx, "the service reply was not JSON");
        const r = c.JS_Call(ctx, call.reject, rs_js_undefined(), 1, @ptrCast(&value));
        c.JS_FreeValue(ctx, r);
        c.JS_FreeValue(ctx, value);
        return 1;
    }
    const r = c.JS_Call(ctx, call.resolve, rs_js_undefined(), 1, @ptrCast(&value));
    c.JS_FreeValue(ctx, r);
    c.JS_FreeValue(ctx, value);
    return 0;
}

/// Fail one pending call — a dispatch that raised on the Ring side becomes
/// a rejected promise in the guest, so `try/catch` works across the seam.
pub export fn js_reject_call(id: u32, message: [*:0]const u8) i32 {
    const ctx = g_ctx orelse return 1;
    const call = takeCall(id) orelse return 1;
    defer freeCall(ctx, call);
    var err = c.JS_NewError(ctx);
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewString(ctx, message));
    const r = c.JS_Call(ctx, call.reject, rs_js_undefined(), 1, @ptrCast(&err));
    c.JS_FreeValue(ctx, r);
    c.JS_FreeValue(ctx, err);
    return 0;
}

/// Encode the awaited action's result, or answer PENDING again.
///
/// Shared by `js_service_call` and `js_continue` so there is exactly one
/// place that decides what "done" means.
fn finishAwaited(ctx: *c.JSContext) [*:0]const u8 {
    const frame = topFrame() orelse {
        setError("nothing is awaiting continuation", .{});
        return "";
    };
    const promise = frame.promise;
    switch (c.JS_PromiseState(ctx, promise)) {
        c.JS_PROMISE_PENDING => {
            if (frame.calls.items.len > 0) return PENDING;
            clearAwaited(ctx);
            setError("the service returned a promise that never settled — " ++
                "it is awaiting something this host does not provide", .{});
            return "";
        },
        c.JS_PROMISE_REJECTED => {
            const reason = c.JS_PromiseResult(ctx, promise);
            defer c.JS_FreeValue(ctx, reason);
            _ = c.JS_Throw(ctx, rs_js_dup_value(ctx, reason));
            captureException(ctx);
            clearAwaited(ctx);
            return "";
        },
        else => {
            const value = c.JS_PromiseResult(ctx, promise);
            defer c.JS_FreeValue(ctx, value);
            clearAwaited(ctx);
            return encodeValue(ctx, value);
        },
    }
}

fn clearAwaited(ctx: *c.JSContext) void {
    var frame = g_frames.pop() orelse return;
    c.JS_FreeValue(ctx, frame.promise);
    // Abandon anything still queued in THIS frame: the action is over, and
    // resolving a call whose caller has gone would run guest code with no
    // one waiting for it. An outer frame's queue is untouched.
    for (frame.calls.items) |call| freeCall(ctx, call);
    frame.calls.deinit(alloc);
}

/// Resume a service that was waiting on `serv.call` results.
pub export fn js_continue() [*:0]const u8 {
    g_result.clearRetainingCapacity();
    g_err.clearRetainingCapacity();
    const ctx = g_ctx orelse {
        setError("no JS context", .{});
        return "";
    };
    drainJobs(ctx);
    if (g_err.items.len != 0) return "";
    return finishAwaited(ctx);
}

/// JSON-encode a settled value into the result buffer.
fn encodeValue(ctx: *c.JSContext, value: c.JSValue) [*:0]const u8 {
    g_result.clearRetainingCapacity();
    const encoded = c.JS_JSONStringify(ctx, value, rs_js_undefined(), rs_js_undefined());
    defer c.JS_FreeValue(ctx, encoded);
    if (c.JS_IsException(encoded)) {
        captureException(ctx);
        return "";
    }
    if (c.JS_ToCString(ctx, encoded)) |s| {
        defer c.JS_FreeCString(ctx, s);
        g_result.appendSlice(alloc, std.mem.span(s)) catch {};
    }
    g_result.append(alloc, 0) catch return "";
    defer _ = g_result.pop();
    return @ptrCast(g_result.items.ptr);
}
