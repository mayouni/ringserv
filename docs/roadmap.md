# Roadmap

*The charter these phases answer to is [VISION.md](VISION.md) — the author's
statement of what RingServ is for, recorded 2026-08-22. The road ahead —
phases 10 and on — is proposed and kept current in [PLAN.md](PLAN.md);
delivered phases move back here with their gate results.*

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
**Gate — CLOSED 2026-08-22, and it was not a formality.** RingServ is
now built and run on **Windows, Linux and macOS** every push
(`.github/workflows/gates.yml`, run 32583106700: macos-14 2m4s,
ubuntu 12m32s, windows 5m43s), plus `zig build dist` proving all five
shipped targets still cross-compile.

Running them found five real defects that Windows-only testing was
structurally incapable of seeing:

- **`zig build dist` was broken for every target.** `dist` was written
  here in phase 4; tree-sitter arrived with `check` in phase 5 and only
  the *native* executable was taught about it. Every cross target failed
  on `tree_sitter/api.h` for months while this file said the opposite —
  because nothing ran it and nothing gated it.
- **Strict ISO hid POSIX on musl.** `-std=c11` defines `__STRICT_ANSI__`;
  musl honours it, so QuickJS lost `clock_gettime` and tree-sitter lost
  `fdopen`. The obvious fix (`-D_POSIX_C_SOURCE`) *broke macOS*, whose
  `malloc.h` needs the Darwin extensions it suppresses. `gnu11` satisfies
  all three.
- **The panel's Stop button deadlocked on Linux.** `Child.kill()` is
  TerminateProcess on Windows and SIGTERM-then-blocking-waitpid on POSIX,
  so the same line that stopped an app instantly here held the HTTP
  worker forever there. 301 s to 2.2 s.
- **Six markdown links were dead on GitHub and Linux** — `docs/vision.md`
  tracked lowercase against `VISION.md` links. The gate that should have
  caught it used `fs.existsSync`, which is case-insensitive on NTFS: it
  found the file on the machine doing the checking and passed while every
  reader got a 404. It now asks **git** for the exact tracked names,
  across every tracked markdown file.
- **Line endings were nondeterministic.** No `.gitattributes`, so a
  Windows checkout produced CRLF; `cli.zig`'s scaffold templates are Zig
  multiline literals, so the CRLF reached the generated `app.ring` and
  gates that regex on a bare newline stopped matching — reporting success
  while checking nothing. Three suites were red in CI and green locally, for no
  reason visible in any diff.

The lesson, recorded because it generalises: **a gate that has only ever
run in one environment is a gate that has only ever tested one
environment.** See [cli.md](cli.md).

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

## Phase 7 — The JS guest ✅ (passed 2026-08-19)

**Part 1 — the resident runtime ✅ (passed 2026-08-18).** quickjs-ng
v0.16.1 vendored (four translation units; **quickjs-libc deliberately
absent**), `src/js.zig` mirroring the Ring bridge name for name, one
runtime and context per worker. Errors carry line numbers; an `async`
function is settled rather than encoded as a promise; memory and stack
limits are the server's.
**Gate — passed:** 25 gates (`node tests/js-gates.js`), five of which
keep the guest fenced in — `require`, `std`, `os`, `scriptArgs` and
`process` must all be undefined.

**Part 2 — `.js` services ✅ (passed 2026-08-18).** A third service form:
`:report = [ :js = "services/report.js" ]`, where the file's `service`
object holds the actions and everything else is private. Ring reads the
file and hands the host **source, never a path**, so the guest's lack of
a filesystem is a property of the build. The catalog asks the guest what
it answers.
**Gate — passed:** 23 gates (`node tests/jsserv-gates.js`), the central
one being that a JS service and a Ring service answering the same shape
are compared **as data** — envelope, contract, placement, status codes
and catalog identical.

**Part 3 — the host surface and the seam ✅ (passed 2026-08-19).** The
ECMA-429 / WinterTC minimum surface, written once and shared by every
worker: `__host` holds **nine** primitives in Zig, and everything that is
pure computation over them lives in `ringlib/prelude.js`. `serv.call` from
JS reaches other services through the SAME dispatch a Ring service gets,
by a trampoline that keeps Ring as the outer loop rather than re-entering
the VM. Full account in [JS.md](JS.md).
**Gate — passed:** conformance is graded against `tests/wintertc.json` —
someone else's list — in **both directions**: every name claimed present
must exist, and every name recorded absent must genuinely be absent, each
absence carrying a reason. 45 gates in `js-gates.js`, 33 in
`jsserv-gates.js`.

