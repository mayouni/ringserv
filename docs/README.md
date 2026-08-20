# RingServ documentation

## Start here

1. **[getting-started.md](getting-started.md)** — ten minutes to a running
   application with a database, a validated API and a page that calls it.
2. **[fieldnotes-app.md](fieldnotes-app.md)** — one application built all
   the way through: data, contracts, a JavaScript service, placement,
   offline sync, tests and deployment. Every listing comes from
   [`examples/fieldnotes/`](../examples/fieldnotes), which runs — and
   `tests/guide-gates.js` fails the build if the guide and the code ever
   disagree.

## The guides

Each one answers "how do I", and says what it refuses to do.

- **[services.md](services.md)** — the primary paradigm: services,
  actions, envelopes, the three service forms, generic table services,
  typed contracts, and the actor seam.
- **[DATA.md](DATA.md)** — the schema layer and the plain-SQL query
  surface, and why this core carries no framework's query dialect.
- **[topology.md](topology.md)** — declared placement (`:site` +
  `:authority`), the manifest, and the local-first sync protocol with its
  convergence oracle.
- **[JS.md](JS.md)** — the JavaScript guest: what it is, what it
  deliberately is not, and where its one door out leads.
- **[cli.md](cli.md)** — every command and its reasoning.
- **[CHECK.md](CHECK.md)** — how `check` and `docs` know things, and what
  the young grammar cannot see.

## Running it for real

- **[TLS.md](TLS.md)** — RingServ terminates none. Why, what the proxy
  owes you, and why the decision is a refusal rather than a paragraph.
- **[BENCHMARKS.md](BENCHMARKS.md)** — numbers with the method beside
  them, including one finding published unresolved.
- **[WORKERS.md](WORKERS.md)** — the N-worker concurrency model, measured.
- **[WRITES.md](WRITES.md)** — why a write cost 10 ms, what it actually
  was, and the one-writer connection that fixed it.
- **[`examples/bangalo-server/`](../examples/bangalo-server)** — the
  profile that adopts an `stzAgentHost` from stzlib, agents-folder
  convention and read-only surface included. Code-complete against
  stzlib's real API; **does not run yet** — its own README explains the
  boundary this hit and why the fix is not this profile's to make.
- **[GATES.md](GATES.md)** — every suite, one command, and what is still
  thin.

## Design and history

- **[vision.md](vision.md)** — why RingServ exists and what it refuses to
  be.
- **[architecture.md](architecture.md)** — the layers: Zig core, resident
  Ring VM bridge, SQLite, vendored substrate.
- **[landscape.md](landscape.md)** — the study behind the design: Pionia,
  Hono, WinterTC/ECMA-429, local-first sync, the Zig substrate.
- **[roadmap.md](roadmap.md)** — phases 0–8, each with its gate and what
  it actually cost.
- **[VENDOR_PATCHES.md](VENDOR_PATCHES.md)** — every change to vendored
  code, and why.

---

**A note on these documents.** Where one of them states a limit, that
limit is real and usually gated. Where one records a mistake — a
measurement taken against a stale server, a benchmark cliff nobody
explained, a trigger installed in the wrong order — it is there because
the mistake was instructive and hiding it would make the rest less
trustworthy.
