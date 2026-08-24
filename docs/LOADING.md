# `load` in RingServ — what resolves, and what does not

*Ring's `load` is a compile-time directive. This page says exactly where
RingServ looks for the file, where it diverges from native `ring`, and
which load forms are held by a gate. It exists because RingServ used to
diverge here silently, and nobody could have known: no RingServ app had
ever loaded a multi-file library.*

Held by `tests/loader-gates.js`, several of whose gates run the native
`ring` interpreter as an ORACLE and compare byte for byte. *The count that
stood here was transcribed by hand and was three behind within a week; the
suite reports its own total, so this line no longer carries one.*

---

## The rule

**A nested `load` resolves against the directory of the file that
contains it.** `base/stzBase.ring` writing `load "common/stzIntSeq.ring"`
means `base/common/stzIntSeq.ring`, wherever the process happens to be
standing. That is Ring's rule and it is now RingServ's.

**A `load` in the application file itself resolves against the process
working directory** — *not* against the application's own folder. This is
also Ring's rule, and RingServ matches it deliberately rather than
improving on it. See "The one place this may surprise you" below.

## What used to happen, and why

RingServ hands an application's source to the VM as a **string**, through
the `rs_getcode` hook (`src/bridge.zig`), so the VM never opens the app as
a real file. That is not what broke it.

Ring anchors nested loads with a real `chdir`: `ring_state_runfile()`
switches into a loaded file's folder while it is being scanned and the
caller switches back afterwards. RingServ builds the VM with
`-DRING_LIMITEDSYS=1`, which sets `RING_CURRENTDIRFUNCTIONS` to `0` and
turned `ring_general_chdir()` into a **no-op that returned success** and
`ring_general_currentdir()` into a function that filled in nothing. So
every anchor move did nothing, every nested relative `load` fell back to
the process's working directory, and one directory had to satisfy a whole
load graph — which it can do for at most one level of it.

Two things follow from that shape, and both were true:

- it broke **every** multi-file Ring library, not one framework;
- `currentdir()` called from Ring code returned an **uninitialised
  buffer**, because nothing ever wrote to it.

## What the fix is

`src/rs_path.c`: a **per-thread virtual working directory**. `chdir` moves
this thread's idea of "here", `currentdir` reads it back, and every
relative path the VM opens is resolved against it first. The VM's own
anchoring logic was correct as authored and is now simply allowed to work.

**The process's real working directory is never changed.** That is not an
implementation detail — RingServ runs N worker threads that each evaluate
the application source at boot, and a process-wide `chdir` would let two
workers anchor into two different library directories at the same moment.
A load graph resolved half in one folder and half in another fails in a
way no test reproduces twice.

## Coverage — what resolves after the fix

| Form | Resolves against | Held by |
|---|---|---|
| `load "sibling.ring"` in a loaded file | that file's own directory | oracle + fixture |
| `load "child/x.ring"` in a loaded file | that file's own directory | oracle + fixture |
| `load "../cousin.ring"` in a loaded file | that file's own directory | oracle + fixture |
| `load package "x.ring"` | same, through the custom-global-scope path | oracle + fixture |
| `load again "x.ring"` | same, through the reload path | oracle + fixture |
| an **absolute** path at any depth | itself; the whole graph below it anchors per file | fixture, from an unrelated cwd |
| `load "x.ring"` in the **application file** | the **process working directory** | fixture, both ways |
| a bare name not found relative | `<exe folder>/x.ring`, then `<exe folder>/load/x.ring` — Ring's own fallback, unchanged | not gated (see below) |
| `load "/../../x.ring"` — Ring's own leading-separator form | the exe folder, concatenated; unchanged from the VM | not gated (see below) |
| `ringserv check` | identically to `ringserv run` — same parse | fixture |
| Ring's `currentdir()` | the virtual directory (was: uninitialised memory) | fixture |
| Ring's `chdir()` | moves the virtual directory only, never the process | fixture |

## What resolves now, and what still does not

**1. ~~Ring's own bundled libraries.~~ RESOLVED 2026-08-21 — a found
search root.**

`RINGSERV-LOADROOT-01` was **ruled DEPEND** on 2026-08-20: *a general Ring
application server MAY require a Ring installation to be present and NEED
NOT carry its own search root.* So RingServ does not carry one — it
**finds** one:

1. `RINGSERV_RING_HOME`, if set. The explicit answer, taken as given, and
   the only one an operator can rely on where PATH is minimal.
