# Building Fieldnotes

*One application, built all the way through. Every listing here is taken
from [`examples/fieldnotes/`](../examples/fieldnotes), which runs:*

```bash
ringserv test examples/fieldnotes/app.ring     # 13 expectations pass
ringserv run  examples/fieldnotes/app.ring     # then open :8100
```

*`tests/guide-gates.js` checks this guide's claims against that
application on every build, so a change to one that contradicts the other
fails rather than rots.*

Fieldnotes is a notebook for observations made in the field: a note has a
title, a body, a place and a weight. It is small enough to read in one
sitting and large enough to need every seam RingServ has.

---

## 1. The whole application is one declaration

```ring
RingServ([
    :port     = 8100,
    :database = "fieldnotes.db",

    :data = [
        :notes = [ :title = :text, :body = :text,
                   :place = :text, :weight = :number ]
    ],

    :services = [ … ],
    :routes   = [ [ :static, "/", "public/" ] ]
])
```

Port, database, tables, services, static files. **There is no second place
to look** — no config file that disagrees with the code, no environment
variable that changes the shape of the app.

The table gets an `id` column whether you declare one or not, because
everything above this layer addresses rows by id.

## 2. The service you do not write

```ring
:notes = [ :table = "notes" ]
```

Five actions — `list`, `get`, `create`, `update`, `delete` — with paging,
equality filters, and column names matched against the **live schema**, so
a payload key can never reach statement text. That last part is not a
convenience; it is why this line is not an injection hole.

Restrict it when you mean to:

```ring
:notes = [ :table = "notes", :actions = [ :list, :get, :create ] ]
```

...and override any single action by simply defining it — explicit always
wins, so adding a real `create` next to `:table` replaces the generic one
and leaves the other four alone.

## 3. The service you do write

Generic services stop where the interesting work starts:

```ring
:report = [
    :summary = func aReq {
        aRows = DataQuery("select place, count(*) as n, sum(weight) as total " +
                          "from notes group by place order by n desc", [])
        return Reply(:ok, [ :places = aRows, :count = len(aRows) ])
    },

    :heaviest = func aReq {
        nLimit = 5
        aP = aReq[:payload]
        if islist(aP) and isnumber(RsDeclGet(aP, "limit", ""))
            nLimit = RsDeclGet(aP, "limit", 5)
        ok
        return Reply(:ok, [ :rows = DataQuery(
            "select id, title, weight from notes order by weight desc limit ?",
            [ nLimit ]) ])
    }
]
```

**Plain SQL, bound parameters.** RingServ's core carries no query dialect
of its own — that was settled by removal, and [DATA.md](DATA.md) explains
why a general Ring application server should not embed a framework's
grammar. `?` placeholders are the only way values reach a statement.

## 4. Contracts, at the door

```ring
Contract(:notes, [
    :create = [
        :in = [
            :title  = [ :type = :string, :required = true, :maxlen = 120 ],
            :body   = [ :type = :string, :maxlen = 4000 ],
            :place  = [ :type = :string, :maxlen = 80 ],
            :weight = [ :type = :number, :min = 0, :max = 100 ]
        ],
        :out = [ :id = :number ]
    ]
])
```

Three things follow, and each is worth more than the syntax:

- **The action never sees a bad payload.** Validation runs before
  dispatch, so an action that checks its own arguments is an action
  written twice.
- **Every violation comes back at once**, as a 422. Not the first one —
  fixing one field per round trip is a bad afternoon.
- **It governs the generic service too.** `notes.create` was never
  written by hand, and it is still validated.

## 5. A JavaScript service, which is just a service

```ring
:digest = [ :js = "services/digest.js" ]
```

```js
function wordCount(s) {                       // private
    return String(s || "").split(/\s+/).filter(Boolean).length;
}

const service = {
    async brief(payload) {
        const heavy  = await serv.call("report.heaviest", { limit: payload.limit });
        const places = await serv.call("report.summary", {});
        return { code: 0, message: "OK", data: {
            headline: heavy.data.rows.map(r => `${r.title} (${r.weight})`).join("; "),
            places: places.data.count,
        } };
    },
};
```

The `service` object's methods are the actions; **everything else in the
file is private**, so `wordCount` can never be reached over the wire. The
envelope, the contracts, the placement and the sync path do not know a
JavaScript service from a Ring one — the only thing that changed is the
language.

`serv.call` reaches other services **by name**, and the topology decides
where those names live. There is deliberately no `fetch`: a service that
hardcoded a URL would have made a deployment decision inside application
code. Full account in [JS.md](JS.md).

