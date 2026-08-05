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
        :notes  = :local,      # runs in the page (RingScript wasm VM)
        :tags   = :both,       # local for reads, server is authority
        :report = :server,     # heavy work stays on RingServ
        :users  = :server
    ]
])
```

- `:local` — the service's Ring code ships to the page and runs in
  RingScript against the local store. The server may never see a call.
- `:server` — `serv.call("report.build", …)` from the page becomes a
  wire call to `/api/v1`; the page carries no implementation.
- `:both` — the code runs locally against synced data; the server
  runs the same code as the authority on writes.

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
| Instant reads, safe writes | data `:local :sync=:live`, services `:both` |
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
  each action **authoritatively** (contracts enforced, `:both`
  services re-run server-side), records `last_mutation_id` per client
  for exactly-once, and the results flow back to the client *through
  the shape log* — there is no second response channel to reconcile.
- The client rebases: server state + replay of still-unacked local
  mutations. Conflicts resolve by re-execution against fresh state —
  the authority is the server-run action, not a merge heuristic.

**ZQL binds the two sides.** The page queries its synced store in
ZQL (via `stzZql`, already shipping in RingScript); the server
queries SQLite in ZQL. One data language, one service language, one
call seam — the whole stack in Ring.

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

## 5. Verification

The sync suite is a **convergence oracle**: N simulated clients apply
random interleavings of offline mutations, connections drop and
resume at hostile moments, and the gate asserts a single final state
equal on all sides plus exactly-once execution of every mutation.
This suite exists before the protocol is trusted with an application
— the RingScript discipline, applied to distribution.
