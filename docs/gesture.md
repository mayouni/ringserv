# From a function to a service, in ninety seconds

This is RingServ's **first-touch form** — the vision's dead-simple gesture
([VISION.md](VISION.md)) made executable. You write functions; `serve` makes
them a service. No declarations, no framework, nothing to learn before the
first call answers.

*(Every claim on this page is executable, and `tests/gesture-gates.js` fails
the build the day one stops being true.)*

## Ninety seconds

Write a file — or scaffold one with `ringserv new calc --gesture`:

```ring
# calc.ring — plain functions. That's the whole file.

func hello name
	return "Hello, " + name + "!"

func add a, b
	return a + b
```

Serve it:

```bash
ringserv serve calc.ring
```

Call it:

```bash
curl -X POST http://127.0.0.1:8080/api/v1 \
  -d '{"service":"calc","action":"add","payload":{"a":19,"b":23}}'
```

```json
{"code":0,"message":"OK","data":42}
```

Done. Every top-level function is an action; the payload's keys map to the
parameters **by name**; the return value comes back enveloped.

## The mapping is boring, on purpose

Magic that cannot be explained is a debugging loss dressed as a convenience.
So the mapping has four rules, and a command that prints them:

| Rule | What it means |
|------|---------------|
| service = file name | `calc.ring` answers as `"service": "calc"` |
| action = function | every top-level `func`, **except names starting with `_`** — those stay private |
| payload → parameters, by name | case-insensitive, order-independent; a **missing** parameter is refused as 422 naming every missing one at once; **extra** keys are ignored |
| return → `data` | strings, numbers and lists come back as JSON, enveloped |

Never trust prose — ask the tool:

```bash
ringserv serve --explain calc.ring
```

```text
gesture: calc.ring  ->  service `calc`
  exposed:
    calc.hello(name)
    calc.add(a, b)
  call shape:
    POST /api/v1  {"service":"calc","action":"add","payload":{"a": ..., "b": ...}}
```

What `serve` refuses, it refuses with the reason: a file that already
declares `RingServ([...])` (use `run` — it's a full application), a file name
that can't be a service name, a file with no functions, a function with more
than 10 parameters (that function wants the declarative form and a payload
object).

## Configuration lives beside the code — `ringserv.yaml`

Port, workers, database: configuration, not code. Put it in a file next to
your application:

```yaml
# ringserv.yaml
port: 8095
workers: 2
database: calc.db
static:
    /: public/
```

This is a **deliberately small yaml-like subset**, parsed by RingServ itself:
mappings, scalars, comments, one nesting level. Everything outside it —
anchors, aliases, tags, flow style, block scalars, sequences, tab
indentation — is **refused by name, with the line number**, because YAML's
famous surprises live in exactly the corners this subset declines to have.
(`country: no` stays the string `no` here. Only `true` and `false` are
booleans.)

Two boundaries worth knowing:

- **Code is not configuration.** `services:`, `data:`, `contracts:` in the
  yaml are refused with a pointer back to the application file. A function in
  a config file is a program pretending to be data.
- **The declaration wins.** `RingServ([...])` values beat the file, `--port`
  beats both, and every collision is *printed at boot* — never silently
  resolved. The file's job is to fill what the code left unset, so the same
  application can run on three machines with three yamls and zero edits.

## When you outgrow the gesture

The gesture is the first touch, not the ceiling. The moment you want
contracts, placement, actors, tables, sync or a journal, graduate to the
declarative form — same server, same envelope, same everything:

```ring
RingServ([
	:port = 8095,
	:services = [ ... ],          # docs/services.md
	:data     = [ ... ],          # docs/DATA.md
	:contracts = [ ... ]          # validated before dispatch
])
```

`ringserv new <name>` (without `--gesture`) scaffolds that form, page
included. Nothing you learned changes: the gesture *is* the declarative form,
generated for you — `--explain` shows precisely the declaration you would
have written.