**Phase 7 is complete.** Still open and recorded rather than implied:
`crypto.subtle`, streams, `Blob` and `WebSocket`, each with its reason in
`wintertc.json`.

## Phase 8 — Hardening toward 0.9 ✅ (delivered 2026-08-19)

**Compaction ✅ (2026-08-19).** `SyncCompact` trims a shape and moves its
floor **in one transaction**, because two statements would leave a window
where the rows are gone and the floor still says they are there. Closes
the gap phase 6 recorded rather than implied. 53 sync gates.

**The TLS decision ✅ (2026-08-19).** RingServ terminates no TLS and says
why in four places ([TLS.md](TLS.md)) — the decisive one being that a TLS
stack is the single dependency that cannot be vendored honestly. Made
**executable**: binding a non-loopback address refuses to start without
`:behindproxy`, and the refusal names both ways forward. 17 gates.

**The actor seam ✅ (2026-08-19).** `Actor()` plus `:auth` in the contract.
The host verifies a token (HS256, signature before claims, constant-time,
`alg: none` refused by allowlist); Ring decides what an actor may do,
because permissions are an application's vocabulary. 401 and 403 stay
distinct. 25 gates, most of them refusals. **C5 is deliberately not
guessed at** — this is the seam it plugs into.

**Benchmarks published ✅ (2026-08-19).** [BENCHMARKS.md](BENCHMARKS.md),
with the method beside the numbers and one finding published *unresolved*
rather than benchmarked around.

**The didactic docs ✅ (2026-08-19).** RingScript's culture, adopted:
[getting-started.md](getting-started.md) and a **worked application**,
[fieldnotes-app.md](fieldnotes-app.md), built all the way through. The
listings are not excerpts — they come from
[`examples/fieldnotes/`](../examples/fieldnotes), which runs, tests and
serves. `tests/guide-gates.js` (31) checks the guide's claims against that
application, its links, and the commands it promises: documentation rots
because nothing fails when it stops being true, so now something does.

**Phase 8 is delivered.**
**Gate — the Principal's to open:** RingServ carries one real application
of the author's — the same bar RingScript's 0.9 met before its API froze.
No session can open that gate for him, and the worked example is a guide,
not a substitute.

## Phase 9 — The journaled store ✅ (delivered 2026-08-22)

The second half of the answer to
[COMMONS.md §1](COMMONS.md): a record some applications are **required by
law** to keep whole, in a server whose sync layer trims history on purpose.
`Journal()` is a **store beside `Data()`, not a mode of it**, because the
two want opposite things and one primitive settling between them would
serve neither.

|            | `Data()`                          | `Journal()`                     |
|------------|-----------------------------------|---------------------------------|
| rows       | mutable                           | append-only                     |
| history    | derived by triggers, **compacted** | *is* the data, **never trimmed** |
| recovery   | the rows are the state            | **replay is the only recovery** |

```ring
Journal([ :name = "ventes", :apply = func aEvent { ... } ])
JournalAppend("ventes", [ :type = "passer_commande", :who = "ada" ])
JournalVerify("ventes")   ->  [ :events = 41, :chain = "INTACTE", :at = 0 ]
```

**Chained, and verified where it breaks.** Each record stores `prev` and
`hash = SHA-256(prev + body)` — hashed over *the exact stored body text*,
never a re-serialisation, so two encoders disagreeing about whitespace can
never manufacture a break that did not happen. `JournalVerify` reports
`INTACTE`/`ROMPUE` **and the sequence number where it first fails, and which
of the two invariants failed**. A verdict without a location is a verdict
nobody can act on. The gate edits a body through a second connection — the
real threat model is someone with the file, not someone with the API.

**The head is read inside the write transaction.** Reading it outside would
be a guess: a second worker appending in between forks the chain silently,
which is the one failure this structure exists to prevent. `:apply` runs
**only after the commit**, so an application can never hold state the
journal cannot account for.

