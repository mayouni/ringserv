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

## What to do about it

Not done yet, and deliberately not decided in passing — the fix is a
real design change:

**Give writes a single dedicated connection.** Many readers, one
writer is SQLite's own recommended server shape. Reads keep their
per-worker connections and their parallelism; writes queue onto one
connection, which removes the multi-connection commit cost entirely.
The worker model in `docs/WORKERS.md` stays as it is — this changes
only which connection a write travels on.

Cheaper partial measures, if that proves awkward:

- Batch related writes into one explicit transaction where an action
  performs several — worth ~100× on that path, per the table above.
- Nothing here argues for `synchronous=OFF`; the cost is not the
  flush, and durability should not be traded for a problem this is
  not.

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
