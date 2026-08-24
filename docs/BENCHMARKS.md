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
| `/health` (no VM at all) | 0.26 | 0.36 | 1.06 | 1.50 |
| dispatch, empty service | 0.75 | 1.23 | 2.08 | 2.59 |
| create (one row, one commit) | 0.94 | 1.37 | 2.33 | 5.46 |
| get by id | 0.78 | 1.16 | 1.87 | 2.36 |
| update one field | 0.89 | 1.31 | 1.76 | 2.79 |
| list, limit 50 | 1.33 | 1.96 | 2.65 | 2.68 |
| list, limit 500 | 2.97 | 4.12 | 5.16 | 5.52 |
| dispatch, **JS** service | 0.69 | 1.03 | 1.36 | 1.88 |
| JS service calling a Ring service | 0.87 | 1.23 | 2.24 | 3.69 |

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
- **Listing is encoding-bound, not query-bound.** 500 rows cost 2.97 ms
  against 1.33 for 50 — roughly linear in rows, which is the JSON encoder,
  not SQLite. The C codec already took this from 1134 ms to 7 ms on a
  2,000-row reply; what is left is the shape of the work.

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

Measured 2026-08-23 (`node tests/bench-vs-node.js 400`): the same three
service-shaped workloads, same logic on both sides, RingServ's JS guest
(module form) against a plain `node:http` server — no framework on
either side, because the comparison is engines, not ecosystems. Node
v22.20.0, sequential requests, medians. **RingServ built ReleaseFast**
(the default; `ringserv version` prints the mode of whatever binary you
are holding) — a number published without its build mode is a number a
later reader cannot check.

| scenario | RingServ | Node | verdict |
|---|---:|---:|---|
| dispatch + JSON (hello) | 0.77 ms | 0.42 ms | **Node, 1.8×** |
| JSON-heavy (100-item list) | 1.37 ms | 0.36 ms | **Node, 3.8×** |
| SQLite write+read | 10.47 ms | 10.06 ms | parity |

**The losses, with their causes.** V8 and QuickJS are different weight
classes: V8 is a multi-tier JIT the size of RingServ's entire binary
many times over; QuickJS-ng is a small embeddable interpreter. On pure
JS work QuickJS typically runs 5–30× behind V8, so a gap of only
1.8–3.8× at the wire says the fixed cost of dispatch is doing most of
the talking. The JSON-heavy row is the honest worst case: the list is
built and encoded inside the guest, exactly where the engine difference
is largest.

**The parity, with its cause.** The SQLite row is the one closest to a
real business action, and both sides answer in ~10 ms — because both
are paying the same disk flush, not their engines. On durable writes
the engine war is noise.

**What this means for choosing.** If raw JS throughput is the
requirement, Node's engine is faster and this document says so plainly.
RingServ's case was never winning that row: it is 0.77 ms — far under
network jitter for the applications this exists for — from a binary
~7 MB on disk with nothing to install, no `node_modules` to audit, and
the Ring, data, journal and sync machinery in the same file. The same
comparison harness is committed, so re-measuring is one command.

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
