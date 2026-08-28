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
**Gate — OPENED by the Principal 2026-08-25.** RingServ carries real work:
a deployment of Comptoir standing at `D:\RingServ-Local`, taking orders,
with its record verified and its restore rehearsed. The bar RingScript's
0.9 met before its API froze is met here. No session could open this gate,
and none did.

**And the deployment earned its keep in its first hour**, which is the
argument for the bar rather than a footnote to it: four defects that
twenty-seven green suites on three platforms had never seen. The sharpest
was one syscall — `posix.write` is `WriteFile` on Windows and does not work
on an overlapped socket — behind two symptoms a day apart: no .NET client
could POST to this server on Windows at all, and SSE streaming wrote
nothing, which had been accepted as a platform gap twenty-four hours
earlier. See [FRICTIONS.md](FRICTIONS.md) 4–7.

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

## Phase 18 — Pages that react

A page used to ask "has anything changed?" every two seconds and hear "no"
almost every time. Now the server tells it. `GET /sync/stream` pushes
Server-Sent Events, and the browser half ships **inside the binary** at
`/ringserv.js`, so a page opts in with one line and installs nothing:

```html
<script src="/ringserv.js"></script>
<script> serv.subscribe("menu", refresh); </script>
```

**The event carries an offset, never a row.** One code path for data — the
one that already has paging, `must-refetch` and placement — and therefore **a
dropped notification costs latency, never correctness**. The client keeps a
slow poll underneath, so a page written against `subscribe` is still correct
behind a proxy that eats streaming entirely. That is what made this safe to
ship at 0.9 rather than at 1.0.

**Why SSE and not WebSocket**, in one line each: the flow is one-way, so a
second direction would only invite a second write path; SSE is plain HTTP,
which every proxy passes untouched while a WebSocket upgrade needs
configuring in each one; and `Last-Event-ID` **is** our shape-log offset, so
the browser's own reconnect resumes exactly rather than approximately.

**The two standing complaints about SSE, answered rather than left silent**
(docs/STREAM.md carries both in full):

- *`EventSource` cannot send an `Authorization` header.* It cannot, and there
  is no browser workaround. It does not matter here **because the stream
  carries no data**: a frame is `{shape, offset}`, and the rows come through
  `POST /api/v1`, which does carry the bearer. The usual fix — a token in the
  query string, logged by every proxy it passes — is not needed. This is a
  property of the design, so it is gated on shape: an `advanced` frame is
  asserted to hold **exactly** those two keys, because one extra key would
  quietly turn an unauthenticated channel into a leak.
- *HTTP/2 and buffering proxies.* A buffered stream is indistinguishable from
  a working one until updates arrive minutes late. Every measure the server
  can take from its own side is taken and gated: `no-cache, no-transform`,
  `X-Accel-Buffering: no`, a `retry:` hint, a 15-second heartbeat comment,
  and a deliberate close at ten minutes so no connection lives long enough to
  rot. And if all of it fails, the poll underneath still converges.

**Not delivered, and named rather than implied:** the `Stream()` declaration
and placement-governed subscriptions — a subscription today names a shape-log
shape directly, which is safe only because the stream carries no data, and it
is the first thing phase 19 owes. The admin panel still polls: it is a
separate server with no shape log, so there is nothing there to subscribe to.
Comptoir's ticket half still polls too, and **the page says which half is
pushed and which half still asks**, because a page claiming to be reactive
everywhere and quietly not is worse than one that polls.

**Windows, decided rather than deferred — AND THE DECISION WAS OVERTAKEN
ON 2026-08-25, one day later, by deploying.** The gap was never SSE:
`HTTPConn.writeAll` used `posix.write`, which is `WriteFile` on Windows and
does not work on an overlapped socket. One expression fixed it and this
suite now runs 21/21 there. The same call is why no .NET client could POST
to this server on Windows at all. **The reading below was right about the
FACT and wrong about the CAUSE, and it is left standing rather than
rewritten, because the lesson is that a platform gap accepted on a
plausible cause stops anyone looking for the real one.** See
[VENDOR_PATCHES.md](VENDOR_PATCHES.md) and friction 5.

The reading as it stood: the vendored HTTP layer cannot
stream responses on Windows — measured three ways (`startEventStreamSync` and
`startEventStream` both answer `error.Unexpected`; `res.chunk` writes nothing
and the socket closes). The decision is **to ship without it**: a Windows page
falls back to the client's own poll and keeps working, undamaged and slower,
and the suite skips by name rather than going red. Linux and macOS, the
deployment targets, are unaffected.

