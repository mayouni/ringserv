# The landscape study

*What was learned, from whom, before designing RingServ — recorded so
the design's debts are explicit and its departures deliberate.
Surveyed August 2026.*

## 1. Pionia (PHP) — the service paradigm

[Pionia](https://pionia.netlify.app/) ("PHP REST framework for
developers with deadlines", by Tumusiime Ezra Jnr) names its paradigm
the **Moonlight architecture**: one endpoint per API version, POST
only, the body carries `{service, action, payload}`, and every
response is a uniform envelope (`returnCode` / `returnMessage` /
`returnData`). Services are classes; methods suffixed `Action` are
reachable, the rest are private. A **switch** maps service names to
classes per version; v2 re-registers v1 services and overrides only
what changed. **Generic services** are the boilerplate killer: declare
`$table = "todo"` and list/retrieve/create/update/delete exist,
mixin-composable, pagination included. Middleware is two flat hooks
(`onRequest`/`onResponse`), not an onion. Their `api:docs` generates
OpenAPI despite the single URL — the catalog is data.

**Adopted:** the entire service/action/envelope paradigm; the
`Action` suffix rule; generic table services; two-hook middleware;
versions as switchboards; docs-from-catalog.
**Departed:** Pionia originally returned HTTP 200 for everything and
later reversed to dual signaling (business code in the envelope,
transport code on the wire) — RingServ adopts the *reversed* position
from day one. And where Pionia says "JavaScript should never be
written on the server", RingServ plans the opposite: JS as a guest.

## 2. Hono + WinterTC — the standards spine

[Hono](https://hono.dev/) is built solely on web standards: the whole
framework is `fetch(Request) => Response`, which is why one codebase
runs unchanged on Cloudflare Workers, Deno, Bun, Fastly, and Node
(via a thin adapter). Its lessons: push runtime differences into
adapters at the edge and never touch sockets in the framework;
testing is trivial when the app is a Request→Response function;
pluggable routers matter (its RegExpRouter compiles all routes into
one regex); smallness is a feature (`hono/tiny` < 15 KB); and typed
RPC (`hc<AppType>`) gives end-to-end types without codegen.

The **minimum common web API** is now a standard: WinterCG became
Ecma **TC55 (WinterTC)**, and **ECMA-429** (1st edition, Dec 2025)
fixes the surface — fetch/Request/Response/Headers, URL +
URLPattern, the full streams family, TextEncoder/Decoder,
crypto.subtle, AbortController, structuredClone, timers,
Compression streams. Notably **WebSocket server upgrade is *not*
standardized** — every runtime differs, so adapters are legitimate
there. Bun (`Bun.serve({fetch})`), Deno (`Deno.serve(handler)`), and
workerd (`export default {fetch}`) all converge on the same ABI.

**Adopted:** fetch-shaped handlers as the internal model and the
secondary route surface; ECMA-429 as the reference list for the
future JS guest; app-as-function testability; the tiny-and-vendored
ethos. **Noted:** Elysia shows what per-route compile-time
specialization buys (~255k req/s) — a later optimization, not a
design driver.

## 3. Local-first sync — the field, and the minimal design

- **ElectricSQL**: read-path-only **shape sync** over plain HTTP — a
  shape is a filtered table subset; the server tails the database
  into per-shape logs with offsets; clients page then long-poll/SSE;
  `up-to-date` and `must-refetch` control messages; **writes are
  deliberately your API's problem**. The smallest respectable
  protocol, and CDN-friendly because it is just HTTP.
- **PowerSync**: bucket oplogs + checkpoints with checksums —
  partitioning and integrity at scale; heavier than needed to start.
- **Replicache / Zero**: push batches of named mutations with
  `(clientID, mutationID)` for exactly-once; server re-executes
  authoritatively; pull returns a patch + cookie; client rebases
  unacked mutations. The smallest full read-write model; Zero 1.0
  (2026) is its successor with ZQL-branded queries (nota bene: a
  *different* ZQL than Softanza's — naming collision to be aware of
  in public writing).
- **CR-SQLite / Automerge**: the CRDT road — no authority needed,
  but column-level merge semantics and maintenance risk (CR-SQLite
  is low-activity). Out of scope while an authoritative server
  suffices.

**Adopted:** Electric's shape-log read path + Replicache's
mutation-queue write path, with the RingServ twist that *a mutation
is a service call* — no second vocabulary. See
[topology.md](topology.md).

## 4. Ring's own backend field

- **WebLib** (ships with Ring): CGI under Apache/mod_cgi, three
  page-generation styles, MVC helpers. Real, documented, but
  process-per-request and Apache-bound.
- **RingHttpLib** (ships with Ring): wraps cpp-httplib (C++,
  blocking/thread-pool); `route(:Get, "/hi", :handler)`; static
  folders, uploads. A wrapper, not a runtime.
- **Bolt** (Youssef Saeed / ysdragon, Ring 1.27+): Express-style DSL
  (`@get("/users/:id", func {...})`, `$bolt` context) over
  **Actix-web/Tokio (Rust)**; middleware, WS, SSE, JWT, sessions,
  OpenAPI; ~585K req/s claimed; MIT. The strongest neighbor — and
  proof that Ring's community wants modern backends.

**Position:** RingServ is the fourth road — Zig-native, one binary,
service-first, fullstack-with-RingScript. It should *coexist*
gracefully: Bolt is a fine answer to "Express in Ring"; RingServ
answers "one programming model across page and server". Worth noting:
ysdragon authored both Bolt **and** tree-sitter-ring, and is a Ring
core developer — a natural ally, not a rival.

## 5. tree-sitter-ring

[ysdragon/tree-sitter-ring](https://github.com/ysdragon/tree-sitter-ring)
(MIT, published August 2026 — by Youssef Saeed): covers `.ring` /
`.rh` / `.rform`, all three func declaration styles, classes,
`#{...}` interpolation, context-sensitive keyword demotion mirroring
Ring's real parser, an external scanner, 142 corpus tests verified
against Ring's own samples. Excludes (correctly — they are
runtime-mutable) NaturalLib DSLs and dynamic keyword remapping.
Vendoring is the standard tree-sitter pattern: commit generated
`parser.c` + `scanner.c` + the MIT C runtime; compile with `zig cc`;
extern `tree_sitter_ring()`. Days old — pin a commit, expect churn.

## 6. The Zig substrate (2026)

- **HTTP**: `std.http.Server` is not production-grade yet (std.Io
  landed in 0.16; maturing). **http.zig** (karlseguin, MIT) is the
  de-facto library-grade server — epoll/kqueue, Windows via threaded
  fallback, `websocket.zig` companion. **zap** is production-proven
  but no Windows (facil.io) — disqualifying for a
  Windows-first-class project. Choice: vendor http.zig.
- **SQLite**: the amalgamation (public domain) compiles cleanly with
  `zig cc`; **zqlite.zig** (same author as http.zig, tracks the same
  Zig versions) as the thin wrapper pattern.
- **JS engine**: **quickjs-ng** (MIT, releases every ~2 months,
  ES2023+, amalgamation script in-repo) over Bellard's original
  (brilliant but cathedral-paced) — and **txiki.js** as the living
  proof and reference for layering web APIs over it. **Kiesel**
  (Zig-native JS engine) is early-stage; watch, don't adopt.

## 7. The one-table summary

| From | RingServ takes |
|---|---|
| Pionia | services/actions/envelope, generic table services, two-hook middleware, docs-as-catalog |
| Hono | fetch-shaped handlers, app-as-function testing, tiny+vendored ethos |
| WinterTC / ECMA-429 | the standard API list for the JS guest; legibility to the web |
| ElectricSQL | shape logs over plain HTTP (read path) |
| Replicache | idempotent named-mutation push + rebase (write path) |
| Bolt / WebLib / RingHttpLib | the map of what exists; coexistence, not rivalry |
| tree-sitter-ring | the eyes of `check` and `docs` |
| http.zig / SQLite / quickjs-ng | the vendored muscle |
| RingScript | the method itself: vendor purity, resident bridge, oracle verification, artifacts-as-install |
