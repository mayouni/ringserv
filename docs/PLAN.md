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
| 13    | Comptoir, run for real        | born in real constraints; opens the phase-8 gate |
| 14    | The phone                     | Android as a first-class target             |
| 15    | The cloud story               | cloud scalers with real ergonomics          |
| ~~18~~ | ~~Pages that react~~ *(delivered 2026-08-24)* | the unified model, felt: pushed updates |
| 16    | Agent hosting, named          | agent hosting as its own gesture            |
| 17    | TypeScript                    | "and maybe TypeScript after"                |

Why this order and not another: **the gesture comes first because every later
phase demos through it** — a JS module, a discovered sibling, an agent, all of
them should be *shown* via the dead-simple gesture, so the gesture must exist
before there is anything to show. **JS comes second because it is the largest
new audience** and everything it needs (QuickJS-ng, the trampoline, async
settling) already stands. **Symbiosis precedes Android** because the phone is
worth little as an island — a field counter's phone talks to a server, and the
handshake is what makes that a one-liner. **real usage sits mid-arc, not last**,
because the vision's sharpest sentence is "not a research tool, not a
beautiful toy" — the longer real usage waits, the more toy-shaped decisions
accumulate unchallenged.

**Phase 18 was added on 2026-08-24, out of numeric order and above 16 and 17
deliberately.** It is numbered last because the plan's numbers are birth
order, not priority; it is *placed* after 15 because it is the phase that
makes the RingScript pairing FELT rather than merely correct. A page that
polls every two seconds is a page whose author has to think about polling;
a page that is told when something changed is the promise the unified model
has been making since VISION.md. Agent hosting and TypeScript are both worth
building and neither changes how the pairing feels.

---

## Phase 10 — The gesture ✅ (delivered 2026-08-22)

Delivered the day the plan was adopted; the record is in
[roadmap.md](roadmap.md). `ringserv serve`, `--explain`, `new --gesture`,
`ringserv.yaml` with refusals by name, 41 gates. One scope note recorded in
the change log below.

## Phase 11 — JS, honestly measured ✅ (delivered 2026-08-23)

The record is in [roadmap.md](roadmap.md). ES modules with the sandbox
intact (Ring walks the graph; the guest still has no filesystem),
`crypto.subtle.digest` and only digest, and the Node comparison
published losses-first in [BENCHMARKS.md](BENCHMARKS.md). One scoping
note in the change log.

## Phase 12 — The family handshake ✅ (delivered 2026-08-23)

The record is in [roadmap.md](roadmap.md); the doc is
[FAMILY.md](FAMILY.md). Zero-config discovery on host+LAN, the placed
call by name, refusal by absence (packet-captured), the identity fields
carried provisionally pending Central's PLAN-HANDSHAKE-12 answer.

## Phase 13 — Comptoir, run for real

**Vision:** *"used by my real-world applications… so you can learn from
them"* — and this is also **the phase-8 gate**, which only the author can
open: one real application of his own.

**The naming rule, set 2026-08-23:** the author's customer applications
are proprietary and stay out of this open repository entirely — no names,
no paths, no data. The open stand-in is **[Comptoir](../examples/comptoir)**,
built as the same shape in the open, and this phase takes it from
reference grade to run-for-real grade. Where the author's real usage
teaches something, the lesson arrives here as a friction entry or a
feature — never as the customer's name.

**Deliverables.**
- **The interchange import.** `ringserv journal import` accepts the
  JSONL interchange format — including its **legacy truncated-hash
  dialect** (16-hex chains over the stored bytes) — verifying the chain
  as written, so a journal born elsewhere deverses into a `Journal()`
  and answers `INTACTE` unmodified. Gated with synthesized fixtures
  generated by the same algorithm; customer data never enters the tree.
- **The friction list as a practice.** `docs/FRICTIONS.md`: every
  friction real usage hits becomes a fix or a named refusal with a
  reason, each entry dispositioned. The list is the deliverable.
- Whatever real use demands next — discovered by running, not guessed.

