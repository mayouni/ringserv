# The gates

*Every claim in this repository is executable. One command runs them
all:*

```bash
zig build gates             # the six fast suites
zig build gates -- --full   # ...plus soak and the native oracle
```

Suites run in dependency order — bridge, services, data, CLI — and
none stops the others: a full picture beats an early exit.

| Suite | What it defends |
|---|---|
| **bridge gates** (18, in process) | residency, trapped errors with real line numbers, reset, the region terminator, `give`, `rs_call`, filesystem `load`, **load integrity**, and the **C JSON codec held byte-identical to the pure-Ring reference** |
| **service gates** (16 + 200-body fuzz) | dispatch in both forms, envelopes, 404/400/500, Action-suffix privacy, 24-way parallelism, survival |
| **schema gates** (18) | declared tables and columns, automatic `id`, 40 concurrent writes across workers, cross-worker visibility, persistence across restart, idempotent re-declaration, shared in-memory database |
| **CRUD + contracts** (38) | every generic action, paging, filters, `:actions`, overrides, and **every validation rule the validator implements** |
| **data fuzz** (9, 400 payloads) | the payload-key **SQL boundary**, hostile shapes, and proof the database is untouched afterwards |
| **check + docs** (21) | seeded defects: syntax shapes, contracts naming things that do not exist, services that can never answer — each must be NAMED and fail; plus the clean scaffold staying silent |
| **CLI gates** (16) | new → test → dev → edit → reload → where, including that a failing expectation *fails the run* |
| **soak** (`--full`) | 3,000 requests with flat memory |
| **soak — data layer** (`--full`) | sustained mixed CRUD on a file database: connections, prepared statements, WAL, and the per-cell allocation path — flat memory, bounded WAL, an exact final row count, and survival across a restart |
| **native oracle** (`--full`) | the 24 shared playground examples, byte-identical to native `ring.exe` |
| **wide sweep — samples** (`--full`) | **249 of Ring's own sample programs** byte-identical, 62 more required to run cleanly |
| **wide sweep — docs** (`--full`) | the same, over ~500 snippets extracted from Ring's documentation |

## Two gates that exist because of specific bugs

**Load integrity.** `ring_state_runcode` does not report failure: an
embedded Ring file with a syntax error simply defines nothing, and the
damage surfaces far from the cause. `func Call` did exactly this —
`call` is a Ring keyword, so `testing.ring` silently defined nothing
and `rs_init` said OK; it was caught only because an unrelated command
broke. Now `rs_init` proves each file defined what it promises, fails
loudly with the file's name (`rs_init_error()`), and a gate proves the
**detector discriminates** — a check that cannot fail is decoration.

**The SQL boundary.** Generic table services build statement *text*
from column names, so a payload key that reached the statement would
be an injection. `tests/fuzz-data.js` throws quote-escapes,
`drop table`, and 5 KB keys at every generic action, then proves the
schema is unchanged and the row count is exactly baseline plus
successful creates.

## The wide sweep, and what it found

`tests/sweep.js` runs Ring's own corpus — its ~470 sample programs and
~500 documentation snippets — through native `ring.exe` **and**
`ringserv run`, comparing byte for byte. It is RingScript's sweep
transposed to a native runtime, and the transposition is mostly
*subtraction*: RingScript had to exclude everything touching files,
because a browser has none. RingServ has a real filesystem, so files,
`load`, and multi-file samples are all comparable here.

It earned its place on the first run, finding a fidelity bug no
hand-written gate would ever have caught: **native `ring` normalizes
CRLF as it reads a source file**, so a multi-line string literal in a
Windows-saved file contains bare newlines. RingServ passed the raw
bytes, and every such literal was two characters longer per line.
Fixed in `cli.zig` (`normalizeZ`), and now every path that loads a
`.ring` file goes through it.

**Known divergences are a ledger, not a silence.** Four samples (plus
one documentation snippet with the same root cause) still differ, each
listed in `tests/sweep.js` with its reason — chiefly Ring's
`optionalFunc()`, whose deferred-definition semantics do not survive
`ringserv run` evaluating a program's *source* where native compiles a
*file*. They are reported and excused; **anything not on that list
fails the sweep**, and an entry that stops diverging is announced so
the list cannot rot into excuses nobody rechecks.

## What the data soak measured

`tests/soak-data.js` runs a mixed CRUD workload against a **file**
database, so it exercises what `soak-lite` never touches: a connection
per worker, a prepared statement per call, the WAL, and a Ring list
allocated per row *per cell* on every read. It also keeps score, so a
run that leaked nothing but corrupted a row still fails.

Result over 2,000 operations on 2,000 seeded rows: **RSS flat at
~70 MB** (69.9 → 70.1), WAL checkpointed and bounded, the final row
count exactly right, and every row present after a restart.

**It also found where the time goes**, which no gate had measured
before — and the finding was acted on.

| operation | before | after |
|---|---|---|
| `get` by id | 1.5 ms | 1.3 ms |
| `list` with `limit 50` | 5.5 ms | 1.8 ms |
| `create` | 12.5 ms | 11.5 ms (see [WRITES.md](WRITES.md) — it is the commit, not the codec) |
| `list` of 2,000 rows | **163 ms** | **28 ms** |

Isolating that last one showed the cause: querying SQLite *and*
building the 2,000 column-keyed rows cost 17 ms, while encoding them
to JSON cost **113 ms** — about 87 % of the response. RingServ was
using the **pure-Ring** JSON codec, deliberately, since phase 1.

RingScript had already solved this and held the solution to a hard
contract, so the fix was to vendor rather than to invent:
`src/rs_json.c` is now the shipped codec, and `src/ringlib/json.ring`
stays exactly where it was as **the reference it is held
byte-identical to** — which is also the implementation native Ring
runs. Encoding 2,000 rows ten times went from **1,134 ms to 7 ms**.

The contract is enforced, not asserted: two gates load the pure
reference under renamed entry points and diff the two codecs in one
VM — 22 decode cases including every malformed shape `json.ring` has
an opinion about (and the quirks it *tolerates*, like a lone `+`
parsing as 0, which an imitation would miss), and 11 encode cases
covering control bytes, deep nesting and number formatting. Error
texts are compared verbatim, because `json.ring`'s `raise()` messages
carry 1-based positions the C codec must reproduce rather than
approximate.

## What is still thin (honest list)

- **Writes cost ~10 ms because every one is its own WAL commit, and a
  commit gets ~70× dearer once several worker connections hold the
  file open** — measured, reproduced, and written up in
  [WRITES.md](WRITES.md). The fix (one dedicated writer connection,
  SQLite's own recommended server shape) is **not done**.
- **Micro-benchmarks here need repeated runs**, not one 20-operation
  average: the same work measured between 0.8 ms and 12.9 ms across
  runs before the conditions were controlled. WRITES.md records that
  mistake too, because the numbers it corrects were mine.
- **Ports are hardcoded** (8080/8093/8094/8095), so a leftover
  process breaks a run, and suites cannot run in parallel.
- **`dev`'s child can outlive its parent** when the parent is killed
  abruptly (the CLI gates kill the tree explicitly to compensate).
- **Untested error paths in `db.zig`**: a read-only file, a
  nonexistent directory, a disk that fills.
- **Only the Windows binary has been run.** Four other targets
  cross-compile; that is not the same thing.
