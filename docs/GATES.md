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
| **bridge gates** (16, in process) | residency, trapped errors with real line numbers, reset, the region terminator, `give`, `rs_call`, filesystem `load`, **load integrity** |
| **service gates** (16 + 200-body fuzz) | dispatch in both forms, envelopes, 404/400/500, Action-suffix privacy, 24-way parallelism, survival |
| **schema gates** (18) | declared tables and columns, automatic `id`, 40 concurrent writes across workers, cross-worker visibility, persistence across restart, idempotent re-declaration, shared in-memory database |
| **CRUD + contracts** (38) | every generic action, paging, filters, `:actions`, overrides, and **every validation rule the validator implements** |
| **data fuzz** (9, 400 payloads) | the payload-key **SQL boundary**, hostile shapes, and proof the database is untouched afterwards |
| **check + docs** (21) | seeded defects: syntax shapes, contracts naming things that do not exist, services that can never answer — each must be NAMED and fail; plus the clean scaffold staying silent |
| **CLI gates** (16) | new → test → dev → edit → reload → where, including that a failing expectation *fails the run* |
| **soak** (`--full`) | 3,000 requests with flat memory |
| **native oracle** (`--full`) | 24 programs byte-identical to native `ring.exe` |

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

## What is still thin (honest list)

- **The oracle is 24 programs.** RingScript sweeps ~830 (its samples
  plus documentation snippets) with a harness that already exists next
  door. Pointing it here is the cheapest large win available.
- **Soak has no data layer.** The flat-memory evidence predates
  SQLite; connections and prepared statements are a resource class
  with no endurance evidence yet.
- **Ports are hardcoded** (8080/8093/8094/8095), so a leftover
  process breaks a run, and suites cannot run in parallel.
- **`dev`'s child can outlive its parent** when the parent is killed
  abruptly (the CLI gates kill the tree explicitly to compensate).
- **Untested error paths in `db.zig`**: a read-only file, a
  nonexistent directory, a disk that fills.
- **Only the Windows binary has been run.** Four other targets
  cross-compile; that is not the same thing.