**Replay at boot was not enough — the finding of this phase.** The germ this
comes from was one process; RingServ is N workers, each with a private VM.
`:apply` runs in the worker that appended, so every other worker's state
stopped at its own boot: four orders numbered **1, 1, 2** across two
workers, which is what the fixture printed the first time it ran. A worker
now **catches up at the door**, applying every record newer than its own
in-memory high-water mark — normally an indexed query returning nothing.
The mark is per worker and never persisted: it describes what *this* VM has
folded in, and a stored copy would be wrong for every worker that read it.

**Compaction refuses a journal by name** — the mirror image of it refusing a
non-shape, and the more important half. The service an application may
expose (`RsJournalService`) is **read-only by construction**: `verify` and
`read`, and no append. An endpoint that let any caller write to a fiscal
record would be worse than no endpoint.

`JournalExport` emits the germ's own line-per-record JSON, so a journal
moves between the two without translation.

**And it is reachable with nothing connected.** `ringserv journal
list | verify | export` (`src/journal.zig`) is the ambassador COMMONS.md §1
named: the box in a drawer, an inspector standing there, and no client
attached. It opens the application's **own** database rather than the
scratch `:memory:` that `check`, `docs` and `topology` use, because it reads
records and not declarations -- and it names that file on every run, since
an export whose provenance is implicit is one nobody can hand to an
auditor. `verify` **exits 1 on ROMPUE**, so it can be a cron job rather than
a ritual. It **never creates the journal table**: pointed at the wrong path
it reports a MISSING record rather than an empty one, and says so, because
SQLite creating an absent file is not evidence that anything was lost.
Which journal a request means is decided in Ring, beside the identical rule
the HTTP service uses -- a second copy in Zig would be a second answer.

42 gates own it (`tests/journal-gates.js`), covering the chain, the restart,
worker agreement, the refusals, the tamper, and the command line. 19 suites now.

**Phase 9 is delivered.**

## Phase 10 — The gesture ✅ (delivered 2026-08-22, the plan's first phase)

The charter's heart ([VISION.md](VISION.md)): *hosting anything is a
dead-simple gesture, even a single function.* Full account in
[gesture.md](gesture.md); the plan entry was [PLAN.md](PLAN.md) phase 10.

