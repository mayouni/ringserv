/*
** The Node comparison, run honestly.
**
**   node tests/bench-vs-node.js [n-per-scenario]
**
** The same three service-shaped workloads, implemented twice with the
** same logic: once as a RingServ JS service (module form), once as a
** plain node:http server — no framework on either side, because the
** comparison is engines, not ecosystems. Same client, same machine,
** sequential requests, medians reported.
**
** What this measures: dispatch + JSON both ways (hello), JSON-heavy
** encode/decode (items), and a SQLite write+read round trip (till) —
** the last only when this Node has node:sqlite, and it is SKIPPED BY
** NAME otherwise rather than silently dropped.
**
** What this does NOT measure: parallel throughput (both sides would
** need tuned concurrency to say anything fair), cold start, npm
** install time. The numbers go into docs/BENCHMARKS.md with these
** caveats attached, and the losses stay in the table.
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const N = parseInt(process.argv[2] || "400", 10);
const WARM = 60;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-vsnode-"));

// ---------------------------------------------------------- the twins

const JS_SERVICE = `
import { total } from "./maths.js";
export const service = {
    async hello(p) {
        return { code: 0, message: "OK", data: { greeting: "Hello, " + (p.name || "world") + "!" } };
    },
    async items(p) {
        const n = p.n || 100;
        const items = [];
        for (let i = 0; i < n; i++) {
            items.push({ id: i, name: "item-" + i, price: (i * 7) % 1000, tags: ["a", "b"] });
        }
        return { code: 0, message: "OK", data: { items, total: total(items) } };
    },
};
`;
const JS_MATHS = `
export function total(items) {
    let t = 0;
    for (const it of items) t += it.price;
    return t;
}
`;
const RING_APP = `
RingServ([
    :port = 8121,
    :database = sysget("BENCH_DB"),
    :data = [ :sales = [ :item = :text, :amount = :number ] ],
    :services = [
        :bench = [ :js = "bench.js" ],
        :till  = [ :table = "sales" ]
    ]
])
`;

const NODE_SERVER = `
const http = require("http");
let sqlite = null;
try { sqlite = require("node:sqlite"); } catch {}
let db = null;
if (sqlite) {
    db = new sqlite.DatabaseSync(process.env.BENCH_DB_NODE);
    db.exec("create table if not exists sales (id integer primary key autoincrement, item text, amount integer)");
}
function total(items) { let t = 0; for (const it of items) t += it.price; return t; }
const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", d => body += d);
    req.on("end", () => {
        let out;
        try {
            const { action, payload: p = {} } = JSON.parse(body || "{}");
            if (action === "hello") {
                out = { code: 0, message: "OK", data: { greeting: "Hello, " + (p.name || "world") + "!" } };
            } else if (action === "items") {
                const n = p.n || 100;
                const items = [];
                for (let i = 0; i < n; i++) {
                    items.push({ id: i, name: "item-" + i, price: (i * 7) % 1000, tags: ["a", "b"] });
                }
                out = { code: 0, message: "OK", data: { items, total: total(items) } };
            } else if (action === "till" && db) {
                const r = db.prepare("insert into sales (item, amount) values (?, ?)").run(p.item, p.amount);
                const row = db.prepare("select * from sales where id = ?").get(r.lastInsertRowid);
                out = { code: 0, message: "OK", data: row };
            } else {
                out = { code: 1, message: "unknown action", data: "" };
            }
        } catch (e) {
            out = { code: 1, message: String(e), data: "" };
        }
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(out));
    });
});
server.listen(8122, "127.0.0.1", () => console.log("node up " + (db ? "with" : "WITHOUT") + " node:sqlite"));
`;

// ------------------------------------------------------------ harness

async function waitUp(port) {
    for (let i = 0; i < 150; i++) {
        try { const r = await fetch(`http://127.0.0.1:${port}/health`).catch(() => null);
              if (r && r.status === 200) return true; } catch {}
        try { const r2 = await fetch(`http://127.0.0.1:${port}/`, { method: "POST", body: "{}" });
              if (r2.status) return true; } catch {}
        await new Promise(r => setTimeout(r, 100));
    }
    return false;
}

async function timeOne(url, body) {
    const t0 = process.hrtime.bigint();
    const res = await fetch(url, { method: "POST", body: JSON.stringify(body) });
    await res.text();
    return Number(process.hrtime.bigint() - t0) / 1e6;
}

function stats(xs) {
    const s = [...xs].sort((a, b) => a - b);
    const q = p => s[Math.min(s.length - 1, Math.floor(p * s.length))];
    return { median: q(0.5), p90: q(0.9), mean: s.reduce((a, b) => a + b, 0) / s.length };
}

async function scenario(name, ringBody, ringUrl, nodeBody) {
    const out = { name };
    for (const [side, url, body] of [
        ["ringserv", ringUrl, ringBody],
        ["node", "http://127.0.0.1:8122/", nodeBody],
    ]) {
        for (let i = 0; i < WARM; i++) await timeOne(url, body);
        const xs = [];
        for (let i = 0; i < N; i++) xs.push(await timeOne(url, body));
        out[side] = stats(xs);
    }
    return out;
}

(async () => {
    // stage the twins
    const appDir = path.join(tmp, "ring"); fs.mkdirSync(appDir);
    fs.writeFileSync(path.join(appDir, "app.ring"), RING_APP);
    fs.writeFileSync(path.join(appDir, "bench.js"), JS_SERVICE);
    fs.writeFileSync(path.join(appDir, "maths.js"), JS_MATHS);
    fs.writeFileSync(path.join(tmp, "node-server.js"), NODE_SERVER);

    const ring = spawn(RINGSERV, ["run", path.join(appDir, "app.ring")], {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, BENCH_DB: path.join(tmp, "ring.db").replace(/\\/g, "/") },
    });
    const node = spawn(process.execPath, [path.join(tmp, "node-server.js")], {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, BENCH_DB_NODE: path.join(tmp, "node.db") },
    });
    let nodeHasSqlite = false;
    node.stdout.on("data", d => { if (String(d).includes("with node:sqlite")) nodeHasSqlite = true; });

    if (!await waitUp(8121)) { console.error("ringserv did not come up"); process.exit(2); }
    if (!await waitUp(8122)) { console.error("node did not come up"); process.exit(2); }
    console.log(`node ${process.version} vs ${path.basename(RINGSERV)} — ${N} sequential requests per scenario, medians\n`);

    const rows = [];
    rows.push(await scenario("dispatch + JSON (hello)",
        { service: "bench", action: "hello", payload: { name: "bench" } },
        "http://127.0.0.1:8121/api/v1",
        { action: "hello", payload: { name: "bench" } }));

    rows.push(await scenario("JSON-heavy (100-item list)",
        { service: "bench", action: "items", payload: { n: 100 } },
        "http://127.0.0.1:8121/api/v1",
        { action: "items", payload: { n: 100 } }));

    if (nodeHasSqlite) {
        rows.push(await scenario("SQLite write+read (till)",
            { service: "till", action: "create", payload: { item: "espresso", amount: 180 } },
            "http://127.0.0.1:8121/api/v1",
            { action: "till", payload: { item: "espresso", amount: 180 } }));
    } else {
        console.log("SKIPPED BY NAME: SQLite write+read — this Node has no node:sqlite module");
    }

    console.log("scenario".padEnd(28) + "ringserv med".padStart(14) + "node med".padStart(12) +
        "  ringserv p90".padStart(14) + "node p90".padStart(12));
    for (const r of rows) {
        console.log(r.name.padEnd(28) +
            (r.ringserv.median.toFixed(2) + " ms").padStart(14) +
            (r.node.median.toFixed(2) + " ms").padStart(12) +
            (r.ringserv.p90.toFixed(2) + " ms").padStart(14) +
            (r.node.p90.toFixed(2) + " ms").padStart(12));
    }

    ring.kill(); node.kill();
    await new Promise(r => setTimeout(r, 700));
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
})().catch(e => { console.error(e); process.exit(2); });
