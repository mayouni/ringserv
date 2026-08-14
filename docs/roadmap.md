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

## Phase 3 — Data: SQLite + ZQL + contracts

Vendor the SQLite amalgamation; `data.ring` schema declarations;
embed `stzZql` targeting SQLite; generic table services; `Contract()`
with runtime validation (422 envelopes).
**Gate:** ZQL parity suite — the same queries against the browser
stzZql and the server one agree; contract conformance generation
works; generic services covered end-to-end.

## Phase 4 — The CLI

`new`, `dev` (watch + reload + error stream), `run`, `test`,
`version`, `where`; prebuilt binaries in `bin/`, `zig build dist`
cross-compilation; the starter scaffold with a RingScript page
calling a RingServ service — **the first fullstack moment**.
**Gate:** the scaffold runs on Windows/macOS/Linux from the committed
binaries with zero installed dependencies; a scripted "new → dev →
edit → test" session passes on all three.

## Phase 5 — check + docs (tree-sitter-ring)

Vendor the grammar (pinned commit) + tree-sitter runtime;
`ringserv check` (syntax, contract agreement, dead actions);
`ringserv docs` (markdown + JSON catalog).
**Gate:** check flags each seeded defect class in a fixture app and
stays silent on the clean scaffold; docs output round-trips (JSON
catalog → rendered markdown → same catalog).

## Phase 6 — Topology + sync

`Topology()` compilation of the call seam (`:local` / `:server` /
`:both`); shape logs in SQLite; `GET /sync/shape` with long-poll/SSE;
`POST /sync/push` with per-client exactly-once; RingScript-side store
integration.
**Gate:** the convergence oracle (topology.md §5): N clients, random
offline interleavings, hostile disconnections — single final state,
every mutation exactly once. Plus the one-word-move gate: switching a
scaffold service between `:local` and `:server` changes no
application code and both configurations pass the same tests.

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
