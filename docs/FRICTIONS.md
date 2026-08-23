# Frictions — what real usage hits, and what became of each

Phase 13's practice ([PLAN.md](PLAN.md)): every friction that real usage
hits becomes either a **fix** or a **named refusal with a reason** — never
a shrug, never silence. The list is the deliverable; an empty disposition
column is the only failure state.

Lessons arriving from the author's proprietary applications appear here in
neutral wording, per the naming rule in PLAN.md's change log. Lessons from
[Comptoir](../examples/comptoir) and public users appear as themselves.

| # | Friction, as hit | Disposition | Where |
|---|---|---|---|
| 1 | A journal born under the older field discipline (16-hex truncated chains) could not move into a `Journal()` without breaking its own verification. | **Fixed** — `ringserv journal import` accepts the interchange dialect, verifies before writing, stores the original bytes, and native appends continue the imported chain. | `journal.ring`, 9 gates |
| 2 | A Latin-1 byte in a request body reached the journal — where nothing may be deleted — and permanently broke strict JSON consumers of that record. | **Fixed** — the HTTP door refuses non-UTF-8 bodies as 400, naming RFC 8259. | `serve.zig`, gate replays the byte |
| 3 | Re-hashing imported legacy records to the native 64-char discipline was considered and declined. | **Named refusal** — an inalterable record's chain is honoured, not upgraded: re-hashing would break the very chain the import exists to preserve. | `RsJournalCheckOne` |

*Add entries at the top. A friction with no disposition yet is written down
anyway, marked `open` — invisible frictions are the expensive kind.*
