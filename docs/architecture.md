# Architecture (planned)

*The layers RingServ will be built from, the seams between them, and
the decisions already taken. This is a blueprint: it is written before
the code so that the code can be judged against it — the same way
RingScript's REPAIR_PLAN.md preceded its runtime.*

## 1. The big picture

```
 clients                              ringserv (one static binary)
┌───────────────────────┐            ┌─────────────────────────────────────┐
│ RingScript page       │            │ CLI (Zig)                           │
│   serv.call(...)      │            │  new · dev · run · check · test ·   │
│ JS / any HTTP client  │◄─ HTTP ───►│  docs · build                       │
│   fetch("/api/v1")    │   JSON     ├─────────────────────────────────────┤
│ curl, mobile, ...     │            │ HTTP core (Zig)      sockets, TLS,  │
└───────────────────────┘            │  WebSocket/SSE, static, timers      │
                                     ├─────────────────────────────────────┤
                                     │ bridge (Zig)   resident RingState,  │
                                     │  dispatch, envelopes, error traps   │
                                     ├──────────────────┬──────────────────┤
                                     │ Ring VM (native) │ SQLite (vendored)│
                                     │  vendored 1.27   │  + sync log      │
                                     │  + servlib(Ring) │                  │
                                     └──────────────────┴──────────────────┘
```

Three languages, each doing the one thing it is best at — the
RingScript division of labor, transposed to the server:

- **Zig** owns the process: CLI, event loop, sockets, TLS, timers,
  file watching, SQLite embedding, and the build itself.
- **C (vendored, untouched)** is the Ring VM and SQLite — compiled
  as-is by `zig cc`, with the vendor-purity discipline RingScript
  established (patches only when unavoidable, marked in place,
  documented, contributed upstream).
- **Ring** owns everything the developer touches: the service model,
  contracts, ZQL, envelopes — as `servlib`, pure Ring embedded in the
  binary exactly as RingScript embeds `ringlib`.

## 2. The bridge — RingScript's, matured

`src/bridge.zig` in RingScript already solved the hard residency
problems: one long-lived `RingState`, eval with trapped errors and
real line numbers, hooks for I/O, an embedded pure-Ring file map, JSON
in and out via `rs_call`. RingServ starts from that design (native
target instead of wasm32-wasi — *simpler*: no WASI shims, no
`fmemopen` tricks, a real filesystem):

- `rs_init / rs_eval / rs_call / rs_reset` — the same resident API.
- The request path is `rs_call("__dispatch", envelope_json)`:
  the Zig HTTP core parses the wire, builds the envelope, and calls
  one Ring entry point; `servlib` routes to the service action. All
  service-model logic stays in Ring, where it is readable and
  hackable.
- Errors anywhere in user code produce a clean error envelope with a
  real line number — never a dead server. (RingScript's catch-shim
  and error-line vendor patch carry over directly.)

**Concurrency decision (to validate in phase 1):** the Ring VM is not
thread-safe, so the design is **N isolated VM workers** (processes or
threads each owning a `RingState`), fed by the Zig event loop —
Node's model, but N-wide. Session affinity is not required because
services are stateless by contract; shared state lives in SQLite.
This must be benchmarked and gated before anything is built on it.

## 3. The HTTP core

Written in Zig against the fetch shape: internally, a request becomes
a `Request`-like value and a handler returns a `Response`-like value,
so the core stays legible to the web ecosystem and portable in
thinking (ECMA-429 is the reference surface). Candidate foundations,
in order of preference:

1. **http.zig** (karlseguin) — proven, MIT, cross-platform (epoll /
   kqueue, threaded fallback on Windows), with `websocket.zig` as a
   companion. Vendored, not fetched.
2. `std.http.Server` — revisit as `std.Io` matures (Zig 0.16+); not
   production-grade today.

TLS is deferred to a phase of its own (reverse proxies cover the gap
meanwhile — the honest thing is to say so, not to ship weak TLS).

## 4. Data: SQLite + ZQL + the sync log

