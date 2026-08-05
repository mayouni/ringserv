# RingServ documentation

The blueprint, in reading order:

1. **[vision.md](vision.md)** — why RingServ exists, what it refuses
   to be, and the two-player fullstack model with RingScript.
2. **[services.md](services.md)** — the primary paradigm: services,
   actions, envelopes, generic table services, typed contracts.
3. **[topology.md](topology.md)** — declared placement (`:local` /
   `:server` / `:both`) and the local-first sync protocol.
4. **[architecture.md](architecture.md)** — the planned layers: Zig
   core, resident Ring VM bridge, SQLite + ZQL, vendored substrate.
5. **[cli.md](cli.md)** — every `ringserv` command and its reasoning.
6. **[landscape.md](landscape.md)** — the study behind the design:
   Pionia, Hono, WinterTC/ECMA-429, local-first sync, Ring's existing
   backends, the Zig substrate.
7. **[roadmap.md](roadmap.md)** — phases 0–8, each with its gate.
