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
