//! db.zig — the SQLite layer.
//!
//! The concurrency model follows WORKERS.md: each VM worker thread owns a
//! private RingState, and here it also owns a private SQLite connection to
//! the same database file. SQLite in WAL mode is built for exactly this —
//! concurrent readers with one writer at a time — so no connection is ever
//! shared between threads (SQLITE_THREADSAFE=2 enforces it at the library
//! level: serialized per connection, never across).
//!
//! Every entry point answers Ring, never the process: a failed statement
//! raises a trappable Ring error carrying SQLite's own message, so a bad
//! query lands in a 500 envelope and the server keeps serving.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const alloc = std.heap.c_allocator;

/// Ring C API pieces this layer needs (same externs as the bridge; kept
/// local so db.zig stays a leaf module).
extern fn ring_vm_api_isstring(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getstring(p: ?*anyopaque, n: c_int) ?[*:0]u8;
extern fn ring_vm_api_getstringsize(p: ?*anyopaque, n: c_int) c_uint;
extern fn ring_vm_api_isnumber(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_getnumber(p: ?*anyopaque, n: c_int) f64;
extern fn ring_vm_api_islist(p: ?*anyopaque, n: c_int) c_int;
extern fn ring_vm_api_paracount(p: ?*anyopaque) c_int;
extern fn ring_vm_api_retstring2(p: ?*anyopaque, s: [*]const u8, n: c_uint) void;
extern fn ring_vm_api_retnumber(p: ?*anyopaque, n: f64) void;
extern fn ring_vm_error(pVM: ?*anyopaque, cStr: [*:0]const u8) void;
extern fn ring_vm_api_newlist(p: ?*anyopaque) ?*anyopaque;
extern fn ring_list_newlist(pList: ?*anyopaque) ?*anyopaque;
extern fn ring_list_addstring2(pList: ?*anyopaque, str: [*]const u8, n: c_uint) void;
extern fn ring_list_adddouble(pList: ?*anyopaque, n: f64) void;
extern fn ring_vm_api_retlist(p: ?*anyopaque, pList: ?*anyopaque) void;

/// This worker's connection. Opened lazily on first use, closed never —
/// a worker lives as long as the process.
threadlocal var g_db: ?*c.sqlite3 = null;
/// The database path, set once at boot by the main thread before workers
/// start (read-only afterwards, so no lock is needed).
var g_path: [:0]const u8 = ":memory:";
/// Memory databases are per-connection by definition, so N workers would
/// each get their own empty one. Shared-cache URI form keeps them looking
/// at the same data, which is what a test or a scratch app expects.
var g_is_memory: bool = false;

var g_configured: bool = false;

pub fn configure(path: []const u8) !void {
    if (g_configured) alloc.free(g_path);
    g_is_memory = path.len == 0 or std.mem.eql(u8, path, ":memory:");
    // A private :memory: database is per-CONNECTION, so N workers would
    // each get their own empty one. The shared-cache URI form makes them
    // all see the same data — what a test or a scratch app expects.
    g_path = if (g_is_memory)
        try alloc.dupeZ(u8, "file:ringserv_mem?mode=memory&cache=shared")
    else
        try alloc.dupeZ(u8, path);
    g_configured = true;
}

/// What the app asked for, before URI rewriting — for diagnostics.
var g_display_path: []const u8 = ":memory:";

pub fn setDisplayPath(path: []const u8) void {
    g_display_path = path;
}

fn openIfNeeded(p: ?*anyopaque) ?*c.sqlite3 {
    if (g_db) |db| return db;
    // A program that never declared a database still gets one: the
    // shared in-memory default, configured on first touch.
    if (!g_configured) configure(":memory:") catch {
        ring_vm_error(p, "cannot configure database");
        return null;
    };
    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI;
    if (c.sqlite3_open_v2(g_path.ptr, &db, flags, null) != c.SQLITE_OK) {
        if (db) |d| ring_vm_error(p, c.sqlite3_errmsg(d)) else ring_vm_error(p, "cannot open database");
        if (db) |d| _ = c.sqlite3_close(d);
        return null;
    }
    // WAL: concurrent readers alongside a writer — the whole reason N
    // workers can share one file. Meaningless for :memory:, harmless there.
    if (!g_is_memory) _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON;", null, null, null);
    // Writers queue rather than fail instantly when another worker holds
    // the write lock. 5s is long for a request and short for a deadlock.
    _ = c.sqlite3_busy_timeout(db, 5000);
    g_db = db;
    return db;
}

fn argText(p: ?*anyopaque, n: c_int) []const u8 {
    if (ring_vm_api_isstring(p, n) == 0) return "";
    const s = ring_vm_api_getstring(p, n) orelse return "";
    return s[0..@intCast(ring_vm_api_getstringsize(p, n))];
}

/// Bind Ring arguments 2..N to statement parameters 1..N-1. Strings bind
/// as text, numbers as doubles — Ring has no other scalar.
fn bindArgs(p: ?*anyopaque, stmt: ?*c.sqlite3_stmt) void {
    const count = ring_vm_api_paracount(p);
    var i: c_int = 2;
    while (i <= count) : (i += 1) {
        const idx = i - 1;
        if (ring_vm_api_isstring(p, i) != 0) {
            const s = argText(p, i);
            _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_TRANSIENT);
        } else if (ring_vm_api_isnumber(p, i) != 0) {
            _ = c.sqlite3_bind_double(stmt, idx, ring_vm_api_getnumber(p, i));
        } else {
            _ = c.sqlite3_bind_null(stmt, idx);
        }
    }
}

fn fail(p: ?*anyopaque, db: ?*c.sqlite3, what: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ what, c.sqlite3_errmsg(db) }) catch "database error";
    ring_vm_error(p, msg);
}

