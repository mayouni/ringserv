# Data and compute in one process

*The position, and exactly how much of it the measurements support.
Written 2026-08-29, prompted by a published benchmark that gave the
paradigm a public name — InfoQ's report on
[Harper 5.2 against a Vercel stack](https://www.infoq.com/news/2026/08/harper-vercel-benchmark/),
August 2026. **RingServ has run neither side of that benchmark**, and
nothing here is a head-to-head. What follows is RingServ's own numbers,
already published in [BENCHMARKS.md](BENCHMARKS.md), read against a
claim someone else made.*

## The claim someone else is now making out loud

Harper's argument, as reported: collapse the tiers. Instead of an
application process talking over a network to a database, a cache and a
message broker — each hop a serialization, a socket and a scheduler —
keep **data, compute and messaging in one runtime**, so a personalized
read becomes a function call against a table already in memory. Their
published figures: roughly **0.4 ms in-process against ~3 ms** across
the network, and up to ~14× on live personalized paths, over eight
scenarios and 474 load tests, against Vercel Functions + Neon Postgres +
Upstash Redis + Ably.

Their own stated caveats matter as much as the numbers, and they are
the honest kind: the dataset was **warm and in memory**, the tests
predate 5.2's optimizations, and **Vercel wins on cacheable content,
broadcast-only workloads, and high fan-out**, where serverless
autoscaling beats a single runtime outright. It is a vendor benchmark
of a vendor's own architecture. Read it as a direction, not a verdict.

**Why record it here at all:** because it is the architecture RingServ
already had, argued from first principles in [VISION.md](VISION.md)
before anyone was selling it. A named industry current is worth
recording the day it appears — not because it validates the design, but
because it makes the design's trade-offs legible to people who would
otherwise have to take them on faith.

## Where RingServ already stands

RingServ is one static binary. The Ring VM, SQLite, QuickJS-ng and the
HTTP server are compiled into the same executable and run in the same
address space ([architecture.md](architecture.md)). The consequence is
not a fast database call. It is **the absence of a database call** in
the sense the tiered stack means it:

- `DataQuery` / `DataExec` reach SQLite through a C function call. No
  socket, no wire protocol, no connection pool, no serialization of the
  query or the rows.
- The **journal** — the append-only, fingerprint-sealed record — is in
  the same file, on the same connection discipline.
- **Streams** ([STREAM.md](STREAM.md)) are the messaging third of
  Harper's triad, and they are in-process too: a subscription is state
  in this server, not a broker across a network.
- A **JavaScript** service is not a separate runtime either — QuickJS-ng
  is resident, and `serv.call` from JS to Ring costs one extra dispatch
  ([JS.md](JS.md)).

So the triad the paradigm names — data, compute, messaging — plus the
record, are already one process here. That was never marketed as
fusion. It was the consequence of the actual goal: **one file to
download, nothing to install, nothing to configure.**

## The number that decomposes the claim

This is the finding worth having, and RingServ measured it on itself
long before the paradigm had a name. From
[BENCHMARKS.md](BENCHMARKS.md), on 12 logical cores, ReleaseFast, four
workers, SQLite on disk in WAL:

| path | p50 |
|---|---:|
| `/health` — never enters the VM | 0.18 ms |
| dispatch, empty service, over HTTP | 0.72 ms |
| **the same dispatch, called in-process** | **0.08 ms** |
| get by id, over HTTP | 0.72 ms |
| create — one row, one durable commit, over HTTP | 0.91 ms |

**0.08 ms in-process against 0.72 ms over HTTP is a 9× gap, and it is
the same gap Harper published as 0.4 against 3.** Different absolute
numbers on different hardware measuring different stacks — but the same
shape, and the same cause: a socket, a queue and a thread handoff cost
roughly an order of magnitude more than a function call.

RingServ's version of that measurement is more useful than a
cross-vendor one, because both sides of it are the *same server*. There
is no second product's tuning in the comparison. The conclusion it
supports is precise, and it is already written in BENCHMARKS.md:
**Ring is 11% of a request; the other 89% is the HTTP layer and the
handoff to a VM worker.**

That sentence is the whole fusion argument stated as an engineering
fact rather than a slogan. Every hop you remove is worth about that
much. RingServ removed the database hop entirely — which is why a
`create` costs 0.91 ms **including** HTTP, dispatch, contract
validation and a real durable WAL commit, where a tiered stack's ~3 ms
is the hop *before* any of that work starts.

For the historical record: a create cost **10.13 ms** here before the
one-writer connection landed on 2026-08-17 ([WRITES.md](WRITES.md)).
Co-location did not make it fast. Co-location plus getting the
connection discipline right made it fast, and the second half was work.

## What fusion does not buy, measured

House rule: the losses are published with the wins. Four of them, and
none is small.

**1 — It does not make the engine fast.** Against a plain `node:http`
server on the same workloads, **Node wins every row**: 2.1× on dispatch,
2.9× on JSON-heavy, 2.2× on SQLite write+read. V8 is a multi-tier JIT
many times the size of RingServ's entire binary. Fusion removes hops;
it does not close an engine gap, and BENCHMARKS.md says so in every row.

**2 — It removes the database hop, not the client hop.** The 89% above
is RingServ's *own* HTTP transport — the socket between the browser and
this server. Every architecture pays that one. A benchmark that quotes
in-process latency as if it were end-to-end latency is quoting the half
of the journey it likes.

**3 — The warm-working-set caveat applies here too, in a different
shape.** Harper's advantage narrows when the working set exceeds
memory; RingServ's data lives in SQLite's page cache with the disk
underneath, so it **degrades along a slope rather than off a cliff** —
but a working set far past the cache is disk I/O, and no amount of
co-location changes that. This has not been measured here at scale, and
is not claimed.

**4 — There is no elastic fan-out, and this is the sharpest trade.**
Harper concedes serverless autoscaling wins under high fan-out.
RingServ concedes it harder: it is N worker threads in one process on
one machine ([WORKERS.md](WORKERS.md)), scaling flattens past four
workers, and peak measured throughput is **~5,700 reads/s**. Its answer
to growth is not elastic spawn — it is **declared placement**: move a
service between page and server by changing one word, with the server
enforcing the declaration ([topology.md](topology.md)). That is a good
answer for applications on one machine to a few. It is not an answer
for a traffic spike, and pretending otherwise would be the kind of
claim this document exists to avoid.

## The failure mode fusion introduces — and what it cost us

Worth writing down because it is the honest counterweight, and because
it was paid in this repository on **2026-08-28**, the day before this
document.

When data and compute are separate tiers, "can I reach the database?"
is a *connection* question, answered continuously by a pool that
retries. When they are one process, it becomes a **boot** question
about the process itself — and a process that answers it wrong looks
perfectly healthy from outside.

That is exactly what happened. A worker whose database was unreachable
— a read-only file, a missing parent directory — marked itself alive
anyway. The server printed `serving on http://...`, answered `/health`
with 200, and failed every request that touched data with a 500,
indefinitely, with nothing in between to say why. Fixed at both points:
a worker that cannot reach its database now refuses and names the
reason, and the server refuses to serve at all if no worker ever came
up. Gated by `tests/db-boot-gates.js`; the account is in
[GATES.md](GATES.md).

**The transferable half:** every architectural property you gain has a
failure mode that arrives with it, wearing the property's own clothes.
Fusion's is that liveness stops being a question you can ask the
network and becomes a question the process must ask itself, honestly,
at boot.

## What this document does not claim

- **No head-to-head.** RingServ has not run Harper's benchmark, or
  Vercel's, or anything resembling either. The 0.08/0.72 figures are
  RingServ measuring itself, on the machine and method BENCHMARKS.md
  documents, and they are comparable to Harper's *in shape only*.
- **No claim that fusion is the right architecture generally.** It is
  the right architecture for what RingServ is for: applications that
  run on one machine to a few, where the whole point is that there is
  nothing to assemble. The article's own losses name the workloads
  where it is the wrong one, and this document repeats them rather than
  omitting them.
- **No new feature.** Nothing was built for this position and nothing
  should be. The failure mode above is the only code that came out of
  reading the article, and it was already being fixed for its own
  reasons. Adding in-memory tables, a bundled cache tier or a broker
  because a paradigm has them would trade away the property RingServ
  actually has: a data layer that is **plain SQL over the most-deployed
  database in the world** ([DATA.md](DATA.md)), journaled, with none of
  its own persistence inventions.

The estate settled that instinct once already, by deletion: there is no
framework query dialect here, because plain SQL was the better answer
and removal was the better move. The same instinct applies to a
paradigm that arrives with a shopping list.
