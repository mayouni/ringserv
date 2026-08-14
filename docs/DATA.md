# The data layer

*Phase 3, complete: the SQLite substrate, the schema seam, the query
surface, generic table services, and contracts. 43 gates
(`tests/data-gates.js` 18, `tests/crud-gates.js` 25).*

## The decision that shaped this layer

RingServ's core speaks **plain SQL over SQLite** and carries **no
framework's query dialect** — not even a family one.

The reasoning, recorded because it will be asked again: RingServ is a
*general* Ring application server. A developer who has never heard of
Softanza must be able to use all of it. Embedding Softanza's ZQL would
have inverted the family's dependency direction — the floor depending
on a framework's grammar, versioning, and extraction schedule — and
that was not theoretical: this phase was blocked for exactly that
reason until the coupling was removed. Two projects in one family
already disagreeing about what "ZQL" means was the evidence that it is
a framework concept, not an infrastructure one.

So higher-level query languages are **layers**: pure-Ring libraries an
application loads, compiling down to `DataQuery`/`DataExec`. Softanza
can still promise one query language across page and server — that
promise is simply Softanza's to make, where it belongs, rather than
RingServ pretending to be Softanza-specific.

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

## The query surface

```ring
aRows = DataQuery("select id, title from notes where weight > ?", [ 10 ])
DataExec("insert into notes (title, weight) values (?, ?)", [ cTitle, nW ])
nId   = DataInsertId()
nHowMany = DataValue("select count(*) from notes", [], 0)
```

Parameters are a **list**, always bound, never interpolated — Ring has
no variadic user functions, so an explicit list is the honest shape.
`DataQuery` returns **column-keyed rows** (`[{"id":1,"title":"a"}]`),
because services emit JSON objects; the positional form stays
available internally.

## Generic table services

Declaring a table is enough:

```ring
:notes = [ :table = "notes" ]                          # all five actions
:tags  = [ :table = "tags", :actions = [ :list, :get ] ]
:tags  = [ :table = "tags", :create = func aReq { … } ] # explicit wins
```

`list` (with `limit`/`offset` paging and equality `filter`), `get`,
`create`, `update`, `delete`. **Column names never come from the
request**: payload keys are matched against the live schema and
unknown ones are dropped, so a key cannot reach the statement text;
values always travel as bound parameters. Missing rows are 404s, not
empty successes.

## Contracts

```ring
Contract(:notes, [
    :create = [
        :in = [
            :title  = [ :type = :string, :required = true, :maxlen = 20 ],
            :weight = [ :type = :number, :min = 0, :max = 100 ]
        ],
        :out = [ :id = :number ]
    ]
])
```

Enforced **before dispatch**, so they govern generic actions too, and
the action never sees a violating payload. Every failure is reported
at once (a client fixing one field per round-trip is a bad afternoon),
as a **422** envelope. Supported: `:type` (string/number/int/list/
bool), `:required`, `:min`/`:max` (number value or list length),
`:maxlen`/`:minlen`, `:of` (element type). `:out` is declared for the
docs and the static checker but **not** enforced at runtime — a server
should not refuse to answer because its own reply drifted.

## Gates (`node tests/data-gates.js` — 18, all passing)

Declared tables and columns exist · automatic `id` · `DataPath`
reports the declared database · insert through a service · 40
concurrent writes across workers · all writes land · every worker
agrees on the count · SQL error is a clean 500 envelope · server
survives it · server never dies · restart against an existing file ·
**data persists across restart** · re-running `Data()` is idempotent ·
writes continue after restart · in-memory comes up · in-memory writes
· all workers share one in-memory database.

## Gates (`node tests/crud-gates.js` — 25, all passing)

Generic create/get/update/delete/list · update and delete persist ·
paging by limit and offset · equality filters · **unknown filter
columns dropped rather than injected** · missing rows are 404 ·
`:actions` restriction · explicit override wins and actually runs ·
required · wrong type · maxlen · numeric max · **all violations
reported at once** · contracts govern generic actions · valid payloads
pass · server never dies.
