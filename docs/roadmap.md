# Roadmap

*Phases in the RingScript tradition: each one small, each one gated by
executable verification, one commit per phase milestone. No phase
begins until the previous phase's gates pass.*

## Phase 0 — Blueprint (this repository, today)

The design documents you are reading. **Gate:** the design survives
review — including by the RingScript experience: every seam named
here has a working precedent there, or an explicit risk note.

## Phase 1 — The resident native VM ✅ (passed 2026-08-05)

Port RingScript's bridge to a native target: `build.zig` compiles
`ringvm/` + `bridge.zig` to a host binary; `rs_init / rs_eval /
rs_call / rs_reset` work; errors trapped with real line numbers.
Benchmark and settle the N-worker concurrency model (§2 of
architecture.md) before anything depends on it.
**Gate — passed:** 12 gates green (`zig build test`); the 24-example
shared corpus byte-identical to native `ring.exe`
(`node tests/oracle.js`); the worker model proven and recorded in
[WORKERS.md](WORKERS.md) (~9,500 evals/sec at 8 workers, zero
corruption). Bonus surface: a working `ringserv run / eval /
version / bench-workers` CLI with lazy interactive `give`.

## Phase 2 — HTTP core + the service model ✅ (passed 2026-08-13)

Vendor http.zig; wire `POST /api/v1` → `rs_call("__dispatch", …)`;
implement `servlib` (RingServ(), dispatch, envelopes, Reply()) in pure
Ring; declarative and class service forms; transport status codes.
**Gate — passed:** 16 service gates green (`node tests/serv-gates.js`
— dispatch both forms, envelopes, 404/400/500, Action-suffix privacy,
24-way parallelism); fuzz (200 hostile bodies, server never dies);
soak-lite (`node tests/soak-lite.js` — 3,000 requests, 0 errors, RSS
flat at 47.8 MB to the decimal). Architecture as designed: httpz
(vendored with pinned deps, vendor/VENDOR.md) in front, N VM worker
threads behind a queue, the bridge state threadlocal — HTTP threads
never touch the VM. The full N-hour soak remains a phase-8 gate.

## Phase 3 — Data: SQLite + query surface + contracts

**Split deliberately.** Part 1 (the substrate) is done; part 2 waits
on one decision.

### Part 1 — SQLite + the schema layer ✅ (passed 2026-08-14)

Vendor the SQLite amalgamation; `Data()` schema declarations; one
connection per worker with WAL; `__db_exec`/`__db_query` primitives
raising trappable Ring errors.
**Gate — passed:** 18 schema gates (`node tests/data-gates.js`) —
declared tables/columns with automatic `id`, 40 concurrent writes
across 4 workers, cross-worker visibility, SQL errors as clean 500
envelopes, **persistence across restart**, idempotent re-declaration,
shared in-memory database. Details in [DATA.md](DATA.md).

### Part 2 — query surface, generic services, contracts ✅ (passed 2026-08-14)

**The naming question resolved by removal, not arbitration.** RingServ
is a general Ring application server, so its core carries no
framework's query dialect: it speaks the engine's own SQL through
`DataQuery` / `DataExec` / `DataValue` / `DataInsertId` (bound
parameters, column-keyed rows). Softanza's ZQL — and any other
higher-level surface — is a **layer**: a pure-Ring library an
application loads, compiling down to those calls. The collision in
issue #1 therefore has nothing left to collide with, and the
dependency points the right way.

Also built: **generic table services** (`table = "notes"` →
list/get/create/update/delete, with paging, equality filters,
`:actions` restriction, explicit override, and column names matched
against the live schema so a payload key can never reach statement
text) and **`Contract()`** validation (types, required, min/max,
maxlen/minlen, `:of`) enforced before dispatch, reporting *every*
violation at once as a 422.
**Gate — passed:** 25 CRUD/contract gates
(`node tests/crud-gates.js`).

## Phase 4 — The CLI ✅ (passed 2026-08-14, with one gate held open)

`new`, `dev` (watch + restart), `run`, `test`, `version`, `where`;
static file routes; `zig build dist` cross-compilation; the starter
scaffold whose page calls its own services — **the first fullstack
moment**.
**Gate — passed:** 16 CLI gates (`node tests/cli-gates.js`) drive the
real developer path — new → test → dev → edit → reload → where —
including that the scaffold's own tests pass untouched, that a
failing expectation *fails the run*, that `test` writes no database
file, that the page and the API both answer, and that saving a file
reloads the server.
**Gate — still open:** the scaffold has only been *run* on Windows.
The other four targets cross-compile cleanly, which is not the same
as being tested on their platforms. Closing this needs a machine (or
CI) per platform; see [cli.md](cli.md).

