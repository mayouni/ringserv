//! db.zig — the SQLite layer.
//!
//! MANY READERS, ONE WRITER. Each VM worker thread owns a private
//! RingState (WORKERS.md) and a private SQLite READ connection; every
//! write in the process goes through a single shared write connection
//! behind a mutex.
//!
//! That split is a measurement, not a preference. With a connection per
//! worker, each commit cost 4.5–6.2 ms once three connections held the
//! file open, against 0.07 ms with one — SQLite's WAL commit coordinates
//! through the shared-memory index, and the cost grows with the number
//! of attached connections (docs/WRITES.md). Reads keep their own
//! connections and their parallelism, because reads never paid it.
//!
//! SQLITE_THREADSAFE=2 means a single connection must not be touched by
//! two threads at once, which is exactly what the write mutex enforces.
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
extern fn ring_vm_api_getlist(p: ?*anyopaque, n: c_int) ?*anyopaque;
extern fn rs_bind_text(stmt: ?*c.sqlite3_stmt, idx: c_int, s: [*]const u8, n: c_int) c_int;
extern fn rs_list_getsize(pList: ?*anyopaque) c_int;
extern fn rs_list_isstring(pList: ?*anyopaque, n: c_int) c_int;
extern fn rs_list_getstring(pList: ?*anyopaque, n: c_int) ?[*:0]const u8;
extern fn rs_list_getstringsize(pList: ?*anyopaque, n: c_int) c_int;
extern fn rs_list_isnumber(pList: ?*anyopaque, n: c_int) c_int;
extern fn rs_list_getdouble(pList: ?*anyopaque, n: c_int) f64;

/// This worker's READ connection. Opened lazily on first use, closed
/// never — a worker lives as long as the process.
threadlocal var g_db: ?*c.sqlite3 = null;

/// The single WRITE connection, shared by every worker and guarded by
/// the mutex below. Many readers, one writer is SQLite's own recommended
/// server shape, and here it is not a preference but a measurement:
/// a per-worker commit cost 4.5–6.2 ms with three connections open on
/// the file and 0.07 ms with one (docs/WRITES.md). Reads keep their own
/// connections and their parallelism; only writes come through here.
var g_write_db: ?*c.sqlite3 = null;
var g_write_mutex: std.Thread.Mutex = .{};

/// The rowid of the last insert THIS worker made, captured while the
/// write mutex was still held.
///
/// This is load-bearing. With a shared writer, `sqlite3_last_insert_rowid`
/// is a property of the connection, not of the caller — so two workers
/// inserting concurrently would each read whichever insert landed last,
/// and a service would hand a client somebody else's id. Capturing it
/// under the same lock that performed the insert makes the pair atomic.
threadlocal var g_last_insert_id: i64 = 0;
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

/// Open one connection to the configured database, with this server's
/// pragmas applied. Used for both the per-worker readers and the one
/// writer, so they cannot drift apart.
fn openConn(p: ?*anyopaque) ?*c.sqlite3 {
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
    // WAL: concurrent readers alongside the writer — the whole reason N
    // workers can share one file. Meaningless for :memory:, harmless there.
    if (!g_is_memory) _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
    _ = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON;", null, null, null);
    // Writers queue rather than fail instantly when another connection
    // holds the write lock. 5s is long for a request, short for a deadlock.
    _ = c.sqlite3_busy_timeout(db, 5000);
    return db;
}

/// This worker's read connection.
fn openIfNeeded(p: ?*anyopaque) ?*c.sqlite3 {
    if (g_db) |db| return db;
    const db = openConn(p) orelse return null;
    g_db = db;
    return db;
}

/// The shared write connection. THE CALLER MUST HOLD g_write_mutex.
fn writerLocked(p: ?*anyopaque) ?*c.sqlite3 {
    if (g_write_db) |db| return db;
    const db = openConn(p) orelse return null;
    g_write_db = db;
    return db;
}

/// A prepared statement plus the connection it belongs to. When `is_write`
/// is set the write mutex is HELD and `release` must be called.
const Routed = struct {
    stmt: ?*c.sqlite3_stmt,
    db: ?*c.sqlite3,
    is_write: bool,

    fn release(self: Routed) void {
        _ = c.sqlite3_finalize(self.stmt);
        if (self.is_write) g_write_mutex.unlock();
    }
};

/// Prepare a statement on the right connection.
///
/// Which one it is comes from SQLite itself — `sqlite3_stmt_readonly`
/// after preparing — rather than from inspecting the SQL text, so a
/// write hidden inside a CTE or a trigger cannot be mistaken for a read.
/// A write costs one extra prepare (microseconds) to move to the writer;
/// that is the price of not guessing.
fn prepareRouted(p: ?*anyopaque, sql: [:0]const u8) ?Routed {
    const rdb = openIfNeeded(p) orelse return null;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(rdb, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        fail(p, rdb, "sql error");
        return null;
    }
    if (c.sqlite3_stmt_readonly(stmt) != 0) {
        return .{ .stmt = stmt, .db = rdb, .is_write = false };
    }

    _ = c.sqlite3_finalize(stmt);
    g_write_mutex.lock();
    const wdb = writerLocked(p) orelse {
        g_write_mutex.unlock();
        return null;
    };
    var wstmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(wdb, sql.ptr, -1, &wstmt, null) != c.SQLITE_OK) {
        fail(p, wdb, "sql error");
        g_write_mutex.unlock();
        return null;
    }
    return .{ .stmt = wstmt, .db = wdb, .is_write = true };
}