## 6. Placement — the same code, deployed differently

```ring
Topology([
    :app = "fieldnotes",

    :data = [
        :notes = [ :store = :local, :sync = :onreconnect ]
    ],

    :services = [
        :notes  = [ :site = :local, :authority = :server ],
        :report = [ :site = :server ],
        :digest = [ :site = :server ]
    ]
])
```

Read it as two questions per service. **Where does it run?** `:site`.
**Who decides?** `:authority`.

- `notes` runs **in the page**, against a local store, so a note appears
  the instant it is typed — and the **server re-runs the same action** as
  the authority when it syncs. The page's answer is a *prediction*.
- `report` and `digest` are server work and stay there. A page asking for
  them makes a wire call; the page carries no implementation.

Moving `report` into the page is one word. That is the promise, and it is
gated: the same test suite runs against both placements and the results
are compared *as data*.

**The server holds you to it.** Calling a `:site = :local` service with no
server authority over the wire is refused with a **501** — the service
exists, and this host truthfully does not run it. A deployment declaration
the runtime does not enforce is a comment.

## 7. Offline, and back

`:sync = :onreconnect` on the `notes` store turns on the sync protocol:

- **Reading** — the server keeps an append-only *shape log* of every
  insert, update and delete, maintained by **database triggers** so it is
  true for every write path, not only the ones somebody remembered. The
  client reads from an offset and pages until it is up to date.
- **Writing** — offline changes queue locally as *service calls* and are
  POSTed in order. A mutation **is** a service call, so there is no second
  vocabulary to learn.

Exactly-once is a property of the database rather than of the control
flow: a mutation's claim and its work are one transaction. A duplicate
finds the claim taken; a **gap is refused** rather than accepted, because
accepting mutation 5 while 4 never arrived would strand 4 forever; and a
**refusal rolls back its own claim**, so you can fix the payload and
resend the same id.

The whole thing is judged by a convergence oracle — N clients, random
interleavings, a third of all pushes retried as after a dropped response —
in [topology.md](topology.md).

## 8. Tests that run on every save

```ring
aReply = Ask(:notes, :create, [ :title = "First light", :place = "Sidi Bou" ])
ExpectOk("creates a note", aReply)

aReply = Ask(:notes, :create, [ :body = "no title" ])
ExpectCode("refuses a note with no title", aReply, 1)
ExpectStatus("...with a 422, not a 500", 422)
```

```bash
ringserv test examples/fieldnotes/app.ring
```

Tests call services **the way a client does** — same dispatch, same
contracts, same placement — against a scratch in-memory database. No
server, no port, nothing to clean up. That is why they are fast enough to
run on every save.

## 9. Before it meets a network

```bash
ringserv check      # syntax, contract agreement, placement defects
ringserv docs       # the API reference, generated from the runtime
ringserv topology   # the placement map
```

`check` reports in the family's diagnostic envelope (`--json`), and both
`check` and `docs` ask the *runtime* what exists rather than parsing the
file — so neither can drift from the code.

### Deploying

RingServ **terminates no TLS** and binds loopback. Put a proxy in front:

```
api.example.com {
    reverse_proxy 127.0.0.1:8100
}
```

That is the whole Caddy configuration, certificate included. If you bind a
public address instead, RingServ **refuses to start** unless you also
declare `:behindproxy = true` — the reasoning, and the two ways forward,
are in [TLS.md](TLS.md).

### Who is calling

```ring
Actor([ :secret = sysget("APP_SECRET") ])

Contract(:notes, [
    :delete = [ :auth = "notes.manage" ]
])
```

The host verifies the token; your application decides what the actor may
do, because permissions are your vocabulary. `401` and `403` stay
distinct. See [services.md §6](services.md).

## 10. What you have now

An application with a database, a validated API, a page, a second guest
language, a declared deployment, offline sync and its own tests — in one
file plus one JavaScript service, served by **one binary with nothing
installed beside it**.

What to read next depends on what you are doing:

| you want | read |
|---|---|
| every service form and rule | [services.md](services.md) |
| the query surface, and why there is no ZQL here | [DATA.md](DATA.md) |
| placement and the sync protocol in full | [topology.md](topology.md) |
| the JS guest's limits and host surface | [JS.md](JS.md) |
| what the numbers actually are | [BENCHMARKS.md](BENCHMARKS.md) |
| how the pieces fit | [architecture.md](architecture.md) |