**`ringserv serve file.ring`** — a file of plain functions serves as-is:
service = file name, action = every top-level function (`_` prefix stays
private), payload keys map to parameters BY NAME (case-insensitive,
order-independent, a missing parameter refused as 422 naming every missing
one at once), return value enveloped. The mapping is deliberately boring,
and **`serve --explain` prints it** without serving — the phase's risk
clause (magic that lies) discharged by making the tool state what it
exposed. What serve refuses, it refuses with the reason: a file already
declaring RingServ() (that is `run`'s job), an unserviceable file name, a
file with no functions, more than 10 parameters. `new --gesture` scaffolds
the first-touch pair; the full scaffold stays the default.

**`ringserv.yaml`** — the config-file form, a deliberately small yaml-like
subset parsed in ~150 lines of Ring (`src/ringlib/config.ring`), because
vendoring a YAML engine for a config file breaks the dependency ethos for
nothing. Mappings, scalars, comments, one nesting level; anchors, aliases,
tags, flow style, block scalars, sequences, tabs and document markers are
**refused by name with the line number**. Only `true`/`false` are booleans
— `country: no` stays a string, which is the Norway problem defused by
deciding (flag keys still read the yes/no family through RsBool). Two
boundaries stated rather than discovered: **code is not configuration**
(`services:` in yaml is refused toward the application file), and **the
declaration wins** — `--port` > `RingServ([...])` > yaml, every collision
printed at boot with both values.

**Gate — passed:** 41 gates (`node tests/gesture-gates.js`), including:
the two forms answering **byte-identically** (same service configured in
Ring vs in yaml, envelopes compared as strings); the yaml-named database
file existing where it said; every refused construct refused by name; and
the doc's ninety-seconds example **extracted from its own fence in
[gesture.md](gesture.md) and driven** — the page cannot rot silently.
20 suites.

**Phase 10 is delivered.**

## The panel ✅ (delivered 2026-08-22, by the author's standing order)

`ringserv panel [dir]` — the admin panel: every app in a directory (both
shapes: gesture files and app.ring directories), status/start/stop/logs
and a call box on one clean loopback-only page, with children managed as
real processes. The design rule is TRUTH: status follows the process (a
child killed behind the panel's back is reported stopped — gated), start
is proven by the app's own port answering, shutdown leaves no orphans —
gated on the ports, not the promise. [panel.md](panel.md); 29 gates
(`tests/panel-gates.js`), including that a server-wide stop leaves the
panel resident and able to start everything again. 21 suites.

Also standing from the same order: **every phase closes with an
interactive browser demo** the author can drive — recorded in
[PLAN.md](PLAN.md)'s change log as a gate on communication.

## Phase 11 — JS, honestly measured ✅ (delivered 2026-08-23)

The plan's second phase ([PLAN.md](PLAN.md)): the module story, the
surface widened by real need, and the Node comparison published with its
losses on top.

**ES modules, without surrendering the sandbox.** A service file using
top-level `import`/`export` loads as a real ES module (live bindings,
diamonds, cycles — the engine's own semantics) and says `export const
service`. The design decision that mattered: **the guest still has no
filesystem.** Ring walks the static import graph itself — the same
app-root anchoring its own loader learned the hard way — reads every
file, and stages sources in the guest's in-memory store; QuickJS's
loader serves only from that store. Three boundaries enforced by
structure and named when hit: relative paths inside the application
only, no npm (a statement, not a gap), static imports only. The
reference application's receipt service now runs as a module
([examples/comptoir/services](../examples/comptoir/services)).

**`crypto.subtle.digest`, and only digest.** SHA-256/384/512 and SHA-1,
computed by Zig's native crypto through one new host primitive — the
narrow-door gate widened from nine to ten, on the record, which is that
gate's whole job. Every other SubtleCrypto member throws by name: a
wrong `sign()` must not be able to look like a slow one. Verified
against the textbook SHA-256 of `"abc"`.

**The Node comparison, losses first**
([BENCHMARKS.md](BENCHMARKS.md) § Against Node): Node wins dispatch
1.8× and JSON-heavy 3.8× — V8 and QuickJS are different weight classes
and the document says so plainly — while the SQLite row lands at parity
because both sides pay the disk, not their engines. The harness is
committed (`tests/bench-vs-node.js`); re-measuring is one command.

**Gate — passed:** jsserv-gates grew to 43 (module diamond, sibling
imports, re-exported consts, `false`/`null` from modules, and five named
refusals: npm, escape, missing file, dynamic import, no-service-export);
js-gates to 45 (the digest quartet, the by-name refusals of the other
SubtleCrypto members, the widened door). Comptoir's 38 pass unchanged
over the module-form receipt — the forms are indistinguishable from
outside, which was the claim.

**Phase 11 is delivered.**

## Phase 12 — The family handshake ✅ (delivered 2026-08-23)

The vision's symbiosis promise made executable ([FAMILY.md](FAMILY.md)):
two RingServ processes on one host or LAN discover each other with zero
configuration and call each other by name — `Family()` and
`FamilyCall("beta", "hello.greet", …)` — while `:announce = false`
refuses by ABSENCE: no socket, nothing to overhear, proven by packet
capture rather than trust.

One boring transport: a JSON beacon on UDP multicast 239.255.71.74:47474,
carrying the device-identity fields relayed from microring (custody as
the axis, the algorithm named even when "none") — shape routed to
Central as PLAN-HANDSHAKE-12 before it freezes, provisional until
answered. The roster is a phone book, not a trust store: a family call
is dispatched by the called server's ordinary door, because over the
wire family is a stranger with a known address.

Two findings, each from a failing gate, each now a comment where the
code is: **multicast, not unicast** (N sockets sharing a port all hear a
multicast; only one hears a unicast — the suite's own capture socket ate
the beacons and proved it), and **the beacon carries the bind address**,
so reachability mirrors the TLS rule instead of lying — a loopback-bound
sibling honestly advertises same-host-only.

**Gate — passed:** 13 gates (`tests/family-gates.js`): discovery with
zero config, identity round-trip, the placed call, refusals unchanged
for family callers, packet-captured silence, junk/wrong-family/wrong-
version ignored by shape. 23 suites.

**Phase 12 is delivered.**

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
