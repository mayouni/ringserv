pinned:
- httpz: branch zig-0.15 @ 1a4d53b95bc4ac6c84cbc081727428de40c8c635
- metrics: 603954879849c331a26529b88254770089acac8b
- websocket: 4deaaef2b4475a63f19c5e2f43e38fd55464b118
- sqlite: amalgamation 3.53.4 (2026), public domain, from sqlite.org/2026/sqlite-amalgamation-3530400.zip
- tree-sitter runtime: 277f53f886de938bb686703ce593b36184ef5470 (MIT)
- quickjs-ng: **v0.16.1**, vendored source, four translation units (quickjs.c, dtoa.c,
  libregexp.c, libunicode.c) — MIT. quickjs-libc.c is DELIBERATELY ABSENT:
  it would hand the guest files, processes and sockets, and the JS guest's
  whole promise is that its host surface is ECMA-429's, implemented once in
  Zig. tests/js-gates.js keeps that true.
- tree-sitter-ring: ysdragon @ 946a10c9736251c235e387a063c9a873b105ecdd (2026-08-06, MIT) — days old, pinned; expect churn

pinned instruments (law, not code — vendored so a gate can run with no sibling
repository present, and held byte-identical to upstream by tests/c2-gates.js):
- c2/diagnostic-contract.schema.json: the Diagnostic Contract envelope, **v1.1**
  of 2026-08-20, normative home stzzui/doc/diagnostic-contract.md. RingServ
  pinned v1.0 from 2026-08-18 and **moved to v1.1 on 2026-08-20 by its own
  decision**, per §4 "Consumers pin" — the decision Central returned unruled
  because this repository had reserved it.
  WHY MOVE, since a pin exists to be kept: v1.1 adds `definitions.report` and
  forbids a top-level array, on a MEASURED ground — Ring 1.27's own jsonlib
  returns a one-element list for a bare JSON array, so a court emitting one
  emits something the rest of the family cannot read, and it fails quietly.
  `ringserv check --json` emitted exactly that shape. Staying on v1.0 would
  have meant keeping a defect that had been demonstrated.

vendored from RingScript (same author, same project family), not from a third party:
- src/rs_json.c: the C JSON codec, held byte-identical to src/ringlib/json.ring by tests/gates.zig
