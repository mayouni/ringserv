# The CLI

*One tool, the whole backend experience. `ringserv` is a single static
binary containing the Ring VM, the HTTP core, SQLite, and every
command below — a backend developer installs nothing else, not even
Ring.*

## The commands

### `ringserv new <name>`

Scaffolds a working fullstack skeleton — not an empty folder:

```
myapp/
├── app.ring          a running service (hello.greet) with a contract
├── topology.ring     everything :server — the simplest truth
├── data.ring         schema declarations (become SQLite tables)
├── public/
│   └── index.html    a RingScript page already calling hello.greet
└── tests/
    └── hello.ring    a passing test against the service
```

The scaffold runs immediately: `cd myapp && ringserv dev` answers on
:8080 with a page that round-trips a service call. First success in
under a minute — the RingScript starter-kit bar.

### `ringserv dev`

The daily loop: serve the app, watch the files, reload on change
(a fresh Ring state per reload — residency is for production, honesty
is for development), stream trapped errors to the console with real
line numbers. Serves `public/` and the RingScript runtime files so the
fullstack loop needs no second tool.

### `ringserv run app.ring`

Production mode: no watcher, resident state, N VM workers. This is
the deploy story: copy the binary and the app folder, run.

### `ringserv check`

Static analysis via the vendored tree-sitter-ring grammar:

- syntax errors with positions (before the VM ever runs);
- contract ↔ implementation agreement (see services.md §5);
- actions never referenced by any topology; services with no
  contract; payload fields read but not declared.

Exit code is CI-ready. `check` is a linter, not a second compiler —
runtime truth stays with the VM.

### `ringserv test`

Runs the app's `tests/` against a scratch server on an ephemeral port
with a scratch database: each test file declares calls and expected
envelopes. Contract conformance cases (valid payloads must pass,
each declared violation must 422) are generated automatically.

### `ringserv docs`

Renders the API catalog — services, actions, contracts, envelopes —
as markdown (and JSON for tooling) straight from the source. What
Pionia's `api:docs` proves: single-endpoint APIs are *more*
documentable than REST, because the catalog is a data structure, not
a URL archaeology.

### `ringserv build`

Produces the deployable: the `ringserv` binary plus the app baked
into a `dist/` folder — later, optionally, a single self-contained
executable with the app embedded (the `@embedFile` trick RingScript
uses for ringlib, applied to the whole app).

### `ringserv version` / `ringserv where`

The RingScript conventions, kept: print versions (RingServ, Ring,
SQLite), print the paths that matter.

## Design rules

1. **No configuration files for the tool itself.** The app declares
   (`Serv()`, `Topology()`); the CLI reads the app. No
   `ringserv.toml`.
2. **Every command works offline.** Nothing fetches anything, ever —
   the binary is the supply chain.
3. **Errors are envelopes, everywhere.** A trapped Ring error prints
   as `service.action line N: message` on the console and returns a
   500 envelope on the wire; the server never dies, the developer
   never sees a stack trace from Zig.
4. **The CLI is also a library.** Like RingScript's `lib.ring`, every
   operation is callable from Ring code — Softanza orchestrates
   RingServ programmatically without shelling out.
