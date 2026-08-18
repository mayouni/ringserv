# Alignment — RingServ against the Softanza reference design

**Reference**: `softanza/REFERENCE_DESIGN.md` **v1.4** · **C3 ratified v1.0,
2026-08-12**
**This revision**: 2026-08-17, by RingServ's session (prompt 07, placement half)
**Status**: **obligations in force**, not obligations-if-ratified

> The previous revision of this file was written on 2026-08-08 against a *draft,
> unratified* v0.1, when RingServ had shipped nothing. Five phases have landed
> since and the contract was ratified. Everything below is stated against the
> tree as it actually is.

## Where RingServ sits

The **lean server placement** — and the **germ** of C3: `Topology()` is what the
Placement Contract generalized, so RingServ co-authored it rather than adopting
it. Being the germ carries one duty the other co-authors do not have: when a
claim in the contract is RingServ-shaped, only this repository can say whether
the generalization was intended.

## What has been delivered

| | |
|---|---|
| Phase 1 | resident native Ring VM · 18 bridge gates · oracle byte-exact |
| Phase 2 | services on `POST /api/v1` · both service forms · fuzz · flat-memory soak |
| Phase 3 | SQLite, `Data()` schema, plain-SQL query surface, generic services, `Contract()` |
| Phase 4 | the CLI: `new` · `dev` · `test` · `where` · static routes · cross-compiled dist |
| Phase 5 | `check` and `docs` — syntax from tree-sitter, structure from the VM |
| Since | C JSON codec (byte-identical to the pure reference), one-writer connection, VM swapped to patched Ring |

**12 gate suites green**, one command: `zig build gates -- --full`.

## The six horizontal contracts, as they stand here

### C3 — Placement · **adopted, this session**

Answered in [docs/topology.md §5](docs/topology.md), decision by decision:

- **`:both` decomposed into `site` + `authority` — adopted.** The recorded cost
  (§8.2, "a one-word change becomes two fields") does not materialise: moving a
  service is still one word, and the second field names a decision the
  application was already making silently. RingServ does not ask for a fifth
  value.
- **The two-surface split — adopted**, with one boundary recorded: RingServ is a
  *general* Ring application server, so emitting `zing.json` is something an app
  **may** do, not something it must. Family app: the manifest ships and the
  contract governs. Standalone app: `Topology()` may remain the only surface.
  **Central ruled on 2026-08-18 that this is the contract's own reading** —
  inside a Zing solution the manifest is mandatory, and what makes it mandatory
  is the solution's membership, not RingServ's discretion. The Principal
  **ratified** the jurisdiction sentence the same day (`CENTRAL-C3-JURISDICTION`,
  `contracts/placement.md` §6), so the boundary is settled law, not a position
  this repository is holding.
- **The authority mechanic — confirmed** as contract language, and since
  2026-08-17 it is also how the write path is built ([WRITES.md](docs/WRITES.md)).
- **StzZql pin — not applicable.** RingServ is not a StzZql consumer.
- **Placement case in the convergence oracle — owed**, scheduled as a phase-6
  gate.

### C2 — Diagnostic · **adopted, this session**

`ringserv check --json` emits one C2 envelope per finding —
`{code, severity, message, span{file,line}, cites[], language}` with
`language: "ringserv"`. Seven stable codes: `RS_SYNTAX_ERROR`,
`RS_SYNTAX_MISSING`, `RS_CONTRACT_UNKNOWN_SERVICE`,
`RS_CONTRACT_UNKNOWN_ACTION`, `RS_SERVICE_UNANSWERABLE`,
`RS_ACTION_UNCONTRACTED` (warning) and `RS_APP_UNEVALUABLE`.

**RingServ pins C2 v1.0**, whose normative home is
`stzzui/doc/diagnostic-contract.md` — vendored at `vendor/c2/` and gated by
`node tests/c2-gates.js` (40 gates, every code exercised, every envelope
validated against the schema *as read*, not as restated). Recording the pin is
itself a condition of conformance (§3.3); the details are in
[docs/CHECK.md](docs/CHECK.md).

Conforming exposed two real defects that the one-sentence summary could not
have: `col` was emitted as `0` on file-wide findings where the schema requires
`>= 1` when present, and `cites` carried documentation anchors where the
contract admits only stable identifiers in a pinned instrument. Both fixed —
`col` omitted, `cites` empty and honestly so, since RingServ pins no instrument
of law.

Prompt 07 asked for this *before* `check` was built; `check` shipped in phase 5
on 2026-08-14, so this was a retrofit rather than a birth. It cost one output
mode, which is the cheap version of that mistake, but the prompt was right that
earlier would have been cheaper still.

### C5 — Actor · **open, and not closed here**

RingServ must authenticate callers and issue signed principal assertions in the
same format as `stzAppServer`, so `ACTOR:` binds identically whichever host a
manifest declares. That work is co-authored and rides with Zing's Bedrock
revision (prompt 10). **Pending — recorded so it is not silently forgotten.**

### C1 · C4 · C6 — nothing owed here yet

No obligation has been stated against RingServ for the world, evolution or
commons contracts. If one arrives, it arrives through the mailbox.

## What must not change

The **service envelope** — `{service, action, payload}` → uniform
`{code, message, data}`. Zing's projection spec maps its flows onto it, and it
is the best-shaped seam in the family. Phase ordering also stands.

## Phase 6 is unblocked

Its gate was C3, and **C3 was ratified on 2026-08-12**. The previous revision of
this file held phase 6 until ratification; that hold is lifted. What phase 6 now
owes the contract, beyond its own design: the placement case in the convergence
oracle, and — for an app that is part of a Zing solution — `Topology()` emitting
`zing.json` rather than being read directly.

## Findings routed upward, not fixed here

Never edit a sibling repository. These went to Central:

1. **`stzzql`'s README lists RingServ among its expected consumers.** RingServ is
   not one, by a decision taken on 2026-08-14. That README is wrong and is not
   this session's to correct.
2. **C3 §2.1's two disputed claims are RingServ-shaped and describe an unbuilt
   design** — answered as the germ; see the memo of 2026-08-17.
3. **MicroRing's `interplay.md` still calls the device story bilateral.** It is
   the contract's now. MicroRing's own session applies that.
4. **C2 had no file in `contracts/`** — answered 2026-08-18: the normative
   specification *does* exist, at `stzzui/doc/diagnostic-contract.md` v1.0, and
   the real defect was that nothing a session reads points at it. Central adds
   the citation and a pointer file. RingServ conformed to a summary because the
   summary was what the estate showed it — which is exactly how the `col` and
   `cites` defects above got in.

Central answered all four on 2026-08-18: finding 1 adopted as written, 2 and 3
routed to their own sessions, 4 corrected and owned. Closures on 2 and 3 come
back through the mailbox; this file does not mark them closed until they do.
