# The tutorial arc — from a function to a fiscal record

Six steps, in order, each one runnable. Nothing here is a sketch: every
listing comes from a file in this repository that CI builds and runs, so a
step that stops working stops the build rather than wasting your afternoon.

If you only have ten minutes, do **step 1** and stop. It is the whole idea.

| | Step | You end up with | Time |
|---|---|---|---|
| 1 | [A function becomes a service](#1-a-function-becomes-a-service) | a running API, no declarations | 2 min |
| 2 | [Configuration leaves the code](#2-configuration-leaves-the-code) | `ringserv.yaml` beside your app | 3 min |
| 3 | [A real application](#3-a-real-application) | tables, contracts, a page | 20 min |
| 4 | [JavaScript, as a guest](#4-javascript-as-a-guest) | a `.js` service calling Ring | 10 min |
| 5 | [History that cannot be edited](#5-history-that-cannot-be-edited) | a hash-chained journal | 15 min |
| 6 | [Placing it, and syncing it](#6-placing-it-and-syncing-it) | local-first by declaration | 20 min |

---

## 1. A function becomes a service

**Read:** [gesture.md](gesture.md) · **Time:** two minutes

Write plain functions in a file. `ringserv serve` exposes each one as an
action, maps payload keys to parameters by name, and envelopes the return
value. No framework, no declarations, nothing to learn first.

```ring
# calc.ring
func add a, b
	return a + b
```

```bash
ringserv serve calc.ring
ringserv serve --explain calc.ring    # exactly what got exposed, and how
```

**Getting the command.** If you already have Ring:
`ringpm install ringserv from mayouni`, then `ringpm run ringserv` — which
also brings these guides and both example applications with it. If you do
not have Ring, download one file from
[Releases](https://github.com/mayouni/ringserv/releases) and put it on your
path; nothing else is needed.

**The lesson to carry forward:** the tool tells you what it did. You will
meet `--explain`, `check`, `docs` and `topology` again — RingServ prefers
printing the truth over asking you to trust it.

## 2. Configuration leaves the code

**Read:** [gesture.md](gesture.md) § *Configuration lives beside the code*

Port, workers, database and static routes belong in `ringserv.yaml`, so the
same application runs on your laptop, a server and CI with no edit.

```yaml
port: 8095
workers: 2
database: calc.db
```

**Two boundaries worth learning now**, because they explain a lot of
RingServ's design: **code is not configuration** (`services:` in the YAML is
refused, pointing you back to the application file), and **the declaration
wins** every collision — with the collision *printed at boot*, never
silently resolved.

## 3. A real application

**Read:** [getting-started.md](getting-started.md), then
[fieldnotes-app.md](fieldnotes-app.md) · **Code:**
[`examples/fieldnotes`](../examples/fieldnotes)

The guide builds one application all the way through: a `RingServ()`
declaration, `Data()` tables, a generic table service, a hand-written
service, `Contract()` validation, and a page that calls its own API.

```ring
RingServ([
	:port = 8100,
	:data     = [ :notes = [ :title = :text, :weight = :number ] ],
	:services = [ :notes = [ :table = "notes" ] ],
	:routes   = [ [ :static, "/", "public/" ] ]
])
```

Then meet the tools: `ringserv check` finds contract defects *before* you
run, `ringserv docs` generates the API catalog from the declarations, and
`ringserv test` runs your tests against a scratch database.

**Why contracts sit at the door:** an action that validates its own payload
is an action written twice. Declare it once and every violation comes back
at once as a 422, before your code runs.

## 4. JavaScript, as a guest

**Read:** [JS.md](JS.md) · **Code:**
[`examples/comptoir/services/receipt.js`](../examples/comptoir/services/receipt.js)

A service's implementation may be a `.js` file. It gets the same envelope,
the same contracts and the same placement as a Ring service, and it calls
Ring services by name:

```js
const service = {
    async render(payload) {
        const state = await serv.call("orders.state", {});
        return { code: 0, message: "OK", data: { open: state.data.open } };
    },
};
```

```ring
:receipt = [ :js = "services/receipt.js" ]
```

**Read the honest limits before you rely on it.** There is no filesystem and
no sockets by design; timers do not sleep; `Intl` is a *named subset* that
refuses unlisted locales rather than formatting them wrongly. Knowing the
edges early is cheaper than discovering them later.

## 5. History that cannot be edited

**Read:** [COMMONS.md](COMMONS.md) § 1 · **Code:**
[`examples/comptoir`](../examples/comptoir)

Some records must stay whole — fiscal ones, by law, in several countries.
`Journal()` is a **second store beside `Data()`, not a mode of it**, because
the two want opposite things:

| | `Data()` | `Journal()` |
|---|---|---|
| rows | mutable | append-only |
| history | trimmed by compaction | *is* the data, never trimmed |
| recovery | the rows are the state | **replay is the only recovery** |

```ring
Journal([ :name = "ventes", :apply = func aEvent { ... } ])

JournalAppend("ventes", [ :type = "commander", :client = "Ada" ])
JournalVerify("ventes")   # -> [ :events = 41, :chain = "INTACTE", :at = 0 ]
```

Each record stores the previous record's hash, so an edited row is reported
`ROMPUE` **with the sequence number where the chain first breaks**. Try it:
change a row with any SQLite tool and run `ringserv journal verify` — it
exits non-zero, so it can be a cron job rather than something someone
remembers to check.

**The idea that makes this work:** a cancellation is an *event*, never a
deletion. The order stays in the record with its reason beside it.

## 6. Placing it, and syncing it

**Read:** [topology.md](topology.md) · **Code:**
[`examples/fieldnotes/topology.ring`](../examples/fieldnotes/topology.ring)

Where a service runs is a **deployment** decision, so it lives in its own
declaration and not in your application:

```ring
Topology([
	:app  = "comptoir",
	:data = [ :menu = [ :store = :local, :sync = :onreconnect ] ],
	:services = [
		:menu   = [ :site = :local, :authority = :server ],
		:orders = [ :site = :server ]
	]
])
```

Move a service between the page and the server by editing one word here.
The sync layer underneath is deliberately boring: a shape log maintained by
database **triggers** (so it is true for every write path, not just the ones
that remembered), and a mutation queue whose exactly-once guarantee is a
property of the database rather than of the control flow.

---

## Where to go next

- **See it all at once** — [`examples/comptoir`](../examples/comptoir) wires
  every hostable form together: generic table, class, declarative,
  JavaScript, journal and sync, over contracts, an actor seam and placement.
  `ringserv panel examples` starts it from a browser.
- **Deploy it** — [TLS.md](TLS.md) first: RingServ terminates no TLS on
  purpose, and refuses to serve plain HTTP on a public address without you
  saying you have a proxy in front.
- **Understand the machine** — [architecture.md](architecture.md),
  [WORKERS.md](WORKERS.md), [WRITES.md](WRITES.md).
- **See what is thin** — [GATES.md](GATES.md) lists what the gates do *not*
  yet defend. It is a better map of the risk than any feature list.
