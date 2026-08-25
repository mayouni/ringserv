# Putting it up, and changing it

Three things you do to an application, over and over, for as long as it
lives: **put it up**, **change it**, **put the change live**. RingServ makes
the third one free.

---

## Change a running server, without stopping it

```bash
ringserv reload --port 8210
```

Edit your `.ring` file, run that, and the running server is running your new
code. **The process does not restart. The port is never rebound. Open
connections stay open.** Measured: 62 ms for three workers.

In the admin panel it is a **Reload** button next to Start and Stop, and the
panel tells you what happened rather than flashing green:

| What you see | What it means |
|---|---|
| **reloaded — all N workers took the new code** | done |
| **refused — the code would not run, so nothing changed** | your file has an error. The server is untouched and still serving. Fix it and press again. |
| **PARTIAL RELOAD** (red) | some workers took it and some did not, so the server is answering with two versions. Rare, and the one case worth restarting for. |

Those three read differently on purpose. An operator who cannot tell
*nothing happened* from *half of it happened* will treat them the same, and
only one of them is an emergency.

### How it works, in one paragraph

Each worker owns its own resident Ring VM, so no worker has to agree with
any other about when to change. A reload swaps the source and bumps a
**generation counter**; each worker re-evaluates the application **between
two requests**, on its own thread, where it is already alone with its own
state. A request that has already started keeps the code it started under.
The HTTP threads never learn that anything happened — which is why the
listener is untouched.

**A worker that cannot evaluate the new code goes back to the old code and
is counted.** That count is what the three messages above are made of.

### What it will not do

- **Loopback only.** This endpoint replaces the code the server runs, so it
  is not something an application can open to the network. Deploying from
  another machine is a different product with a different threat model, and
  RingServ says no rather than doing it badly.
- **It re-reads ONE file** — the one the server was started with, and
  whatever that file loads. A server started with `ringserv eval` has no
  file to re-read and says so.
- **It does not migrate your data.** Reloading changes code. If your new
  code expects a column that is not there, it will fail like any other code
  that expects a column that is not there.

---

## Putting an application up

```bash
ringserv deploy ./myapp --port 8210
```

That is the whole thing. It makes a **named deployment**: your code, and a
private corner beside it for everything the application will ever write.

```
deployments/myapp/
    app.ring, public/, services/…     your code
    .ringserv/
        deployment.yaml               name, port, where it came from, when
        data/                         the database, and the journal inside it
        logs/
```

Then run it, with the command `deploy` prints for you, ready to paste:

```bash
ringserv run deployments/myapp/app.ring --port 8210 --data deployments/myapp/.ringserv/data
```

`--data` is what puts the database in that private corner. A relative
`:database` is resolved against it; an absolute one is left alone, because
an application that named an absolute path meant it.

**A `.db` sitting beside your source is not deployed.** That file is your
scratch copy, and installing test data as production data is a mistake
nobody recovers from quickly. `.git`, `node_modules` and build directories
are skipped too, by name.

---

## Changing what is deployed

```bash
ringserv redeploy myapp
```

**Replaces the code, keeps the data, and — if it is running — reloads it
live.** One command, no downtime, no second thing to remember.

```
redeployed `myapp` — 12 file(s) replaced, data untouched
  and reloaded it live on port 8210 — no restart, no dropped connection
```

**Why the data is safe is worth one sentence, because it is not care — it
is arithmetic.** Redeploy deletes everything in the deployment directory
*except* `.ringserv/`, then copies the new code in. The record is not
somewhere the code change is careful to avoid; it is somewhere the code
change cannot reach. There is no flag to forget and no order to get right.

If the running server refuses the new code, you are told both halves: the
files are deployed, and the server is unchanged. Fix and `ringserv reload`.

Redeploy takes its source from the manifest, so it repeats itself. Point it
somewhere new with `--from <folder>`, or skip the live reload with
`--no-reload`.

---

## Seeing what is deployed

```bash
ringserv ls
```

```
deployments in deployments

  myapp              port 8210   running   2026-08-25 21:12 UTC
  comptoir           port 8250   stopped   2026-08-25 19:40 UTC
```

`running` is **asked**, not assumed from a pid file — a live process is not
a serving port. The timestamp says UTC because it is UTC.

Deployments live in `./deployments` unless you say otherwise with `--root`
or the `RINGSERV_DEPLOYMENTS` environment variable.

---

## Four things worth doing, learned by standing one up

**1. Let `deploy` keep the data out of the application folder.** That is
what `.ringserv/data` and `--data` are for. An upgrade replaces the code and
must not be able to reach the record.

**2. Choose the port from the command line, not by editing the app.**
`--port` beats both the declaration and `ringserv.yaml`, and the override is
printed at boot. A deployment that edits its own application has to re-edit
it after every upgrade, and one day will forget. *(Comptoir declares 8110 —
which is also the port its own test suite binds.)*

**3. Do not trust a pid.** A start that failed to bind can leave a pid file
pointing at a process happily serving something else. Ask `/health`.

**4. Rehearse the restore, and count.** An untested backup is a belief. Copy
the database (with its `-wal` and `-shm` companions), restore it *somewhere
else*, and check the **event count**, not just the verdict — an empty
journal verifies `INTACTE` perfectly well, and a restore that restored
nothing will happily tell you so.

---

## The panel

```bash
ringserv panel deployments
```

Point it at your deployments root and every deployment is there, with Start,
Stop, **Reload**, a log tail, and a box to call any service. Nothing had to
be taught to the panel: a deployment is laid out as `<name>/app.ring`, which
is exactly what the panel already looks for.

Loopback only, for the same reason as the reload endpoint.

---

## What this is not

No process supervisor, no clustering, no service-manager integration, no
remote deploy. Those are real needs and each is a different product; a
server that grows a supervisor grows a supervisor's failure modes. On
Windows use a scheduled task or a service wrapper; on Linux, a systemd unit.
RingServ puts an application up **on the machine you are on**, and says so.
