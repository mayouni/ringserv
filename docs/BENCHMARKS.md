# Benchmarks — with the method beside them

*Phase 8. Numbers are worthless without the method that produced them, so
the method is here and the measuring program is `tests/bench.js`. Run it
yourself: `node tests/bench.js 200`.*

## The machine and the shape

| | |
|---|---|
| CPU | 12 logical cores |
| OS | Windows 11 |
| Build | `zig build` (ReleaseFast) |
| Workers | 4 VM workers |
| Database | SQLite on disk, WAL, one shared writer |
| Client | node 22 `fetch`, same machine |

**Same machine, loopback.** That removes the network and flatters latency;
it also removes a variable nobody can reproduce. Numbers over a real
network are a deployment's to measure, not this document's to guess.

## Latency, one request at a time

200 operations each, 20 more discarded as warmup. **p50/p90/p99, never a
mean** — a mean over a distribution with a tail describes nobody's
experience, and `docs/WRITES.md` records the day a 20-sample mean moved
2 ms because of a single outlier.

| operation | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|
| `/health` (no VM at all) | 0.24 | 0.53 | 1.50 | 1.71 |
| dispatch, empty service | 0.81 | 1.06 | 1.57 | 2.57 |
| list, limit 50 | 1.09 | 1.35 | 1.93 | 2.47 |
| list, limit 500 | 4.15 | 5.46 | 7.05 | 7.36 |
| dispatch, **JS** service | 0.62 | 0.88 | 1.41 | 2.10 |
| JS service calling a Ring service | 0.78 | 1.08 | 2.08 | 2.38 |

*Re-measured 2026-08-26 on a busier machine than the 2026-08-19 run: the
`/health` floor and the write rows are unchanged within noise, and the
rows above moved for the reasons in the next section. The 08-19 figures
are kept in git rather than quietly overwritten.*

Milliseconds. Boot to first `/health`: **228 ms**.

### What those numbers say

- **The VM is not the cost.** An empty dispatch is 0.75 ms against a
  0.26 ms floor for a route that never enters Ring, so a full round trip
  through a resident VM costs about half a millisecond.
- **A write costs about a read.** 0.94 vs 0.78 ms. That is the
  one-writer connection of 2026-08-17 still holding: before it, a create
  cost **10.13 ms** on this same path (`docs/WRITES.md`).
- **The JS guest is not slower.** 0.69 ms against Ring's 0.75 — within
  noise, and unsurprising once both are resident. Nobody should choose a
  guest language here for speed.
- **`serv.call` from JS costs about one extra dispatch.** 0.87 vs
  0.69 ms, which is what the trampoline should cost: it *is* one more
  dispatch.
- **Listing was never encoding-bound. It was COPY-bound, and that was
  wrong in this document until 2026-08-26.** A 500-row reply was taken
  apart in-process: 2.4 ms of SQLite, **0.18 ms** of JSON encoding, and
  6.38 ms in total. The missing four milliseconds were Ring's value
  semantics — `aCopy = aRows` alone costs **0.72 ms** on that list, and
  the rows crossed five function boundaries between the query and the
  socket, being copied at each one.

  The fix is to encode ONCE at the source when the reply is the whole wire
  response, so the rest of the journey carries a two-element list instead
  of 500 rows: **6.38 → 4.15 ms for 500, 1.64 → 1.09 for 50.** A Ring
  caller still receives a list, and a gate asserts both paths return the
  same rows (`tests/crud-gates.js`).

  The old sentence blamed the encoder because the encoder is the part that
  looks expensive. It was measured only after it was written down.

## Throughput, concurrent readers

| concurrency | requests/s |
|---:|---:|
| 1 | 1,176 |
| 2 | 1,840 |
| 4 | 2,698 |
| 8 | 2,691 |
| 16 | 4,472 |
| **20** | **5,669** |
| 24 | 4,216 |

**Peak ~5,700 reads/s at 20 in flight**, with 4 VM workers.

### One finding worth more than the peak

An earlier run of this sweep showed a **cliff**: fine to 18 concurrent,
then collapse to ~12 requests/s with multi-second stalls. It reproduced
consistently, and it disappeared entirely once the same client had already
made requests at lower concurrency.

So the cliff is in **opening many new connections at once**, not in
serving them. Warm keep-alive connections at concurrency 24 are fine;
twenty-four *simultaneous fresh* connections on this platform are not.

What was ruled out: httpz's listen backlog (1024, not small), its
`max_conn` (8,192), and its timeouts (none default to seconds). What was
**not** determined: whether the remaining cost is Windows' TCP accept
path, httpz's thread-per-connection fallback on Windows, or the client. An
attempt to discriminate with a second client (24 parallel `curl`
processes) was abandoned because process spawn on Windows swamped the
measurement.

It is published unresolved rather than benchmarked around. A server whose
published throughput quietly avoids its own bad case has published a
number about the benchmark, not about the server.

## Against Node — losses first

