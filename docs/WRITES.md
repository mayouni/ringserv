# Why a write costs 10 ms — and what it actually is

*The data soak reported `create` at ~11 ms while a read cost ~1 ms, and
`docs/GATES.md` recorded that as "a measurement waiting to be made".
This is that measurement. The answer was not where any of my first
three guesses put it.*

## The finding

**Every generic write is its own implicit transaction, so it pays a
full WAL commit — and a WAL commit becomes ~70× more expensive once
several worker connections have the same database file open.**

Measured in process, with HTTP, dispatch and the job queue removed, on
identical fresh databases where **worker count is the only variable**:

| | 1 worker | 3 workers |
|---|---:|---:|
| insert, one commit each | **0.07 ms** | **4.5 – 6.2 ms** |
| the same inserts inside one transaction | 0.003 ms | 0.02 – 0.03 ms |
| single-row read | 0.010 ms | 0.097 ms |

Four alternating runs, same fixture, same machine. The pattern held
every time.

Two things that table settles:

- **It is the commit, not the insert.** Wrapping the same 300 inserts
  in one explicit transaction keeps them at hundredths of a
  millisecond even with three workers. The row write is nearly free;
  the *commit* is what costs.
- **It is the other connections, not the load.** The other two workers
  are idle. Merely having the database open on more connections makes
  each commit dramatically more expensive.

That is consistent with how SQLite's WAL works: a commit coordinates
through the shared-memory index (`-shm`) and its locks, and that
coordination grows with the number of connections attached to the
file — which is exactly the shape RingServ's worker model creates,
because **every worker opens its own connection** (`docs/WORKERS.md`).

## What it is not — three hypotheses, each tested and dropped

Worth recording, because each was plausible and each was wrong:

1. **"It's WAL checkpointing."** Disproved directly: setting
   `PRAGMA wal_autocheckpoint=0` on a mature 4 MB WAL changed inserts
   from 0.063 ms to 0.020 ms — real, but three orders of magnitude too
   small to explain 10 ms.
2. **"It's disk — fsync on commit."** Disproved by the in-memory run:
   `:memory:` writes measured p50 = 1.00 ms over HTTP, with the *same*
   rare tens-of-ms outliers as the file database. No disk, same shape.
3. **"It's the HTTP and job-queue overhead."** Disproved by measuring
   inside a single request: an empty request costs 0.89 ms and a read
   1.19 ms, while the in-process insert loop *by itself* cost 8.6 ms
   per insert on that same server. The cost was already there before
   HTTP was involved.

## And one measurement error of my own

The first numbers I published (`create` 12.5 ms, then 11.5 ms) came
from **20-operation averages taken once**. That window is far too
small here: a single rare 40 ms outlier moves a 20-op average by
2 ms, and the runs varied between 0.8 ms and 12.9 ms for identical
work depending on conditions I had not controlled. Two of those runs
were also measuring a **stale server** — `pkill` does not kill
processes on Windows, so a previous server was still bound to the port
and answering from a different database. Every number in this document
comes from repeated runs with p50/p90 reported, a verified row count,
and a confirmed-dead previous process.

## The fix, and what it bought

**Writes now share a single dedicated connection** — many readers, one
writer, SQLite's own recommended server shape. Reads keep their
per-worker connections and their parallelism; only writes travel
through the shared one, behind a mutex. `docs/WORKERS.md` is unchanged:
this decides which *connection* a write uses, not which thread runs it.

Which statements are writes comes from **SQLite itself**
(`sqlite3_stmt_readonly` after preparing), not from reading the SQL
text, so a write hidden in a CTE or fired by a trigger cannot be
mistaken for a read. A write pays one extra prepare to move to the
writer; that is the price of not guessing.

In process, worker count the only variable:

| | before | after |
|---|---:|---:|
| insert, 1 worker | 0.07 ms | 0.13 – 0.19 ms |
| insert, 3 workers | **4.5 – 6.2 ms** | **0.15 – 0.16 ms** |

Over HTTP, on a verified 2,000-row database:

| operation | before | after |
|---|---:|---:|
| empty request | 0.89 ms | 0.63 ms |
| `get` by id | 1.19 ms | 0.69 ms |
| **`create`** | **10.13 ms** | **0.78 ms** |
| `list` with `limit 50` | 1.44 ms | 1.11 ms |

The single-worker case is slightly *slower* — 0.07 ms to ~0.15 ms —
because every write now pays a mutex and a second prepare. That is the
honest cost of the routing, and it buys the 3-worker case a 30×
improvement, so it is the right trade for a server. Nothing was gained
by trading away durability: `synchronous` is untouched, because the
cost was never the flush.

### The hazard it introduced, and the gate that holds it

A shared writer makes `sqlite3_last_insert_rowid` a property of the
*connection* rather than of the caller. Two workers inserting at once
would each read whichever insert landed last, and a service would hand
a client **somebody else's id** — a data-correctness bug, not a
performance one. `db.zig` captures the rowid into thread-local state
under the same lock that performed the insert, making the pair atomic.

Three gates in `tests/crud-gates.js` hold it: 60 concurrent creates all
succeed, every returned id is distinct, and **each id names the row it
created**. A fourth checks that a write through the writer connection
is visible to a reader connection immediately.

## Reproducing it

`tests/fixtures/bench-app.ring` is the probe: it times inserts,
transaction-wrapped inserts, `__db_columns`, reads and full generic
creates *inside one request*, and reports per-operation cost, so HTTP
and dispatch drop out. Worker count comes from
`RINGSERV_TEST_WORKERS`, so one fixture measures the whole effect.

```bash
RINGSERV_TEST_DB=/tmp/p.db RINGSERV_TEST_WORKERS=3 \
  ringserv run tests/fixtures/bench-app.ring
curl -s -X POST localhost:8096/api/v1 \
  -d '{"service":"bench","action":"inserts","payload":{"n":300}}'
```
