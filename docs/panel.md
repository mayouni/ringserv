# The panel — one place for your apps

```bash
ringserv panel my-apps/
# RingServ — panel on http://127.0.0.1:8079/  (2 apps in my-apps/)
```

Open that address and you have the admin panel: every application in the
directory, each with its status, port, pid and uptime — **Start**, **Stop**,
a live log tail, and a call box that speaks to the app's own `/api/v1`, all
on one page. The header holds the server itself: a state chip and one
toggle that **starts or stops everything the panel hosts** — and the
panel **stays resident through a stop**, because a stop button that kills
the only thing able to start again is a trap, not a control.
(`/panel/shutdown` still exists for the terminal and the gates; the page
never calls it.)

*(Every claim here is executable — `tests/panel-gates.js`, 29 gates.)*

## What counts as an app

The panel scans one directory for two shapes — the same two shapes the CLI
serves:

| Shape | How it runs |
|-------|-------------|
| `<name>.ring` — a bare file of functions | `ringserv serve` (the [gesture](gesture.md)) |
| `<sub>/app.ring` — an application directory | `ringserv run` |

Ports are read from `ringserv.yaml` or the declaration's `:port` — and a
port the panel cannot determine is shown as **unknown, never invented**.

## The panel tells the truth

This is the design rule everything above hangs on:

- **Status follows the process, not the button.** An app that dies — or is
  killed behind the panel's back — is reported stopped, automatically: the
  panel watches the process's own pipes, and EOF is the one signal that
  cannot lie. (Gated: the suite kills a child directly and the panel must
  notice with no operator action.)
- **Start is proven, not assumed** — the gate is the app's *own* port
  answering `/health`, not the panel's belief.
- **Logs are the child's real output**, a bounded 64 KB tail per app. The
  panel is a window, not an archive.
- **Stopping the panel leaves no orphans** — every child it started dies
  with it, and the gate checks the ports, not the promise.

## The call box

Each app's drawer has a one-line caller: action + payload, answered with
the app's own envelope. The page talks to the panel and the panel forwards
to the app on loopback — same origin, no CORS configuration, nothing to
install. It is the ninety-seconds demo from [gesture.md](gesture.md),
permanently one click away.

## Loopback only, not configurable

A panel that starts and stops processes is an operations surface, so the
TLS doctrine ([TLS.md](TLS.md)) applies twice over: the panel binds
`127.0.0.1` and that is not a setting. Reaching it from elsewhere is a
reverse proxy's business, with authentication in front — the panel refuses
to be the thing that forgot.
