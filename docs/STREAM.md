# Pages that react

A page usually **asks**: every two seconds, "has anything changed?" — nearly
always no. RingServ lets a page **be told** instead.

```html
<script src="/ringserv.js"></script>
<script>
  serv.subscribe("menu", refresh);   // refresh() runs when the menu moves
</script>
```

That is the whole client API. `/ringserv.js` is served by the binary itself,
so there is nothing to install and no build step.

Try it: open [Comptoir](../examples/comptoir/) in two browser windows and add
a menu item in one. It appears in the other in milliseconds.

---

## The handler gets an offset, not the data

`refresh` is called with a number — how far the shape log has advanced — and
**never with the row that changed**. That is deliberate, and it is the whole
design:

- Your data keeps arriving through the one call path you already use, so
  paging, `must-refetch` and the placement contract keep working.
- There is never a second source of truth to drift.
- **A lost notification costs latency, never correctness.** The worst case of
  a dropped event is that the page updates on its next ordinary poll.

The client keeps a slow poll running underneath (every 15 seconds by default,
`{poll: 0}` to turn it off). So a page written against `subscribe` is still
correct behind a proxy that eats streaming entirely — it is just slower.

### It gives up, on a deadline rather than on an error

A stream that has not said `open` within six seconds counts as a failed
attempt. Three of those and the client stops trying, says so once in the
console at info level, and speeds its poll up to every three seconds.

**The deadline is the point, and it was measured rather than guessed.** When
a server cannot stream to a page — a buffering proxy, a dead intermediary,
or this server on Windows before the fix noted below — the browser is *not*
told. The connection is not refused, `onerror` never fires,
and the page simply holds a stream that is open and silent for as long as the
tab lives. A client that waited for an error would wait forever. A client
that only counted errors would count zero.

Once a stream *has* worked, the browser's own reconnection takes over
untouched — that is the thing it is genuinely good at.

---

## Who may subscribe: `:stream`

By default, anyone who can reach the server can subscribe to any shape.
That is safe for the reason above — the stream carries `{shape, offset}`
and never a row — but "safe" and "governed" are different words, so a
shape can say who decides:

```ring
Topology([
    :data = [
        :menu    = [ :store = :local, :sync = :onreconnect, :stream = "menu" ],
        :takings = [ :store = :local, :sync = :live,        :stream = :never ],
        :notes   = [ :store = :local, :sync = :live ]
    ]
])
```

| `:stream` | What happens |
|---|---|
| `"<service>"` | **you may subscribe exactly when you may call that service** — and the refusal is the *same sentence*, word for word, that the call would give |
| `:never` | refused `403`, naming the declaration, so a reader knows it is a decision and stops looking for a defect |
| absent | streams, exactly as before this existed |

**Absent means open, on purpose.** The declaration *adds* governance; it does
not switch streaming on. A release that quietly turned working pages off to
make a point about declarations would teach people to fear upgrades, and that
costs more than the point is worth.

**A wrong declaration is found at boot, not by a page.** `:stream` naming a
service that does not exist, or sitting on a table with no `:sync` mode, is
reported by `ringserv check` — that is most of the reason to declare it at all.

**It governs the stream and nothing else.** `/sync/shape` is untouched by
`:stream`: polling is a different door asking a different question, and
widening this to cover it would change refusals that have shipped since
phase 8. Said here so it is a decision you can read, rather than a surprise.

---

## Why Server-Sent Events and not WebSocket

The traffic is one-way: the server says "something moved". WebSocket is a
two-way protocol, and paying for the second direction buys nothing here.

What SSE gives that we would otherwise write ourselves:

- **The browser reconnects on its own.** No retry loop, no backoff to tune.
- **It resumes where it stopped.** On reconnect the browser sends back the
  last `id` it saw as `Last-Event-ID` — and that id **is our shape-log
  offset**, so resuming is exact rather than approximate. This one fact is
  why SSE fits: the protocol's resume token and our data model's cursor are
  the same number.
- **It is ordinary HTTP.** Same port, same proxy, same logs, no upgrade
  handshake for a firewall to refuse.