**And taking that decision found the finding of the phase.** Watched from a
real browser, the Windows failure is *silent*: the connection is not refused,
`onerror` never fires, and the page holds a stream that is open and delivers
nothing for as long as the tab lives. A client retreating on errors would
have waited forever and counted zero of them. So the client retreats on a
**deadline** — no `open` frame within six seconds is a failed attempt whether
or not anyone reported one, three of those and it falls back to polling and
says so once. **This is not a Windows workaround: a buffering proxy produces
exactly the same silence**, which is the second complaint above arriving from
the other end. Verified in a browser on Windows: the page caught up on every
change made behind its back, and the console went quiet after three attempts
instead of erroring forever.

One thing found the same way and fixed: `/ringserv.js` was served with an
hour of cache, which is precisely the window in which an upgraded binary
serves a page a client it no longer ships. It now revalidates — seven
kilobytes against a symptom that would appear in someone else's page.

**Gate — passed:** 21 gates (`tests/stream-gates.js`), 21/21 on Linux,
21 owned and 0 run on Windows, skipped by name. Push measured at 24 ms from
write to event. 26 suites at the time; 27 now.

**Phase 18 is delivered, with the two exclusions named above.**

## Phase 19 — A subscription is a placed thing

Phase 18 shipped subscriptions that name a shape directly, with nothing in
between, and named that as its own exclusion. This is that exclusion closed —
and it opened on a defect found by measuring the endpoint rather than by
reading the plan.

**THE DEFECT, measured 2026-08-25 before any of this was designed.**
`GET /sync/stream?shape=nonsense` answered **200**, sent an `open` frame and
reported offset **-1**. The poll path had refused the same name `404` since
phase 8. So a page with a typo in a shape name was told it was connected and
then waited forever — *the silent failure phase 18 exists to eliminate,
reintroduced by phase 18's own front door.* Both doors now refuse from **one
function**, and the gate compares them **to each other** rather than to a
literal, because a literal drifts and an agreement cannot.

**`:stream` — three states and no fourth.** A shape can name who governs a
subscription to it:

- `:stream = "<service>"` — **you may subscribe exactly when you may call
  that service**, and the refusal is the CALL's own sentence, byte for byte.
  The sentence now lives in one function that both doors use, which is what
  makes "byte-identical" assertable rather than aspirational. A caller told
  `no` in two different sentences learns that the rule is two rules.
- `:stream = :never` — refused `403`, naming the declaration, so a reader
  knows it is a decision somebody made and stops hunting a defect.
- **absent — open, exactly as phase 18 shipped**, and this is a gate rather
  than an intention. The declaration ADDS governance; it does not switch
  streaming on. A release that quietly turned working pages off to make a
  point about declarations would teach people to fear upgrades.

**A wrong declaration is a BOOT problem.** `:stream` naming a service that
does not exist, or sitting on a table with no `:sync`, is reported by
`ringserv check` and weighed exactly as every other topology problem is —
asserted by running an ordinary bad topology beside it in the same gate, so
the two move together if the severity policy ever changes.

**One deliverable DROPPED mid-phase, by its own logic.** The plan promised
`check` would note *ungoverned* shapes. It does not, and should not: an absent
`:stream` is a supported choice, so that note would fire hardest on
applications doing nothing wrong — and a diagnostic that is usually noise is
one people learn to scroll past, which costs the ones that matter. `check`
reports a declaration that is WRONG, which is a fact rather than an opinion.

**Two defects of my own, found and fixed inside the phase, both of the same
family — a guard that fails open.** The refusal message was first duped into a
single global buffer, so two HTTP threads refused at the same moment could
have been handed each other's sentence; it is now the request's arena. And the
VM returns a JSON-encoded value, so a STRING return arrives quoted while
`__rs_sync_head`'s number arrives bare — the parse silently returned "no
refusal" for **every** shape and let the handler fall straight through to the
path it was written to guard. **A guard that fails open tests green everywhere
the thing it guards already works**, which is exactly where nobody looks.

**Gate — passed:** 17 gates (`tests/streamgov-gates.js`), 17/17 on Linux;
15 run and 2 owned-and-skipped-by-name on Windows, where only the two gates
that need an OPEN stream cannot run — the refusals are ordinary JSON and run
everywhere. Phase 18's 21 gates still green. 27 suites.