**Gate.** The author's judgement that a real counter runs on it (his to
give, phase 8's gate); an imported legacy journal verifies `INTACTE` and
a tampered one answers `ROMPUE` at the right entry; the friction list
exists with every entry dispositioned.

**Placement note.** Interleaves with 14–15 rather than blocking them.

**Progress, 2026-08-23:** the session-side deliverables are built —
`ringserv journal import` with the legacy dialect (verify-before-write,
byte-identical round-trip, native appends continuing an imported chain;
9 gates) and [FRICTIONS.md](FRICTIONS.md) opened with its first three
entries dispositioned. The gate that closes the phase — a real counter
running on it — remains the author's to give.

## Phase 14 — The phone

**Vision:** *"even on an Android phone"* — proven in the field by a prior
application of the author's.

**Deliverables.** RingServ built for `aarch64-linux-android` (Zig makes the
cross-compile the easy half); the SQLite/WAL and file-layer assumptions
verified on Android's filesystem reality; the author's prior Android field experience mined *first*, its findings
filed as what transfers and what does not. Served from Termux
or equivalent first; a packaged story only if real use demands it.

**Gate.** The binary runs a fixture app on a physical Android device with the
test suites' core subset green on-device; the journal survives an on-device
kill mid-append (the phone is where power loss is normal, which is exactly the
journal's promise); a written account of what differs on Android, in the tree.

**Dependency, honestly.** Requires hardware in hand and the author's prior
Android notes accessible. If either is missing when its turn comes, the phase swaps
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

## Phase 18 — Pages that react

> **DELIVERED 2026-08-24**, with two exclusions named rather than implied:
> the `Stream()` declaration and placement-governed subscriptions did not
> ship — a subscription names a shape-log shape directly, which is safe only
> because the stream carries no data, and it is what phase 19 owes first.
> The admin panel still polls (a separate server, no shape log). And the
> vendored HTTP layer cannot stream on Windows, measured three ways: the
> decision taken is to ship without it, because the client falls back to its
> own poll and the page keeps working. The full account, including the two
> standing SSE complaints and what answers them here, is in
> [roadmap.md](roadmap.md) and [STREAM.md](STREAM.md).


**Vision:** the unified model made *felt* — "the same call shape on both
sides" is already true, but today a page learns that something changed by
asking again. Comptoir's counter polls every 2.5 s and the admin panel every
1.5 s; both are evidence, not implementation details.

**What already exists, which is why this phase is small.** The hard
semantics are built and gated: the shape log with ordered offsets,
`must-refetch` for a client that has been away too long, exactly-once
mutations, and a **long poll** (`/sync/shape?live=true`) that parks on an
HTTP thread rather than a VM worker — with the reason in the code, since
parking a worker for 20 seconds costs a twelfth of the server's capacity per
waiting client. `vendor/websocket/` is already compiled in via httpz. What
is missing is a push transport and a one-line client helper.

**Deliverables.**
- **`GET /sync/stream` — Server-Sent Events**, not WebSocket, and the
  reasons are specific to this project rather than to fashion:
  - *The flow is one-way.* Writes already go through `POST /sync/push` with
    exactly-once semantics. A bidirectional transport invites a second write
    path, and a second write path is how exactly-once quietly dies.
  - *SSE is plain HTTP.* RingServ **mandates** a reverse proxy for TLS
    (docs/TLS.md), and every proxy passes SSE untouched while WebSocket
    upgrade needs explicit configuration in each one. Our own deployment
    rule argues for SSE.
  - *`Last-Event-ID` IS our offset.* The browser reconnects by itself and
    says where it stopped; that maps onto the shape-log offset exactly, so
    reconnection is nearly free rather than a feature to build.
  - *It is the shape the field application already proved* — its kitchen
    display ran on SSE with a broadcast to a set of subscribers.
- **OFFSETS ARE PUSHED, NEVER PAYLOADS.** The event says *shape `menu`
  advanced to 47*; the client fetches through the `/sync/shape` path it
  already uses. Two consequences earn the constraint: one code path for data
  (the one with paging and `must-refetch`), and **a dropped notification
  costs latency, never correctness** — the existing poll still converges.
  That property is what makes this safe to ship at 0.9.
- **`Stream()` as a declaration** and `serv.subscribe("orders")` in the
  page, so a RingScript or JS page opts in with one line. **Placement
  governs subscriptions exactly as it governs calls**: a page may not
  subscribe to a stream it would be refused for calling.
- **Comptoir and the panel stop polling**, which is the demo.

**Gate.** A page receives a pushed offset within one second of a write; a
client killed mid-stream reconnects with `Last-Event-ID` and misses nothing;
a subscription the topology refuses is refused with the same message the
call would give; a stream cap is enforced and the refusal names it; killing
the stream entirely leaves the application *correct but slower*, proven by
running the whole comptoir suite with streaming disabled.

**Risks, named now.** One held-open connection per browser tab, so a cap and
a named refusal are part of the phase rather than a follow-up. Dead peers
need a heartbeat. And SSE over HTTP/1.1 shares the browser's six-connection
limit per origin — worth stating in the doc, since a page with several
streams will otherwise mystify someone.

**Kept in reserve, deliberately: WebSocket.** It is already vendored, so the
day a genuinely bidirectional case arrives — a collaborative editor, a shared
terminal, live cursors — it costs a feature and not a dependency. Offering it
by default now would be buying a harder transport for a one-way problem.

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

- 2026-08-24 — **phase 18 added, and placed above 16 and 17**: pushed
  reactive updates to RingScript and JS pages, on the author's proposal.
  Numbered last because the numbers are birth order; ranked here because it
  is what makes the unified model felt rather than merely correct. SSE
  chosen over WebSocket for four project-specific reasons (one-way flow, the
  proxy mandate, Last-Event-ID mapping onto our offset, and the field
  precedent); WebSocket stays vendored and in reserve for a genuinely
  bidirectional case.

- 2026-08-23 — the author's ruling: customer applications are proprietary
  and stay out of this open repository entirely — no names, no paths, no
  data. Phase 13 renamed from the customer's name to "Comptoir, run for
  real"; every public mention scrubbed to neutral wording; lessons from
  real usage arrive as frictions or features, never as the customer.

- 2026-08-23 — PLAN-HANDSHAKE-12 **answered and closed**: zing asked for
  no field added, removed or renamed, so the beacon shape stopped being
  provisional without a wire change. Their one behavioural note — the
  custody set is closed at v1, an unrecognised value is not higher — is
  now contract text in FAMILY.md and in family.zig's header.
- 2026-08-23 — phase 12 delivered. The beacon shape was routed for
  cross-project review before freezing (identity co-owned with zing).

- 2026-08-23 — phase 11 delivered. Scoping: the WinterTC widening was
  digest (+ modules) rather than the full fetch/timers list sketched —
  atob/btoa already existed, and nothing counter-shaped asked for the
  rest yet; the door widens by need, not by list.

- 2026-08-22 — **two standing rules from the author**, recorded where the
  plan lives: (1) every delivered phase closes with an INTERACTIVE example
  the author can drive in the browser — a gate on communication, not only
  on code; (2) RingServ carries an ADMIN PANEL — start/stop the server and
  its hosted apps, see their work, one place. The panel shipped the same
  day (`ringserv panel`, docs/panel.md, 22 gates) as an unnumbered
  deliverable between phases 10 and 11: it is operations surface, not a
  vision-ledger line, and waiting would have made every later phase's demo
  poorer.
- 2026-08-22 — phase 10 delivered. One scoping against its own text: the
  default `ringserv new` scaffold is unchanged (the page calling its own
  services is the fullstack moment, worth keeping first); the gesture gets
  `new --gesture` instead. And the yaml form covers configuration keys only
  — code (`services:`, `data:`) is refused toward the application file,
  because a function in a config file is a program pretending to be data.

- 2026-08-22 — **adopted as-is by the author**; phase 10 started the same day.
- 2026-08-22 — plan created; order proposed by the session, adoption and
  reordering the author's.
