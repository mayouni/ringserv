# Alignment — RingServ against the Softanza reference design

**Reference**: `softanza/REFERENCE_DESIGN.md` v0.1 (draft, unratified) · 2026-08-08
**Status**: obligations-if-ratified. Written from outside; this repository's own
process decides.

## Where RingServ sits in the reference design

The lean server placement — and, unusually, an *author* of one horizontal contract:
`Topology()` is the germ the **Placement Contract (C3)** generalizes. RingServ
co-authors C3 rather than merely adopting it.

## What changes here

1. **C3, co-authored.** RingServ's placement vocabulary (`:local` / `:server` /
   `:both`, and the `:device` / `:shadow` extensions MicroRing designed against it)
   aligns with the family contract's names and semantics. The server half of the device
   story becomes something RingServ *implements from the contract* rather than a claim
   another roadmap makes about it — which resolves the one-way-dependency finding
   already raised in this repository's issue tracker.
2. **The ZQL question resolves structurally (decision 6.1).** When StzZql gets its
   canonical home, RingServ becomes a pinned consumer of the grammar and its fixtures.
   The documentation's `Zql("insert into orders values ?")` examples then either
   conform to the pinned grammar or the surface is renamed — the collision ends by
   pinning, not by negotiation. This supersedes the bilateral framing of the open
   review issue.
3. **C5, host half.** RingServ authenticates callers and issues signed principal
   assertions in the same format as `stzAppServer` (co-authored with stzlib and Zing),
   so `ACTOR:` binds identically whichever host the manifest declares.
4. **C2** — the Phase 5 `check` speaks the family diagnostic envelope from its first
   refusal.

## What must not change

The service envelope (`{service, action, payload}` → uniform reply) — the projection
spec already maps Zing flows onto it and it is the best-shaped seam in the family. The
phase ordering, except the one gate below.

## Order and gates

**Phase 6 (Topology + sync) does not start before C3 is ratified** — it is the phase
C3 rewrites if it comes second. Phases 1–5 proceed untouched; item 2 lands whenever the
extraction happens; item 3 follows C3.

## Honest boundaries

This file supersedes part of the earlier review issue (the ZQL collision's *resolution
path*), not its facts. C3 is co-authored: if RingServ's topology semantics resist the
generalization, that finding goes back to the reference design before either side
builds.