If you later need the browser to *push* — collaborative editing, a game — SSE
is the wrong tool and you want WebSocket. RingServ does not do that yet, and
says so rather than pretending.

---

## Two things that bite people, and what this server does about them

These are the two complaints you find in every thread about SSE. Both are
real. Here is the position rather than a silence.

### 1. `EventSource` cannot send an `Authorization` header

True, and it has no workaround in the browser. The usual answers are to put
the token in the query string — which then lands in every proxy log and
browser history — or to pull in a library that reimplements the protocol.

**RingServ needs neither, because the stream carries no data.** An event is
`{shape, offset}` and nothing else, so an unauthorised listener learns only
that *something* moved in a shape — the same thing they learn from watching
the page's request timing. **The rows still come through `POST /api/v1`,
which does carry the bearer token and does run your service's checks.**

The secret never rides the stream because there is nothing on the stream to
protect. That is a property of the design, not a mitigation, and it is
asserted by a gate: an `advanced` frame is checked to contain the offset and
the shape and nothing else.

If a shape *name* is itself sensitive in your application, do not stream it —
poll `/sync/shape` through the authenticated path.

### 2. HTTP/2, and proxies that buffer

A stream that a proxy buffers looks exactly like a stream that works, until
updates arrive minutes late or the connection times out with no error
anywhere. It is the failure that costs the most to diagnose, so the server
takes every measure it can from its side:

| Sent on every stream | What it stops |
|---|---|
| `Cache-Control: no-cache, no-transform` | a cache holding the response; `no-transform` also tells compressing proxies to leave it alone |
| `X-Accel-Buffering: no` | nginx buffering the body (the single most common cause) |
| `retry: 2000` in the first frame | the browser reconnecting too fast after a drop |
| a `: beat` comment every 15 s | an idle connection being reaped as dead |
| a deliberate close after 10 minutes | a connection living long enough to be broken silently by something in the middle |

Behind Caddy or Traefik this works with no configuration. Behind nginx,
`X-Accel-Buffering` handles it; if you have overridden buffering explicitly,
also set `proxy_buffering off;` for the `/sync/stream` location.

**And if all of that fails, the page is still correct** — the poll underneath
converges. That is why this could ship at 0.9: streaming here is an
optimisation, never load-bearing.

---

## Limits, said out loud

- **64 streams at once per server.** Number 65 is refused `503` with the
  number in the message, because a client told "busy" learns nothing and a
  client told the limit can decide what to do.
- **Ten minutes per stream**, then a `bye` event and a close. The browser
  reconnects by itself and resumes at its offset, so this is invisible to a
  page — it exists so no connection lives long enough to rot.
- **Declared tables only.** Shapes come from the shape log, so journal-backed
  state has nothing to subscribe to yet. Comptoir shows both halves and says
  which is which.
- **A shape that does not exist is refused `404`** — the same status and the
  same sentence the poll path gives, because two doors onto one concept that
  disagree about what exists is worse than either answer alone. Until
  2026-08-25 this endpoint answered `200` and offset `-1` for any name at
  all, so a page with a typo was told it was connected and then waited
  forever.
- ~~**Not on Windows in 0.9.**~~ **Windows works, since 2026-08-25.** It
  was never SSE: `HTTPConn.writeAll` used `posix.write`, which is
  `WriteFile` on Windows and does not work on an overlapped socket. One
  expression — `send()` there, `write()` elsewhere — and the suite runs
  21/21 on Windows instead of skipping. The same call is why no .NET
  client could POST to this server on Windows at all. Found by deploying,
  not by testing; see [VENDOR_PATCHES.md](VENDOR_PATCHES.md).

---

## The endpoint, if you want it directly

```
GET /sync/stream?shape=<name>[&offset=<n>]
```

`Last-Event-ID` wins over `offset` when both are present, because that header
is the browser resuming and it knows better than a URL written once.

```
retry: 2000
event: open
id: 41
data: {"shape":"menu","offset":41}

event: advanced
id: 42
data: {"shape":"menu","offset":42}
```

Refusals: `400` with the fix in the message when no shape is named, `503`
naming the cap when the server is full.
