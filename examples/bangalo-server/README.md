# bangalo-server — a profile, not a coupling

*Answers prompts/40-ringserv-bangalo-server.md. Read `app.ring` first —
this file explains the shape and, more importantly, records a real
finding: **this profile does not run yet**, and why that is RingServ's
own boundary rather than stzlib's or this profile's.*

## What the vision asks for

The reference design names two hosts for a Bangalo agent: a dedicated
server on RingServ, for simplicity, and stzAppServer, for enterprise.
stzAppServer's half is built — `HostAgents()`/`AdoptAgentHost()` pump an
`stzAgentHost` inside the server's own reactor
(`stzlib/libraries/stzlib/base/appserver/stzAppServer.ring:616`), and it
publishes a read-only `GET /agents` surface beside it.

This folder is RingServ's half of the same idea, held to the jurisdiction
sentence this repository has argued for since C3: **RingServ stays a
general Ring application server.** The Bangalo profile is something an
app *may* adopt. Nothing in `src/` (RingServ's core) names `stzAgentHost`,
`stzAgentFolder`, or any other stzlib symbol — `app.ring`'s one `load`
line is the entire dependency, and it lives here, in an example, not in
the server.

## The design, as if it ran

- **One `stzAgentHost` per worker**, built once at boot from `app.ring`'s
  own top-level code — the same pattern `aRsServDecl` already uses for
  the app's own service declaration.
- **The folder is the deployment**: `agents/` holds `.pia` declarations
  and Ring-defined agents, mounted by `UseAgentsFrom("agents")` on
  whatever schedule each file declares for itself. Dropping a file in is
  the whole act of adding an agent; nothing else in `app.ring` changes.
- **The pump rides RingServ's own request loop**, because that is the
  only loop a RingServ app can reach. See "the pump" below — this is the
  profile's real design decision, not an afterthought.
- **A read-only `:agents` service** — `list`, `trace`, `get` — mirrors
  stzAppServer's `GET /agents` surface: name, kind, active/retired
  state, tick count, channel, and the last tick's timestamp (read from
  the host's own trace, not tracked a second time). No action can pause,
  resume or retire an agent. Effects stay where stzlib already puts
  them — behind the agent's own governed skills — never reachable over
  the wire, exactly as the ask required.

## The pump: honestly bounded, not idle-driven

stzAppServer owns its own reactor and interleaves a bounded socket slice
with `oAgentHost.TickDue()` on every pass of its `RunFor`/`Run` loop
(`stzAppServer.ring:264-296`) — agents progress whether or not a request
is in flight.

RingServ's worker loop (`src/serve.zig` `workerMain`) has no such idle
window: a worker blocks on `dequeue()` until a job arrives, serves it,
and blocks again. There is no timer, no idle callback, and — checked
directly — **no way for an app to install one without redefining
`__dispatch`**, which Ring refuses as a function redefinition (the same
C22 stzlib's own loader comment warns about) and which would in any case
be reaching into the dispatcher RingServ's core owns, not using an
extension point it offers.

So this profile ticks the host from **its own service actions** —
`oBangaloAgentHost.TickDue()` runs at the top of `list`, `trace` and
`get`. This is the one hook a RingServ app genuinely has: its own
declared handlers, called on its own worker's own request loop. State it
plainly:

- **Agents progress on traffic to this app, not on wall-clock time.** An
  idle Bangalo server with no requests does not advance its agents
  between them. Polling `:agents/list` on a cheap interval (a cron
  `curl`, a health-checker) is what stzAppServer's reactor gives you for
  free and this profile does not.
- An app that adds its own services beside `:agents` can call
  `oBangaloAgentHost.TickDue()` from its own actions too, tightening the
  cadence to whatever traffic it actually receives — that is an
  application decision this profile leaves open rather than makes for
  you.

## `:workers = 1`, and why it is pinned rather than left to the operator

RingServ gives every worker thread its own resident Ring VM and
evaluates the whole app file again in each one at boot
(`bridge.rs_eval(g_app_source)`, once per worker, `src/serve.zig`). An
`stzAgentHost` built at the top of `app.ring` is therefore built **again
per worker** — its own copy of every supervised agent, its own tick
counts, no shared state between workers unless the agents themselves
read and write through SQLite. `:workers > 1` would not scale one
Bangalo host; it would silently run N uncoordinated ones answering the
same `/api/v1`, which is the opposite of what "a dedicated server, for
simplicity" asks for. `app.ring` pins `:workers = 1` and says why at the
line, so nobody has to rediscover it by reading `serve.zig`.

## The `/agents` surface is a service, not a route — and that is not a compromise

stzAppServer owns its HTTP listener outright, so it can add whatever
path it likes; its `_ServeAgents` handler answers `GET /agents` directly
(`stzAppServer.ring:1066`). RingServ's core does not give an app that
power: `src/serve.zig`'s router is five fixed paths
(`/api/v1`, `/health`, `/topology`, `/sync/shape`, `/sync/push`,
`/sync/state`) plus declared `:static` mounts — nothing in `app.ring`
can add a sixth. Making one would mean editing `serve.zig`, which is
exactly the core coupling the prompt asked this profile to refuse rather
than take.

So the surface this profile publishes is the same *information*
stzAppServer's is — names, kinds, states, last tick, refusals — reached
through the door every RingServ app already has: `POST /api/v1` naming
`service: "agents"`. It is read-only by construction (every action only
reads the host), which is the rule the ask actually cares about; the
HTTP verb carrying it is a RingServ wire-contract fact
(`docs/services.md`), not a decision this profile made.

## UPDATE, 2026-08-24 — the 08-22 conclusion was right and its middle step was wrong; two failures were being read as one

*Everything below is measured on this machine today, in this order, and the
order is the point: each measurement killed the explanation the previous one
had left standing.*

**The 08-22 passage read the warnings and the `stzenginestring` error as one
event — "RingServ cannot load a native extension". They are two events, and
only the second one is that.** The warnings come from `fexists` failing
BEFORE any load is attempted (`engine/stz_string.ring:18`); `loadlib` is
never reached. So the warnings were never evidence about RingServ's
capability. They were evidence about a path.

**1. The engine IS built here. It was not on 08-20, and the 08-20 note that
said so was still being read four days later.** Counted rather than assumed:
**92 built libraries against 92 bindings** in
`stzlib/libraries/stzlib/engine/zig-out/bin/`. `tests/stzprofile-gates.js`
now counts them on every run, so this number cannot go stale silently again.

**2. So why were 80 libraries "not found"? Because stzlib looks for its
engine relative to the WORKING DIRECTORY, and a sibling checkout is not on
that path.** `stzlib/libraries/stzlib/core/common/stkRingLibs.ring:17`
(`_stzDiscoverEngineDir`) walks **up from `currentdir()`**, up to ten levels,
trying `<dir>/engine` and `<dir>/libraries/stzlib/engine` at each — then
falls back to `exefolder() + "/../libraries/stzlib/engine"`, which is the
*Ring installation* layout. Started in `D:/GitHub/ringserv`, the walk tries
`D:/GitHub/libraries/stzlib/engine` and never
`D:/GitHub/stzlib/libraries/stzlib/engine`, so it falls through to the
exefolder form and points inside **RingServ's own `zig-out/bin`**. That is
the path the 80 warnings print, and reading one of them closely is what
turned this over.

**3. Start the same binary from inside the stzlib checkout and the warnings
go to zero.** Not a code change, not a rebuild — a working directory:

```
$ cd D:/GitHub/stzlib
$ D:/GitHub/ringserv/zig-out/bin/ringserv.exe run \
      D:/GitHub/ringserv/examples/bangalo-server/app.ring
ringserv: line 19: Error (R3) : Calling Function without definition: loadlib
```

**80 warnings before, 0 after, and the run now stops at `loadlib`.**

**So the 08-22 conclusion survives, and is now reached honestly.** `loadlib`
IS the final boundary and it IS a property rather than a defect
(`RING_NODLL=1` in `build.zig`, stated as a property in `docs/LOADING.md`).
What changed is that it is no longer being credited with a failure it did
not cause. A single binary that cannot load arbitrary native code stops
here, at `stz_string.ring:19`, with everything found — and that is the whole
of what stands between this profile and running.

**Why this matters beyond this file, and it is the reason a gate now exists.**
Central routed a proposal that a dependency like this should check the
**source** is present and the **library** is built, reporting each
separately because they are different repairs. Both of those were **GREEN
here** while the profile failed 80 times. A two-part check would have shown
a clean bill of health for a machine that could not run the thing. So
`tests/stzprofile-gates.js` asks **four** questions and names which repair
each answer calls for: source, built, **reachable from this working
directory**, and **loadable by this binary at all**.

**And `load`'s "no alternative" is retired, in both halves, by
measurement.** This file used to say Ring's `load` takes a literal string so
there is no environment variable to set instead. Both parts of that were
tested in RingServ's own binary today:

- **`sysget` and `eval` are BOTH present here** — `RING_EXTRAOSFUNCTIONS` is
  gated on `RING_LIMITEDENV`, which RingServ does not set, so
  `-DRING_LIMITEDSYS=1` never took them away. `eval('load "' + dir +
  '/x.ring"')` works. The pattern is adopted below.
- **But a *relative* fallback inside that `eval` is a coupling that hides.**
  Measured: an `eval`'d `load` resolves a relative path against the
  **process working directory**, not the script's folder — the same
  asymmetry ringupstream confirmed in stock Ring. The identical command that
  works from the repository root dies `Error (E9)` from any other directory,
  *including with an absolute path to the script*. So this file takes the
  environment variable and **refuses the sibling-relative fallback**: an
  absolute literal that a reader is told to edit fails in one obvious way,
  and a relative one fails differently depending on where you stood.
- **An environment variable cannot reach the ENGINE, only the library.**
  `stkRingLibs.ring:11` assigns `$cEngineDir = _stzDiscoverEngineDir()`
  **unconditionally**, so a host that pre-sets that global before
  `load "stzLib.ring"` has it overwritten. Routed to stzlib as a one-line
  question rather than changed from here.

## UPDATE, 2026-08-22 — both of those reasons are gone; the third one stands

*Measured, not assumed. Both blockers named in the 08-20 update below were
fixed on 2026-08-21 and 08-22, and this profile now loads **the whole of
stzlib** — every file resolves, nothing is left unfound.*

**1. The library search root — done.** `RINGSERV-LOADROOT-01` was ruled
**DEPEND** on 2026-08-20: a general Ring application server MAY require a
Ring installation and need not carry a search root. RingServ now **finds**
one (`RINGSERV_RING_HOME`, else `ring` on PATH) and `ringserv where` prints
it. stzlib's `load "stdlibcore.ring"` resolves, and so does the whole graph
below it.

**2. The `Ask` collision — done.** `RINGSERV-RINGLIBNS-01` was ruled
**SCOPED, NOT RENAMED**: `testing.ring` loads for `ringserv test` alone, so
`run`, `dev`, `serve` and `check` never see it. `Ask` keeps its name, and
`stzNodePlane.ring:42` may define its own.

**What it takes now, and it is the third boundary this README already
named.** The run reaches application code and stops at:

```
Error (R3) : Calling Function without definition: stzenginestring
```

preceded by warnings that `stk_string.dll`, `stz_string.dll` and their
siblings were not found. stzlib's engine is a set of **native
extensions**, and RingServ cannot load one: `dll_e.c` is deliberately out
of `build.zig` (`RING_NODLL`). That is not a defect to be fixed later — a
single static binary that cannot load arbitrary native code is the
property, and `docs/LOADING.md` states it as one.

> **Superseded in one step, 2026-08-24 — see the update above.** The
> conclusion here is right; this paragraph's causal link is not. Those
> warnings are a *path* failure that happens before any load is attempted,
> not evidence of the `RING_NODLL` boundary. Clear the path and the warnings
> vanish while the boundary stays exactly where it is.

So the honest summary changed shape. It used to be *"the loader cannot
find the files"*. It is now: **every file is found; the profile needs a
capability this binary declines to have.** Closing that would mean either
a RingServ that loads native extensions — a real decision, not an
oversight to correct — or an stzlib whose engine has a pure-Ring path.
Neither is this profile's to make, and neither is urgent: what this
example was written to demonstrate — the `stzAgentHost` adoption, the
agents-folder convention, the read-only surface — is unaffected by which
of those two answers arrives.

## UPDATE, 2026-08-20 — the loader was fixed; this profile still does not run, for two other reasons

*The finding below stands as written and is what routed prompt 45. That
prompt is done: `src/rs_path.c` and one marked patch in
`ringvm/src/general.c` give the VM a per-thread virtual working directory,
so a nested `load` now anchors against the file that contains it, exactly
as native `ring` does. `docs/LOADING.md` states the coverage;
`tests/loader-gates.js` holds it, with native `ring` as an oracle.*

**What the fix changed for this profile, measured rather than assumed.**
`ringserv check examples/bangalo-server/app.ring` no longer dies at
`base/stzBase.ring`. The load walks four directories deep through
stzlib — `stzLib.ring` → `base/stzBase.ring` → `base/../core/stzCore.ring`
→ `core/common/stkRingLibs.ring` — with the `..` form resolving correctly.
The diagnosis in THE FINDING was right about the symptom and about whose
concern it was; it was wrong about the mechanism in one detail worth
recording, because the detail is the whole bug: the VM never seeing a real
path is **not** what broke it. Ring anchors by `chdir`, and RingServ's
`-DRING_LIMITEDSYS=1` had quietly turned `chdir` into a no-op.

**Two things now stand between this profile and running, and neither is
the loader.**

1. **RingServ ships no Ring installation**, so stzlib's `load
   "stdlibcore.ring"` — a bare name that native `ring` finds under
   `<ring>/bin/load/` — does not resolve. This is a **library search
   root** decision, not an anchoring defect, and it is open.
   Re-measured 2026-08-20 in a pristine tree, and the earlier note here
   was too generous: staging a Ring installation around `ringserv.exe`
   **in Ring's own layout** (`<X>/bin/` for the binary, with `bin/load/`,
   `libraries/` and `extensions/` beside it) does make every `load`
   resolve — and the run then dies on `loadlib`, which RingServ does not
   provide because `dll_e.c` is deliberately out of the build. So the
   search root is **not** the only thing between here and a working
   `stdlib.ring`. `docs/LOADING.md` §"What still does not resolve".
2. **One name collides.** `src/ringlib/testing.ring` defines `Ask` — the
   `ringserv test` vocabulary — and is loaded into every application's VM,
   including `run` and `serve`, which have no use for it.
   `stzNodePlane.ring:42` also defines `Ask`, so the load dies with `C22`.
   Measured on 2026-08-20 with a throwaway build in which `Ask` was
   renamed: **all of stzlib then loaded with no errors whatsoever.** One
   name is the only remaining namespace blocker. (A second collision,
   `split` against Ring's own stdlib, WAS removed — it is now
   `RsSplitOn`.)

**And a machine fact that outranks both.** With those two cleared in the
throwaway build, `ringserv run examples/bangalo-server/app.ring` fails at
`line 666: Error (R3) : Calling Function without definition:
stzenginestring` — and **native `ring` fails at the same line with the
same error**. "The agent host ticks" is therefore not reachable here by
either interpreter, and that is nothing RingServ can fix.

> **The reason recorded here on 08-20 was "the engine is not built on this
> machine". True then; false from some point before 2026-08-24, when it was
> counted at 92 built libraries.** The 08-24 update above replaces it with
> the reachability finding, which does not go stale, and
> `tests/stzprofile-gates.js` now counts the libraries instead of a document
> asserting a number.

---


## THE FINDING: this profile does not run yet, and the reason is RingServ's own loader

Checked directly, not assumed. `stzLib.ring`'s own header explains that
Ring's `load` is a **compile-time** directive that resolves a relative
path against *the directory of the file that contains it* — normal,
correct behavior under the native `ring` interpreter, proven with a
one-line script that does nothing but load it:

```
$ cd D:/GitHub/stzlib/libraries/stzlib
$ /d/Ring127/bin/ring.exe any-script-that-loads-stzLib.ring
stzlib loaded ok        # native ring.exe: works, from any cwd
```

Run `app.ring` itself through `ringserv run` or `ringserv check` — which
evaluate the app by handing its source to the VM through a hook
(`rs_getcode`, `src/bridge.zig`) instead of opening it as a real file —
and every *nested* relative `load` inside stzlib collapses to the
process's working directory, regardless of which file actually contains
it. Reproduced against this exact file:

```
$ cd D:/GitHub/ringserv
$ zig-out/bin/ringserv.exe run examples/bangalo-server/app.ring
Error (E9) : Can't open file base/stzBase.ring
D:/GitHub/stzlib/libraries/stzlib/stzLib.ring Line (40) Error (C27) : Syntax Error!
...
ringserv: line 1: Error (R42) : Error in eval() function

$ zig-out/bin/ringserv.exe check examples/bangalo-server/app.ring
Error (E9) : Can't open file base/stzBase.ring
...
examples/bangalo-server/app.ring: the application could not be evaluated (see `ringserv run`)
check: 1 problem(s), 0 note(s).
```

The failure is always `base/stzBase.ring` (tried against RingServ's own
cwd, `D:/GitHub/ringserv`) because that is the *first* nested `load`
`stzLib.ring` makes; anchoring cwd one level deeper (inside
`stzlib/libraries/stzlib/`, so `base/stzBase.ring` itself resolves) only
moves the failure one level further in — `base/stzBase.ring`'s own
`load "common/stzIntSeq.ring"` (meant to resolve against `base/`)
collapses to cwd the same way. One anchor directory satisfies at most
one level of the graph.

One anchor directory can satisfy at most one level of stzlib's own
`load` graph; stzlib is authored across dozens of subdirectories
(`base/`, `common/`, `object/`, `number/`, `list/`, `graph/`, `data/`,
`system/`, `agentic/`, …), each loading siblings and cousins by paths
relative to *itself*. No single working directory satisfies more than
one level of that graph, so `load "stzLib.ring"` cannot succeed inside
`ringserv run` today, independent of which path this profile writes on
its own `load` line.

**This is not a stzlib defect** — native `ring` loads it correctly from
any working directory, exactly as authored. **It is not something this
profile can route around** without one of two things this prompt's own
boundary rules out: vendoring a flattened, path-rewritten fork of
stzlib's tree inside RingServ (worse coupling than a dependency — a
private copy that drifts), or teaching RingServ's core loader to track a
per-file directory the way the native interpreter does when it opens a
real file (`src/bridge.zig`'s `rs_getcode` hook feeds source from
memory, so the VM never sees a real path to anchor nested loads
against — fixing that is a bridge.zig change, i.e. RingServ's core).

Per the prompt: **stopping here and reporting the fact is the asked-for
outcome**, not a shortfall. `app.ring` is written complete and correct
against stzlib's real agentic API — `stzAgentHost`, `stzAgentFolder`,
the `.pia` folder convention — so that the day RingServ's loader gains
per-file directory tracking (or an operator's own toolchain resolves it
some other way this profile does not need to know about), this profile
runs with no other change. Today, `ringserv check examples/bangalo-server/app.ring`
and `ringserv run examples/bangalo-server/app.ring` both fail at the
`load` line with the `E9` shown above — reproduce it with the two
commands above before assuming a local mistake.

## Coverage — what this profile guarantees, and what it does not

**Guarantees:**
- a process, a port, and one worker holding exactly one `stzAgentHost`
- the pump: every call to `:agents/list`, `:agents/trace` or
  `:agents/get` advances due agents by one `TickDue()` pass first
- the read-only surface: name, kind, active/retired, tick count,
  channel, last-tick timestamp, and every load refusal — the same facts
  stzAppServer's own `/agents` publishes
- refusals are never swallowed — a `.pia` or `.ring` file the folder
  would not admit shows up in `AgentLoadRefusals()`, not in silence

**Does not guarantee:**
- **wall-clock ticking.** Agents advance on traffic to this app, not on
  a timer — see "the pump" above
- **isolation between agents.** All agents supervised by one host share
  one worker's one Ring VM and one process's memory; nothing here
  sandboxes one agent's failure from another's
- **model / LLM access.** This profile wires no model integration —
  that is `stzLLMAgent`'s and the agent author's concern, not the
  host's or this profile's
- **running today.** See the UPDATE and the finding above — this is the
  honest headline, not a footnote. The loader half is fixed; a library
  search root and one colliding name are not
