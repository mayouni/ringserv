# The service model

*RingServ's primary paradigm: services and actions over one endpoint,
with typed declarative contracts. Learned from Pionia's Moonlight
architecture, adapted to Ring's declarative soul, and shaped so that
the browser side (RingScript) speaks it natively.*

## 1. Why services, not routes

REST makes you design URLs, pick verbs, and argue about both. For an
API consumed by your own pages and apps, that machinery is ceremony —
Pionia's insight, and it matches Ring's temperament: *declare the
thing, don't choreograph the transport.*

So the primary surface is **one endpoint per API version**:

```
POST /api/v1
{ "service": "orders", "action": "place", "payload": { ... } }
```

and one uniform envelope back, always:

```
{ "code": 0, "message": "OK", "data": { ... } }
```

`code` 0 is success; anything else is a business failure code that
belongs to your application. The HTTP status stays meaningful for the
*transport* layer (400 malformed, 401 unauthenticated, 404 unknown
service/action, 422 contract violation, 500 trapped error) — the dual
signaling Pionia itself converged on after trying "always 200".

Two consequences fall out for free:

- a client needs **one wrapper function** for the whole API;
- the wire shape is **exactly** RingScript's `ring.call(name, json)` —
  so `serv.call("orders.place", payload)` from a page, and topology
  aside, calling a local Ring function or a remote service is the
  same gesture. This is the keystone of the two-player model.

## 2. Declaring services — the declarative form

For small applications, the whole server is one declaration:

```ring
RingServ([
    :port = 8080,

    :services = [
        :orders = [
            :place = func oReq {
                oOrder = oReq[:payload]
                DataExec("insert into orders (customer, total) values (?, ?)",
                         [ oOrder[:customer], oOrder[:total] ])
                return Reply(:ok, [ :id = DataInsertId() ])
            },
            :list = func oReq {
                return Reply(:ok, DataQuery("select * from orders", []))
            }
        ]
    ]
])
```

`oReq` is a plain Ring list: `:service`, `:action`, `:payload`,
`:auth` (the verified caller, if any), `:headers`. `Reply(code, data)`
builds the envelope. Nothing else to learn.

## 3. Declaring services — the class form

For structured applications, a service is a class; methods ending in
`Action` are reachable, everything else is private helpers — Pionia's
suffix rule, which needs no registration ceremony beyond the class:

```ring
class OrdersService from Service

    table = "orders"        # ← generic actions: see §4

    func PlaceAction oReq
        oOrder = oReq[:payload]
        if not StockAvailable(oOrder)
            return Reply(:fail, [ :reason = "out-of-stock" ])
        ok
        DataExec("insert into orders (customer, total) values (?, ?)",
                 [ oOrder[:customer], oOrder[:total] ])
        nId = DataInsertId()
        Notify(:orders, :placed, nId)
        return Reply(:ok, [ :id = nId ])

    private
        func StockAvailable oOrder
            # not reachable from the wire
```

## 3b. Declaring services — the JS form

A service's implementation may be JavaScript. The declaration stays in
Ring, because that is where `RingServ()`, `Contract()` and `Topology()`
already are and one declaration surface is worth more than two:

```ring
:report = [ :js = "services/report.js" ]
```

```js
// services/report.js
function money(n) {                    // private — see below
    return "$" + n.toFixed(2);
}

const service = {
    build(payload) {
        return { code: 0, message: "OK", data: { total: money(payload.n) } };
    },

    async summary(payload) {           // async is free
        const rows = await somethingSlow(payload);
        return { code: 0, message: "OK", data: { rows } };
    },
};
```

**The `service` object's methods are the actions; everything else in the
file is private.** That is the JS analogue of the class form's `Action`
suffix, and it gives privacy *by structure* rather than by naming
convention — a helper cannot become an endpoint by accident.

Three properties worth stating, because they are the whole point:

- **Nothing around the service changes.** The envelope, `Contract()`
  validation, placement, status codes, the sync path and the catalog all
  behave identically. `tests/jsserv-gates.js` runs the same assertions
  against a JS service and a Ring service and compares the two **as
  data**, so a difference has nowhere to hide.
- **`async` is free.** An action may be `async`; the host settles the
  promise before encoding. A rejected one fails exactly like a thrown
  synchronous error, with a line number.
- **The guest cannot reach the machine.** There is no `require`, no
  `std`, no `os`, no filesystem — quickjs-libc is deliberately not
  vendored. Ring reads the `.js` file and hands the host *source*, never
  a path, so there is no host function that takes a path and therefore
  nothing to escape from.

Each file is evaluated inside a function rather than at global scope, so
two services may both declare `service`, and a helper named `fmt` in one
cannot be reached or clobbered by the other. What they *do* share is one
QuickJS context per worker — resident, like the Ring VM beside it, so a
JS service costs no more per request than a Ring one after the first
call. A server with no JS services never creates a context at all.

