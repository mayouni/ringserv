/*
** Phase-9 gates: the journaled store.
**
** The journal makes four promises, and each one is only worth the gate
** that tries to break it:
**
**   APPEND-ONLY AND CHAINED — every record names the one before it, and a
**   body edited in the database is reported as ROMPUE, at the record where
**   the chain first fails. A chain nobody verifies is a hash column.
**
**   REPLAY IS THE ONLY RECOVERY — state lives in memory and is rebuilt
**   from history at boot. The gate kills the server and asks for the state
**   back. Nothing derived is stored, so nothing derived can survive the
**   restart by accident and make a broken replay look correct.
**
**   N WORKERS AGREE — each worker owns a private VM and replays into it.
**   A worker that only ever applied its OWN appends would drift, and the
**   drift is invisible in single-worker testing: the first run of this
**   fixture numbered four orders 1, 1, 2 across two workers. That is the
**   gate below that reads the same state repeatedly and demands one answer.
**
**   COMPACTION IS REFUSED — the shape log is trimmed on purpose; a journal
**   never is. The two stores are opposite primitives (docs/COMMONS.md §1),
**   and this is where that stops being prose.
**
**   node tests/journal-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "journal-app.ring");
const B = "http://127.0.0.1:8086";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function post(body) {
    const res = await fetch(B + "/api/v1", { method: "POST", body: JSON.stringify(body) });
    const text = await res.text();
    try { return JSON.parse(text); } catch { return { code: -1, message: text }; }
}
const call = (service, action, payload) => post({ service, action, payload });

async function waitUp() {
    const t0 = Date.now();
    while (Date.now() - t0 < 25000) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-journal-"));
const DB = path.join(tmp, "j.db").replace(/\\/g, "/");
let server = null;

/** Start against THE SAME database every time — the point is what survives. */
async function start() {
    server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: DB },
    });
    return waitUp();
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 900));
}