Re-measured 2026-08-26 (`node tests/bench-vs-node.js 800`): the same
service-shaped workloads, same logic on both sides, RingServ's JS guest
(module form) against a plain `node:http` server — no framework on
either side, because the comparison is engines, not ecosystems. Node
v22.20.0, sequential requests, medians. **RingServ built ReleaseFast**
(the default; `ringserv version` prints the mode of whatever binary you
are holding).

| scenario | RingServ | Node | verdict |
|---|---:|---:|---|
| dispatch + JSON (hello) | 0.72 ms | 0.34 ms | **Node, 2.1×** |
| JSON-heavy (100-item list) | 0.87 ms | 0.30 ms | **Node, 2.9×** |
| SQLite write+read | 0.74 ms | 0.33 ms | **Node, 2.2×** |

### Two corrections since the last publication, both against us

**The JSON-heavy row was 1.37 ms and is now 0.87 — and the fix was ours,
not the engine's.** A JS reply goes to the wire as the guest's own text
(Ring has no boolean and no null, so decoding and re-encoding would turn
`{ok: false}` into `{ok: 0}`). But the code decoded it anyway, to check
it was valid JSON, **and then threw the result away** — a full parse of
every reply whose entire product was discarded.

It was measurable rather than theoretical: QuickJS builds *and* encodes
the whole 100-item reply in **0.145 ms**, while the request cost 0.62 ms
more than an empty one. The parse was most of the difference. It is safe
to skip because the text comes from `JS_JSONStringify`, whose output is
valid JSON or an exception — there is no third outcome — and the one
thing the decode also checked ("an object, not a bare value") is answered
by the first and last characters. Anything that does not look like an
object still falls through to the original path, so every error message
is unchanged.

**The SQLite row used to say "parity" and it was not a comparison.**
RingServ compiles SQLite with WAL and `synchronous=NORMAL`; `node:sqlite`
opened with SQLite's own defaults — a rollback journal at
`synchronous=FULL`, which fsyncs on every commit. On Windows that
reported RingServ 0.82 ms against Node 9.97 ms: **a 12× "win" that was
entirely the flush, and entirely in our favour.**

It was caught by running the same harness on Linux, where Node answered
0.63 ms and the story fell apart. Both sides now set the same pragmas,
and the row says Node is 2.2× faster. *A benchmark that flatters its
author by accident is worse than one that loses honestly.*

### The losses, with their causes

V8 and QuickJS are different weight classes: V8 is a multi-tier JIT many
times the size of RingServ's entire binary; QuickJS-ng is a small
embeddable interpreter. On pure JS work QuickJS typically runs 5–30×
behind V8, so a gap of 2–3× at the wire says the engine is not doing most
of the talking.

**What is doing the talking is the transport, and it was measured rather
than guessed.** The same dispatch costs **0.08 ms called in-process**
(no socket, no queue, no thread handoff) against 0.72 ms over HTTP. Ring
is 11% of a request; the other 89% is the HTTP layer and the handoff to a
VM worker — which is the architecture doing exactly what it was built to
do (docs/WORKERS.md: HTTP threads never touch the VM).

**Two attempts to buy that back were made and both removed**, and the
notes are in `src/serve.zig` where the next person will find them:

- Spinning on the HTTP thread before parking on the completion event:
  0.72 ms → 0.77 ms. Nothing, pointing the wrong way.
- Spinning on the *worker* before parking on the condition variable — the
  wake genuinely on the critical path: 0.73 → 0.69 ms. Real, ~4%, and
  inside the run-to-run spread already seen. **Dropped anyway, and not
  for being small: a spinning worker burns a core to save a context
  switch, and this server is meant to run on a Raspberry Pi, a phone and
  a laptop under a shop counter.** On a one-core machine that spin takes
  the core from the very thread waiting for it. A win measured on a
  12-core desktop that becomes a loss on the target hardware is not a win.

### What this means for choosing

If raw request throughput is the requirement, Node's engine is faster and
this document says so in every row. RingServ's case was never winning
them: it is **0.72 ms — far under network jitter** for the applications
this exists for, from a ~7 MB binary with nothing to install, no
`node_modules` to audit, and the Ring, data, journal and sync machinery
in the same file. The harness is committed; re-measuring is one command.

## What is deliberately not measured

- **Sustained load over hours.** `tests/soak-lite.js` and
  `tests/soak-data.js` watch RSS and correctness over thousands of
  requests; neither is a load test, and this is not one either.
- **A real network.** See above.
- **Anything over TLS.** RingServ terminates none — the proxy's latency
  is the proxy's to measure (`docs/TLS.md`).
- **Write throughput under contention.** One writer is the design
  (`docs/WRITES.md`); a concurrent-write benchmark would measure the
  mutex, which is a number with no decision attached to it.

## Reproducing

```bash
node tests/bench.js 200
```

It refuses to run if anything is already answering on port 8096 — two
numbers in `docs/WRITES.md` were once measured against a **stale server**
still bound to the port, because `pkill` does not kill processes on
Windows. It also asserts the row count at the end: a benchmark that
measured failures would be measuring how fast a server can say no.

`--json` prints the whole result, including the sweep, for anyone who
wants to chart it rather than read it.