Deviations from the plan, both deliberate and documented in
[cli.md](cli.md): the scaffold is one `app.ring` with a plain
HTML+fetch page (not three files and a RingScript page — RingServ
should not depend on another project's artifacts to scaffold), and
the dist binaries are **not committed** (~32 MB per build would bloat
git history permanently; they belong on releases).

## Phase 5 — check + docs ✅ (passed 2026-08-14)

Vendor the grammar (pinned commit) + tree-sitter runtime;
`ringserv check` (syntax, contract agreement, dead actions);
`ringserv docs` (markdown + JSON catalog).
**Gate — passed:** 21 gates (`node tests/check-gates.js`) driven by
**seeded defects** — a checker that reports nothing is
indistinguishable from one that cannot see. Each planted fault must be
named *and* fail the command; the clean scaffold stays silent; the
markdown and JSON catalogs agree.

Design note worth keeping: syntax comes from tree-sitter, **structure
comes from the VM** (`__rs_catalog()`), because a Ring declaration is
data the runtime already holds and can be computed — reconstructing it
from an AST would be a second, weaker opinion. Details and the honest
limits (including one gate recording a construct the young grammar
does *not* catch) in [CHECK.md](CHECK.md).

## Phase 6 — Topology + sync ✅ (passed 2026-08-18)

Its gate was C3, and **C3 was ratified v1.0 on 2026-08-12**; RingServ
adopted it on 2026-08-17 (ALIGNMENT.md, [topology.md](topology.md) §5).

**Part 1 — placement ✅ (passed 2026-08-18).** `Topology()` as a
declaration; `GET /topology` publishing the compiled seam; dispatch
enforcing it (a `:local` service without `:authority = :server` is
refused 501 over the wire, with the fix in the message);
`ringserv topology --emit` writing the manifest's `placement` section and
**only** that, and refusing when the app declares no `:solution` — the
ratified jurisdiction sentence, executable. `check` reports placement
defects as C2 envelopes over seven codes.
**Gate — passed:** 42 gates (`node tests/topology-gates.js`), including
the **one-word move**: the same suite run against `:site = :server` and
`:site = :local, :authority = :server`, compared as data, with no
application code different between them.

**Part 2 — sync ✅ (passed 2026-08-18).** The shape log in SQLite,
maintained by **triggers** so it is true for every write path;
`GET /sync/shape` with paging, resume-from-any-offset, `must-refetch`
honesty and a long poll that waits on an HTTP thread rather than a VM
worker; `POST /sync/push` with per-client high-water marks. Exactly-once
is a property of the database, not of the control flow: `__db_write_*`
holds the single writer for a whole transaction, so a mutation's claim and
its work are one commit.
**Gate — passed:** 37 gates (`node tests/sync-gates.js`), of which the
**convergence oracle** is the point — N clients, random interleavings, a
third of all pushes retried verbatim as after a dropped response; every
mutation executed exactly once, and replaying the log from offset zero
reproduces the server's table.

Both contract obligations are discharged: the manifest emit landed in part
1, and the **placement case is paid twice** — the one-word move online, and
the *same offline interleaving* run at both placements with identical final
states, which is where a placement difference would actually hide.

Still open, and recorded rather than implied: **compaction**. The floor
table and the `must-refetch` control exist and are honoured; nothing yet
moves the floor. Phase 8. RingScript-side store integration is
RingScript's, and belongs to that repository's plan.

## Phase 7 — The JS guest

Vendor quickjs-ng (amalgamation); `.js` services beside `.ring` ones;
the ECMA-429 minimum surface implemented once in Zig, exposed to the
guest; `serv.call` from JS on the server.
**Gate:** the scaffold's hello service rewritten in JS passes the
same service gates; a subset of WinterTC's API list is
conformance-tested.

## Phase 8 — Hardening toward 0.9

TLS decision (native vs. documented-proxy), auth backends beyond
JWT-shaped tokens, compaction for shape logs, load benchmarks
published with methodology, and the docs rewritten from blueprint
into didactic guides (the RingScript documentation culture).
**Gate:** RingServ carries one real application of the author's — the
same bar RingScript's 0.9 met before its API froze.

## Standing risks (tracked, not hidden)

- **VM concurrency** — the N-worker model is designed, not proven;
  phase 1 exists to prove or replace it.
- **tree-sitter-ring churn** — the grammar is days old; `check` must
  degrade gracefully (grammar failures never block `dev`/`run`).
- **Sync is where distributed-systems dragons live** — hence the
  convergence oracle before any application trusts it, and CRDTs
  explicitly out of scope.
- **Scope discipline** — every phase has a "refuses to be" list in
  the docs; the CLI is the fence around scope creep.
