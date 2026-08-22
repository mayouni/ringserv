<h1 align="center">RingServ</h1>

<h2 align="center">The Ring language, resident on your server</h2>

<p align="center">
  <strong>0.9</strong> · Ring 1.27 · MIT · a Softanza Project ·
  sister of <a href="https://github.com/mayouni/ringscript">RingScript</a>
</p>

<p align="center">
  <a href="https://github.com/mayouni/ringserv/actions/workflows/gates.yml"><img
    src="https://github.com/mayouni/ringserv/actions/workflows/gates.yml/badge.svg"
    alt="gates"></a>
</p>

RingServ is the backend counterpart of
[RingScript](https://github.com/mayouni/ringscript). Where RingScript
makes [Ring](https://ring-lang.github.io/) resident in the browser,
RingServ makes Ring resident on the server: a single static binary,
built by Zig, that serves HTTP by web standards, runs your services
written in beautiful declarative Ring, stores data in embedded SQLite
queried in plain SQL, and syncs with local-first RingScript pages — with **no
dependency beyond the binary itself**. No Apache, no Node, no runtime
to install, nothing to configure.

```ring
# app.ring — a complete API server

RingServ([
    :port = 8080,

    :services = [
        :hello = [
            :greet = func oReq {
                cName = oReq[:payload][:name]
                return Reply(:ok, [ :message = "Ahlan, " + cName + "!" ])
            }
        ]
    ]
])
```

```bash
ringserv new myapp && cd myapp
ringserv dev
```

And from any RingScript page — or any JavaScript client — the call is
the same call it always was:

```js
const res = await serv.call("hello.greet", { name: "Mansour" })
```

## The idea in one paragraph

RingScript and RingServ are **two players in one programming model**.
A fullstack Ring application declares its *services* and its *data*
once; a declarative **topology** decides where each piece lives — in
the page, on the server, or on both with synchronization. The same
`call(service.action, payload)` seam works everywhere: in the browser
it may dispatch to Ring-in-wasm, on the server to Ring-native, and the
application code cannot tell the difference. Move a service from the
client to the server by editing one line of the topology, not the
application.

## The five pillars

1. **One binary, zero dependencies.** Zig compiles the vendored Ring
   1.27 VM natively (the same VM RingScript compiles to wasm), plus an
   HTTP core, embedded SQLite, a JavaScript engine and the CLI, into one
   static executable per platform. Install is *download one file and run
   it* — the binaries are built by CI for each release, not committed
   (they would bloat git history permanently).

2. **Web standards, not framework standards.** The programming model
   is the fetch shape — a handler receives a Request and returns a
   Response — the same contract that lets Hono run unchanged on
   Cloudflare, Deno, and Bun, now standardized as ECMA-429. RingServ
   speaks that shape natively, so it is legible to the whole web
   ecosystem, and JavaScript is a first-class caller **and a
   first-class guest**: a service's implementation may be a `.js` file,
   run on a vendored QuickJS-ng with a WinterTC-shaped surface, behind
   the same envelope, contracts and placement as a Ring one
   ([docs/JS.md](docs/JS.md)).

3. **Services, not routes.** The primary paradigm (learned from
   [Pionia](https://pionia.netlify.app/)'s Moonlight architecture) is a
   single endpoint per API version dispatching `service` + `action` +
   `payload`, with a uniform response envelope. No URL design, no verb
   ceremony — and the wire shape is *exactly* RingScript's existing
   `ring.call(name, json)`, which is what makes the fullstack symmetry
   free. Classic path routing remains available when you want it
   (static files, SSE, webhooks, REST for third parties).

4. **Local-first by declaration.** The topology can place data
   `:local`, `:server`, or both with `:sync` — from a 99 % offline
   application that syncs on reconnection, to a thin client, and every
   scenario between. The sync protocol is deliberately boring:
   HTTP-shaped logs on the read path, idempotent mutation queues on
   the write path. Data on the server is SQLite, queried in plain SQL
   — RingServ is a *general* Ring application server, so its core
   commits to no framework's query dialect; richer languages
   (Softanza's ZQL among them) ride on top as ordinary Ring libraries.

5. **Governed, testable Ring.** Ring's declarative style carries typed
   service *contracts* — validated at the door at runtime, checked
   statically by the CLI using a vendored
   [tree-sitter-ring](https://github.com/ysdragon/tree-sitter-ring)
   grammar, and rendered into API docs automatically.

## The CLI — the whole developer experience

```bash
ringserv new myapp       # scaffold a working service + page + topology
ringserv dev             # serve, watch, reload — the daily loop
ringserv run app.ring    # run a server program directly
ringserv check           # static analysis: contracts, types, dead actions
ringserv test            # run the app's tests against a scratch server
ringserv docs            # generate the API catalog from the contracts
ringserv journal verify  # is the fiscal record still whole? exits 1 if not
ringserv serve fns.ring  # host a file of plain functions, as-is
ringserv panel examples  # start, stop and watch your apps in a browser
```

One tool. A backend developer needs nothing else installed — not even
Ring, which lives inside the binary.

## Where it stands among Ring's backends

Ring can already speak server-side three ways: **WebLib** (CGI under
Apache), **RingHttpLib** (blocking C++ threads), and
[**Bolt**](https://ysdragon.github.io/bolt/) (an elegant Express-style
DSL over a Rust/Actix engine). RingServ takes a fourth position: a
**Zig-native, standards-shaped, batteries-included runtime** whose
reason to exist is not routing — it is the *unified fullstack
programming model* with RingScript, the local-first topology, and the
zero-dependency CLI. See [docs/landscape.md](docs/landscape.md) for
the full survey and what was learned from each neighbor.

## Part of the Softanza Project

RingServ does not replace Softanza's server and application paradigms —
it is infrastructure *for* them. The same way RingScript exists so that
StzWeb can offer Ring as a frontend scripting language, RingServ exists
so that Softanza can stand on an industrial-strength, dependency-free
backend runtime when it needs one — while remaining, on its own, a
simple and beautiful way to write any backend in Ring.

## Install

Download one file for your platform from
[Releases](https://github.com/mayouni/ringserv/releases), make it
executable, and run it. There is nothing else to install — not Ring, not
Node, not a runtime, not a web server.

```bash
ringserv new myapp --gesture   # or: ringserv new myapp  (fullstack scaffold)
cd myapp && ringserv serve myapp.ring
```

Building from source needs only [Zig](https://ziglang.org) 0.15.2:
`zig build` — every dependency is vendored in `vendor/`, nothing is
fetched.

## Where it stands — 0.9

**0.9 means the surface is complete and exercised, and the API is
stabilising rather than frozen.** Ten phases are delivered and gated;
each one's record, with its gate results, is in
[docs/roadmap.md](docs/roadmap.md).

| | |
|---|---|
| **Services** | declarative, class, generic-table, JavaScript, and *no declaration at all* (`ringserv serve`) |
| **Data** | embedded SQLite, WAL, one connection per worker, plain SQL, typed contracts validated at the door |
| **History** | `Journal()` — append-only, SHA-256 hash-chained, replayed to state, never compacted |
| **Local-first** | C3 placement, a trigger-maintained shape log, an exactly-once mutation queue, compaction with `must-refetch` |
| **Governance** | `check` (tree-sitter + the VM's own catalog), `docs`, C2 diagnostics, an actor seam with 401/403 kept distinct |
| **Operations** | a browser admin panel, `journal verify` for cron, static files, `ringserv.yaml` |

**625 gates across 22 suites** run in about 70 seconds
(`node tests/all.js`); `--full` adds soak, a benchmark, a **differential
oracle against native `ring.exe`**, and a wide sweep over Ring's own
~470 samples plus ~500 documentation snippets compared byte-for-byte.
Every push builds and runs all of it on **Linux, macOS and Windows**.

Two example applications, both real and both gated:
[fieldnotes](examples/fieldnotes) teaches one seam at a time, and
[comptoir](examples/comptoir) — a café counter — wires every hostable
form together the way an application actually does.

**What 0.9 is not.** The API may still move before 1.0. RingServ
terminates no TLS by design ([docs/TLS.md](docs/TLS.md)) — put a proxy
in front. `Intl` and the yaml config are deliberate **named subsets**
that refuse the rest by name rather than guessing. And what is still
thin is listed honestly in [docs/GATES.md](docs/GATES.md); the road
ahead is [docs/PLAN.md](docs/PLAN.md).

## Documentation

**Start here** — [docs/getting-started.md](docs/getting-started.md), then
[docs/gesture.md](docs/gesture.md) (a function to a service in ninety
seconds), then [docs/fieldnotes-app.md](docs/fieldnotes-app.md) (a whole
application, built).

- [docs/VISION.md](docs/VISION.md) — why RingServ exists, and the two-player model
- [docs/architecture.md](docs/architecture.md) — the layers, and the Zig/Ring seams
- [docs/services.md](docs/services.md) — the service model, contracts, envelopes
- [docs/DATA.md](docs/DATA.md) · [docs/WRITES.md](docs/WRITES.md) — the data layer and the single writer
- [docs/COMMONS.md](docs/COMMONS.md) — the journaled store, and why it is a second store
- [docs/topology.md](docs/topology.md) — declarative placement and local-first sync
- [docs/JS.md](docs/JS.md) — the JavaScript guest, and its honest limits
- [docs/CHECK.md](docs/CHECK.md) · [docs/cli.md](docs/cli.md) — governance and every command
- [docs/TLS.md](docs/TLS.md) · [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — the deployment decisions, and the numbers
- [docs/landscape.md](docs/landscape.md) — the study: Pionia, Hono, WinterTC, Bolt, and friends
- [docs/roadmap.md](docs/roadmap.md) · [docs/PLAN.md](docs/PLAN.md) — what shipped, and what is next

## License

MIT License. Copyright (c) 2026 Mansour Ayouni (kalidianow@gmail.com)
