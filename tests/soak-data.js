/*
** Data-layer soak: sustained mixed CRUD against a FILE database across
** N workers, watching what accumulates.
**
** tests/soak-lite.js proves the request path is flat, but it computes —
** it never touches SQLite. Phase 3 added a whole new class of resources
** that soak has never seen: a connection per worker, a prepared
** statement per call, a WAL that grows until it is checkpointed, and a
** Ring list allocated PER ROW PER CELL on every read. This soak aims at
** exactly those.
**
** It also keeps score: every mutation is counted, so the final row
** count must be exactly right. A soak that only watches memory can pass
** while quietly corrupting data.
**
**   node tests/soak-data.js [ops]        (default 5000)
*/
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(__dirname, "fixtures", "crud-app.ring");
const PORT = 8215;
const BASE = "http://127.0.0.1:" + PORT;
const OPS = parseInt(process.argv[2] || "5000", 10);
const SEED = 2000;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

function rssMb(pid) {
    try {
        if (process.platform === "win32") {
            const out = execSync(
                `powershell -NoProfile -Command "(Get-Process -Id ${pid}).WorkingSet64"`,
                { timeout: 15000 }).toString().trim();
            return Math.round(parseInt(out, 10) / 1024 / 1024 * 10) / 10;
        }
        return Math.round(parseInt(execSync(`ps -o rss= -p ${pid}`).toString().trim(), 10) / 1024 * 10) / 10;
    } catch { return -1; }
}

function sizeMb(file) {
    try { return Math.round(fs.statSync(file).size / 1024 / 1024 * 100) / 100; }
    catch { return 0; }
}

async function call(service, action, payload) {
    const res = await fetch(BASE + "/api/v1", {
        method: "POST",
        body: JSON.stringify({ service, action, payload }),
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}

(async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-soakdata-"));
    const dbFile = path.join(tmp, "soak.db").replace(/\\/g, "/");
    const server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: dbFile, RINGSERV_TEST_PORT: String(PORT) },
    });
    let died = false;
    server.on("exit", () => { died = true; });

    try {
        const t0 = Date.now();
        let up = false;
        while (Date.now() - t0 < 25000) {
            try { if ((await fetch(BASE + "/health")).status === 200) { up = true; break; } } catch {}
            await new Promise(r => setTimeout(r, 200));
        }
        check("server comes up on a file database", up);

        // --- seed, so reads return real work rather than empty sets
        const live = [];
        for (let i = 0; i < SEED; i++) {
            const r = await call("notes", "create",
                { title: "seed-" + i, body: "x".repeat(80), weight: i % 100 });
            if (r.json && r.json.code === 0) live.push(r.json.data.id);
        }
        check(`seeded ${SEED} rows`, live.length === SEED, "got " + live.length);

        // --- the soak proper: a mix that touches every path
        const samples = [];
        let errors = 0, created = SEED, deleted = 0;
        const started = Date.now();
        for (let i = 0; i < OPS; i++) {
            const pick = i % 10;
            let r;
            if (pick === 0) {
                r = await call("notes", "create",
                    { title: "op-" + i, body: "y".repeat(120), weight: i % 50 });
                if (r.json && r.json.code === 0) { live.push(r.json.data.id); created++; }
            } else if (pick === 1 && live.length > SEED / 2) {
                const id = live.splice(Math.floor(live.length / 2), 1)[0];
                r = await call("notes", "delete", { id });
                if (r.status === 200) deleted++;
            } else if (pick === 2) {
                r = await call("notes", "update",
                    { id: live[i % live.length], title: "upd-" + i });
            } else if (pick === 3) {
                // The allocation-heavy path: a big result set, every cell
                // a fresh Ring list.
                r = await call("notes", "list", {});
            } else if (pick === 4) {
                r = await call("notes", "list", { filter: { weight: i % 50 } });
            } else if (pick === 5) {
                r = await call("rules", "check", { scores: [1, 2, 3], code: "abc" });
            } else {
                r = await call("notes", "get", { id: live[i % live.length] });
            }
            if (!r || r.status >= 500) errors++;

            if (i === Math.floor(OPS * 0.1) || (i + 1) % Math.max(1, Math.floor(OPS / 5)) === 0) {
                samples.push({
                    at: i + 1,
                    rss: rssMb(server.pid),
                    db: sizeMb(dbFile),
                    wal: sizeMb(dbFile + "-wal"),
                });
            }
            if (died) break;
        }
        const secs = ((Date.now() - started) / 1000).toFixed(1);

        console.log(`\n  ${OPS} mixed operations in ${secs}s ` +
            `(${Math.round(OPS / parseFloat(secs))}/s), ${errors} error(s)\n`);
        console.log("       after      RSS       db      wal");
        for (const s of samples) {
            console.log(`  ${String(s.at).padStart(10)}  ${String(s.rss).padStart(7)}M ` +
                `${String(s.db).padStart(7)}M ${String(s.wal).padStart(6)}M`);
        }

        check("no 5xx during the soak", errors === 0, errors + " error(s)");
        check("server never died", !died);

        // --- memory: compare the post-warmup sample against the last, so
        // the initial heap climb is not mistaken for a leak.
        const first = samples[0], last = samples[samples.length - 1];
        const growth = last.rss - first.rss;
        check(`RSS is flat after warmup (${first.rss}M → ${last.rss}M over ` +
            `${last.at - first.at} ops)`, growth < 25, `grew ${growth.toFixed(1)}M`);

        // --- the WAL must be checkpointed, not grow without bound.
        check(`WAL stays bounded (${last.wal}M)`, last.wal < 64, last.wal + "M");

        // --- correctness: the score must be exactly right.
        const expected = created - deleted;
        let r = await call("notes", "list", {});
        check(`row count is exactly right (${expected})`,
            r.json && r.json.data.count === expected,
            `expected ${expected}, got ${r.json && r.json.data && r.json.data.count}`);

        // --- and the data itself survived a restart with the WAL in play.
        server.kill();
        await new Promise(res => setTimeout(res, 1200));
        const again = spawn(RINGSERV, ["run", FIXTURE], {
            stdio: ["ignore", "ignore", "pipe"],
            env: { ...process.env, RINGSERV_TEST_DB: dbFile, RINGSERV_TEST_PORT: String(PORT) },
        });
        try {
            const t1 = Date.now();
            let back = false;
            while (Date.now() - t1 < 25000) {
                try { if ((await fetch(BASE + "/health")).status === 200) { back = true; break; } } catch {}
                await new Promise(res => setTimeout(res, 200));
            }
            check("restarts against the soaked database", back);
            r = await call("notes", "list", {});
            check("every row survived the restart",
                r.json && r.json.data.count === expected,
                `expected ${expected}, got ${r.json && r.json.data && r.json.data.count}`);
        } finally {
            again.kill();
        }
    } finally {
        try { server.kill(); } catch {}
        await new Promise(r => setTimeout(r, 500));
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    }

    console.log(failed === 0
        ? "\nAll " + passed + " data-soak gates passed."
        : "\n" + failed + " gate(s) FAILED (" + passed + " passed).");
    process.exit(failed ? 1 : 0);
})().catch(e => { console.error("harness crashed:", e); process.exit(1); });
