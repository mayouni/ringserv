# The CLI

*One tool, the whole backend experience. `ringserv` is a single static
binary containing the Ring VM, the HTTP core, SQLite, and every
command below — a backend developer installs nothing else, not even
Ring.*

## The commands

### `ringserv new <name>` ✅

Scaffolds a working application — not an empty folder:

```
myapp/
├── app.ring          services, :data schema and contracts, in one file
├── public/
│   └── index.html    a page that calls them
└── tests/
    └── app.ring      ten expectations that already pass
```

The scaffold runs immediately: `cd myapp && ringserv dev` answers on
:8080 with a page that round-trips a service call, and
`ringserv test` is green before you have written a line. First
success in under a minute — the RingScript starter-kit bar.

It refuses to write into an existing folder: a scaffold that can
overwrite work is a scaffold nobody trusts.

**Two notes on what the scaffold contains.** The declaration lives in
one `app.ring` (services, `:data`, `Contract()`) rather than three
files — for an application this size, three files is ceremony;
splitting is a choice the developer makes when it starts to pay.
And the page is plain HTML + `fetch`, not a RingScript page: shipping
RingScript's runtime here would make RingServ depend on another
project's artifacts, and the whole client is one wrapper function
anyway. The page carries a comment showing the two-file upgrade to
Ring-in-the-browser.

### `ringserv dev` ✅

The daily loop: serve the app, watch its `.ring` files, restart on
change. A *supervisor over a child `run`*, deliberately — a reload
gets a genuinely fresh VM and a genuinely fresh database connection,
so what you see after saving is what a cold start would give you.
Residency is for production; honesty is for development.

Static files declared as `[ :static, "/", "public/" ]` are served by
the Zig core directly (a file is a file; the VM has no business in
that path), with traversal refused outright rather than normalized.

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

### `ringserv test` ✅

Runs every `tests/*.ring` against the app **in process**: `Ask()`
goes straight through the dispatcher, so services, contracts, generic
actions and the database are all exercised without a port, a client,
or a flake. (The HTTP layer is covered by this repository's own
gates, not by every application's tests.) The vocabulary is five
words:

```ring
aReply = Ask(:notes, :create, [ :title = "first" ])
ExpectOk("creates a note", aReply)
Expect("with a title", aReply[:data][:title], "first")
ExpectCode("refuses empties", aReply, 1)
ExpectStatus("...with a 422", 422)
```

The database is forced to `:memory:` whatever the app declares —
tests must never touch real data, and that is not the test author's
job to remember. Files run in sorted order (a run that shuffles
itself cannot be compared to the last one), and the exit code is
CI-ready.

*(`Ask`, not `Call`: `call` is a Ring keyword.)*

### `ringserv docs`

Renders the API catalog — services, actions, contracts, envelopes —
as markdown (and JSON for tooling) straight from the source. What
Pionia's `api:docs` proves: single-endpoint APIs are *more*
documentable than REST, because the catalog is a data structure, not
a URL archaeology.

### `ringserv journal <verb>` ✅

The fiscal record, from a shell. `Journal()` (docs/COMMONS.md §1) makes a
record the law may require to be **inalterable**; `RsJournalService()`
answers questions about it over HTTP. This is the same answer when **no
client is attached** -- which is the case the design was written for: the
box is in a drawer, an inspector is standing there, and the question is
whether the chain holds.

```
ringserv journal list   [app.ring]   the journals this app declares
ringserv journal verify [app.ring]   INTACTE or ROMPUE, and where
ringserv journal export [app.ring]   JSONL, one event per line

  --journal <name>   which journal (required when the app declares > 1)
  --db <path>        read this database instead of the declared one
  --out <file>       write here instead of stdout (export)
  --json             machine-readable verdict (verify)
```

**`verify` exits 1 on ROMPUE.** A verification command that always exits 0
is one no cron job can use, and this is exactly the check that belongs in a
cron job. It names the database it read on every run, because an export
whose provenance is implicit is an export nobody can hand to an auditor.

Three properties that are decisions rather than details:

- **It opens the application's own database.** `check`, `docs` and
  `topology` evaluate an app against `:memory:` because they read
  *declarations*. This reads *records*, so it must look at the same file
  the server writes.
- **It never creates the journal table.** Pointed at the wrong path, a
  command that creates what it cannot find would report an *empty record*
  where it should report a *missing* one. A missing table is printed as the
  fact it is -- and the message says outright that SQLite creates an absent
  file on open, so an empty one is not evidence anything was lost.
- **It decides nothing about which journal is meant.** That rule lives in
  Ring (`__rs_journal_cli`), beside the identical rule the HTTP service
  uses. A second copy in Zig would be a second answer, and the two would
  drift on the first application that declares three journals.

`export` is the germ's own interchange format, so a journal moves between a
Commons and a RingServ without translation: the table is the durable form,
the JSONL is the ambassador.


### `ringserv build`

Not yet built. Deployment today is already small — copy the binary
and the app folder, run `ringserv run app.ring` — so this command
waits until it earns its place (a single self-contained executable
with the app embedded, the `@embedFile` trick applied to the whole
app).

### `ringserv version` / `ringserv where` ✅

The RingScript conventions, kept: `version` prints the short line,
`where` prints the versions compiled in (RingServ, Ring VM, SQLite)
and the paths that matter.

### `zig build dist` — the shipped binaries

Cross-compiles the CLI for **windows-x64, linux-x64, linux-arm64
(both musl-static), macos-x64 and macos-arm64** into `bin/`.

**These are not committed**, deviating from the original plan. Each
build is ~32 MB across five targets — RingScript could commit its
artifacts because a static file server is 40 KB, but a binary
carrying the Ring VM, SQLite and an HTTP core is 2.5–12 MB, and
committing that on every release would bloat git history
permanently. They belong on releases instead; the install story
("download one file, run it") is unchanged.

The same reasoning governs **the RingPM package** (`package.ring`):
`ringpm install ringserv from mayouni` fetches a small package and its
`:setup` downloads the ONE binary the installing machine needs from the
tagged release. A machine that installs without a network still gets a
working package — `ringpm run ringserv` names the missing file, its URL
and its path, rather than failing later somewhere else.

Status, updated 2026-08-23: **all three platforms are built and tested
on every push** (`.github/workflows/gates.yml` — ubuntu, macos-14,
windows), and `zig build dist` proves all five shipped targets still
cross-compile. The cross-platform gate that stood open here is closed;
see the roadmap's phase 4 for the five defects that closing it found.

## Design rules

1. **No configuration files for the tool itself.** The app declares
   (`RingServ()`, `Topology()`); the CLI reads the app. No
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
