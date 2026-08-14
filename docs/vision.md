# Vision

*Why RingServ exists, what it refuses to be, and the fullstack model
it forms together with RingScript.*

## 1. The gap

Ring is a beautiful language for expressing business ideas — its
declarative nested style, its natural-language leanings, its
flexibility — and since 1.27 it has real web options. Yet none of them
gives a backend developer the experience that Bun, Deno, or Go give:
**one tool, zero dependencies, standards-shaped, batteries included.**
WebLib needs Apache. RingHttpLib is a thin wrapper over blocking C++.
Bolt is genuinely lovely but rides a Rust binary and stops at the HTTP
layer. And none of them knows anything about the *browser side* of a
Ring application.

Meanwhile RingScript proved a method: vendor the Ring VM untouched,
let Zig do the hard compilation and the hard runtime services, keep
the JavaScript/host seam tiny and honest, verify everything against
native Ring byte-for-byte, and ship artifacts so small and
self-contained that "install" means "copy files". RingServ applies
the same method to the server.

## 2. What RingServ is

**A resident Ring runtime for the backend, delivered as one static
binary.** Inside the binary:

- the vendored **Ring 1.27 VM**, compiled natively by Zig — the same
  VM, the same vendor-purity discipline, as RingScript;
- a **Zig core** owning what Zig is best at: the HTTP server, TLS,
  WebSocket/SSE, timers and scheduled jobs, file watching, static
  files, the SQLite engine, the sync log;
- a **pure-Ring service library** (`servlib`) owning what Ring is best
  at: the service model, contracts and validation, ZQL, the response
  envelopes, the developer-facing seam;
- the **CLI** that unifies it all: scaffold, dev loop, check, test,
  docs, build.

The division of labor is RingScript's, transposed: *Ring for beauty
and business, Zig for muscle and portability, a thin honest seam
between them.*

## 3. What RingServ refuses to be

- **Not a router with middleware soup.** The primary paradigm is
  services (see [services.md](services.md)); path routing exists as a
  secondary mode for the cases that genuinely need URLs.
- **Not an ORM.** Data access is ZQL over embedded SQLite — a query
  language, not a hydration machine.
- **Not a template engine.** Pages are RingScript's job; RingServ
  serves data (and static files). Server-rendered HTML can come later
  if real projects demand it.
- **Not a replacement for Softanza.** Softanza's server and
  application paradigms sit *above* this; RingServ is the
  dependency-free floor they can stand on — exactly as RingScript is
  StzWeb's road into the browser.
- **Not a fifth web framework for Ring.** Its reason to exist is the
  fullstack model below; the HTTP layer is table stakes.

## 4. The two-player model

The central idea — the one no neighbor project has — is that
**RingScript and RingServ implement the same programming model on the
two sides of the wire**:

| | RingScript (page) | RingServ (server) |
|---|---|---|
| Ring VM | wasm32-wasi, resident | native, resident |
| Host seam | `Platform()` / `Page()` | `RingServ()` / `Reply()` |
| Call shape | `ring.call(name, json)` | `service` + `action` + `payload` |
| Data | ZQL over synced local store | ZQL over SQLite |
| Guest language | Ring is a guest in JS | JS is a guest in Ring (planned) |
| Delivered as | two files to host | one binary to run |

The wire format between them is the one both already speak: JSON,
under a `call(service.action, payload)` seam. An application declares
services once; the **topology** ([topology.md](topology.md)) places
each one — page, server, or both — and placement is a deployment
decision, not a rewrite.

This symmetry is not aesthetic. It is what makes the hard scenarios
declarative:

- **99 % local-first**: everything runs in the page against local
  data; the server is a sync point touched only on reconnection.
- **Thin client**: every action dispatches to the server; the page is
  presentation.
- **Split brain**: reads local and instant, writes queued to the
  server, heavy computations (`:report`, `:search`) placed
  server-side.

All three are the *same application* with different topology files.

## 5. Openness — standards on both sides

RingScript adheres to web standards by construction: it lives in the
browser and is callable from plain JavaScript. RingServ must earn the
same openness on the server:

- Its HTTP model is the **fetch shape** — Request in, Response out —
  now standardized (ECMA-429 / WinterTC) and shared by Cloudflare
  Workers, Deno, Bun, and every modern edge runtime.
- Its API surface is callable from **any** HTTP client in one wrapper
  function — the single-endpoint service protocol is JSON over POST,
  no SDK required.
- **Planned**: an embedded standards-shaped JavaScript engine
  (quickjs-ng — the maintained QuickJS fork, MIT, proven as a runtime
  substrate by txiki.js), so RingServ can also run JS handlers and
  modules. For the common backend cases this lets RingServ stand where
  Node would — one small binary instead of a platform — and it makes
  the guest relationship symmetric: Ring hosts JS on the server as JS
  hosts Ring in the page.

## 6. The name of the game: trust

RingScript's credibility came from verification: 36 gates, soak,
fuzz, and byte-for-byte oracle comparison against native `ring.exe`
across ~850 programs. RingServ inherits the culture:

- every service-model claim gets a gate;
- the HTTP layer gets soak (connection churn, slow clients) and fuzz
  (hostile requests must produce clean envelopes, never a dead
  server);
- Ring-language behavior is oracled against native Ring;
- the sync protocol gets a *convergence* suite: two clients, arbitrary
  interleavings, one final state.

Nothing ships as a claim; everything ships as a passing test.
