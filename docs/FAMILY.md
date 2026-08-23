# The family handshake — zero-config discovery

Two RingServ processes on one machine or one LAN find each other with **no
configuration at all**, and can call each other by name:

```ring
# beta declares who it is — that is ALL the setup there is
RingServ([ :port = 8124, :app = "beta", :services = [ ... ] ])
```

```ring
# alpha, anywhere on the same host or LAN:
Family()
# -> [ [ :app = "beta", :host = "127.0.0.1", :port = 8124,
#        :custody = "L0", :alg = "none", :age_ms = 1200 ] ]

FamilyCall("beta", "hello.greet", [ :name = "alpha" ])
# -> beta's ordinary envelope, dispatched by beta's ordinary rules
```

Refusing is one word: `:announce = false` binds no socket and sends
nothing — refusal is **absence**, not silence with the radio still warm,
and the gate proves it by packet capture rather than trust.

## How it works

One boring transport: a JSON beacon over UDP multicast (group
`239.255.71.74`, port `47474`), sent every two seconds, heard by every
family process sharing the port. The beacon (shape **provisional** until
the cross-project identity contract freezes — it is co-owned with zing):

```json
{ "v": 1, "family": "ringserv", "app": "beta",
  "host": "127.0.0.1", "port": 8124,
  "contracts": { "c2": "1.1", "c3": "1.0" },
  "identity": { "custody": "L0", "alg": "none" } }
```

Three design decisions worth knowing, each learned by a failing gate:

- **Multicast, not unicast.** N sockets sharing a port all receive a
  multicast datagram; only one of them receives a unicast. The first
  gate run proved it — the test's own capture socket ate the beacons.
- **The beacon carries the server's own bind address**, so reachability
  mirrors [the TLS rule](TLS.md) instead of lying about it: a
  loopback-bound sibling advertises `127.0.0.1` and is honestly only
  same-host callable; one that bound the network advertises that.
- **The roster is a phone book, not a trust store.** Hearing a beacon
  proves someone can send UDP, nothing more. A `FamilyCall` is dispatched
  by the *called* server's ordinary door — contracts, placement, actors —
  exactly as for a stranger, because over the wire, family *is* a
  stranger with a known address.

## The identity fields

`custody` and `alg` come from the family's device-identity contract
(microring's, relayed 2026-08-22). Custody is **the axis**: `L0` — a
software key, every PC's default; `L1` — removable hardware; `L2` — a
fused secret behind secure boot. `alg` is present even when `"none"`,
because a host that hardcodes one algorithm has silently excluded
hardware custody. Declare yours:

```ring
RingServ([ ..., :identity = [ :custody = "L1", :alg = "ES256" ] ])
```

## The boundaries, stated

Same host and LAN only — cross-network topology stays
[C3's](topology.md) declared, explicit business. The roster forgets a
silent sibling after ~15 seconds; last-seen is not liveness. And two
siblings may share an app name (two counters of one shop): `FamilyCall`
answers to the most recently confirmed one, which is the useful default
and now the documented one.

Gates: `tests/family-gates.js` — discovery, the placed call, identity
round-trip, packet-captured silence, and junk ignored by shape.