The catalog asks the **guest** which actions exist, exactly as the class
form asks `methods()`. Parsing the file would be a second, weaker opinion
about a fact the runtime already holds.

## 4. Generic table services — the boilerplate killer

Pionia's `UniversalGenericService` (itself a descendant of Django
REST's generic views) is the single biggest lesson: most services are
CRUD over one table. In RingServ, `table = "orders"` alone gives a
service `list`, `get`, `create`, `update`, `delete`, honoring the
contract (§5) if one is declared, with paging when the payload carries
`limit`/`offset` and equality filters under `filter`. Override any
action by defining it — explicit always wins; restrict the set with
`actions = [ :list, :get ]`.

```ring
:orders = [ :table = "orders" ]                       # all five
:tags   = [ :table = "tags", :actions = [ :list ] ]   # read-only
```

**Column names never come from the request.** Payload keys are matched
against the live schema and anything unknown is dropped, so a key can
never reach the statement text; values always travel as bound
parameters.

## 5. Contracts — typed, declarative, governed

Ring's declarative style can *state* what an action accepts and
returns. RingServ makes that statement operational:

```ring
Contract(:orders, [
    :place = [
        :in = [
            :customer = [ :type = :string, :required = true ],
            :items    = [ :type = :list,   :of = :number, :min = 1 ],
            :notes    = [ :type = :string, :maxlen = 500 ]
        ],
        :out = [ :id = :number ],
        :auth = :required
    ]
])
```

One declaration, four consumers:

1. **The runtime** validates every payload at the door — violations
   return a 422 envelope before your action runs.
2. **`ringserv check`** verifies statically (via tree-sitter-ring)
   that implementations and contracts agree — actions without
   contracts, contracts without actions, `:out` shapes that the code
   cannot produce.
3. **`ringserv docs`** renders the API catalog from contracts alone.
4. **`ringserv test`** generates conformance cases (valid payloads
   must not 422; each violation must).

This is the "typed programming experience" Ring can offer without
ceasing to be Ring: types as declarations that govern, not
annotations that decorate.

## 6. Auth and middleware — kept small on purpose

**Built in phase 8.** Auth is a service concern, declared in the contract
that already governs the payload:

```ring
Actor([ :secret = sysget("APP_SECRET"), :leeway = 60 ])

Contract(:orders, [
    :place  = [ :auth = :required, :in = [ … ] ],
    :refund = [ :auth = "orders.manage" ]
])
```

The verified claims arrive as `aReq[:actor]`, and the split is where the
responsibility splits:

- **The host verifies a token.** It knows one format it can check without
  asking anyone — a JWT signed with a shared secret — and it checks it
  properly: HS256 only, **signature before claims**, constant-time
  compare, `exp`/`nbf` honoured, and `alg: none` refused by *allowlist*
  rather than blocklist, because a blocklist is a list somebody will add
  to.
- **Ring decides what an actor may do**, because permissions are an
  application's vocabulary. A permission is read from `scope` (space
  separated, the OAuth convention) or from `permissions` / `roles` — all
  three, because all three are in the wild and an application already
  issuing one should not have to reissue its tokens.
- **401 and 403 stay distinct.** "I do not know who you are" and "I know,
  and no" are different problems for the caller; collapsing them is a
  small unkindness that costs a developer an afternoon.

An application with asymmetric keys, an introspection endpoint or a
session table supplies its own verifier — `Actor([ :verify = func cToken
{ … } ])` — and the host stays out of it.

**Not here, deliberately:** any notion of a signed principal assertion
another host would accept. That is C5, co-authored with Zing's
`stzAppServer`, and inventing a format here would mean inventing the thing
the contract exists to agree on. This is the seam C5 plugs into.
- **Middleware is two hooks, not an onion**: `OnRequest` (before
  dispatch — may short-circuit with a Reply) and `OnResponse` (after —
  may observe/annotate). Pionia's simplification, adopted: chains of
  wrapping middleware are where routing frameworks hide their
  complexity, and services don't need them.

## 7. Versioning

A version is a switchboard: `/api/v1` and `/api/v2` each map to a
declared set of services. The same service class can be registered in
both — v2 re-declares only what changed. Within a version, adding
services and actions is additive and never breaks a client, because
clients dispatch by name, not by URL shape.

## 8. The secondary surface: routes

Some things genuinely are URLs: static files, webhooks from third
parties, SSE streams, a health check, a REST façade for an external
consumer. The `RingServ()` declaration accepts them without ceremony:

```ring
:routes = [
    [ :get,  "/health",   func oReq { return Reply(:ok, [ :up = true ]) } ],
    [ :post, "/webhooks/pay", func oReq { ... } ],
    [ :static, "/", "public/" ]
]
```

Handlers are fetch-shaped (Request in, Response out). This is the
Hono-flavored door for the web-standards world; the service endpoint
is itself just one such route, pre-wired.
