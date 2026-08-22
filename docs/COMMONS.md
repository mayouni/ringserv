# Hosting the Commons — five designs for a journaled, partition-tolerant server

**Status**: design, per the kit's own rule — *"Design is acceptable; vagueness is
not."* Nothing in this document is implemented yet; everything in it is specified
so the next session builds it without re-deciding it.
**Sources**: `restolean/livrable/makeen/KIT-RINGSERV-ARTICLE.md` (the article; its
laws are cited as **Law 1–6**), `restolean/commons/serveur.js` (the germ, 521
lines, read in full), `restolean/livrable/resilience/NETWORK-RESILIENCE-BRIEF.md`,
`softanza/prompts/17-zing-local-first-seam.md` §5 and
`22-partition-tolerance-placement.md`, and **this repository's own tree**.
**Date**: 2026-08-19.

---

## 0. Divergence report — read this before the designs

The kit says *"Phase 6 is still ahead of you… Run now and Phase 6 starts from
evidence; run after and it costs a rewrite."* **The tree says otherwise, and the
tree is right**: phase 6 shipped complete on 2026-08-18 (`docs/roadmap.md`) —
the shape log, `GET /sync/shape`, `POST /sync/push` with per-client exactly-once,
the convergence oracle run at both placements, and compaction on 08-19. Phases 7
and 8 shipped after it.

The consequence is not the rewrite the kit feared. Read against what exists, the
kit decomposes cleanly into three piles:

**Already built, and stronger than the germ.** The mutation queue *is*
store-and-forward with idempotency keys: a mutation's claim and its work are one
write transaction, a duplicate finds the claim taken, a **gap is refused** rather
than accepted, and a refusal rolls back its own claim (`src/ringlib/sync.ring`,
gated by `tests/sync-gates.js`). The convergence oracle already replays a seeded
adversarial interleaving with a third of all pushes retried verbatim — the germ's
Law 6 instinct, independently arrived at. `must-refetch` is already the
*replace-not-merge* instruction of Law 2, stated as a protocol control.

**Built, but the WRONG primitive for the fiscal case — the kit's sharpest
finding against this tree.** RingServ's shape log is a *sync convenience*: derived
from tables by triggers, deliberately **trimmable** (compaction moves the floor),
holding row images rather than business events. The Commons' journal is the
opposite on every axis: it is the **state itself**, hash-chained, *never*
trimmable — French anti-fraud law requires inalterability (article §1), so a
primitive whose defining feature is "the floor moves" is disqualified by
construction. **The journal is a new first-class store, not a configuration of
the shape log.** Section 1 designs it.

**Genuinely new.** The journaled store (§1), the connect-time snapshot (§2 — the
sync protocol has paging-from-zero but no authoritative snapshot event), the
two-plane bridge with merge-policy hooks (§3 — today's sync is
client-to-authority, not plane-to-plane), the host abstraction (§4), and the
partition declaration in the harness (§5 — the oracle interleaves and retries,
but cannot yet *declare a partition and heal it*).

One more divergence, small but worth the line: the kit's reading list includes
`ALIGNMENT.md` "and wherever Phase 6 currently stands" — that file records phase
6 **delivered**, both contract obligations discharged. Nothing else in the kit
contradicts the tree.

---

## 1. The journaled store — `Journal()`, a first-class primitive

> **BUILT, 2026-08-22** — `src/ringlib/journal.ring`, 28 gates in
> `tests/journal-gates.js`, written up as phase 9 in
> [roadmap.md](roadmap.md). Two divergences from the design below, both
> deliberate:
>
> - **`JournalVerify` also reports WHERE.** The design promised
>   `INTACTE`/`ROMPUE`; the implementation adds the sequence number and
>   which invariant failed, because a verdict without a location is one
>   nobody can act on.
> - **A worker catches up at the door.** The design assumed replay at boot
>   was enough. It is not, under N workers — see phase 9. The design was
>   written from a single-process germ and this is what it could not see.
>
> Still owed: `ringserv journal export` as a **CLI** subcommand. The
> function `JournalExport()` exists and the gates use it; the command-line
> ambassador named below does not exist yet.