fn argText(p: ?*anyopaque, n: c_int) []const u8 {
    if (ring_vm_api_isstring(p, n) == 0) return "";
    const s = ring_vm_api_getstring(p, n) orelse return "";
    return s[0..@intCast(ring_vm_api_getstringsize(p, n))];
}

/// Bind statement parameters. Two shapes are accepted, because Ring has
/// no variadic user functions: a LIST as argument 2 (what the Ring-level
/// Data* API passes — `DataQuery(sql, [a, b])`), or arguments 2..N
/// directly (convenient from a C-hook call site). Strings bind as text,
/// numbers as doubles; anything else binds NULL.
fn bindArgs(p: ?*anyopaque, stmt: ?*c.sqlite3_stmt) void {
    const count = ring_vm_api_paracount(p);
    if (count == 2 and ring_vm_api_islist(p, 2) != 0) {
        const list = ring_vm_api_getlist(p, 2);
        const n = rs_list_getsize(list);
        var i: c_int = 1;
        while (i <= n) : (i += 1) {
            if (rs_list_isstring(list, i) != 0) {
                const s = rs_list_getstring(list, i) orelse "";
                const len: usize = @intCast(rs_list_getstringsize(list, i));
                _ = rs_bind_text(stmt, i, s, @intCast(len));
            } else if (rs_list_isnumber(list, i) != 0) {
                _ = c.sqlite3_bind_double(stmt, i, rs_list_getdouble(list, i));
            } else {
                _ = c.sqlite3_bind_null(stmt, i);
            }
        }
        return;
    }
    var i: c_int = 2;
    while (i <= count) : (i += 1) {
        const idx = i - 1;
        if (ring_vm_api_isstring(p, i) != 0) {
            const s = argText(p, i);
            _ = rs_bind_text(stmt, idx, s.ptr, @intCast(s.len));
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

/// Ring: __db_exec(cSql, aParams) — run a statement, return rows changed.
pub fn execHook(p: ?*anyopaque) callconv(.c) void {
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

    const r = prepareRouted(p, sql_z) orelse return;
    defer r.release();
    bindArgs(p, r.stmt);
    const rc = c.sqlite3_step(r.stmt);
    if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        fail(p, r.db, "sql error");
        return;
    }
    // Both of these are properties of the CONNECTION, so they must be
    // read before the write lock is released — see g_last_insert_id.
    if (r.is_write) g_last_insert_id = c.sqlite3_last_insert_rowid(r.db);
    ring_vm_api_retnumber(p, @floatFromInt(c.sqlite3_changes(r.db)));
}

/// Ring: __db_query(cSql, ...) — return a list of row lists. Each cell is
/// a Ring string or number; NULL becomes "".
pub fn queryHook(p: ?*anyopaque) callconv(.c) void {
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

    const r = prepareRouted(p, sql_z) orelse return;
    defer r.release();
    const stmt = r.stmt;
    const db = r.db;
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

/// Ring: __db_rows(cSql, aParams) — like __db_query, but each row is a
/// column-keyed hash ([[name, value], …]) rather than a positional list.
/// This is what services return, because JSON objects are what clients
/// want; positional rows stay available for internal use.
pub fn rowsHook(p: ?*anyopaque) callconv(.c) void {
    const sql = argText(p, 1);
    if (sql.len == 0) {
        ring_vm_error(p, "__db_rows: empty statement");
        return;
    }
    const sql_z = alloc.dupeZ(u8, sql) catch {
        ring_vm_error(p, "__db_rows: out of memory");
        return;
    };
    defer alloc.free(sql_z);

    const r = prepareRouted(p, sql_z) orelse return;
    defer r.release();
    const stmt = r.stmt;
    const db = r.db;
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
            // Each cell is a [name, value] pair — Ring reads that as a hash.
            const pair = ring_list_newlist(row);
            const name = c.sqlite3_column_name(stmt, col);
            if (name) |nm| {
                ring_list_addstring2(pair, nm, @intCast(std.mem.len(nm)));
            } else {
                ring_list_addstring2(pair, "?", 1);
            }
            switch (c.sqlite3_column_type(stmt, col)) {
                c.SQLITE_INTEGER, c.SQLITE_FLOAT => ring_list_adddouble(pair, c.sqlite3_column_double(stmt, col)),
                c.SQLITE_NULL => ring_list_addstring2(pair, "", 0),
                else => {
                    const t = c.sqlite3_column_text(stmt, col);
                    const n = c.sqlite3_column_bytes(stmt, col);
                    if (t) |txt| ring_list_addstring2(pair, txt, @intCast(n)) else ring_list_addstring2(pair, "", 0);
                },
            }
        }
    }
    ring_vm_api_retlist(p, out);
}

/// Ring: __db_insertid() — the rowid of the last insert THIS worker
/// made. Read from the value captured under the write lock, never from
/// the shared connection: asking the connection now could return an
/// insert another worker made in the meantime.
pub fn insertIdHook(p: ?*anyopaque) callconv(.c) void {
    ring_vm_api_retnumber(p, @floatFromInt(g_last_insert_id));
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

/// The vendored SQLite's version, for `ringserv where`.
pub fn versionString() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

/// Ring: __db_path() — the database the app asked for, for diagnostics.
pub fn pathHook(p: ?*anyopaque) callconv(.c) void {
    ring_vm_api_retstring2(p, g_display_path.ptr, @intCast(g_display_path.len));
}
