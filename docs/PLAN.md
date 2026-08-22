# The plan — phases 10 and on, in service of [VISION.md](VISION.md)

**Status: a proposal to follow and adapt, not a contract.** The delivered
record lives in [roadmap.md](roadmap.md) (phases 1–9); this file is the road
ahead. Three rules keep it honest:

1. **Every phase cites the vision line it closes.** A phase that cannot is
   questioned before it is built.
2. **Every phase is gated by executable verification**, in the RingScript
   tradition — small, one commit per milestone, no phase begins until the
   previous one's gates pass. A phase whose gate cannot be written yet is not
   ready to start.
3. **The order is adjustable and the adjustments are recorded.** When reality
   reorders this file (it will), the change is made *here*, with one line
   saying why, so the plan stays the map of what we actually intend — never a
   fossil of what we once intended. Re-ordering is cheap; silent divergence is
   the only failure.

A delivered phase moves to roadmap.md with its gate results, and its entry
here shrinks to one line. The ledger in VISION.md is updated in the same
commit, so the three documents can never disagree about where we stand.

---

## The arc, in one look

| Phase | Name                          | Vision line it closes                       |
|-------|-------------------------------|---------------------------------------------|
| 10    | The gesture                   | one-gesture function→service; yaml-like forms |
| 11    | JS, honestly measured         | JS parity — modules, and the Node/Bun bar   |
| 12    | The family handshake          | zero-config symbiosis across the family     |
| 13    | RestoLean on RingServ         | born in real constraints; opens the phase-8 gate |
| 14    | The phone                     | Android as a first-class target             |
| 15    | The cloud story               | cloud scalers with real ergonomics          |
| 16    | Agent hosting, named          | agent hosting as its own gesture            |
| 17    | TypeScript                    | "and maybe TypeScript after"                |

Why this order and not another: **the gesture comes first because every later
phase demos through it** — a JS module, a discovered sibling, an agent, all of
them should be *shown* via the dead-simple gesture, so the gesture must exist
before there is anything to show. **JS comes second because it is the largest
new audience** and everything it needs (QuickJS-ng, the trampoline, async
settling) already stands. **Symbiosis precedes Android** because the phone is
worth little as an island — RestoLean's phone talks to a server, and the
handshake is what makes that a one-liner. **RestoLean sits mid-arc, not last**,
because the vision's sharpest sentence is "not a research tool, not a
beautiful toy" — the longer real usage waits, the more toy-shaped decisions
accumulate unchallenged.

---

## Phase 10 — The gesture

**Vision:** *"a didactic simplification of the complex task of transforming any
code, even a simple function, to a hosted service"* and *"yaml-like config and
file formats."* The heart of the charter, and the cheapest phase on the board.

**Deliverables.**
- **`ringserv serve <file.ring>`** — a file containing plain functions, no
  `RingServ([...])` at all, becomes a service: each public function an action,
  parameters mapped from the payload by name, return value enveloped. The
  existing declarative form stays the *precise* form; this is the *first-touch*
  form, and `ringserv new` scaffolds start from it.
- **The config-file form** — `ringserv.yaml` (a deliberately small yaml-like
  subset we parse ourselves — mappings, sequences, scalars, comments; anchors
  and the exotic rest of YAML are refused with a clear message, because
  vendoring a full YAML parser for a config file breaks the dependency ethos
  for nothing). Everything declarable in `RingServ([...])` is declarable here;
  the Ring form wins on conflict and the collision is *reported*, never
  silently resolved.
- **The didactic doc** — "from a function to a service in ninety seconds",
  gated like the guides are.

**Gate.** A file of two bare functions serves both over `/api/v1` with zero
declaration lines; the yaml form drives port/database/placement and round-trips
against the Ring form (same app declared both ways answers identically); a
config the subset refuses is refused *by name*; guide-gates hold the new doc to
its promises.

