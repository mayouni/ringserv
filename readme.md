<h1 align="center">RingServ</h1>

<h2 align="center">The Ring language, resident on your server</h2>

<p align="center">
  <strong>design stage</strong> · Ring 1.27 · MIT · a Softanza Project ·
  sister of <a href="https://github.com/mayouni/ringscript">RingScript</a>
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
   HTTP core, embedded SQLite, and the CLI, into one static executable
   per platform. Like RingScript's ~40 KB servers, the binaries are
   prebuilt and committed: install is *download and run*.

2. **Web standards, not framework standards.** The programming model
   is the fetch shape — a handler receives a Request and returns a
   Response — the same contract that lets Hono run unchanged on
   Cloudflare, Deno, and Bun, now standardized as ECMA-429. RingServ
   speaks that shape natively, so it is legible to the whole web
   ecosystem, and JavaScript remains a first-class caller — and, later,
   a first-class guest via an embedded standards-shaped JS engine.

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

## The planned CLI — the whole developer experience

```bash
ringserv new myapp       # scaffold a working service + page + topology
ringserv dev             # serve, watch, reload — the daily loop
ringserv run app.ring    # run a server program directly
ringserv check           # static analysis: contracts, types, dead actions
ringserv test            # run the app's tests against a scratch server
ringserv docs            # generate the API catalog from the contracts
ringserv build           # produce the single deployable binary
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

## Status and documentation

RingServ is **under construction, phase-gated**. Phases 1 and 2 are
**done and green**:

- **Phase 1** — the resident native Ring VM: 12 gates, the shared
  24-example corpus byte-identical to native `ring.exe`, the
  N-worker model proven ([docs/WORKERS.md](docs/WORKERS.md)).
- **Phase 2** — the server lives: `ringserv run app.ring` serves
  `RingServ()` declarations on `POST /api/v1` — both service forms,
  the uniform envelope, transport-status contract (404/400/500),
  N VM workers behind httpz — 16 service gates, 200-case fuzz, and
  a 3,000-request soak with flat memory.

- **Phase 3** — data: SQLite vendored, `Data()` schema declarations,
  one connection per worker with WAL, a plain-SQL query surface
  (`DataQuery`/`DataExec`), generic table services (`table = "notes"`
  → list/get/create/update/delete), and `Contract()` validation with
  422 envelopes — 18 schema gates + 25 CRUD/contract gates
  ([docs/DATA.md](docs/DATA.md)).

- **Phase 4** — the CLI: `new` scaffolds an app whose tests already
  pass, `dev` serves it and reloads on save, `test` runs in process
  against a scratch database, `where` reports what is compiled in;
  static files served by the Zig core; `zig build dist`
  cross-compiles five platforms — 16 CLI gates.

Phase 5 (`check` and `docs`, via tree-sitter-ring) is next.
Everything above is real today — **113 gates across eight suites**,
all runnable with one command:

```bash
zig build gates -- --full
```

See [docs/GATES.md](docs/GATES.md) for what each suite defends, and
for an honest list of what is still thin.

- [docs/vision.md](docs/vision.md) — why RingServ exists, and the two-player model
- [docs/architecture.md](docs/architecture.md) — the planned layers, Zig/Ring seams
- [docs/services.md](docs/services.md) — the service model, contracts, envelopes
- [docs/topology.md](docs/topology.md) — declarative placement and local-first sync
- [docs/cli.md](docs/cli.md) — every command, with its reasoning
- [docs/landscape.md](docs/landscape.md) — the study: Pionia, Hono, WinterTC, Bolt, and friends
- [docs/roadmap.md](docs/roadmap.md) — the phases, each with its gate

## License

MIT License. Copyright (c) 2026 Mansour Ayouni (kalidianow@gmail.com)
