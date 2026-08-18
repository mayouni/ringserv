/* rs_js.c — the few QuickJS entry points Zig cannot reach by itself.
 *
 * quickjs.h expresses its sentinel values as MACROS over JS_MKVAL, which
 * builds a JSValue by initialising a union. Zig's translate-c refuses
 * that at comptime ("Can't default init a union"), so JS_UNDEFINED and
 * friends are unreachable from Zig even though every real function in
 * the header translates cleanly.
 *
 * Same shape as the rs_bind_text shim in native_stubs.c, and for the same
 * reason: one small C function is a better answer than open-coding a
 * vendor's internal representation in Zig, which would then be wrong the
 * first time upstream changed it.
 */

#include "quickjs.h"

JSValue rs_js_undefined(void) { return JS_UNDEFINED; }
JSValue rs_js_null(void) { return JS_NULL; }
JSValue rs_js_true(void) { return JS_TRUE; }
JSValue rs_js_false(void) { return JS_FALSE; }
JSValue rs_js_exception(void) { return JS_EXCEPTION; }

/* JS_FreeValue and JS_DupValue are `static inline` in the header; taking
 * their address from Zig is not portable, so they are re-exported here as
 * real symbols. */
void rs_js_free_value(JSContext *ctx, JSValue v) { JS_FreeValue(ctx, v); }
JSValue rs_js_dup_value(JSContext *ctx, JSValue v) { return JS_DupValue(ctx, v); }
