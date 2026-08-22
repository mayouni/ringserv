# Comptoir — the broad reference application

A café counter: orders taken, sent to a kitchen, paid for, and recorded in
a fiscal journal that may never be altered.

```bash
ringserv run examples/comptoir/app.ring     # then open http://127.0.0.1:8110
node tests/comptoir-gates.js                # 38 gates, the whole thing driven
```

## Why it exists

[fieldnotes](../fieldnotes) is the **teaching** example: one seam at a time,
in the order [the guide](../../docs/fieldnotes-app.md) introduces them.

Comptoir is the **stress** example. Every suite in `tests/` proves a seam in
isolation, which is how a seam gets proven and how an *interaction* gets
missed — the lesson this repository already paid for once, when nine loader
gates passed while the feature was broken because none of them exercised two
features together. Comptoir wires six hostable forms to each other the way a
real counter application wires them, so that class of bug has somewhere to
show up.

It is shaped after a real proprietary application this server was designed
against, rebuilt in the open so the gates can run on it and anyone can read
the whole thing.

## The six forms it hosts

| Service | Form | What it shows |
|---|---|---|
| `menu` | generic table | five actions from one line, and a **synced** table |
| `orders` | **class** | internal state, `Action` suffix, private helpers unreachable |
| `kitchen` | declarative | a hash of anonymous functions, refusing bad state by name |
| `receipt` | **JavaScript** | QuickJS, `Intl` money, calling back into Ring by name |
| `journal` | journaled store | append-only, hash-chained, **read-only by construction** |
| `sync` | the sync layer | offered explicitly, never automatic |

…over contracts, an actor seam (401 vs 403), C3 placement, static files and
a `ringserv.yaml`. Plus a **seventh** form that needs no declaration at all:

```bash
ringserv serve --explain examples/comptoir/tools/tip.ring
```

## The two stores, side by side

This is the point of the application, and the reason it has both:

- **`menu` is a table.** Prices change; the current price is the truth. It
  survives a restart *as rows*, and it syncs to the page.
- **`ventes` is a journal.** Orders, kitchen moves, payments and
  cancellations are **events**. Ticket state survives a restart *by replay*,
  and the per-day ticket number is derived rather than stored — so a crash
  mid-service loses nothing, because there is nothing outside the journal to
  lose.

A **cancellation is an event, not a deletion**: the order stays in the record
with its reason beside it. That single difference is why a fiscal record
cannot live in a store whose defining feature is that rows change.

## What building it found

A reference application earns its keep by breaking things. Building this one
found two real defects, both fixed:

1. **`Intl` was absent.** The first line of money handling reached for
   `Intl.NumberFormat`, which is exactly what a JS programmer does.
   RingServ now ships a named subset ([JS.md](../../docs/JS.md)).
2. **JS `false` arrived as `0`, and `null` as `""`.** Ring has no boolean
   and no null, and the reply was being decoded into Ring and re-encoded. At
   the wire the guest's own JSON is now carried through verbatim.

A third was found by the same app in passing: **static routes resolved
against the working directory** while `:js` paths resolved against the
application, so running an app by path served 404 for its own page. Both
now anchor to the application.
