# Vendor patches to ringvm/

`ringvm/` is the vendored Ring VM source (currently **1.27**, from
the official 1.27 distribution). It carries two deliberate RingScript patches, both marked
with `RINGSCRIPT PATCH` comments at the site. **Any future vendor swap
must re-apply them** — then run `zig build -Drelease=true` and
`node tests/gates.js` (the P2 line-number gates fail if either patch is
missing).

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

Patches **3 and 4 can be dropped** at the swap — they are now upstream. The
`sort()` fix in patch 7 was **merged** as the accepted half of #1642 and can
be dropped too.
