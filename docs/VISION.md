# Vision — what RingServ is for

**Stated by the author, 2026-08-22, in his own words rephrased as little as
possible.** This file is the charter the roadmap answers to. Where the roadmap
says *what next*, this says *why*, and a phase that cannot trace to a line here
should be questioned.

---

## The sentence

RingServ is a modern, lightweight, powerful and flexible server for **Ring
applications, web services, and agent hosting** — where hosting anything is a
**dead-simple gesture**: a declarative programming interface in Ring, yaml-like
configuration and file formats for anything worth hosting, and a **didactic
simplification** of the professional work of turning code — even a single
function — into a hosted service.

## Position — complement, not competitor

RingServ is **not** a competitor to stzApplicationServer, stzCluster, stzApp or
stzMultiApp. It gives the **Ring foundation that Softanza stands on** the
features those need to be complementary — while remaining fully usable by any
programmer, Ring or not, **without Softanza**.

Two audiences, one binary:

- **The Softanza estate** — RestoLean and the author's other real applications,
  the Ring family (RingScript, MicroRing, RingFlex, …), powered where it fits
  by Ring++ and RingFace, with Zig where it belongs: in the internal engine.
- **Any programmer** — who should be able to pick up RingServ with no knowledge
  of the estate and turn a function into a service before their coffee cools.

## The topology promise

RingServ must be **genuinely impressive in how easily it runs everywhere**:

| Where              | Precedent / status                                          |
|--------------------|-------------------------------------------------------------|
| a normal server    | delivered — one static binary, zero dependencies             |
| cloud scalers      | cross-compiles today; the operational story is still owed    |
| an Android phone   | **RestoLean has done this** — learn from it, do not re-invent |
| a microcontroller  | MicroRing's territory — the seam must exist on this side too |

And across whatever topology a programmer chooses, the **family must know each
other by default**: RingServ, RingScript, MicroRing and the rest working
seamlessly **without complex configuration**. The symbiosis is the feature; a
config file that must be written before two Softanza-family processes can talk
is a defect against this paragraph. (C3 placement and the device-identity
contract relayed from microring are the first two bricks of this.)

## JavaScript is a first-class guest, not a demo

As RingScript put Ring and JavaScript hand in hand in the browser, RingServ
must run JavaScript **on the server** (on the vendored runtime — QuickJS-ng
today) and offer JS programmers — and perhaps TypeScript after — **the same
ease and power it offers Ring**. The bar is NodeJS, even Bun and the newer
runtimes — **not for the sake of competing**, but because clearing that bar is
what makes a JS programmer willing to stay, and then to try RingScript, Ring,
and Softanza for their small and medium applications, fun and
business-critical alike.

## The delivery culture

RingServ is the **second contribution to Ring after RingScript**, and it owes
the same arc: **product-oriented delivery**, and the same educational,
communication and documentation quality across the whole repository. The
didactic docs are not an accessory — they are how a server earns programmers.

The deeper aim, in the author's words: an ecosystem from Softanza Labs that
makes programming **fun and simple again like in the 80s, yet modern, powerful
and engaging like 2026 and after**.

## Born in real constraints

RingServ will be used by the author's real-world applications — RestoLean
first. It must learn from them so it is **not a research tool and not a
beautiful toy**: a tool born in real-world constraints and tailored to
practical use, like everything Softanza does. (The journaled store is the
first primitive extracted this way — from RestoLean's Commons germ, French
anti-fraud constraints included.)

---

## Where the tree stands against this vision (2026-08-22)

Honest ledger — what exists, what is partial, what is not started:

**Standing.** One static Zig-built binary; declarative `RingServ([...])`
services; `Data()`, `Journal()`, contracts, sync, C3 placement; JS services on
QuickJS-ng with a WinterTC-shaped prelude; didactic docs with gates that fail
when the prose rots; born-from-RestoLean primitives. **Since phase 10
(2026-08-22):** the one-gesture function→service path (`ringserv serve`,
[gesture.md](gesture.md)) and the yaml-like config-file form
(`ringserv.yaml`).

**Partial.**
- *JS parity with Node/Bun*: services run as ES modules with `serv.call`,
  `Intl` and `crypto.subtle.digest`, and the Node benchmark is published
  losses-first (phase 11, 2026-08-23). Still open: TypeScript, and any
  npm story (currently a named refusal, not a gap).
- *Family symbiosis*: C3 is ratified and enforced; the device-identity
  contract is relayed; but "two family processes find each other with zero
  configuration" is not yet demonstrable end to end.
- *Cloud*: cross-compilation is proven, deployment ergonomics are not.

**Not started.**
- *Android as a first-class target* — RestoLean's experience exists to be
  mined; nothing in this tree runs there yet.
- *Agent hosting* as a named capability with its own gesture.
- *TypeScript.*

Each "partial" and "not started" line is a candidate phase, not a debt: the
vision explicitly wants product-arc delivery, one gated phase at a time, and
the order is the author's and Central's to set. **A proposed order now
exists**: [PLAN.md](PLAN.md), phases 10-17, adopted 2026-08-22 as a living
document -- follow it, adapt it, and record the adaptations there.
