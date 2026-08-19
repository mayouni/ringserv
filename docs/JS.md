# The JS guest — what it is, and what it deliberately is not

*Phase 7. A second guest language beside Ring, resident per worker, with
a host surface that is the web platform's minimum rather than Node's.*

## The one-sentence version

A service's implementation may be JavaScript; **nothing around it
changes**. The declaration stays in Ring, the envelope is the same, the
contract runs before dispatch, the topology places it, the sync path
carries it. `tests/jsserv-gates.js` proves this the only way worth
proving it: a JS service and a Ring service answering the same shape,
compared **as data**.

## Writing one

```ring
:report = [ :js = "services/report.js" ]
```

```js
// services/report.js
function money(n) { return "$" + n.toFixed(2); }   // private

const service = {
    build(payload) {
        return { code: 0, message: "OK", data: { total: money(payload.n) } };
    },

    async summary(payload) {
        const rows = await serv.call("notes.list", { limit: payload.limit });
        return { code: 0, message: "OK", data: { n: rows.data.count } };
    },
};
```

The `service` object's methods are the actions. Everything else in the
file is private — the JS analogue of the class form's `Action` suffix,
and it gives privacy *by structure*, so a helper cannot become an
endpoint by accident.

Each file is evaluated inside a function, so two services may both
declare `service` and neither can see the other's helpers. What they do
share is **one QuickJS context per worker**, resident like the Ring VM
beside it: a JS service costs no more per request than a Ring one after
the first call, and a server with no JS services never creates a context.

## `serv.call` — and why there is no `fetch`

```js
const r = await serv.call("notes.create", { title: "x" });
```

A service reaches another service **by name**. The topology decides where
that name lives; a service that hardcoded a URL would have made a
deployment decision inside application code, which is the whole thing
placement exists to prevent. So there is no network `fetch`, and
`tests/wintertc.json` records that as a decision with a reason rather
than as a gap.

Two properties to know:

- **It returns a promise**, because the dispatch happens outside the
  guest. Awaiting it is the only thing a caller has to know.
- **A refusal comes back as an envelope**, exactly as it does over the
  wire — `{ code: 1, message: "…" }`. `serv.call` rejects only if
  dispatch itself *raises*. A contract violation is a business outcome,
  and it travels in `code`.

### How it works, and why it had to

Dispatch lives in Ring, and by the time JS is running we are already
inside a Ring VM call — so calling back in would be re-entrancy on a
runtime that guards against exactly that. The control flow is therefore
inverted, with **Ring as the outer loop**:

1. `serv.call` returns a promise and queues a request. Nothing re-enters.
2. The action returns a still-pending promise; the host answers a
   sentinel instead of reporting "never settled".
3. Ring drains the queue through its **own** `__dispatch` — contracts,
   placement, generic table services and all — and hands each result back.
4. Ring asks the guest to continue; the loop repeats until the action
   settles.

The guest never sees the trampoline. What it buys is that `serv.call`
from JS is the *same* dispatch a Ring service gets, rather than a second,
weaker path that would drift from it.

**Nesting is bounded at 16.** A service that calls itself opens a new
trampoline each time rather than looping inside one, so the round counter
never sees it and the Ring stack would overflow first. The guest's own
frame stack carries the depth, and the refusal names the cycle.

## The host surface

`__host` is the **only** door out of the guest, and it holds nine
primitives: `utf8Encode`, `utf8Decode`, `b64Encode`, `b64Decode`,
`randomBytes`, `nowMs`, `setTimeout`, `clearTimeout`, `servCall`. A gate
asserts that list exactly, so the door cannot widen without someone
deciding to widen it.

Everything else — `URL`, `URLSearchParams`, `Headers`, `Request`,
`Response`, `TextEncoder`/`TextDecoder`, `structuredClone`, `Event`,
`EventTarget`, `AbortController`, `crypto`, `performance` — is written
once in [`src/ringlib/prelude.js`](../src/ringlib/prelude.js) and
evaluated into every context.

**Why the prelude is JavaScript.** The roadmap asks for the surface
"implemented once in Zig", and the load-bearing word is *once*: what must
not happen is each guest, or each application, growing its own idea of
what `URL` means. Zig implements what genuinely needs the host; pure
computation over those primitives is JS. Writing `URLSearchParams` in Zig
would buy nothing and cost a week of memory management.

### Conformance

`tests/wintertc.json` is the WinterTC / ECMA-429 Minimum Common API as a
checklist — **someone else's list**, because a surface graded by its own
author grades itself generous. `tests/js-gates.js` checks it in **both
directions**: every name claimed present must exist, and every name
recorded absent must genuinely be absent. The second half matters as much
as the first — `fetch` appearing by accident would silently undo the
reason placement exists.

## The honest limits

- **No filesystem, no processes, no sockets.** `quickjs-libc` is
  deliberately not vendored. Ring reads a `.js` file and hands the host
  *source, never a path*, so there is no path-taking host function and
  therefore nothing to escape from. Five gates hold `require`, `std`,
  `os`, `scriptArgs` and `process` at `undefined`.
- **Timers do not sleep.** A timer is a callback held until the host
  drains jobs: `setTimeout(fn, 0)` yields, and a longer delay is honoured
  by **order**, not by waiting. A server that actually slept would be
  holding a worker hostage on a guest's say-so. `setInterval` exists as a
  name and throws, because a request-scoped guest has nowhere to run a
  repeating timer.
- **`URL` is not WHATWG-complete.** It parses absolute URLs and the one
  relative form a server meets. It is a parser for service code, not a
  browser's.
- **No `crypto.subtle`, no streams, no `Blob`, no `WebSocket`** — each
  recorded in `wintertc.json` with a reason. A half-present
  `SubtleCrypto` is worse than an absent one.
- **Memory and stack limits are the server's**, not the application's:
  128 MB and 4 MB. Hitting one is an ordinary trapped error.

## Gates

`node tests/js-gates.js` (45) — the runtime, the fence, the conformance
list, and the surface *behaving* rather than merely existing.
`node tests/jsserv-gates.js` (33) — the service form, the comparison
against a Ring service, and the trampoline.

Two defects those gates found rather than reasoning: a promise returned
by an `async` action was being JSON-encoded as `{}` instead of settled,
and the trampoline's suspended-action slot had to become a **stack**,
because a JS service calling another JS service left the outer call
waiting on a promise nobody held.
