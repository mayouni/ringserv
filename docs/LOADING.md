# `load` in RingServ — what resolves, and what does not

*Ring's `load` is a compile-time directive. This page says exactly where
RingServ looks for the file, where it diverges from native `ring`, and
which load forms are held by a gate. It exists because RingServ used to
diverge here silently, and nobody could have known: no RingServ app had
ever loaded a multi-file library.*

Held by `tests/loader-gates.js` — eleven gates, of which three run the
native `ring` interpreter as an oracle and compare byte for byte.

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

## What still does not resolve, and why

**1. Ring's own bundled libraries — `load "stdlib.ring"`, `load
"jsonlib.ring"`, anything under a Ring installation's `bin/load/`.**

The VM's fallback for a bare name is `<exe folder>/` and then
`<exe folder>/load/`, where *exe folder* is the folder of the running
binary. For native `ring` that is `<ring>/bin/`, which is exactly where
those files live. For RingServ it is wherever `ringserv` was installed,
and a RingServ binary ships **no Ring installation beside it** — it is one
static executable with its own library embedded.

This is a **library search root** question, not an anchoring one, and
answering it means deciding whether a RingServ binary may depend on an
installed Ring. That decision has not been made, and this page does not
make it.

**Measured on 2026-08-20, in a pristine directory**, because the shape of
the answer matters: copy `ringserv.exe` into `<X>/bin/` and stage a Ring
installation's `bin/load/`, `libraries/` and `extensions/` around it in
**Ring's own layout**, and `load "stdlib.ring"` resolves its entire graph
— not one `Can't open file` remains. The layout is not incidental: Ring's
bundled files load their dependencies as `load "/../../libraries/..."`, a
leading-separator form that only lands correctly when the VM concatenates
it onto the exe folder, so a flat `load/` dropped beside the binary is not
enough.

Note what that measurement does **not** say — see 3 below.

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

One collision remains and is *not* fixed here, because it is a decision
about a documented surface rather than a defect: `testing.ring` defines
`Ask`, the `ringserv test` vocabulary, and it is loaded into every VM —
including `run`, `serve` and `check`, which have no use for it. Measured
on 2026-08-20 against stzlib: with `Ask` renamed in a throwaway build, a
~dozen-directory third-party library loaded **with no errors at all**, so
this one name is the only remaining namespace blocker for that library.
The fix is probably to load `testing.ring` only for `ringserv test`; that
is its own change, with its own gates.

**3. `loadlib`, and therefore every Ring extension.**

Reached only once the search root above is solved, and found by the same
measurement. With the whole graph resolving, `load "stdlib.ring"` then
dies with `Error (R3) : Calling Function without definition: loadlib` —
because `ringvm/src/dll_e.c` is deliberately **not** in `build.zig`'s
source list (`RING_NODLL`), so a RingServ binary cannot load a native
extension at all. That is a considered property of a single static
executable, not an oversight.

It is recorded here because it bounds the previous item: solving the
search root would make every Ring **library** resolve, and would still
not make Ring's bundled `stdlib.ring` run. Anything asking for the
search root should be told both halves.

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
