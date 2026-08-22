/*
** The broad gate: one real application, every hostable form at once.
**
** The other suites test seams in isolation, which is how a seam gets
** proven and how an INTERACTION gets missed — the lesson the loader
** regression already taught this repository (nine gates green while the
** feature was broken, because none of them exercised two features
** together). examples/comptoir exists so that cannot happen quietly:
** six hostable forms, wired to each other the way a counter application
** wires them, driven end to end.
**
**   :menu     generic table service
**   :orders   class service, with private helpers
**   :kitchen  declarative service
**   :receipt  JavaScript service, calling back into Ring
**   :journal  journaled store, read-only by construction
**   :sync     the sync layer's own service
**
** ...over contracts, an actor seam, placement, a synced table, static
** files, ringserv.yaml, and a seventh form needing no declaration at
** all (tools/tip.ring, served by `ringserv serve`).
**
**   node tests/comptoir-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const APP = path.join(ROOT, "examples", "comptoir", "app.ring");
const TIP = path.join(ROOT, "examples", "comptoir", "tools", "tip.ring");
const B = "http://127.0.0.1:8110";
const SECRET = "comptoir-test-secret";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const b64 = o => Buffer.from(o).toString("base64url");
function jwt(claims) {
    const h = b64(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const p = b64(JSON.stringify(claims));
    const s = b64(crypto.createHmac("sha256", SECRET).update(h + "." + p).digest());
    return `${h}.${p}.${s}`;
}

async function call(service, action, payload, token) {
    const headers = { "content-type": "application/json" };
    if (token) headers.authorization = "Bearer " + token;
    const res = await fetch(B + "/api/v1", {
        method: "POST", headers,
        body: JSON.stringify({ service, action, payload }),
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}
async function get(p) {
    const res = await fetch(B + p);
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-comptoir-"));
const DB = path.join(tmp, "comptoir.db").replace(/\\/g, "/");
let server = null;

async function waitUp(port, ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < (ms || 25000)) {
        try {
            if ((await fetch(`http://127.0.0.1:${port}/health`)).status === 200) return true;
        } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
function start(args) {
    server = spawn(RINGSERV, args || ["run", APP], {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, COMPTOIR_DB: DB, COMPTOIR_SECRET: SECRET },
    });
    let out = "";
    server.stdout.on("data", d => { out += d; });
    server.stderr.on("data", d => { out += d; });
    server.getOutput = () => out;
    return server;
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 900));
}

(async () => {
    check("the reference application comes up", (start(), await waitUp(8110)));

    // ===================================== 1. the generic table service
    let r = await call("menu", "create", { name: "Espresso", price: 180, category: "cafe" });
    check("generic table: create answers an id", r.json.code === 0 && r.json.data.id >= 1,
        JSON.stringify(r.json));
    await call("menu", "create", { name: "Croissant", price: 220, category: "viennoiserie" });
    r = await call("menu", "list", {});
    check("generic table: list returns the rows",
        r.json.data.rows.length === 2, JSON.stringify(r.json.data).slice(0, 120));
    r = await call("menu", "update", { id: 1, price: 190 });
    check("generic table: update takes", r.json.code === 0, JSON.stringify(r.json));
    r = await call("menu", "get", { id: 1 });
    // `get` answers the row AS the data, not wrapped in {row:…} — the
    // envelope already is the wrapper, and wrapping twice is a thing the
    // caller then has to unwrap twice.
    check("...and the row shows it", r.json.data.price === 190, JSON.stringify(r.json.data));

    // ============================================= 2. the class service
    r = await call("orders", "place", {
        client: "Ada",
        lignes: [{ item: "Espresso", qty: 2, price: 190 },
                 { item: "Croissant", qty: 1, price: 220 }],
    });
    check("class service: place answers a ticket and a chain hash",
        r.json.code === 0 && r.json.data.ticket === 1 && r.json.data.total === 600 &&
        /^[0-9a-f]{64}$/.test(r.json.data.hash), JSON.stringify(r.json.data));

    r = await call("orders", "total", {});
    check("class service: a non-Action method is unreachable from the wire",
        r.json.code === 1 && /unknown action/.test(r.json.message), JSON.stringify(r.json));

    r = await call("orders", "state", {});
    check("class service: state is derived, not stored",
        r.json.data.tickets === 1 && r.json.data.open === 1 && r.json.data.paid === 0,
        JSON.stringify(r.json.data));

    // ======================================= 3. the declarative service
    r = await call("kitchen", "queue", {});
    check("declarative service: the queue holds the open ticket",
        r.json.data.waiting === 1 && r.json.data.tickets[0].client === "Ada",
        JSON.stringify(r.json.data).slice(0, 120));

    r = await call("kitchen", "advance", { ticket: 1, to: "en_cuisine" });
    check("declarative service: advancing journals the move", r.json.code === 0,
        JSON.stringify(r.json));
    r = await call("kitchen", "advance", { ticket: 1, to: "nowhere" });
    check("...and an unknown state is refused 422, naming the path",
        r.status === 422 && /recue -> en_cuisine/.test(r.json.message), r.json.message);

    // ======================================== 4. the JavaScript service
    r = await call("receipt", "total", { lignes: [{ qty: 2, price: 190 }] });
    check("JS service: money maths answers",
        r.json.code === 0 && r.json.data.total === 380, JSON.stringify(r.json.data));
    check("JS service: Intl.NumberFormat formats fr-FR currency",
        r.json.data.formatted === "3,80 €", JSON.stringify(r.json.data.formatted));

    r = await call("receipt", "render", { ticket: 1 });
    check("JS service: renders a receipt REBUILT FROM THE JOURNAL",
        r.json.code === 0 && /C O M P T O I R/.test(r.json.data.text) &&
        /2 x Espresso/.test(r.json.data.text), JSON.stringify(r.json.data).slice(0, 140));
    check("...having called back into a Ring service by name",
        /tickets ouverts: 1/.test(r.json.data.text));
    check("...and reports it unpaid", r.json.data.paid === false);

    // ================================== 5. contracts, before any action
    r = await call("orders", "place", { lignes: [] });
    check("contract: a missing required field is 422 at the door",
        r.status === 422 && /client/.test(r.json.message), r.json.message);

    // ======================================== 6. the actor seam, 401/403
    r = await call("orders", "cancel", { ticket: 1, motif: "erreur de saisie" });
    check("actor: an auth action without a token is 401, not 404",
        r.status === 401 && /authentication required/.test(r.json.message), r.json.message);

    r = await call("orders", "cancel", { ticket: 1, motif: "erreur de saisie" },
        jwt({ sub: "chef", exp: Math.floor(Date.now() / 1000) + 300 }));
    check("actor: a verified caller may cancel", r.json.code === 0, JSON.stringify(r.json));

    // A cancellation is an EVENT, not a deletion — the difference that
    // makes the record a journal rather than a table.
    r = await call("kitchen", "queue", {});
    check("a cancelled ticket leaves the queue", r.json.data.waiting === 0,
        JSON.stringify(r.json.data));
    r = await call("journal", "read", { limit: 50 });
    const types = r.json.data.records.map(x => x.event.type);
    check("...but stays in the journal, with its reason",
        types.join(",") === "commander,avancer,annuler" &&
        r.json.data.records[2].event.motif === "erreur de saisie", types.join(","));

    // ============================================ 7. the journal itself
    r = await call("journal", "verify", {});
    check("journal: the chain verifies INTACTE",
        r.json.data.chain === "INTACTE" && r.json.data.events === 3,
        JSON.stringify(r.json.data));
    r = await call("journal", "append", { type: "x" });
    check("journal: the service exposes NO append action",
        r.json.code === 1 && /unknown action/.test(r.json.message), r.json.message);

    // ================================================ 8. the sync layer
    let s = await get("/sync/shape?shape=menu&offset=0&limit=50");
    check("sync: the synced table's shape log carries its writes",
        s.json.code === 0 && s.json.data.ops.length >= 3,
        JSON.stringify(s.json.data).slice(0, 120));
    check("...insert before update, in order",
        s.json.data.ops.map(o => o.op).join(",").startsWith("insert,insert,update"),
        s.json.data.ops.map(o => o.op).join(","));
    s = await get("/sync/shape?shape=takings&offset=0&limit=5");
    check("sync: a table NOT declared :store = :local is not a shape",
        s.json.code !== 0, JSON.stringify(s.json).slice(0, 120));

    // ================================================== 9. placement
    s = await get("/topology");
    const svc = Object.fromEntries(s.json.data.services.map(x => [x.name, x]));
    check("placement: the whole seam is published",
        Object.keys(svc).length === 6, Object.keys(svc).join(","));
    check("placement: :menu is :local with server authority, so it answers here",
        svc.menu.site === "local" && svc.menu.authority === "server" &&
        svc.menu.answerable === 1, JSON.stringify(svc.menu));
    check("placement: the fiscal services are :server",
        svc.orders.site === "server" && svc.journal.site === "server");

    // ============================================= 10. the static page
    s = await get("/");
    check("the counter page is served at /", s.status === 200 && /Comptoir/.test(s.text || ""),
        String(s.status));

    // ======================== 11. replay is the only recovery, restart
    const before = (await call("orders", "state", {})).json.data;
    await stop();
    check("the application comes back on the same database",
        (start(), await waitUp(8110)));
    const after = (await call("orders", "state", {})).json.data;
    check("state is rebuilt by REPLAY alone, identical",
        JSON.stringify(before) === JSON.stringify(after),
        JSON.stringify(before) + " vs " + JSON.stringify(after));
    check("...and the chain is still INTACTE after a restart",
        (await call("journal", "verify", {})).json.data.chain === "INTACTE");

    // The derived takings table survived because it is a TABLE; the
    // ticket state survived because it was REPLAYED. Two stores, two
    // recoveries, one application — which is the point of §1 of
    // docs/COMMONS.md and the reason this app has both.
    r = await call("menu", "list", {});
    check("the mutable store persisted as rows, not as history",
        r.json.data.rows.length === 2);

    await stop();

    // =================================== 12. the form with no declaration
    const ex = spawnSync(RINGSERV, ["serve", "--explain", TIP], { encoding: "utf8" });
    const exOut = (ex.stdout || "") + (ex.stderr || "");
    check("gesture: the tool beside the app explains itself",
        ex.status === 0 && /tip\.split\(total, people\)/.test(exOut), exOut.slice(0, 160));
    check("gesture: its private function stays private",
        /private/.test(exOut) && /_internal/.test(exOut));

    server = spawn(RINGSERV, ["serve", "--port", "8111", TIP],
        { stdio: ["ignore", "ignore", "pipe"] });
    check("gesture: it serves with no declaration at all", await waitUp(8111));
    const tr = await (await fetch("http://127.0.0.1:8111/api/v1", {
        method: "POST",
        body: JSON.stringify({ service: "tip", action: "split", payload: { total: 580, people: 3 } }),
    })).json();
    check("gesture: and answers, payload mapped by name",
        tr.code === 0 && tr.data.each === 194 && tr.data.rounded_up_by === 2,
        JSON.stringify(tr));
    await stop();

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("comptoir-gates: " + (e && e.stack || e));
    await stop();
    process.exit(2);
});