- **SQLite vendored as the amalgamation** — public domain, one `.c`
  file, compiles cleanly with `zig cc`; accessed from Zig via a thin
  wrapper (zqlite.zig-style, or hand-rolled — it is a small surface).
- **ZQL is the developer's query language.** RingScript already
  embeds `stzZql` (pure Ring) in the browser; RingServ embeds the same
  engine, targeting SQLite instead of the in-page store. One query
  language, both sides of the wire — this is the data half of the
  two-player model.
- **The sync log is a table**, not a technology: an append-only oplog
  with monotonic offsets per *shape* (a declared subset of data —
  ElectricSQL's vocabulary). The Zig core serves it over plain HTTP
  with long-poll/SSE liveness. See [topology.md](topology.md).

## 5. The JS guest (planned, phase 6)

**quickjs-ng**, vendored as its amalgamation: MIT, actively released,
ES2023+, proven as a server-runtime substrate by txiki.js. The
embedding gives RingServ:

- `.js` handlers and modules next to `.ring` ones — same service
  model, same envelopes;
- a migration path for teams with existing JS logic;
- the minimum common web API (fetch, URL, streams, TextEncoder,
  crypto.subtle…) implemented once in Zig and exposed to *both*
  guests.

Kiesel (the Zig-native JS engine) is the long-term watch: same build
graph, no C++ — but not production-ready in 2026.

## 6. Static analysis: tree-sitter-ring

The CLI vendors **tree-sitter-ring** (Youssef Saeed / ysdragon, MIT)
— generated `parser.c` + `scanner.c` plus the tree-sitter C runtime,
all zig-cc-friendly. It powers:

- `ringserv check` — service contracts vs. implementations, unknown
  actions, arity mismatches, dead services;
- `ringserv docs` — the API catalog straight from source;
- future: formatting, editor tooling.

The grammar is days old (pin a commit; expect churn) and cannot see
runtime keyword remapping — acceptable: `check` is a linter with
Ring-shaped eyes, not a second compiler. Runtime truth stays with the
VM.

## 7. Planned repository layout

```
ringserv/
├── build.zig                 one build: binary + dev loop + dist
├── readme.md
├── docs/                     you are here — the blueprint
├── src/
│   ├── main.zig              CLI entry and subcommands
│   ├── http/                 server core (vendor-adapted), ws, sse, static
│   ├── bridge.zig            resident Ring VM: rs_init/rs_eval/rs_call
│   ├── db.zig                SQLite embedding + the sync log
│   ├── jsguest.zig           quickjs-ng embedding        (phase 6)
│   ├── check/                tree-sitter-ring analysis   (phase 5)
│   └── servlib/              pure Ring, embedded in the binary
│       ├── serv.ring         RingServ() — the app declaration seam
│       ├── service.ring      dispatch, envelopes, generic table services
│       ├── contract.ring     typed contracts + validation
│       ├── json.ring         shared with RingScript
│       └── stzZql.ring       shared with RingScript
├── ringvm/                   vendored Ring 1.27 (src + include)
├── vendor/                   sqlite, http.zig, tree-sitter(+ring), quickjs-ng
├── examples/
├── tests/                    gates, soak, fuzz, oracle, convergence
└── bin/                      prebuilt ringserv binaries, committed
```

## 8. Decisions already taken (and why)

| Decision | Why |
|---|---|
| Vendor Ring untouched, native build | RingScript proved the discipline; native is the easier target |
| One Ring entry point (`__dispatch`) | keeps the whole service model in readable Ring |
| Services stateless, state in SQLite | enables N-worker concurrency without VM thread-safety |
| Fetch-shaped internals | ECMA-429 legibility; adapters stay thin |
| SQLite amalgamation, ZQL on top | zero-dep data with the same query language as the browser side |
| Sync = HTTP log + mutation queue | boring, cacheable, reimplementable — see landscape.md |
| tree-sitter for `check`, VM for truth | a linter may approximate; a runtime may not |
| Everything vendored, nothing fetched | `build.zig.zon`-free, like RingScript: the repo is the supply chain |
