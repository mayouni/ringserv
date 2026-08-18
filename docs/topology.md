# Topology — one application, declared placements

*The fullstack heart of the RingScript + RingServ model: services and
data are declared once; a topology file decides where each lives. From
99 % local-first to thin client, the application code does not change.*

## 1. The declaration

```ring
# topology.ring — deployment truth, separate from application truth

Topology([
    :app = "fieldnotes",

    :data = [
        :notes = [ :store = :local,  :sync = :onreconnect ],
        :tags  = [ :store = :local,  :sync = :live ],
        :users = [ :store = :server ]
    ],

    :services = [
        :notes  = [ :site = :local ],                        # runs in the page
        :tags   = [ :site = :local, :authority = :server ],  # predict here, decide there
        :report = [ :site = :server ],                       # heavy work stays on RingServ
        :users  = [ :site = :server ]
    ]
])
```

These are **C3's** names, not RingServ's private ones — see
"Adopting the contract" below for what changed and why.

- `:local` — the service's Ring code ships to the page and runs in
  RingScript against the local store. The server may never see a call.
- `:server` — `serv.call("report.build", …)` from the page becomes a
  wire call to `/api/v1`; the page carries no implementation.
- `:site = :local, :authority = :server` — the code runs locally
  against synced data, and the server runs the same code as the
  authority on writes. This was one word, `:both`, until C3; see below
  for why two fields are the better shape.

The seam is uniform: **`serv.call("service.action", payload)`
everywhere**. The topology compiles the seam — it decides, per
service, whether that call is a local function dispatch or a fetch.
Moving `:report` from `:local` to `:server` is a one-word deployment
decision, not a refactor.

## 2. Scenarios as one-liners

| Scenario | Topology |
|---|---|
| 99 % offline, sync on reconnect | all data `:local :sync=:onreconnect`, all services `:local` |
| Classic SPA + API | all data `:server`, all services `:server` |
| Instant reads, safe writes | data `:local :sync=:live`, services `:site=:local :authority=:server` |
| Heavy compute offloaded | everything local except `:report = :server` |

## 3. The sync protocol — deliberately boring

The study of the local-first field ([landscape.md](landscape.md))
yields a clear minimal design, and RingServ adopts it rather than
inventing one:

**Read path — shapes over HTTP** (ElectricSQL's model, the simplest
respectable one):

- A **shape** is a declared subset of data: a table, optionally
  filtered (`:notes` where `owner = me`). Each `:sync`'d entry in the
  topology defines one.
- The server keeps an append-only **shape log**: ordered operations
  (`insert`/`update`/`delete` + row) with monotonic **offsets**,
  stored in SQLite like everything else.