**Risk.** The function→action mapping must not become magic that lies —
`check` must be able to explain exactly what got exposed and why, or the
didactic gain is a debugging loss.

## Phase 11 — JS, honestly measured

**Vision:** *"offer JS programmers the same ease and power… the bar is NodeJS,
even Bun — not for the sake of competing."*

**Deliverables.**
- **A module story**: ES module imports between the application's own `.js`
  files, resolved relative to the app (the loader discipline learned in the
  Ring path applies verbatim — anchor by search root, never by moving the
  working directory). Explicitly *not* npm compatibility in this phase; the
  boundary is stated in the doc, with the reasoning, so nobody discovers it as
  a disappointment.
- **The WinterTC surface widened** where RestoLean-shaped applications actually
  need it (fetch to loopback services, timers, TextEncoder family, crypto
  digest — driven by real code, not by the spec's table of contents).
- **The benchmark, published like BENCHMARKS.md** — the same service written
  for RingServ-JS and Node, measured on service-shaped workloads (dispatch,
  JSON, SQLite round-trip), with the losses printed as plainly as the wins.
  The vision's bar is only meaningful if we know where we stand against it.

**Gate.** A multi-file JS app with imports runs; js-gates extended to cover the
module graph and each new surface; the benchmark document exists with numbers
on both columns and a method section; sweep and oracle stay green (`--full`).

## Phase 12 — The family handshake

**Vision:** *"the family must know each other and work seamlessly by default
and without complex configuration."* C3 placement and the device-identity
relay (microring's `docs/identity.md` §9) are the two bricks already laid.

**Deliverables.**
- **Announce and discover**: a RingServ process can announce itself (name,
  topology role, contract versions) and discover siblings on the same host and
  LAN with **zero configuration** — one primitive, boring transport (likely
  UDP beacon + the existing `/topology` endpoint as the truth), refusable by a
  single `:announce = false`.
- **The identity seam honoured**: discovery carries the device-identity
  contract's fields, custody-axis included, so a MicroRing device and a
  RingServ host recognise each other by the relayed contract rather than by a
  parallel invention. **Coordination note:** the contract has two owners
  (ringserv and zing) — the shape goes through Central before it freezes.
- **The demo that is the point**: two processes on one machine find each other
  and route a call with *no* config file, shown in the didactic docs through
  the phase-10 gesture.

**Gate.** Two fixtures discover each other and exchange a placed call with
zero lines of discovery config; `:announce = false` is silent on the wire
(gated by packet capture, not by trust); the identity fields round-trip; a
third, non-family process on the same port range is ignored, by name.

**Risk.** Discovery protocols rot into complexity. The scope fence: same
host and LAN only — cross-network topology stays C3's declared, explicit
business, and this phase does not touch it.

## Phase 13 — RestoLean on RingServ

**Vision:** *"used by my real-world applications… so you can learn from them"* —
and this is also **the phase-8 gate**, which only the author can open: one real
application of his own.

**Author-led; sessions support.** The work here is whatever RestoLean needs
and does not yet have — discovered by porting, not guessed in advance. What
can be committed to now:
- Every friction RestoLean hits becomes either a fix or a **named refusal
  with a reason** — an issue-shaped note in this repository either way. The
  friction list *is* the deliverable; it is the vision's "born in real
  constraints" made mechanical.
- The Commons journal **deverses** into a `Journal()` and verifies INTACTE —
  the migration COMMONS.md promised, executed on real fiscal data.

**Gate.** RestoLean's server side runs on RingServ in real use (the author's
judgement, not a test's); the imported journal verifies; the friction list is
in the tree with every entry dispositioned.

**Placement note.** This phase can and should *interleave* with 11–12 rather
than strictly follow them — it is listed here because its gate depends on the
gesture existing, not because everything before it must finish first.

## Phase 14 — The phone

**Vision:** *"even on an Android phone (see what we've done in RestoLean)."*

**Deliverables.** RingServ built for `aarch64-linux-android` (Zig makes the
cross-compile the easy half); the SQLite/WAL and file-layer assumptions
verified on Android's filesystem reality; RestoLean's existing Android
experience mined *first* — the phase opens by reading what RestoLean did, and
its findings file names what transfers and what does not. Served from Termux
or equivalent first; a packaged story only if real use demands it.

**Gate.** The binary runs a fixture app on a physical Android device with the
test suites' core subset green on-device; the journal survives an on-device
kill mid-append (the phone is where power loss is normal, which is exactly the
journal's promise); a written account of what differs on Android, in the tree.

**Dependency, honestly.** Requires hardware in hand and RestoLean's Android
notes accessible. If either is missing when its turn comes, the phase swaps
with 15 rather than blocking the arc — rule 3 above.

## Phase 15 — The cloud story

**Vision:** *"normal server, cloud scalers…"* Cross-compilation is proven;
what is missing is everything after the binary exists.

**Deliverables.** One deployment document in the didactic register — a
container image measured in tens of megabytes (static binary + SQLite file,
nothing else), health/readiness the schedulers expect (`/health` exists;
readiness semantics defined), graceful drain on SIGTERM (the journal's
catch-up discipline makes this cheap), and the backup story stated as
operations (copy one file — but *when*, and verified *how*: `ringserv journal
verify` as the restore test). A worked deploy on one real, cheap target
(Fly.io or equivalent), kept honest the way fieldnotes-app is.

**Gate.** The container builds from a committed Dockerfile at the stated size;
kill-during-load drains without a failed request in the gate's window; a
backup taken mid-load restores and verifies INTACTE; the deploy doc's commands
are gated like the guides.

## Phase 16 — Agent hosting, named

**Vision:** *"Ring applications, web services, and agent hosting."* Last of
the named capabilities because it should *compose* the others rather than
invent: an agent is a service with a loop, state, and outbound calls — the
gesture (10), JS (11), and the journal already carry most of it.

**Deliverables.** A declarative `:agents` form — schedule or trigger, the
work function, state that survives restart (journal-backed, so an agent's
history is inspectable and inalterable by construction); outbound `fetch`
from agents under an explicit allowlist, because an agent that can call
anywhere by default is a liability shipped as a feature. The didactic doc
shows one real agent doing something worth doing.

**Gate.** An agent declared in five lines runs on schedule, journals its
runs, survives a kill mid-run without double-acting (the exactly-once
machinery, reused), and is refused outbound calls off its allowlist — by name.

**Honest caveat.** This phase is scoped at the *hosting* layer — scheduling,
state, restart, refusals. What intelligence runs inside the loop is the
application's business, not RingServ's.

## Phase 17 — TypeScript

**Vision:** *"and maybe TypeScript after"* — the author's own "maybe" keeps
this last and keeps it lean: type-stripping on load (the erasable subset, the
direction Node itself took), not a bundled compiler; `check` reports what was
stripped so the boundary is visible. Full `tsc` semantics are a stated
refusal, with the dependency cost named.

**Gate.** A `.ts` service file runs unmodified for the erasable subset; a
construct outside the subset is refused with the construct's name and the
reason; js-gates extended.

---

## Standing alongside the phases, not inside them

- **The phase-8 platform gate** (scaffold tested on non-Windows targets)
  closes naturally inside phases 14–15, which put real non-Windows platforms
  in hand — noted so it is not forgotten, per the roadmap.
- **Symbiosis is never "done."** Phase 12 builds the handshake; every later
  phase that adds a surface owes that surface to the handshake's vocabulary.
- **The didactic debt rule**: any phase that ships a capability without its
  didactic doc has not shipped — the vision makes documentation quality part
  of the product, so the gate lists carry it explicitly.

## Change log

*Reorderings and scope changes land here, one line each, newest first.*

- 2026-08-22 — plan created; order proposed by the session, adoption and
  reordering the author's.
