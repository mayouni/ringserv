# TLS — the estate rule, and why it is a refusal rather than a paragraph

> **THE RULE.** *No repository in this estate vendors a TLS or crypto
> stack, and TLS terminates at a proxy in front.*
>
> Ruled 2026-08-21 by the Principal, `decisions/LEDGER.md` line 76,
> narrow and checkable. This page is the estate's statement of it.

## Who this binds, and who it does not

It binds **every repository in the estate**, not only the one that wrote
it. The rule was taken from RingServ's own decision of 2026-08-19 and
promoted, so what follows is written from that tree — the argument is
kept in the first person on purpose, because it is evidence rather than
principle, and a rule argued from a measured binary is one a reader can
check against their own.

**What it does *not* say, and will not be read to say.** The broader
version — *no dependency on a security calendar not our own* — was
**refused**, and the reason is worth keeping in front of anyone tempted
to re-propose it: it needs a definition of "security calendar" that
nobody has written, and **a rule with an undefined term is a rule nobody
can check**. The narrow rule is checkable today with an undisputed term.
TLS is the one case where "a vendored copy three months old is a
vulnerability with a pin next to it" is a measurement rather than an
analogy — that is why the narrow form carried and the broad one did not.

**A follow-on, explicitly not part of the rule:** the Observer gains a
vendoring row in its vocabulary check, so a violation becomes *findable*
rather than merely readable. That is a tooling decision routed to the
Observer, and nothing here waits on it.

**One number this page will not carry.** The case for the rule was first
put with "six repositories here vendor something". The measured figure is
**two** carrying a `vendor/` directory — `ringpp` and `ringserv` — of
which only `ringserv` carries a `VENDOR.md`. Two is a floor and six was
never verified; Central owned the correction on the face of its ruling,
and it is repeated here so the record does not carry the invented one.

## The instance: RingServ

**RingServ terminates no TLS.** It speaks plain HTTP, binds loopback by
default, and expects a TLS-terminating reverse proxy in front. Taken
2026-08-19, phase 8 — and enforced, not merely written, which is the half
that makes it a rule rather than advice.

## Why not native TLS

The alternative was real: vendor a TLS stack, and let `ringserv run` bind
443 with a certificate. It was rejected on four grounds, in the order
they mattered. They are stated from RingServ's tree because that is where
they were measured; read them against your own.

**1. It is the one dependency that cannot be vendored honestly.**
RingServ's whole shape is *one static binary, zero dependencies* — the
Ring VM, SQLite, httpz, tree-sitter and QuickJS are all vendored and
pinned, and each is a body of code that changes slowly and fails loudly.
A TLS stack is neither. It changes on a security calendar that is not
this project's, and a vendored copy that is three months old is not an
old dependency, it is a vulnerability with a pin next to it.

*This is the ground the rule stands on.* It generalises to any repository
that vendors: the question is never "can we compile it" but "who ships
the fix, and how fast does it reach a pinned copy".

**2. Certificate lifecycle is a whole product.** Issuance, renewal,
OCSP, SNI for several names, the ACME dance and its failure modes. Caddy
does this well; so does Traefik. RingServ doing it *adequately* would
still be worse than either, and the cost would be paid forever.

**3. The deployment already has one.** Every environment this server is
meant for — a VPS, a container behind an ingress, a machine on a
developer's desk — either has a terminating proxy already or is one
`caddy` away from it. Building what the deployment already provides is
how a small binary stops being small.

**4. The actual risk is elsewhere.** The thing most likely to hurt a
deployment is not a missing cipher suite; it is plain HTTP reaching a
network because nobody noticed. That is the risk this decision addresses
directly, below — and it is the half a repository can act on today,
whatever it vendors.

## Why it is enforced, not merely documented

A decision that lives only in a document is a decision somebody will miss
at 2am. So RingServ's runtime holds it — **the estate rule does not
mandate this mechanism**, and another repository may hold the same line
differently; what follows is one way that works, offered as a worked
example rather than a requirement:

- **The default bind is `127.0.0.1`.** It always was; now it is a stated
  default rather than a hardcoded one.
- **Binding a non-loopback address refuses to start**, unless the
  application also declares `:behindproxy = true`.
- **The refusal names both ways forward** — put a proxy in front and say
  so, or leave `:host` alone and reach it through the proxy on loopback.
  A refusal that only names the problem gets worked around; one that
  names the fix gets followed.

```ring
# The recommended arrangement: the proxy talks to loopback.
RingServ([ :port = 8080, ... ])                      # binds 127.0.0.1

# Exposed deliberately, with TLS acknowledged as the proxy's job.
RingServ([ :port = 8080, :host = "0.0.0.0", :behindproxy = true, ... ])
```

`:behindproxy` claims nothing and checks nothing — RingServ cannot verify
that a proxy exists. It is an **acknowledgement**, and its value is that
it cannot be given by accident. Someone had to write it.

## What the proxy owes you

Under this rule the proxy is where TLS lives, so it inherits everything
that follows from that. The first three rows are the estate's; the last
two are RingServ's own, and another repository should fill them in for
itself rather than assume these answers:

| | |
|---|---|
| TLS termination and certificate lifecycle | the proxy's |
| HTTP→HTTPS redirection | the proxy's |
| HSTS and other transport headers | the proxy's |
| Request body limits beyond RingServ's 4 MB | either; RingServ's is a floor |
| Client IP, via `X-Forwarded-For` | the proxy sets it; **RingServ does not yet read it** |

That last row is an honest gap rather than a feature: RingServ does not
currently trust or parse forwarding headers, because trusting them
without knowing which proxy set them is how a client spoofs its own
address. When rate limiting or per-actor auditing needs a client address,
that will arrive with an explicit statement of which hop is trusted.

### Caddy, which is the shortest correct example

```
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

That is the whole configuration, and it obtains and renews the
certificate by itself. RingServ stays on loopback and needs no `:host`
and no `:behindproxy` at all — which is why it is the recommended shape.

## What would change this rule

Stated so that revisiting it is a judgement rather than a rediscovery.
Note the bar has risen with the scope: this is now an estate rule, so
changing it is an amendment on the Principal's desk, not one
repository's call — and either ground below would be evidence for that
amendment rather than an exemption from the rule:

- **A target with no proxy available.** MicroRing's devices are the
  plausible case, and now the sharpest one: a board that must speak TLS
  itself, with no room for a second process. Under the narrow rule that
  is not MicroRing's own call any more — it is the amendment this rule
  will most likely meet first, and it should arrive as evidence about
  devices rather than as an exemption claimed at the edge. Nothing about
  it changes what a *server* does.
- **A standard library TLS server good enough to depend on.** Zig's
  `std.crypto.tls` is a client. If it grows a server side that the
  standard library maintains, the "cannot be vendored honestly" argument
  weakens considerably, because the pin would move with the toolchain
  rather than with any repository's attention. Note that this weakens the
  *ground*, not the rule: the rule would still need amending, by whoever
  can show the ground has moved.

## Gates

Held here for RingServ's half. The estate rule itself becomes findable
rather than merely readable through the Observer's vendoring row, which
is a separate piece of work and not a precondition for anything on this
page.

`node tests/tls-gates.js` — the default is loopback; a non-loopback bind
without acknowledgement **fails to start** and says both ways forward; the
same bind with `:behindproxy = true` starts and serves; and the whole
127/8 block counts as loopback, because 127.0.0.2 is as local as
127.0.0.1.
