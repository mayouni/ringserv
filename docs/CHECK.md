# check and docs — how they know things

*Phase 5. Two commands, deliberately fed from **two different sources
of truth**, because neither one alone is honest about a language like
Ring.*

```bash
ringserv check          # syntax + contract agreement, before running
ringserv docs           # the API catalog as markdown
ringserv docs --json    # ...and as data, for tooling
```

## Syntax comes from tree-sitter

A vendored Ring grammar
([ysdragon/tree-sitter-ring](https://github.com/ysdragon/tree-sitter-ring),
MIT, pinned) parses every `.ring` file in the app folder *and* its
`tests/`, reporting `ERROR` and `MISSING` nodes as
`file:line:column` with the offending text:

```
app.ring:58:4: syntax error near `= )`
tests/broken.ring:1:8: missing syntax
```

The walk descends to the smallest node carrying the error, so the
report points at the token rather than the file.

## Structure comes from the VM

The application's declaration is *data the runtime already holds* —
services, their actions, any declared table, and every `Contract()`.
So `check` and `docs` evaluate the app in a scratch VM (memory
database, never served) and ask `__rs_catalog()`, rather than
reconstructing the same facts from an AST.

This is not laziness; it is correctness. Ring declarations can be
computed, and `architecture.md` §6 already fixed the rule: **runtime
truth stays with the VM.** An AST would be a second, weaker opinion
about what the program says.

What `check` then verifies:

| Finding | Severity |
|---|---|
| `Contract(:x)` names a service that is not declared | problem |
| a contract declares an action the service does not answer | problem |
| a service declares no actions and no table — it can never answer | problem |
| the application cannot be evaluated at all | problem |
| an action has no contract — its payload is unchecked | note |

Contracts on the **generic** actions of a table service (`create`,
`list`, …) are legitimate and are not flagged — that false positive
has its own gate.

Notes never fail the command; problems do. The exit code is CI-ready.

## What `docs` renders

The catalog, and only the catalog: the endpoint, the envelope, each
service (marking generic table services), each action, and each
contract's fields as a table of type / required / limits. Actions
without contracts are marked plainly rather than omitted — an
undocumented payload is a fact worth showing.

`--json` emits the same catalog as data, so other tooling never has to
parse the markdown.

## `check --json` speaks the Diagnostic Contract

**RingServ pins C2 v1.1** — `stzzui/doc/diagnostic-contract.md` and the
schema beside it, of 2026-08-20, vendored here at
`vendor/c2/diagnostic-contract.schema.json`. This paragraph is not
decoration: §3.3 of the contract makes recording the pinned version a
condition of conformance, and §4 puts the move under RingServ's own
decision rather than upstream's — which is why v1.0 held from 08-18 until
this repository chose to move, and `vendor/VENDOR.md` records why it did.

`--json` emits a **report object** — never a top-level array, which is
v1.1's whole point and a measured one: Ring 1.27's own jsonlib **wraps** a
bare top-level array in one extra level, so a court emitting an array is
read one level deeper than it meant — **silently**, which is the part that
matters. Not "unreadable": readable and wrong. `diagnostics` is present
even when empty, so clean is distinguishable from no output:

```json
{ "diagnostics": [
    { "code": "RS_SERVICE_UNANSWERABLE", "severity": "error",
      "message": "service `notes` declares no actions and no table …",
      "span": { "file": "app.ring", "line": 0 },
      "cites": [], "language": "ringserv" }
] }
```

**And the shape above round-trips.** Measured 2026-08-21 by Central on Ring
1.27: a whole C2 report encoded, decoded and re-encoded through `jsonlib`
comes back as the same document. That is the claim worth holding — not that
some other shape is bad, but that **this** one is read by the family exactly
as this court wrote it.

