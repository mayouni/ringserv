# The data layer — what exists after phase 3 (part 1)

*Phase 3 is split deliberately. The schema layer and the SQLite
substrate are built and gated; the developer-facing **query surface**
is not, because its name and grammar are an open family question
(issue #1). This page records exactly where the line is.*

## What is built

**SQLite, vendored** — the 3.53.4 amalgamation (public domain),
compiled by `zig cc` in the same build graph as everything else. Flags
chosen for this server: `SQLITE_THREADSAFE=2` (serialized per
connection — correct *and* faster than full mutexing, because a
connection is never shared), `SQLITE_OMIT_LOAD_EXTENSION` (no dlopen
surface), `SQLITE_DQS=0` (a double-quoted string is an error, not a
silent fallback to a literal), FTS5 and JSON1 on.

**One connection per worker** (`src/db.zig`). Each VM worker thread
already owns a private `RingState`; it now also owns a private SQLite
connection to the same database. WAL mode makes that the *supported*
shape rather than a gamble — concurrent readers alongside one writer —
and `busy_timeout=5s` makes a contended write queue rather than fail.
The gates prove it: 40 concurrent writes across 4 workers all land,
and every worker sees the same 41 rows afterwards.

An in-memory database gets the shared-cache URI form, because a plain
`:memory:` database is per-*connection*: N workers would otherwise
each get a private empty one. The gate for this exists (`all workers
share one in-memory database`) because the bug it prevents is silent.

**`Data()` — the schema seam** (`src/ringlib/data.ring`, pure Ring):

```ring
RingServ([
    :database = "app.db",           # or :memory: (the default)

    :data = [
        :notes = [
            :title  = :string,
            :body   = :string,
            :weight = :number,
            :tags   = :list         # stored as JSON text
        ]
    ]
])
```

- Every table gets an `id INTEGER PRIMARY KEY AUTOINCREMENT`, declared
  or not, so every row is addressable by the layers above.
- Types map Ring→SQLite: `:string`/`:text`→TEXT, `:number`→REAL,
  `:int`/`:bool`→INTEGER, `:list`/`:object`→TEXT (JSON).
- **Idempotent by construction**: `CREATE TABLE IF NOT EXISTS`, then
  `ALTER TABLE ADD COLUMN` for any column the declaration gained.
  Restarting against an existing file is a no-op; adding a column to
  the declaration adds it to the table. **Removals are never applied**
  — dropping data is not something a boot sequence should decide.
- Every worker applies the schema to its own connection at boot
  (`__rs_data_apply`); the repeats are free and the race is safe.

**Introspection**: `DataTables()`, `DataColumns(cTable)`,
`DataPath()`.

**The two primitives** everything above will stand on: `__db_exec(sql,
…)` and `__db_query(sql, …)`, both with real parameter binding (`?`),
both raising **trappable Ring errors** carrying SQLite's own message.
A bad statement is therefore a clean 500 envelope and a living server
— gated.

## What is NOT built, and why

The **query surface** a developer writes — the `Zql(...)` of the
blueprint's examples — is deliberately absent. Issue #1 established
that "ZQL" already names a *different* language in Zing (a closed verb
set: `DEFINE ENTITY | NORM | FLOW` plus `SELECT`, where `insert` is
unparseable by design), while `docs/services.md` shows
`Zql("insert into orders values ?")`. Building a surface under a
contested name would make the collision permanent in code rather than
just in documentation.

So phase 3 stops at the substrate, and the surface waits for one
decision (RingServ's to make, per the issue):

1. **Same language** — pin to the canonical StzZql grammar and give
   writes a different door (generic table services, or an explicit
   `Data`-side API). The `Zql("insert …")` examples in
   `docs/services.md` then get corrected.
2. **Different languages** — RingServ names its own surface (e.g.
   `Query()` / `Data()`), and "ZQL" belongs to Zing and Softanza.

Also still ahead in phase 3: **generic table services** (`table =
"notes"` → list/get/create/update/delete) and **`Contract()`**
validation with 422 envelopes. Both are written against the query
surface, so both wait on the same decision.

## Gates (`node tests/data-gates.js` — 18, all passing)

Declared tables and columns exist · automatic `id` · `DataPath`
reports the declared database · insert through a service · 40
concurrent writes across workers · all writes land · every worker
agrees on the count · SQL error is a clean 500 envelope · server
survives it · server never dies · restart against an existing file ·
**data persists across restart** · re-running `Data()` is idempotent ·
writes continue after restart · in-memory comes up · in-memory writes
· all workers share one in-memory database.
