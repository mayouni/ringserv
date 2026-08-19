# TLS — the decision, and why it is a refusal rather than a paragraph

**Decision: RingServ terminates no TLS.** It speaks plain HTTP, binds
loopback by default, and expects a TLS-terminating reverse proxy in
front. Taken 2026-08-19, phase 8.

## Why not native TLS

The alternative was real: vendor a TLS stack, and let `ringserv run` bind
443 with a certificate. It was rejected on four grounds, in the order
they mattered.

**1. It is the one dependency that cannot be vendored honestly.**
RingServ's whole shape is *one static binary, zero dependencies* — the
Ring VM, SQLite, httpz, tree-sitter and QuickJS are all vendored and
pinned, and each is a body of code that changes slowly and fails loudly.
A TLS stack is neither. It changes on a security calendar that is not
this project's, and a vendored copy that is three months old is not an
old dependency, it is a vulnerability with a pin next to it.

**2. Certificate lifecycle is a whole product.** Issuance, renewal,
OCSP, SNI for several names, the ACME dance and its failure modes. Caddy
does this well; so does Traefik. RingServ doing it *adequately* would
still be worse than either, and the cost would be paid forever.

**3. The deployment already has one.** Every environment this server is
meant for — a VPS, a container behind an ingress, a machine on a
developer's desk — either has a terminating proxy already or is one
`caddy` away from it. Building what the deployment already provides is
how a small binary stops being small.

**4. Phase 8's actual risk is elsewhere.** The thing most likely to hurt
a RingServ deployment is not a missing cipher suite; it is plain HTTP
reaching a network because nobody noticed. That is the risk this decision
addresses directly, below.

## Why it is enforced, not merely documented

A decision that lives only in a document is a decision somebody will miss
at 2am. So the runtime holds it:

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

RingServ assumes the proxy handles, because it does not:

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

## What would change this decision

Stated so that revisiting it is a judgement rather than a rediscovery:

- **A target with no proxy available.** MicroRing's devices are the
  plausible case — a board that must speak TLS itself with no room for a
  second process. That is a MicroRing decision about a MicroRing target,
  and it would not change what a *server* does.
- **A standard library TLS server good enough to depend on.** Zig's
  `std.crypto.tls` is a client. If it grows a server side that the
  standard library maintains, the "cannot be vendored honestly" argument
  weakens considerably, because the pin would move with the toolchain
  rather than with this repository's attention.

## Gates

`node tests/tls-gates.js` — the default is loopback; a non-loopback bind
without acknowledgement **fails to start** and says both ways forward; the
same bind with `:behindproxy = true` starts and serves; and the whole
127/8 block counts as loopback, because 127.0.0.2 is as local as
127.0.0.1.