One trap that does not touch RingServ but is worth knowing when reading
other courts' output: inside a list, Ring's `List2JSON` renders a member as
`key: value` whenever that member is a **2-element list whose first element
is a string** — so `["line", 12]` collapses into an object key, while
`[12, 4]` does not. Every published statement of that rule said "two-string
list", and the second element's type is irrelevant. RingServ is unaffected
because its spans are objects and its `--json` is written as text by
`check.zig` rather than by `jsonlib`, but a court rendering attributes as
`[["k","v"], …]` emits the one shape that silently becomes an object.

Seven stable codes — `RS_SYNTAX_ERROR`, `RS_SYNTAX_MISSING`,
`RS_CONTRACT_UNKNOWN_SERVICE`, `RS_CONTRACT_UNKNOWN_ACTION`,
`RS_SERVICE_UNANSWERABLE`, `RS_ACTION_UNCONTRACTED` (the one warning) and
`RS_APP_UNEVALUABLE` — stable forever and never reused, which is the
promise a code carries.

Three details the contract decides and this implementation obeys:

- **`line: 0` means the whole file.** A contract naming a service that does
  not exist is not at a line; pretending otherwise would be a lie with a
  number in it.
- **`col` is omitted, not zeroed.** The schema requires `col >= 1` where
  present. A zero is not a missing column, it is an invalid one — and
  RingServ is the first court in the family to emit the field at all, which
  §"honest boundaries" reserved it for.
- **`cites` is empty, and honestly so.** A cite must name a stable
  identifier in a pinned instrument of law. RingServ pins none: its rules
  live in prose with section numbers that renumber, which is exactly what
  §2.5 forbids citing. Where no law applies, `[]` is the conforming answer,
  and the reader's pointer travels in `message`, where wording is free.

Conformance is executable: `node tests/c2-gates.js` (57 gates) drives all
seven codes and validates every envelope against the vendored schema — the
validator *reads* the schema rather than restating it, so a version bump is
felt here instead of being agreed with.

When a `stzzui` checkout sits beside this repository it also checks the pin
against the normative file — by **substance**, not by bytes. Byte-identity
was the first version of that gate and it was too strict by the contract's
own §4: a PATCH marks a correction that changes no requirement, and a court
pinned at `x.y` loses nothing by staying. It fired on v1.1.1, which corrects
a justification and moves nothing, so the gate now fails on a MAJOR.MINOR
difference and merely notes a patch. Absent a sibling checkout it skips:
RingServ's gates must never need another repository on disk.

**And one gate proves the family can read what this court emits** — the
whole point of an envelope contract, and the only claim here that is not
about RingServ alone. It runs `ring` against the real `--json` output,
decoding and re-encoding it with `jsonlib`, and requires the same document
back. It skips when no Ring is installed.

## The honest limits

- **The grammar is young** — pinned days after its first publication,
  and it will churn. It catches unterminated strings, unclosed
  brackets, stray parens and unclosed blocks; it does **not** reject
  every malformed construct (`func 123bad()` parses cleanly). There is
  a gate recording exactly that, so the boundary is visible rather
  than assumed. `check` is a linter with Ring-shaped eyes, **not** a
  second compiler.
- **A grammar that fails to load must never block work.** If the
  parser cannot be created, the syntax pass reports itself as skipped
  and the semantic pass still runs. `dev` and `run` never call `check`
  at all.
- **The semantic pass runs the application.** That is how it learns
  what was declared — so top-level side effects happen (against a
  scratch in-memory database). An app whose top level does something
  irreversible should not expect `check` to be inert.
- **Syntax errors suppress the semantic pass.** Evaluating a file that
  does not parse produces noise, not findings.

## Gates (`node tests/check-gates.js` — 21, all passing)

Seeded defects, because a checker that reports nothing is
indistinguishable from a checker that cannot see: unterminated string ·
stray paren · unclosed block · broken file under `tests/` · contract
for an undeclared service · contract for an unanswered action ·
service that can never answer · unevaluable app — each must be named
*and* fail. Plus: the clean scaffold stays silent, a contract on a
generic action is not a false positive, a missing contract is a note
rather than a failure, the known grammar limit holds, and the markdown
and JSON catalogs agree on the service set.
