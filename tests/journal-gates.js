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
const { spawn, spawnSync } = require("child_process");
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

    // ================================= 5b. the same answers, from a shell
    // The ambassador docs/COMMONS.md §1 named and phase 9 owed. `Journal()`
    // made the record durable and `RsJournalService()` made it answerable
    // over HTTP; these gates are the case the design was actually written
    // for -- the box in a drawer, nothing connected, and an inspector
    // asking whether the chain holds. They run the REAL binary against the
    // REAL file, because an in-process check would prove the function and
    // not the command.
    await stop();
    const cliEnv = { ...process.env, RINGSERV_TEST_DB: DB };
    const cli = (...a) => spawnSync(RINGSERV, ["journal", ...a],
        { encoding: "utf8", env: cliEnv });
    const jsonl = t => t.split("\n").map(s => s.trim()).filter(s => s.length > 0);

    let c = cli("list", FIXTURE);
    check("journal list names the declared journal",
        c.status === 0 && c.stdout.trim() === "ventes", c.stdout + c.stderr);

    c = cli("verify", FIXTURE);
    check("journal verify answers INTACTE with no server running",
        c.status === 0 && c.stdout.includes("INTACTE"), c.stdout + c.stderr);
    check("...counting every event, not this shell's share",
        c.stdout.includes(String(WHO.length + 1)), c.stdout);
    check("...and naming the database it read, which an auditor needs first",
        c.stdout.includes(path.basename(DB)), c.stdout);

    c = cli("verify", FIXTURE, "--json");
    check("verify --json answers the service's own envelope",
        c.status === 0 && JSON.parse(c.stdout).chain === "INTACTE", c.stdout + c.stderr);

    c = cli("export", FIXTURE);
    const cliLines = jsonl(c.stdout);
    check("journal export writes one JSON object per record",
        c.status === 0 && cliLines.length === WHO.length + 1 &&
        cliLines.every(l => JSON.parse(l).type), c.stdout + c.stderr);
    // The CLI and the service must not be two exports. `exported` was read
    // over HTTP in section 4, one record ago; the tail is compared so the
    // one append since then does not make an agreement look like a
    // disagreement.
    check("...identical to what the service exports, line for line",
        cliLines.slice(0, WHO.length).join("|") === jsonl(exported).join("|"),
        cliLines.slice(0, WHO.length).join("|"));

    const outFile = path.join(tmp, "export.jsonl");
    c = cli("export", FIXTURE, "--out", outFile);
    check("export --out writes the file and reports what it wrote",
        c.status === 0 && fs.existsSync(outFile) &&
        jsonl(fs.readFileSync(outFile, "utf8")).length === WHO.length + 1,
        c.stdout + c.stderr);

    // Three ways to be wrong, and each has to fail LOUDLY. A command that
    // prints an empty export when it cannot find the record is worse than
    // one that prints nothing: it answers the auditor's question with the
    // wrong answer.
    c = cli("verify", FIXTURE, "--journal", "achats");
    check("an undeclared journal is refused, and the real ones are named",
        c.status !== 0 && c.stdout.includes("achats") && c.stdout.includes("ventes"),
        c.stdout + c.stderr);

    c = cli("frobnicate", FIXTURE);
    check("an unknown verb is refused with the usage",
        c.status === 2 && c.stdout.includes("ringserv journal"), c.stdout + c.stderr);

    c = cli("export", FIXTURE, "--db", path.join(tmp, "nothing-here.db"));
    check("a database with no journal table reports the fact, not an empty export",
        c.status !== 0 && c.stdout.includes("no such table") &&
        !c.stdout.includes('"type"'), c.stdout + c.stderr);
    check("...and says the empty file is not evidence the record was lost",
        c.stdout.includes("proves nothing was lost"), c.stdout);


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

    // The same command over the tampered file. A verification tool that
    // cannot fail is decoration, and the exit code is the whole of what a
    // cron job reads.
    c = cli("verify", FIXTURE);
    check("journal verify reports ROMPUE from the command line",
        c.status === 1 && c.stdout.includes("ROMPUE"), c.stdout + c.stderr);
    check("...naming the record where the chain broke",
        c.stdout.includes("seq " + target), c.stdout);

    // ================================ the deversement (phase 13)
    // A journal written elsewhere, in the legacy interchange dialect
    // (16-hex chains), imports into an empty Journal() and verifies
    // INTACTE — then NATIVE appends continue the same chain. The fixture
    // is SYNTHESIZED by the legacy discipline itself, right here, so the
    // gate proves the documented algorithm and never carries anyone's
    // data.
    {
        const crypto = require("crypto");
        let prev = "GENESE";
        const lines = [];
        for (const [type, extra] of [
            ["passer_commande", { who: "ada", total: 580 }],
            ["faire_avancer", { id: 1, etat: "prete" }],
            ["passer_commande", { who: "grace", total: 320 }],
        ]) {
            const ev = { type, ...extra, ts: 1787000000000 + lines.length * 60000 };
            ev.prev = prev;
            ev.hash = crypto.createHash("sha256")
                .update(prev + JSON.stringify({ ...ev, hash: undefined }))
                .digest("hex").slice(0, 16);
            prev = ev.hash;
            lines.push(JSON.stringify(ev));
        }
        const legacy = path.join(tmp, "legacy.jsonl");
        fs.writeFileSync(legacy, lines.join("\n") + "\n");

        const impDb = path.join(tmp, "imp.db").replace(/\\/g, "/");
        const run = (args) => spawnSync(RINGSERV, ["journal", ...args, FIXTURE], {
            encoding: "utf8", env: { ...process.env, RINGSERV_TEST_DB: impDb },
        });

        let r7 = run(["import", "--in", legacy]);
        check("a legacy journal imports into an empty Journal()",
            r7.status === 0 && /INTACTE/.test(r7.stdout + r7.stderr),
            (r7.stdout + r7.stderr).slice(0, 160));

        r7 = run(["verify"]);
        check("...and verifies INTACTE by the legacy discipline",
            r7.status === 0 && /3 event\(s\)/.test(r7.stdout + r7.stderr),
            (r7.stdout + r7.stderr).slice(0, 160));

        const rt = path.join(tmp, "rt.jsonl");
        run(["export", "--out", rt]);
        check("export round-trips the imported bytes identically",
            fs.readFileSync(legacy, "utf8").replace(/\r\n/g, "\n") ===
            fs.readFileSync(rt, "utf8").replace(/\r\n/g, "\n"));

        r7 = run(["import", "--in", legacy]);
        check("importing over a non-empty journal is refused, with the count",
            r7.status === 1 && /already holds 3/.test(r7.stdout + r7.stderr),
            (r7.stdout + r7.stderr).slice(0, 160));

        const bad = path.join(tmp, "bad.jsonl");
        fs.writeFileSync(bad, fs.readFileSync(legacy, "utf8").replace("ada", "eve"));
        const badDb = path.join(tmp, "bad.db").replace(/\\/g, "/");
        r7 = spawnSync(RINGSERV, ["journal", "import", "--in", bad, FIXTURE], {
            encoding: "utf8", env: { ...process.env, RINGSERV_TEST_DB: badDb },
        });
        check("a tampered file is refused AT ITS LINE, never laundered",
            r7.status === 1 && /ROMPUE at line 1/.test(r7.stdout + r7.stderr),
            (r7.stdout + r7.stderr).slice(0, 160));

        // The prize: boot the app on the imported journal — legacy events
        // REPLAY through :apply — then a native append continues the
        // legacy chain, and verify stays INTACTE across the seam.
        server = spawn(RINGSERV, ["run", FIXTURE], {
            stdio: ["ignore", "ignore", "pipe"],
            env: { ...process.env, RINGSERV_TEST_DB: impDb },
        });
        check("the app boots over the imported journal", await waitUp());
        let st = (await call("orders", "state", {})).data;
        check("legacy events replayed through :apply",
            st.count === 2 && st.numero === 2, JSON.stringify(st));
        const more2 = (await call("orders", "place", { who: "joan", total: 5 })).data;
        check("a NATIVE append continues the legacy chain",
            more2.seq === 4 && /^[0-9a-f]{64}$/.test(more2.hash), JSON.stringify(more2));
        const v7 = (await call("journal", "verify", {})).data;
        check("...and the mixed chain verifies INTACTE across the seam",
            v7.chain === "INTACTE" && v7.events === 4, JSON.stringify(v7));
        await stop();
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("journal-gates: " + (e && e.stack || e));
    await stop();
    process.exit(2);
});