### What it is, and what it is not

A second store beside `Data()`, not a mode of it:

```ring
Journal([
    :name   = "ventes",                  # one journal per declared name
    :events = [ :passer_commande, :faire_avancer, :annuler, :couper_produit ],
    :apply  = func aState, aEvent { … return aState }
])
```

`Data()` tables are *current state*: mutable rows, additive migration, a shape
log derived by triggers and **compactable** — none of which may touch a fiscal
record. `Journal()` is *history as the only truth*: append-only, hash-chained,
replay-to-state, **never compacted** — `SyncCompact()` refuses a journal by
name, the mirror image of it refusing a non-shape today (`tests/sync-gates.js`,
"compacting a non-shape is refused").

### The record shape and the chain

One JSONL line per event, the germ's shape kept deliberately so a Commons
journal *deverses* into a RingServ one without translation (the germ's own
stated migration plan, `serveur.js` header comment):

```json
{ "type": "passer_commande", "ts": 1755624000000,
  "prev": "a3f19c02e77d4b10", "hash": "9e02c47b11aa30f5", … }
```

- `hash = sha256(prev + canonical(event-without-hash))`, hex, as the germ does
  (`journaliser`, serveur.js:76–83). RingServ keeps the full 64 hex chars where
  the germ truncates to 16: the truncation was a display economy, not a design
  position, and a fiscal chain should not spot the auditor 48 characters.
- `prev` of the first record is `"GENESE"` — kept verbatim, so an imported germ
  journal verifies unmodified.
- **Canonical bytes are the stored bytes.** The hash is computed over the exact
  byte sequence appended, and verification re-reads those bytes; there is no
  re-serialization step anywhere, because two JSON encoders' whitespace
  disagreeing is a `ROMPUE` that never happened.

### One write path, one recovery path (Law 1)

The write path is the germ's `journaliser`, generalized and placed on RingServ's
existing machinery:

```
JournalAppend("ventes", aEvent)
  → __db_write_begin()                     — the ONE writer (docs/WRITES.md)
  → read dernierHash (in-transaction)
  → chain, append row, update head
  → __db_write_commit()
  → apply to derived state, broadcast to subscribers
```

Chain-append-apply-broadcast, in that order, exactly the germ's — but the
chain-and-append ride the single-writer transaction RingServ already built for
exactly-once (`db.zig`, `g_in_write_txn`), so two workers appending
concurrently cannot interleave their hashes. The germ never faced this (one
Node process, one thread); RingServ has N workers and **must** face it, and the
answer already exists in the tree.

Storage: a `__rs_journal_<name>` table (`seq INTEGER PRIMARY KEY AUTOINCREMENT,
ts, type, prev, hash, body TEXT`) — *inside* the same SQLite file, so the
journal and any derived `Data()` tables commit atomically, WAL protects against
torn appends, and `ringserv`'s existing backup story (copy one file) covers the
fiscal record. A JSONL export (`ringserv journal export`) preserves the germ's
interchange format; the table is the durable form, the JSONL is the ambassador.

### Derived state is replay, including the human counter