(async () => {
    check("the journal fixture comes up", await start());

    // ============================================ 1. append and the chain
    const WHO = ["ada", "grace", "edsger", "hedy", "barbara", "katherine"];
    const placed = [];
    for (const who of WHO) {
        const r = await call("orders", "place", { who, total: 10 });
        placed.push(r.data);
    }
    check("every append answered", placed.every(d => d && d.seq >= 1),
        JSON.stringify(placed.slice(0, 2)));
    check("seq is dense and increasing from 1",
        placed.map(d => d.seq).join(",") === WHO.map((_, i) => i + 1).join(","),
        placed.map(d => d.seq).join(","));
    check("every record has a 64-hex hash",
        placed.every(d => /^[0-9a-f]{64}$/.test(d.hash)));
    check("no two records share a hash",
        new Set(placed.map(d => d.hash)).size === placed.length);

    // The counter is derived by :apply, so it is a direct read of whether
    // the applying worker saw the whole history — not just its own share.
    check("the derived number counts every event, not this worker's share",
        placed.map(d => d.numero).join(",") === WHO.map((_, i) => i + 1).join(","),
        placed.map(d => d.numero).join(","));

    // ===================================== 2. N workers, one answer
    // Requests round-robin across workers; a drifting worker shows up as
    // two different answers to the same question.
    const states = [];
    for (let i = 0; i < 8; i++) states.push((await call("orders", "state", {})).data);
    check("every worker answers the same state",
        new Set(states.map(s => `${s.count}/${s.numero}`)).size === 1,
        JSON.stringify(states.map(s => `${s.count}/${s.numero}`)));
    check("...and it is the whole history",
        states[0].count === WHO.length && states[0].numero === WHO.length,
        JSON.stringify(states[0]));

    // ===================================== 3. reading out, and the chain
    let v = (await call("journal", "verify", {})).data;
    check("the chain verifies INTACTE", v.chain === "INTACTE" && v.events === WHO.length,
        JSON.stringify(v));

    const recs = (await call("journal", "read", { limit: 100 })).data.records;
    check("read returns every record in order",
        recs.length === WHO.length && recs.every((r, i) => r.seq === i + 1));
    check("the first record's prev is GENESE", recs[0].prev === "GENESE", recs[0].prev);
    check("each prev names the hash before it",
        recs.every((r, i) => i === 0 || r.prev === recs[i - 1].hash));
    check("the stored event carries what was appended",
        recs.map(r => r.event.who).join(",") === WHO.join(","),
        recs.map(r => r.event.who).join(","));
    check("every record is stamped with a time", recs.every(r => r.ts > 1700000000));

    check("read pages from a sequence number",
        (await call("journal", "read", { from: 4, limit: 2 })).data.records
            .map(r => r.seq).join(",") === "5,6");

    // ===================================== 4. what the service refuses
    const noAppend = await call("journal", "append", { type: "x" });
    check("the journal service exposes NO append action",
        noAppend.code !== 0 && /unknown action/i.test(noAppend.message),
        JSON.stringify(noAppend));

    const untyped = (await call("probe", "untyped", {})).data;
    check("an event with no :type is refused",
        untyped.refused === 1 && /:type/.test(untyped.why), JSON.stringify(untyped));

    const comp = (await call("probe", "compact", {})).data;
    check("compaction refuses a journal, by name",
        comp.refused === 1 && /JOURNAL/.test(comp.why) && /ventes/.test(comp.why),
        JSON.stringify(comp));

    const exported = (await call("probe", "export", {})).data.text;
    const lines = exported.trim().split(/\r?\n/);
    check("export is one JSON object per line, one per record",
        lines.length === WHO.length && lines.every(l => JSON.parse(l).type));

    // ===================================== 5. replay is the only recovery
    await stop();
    check("the server comes back on the same database", await start());

    const after = (await call("orders", "state", {})).data;
    check("state is rebuilt by replay alone",
        after.count === WHO.length && after.numero === WHO.length, JSON.stringify(after));

    // Appending after a restart must continue the SAME chain, not fork it.
    const more = (await call("orders", "place", { who: "joan", total: 5 })).data;
    check("an append after a restart continues the chain",
        more.seq === WHO.length + 1 && more.numero === WHO.length + 1, JSON.stringify(more));
    v = (await call("journal", "verify", {})).data;
    check("...and the chain is still INTACTE",
        v.chain === "INTACTE" && v.events === WHO.length + 1, JSON.stringify(v));

    // ===================================== 6. tampering is detected, and located
    await stop();
    // Edited through SQLite directly — which is exactly the threat model:
    // someone with the file, not someone with the API.
    // No sqlite3 CLI is assumed to exist, so the edit is made by a second
    // one-shot RingServ opened on the same file — a plain UPDATE, which is
    // precisely what the chain is supposed to survive being unable to stop.
    const target = 3;
    const editor = path.join(tmp, "tamper.ring");
    fs.writeFileSync(editor, [
        `RingServ([ :port = 8087, :database = sysget("RINGSERV_TEST_DB"),`,
        `           :services = [ :t = [ :go = func aReq {`,
        `                __db_exec("update __rs_journal_ventes set body = ` +
            `replace(body, 'edsger', 'EDSGER') where seq = ${target}")`,
        `                return Reply(:ok, [ :done = 1 ]) } ] ] ])`,
    ].join("\n"));
    const ed = spawn(RINGSERV, ["run", editor], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: DB },
    });
    for (let i = 0; i < 100; i++) {
        try { if ((await fetch("http://127.0.0.1:8087/health")).status === 200) break; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    await fetch("http://127.0.0.1:8087/api/v1", {
        method: "POST", body: JSON.stringify({ service: "t", action: "go", payload: {} }) });
    ed.kill();
    await new Promise(r => setTimeout(r, 900));

    check("the server comes up over the edited journal", await start());
    v = (await call("journal", "verify", {})).data;
    check("an edited body is reported ROMPUE", v.chain === "ROMPUE", JSON.stringify(v));
    check("...at the record that was edited", v.at === target, JSON.stringify(v));
    check("...and says which of the two invariants failed",
        /hash/.test(v.why), v.why);
    check("...having counted the intact prefix", v.events === target, JSON.stringify(v));

    await stop();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("journal-gates: " + (e && e.stack || e));
    await stop();
    process.exit(2);
});