**Phase 19 is delivered.**

## Phase 20 — Deploy, redeploy, reload — without ceremony

The phase phase 13 asked for. Standing up one real deployment took an hour
and five hand-written PowerShell scripts, and **every one of them was a
thing the server should have done itself.**

```bash
ringserv deploy ./myapp --port 8210     # code here, data safely apart
ringserv redeploy myapp                 # new code, same data, live
ringserv reload --port 8210             # or just: change it, now
ringserv ls                             # what is up, asked not assumed
```

**THE SAFETY PROPERTY IS ARITHMETIC, NOT CARE.** A deployment keeps its
record in `.ringserv/`, and redeploy deletes everything *except* that. The
data is not somewhere the code change is careful to avoid — it is somewhere
the code change cannot reach. There is no flag to forget and no order to get
right at 2 a.m. Gated by writing a row, redeploying different code, and
reading the row back.

**Hot reload is a generation counter and nothing else**, which is why it can
be simple here: each worker owns its own resident VM, so no worker has to
agree with any other about when to change. Bump the counter; each worker
re-evaluates **between two jobs**, on its own thread, already alone with its
own state. A request in flight keeps the code it began under, and the HTTP
threads never learn anything happened — which is why the listener is
untouched. 62 ms for three workers, the pid unchanged, and a keep-alive
socket opened BEFORE the reload used again AFTER it.

**A worker that cannot take the new code goes back to the old one and is
COUNTED**, and the three outcomes read differently on purpose:

| | |
|---|---|
| `200` | every worker took it |
| `422` | **none** did — nothing changed, the server is untouched |
| `500` | **some** did — the server is answering with two versions |

An operator who cannot tell *nothing happened* from *half of it happened*
will treat them the same, and only one is an emergency. My first draft
called the safe case PARTIAL too; catching that by reading my own output is
the reason this table exists.

**The panel is the face of it, and the bridge had a real defect.** It used
to guess a deployment's port from its source — showing 8110 for something
deployed on 8250 — so starting from the panel would have bound the wrong
port and written the database beside the code, **where the next redeploy
deletes it**. The panel now reads the manifest and starts a deployment with
its own `--port` and `--data`. A panel that can quietly lose the record is
worse than no panel, so it is gated.

**Refused by name:** no process supervisor, no clustering, no
service-manager integration, no remote deploy. Each is a different product,
and a server that grows a supervisor grows a supervisor's failure modes.

**Gate — passed:** 47 gates across two suites — `deploy-gates.js` (30,
including the panel bridge) and `reload-gates.js` (17). 29 suites.

**Phase 20 is delivered.**

**CORRECTED 2026-08-27, two days after delivery, and the correction is the
part worth reading.** The paragraph above says a worker "re-evaluates
between two jobs" as though every worker reliably gets a job to prompt it.
It shipped with a real race hiding inside that assumption: the reload
endpoint woke workers by enqueueing one no-op job per worker into a
**single shared queue**, and nothing paired a job with a particular
worker. A fast worker could finish job 1 and go idle again *before* job 2
was even enqueued — taking that one too — leaving a slower worker with
nothing to wake it, ever. CI caught it immediately: macOS reported "2 of 3
workers took the new application" on every run from the push that shipped
this phase. It stayed unnoticed for two days because a push that reports
success invites nobody to re-open the report, and because Windows —
the only platform tested by hand — never showed it: three threads on that
machine happened to interleave often enough that each got exactly one
job, every time. That is luck, not a guarantee, and it is the same lesson
phase 4 already paid for once ("a gate that has only ever run in one
environment is a gate that has only ever tested one environment").

**The fix removes the dependency on delivery entirely**, rather than
trying to guarantee fair delivery through the queue. Every worker now
polls its own generation on a short bounded wait (`RELOAD_POLL_NS`, 50 ms)
whether or not a job ever reaches it — so correctness no longer rests on
which worker happens to grab which job. The reload endpoint's broadcast
is now only a latency optimisation for the common case (wake a sleeping
worker immediately rather than making it wait out one poll interval); a
worker that never gets the broadcast still reloads on its own within
50 ms. Reload latency is unchanged, 62–71 ms across five repeated runs on
three workers and again on eight.

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