2. otherwise `ring` on PATH, whose parent is the home — a Ring
   installation puts its binary in `<home>/bin/`.

`ringserv where` prints what was found, or says plainly that nothing was.
A search root nobody can see is a search root nobody can debug.

A bare name that does not resolve against the anchor is then looked for at
`<home>/bin/` and `<home>/bin/load/` — the same two places, in the same
order, that native `ring` searches. **Only after the ordinary answer has
failed**, so an application's own file of the same name always wins, and a
path the author wrote with a directory in it (`load "mylib/util.ring"`) is
never satisfied from the installation.

Two things had to be fixed for the graph to follow, and both are worth
recording because neither was visible from the outside:

- **The leading-separator form.** Ring's bundled files reach their
  dependencies as `load "/../../libraries/stdlib/stdlib.rh"`. That leading
  separator is a *marker*, not a root — the path is relative to the file
  that wrote it, and `/../..` is never a meaningful absolute path since the
  root has no parent. It is now stripped and anchored. The test is narrow
  (separator followed by `..`) so a genuine POSIX absolute path cannot take
  that branch.
- **The anchor has to follow the file into the installation.** Ring's
  loader switches to a loaded file's folder using the name *as written*,
  which for a bare name moves nothing. Correct for a file found next to the
  anchor; wrong for one found in an installation, whose own dependencies
  are written relative to where *it* lives. Resolving from the home now
  anchors there too, and the VM's own save/restore around each load scopes
  the move to the file that caused it.

**Both halves, stated together, because a routing memo once said this
"makes every one of them resolve" and that was one half:** every Ring
LIBRARY now resolves — no file is left unfound — and Ring's bundled
`stdlib.ring` still does not **run**. What stops it is a missing *host
function*: `loadlib`, because `dll_e.c` is deliberately absent from
`build.zig` (`RING_NODLL`), and `ismainsourcefile`, a CLI-layer builtin a
server has no meaning for. The boundary moved outward as the search root
improved, and it is now exactly where item 3 says it should be: at what
this binary declines to be, not at what it cannot find.

**How a library's own dependencies follow.** A file found in the
installation is remembered by its DIRECTORY, and that set — most recent
first, bounded at 16 — is the last resort when the anchor misses. Two
earlier designs were wrong and both are worth recording:

- **Moving the anchor was wrong.** `scanner.c` saves the current directory
  *after* opening the file, so a move made during the open lands inside the
  VM's own save window and is then "restored" as though it had always been
  the anchor. Every relative load for the rest of the run resolved from the
  installation. stzlib found it four directories deep.
- **One remembered directory was wrong.** A graph descends into
  `extensions/ringpostgresql/`, returns, and a file back in
  `libraries/stdlib/` asks for a sibling — which a single variable can no
  longer find. Descend-and-return is the ordinary shape of a library graph.

A stack is the exactly-right structure and needs a "this scan has ended"
signal the VM does not give this layer. The bounded set is the honest
approximation, and it is consulted **only after the anchor has already
missed** — so it can rescue a path that would otherwise be an error and can
never redirect one that already works.

Measured 2026-08-22: `load "stdlibcore.ring"` loads and runs by bare name,
and `load "stdlib.ring"` resolves its **entire graph with no file left
unfound** — stopping at a missing *function*, not a missing file. Held by
`tests/loadroot-gates.js`, which **skips itself entirely when no Ring is
installed** — the ruling says MAY, and a suite that failed without an
installation would have quietly turned that into MUST.

**2. A name RingServ's own embedded library already defines.**

Every application's VM is preloaded with `src/ringlib/*.ring`, whose
functions live in the same global namespace the application's libraries
do. A library defining a function of the same name dies with
`C22 Function redefinition` and the message does not say who the other
definition belongs to.

One such collision was removed with this fix, because Ring's own standard
library forced it: `actor.ring` defined a bare `split`, and
`libraries/stdlib/stdlibcore.ring` defines `Func Split` — so
`load "stdlib.ring"`, the most ordinary line in Ring, was fatal. It is
now `RsSplitOn`. **Keep new names in `src/ringlib/` prefixed.**

That collision is **also closed, on 2026-08-21**, and by the better of the
two available fixes. `testing.ring` defines `Ask` — an ordinary English
word — and was loaded into every VM, including `run`, `serve` and `check`,
which have no use for it.