- The client (RingScript's store) reads
  `GET /sync/shape?name=notes&offset=N`, pages until `up-to-date`,
  then long-polls (or SSE) with `live=true` for changes. Plain HTTP:
  cacheable, proxy-friendly, resumable from any offset, and a
  `must-refetch` control message covers compaction.

**Write path — an idempotent mutation queue** (Replicache's model):

- Offline writes append to a local queue:
  `{ client_id, mutation_id, service, action, payload }` — note that
  a mutation *is a service call*; the model needs no second
  vocabulary.
- On reconnection the queue is POSTed in order; the server executes
  each action **authoritatively** (contracts enforced, locally-predicted
  services re-run server-side), records `last_mutation_id` per client
  for exactly-once, and the results flow back to the client *through
  the shape log* — there is no second response channel to reconcile.
- The client rebases: server state + replay of still-unacked local
  mutations. Conflicts resolve by re-execution against fresh state —
  the authority is the server-run action, not a merge heuristic.

**The call seam binds the two sides.** The page queries its synced
store with whatever its runtime provides; the server queries SQLite
in SQL. The *shared* vocabulary is the service call and the shape —
not a query dialect, because RingServ's core deliberately has none
(see [vision.md](vision.md)). A stack that wants one query language
across page and server gets it by loading the same pure-Ring query
library on both sides — that is a framework's promise to make, and
Softanza is where it belongs.

## 4. What the server must implement (and nothing more)

1. Shape declaration → log maintenance (triggers on writes, offsets,
   compaction with `must-refetch`).
2. `GET /sync/shape` — paged reads + long-poll/SSE liveness.
3. `POST /sync/push` — ordered, idempotent mutation execution with
   per-client high-water marks.
4. That's all. No CRDTs, no vector clocks, no bespoke binary
   protocol. (CRDT-based merging — the CR-SQLite/Automerge road — is
   explicitly out of scope until an authoritative-server model proves
   insufficient for real applications.)

## 5. Adopting the contract — what changed, and what RingServ answered

`Topology()` is the **germ** of the family's Placement Contract
([C3](https://github.com/mayouni/softanza/blob/main/contracts/placement.md),
ratified v1.0 on 2026-08-12): the contract generalized what this file
had, so RingServ is a co-author rather than an adopter. C3's checklist
asked this repository five questions. Answered here, in order.

**1. `:both` → `site` + `authority`. Adopted.** The contract decomposed
RingServ's fifth value into `site: local` plus `authority: server`, on
the ground that `:both` describes a *relationship* between two
placements rather than a third place. That is right, and the
decomposition is faithful: `:both` always meant exactly "predict here,
decide there", with the second half hidden inside the word.

The recorded cost was that "a one-word deployment change becomes two
fields" (§8.2). Measured against this file, that cost does not
materialise: moving a service between page and server is still one word
— `:site` — and the second field appears only when an application wants
an authority, which is a second decision it was always making silently.
**RingServ does not ask for a fifth value.**

**2. The two-surface split. Adopted, with one boundary recorded.**
`Topology()` is the **builder** — Ring, authored by hand; `zing.json` is
the **artifact** — what ships and what any court reads. RingServ gives
up only the claim that `topology.ring` is what ships, and the polyglot
argument for it is sound: a Zig court or a Zen frontend cannot read Ring,
and deployment truth they cannot read is deployment truth they cannot
check.

The boundary, recorded rather than resisted: **RingServ is a general
Ring application server**, usable by someone who has never heard of Zing.
Emitting a manifest is therefore something a RingServ app *may* do, not
something it *must* do. For an application that is part of a Zing
solution, `zing.json` is the artifact and the contract governs. For a
standalone RingServ application, `Topology()` may remain the only
surface — and then RingServ is the only consumer, which is precisely the
case §6 grants was "right when RingServ was the only reader". The
two-surface doctrine is adopted for the family case; it is not adopted
as a requirement that every RingServ app join the family.

**Central ruled on 2026-08-18 that this boundary is the contract's own
reading**, on three grounds worth keeping: the contract's argument in §6 is
about *readers*, and where no second reader exists the reason for the
manifest does not exist either; requiring it everywhere would reintroduce
the framework-into-the-floor inversion that the ZQL removal settled on
2026-08-14, through a different door; and MAY→MUST is the reversible
direction, while MUST→MAY would mean removing a Zing dependency from
scaffolds already generated in repositories nobody can reach. Inside a Zing
solution the manifest is **not** optional — and what makes it mandatory is
the solution's membership, never RingServ's discretion. The jurisdiction
sentence now stands in [placement.md §6](https://github.com/mayouni/softanza/blob/main/contracts/placement.md),
**ratified by the Principal on 2026-08-18** (`CENTRAL-C3-JURISDICTION`), so
this is settled law rather than a boundary held pending a ruling. Phase 6
builds on it.

**3. The authority mechanic. Confirmed as contract language.** §2.2 took
it from this file and it is exact: the server **re-executes** the action;
it does not merge a result. Since 2026-08-17 that is also how the write
path is built — every write goes through one connection and the action
runs there ([WRITES.md](WRITES.md)), so "the authority is the server-run
action" is now a property of the implementation, not only of the design.

**4. Pin StzZql. Not applicable — RingServ is not a StzZql consumer.**
Settled on 2026-08-14 by removal: this core carries no framework query
dialect and speaks plain SQL over SQLite ([DATA.md](DATA.md)). There is
no grammar here to pin. Reported upward, because `stzzql`'s README still
lists RingServ among its expected consumers.

**5. A placement case in the convergence oracle. Paid in full, 2026-08-18.**
Twice over. *Online*: `tests/fixtures/move-app.ring` runs under
`:site = :server` and under `:site = :local, :authority = :server` with **no
application code different between them**, and the two runs are compared as
data — create, get, update, list, delete, an aggregate and a contract
violation must all answer identically. *Offline*: the convergence oracle
itself runs at both placements, with the same clients, the same seed and
therefore the same interleaving, and the final states must match. That is
the harder half, because it is the one where a placement difference would
actually hide.

### `:device` and `:shadow` are the contract's, not a bilateral deal

MicroRing's `interplay.md` describes the device story as an agreement
between that repository and this one. It is not — not since C3 was
ratified on 2026-08-12: `:device` is one of the contract's four
sites and `:shadow` stays a **data-store mode** under `data.store`,
which is where MicroRing's own example put it. RingServ implements the
server half **from the contract**. If MicroRing's session decides
otherwise for `:shadow` (§8.3 leaves that to it), the contract changes
and this file follows it — not the other way round.

That correction belongs in MicroRing's file too, and this session did
not make it: never edit a sibling repository. It is routed to Central
instead, for MicroRing's own session to apply.

## 6. What is built, and what the runtime holds to

Shipped 2026-08-18, the placement half of phase 6. The sync half (§3, §4)
is still design.

**`Topology()` is a declaration, not a compiler.** It stores the map; the
server publishes and enforces it; the *page* compiles `serv.call` into a
local dispatch or a fetch by reading it. Putting the compiler on this side
would put it on the wrong side of the wire.

**`GET /topology`** publishes exactly what a page needs to do that
compiling — each service's `site`, `authority` and, decisively,
`answerable` — plus each synced table's `store` and `sync`. It is a GET
because it states a fact about the deployment rather than asking for work.

**Placement is enforced at the door**, beside contracts and for the same
reason: a deployment declaration the runtime does not hold to is a comment.

| Declared | A wire call to it |
|---|---|
| `:site = :server` | answered |
| `:site = :local`, `:authority = :server` | **answered** — predicted in the page, decided here |
| `:site = :local` | **refused, 501** — it runs in the page and nowhere else |
| `:site = :device` | refused, 501 — routing is phase 7 |
| not in the topology | answered, as before phase 6 existed |

The refusal is **501, not 404**: the service exists, and this is a truthful
statement about what this host implements. 404 would be a lie with a number
in it, and 421 invites HTTP/2 clients to retry. The message names where to
call it instead *and* the one word that would make it answerable here.

**`ringserv topology`** prints the map; **`--emit`** writes `zing.json`.
Three rules, all from the contract rather than from taste:

- It emits **only `placement`**. `solution`, `governance` and `targets` are
  Zing's — a build decision and a deployment decision are different fields
  (C3 §4.1) — so an existing manifest is *edited*, and a manifest that is
  not valid JSON is refused rather than overwritten.
- It **refuses when the app declares no `:solution`**, saying so plainly and
  exiting 0. That is the ratified jurisdiction sentence made executable: a
  standalone RingServ app owes no manifest, and reporting the absence as a
  failure would push people to claim membership they do not have.
- It never runs at request time. The builder authors, the artifact ships.

`ringserv check` reports placement defects as C2 envelopes over five codes
(`RS_TOPOLOGY_UNKNOWN_SITE`, `_UNKNOWN_SERVICE`, `_UNKNOWN_STORE`,
`_UNKNOWN_SYNC`, `_SYNC_WITHOUT_LOCAL`, `_AUTHORITY_NOT_SERVER`,
`_NO_SITE` as the one warning). The verdicts are computed in
`topology.ring`, where the vocabulary lives; `check` only carries them out.
Two places deciding what a bad placement is would eventually disagree.

## 7. What the sync half is, as built

Shipped 2026-08-18. The protocol is the one §3 describes, with three
decisions the design did not have to make and the implementation did.

**The log is kept by triggers, not by application code.** A log maintained
by whatever remembers to maintain it is wrong exactly when it matters — a
hand-written `DataExec`, a cascade, a path nobody has thought of yet. The
`json_object(...)` is built from the *live* columns, so a table that gains
one through additive migration logs it without anyone rewriting a trigger.

**Triggers are created before the old generation is dropped, never after.**
This was found by a gate, not by reasoning. `DROP` then `CREATE` leaves a
window with no trigger, and every worker re-runs the install at boot while
the server is *already serving* — `/health` answers as soon as the first
worker is up. A write landing in another worker's window is a write missing
from the log forever, which is the quietest corruption a local-first system
has. So the column set is stamped into the trigger name, the new generation
is created with `IF NOT EXISTS`, and only then is the stale one dropped.

**Exactly-once is a property of the database, not of the control flow.**
`__db_write_begin/commit/rollback` hold the single writer for a whole
transaction, so a mutation's *claim* and its *work* are one commit. Three
consequences, each gated:

- a duplicate finds the claim taken and does nothing;
- a **gap is refused** — accepting mutation 5 while 4 has never arrived
  would strand 4 forever, since it would return, land under the mark, and
  be discarded as a duplicate it never was;
- a **refusal rolls back its own claim**, so the client may fix the payload
  and resend *the same id*. Keeping the claim would turn a validation error
  into permanent data loss. The rest of that batch is reported
  `not-attempted` rather than pushed past.

The long poll waits on an **HTTP thread**, not a VM worker: parking a
worker for twenty seconds would take a share of the server's capacity out
of service per waiting client. It asks the VM only for the shape's head
offset, which is one indexed `max()`.

**What is not built:** compaction. The floor table and the `must-refetch`
control exist and are honoured, so a client below the floor is told the
truth; nothing yet moves the floor. That is phase 8's, and it is recorded
rather than implied.

## 8. Verification

The sync suite is a **convergence oracle**: N simulated clients apply
random interleavings of offline mutations, connections drop and
resume at hostile moments, and the gate asserts a single final state
equal on all sides plus exactly-once execution of every mutation.
This suite exists before the protocol is trusted with an application
— the RingScript discipline, applied to distribution.
