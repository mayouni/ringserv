# fieldnotes — the target developer experience

**This example does not run yet.** It is a design artifact: the
application we intend `ringserv new` to make possible, written first
so every phase of the [roadmap](../../docs/roadmap.md) can be judged
against it. When phase 6 lands, this folder must work exactly as
written — it is the blueprint's executable promise.

A note-taking app that is 99 % local-first: notes live in the page,
sync when a connection exists, and one heavy service (the report)
runs on the server.

```bash
ringserv dev        # the whole stack: server, sync, page
```

- [app.ring](app.ring) — the services, declared once
- [contracts.ring](contracts.ring) — the governed shapes
- [topology.ring](topology.ring) — where each piece lives
- [public/index.html](public/index.html) — the RingScript page