`RINGSERV-RINGLIBNS-01` was **ruled SCOPED, NOT RENAMED**: the vocabulary
now loads for `ringserv test` and nothing else, so `Ask` **keeps its name**
and no RingServ user pays a compatibility cost for a scope defect that was
never theirs. The collision went away by removing the *exposure* rather
than the word.

What that leaves, deliberately: an application that defines its own `Ask`
now **serves perfectly** and collides only under `ringserv test`. Ring
reports that as a bare `C22 Function redefinition` with no hint where the
other definition came from, so `test` recognises it and names the whole
vocabulary — `Ask`, `Expect`, `ExpectOk`, `ExpectCode`, `ExpectStatus`,
`ExpectTrue` — and says the application itself is fine. A diagnosis rather
than an afternoon.

**3. `loadlib`, and therefore every Ring extension.**

Reached only once the search root above is solved, and found by the same
measurement. With the whole graph resolving, `load "stdlib.ring"` then
dies with `Error (R3) : Calling Function without definition: loadlib` —
because `ringvm/src/dll_e.c` is deliberately **not** in `build.zig`'s
source list (`RING_NODLL`), so a RingServ binary cannot load a native
extension at all. That is a considered property of a single static
executable, not an oversight.

It is recorded here because it **bounds item 1, which is now done**: the
search root makes every Ring *library* resolve, and still does not make
Ring's bundled `stdlib.ring` run. That is not a defect to be fixed later —
a static binary that cannot load a native extension is a considered
property. Anything reporting the search root must report both halves, and
`ringserv where` does.

**4. Symbolic links.** `..` is resolved textually, not through the
filesystem, so a path crossing a symlink normalises to somewhere a real
`chdir` would not have gone. This is the only place the virtual directory
differs from the interpreter's real one.

## The one place this may surprise you

`ringserv run apps/foo/app.ring`, from a directory that is not
`apps/foo/`, will **not** resolve a `load "lib/util.ring"` written inside
`app.ring` — the same as `ring apps/foo/app.ring` would not. Only files
loaded *below* the top level are anchored to their container.

RingServ could have anchored the top level to the application's folder,
and there is a real argument for it: `:js` and `:static` paths already
work that way, and `src/bridge.zig` says why. It does not, because
matching the language it hosts is worth more than being right about one
line, and because a divergence in this direction is the harder kind to
discover — a program that works under `ringserv` and not under `ring`.
`tests/loader-gates.js` asserts the current behaviour in both directions,
so changing it means changing a gate and saying so.

Until then: run from the application's directory, or write the path
absolutely.

## `eval`'d `load` — the one form that looks configurable and is not anchored

**Added 2026-08-24, measured rather than reasoned, because this form is
being proposed across the estate as the way one repository depends on
another.** Ring's `load` takes a literal string, so a path cannot be a
variable. `eval` has no such restriction, and the pattern that follows is
the obvious way out:

```ring
$cDir = sysget("SOME_DIR")
if $cDir = ""
    $cDir = "../../other/checkout"        # <-- the trap is HERE
ok
eval('load "' + $cDir + '/thing.ring"')
```

**Both halves work in RingServ.** `eval` resolves the constructed `load`,
and `sysget` is present — `RING_EXTRAOSFUNCTIONS` is gated on
`RING_LIMITEDENV`, which this build does not set, so `-DRING_LIMITEDSYS=1`
never removed the environment functions. Verified by running them.

**But an `eval`'d `load` is a TOP-LEVEL load, wherever the `eval` sits.**
Its relative path resolves against the **process working directory**, not
against the file containing the `eval`. Measured with one script and three
working directories: identical command, absolute path to the script every
time.

| started in | result |
|---|---|
| the folder the relative path is written against | resolves |
| any other folder | `Error (E9) : Can't open file …` |

So **the environment variable is a genuine improvement and the relative
fallback beside it is a regression.** An absolute path a reader is told to
edit fails in exactly one way, visibly, on the first run. A relative
fallback fails only for readers who start the process somewhere else, and
it reports a missing file rather than a wrong configuration — which sends
them looking for the file instead of for their working directory.

**The recommendation this page makes:** variable first, then an **absolute**
default. Never a relative default. `examples/bangalo-server/app.ring` is
written that way, with the measurement in its comment.

*This is not a RingServ divergence — it is the "one place this may surprise
you" above, reached through a door that looks like it should behave
differently. Native `ring` does the same thing, confirmed independently by
ringupstream against stock 1.27 on 2026-08-24, including that a top-level
miss is a hard error with no fallback to the script's own folder.*
