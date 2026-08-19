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

    // `this` is the service object, so an action may call a sibling as
    // `this.other(...)` — the same reach a Ring class-form service has.
    const ret = c.JS_Call(ctx, fn_val, obj, 1, @ptrCast(&arg));
    defer c.JS_FreeValue(ctx, ret);
    if (c.JS_IsException(ret)) {
        captureException(ctx);
        return "";
    }
    drainJobs(ctx);
    if (g_err.items.len != 0) return "";

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
