/*
** Phase-3 schema gates: the Data() declaration against a real server —
** creation, types, idempotency, persistence across restart, concurrent
** writes from N workers, and DB errors as clean envelopes.
**
** Usage: node tests/data-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(__dirname, "fixtures", "data-app.ring");
const BASE = "http://127.0.0.1:8094";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function post(service, action, payload) {
    const res = await fetch(BASE + "/api/v1", {
        method: "POST",
        body: JSON.stringify({ service, action, payload: payload || {} }),
    });
    let json = null;
    const text = await res.text();
    try { json = JSON.parse(text); } catch {}
    return { status: res.status, text, json };
}

async function waitUp(ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
        try { if ((await fetch(BASE + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 200));
    }
    return false;
}

function startServer(dbPath) {
    const server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: dbPath },
    });
    // `died` means "exited on its own" — an exit after we ask it to stop
    // is the harness doing its job, not a crash.
    server.died = false;
    server.stopping = false;
    server.on("exit", () => { if (!server.stopping) server.died = true; });
    return server;
}

async function stop(server) {
    server.stopping = true;
    server.kill();
    // Wait for the port to actually free before the next start.
    await new Promise(r => setTimeout(r, 800));
}

(async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-data-"));
    const dbFile = path.join(tmp, "gates.db").replace(/\\/g, "/");

    // ---------------------------------------------- run 1: on-disk database
    let server = startServer(dbFile);
    try {
        check("server with :database comes up", await waitUp(25000));

        let r = await post("notes", "schema");
        const tables = r.json && r.json.data ? r.json.data.tables : [];
        check("declared tables exist", Array.isArray(tables) &&
            tables.includes("notes") && tables.includes("visits"), r.text);
        check("declared columns exist, id added automatically",
            r.json && ["id", "title", "body", "weight", "tags"]
                .every(c => r.json.data.notes.includes(c)), r.text);
        check("DataPath reports the declared database",
            r.json && r.json.data.path === dbFile, r.text);

        r = await post("notes", "add", { title: "first", weight: 1.5 });
        check("insert through a service works", r.status === 200 &&
            r.json.data.count === 1, r.text);

        // Concurrency: 40 parallel writes across 4 workers, each with its
        // own connection to the same file.
        const writes = await Promise.all(Array.from({ length: 40 }, (_, i) =>
            post("notes", "add", { title: "n" + i, weight: i })));
        check("40 concurrent writes across workers all succeed",
            writes.every(w => w.status === 200 && w.json.code === 0),
            writes.find(w => w.status !== 200)?.text);

        r = await post("notes", "count");
        check("all concurrent writes landed (41 rows)",
            r.json && r.json.data.count === 41, r.text);

        // A worker other than the writer must see the data — that is the
        // whole point of a shared file plus WAL.
        const reads = await Promise.all(Array.from({ length: 12 }, () =>
            post("notes", "count")));
        check("every worker sees the same row count",
            reads.every(x => x.json && x.json.data.count === 41),
            JSON.stringify(reads.map(x => x.json && x.json.data.count)));

        r = await post("notes", "bad");
        check("SQL error is a clean 500 envelope", r.status === 500 &&
            r.json && /no_such_table/.test(r.json.message), r.text);

        r = await post("notes", "count");
        check("server survives the SQL error", r.status === 200 &&
            r.json.data.count === 41, r.text);
        check("server never died during run 1", !server.died);
    } finally {
        await stop(server);
    }

    // -------------------------------- run 2: restart against the same file
    server = startServer(dbFile);
    try {
        check("restart against an existing database comes up", await waitUp(25000));
        let r = await post("notes", "count");
        check("data persists across restart", r.json && r.json.data.count === 41, r.text);

        r = await post("notes", "schema");
        check("re-running Data() is idempotent (no duplicate columns)",
            r.json && r.json.data.notes.filter(c => c === "title").length === 1, r.text);

        r = await post("notes", "add", { title: "after restart", weight: 9 });
        check("writes continue after restart", r.json && r.json.data.count === 42, r.text);
    } finally {
        await stop(server);
    }

    // ------------------------------------------- run 3: in-memory default
    server = startServer(":memory:");
    try {
        check("in-memory database comes up", await waitUp(25000));
        let r = await post("notes", "add", { title: "mem", weight: 1 });
        check("in-memory writes work", r.status === 200 && r.json.code === 0, r.text);
        // Shared-cache: every worker must see the one in-memory database,
        // not a private empty one.
        const counts = await Promise.all(Array.from({ length: 12 }, () =>
            post("notes", "count")));
        check("all workers share one in-memory database",
            counts.every(x => x.json && x.json.data.count === 1),
            JSON.stringify(counts.map(x => x.json && x.json.data.count)));
    } finally {
        await stop(server);
    }

    fs.rmSync(tmp, { recursive: true, force: true });
    console.log(failed === 0
        ? "\nAll " + passed + " schema gates passed."
        : "\n" + failed + " gate(s) FAILED (" + passed + " passed).");
    process.exit(failed ? 1 : 0);
})().catch(e => { console.error("harness crashed:", e); process.exit(1); });