`:apply` folds events into state at boot, per worker, exactly as every worker
already evaluates the app and applies schema (`serve.zig` `workerMain`). The
germ's per-day order number is the worked case: `compteur` is **recomputed
during replay** (serveur.js:63 — `if (ev.commande.jour === etat.jour &&
ev.commande.numero > etat.compteur)`), never persisted as a counter. RingServ
adopts that as the rule: **no derived value may be stored outside the journal**;
a restart mid-service loses nothing because there is nothing outside the journal
to lose (Law 1: "order numbering survives restart because it is derived from
the journal, not from memory").

### Verification is a protocol answer

`INTACTE`/`ROMPUE` is already API in the germ (serveur.js:491). RingServ keeps
it as one:

- `GET /journal/<name>/verify` → `{ "events": n, "chain": "INTACTE" }` or
  `{ …, "chain": "ROMPUE", "at": seq }` — with **where** it broke, which the
  germ omits and an auditor needs first.
- `ringserv journal verify` — the same check from the CLI, because the box may
  be in a drawer with no client attached.
- The **convergence gates assert `INTACTE` after every partition scenario**
  (§5) — chain verification as a standing invariant, not an audit-day ritual.

### The encoding gate is the host's, not the application's

The mojibake incident (article §2) produced two laws and RingServ inherits
both at the layer each belongs to:

- **Bytes to the end, decoded once.** httpz already delivers the body as one
  byte slice — the chunk-concatenation bug that split `è` across packets cannot
  occur by construction. Recorded here so it is a stated property, and gated
  (§5's harness sends a multibyte body split across TCP writes, the germ's own
  socket-level proof re-run against this server).
- **U+FFFD is refused at the door.** A new check in `serveJob`
  (`serve.zig`): a body containing `EF BF BD` is answered
  `400 { "refus": "ENCODAGE_INVALIDE" }` before dispatch, before contracts,
  before anything. Rationale is the article's, verbatim: *"an inalterable store
  must never ingest a byte it cannot vouch for."* The refusal is a named
  machine word (Law 3), not prose.

---

## 2. The snapshot/stream protocol contract

### On connect: replace, then apply

The germ's SSE contract (Law 2, the ghost-ticket lesson) becomes RingServ's
subscription contract, layered on the existing shape/journal read path:

```
GET /subscribe?shape=ventes            (SSE)

event 1:   { "type": "snapshot", "offset": 4812, "state": { … } }
event 2…n: { "type": "delta", "offset": 4813, "event": { … } }
```

Three normative sentences, each one a bug that already happened somewhere:

1. **The snapshot replaces.** A client holding cached state discards it — all
   of it — on receipt. The protocol does not distinguish "first connect" from
   "reconnect", because a client that merges a snapshot resurrects the dead
   (the ghost ticket). This is the same ruling `must-refetch` already makes for
   the paging path (`sync.ring`, "a client below the floor… told to refetch
   rather than handed a silently incomplete history"); the snapshot extends it
   from the failure case to *every* connect.
2. **Deltas are ordered and gap-free from the snapshot's offset.** Each carries
   the offset the client must hold before applying it; a client seeing a gap
   does not guess — it reconnects, which yields a fresh snapshot (rule 1
   closes the loop).
3. **Wholeness is knowable.** The client is whole exactly when it has the
   snapshot plus every delta through the last offset received. There is no
   third state; "probably synced" is not in the protocol.

The snapshot for a `Journal()` store is the `:apply`-folded state at an offset;
for a `Data()` shape it is the row set. Both are produced under a read
transaction so the offset and the state agree.

### Probes are not faults (Law 4)

- `HEAD` is answered on every route that answers `GET` — already true for
  static files (`serve.zig`: "sonder un fichier n'est pas une faute" has an
  exact analogue in the germ at serveur.js:501); extended to `/health`,
  `/topology`, `/journal/*`.
- Probe requests are excluded from any future request log/anomaly layer *by
  method*, at the layer that writes the log — the germ's finding is that
  otherwise "the anomaly report drowned in the system watching itself."

### Instance honesty (Law 5)

`/health` today answers `{"up":true}` and nothing else. It grows:

```json
{ "up": true, "version": "0.1-dev", "build": "<git short hash, embedded>",
  "database": "fieldnotes.db", "booted": 1755624000, "pid": 4712 }
```

The tree itself paid for this law before the kit arrived: two benchmark runs
measured a **stale server** still bound to the port, answering from a different
database (`docs/WRITES.md`, "And one measurement error of my own"). The article
independently paid for it in the field (the launcher's "already running" trap).
Two payments for one lesson is enough: *which build, which data directory* is
protocol, not README. `ringserv dev` additionally probes `/health` after
restart and **refuses to report "reloaded"** if `build` did not change — the
stale-instance trap closed at the tool that creates it.

---

## 3. The two-plane sync bridge — Makeen ↔ cloud

### What the existing sync is, and why the bridge is not it

Phase 6's sync is **client-to-authority**: the server is the single authority
(C3 §2.2 — "the server re-executes; it does not merge"), clients hold
predictions. The two-plane case is different in kind: Makeen (venue) and the
cloud are **both servers, each able to live alone** (article §4), and the
fiscal journal's *original* lives on Makeen. The bridge is therefore a new
seam — but it deliberately reuses the wire shapes phase 6 already gated.

### Roles, declared not inferred

```ring
Topology([
    :app    = "cousbox",
    :plane  = :venue,                    # or :cloud
    :bridge = [
        :peer      = "https://cloud.example/api/v1",
        :journal   = "ventes",           # what crosses
        :originals = :here               # the fiscal anchor — venue only
    ]
])
```

`:originals = :here` is a **placement fact with legal weight**: exactly one
plane may declare it per journal, the manifest carries it (C3's two-surface
doctrine — a court must be able to read where the original lives), and `check`
refuses a topology where both or neither plane claims it.

### Store-and-forward, on the machinery that exists

Each plane keeps an **outbox** per peer — the client-side mutation queue phase
6 designed, applied symmetrically. Events cross with idempotency keys the
journal already provides for free: `(plane, seq)` — hash-chained sequence
numbers are idempotency keys with a signature. Delivery is the existing
`/sync/push` contract: in order, per-peer high-water mark, duplicate finds the
claim taken, **gap refused** (a hole in a fiscal chain is not a retry case, it
is a `ROMPUE` case). The SIM constraint (article §4: Wi-Fi client *or* hotspot,
never both — **a SIM is constitutive**) means the bridge must assume long
partitions as the *normal* case, which the outbox already does: it is a queue,
not a connection.

### Merge-policy hooks — both rulings expressible, neither taken

Per event class, declared where the journal is declared:

```ring
Journal([
    :name   = "ventes",
    :events = [
        :passer_commande = [ :merge = :actor ],
        :faire_avancer   = [ :merge = :actor ],
        :couper_produit  = [ :merge = :monotonic, :direction = :off_wins ]
    ]
])
```

**`:merge = :actor`** — doctrine 3 (17 §5), the default, and the only merge
the runtime performs is *none*: when the bridge heals and two planes hold
conflicting business truth (same order advanced differently, a cancellation
racing a preparation), the runtime appends a `conflit` event to the journal —
the conflict itself is journaled, because it happened — and routes it to a
service call: `serv.call("conflits.trancher", …)` awaiting a **named
operator** (Law 3: every mutation requires one). The queue of open conflicts
is a shape like any other; a kitchen display can show it. *A conflict is a
business event that needs an actor* — so it is represented as exactly what
this server already represents business events as.

**`:merge = :monotonic`** — the hook prompt 22 may or may not bless. For an
event class declared monotonic with a direction, the bridge resolves without
an actor: two `couper_produit` observations merge to the declared-winning
state (`:off_wins`: out-of-stock beats in-stock until an explicit `remettre`),
both observations still land in the journal — nothing is silently altered
(§1) — and no human is interrupted mid-rush.

**Both rulings, no code change** — the gate's requirement, met by
construction: if 22 rules that observations are actor-free, `couper_produit`
keeps `:monotonic`; if 22 rules doctrine 3 absolute, the application deletes
one line and the class falls back to `:actor`. The runtime ships both hooks
and **rules on neither** — `check` emits a warning (`RS_MERGE_UNRULED`,
C2-shaped) on any `:monotonic` declaration until 22 lands, so using the hook
before the ruling is visible, legal, and reversible.

### Human order numbers after a merge, without a coordinator

The germ derives `numero` from replay (Law 1). Two planes replaying
independently would collide. The design: **numbers are allocated per plane
from the plane's own journal, and carry the plane** — venue issues `1, 2, 3…`
bare (it is the venue; its tickets are the ones shouted across a kitchen), the
cloud plane issues `C1, C2, C3…`. Uniqueness after merge is by construction,
not negotiation; no coordinator, no ranges to exhaust, and both sequences
remain replay-derived. A merged view sorts by `ts` and displays what each
plane printed. (Rejected: disjoint numeric ranges — they need a coordinator
the moment a third plane appears; and offset/stride — a kitchen cannot shout
"order forty-seven" if forty-seven means different food on different screens.)

### Refused rather than risked

**Payment is refused across the bridge.** A payment event class may not be
declared `:monotonic`, may not be replayed onto a peer as anything but a
read-only record, and a partition-healing merge never *completes* a payment —
the bridge carries the fact that a payment happened on the plane where it
happened, and nothing else. This is the one entry of the "refused" set the
article names as known (article §4); the set is open, and membership is a
declaration (`:bridge = :never`) so the next member costs a word, not a
design.

---

## 4. The host abstraction — sized for a €200 Android box

### What the runtime asks of a host

Named as an interface, because the Commons already runs on three hosts (node,
SEA single-file, soon an Android foreground service) and RingServ's binary
will meet the same fate:

| Need | Today (desktop/server) | Makeen (Android box) |
|---|---|---|
| **Listen** on an address:port | httpz, `:host` gated by the TLS refusal | same binary; hotspot gateway address is stable *by construction* (measured twice: `10.221.160.66` — article §4) |
| **Append durably** | SQLite WAL on a real fs | app-sandbox storage; same file, path from the host |
| **Describe its interfaces** | — (gap) | `GET /api/reseau` analogue: the addresses the host serves on, feeding QR provisioning (the germ's `/api/reseau`, serveur.js:388) |
| **Survive screen-off** | n/a | the host's duty (foreground service + wake lock); the runtime's duty is only to *tolerate* clock jumps and suspended timers |
| **Say who it is** | `/health` per §2 | same — doubly vital where "reinstall the APK" is the update story |

New CLI surface: `ringserv where --net` — the interface enumeration, from the
same code `/api/reseau` will use, because provisioning by QR is how devices
that must know *only this network* (the iOS finding, article §4) get onto it.

### What the runtime must never assume

Stated as prohibitions because each was a field incident:

- **No stable public address.** The DHCP night (article §2). Anything durable
  lives behind the journal, not behind an address; clients are given the
  gateway address *because it is stable by construction*, never a leased one.
- **No filesystem outside the sandbox.** The database path comes from the
  host; the runtime never derives paths from its own location (the germ's
  RACINE dance, serveur.js:19–26, is host code — RingServ keeps it out of the
  runtime).
- **Never the only instance on the port.** Law 5. The `/health` identity check
  (§2) is the mechanism; `dev`'s refusal-to-lie is the policy.
- **No both-at-once radios.** Wi-Fi client XOR hotspot (measured, article §4).
  The bridge (§3) therefore never assumes it can reach its peer while serving
  the room unless a second path (SIM) exists — which is why the outbox is the
  primitive and the live connection is the optimization.

### Zero-dependency cost statement

The kit demands any new dependency be priced. This design adds **none**: the
journal is SQLite (vendored since phase 3), the chain is sha256 (in
`std.crypto`, already linked for the JWT seam), SSE is httpz (vendored),
the bridge speaks the existing `/sync` contract over the existing client. The
Android *host* is new engineering, but it wraps the binary; nothing enters it.

---

## 5. The partition simulator — a first-class harness

### Why the oracle is not enough

The convergence oracle (`tests/sync-gates.js`) interleaves clients and retries
pushes — transport hostility. It cannot yet say *"the network is down from
19:40 to 20:15, twice, and customers were lost in the window"* — scenario
hostility, Law 6's whole point: *"a failure you cannot replay is a failure you
cannot claim to have fixed."*

### The harness contract

A deterministic scenario runner, shipped with the server (the germ runs its
simulator *inside* the server so the SEA build has it too — same reason, same
placement):

```
ringserv sim <scenario.ring> [--seed N]
```

A scenario is Ring (it is an application file; the vocabulary is a library,
like `testing.ring`):

```ring
Sim([
    :seed = 20260803,                    # the germ's seed, kept comparable
    :planes = [ :venue, :cloud ],
    :days = [
        :thursday = func {
            Load(:evening_service)                    # generated traffic
            Partition(:venue, :cloud, from = "19:40", to = "19:52")
            LostCustomers(0.4)                        # counted, not implied
            Partition(:venue, :cloud, from = "20:30", to = "20:41")
            ReconnectBurst()                          # the pent-up rafale
            AbandonPickups(1, 30)                     # 1 in 30 never retiree
        }
    ]
])
```

Primitives, each with defined semantics rather than vibes:

- **`Partition(a, b, …)`** — the bridge between the named planes drops every
  request in the window (connection refused, not timeout — both cases exist;
  a flag selects). Simulated time, like the germ's `tsSimule`, **accepted only
  under `--sim`** (serveur.js:29 — "jamais en production"), and RingServ makes
  that structural: the sim clock hook exists only in the harness build path.
- **`LostCustomers(p)`** — traffic that would have arrived during a partition
  is dropped *and counted*, because the germ's enriched Thursday distinguishes
  lost customers from delayed ones (serveur.js, the 15-August re-enactment
  comment) and an analytics layer must see the écart.
- **`ReconnectBurst()`** — the held traffic arrives compressed at heal, which
  is the load shape that actually breaks queues.
- **`Heal()`** — implied at window end; the outbox drains, merges run through
  the §3 hooks.

### The assertions the harness owes, every run

1. **Convergence**: after final heal, both planes' journals contain the same
   event set; folded state agrees as data (the oracle's digest technique,
   reused — `sync-gates.js` `runOracle`'s `norm()` comparison).
2. **Chain integrity**: `verify` answers `INTACTE` on **both** planes — after
   partitions, merges, and the burst. The chain gate is what makes the
   simulator fiscal-grade rather than merely functional.
3. **Exactly-once across the bridge**: no event applied twice, none lost —
   lost *customers* are counted, lost *events* are a failure.
4. **Conflict accounting**: every `:actor` conflict raised during heal is
   present in the conflicts shape, none silently resolved (doctrine 3,
   asserted mechanically).
5. **Determinism**: same seed, same journals, byte-for-byte after `ts`
   normalization — the property that makes a field failure replayable at the
   desk.

### What the default deployment gets

`ringserv new` scaffolds no scenario, but `ringserv sim --builtin 5days` ships
the germ's five days — 86'd product Tuesday, midday cut Wednesday, the
double-outage Thursday, abandoned pickups, Friday rush, seed `20260803` —
ported once, kept comparable with the germ run-for-run. It is the acceptance
test for §§1–3: **the next session builds the journal, the snapshot, and the
bridge against this scenario, and the five assertions above are its gate.**

---

## Appendix — traceability

| Ruling here | Source |
|---|---|
| Journal is append-only, replay-derived, one write path | Law 1; serveur.js `journaliser`/`rejouerJournal` |
| Journal ≠ shape log; never compacted | Article §1 (fiscal inalterability) vs `docs/topology.md` §7 (compaction) |
| Chain over stored bytes, full sha256, `GENESE` kept | serveur.js:76–83; migration-by-déversement (serveur.js header) |
| Append rides the one-writer transaction | `docs/WRITES.md`; `db.zig` `g_in_write_txn` |
| Snapshot replaces, never merges | Law 2 (ghost ticket); `must-refetch` in `sync.ring` |
| Bytes decoded once; U+FFFD refused at the door | Article §2 (mojibake); serveur.js `lireCorps` |
| Named machine-word refusals | Law 3; already RingServ's envelope practice |
| HEAD answered, probes not logged | Law 4; serveur.js:501; `serve.zig` static path |
| `/health` carries build + data dir; `dev` refuses to lie | Law 5; `docs/WRITES.md` stale-server incident (paid twice) |
| Simulator ships in the server, deterministic seed | Law 6; serveur.js `lancerSimulation5Jours` |
| No CRDT / no LWW for business truth; conflict → named actor | 17 §5, doctrine 3 |
| Monotonic hook built, not ruled | Prompt 22 (pending); article §4 boundary case |
| Payment refused across the bridge | Article §4 ("refused rather than risked") |
| SIM constitutive; outbox as primitive | Article §4 measured table (Wi-Fi XOR hotspot) |
| Stable gateway by construction | Article §4 (measured twice, `10.221.160.66`) |
| Per-plane order numbers, venue bare / cloud prefixed | Law 1 (replay-derived) + no-coordinator requirement (kit item 3) |
