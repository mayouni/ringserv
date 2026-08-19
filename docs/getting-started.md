# Getting started

*Ten minutes, one binary, and a running application with a database, a
validated API and a page that calls it.*

## 1. One binary

```bash
zig build
./zig-out/bin/ringserv version
```

That is the whole install. There is no runtime to install beside it, no
package manager, no `node_modules`: the Ring VM, SQLite, the HTTP server,
the JavaScript engine and the parser are all inside the executable.

## 2. An application that already runs

```bash
ringserv new fieldnotes
cd fieldnotes
ringserv dev
```

`dev` serves the app and restarts it when you save. Open
<http://127.0.0.1:8080> — the page is already talking to its own API.

What `new` gave you:

```
fieldnotes/
  app.ring          the whole application: services, data, routes
  public/index.html a page that calls them
  tests/            tests that already pass
```

## 3. The idea, in one paragraph

RingServ has **no routes**. It has **services**, and every request is the
same shape:

```
POST /api/v1
{ "service": "notes", "action": "create", "payload": { "title": "…" } }
```

and every reply is the same shape:

```json
{ "code": 0, "message": "OK", "data": { "id": 1 } }
```

`code` is **business** outcome — 0 succeeded, anything else did not. The
HTTP status is **transport** outcome: 404 no such service, 422 the
payload broke its contract, 500 the action failed. Keeping those two
apart is why you never have to decide whether "the order was declined"
is a 400 or a 200.

## 4. Your first service

Open `app.ring`. Add a service to the `:services` list:

```ring
:report = [
    :summary = func aReq {
        aRows = DataQuery("select place, count(*) as n from notes " +
                          "group by place", [])
        return Reply(:ok, [ :places = aRows ])
    }
]
```

Save. `dev` restarts. Call it:

```bash
curl -s localhost:8080/api/v1 \
  -d '{"service":"report","action":"summary","payload":{}}'
```

That is the whole loop: declare a service, save, call it.

## 5. A table, without writing the service

Most services are "the five things you do to a table". Declare the table
and say so:

```ring
:data = [
    :notes = [ :title = :text, :place = :text, :weight = :number ]
],
:services = [
    :notes = [ :table = "notes" ]
]
```

`notes` now answers `list`, `get`, `create`, `update` and `delete`. No
migration step: the table is created on boot, and adding a column to the
declaration adds it to the table. Removing one does **not** drop it —
losing data is never automatic.

## 6. Say what a payload must be

```ring
Contract(:notes, [
    :create = [
        :in = [
            :title  = [ :type = :string, :required = true, :maxlen = 120 ],
            :weight = [ :type = :number, :min = 0, :max = 100 ]
        ]
    ]
])
```

Now a bad payload never reaches your action — it comes back a **422 with
every violation at once**, not the first one, because fixing one field per
round trip is a bad afternoon.

## 7. Check and test before you run

```bash
ringserv check        # syntax, and contracts that name services that do not exist
ringserv test         # the tests in tests/, against a scratch database
ringserv docs         # the API reference, from the declarations
```

`test` uses an in-memory database and never touches your real one. `docs`
is generated from what the runtime actually holds, so it cannot drift from
the code.

## 8. Where to go next

- **[The Fieldnotes guide](fieldnotes-app.md)** — one application built
  all the way through: data, contracts, a JavaScript service, placement,
  offline sync and deployment. Start here if you want the whole picture.
- **[services.md](services.md)** — the service model in full.
- **[cli.md](cli.md)** — every command.
- **[TLS.md](TLS.md)** — before you put it on a network.
