# Vendor patches to ringvm/

`ringvm/` is the vendored Ring VM source, **Ring master at
[`8a89cc00c2`](https://github.com/ring-lang/ring/commit/8a89cc00c2)** —
the same base RingScript took on 2026-08-16. Patches are marked with
`RINGSERV` or `RINGSCRIPT PATCH` comments at the site. **Any future vendor
swap must re-apply the live ones** — then run `zig build` (`-j2` on the
project host, see [GATES.md](GATES.md)) and
`node tests/all.js`.

## The base, measured — and a correction this file owes

**The line above used to say "currently 1.27, from the official 1.27
distribution", and that was wrong.** It stayed wrong long enough to
generate a board row asking this repository to perform a swap it had
already performed on 2026-08-17, and Central carried that row for days on
the strength of this sentence. A vendored-source file whose first
paragraph names the wrong base is worse than one that names none: it is
believed.

`RING_VERSION_MINOR` says **27**, and that is not evidence of anything —
it says 27 *because a patch makes it say 27* (RingScript's state.h patch,
carried here). Reading the macro is how the wrong claim survived.

Measured 2026-08-21, ignoring line endings, over the files `build.zig`
actually compiles:

| against | files differing | lines |
|---|---:|---:|
| the official **1.27** distribution (`D:\Ring127/language/src`) | 16 | 631 |
| **master**, as vendored by RingScript | 3 | 91 |

And all three of those files are **this repository's own work** —
`ring.h` (4 lines of declarations), `general.c` (78, patches 9 and 10) and
`vmerror.c` (9, the thread-local variant of patch 2). There is no upstream
delta left to take.

## Which of the patches below are still ours

The audit the swap makes possible, and the one RingScript ran on itself
(three of its seven became upstream code and were deleted rather than
re-applied). Ours:

| # | file | status |
|---|---|---|
| 1 | `vmeval.c` | **live**, and shared — RingScript carries the same one |
| 2 | `vmerror.c` | **live**, and RingServ-only in its thread-local form |
| 3 | `stmt.c` | **UPSTREAM NOW** — the file is master's; nothing to re-apply |
| 4 | `vmexpr.c` | **UPSTREAM NOW** — the strtod guard is in master |
| 5 | `vm.c` | **live**, and shared (the computed-goto loop) |
| 6 | `vmoop.c` | **live**, and shared (the object template cache) |
| 7 | `rlist.c` sort | **UPSTREAM NOW** |
| 8 | `rlist.c` accessor | **gone** — withdrawn on evidence, and master does not carry it |
| 9 | `general.c` | **live**, RingServ-only (the load anchor) |
| 10 | `general.c` | **live**, RingServ-only (the library search root) |

Sections 3, 4, 7 and 8 below are kept as **history, not as instructions**:
they record why a change was made and how it was measured, and a future
swap must not try to re-apply them.

## Before you call Ring from C: the door is `ring_vm_callfuncwithouteval`

Not a patch — a note kept here because this is the file anyone touching
the vendored VM reads first, and it costs a whole day to learn otherwise.
RingServ does not call Ring from C today (grep for either symbol outside
`ringvm/` returns nothing), so this is **preventive, not a defect**.

`ring_vm_callfunction` reads as the general-purpose door and is not one.
In this very tree, `ringvm/src/vmeval.c:34` has it delete the *calling* C
function's frame (`RING_VM_DELETELASTFUNCCALL`) before loading anything,
then set `pVM->lActiveCatch = 1` at `:44` under the comment *"Avoid normal
steps after this function, because we deleted the scope in Prepare"*. The
VM is left mid-catch, so the **next** Ring call from that same C function
dies with *"Deleting scope while no scope"* — a message that names
nothing about the code that reported it.

Use what Ring itself uses: `ring_vm_callfuncwithouteval`, at
`ringvm/src/vmerror.c:43` and `ringvm/src/vmoop.c:1402`. It saves the PC,
runs the function and pushes the result — no frame deletion, no
`lActiveCatch`, and errors raised from C with `ring_vm_error` stay
catchable.

Found by microring, which paid for it twice from opposite directions, and
routed here by Central on 2026-08-23 (MICRORING-VMCALLBACK-01) after
verifying the diagnosis against *these* line numbers. The reusable half
is not the function name: it is that **a name describing an API more
generously than its body does costs every reader the same day, one at a
time, and none of them can see the previous one paying it.**

## 1. `ringvm/src/vmeval.c` — keep line numbers in eval'd bytecode

Upstream wraps the eval parser call in `lNoLineNumber = 1 … = 0`, which
strips `ICO_NEWLINE` instructions from eval'd code. The bridge runs all
user code through `eval()` (the try/catch shim in `bridge.zig`), so that
would freeze `pVM->nLineNumber` at the try-entry line. The patch removes
the forcing so the state's flag (default 0) is respected.

## 2. `ringvm/src/vmerror.c` — capture the failing line at error time

Adds a global `unsigned int rs_error_line` set from `pVM->nLineNumber`
at the top of `ring_vm_error()` (after the active-error guard). Needed
because `ring_vm_catch → ring_vm_restorestate` rewinds the VM's line
number to its try-time value *before* the catch block runs — by the time
`rs_reporterror` fires, the line is gone from the VM. The bridge reads
`rs_error_line` via `extern var` (bridge.zig).

Together these make `rs_last_error()` report the real failing line for
multi-line evals (e.g. an error on line 3 reports `line 3: …`).

## 3. `ringvm/src/stmt.c` — fix `private` inside eval (upstream crash)

In the `K_PRIVATE` handler, `pParser->nClassMark` (from `newlabel2`) is a
GLOBAL instruction number (`pGenCode size + nInstructionsCount`), but
`ring_parser_icg_getoperationlist` indexes the LOCAL `pGenCode` list. With
any prior code in the state the raw index reads far past the list. This
crashes **stock native Ring 1.27** too — `eval("class q private b = 2")`
kills ring.exe — and since the resident bridge routes everything through
eval, every class with a `private` section crashed the wasm instance.
The patch subtracts `nInstructionsCount` at the lookup. Worth reporting
upstream (a real crash bug, unlike the global/attribute scope rule).

## 4. `ringvm/src/vmexpr.c` — strtod errno portability (musl vs MSVC)

In `ring_vm_stringtonum`, the error branch fires when `strtod` returned 0
with `errno` set. On no-conversion input, musl (wasi-libc) sets `errno`
to EINVAL while MSVC/glibc leave it untouched — so `"test" = 5` raised
`R41 Invalid numeric string` under wasm where native prints `0` (false).
The patch adds a `cEndStr != cStr` guard so plain no-conversion falls to
the existing no-conversion branch. Portability fix, worth upstreaming
(bites any musl-based Ring build, not just wasm).

## 5. `ringvm/src/vm.c` — the computed-goto dispatch loop, written

The vendor scaffolded this one and left it to be filled in: `vm.h`
declares `ring_vm_computedgoto()` under `#ifdef RING_VM_COMPUTEDGOTO`,
`ring_vm_mainloop()` calls it, and the comment says it "must be written
if RING_VM_COMPUTEDGOTO is enabled". The patch appends that function,
GENERATED mechanically from `ring_vm_execute()`'s switch — one label per
opcode, bodies identical, label table in `codegen.h` enum order — so
fetch, dispatch and the stack check live in one loop with no function
call per instruction.

Purely additive and guarded: without `-DRING_VM_COMPUTEDGOTO`
(build.zig sets it) the file compiles exactly as stock. Measured in
wasm: nothing at `-Os` (clang lowers switch and goto to the same
`br_table`), a consistent ~9% on dispatch-bound code once the VM core
is compiled `-O2`. Behavior is held identical by the oracle battery
(~850 programs byte-exact vs native). If the opcode enum ever changes,
the function must be regenerated — a stale table dispatches the wrong
opcode. Worth offering upstream, since the hook is the vendor's own.

## 6. `ringvm/src/vmoop.c` — one call out to the object template cache

`new X` on an attributes-only class re-executes the class-region
bytecode on every instantiation, wrapped in a full VM state save/restore
— identical work producing identical NULL attributes each time
(measured: 31x a Lua table). The patch is two lines in
`ring_vm_oop_newobj`: an extern declaration and one guarded call, placed
where the state save was about to happen. Everything else — the static
region-bytecode scan that proves a class is bare-attributes-only, the
name table, the replay, Ring's documented global-vs-attribute conflict
rule (any cached name visible as a global falls back to the normal
path), the reset lifecycle — lives in RingScript's own `src/rs_oop.c`.
Ineligible classes (defaults, private sections, parents, executable
statements) never leave the stock path. Held identical by the gates'
oop phase (written against the unpatched VM first) and the full oracle
battery, which caught and now guards the conflict rule.

## 7. `ringvm/src/rlist.c` — `sort(list, nColumn)` was O(n²)

`ring_list_sortnum_gc` / `ring_list_sortstr_gc` extract keys, quicksort an
index array, then rebuild the list by reading `pList` at `idx[i]` — in
sorted order, which is to say randomly. Without the items array,
`ring_list_getitem` walks the linked list, so the rebuild is quadratic.

Measured on stock Ring, sorting `[key, index]` pairs: **2.3 / 8 / 39 /
257 ms** at 2.5k / 5k / 10k / 20k rows — quadrupling per doubling — while
sorting the same values as a flat list stayed linearithmic (0.4 / 0.6 /
1.3 / 4.0 ms). The patch calls `ring_list_genarray_gc()` before the
rebuild when `nColumn != 0`. After it: **0.9 / 2.1 / 6.0 / 16.4 ms**.
Sorting rows by a column is what every data table does; worth upstreaming.

## 8. `ringvm/src/rlist.c` — random list access built the array instead of walking

The list cache (`pLastItem` / `nNextItem`) is a **cursor**: it makes
sequential access O(1) and does nothing for random access, which falls
through to a linear walk. So any pass over a large list through a
permuted index — exactly what "sort the table, then total the visible
rows" produces — is O(n²).

Measured on a ledger app, after sorting: one aggregate pass over 20,000
rows took **1.16 s**, and over 50,000 rows **19.8 s**. The patch makes
the fallback build the items array once (above
`RING_LIST_ARRAYONRANDOMACCESS`, 64 items) and answer from it, instead of
walking. Every structural mutation already calls
`ring_list_clearcache_gc`, which frees the array, so it cannot go stale;
`ring_list_genarray_gc` does not call back into the accessor, so there is
no recursion.

After: **11.3 ms** at 20,000 rows (33×) and **31.3 ms** at 50,000 (184×);
the leaderboard pass went 1162 → 96 ms and 19,758 → 277 ms. Cost is one
n-pointer allocation on the first random access, repaid on the second.
Held by the full oracle battery — ~850 programs still byte-exact — since
this is the VM's most-used accessor.

> ### Read this before trusting the paragraph above — added 2026-08-15
>
> **This exact change was proposed upstream as the second half of
> [#1642](https://github.com/ring-lang/ring/pull/1642) and rejected**, and
> the rejection measured out correct. RingScript carried the same patch,
> re-measured it, and **withdrew it**; RingServ still has it, at
> `ringvm/src/rlist.c:322`.
>
> Mahmoud's objection: building the array has a cost, and a program that
> *mixes* adding and reading creates and destroys it repeatedly. Two builds
> differing in nothing but this change came out **1.7–2.3× slower on mixed
> add/read**.
>
> **And the reassurance in the last sentence above is the trap.** The
> ~850-program byte-exact oracle was green *with the patch in place* —
> because none of those programs does mixed add/read at scale. **A
> correctness corpus is silent about performance, and silence reads like
> approval.**
>
> This does not automatically make the patch wrong *here*. RingServ serves
> data tables, and a build-once-then-read-many workload is the favourable
> case — the one where the patch wins. But that has never been measured on
> RingServ's own workload, and the numbers above only measure the half that
> flatters it.
>
> Full reasoning and Mahmoud's exact words: **RingUpstream**,
> [`REGISTER.md`](https://github.com/mayouni/ringupstream) Part 6.

## The A/B, run 2026-08-17

Two builds differing in **nothing but this patch**
(`zig build` against `zig build -Dno-arraycache`, the `#ifndef` at
`ringvm/src/rlist.c:321`), same benchmark file
(`tests/fixtures/bench-lists.ring`), two runs each. Times in ms.

**Upstream's objection reproduces.** Append and read the *same* list,
interleaved — every append frees the array, every read rebuilds it:

| n | patch ON | patch OFF | |
|---:|---:|---:|---|
| 2,000 | 2 – 3 | 1 | |
| 10,000 | 68 – 70 | 41 – 43 | **1.65× slower** |
| 20,000 | 315 – 331 | 144 – 157 | **2.1× slower** |

That lands inside the 1.7–2.3× Mahmoud measured. The rejection was
right about the cost, and this build has it too.

**The win is real, and larger.** Build once, then read by a permuted
index — the "sort a table, then walk the rows" shape:

| n | patch ON | patch OFF | |
|---:|---:|---:|---|
| 2,000 | 0 | 0 – 1 | |
| 10,000 | 1 – 2 | 25 – 26 | **~15× faster** |
| 20,000 | 3 – 4 | 157 – 187 | **~45× faster** |

**And RingServ's own workload cannot tell the difference:**

| measurement | patch ON | patch OFF |
|---|---:|---:|
| query + build rows ×10, n=500 | 24 – 25 | 25 – 27 |
| `JsonEncode` rows ×10, n=500 | 2 | 1 – 2 |
| walk rows, read a field ×10, n=500 | 1 – 2 | 1 – 2 |
| query + build rows ×10, n=2000 | 159 – 160 | 160 – 163 |
| `JsonEncode` rows ×10, n=2000 | 9 | 9 – 11 |
| walk rows, read a field ×10, n=2000 | 8 | 8 |

Every figure is inside run-to-run noise. The reason is structural: a
query result is **built by appending and then read sequentially**, which
the cursor cache already serves, and a row is a 4-item list — far under
the 64-item threshold that triggers the array at all. RingServ's
response path never reaches the code this patch changes.

### What the numbers support, and what they do not

They support **keeping** it: the case it wins is ~45× and the case it
loses is ~2×, and the losing shape (appending to a list while indexing
*that same list*, at ten thousand items) is rarer in service code than
"read a query result by index" — which is what an application doing its
own sorting or aggregation over rows will write. Without the patch that
application meets a cliff (157 ms against 3 ms at 20,000 rows) with
nothing in the error to explain it.

They do **not** settle two things, and neither is a measurement:

- **Family consistency.** RingScript, same author and same family,
  withdrew this patch and now calls `ringvm_genarray(aList)` explicitly
  where a list stops being mutated. MicroRing carries it too. Three
  projects disagreeing about a vendor patch is a maintenance fact, not
  a performance one.
- **The pending VM swap.** Carrying a rejected-upstream change through
  a swap is exactly what makes swaps expensive.

The toggle stays in the tree either way, so the decision is one build
flag and this table is reproducible by anyone who doubts it.

---

# The 2026-08-17 VM swap

The vendored tree is now **Ring master `8a89cc00c2`** — the same tree
RingScript swapped to on 08-16, taken wholesale, because RingServ's
`ringvm/` came from RingScript's and the two are byte-identical again.
`version()` still reports **1.27**, on RingScript's reasoning: master is
1.27 plus fixes with no features, and the version a user tests against
matters more than the commit the source came from.

**Local patches: 7 → 4.** Three left with the swap:

| patch | why it went |
|---|---|
| `private` inside `eval()` (stmt.c) | landed upstream — the fix in the tree is our logic, minus our comment |
| `strtod`/errno on musl (vmexpr.c) | landed upstream |
| the #1642 random-access accessor (rlist.c ×3) | rejected upstream, withdrawn by RingScript, and **[measured indifferent for RingServ](#the-ab-run-2026-08-17)** — keeping it would mean hand-porting a rejected change onto a new file at every future swap, for a benefit our own workload cannot detect |

The four that remain are the ones the bridge depends on: the
computed-goto dispatch loop (vm.c), the error-line capture (vmerror.c),
`ICO_NEWLINE` kept in eval'd bytecode (vmeval.c), and the object-cache
hooks (vmoop.c).

An application that *does* want random-access-after-sort has the
supported route the language already provides: `ringvm_genarray(aList)`,
called where a list stops being mutated. That is what RingScript does.

## What the swap broke, and what caught it

**Taking a file wholesale silently reverted a RingServ-only edit.**
`rs_error_line` in `vmerror.c` is `_Thread_local` here — RingServ runs N
worker threads, so a shared global would let one worker's failing line
overwrite another's. RingScript has no such need and its file declares a
plain global; copying it over dropped the qualifier.

The failure mode was quiet and would have been easy to shrug at:
`bridge.zig` declares the symbol `extern threadlocal`, so Zig read a
thread-local slot that C never wrote and **every error reported
`line 0`** — no link error, no crash, just a runtime that had lost its
line numbers. The phase-1 gate *"errors carry real line numbers and the
state survives"* failed on the first run after the swap, which is the
entire reason that gate exists.

Both sides are thread-local again, and `vmerror.c` now carries a comment
saying so, because this is exactly the edit the next swap will drop.

## Verification

- All **12 gate suites** green, including both wide sweeps.
- Sample sweep unchanged at **249 exact / 62 ran / 0 mismatch**, and the
  native-failure count did **not** rise — the thing RingScript warned to
  watch, since our VM now carries fixes the 1.27 oracle lacks.
- `eval("class q private b = 2")` now runs here and prints its result;
  **native `ring.exe` 1.27 dies silently on it**, producing no output.
  That is the swap visibly working, and a live demonstration that the
  differential oracle is now behind the VM it checks.

## 10. `ringvm/src/general.c` — the library search root

One block inside `ring_general_fopen()`, marked `RINGSERV PATCH 10`, and
it sits immediately after patch 9's anchor resolution: if the anchored
path does not exist, ask whether an installed Ring has this name, and if
it does, open THAT and anchor to where it lives.

**Why it is needed.** `RINGSERV-LOADROOT-01` was ruled DEPEND — a general
Ring application server may require a Ring installation and need not carry
its own search root. The fallback itself lives in `src/native_stubs.c`
(`rs_library_resolve`), reached through `rs_fopen` for every ordinary
open. This function is the exception: **on Windows it calls `_wfopen`
directly**, which the `-Dfopen=rs_fopen` redirection never reaches. That
is the same reason patch 9 exists here rather than in the stub layer.

**The symptom it cured, which is worth keeping.** With the fallback in
`rs_fopen` alone, Ring's loader checked existence through the redirect
(found the file), then opened through `_wfopen` (did not), and reported
`Can't open file` **for a file it had just located**. Two different
answers to the same question, from two paths that must agree.

**And the anchor half.** Ring's loader switches to a loaded file's folder
using the name *as written*, so a bare name moves nothing. Correct for a
file beside the anchor, wrong for one found in an installation — its own
dependencies are written `/../../libraries/...`, relative to where it
lives, and without the move they resolve against the application. So a
home-resolved open anchors to that file's directory; the VM's own
save/restore around each load scopes it.

**Verification**: `node tests/loadroot-gates.js` — nine gates, and they
**skip themselves entirely when no Ring is installed**, because the ruling
says MAY and a suite that failed without an installation would have turned
that into MUST.

## 9. `ringvm/src/general.c` — the load anchor, given somewhere to point

Three functions, marked `RINGSERV`. `ring_general_chdir()` and
`ring_general_currentdir()` delegate to `src/rs_path.c`, and
`ring_general_fopen()` resolves its path through it first.

**Why it is needed.** RingServ builds with `-DRING_LIMITEDSYS=1`, which
sets `RING_CURRENTDIRFUNCTIONS` to `0` — upstream's own switch for
platforms without them. That leaves `ring_general_chdir()` a no-op
returning success and `ring_general_currentdir()` a function that writes
one NUL and nothing else. But **`chdir` is how Ring anchors a nested
`load`**: `ring_state_runfile()` switches into a loaded file's folder
while it is scanned, and the caller switches back. With the switch off,
every anchor move did nothing, so every nested relative `load` collapsed
to the process directory and **no multi-file Ring library could be loaded
at all**. `currentdir()` called from Ring returned uninitialised memory
for the same reason.

**Why not just turn the switch on.** `chdir` is process-wide and RingServ
runs N workers that each evaluate the app at boot; two of them anchoring
into different library folders at once is a failure nothing reproduces
twice. `src/rs_path.c` gives each thread a **virtual** working directory
instead, and the real one is never moved.

**Why `ring_general_fopen` too, and not only the stub layer.** Its
Windows branch calls `_wfopen` directly, which the `-Dfopen=rs_fopen`
redirection in `build.zig` does not reach — without this line the fix
would work everywhere except Windows.

Not upstreamable as written: it is RingServ-specific. What *is* worth
raising upstream is the coupling itself — that `RING_LIMITEDSYS`, whose
name is about `system()` and `chdir()` as *user-facing functions*,
silently disables `load` path anchoring as a side effect, with no
diagnostic. Held by `tests/loader-gates.js`, which runs native `ring` as
an oracle over the same fixture.

# Upstream fixes to pick up at the next vendor swap

Bugs fixed in Ring **after 1.27** that this vendored tree still has. These
are **not** patches to re-apply — they arrive for free with a newer Ring.
Six of them, verified against Ring's commit log on 2026-08-15. Worth
scheduling as **one** swap rather than six errands:

| fix | landed as | what the vendored 1.27 still does |
|---|---|---|
| `private` inside `eval()` | [`7acf95bf`](https://github.com/ring-lang/ring/commit/7acf95bf) | crashes — currently covered by patch 3 above |
| `strtod`/errno on musl | [`4014382a`](https://github.com/ring-lang/ring/commit/4014382a) | misparses at the edges — currently covered by patch 4 above |
| `memcpy()` zero-byte source | [`8675fe3a`](https://github.com/ring-lang/ring/commit/8675fe3a) | aborts the process |
| empty `catch` stack slot | [`cda2ecf0`](https://github.com/ring-lang/ring/commit/cda2ecf0) | leaks one slot per caught raise; `R4` at ~1003 |
| name folding in four lookups | [`b6aea3d5`](https://github.com/ring-lang/ring/commit/b6aea3d5) | `varptr("nTotal")` raises `R6`; `ring_state_findvar` silently misses |
| operator overloading with a list element | [`05dc3f49`](https://github.com/ring-lang/ring/commit/05dc3f49) | `o1 + a[1]` reads a type-confused pointer and the process dies silently |

**Done — all three were dropped by the 2026-08-17 swap above.**

## httpz — `posix.write` on a Windows socket (2026-08-25)

`vendor/httpz/src/worker.zig`, `HTTPConn.writeAll`.

**What it did.** Every DIRECT write to a connection — the ones that bypass
the buffered response path — failed on Windows and dropped the connection.
`posix.write` is `WriteFile` there, and `WriteFile` does not work on an
overlapped socket. Ordinary responses take another path, so everything
looked healthy.

**Two symptoms, one call, and they were investigated three weeks apart as
if they were unrelated:**

- **No .NET client could POST to RingServ on Windows.** PowerShell and
  every .NET Framework application send `Expect: 100-continue` by default;
  httpz answers it by writing `HTTP/1.1 100 Continue` straight to the
  socket. That write failed, and the request died with no reply.
- **SSE response streaming wrote nothing** — recorded in phase 18 as a
  Windows platform gap, with the suite skipping by name, on the reading
  that httpz's streaming did not survive being disowned. That reading was
  wrong about the cause and right about the fact.

**The patch.** `send()` on Windows, `write()` elsewhere. One expression.

**Found by deploying** (phase 13), not by testing: the first PowerShell
`Invoke-WebRequest` POST against a real deployment failed, and curl with
`-H "Expect: 100-continue"` reproduced it in one command. Neither the test
suite nor CI sends that header, and CI's Windows job passes because
`node`'s fetch does not send it either.

**What it bought.** `tests/stream-gates.js` runs 21/21 on Windows instead
of skipping 21, and `tests/streamgov-gates.js` 17/17 instead of 15.