/// Ring: __db_exec(cSql, ...) — run a statement, return rows changed.
pub fn execHook(p: ?*anyopaque) callconv(.c) void {
    const db = openIfNeeded(p) orelse return;
    const sql = argText(p, 1);
    if (sql.len == 0) {
        ring_vm_error(p, "__db_exec: empty statement");
        return;
    }
    const sql_z = alloc.dupeZ(u8, sql) catch {
        ring_vm_error(p, "__db_exec: out of memory");
        return;
    };
    defer alloc.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        fail(p, db, "sql error");
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);
    bindArgs(p, stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        fail(p, db, "sql error");
        return;
    }
    ring_vm_api_retnumber(p, @floatFromInt(c.sqlite3_changes(db)));
}

/// Ring: __db_query(cSql, ...) — return a list of row lists. Each cell is
/// a Ring string or number; NULL becomes "".
pub fn queryHook(p: ?*anyopaque) callconv(.c) void {
    const db = openIfNeeded(p) orelse return;
    const sql = argText(p, 1);
    if (sql.len == 0) {
        ring_vm_error(p, "__db_query: empty statement");
        return;
    }
    const sql_z = alloc.dupeZ(u8, sql) catch {
        ring_vm_error(p, "__db_query: out of memory");
        return;
    };
    defer alloc.free(sql_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        fail(p, db, "sql error");
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);
    bindArgs(p, stmt);

    const out = ring_vm_api_newlist(p);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) {
            fail(p, db, "sql error");
            return;
        }
        const row = ring_list_newlist(out);
        const ncols = c.sqlite3_column_count(stmt);
        var col: c_int = 0;
        while (col < ncols) : (col += 1) {
            switch (c.sqlite3_column_type(stmt, col)) {
                c.SQLITE_INTEGER, c.SQLITE_FLOAT => ring_list_adddouble(row, c.sqlite3_column_double(stmt, col)),
                c.SQLITE_NULL => ring_list_addstring2(row, "", 0),
                else => {
                    const t = c.sqlite3_column_text(stmt, col);
                    const n = c.sqlite3_column_bytes(stmt, col);
                    if (t) |txt| ring_list_addstring2(row, txt, @intCast(n)) else ring_list_addstring2(row, "", 0);
                },
            }
        }
    }
    ring_vm_api_retlist(p, out);
}

/// Ring: __db_columns(cTable) — column names of a table, for the schema
/// layer's introspection (also how "does this table exist" is answered).
pub fn columnsHook(p: ?*anyopaque) callconv(.c) void {
    const db = openIfNeeded(p) orelse return;
    const table = argText(p, 1);
    var buf: [256]u8 = undefined;
    // The table name comes from the app's own Data() declaration and is
    // validated there; quote it anyway so a stray character cannot
    // rewrite the statement.
    const sql = std.fmt.bufPrintZ(&buf, "PRAGMA table_info(\"{s}\")", .{table}) catch {
        ring_vm_error(p, "__db_columns: table name too long");
        return;
    };
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        fail(p, db, "sql error");
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);
    const out = ring_vm_api_newlist(p);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const t = c.sqlite3_column_text(stmt, 1); // 1 = name
        const n = c.sqlite3_column_bytes(stmt, 1);
        if (t) |txt| ring_list_addstring2(out, txt, @intCast(n));
    }
    ring_vm_api_retlist(p, out);
}

/// Ring: __db_path() — the database the app asked for, for diagnostics.
pub fn pathHook(p: ?*anyopaque) callconv(.c) void {
    ring_vm_api_retstring2(p, g_display_path.ptr, @intCast(g_display_path.len));
}
