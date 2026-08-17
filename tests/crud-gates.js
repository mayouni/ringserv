/*
** Phase-3 part-2 gates: generic table services and contract validation.
**
** Usage: node tests/crud-gates.js
*/
const { spawn } = require("child_process");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(__dirname, "fixtures", "crud-app.ring");
const BASE = "http://127.0.0.1:8095";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function call(service, action, payload) {
    const res = await fetch(BASE + "/api/v1", {
        method: "POST",
        body: JSON.stringify({ service, action, payload: payload || {} }),
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch {}
    return { status: res.status, text, json };
}

(async () => {
    const server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: ":memory:" },
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
        check("server comes up", up);

        // ---------------------------------------------- generic CRUD
        let r = await call("notes", "create", { title: "first", weight: 5, body: "hello" });
        check("generic create returns an id", r.status === 200 && r.json.code === 0 &&
            typeof r.json.data.id === "number", r.text);
        const id = r.json && r.json.data ? r.json.data.id : 0;

        r = await call("notes", "get", { id });
        check("generic get returns the row as an object", r.status === 200 &&
            r.json.data.title === "first" && r.json.data.weight === 5, r.text);

        r = await call("notes", "update", { id, title: "renamed" });
        check("generic update reports the change", r.status === 200 &&
            r.json.data.changed === 1, r.text);

        r = await call("notes", "get", { id });
        check("update persisted", r.json && r.json.data.title === "renamed", r.text);

        await call("notes", "create", { title: "second", weight: 10 });
        await call("notes", "create", { title: "third", weight: 15 });
        r = await call("notes", "list", {});
        check("generic list returns all rows", r.status === 200 &&
            r.json.data.count === 3 && Array.isArray(r.json.data.rows), r.text);

        r = await call("notes", "list", { limit: 2 });
        check("list honors limit", r.json && r.json.data.count === 2, r.text);
        r = await call("notes", "list", { limit: 2, offset: 2 });
        check("list honors offset", r.json && r.json.data.count === 1, r.text);

        r = await call("notes", "list", { filter: { weight: 10 } });
        check("list honors equality filters", r.json && r.json.data.count === 1 &&
            r.json.data.rows[0].title === "second", r.text);

        r = await call("notes", "list", { filter: { nosuchcolumn: 1 } });
        check("unknown filter column is dropped, not injected",
            r.status === 200 && r.json.data.count === 3, r.text);

        r = await call("notes", "delete", { id });
        check("generic delete works", r.status === 200 && r.json.data.deleted === 1, r.text);
        r = await call("notes", "get", { id });
        check("deleted row is gone (404)", r.status === 404, r.text);

        r = await call("notes", "update", { id: 9999, title: "ghost" });
        check("update of a missing row is 404", r.status === 404, r.text);
        r = await call("notes", "delete", { id: 9999 });
        check("delete of a missing row is 404", r.status === 404, r.text);

        // ------------------------------------- restriction and override
        r = await call("tags", "create", { label: "ring" });
        check("explicit action overrides the generic one", r.status === 200 &&
            r.json.data.shouted === 1, r.text);
        r = await call("tags", "list", {});
        check("override actually ran (label upper-cased)", r.json &&
            r.json.data.rows[0].label === "RING", r.text);
        r = await call("tags", "delete", { id: 1 });
        check("actions not in :actions are unreachable (404)", r.status === 404, r.text);

        // ------------------------------------------------- contracts
        r = await call("notes", "create", { weight: 5 });
        check("missing required field is 422", r.status === 422 &&
            /title is required/.test(r.json.message), r.text);

        r = await call("notes", "create", { title: 12345 });
        check("wrong type is 422", r.status === 422 &&
            /title must be a string/.test(r.json.message), r.text);

        r = await call("notes", "create", { title: "x".repeat(50) });
        check("maxlen violation is 422", r.status === 422 &&
            /at most 20 characters/.test(r.json.message), r.text);

        r = await call("notes", "create", { title: "ok", weight: 500 });
        check("numeric max violation is 422", r.status === 422 &&
            /at most 100/.test(r.json.message), r.text);

        r = await call("notes", "create", { weight: -5 });
        check("all violations are reported at once", r.status === 422 &&
            /title is required/.test(r.json.message) &&
            /at least 0/.test(r.json.message), r.text);

        r = await call("notes", "get", { id: "not-a-number" });
        check("contract governs generic actions too", r.status === 422, r.text);

        r = await call("notes", "create", { title: "valid", weight: 1 });
        check("a valid payload passes the contract", r.status === 200 &&
            r.json.code === 0, r.text);

        // ------------------------- the rules that shipped without gates
        // :of, :int, :bool, :minlen were implemented and never exercised.
        r = await call("rules", "check", { scores: [1, 2, 3] });
        check(":of accepts a list of the right element type", r.status === 200, r.text);
        r = await call("rules", "check", { scores: [1, "two", 3] });
        check(":of rejects a wrong element type", r.status === 422 &&
            /scores item must be a number/.test(r.json.message), r.text);

        r = await call("rules", "check", { count: 7 });
        check(":int accepts a whole number", r.status === 200, r.text);
        r = await call("rules", "check", { count: 7.5 });
        check(":int rejects a fraction", r.status === 422 &&
            /count must be a whole number/.test(r.json.message), r.text);

        r = await call("rules", "check", { flag: 1 });
        check(":bool accepts 1", r.status === 200, r.text);
        r = await call("rules", "check", { flag: 0 });
        check(":bool accepts 0", r.status === 200, r.text);
        r = await call("rules", "check", { flag: 5 });
        check(":bool rejects other numbers", r.status === 422 &&
            /flag must be true or false/.test(r.json.message), r.text);

        r = await call("rules", "check", { code: "abc" });
        check(":minlen accepts a long-enough string", r.status === 200, r.text);
        r = await call("rules", "check", { code: "ab" });
        check(":minlen rejects a short string", r.status === 422 &&
            /at least 3 characters/.test(r.json.message), r.text);

        r = await call("rules", "check", { tags: ["a", "b"] });
        check(":min/:max measure list LENGTH, not value", r.status === 200, r.text);
        r = await call("rules", "check", { tags: [] });
        check("an empty list violates :min", r.status === 422, r.text);
        r = await call("rules", "check", { tags: ["a", "b", "c", "d"] });
        check("an over-long list violates :max", r.status === 422, r.text);

        r = await call("rules", "check", {});
        check("nothing is required, so an empty payload passes",
            r.status === 200, r.text);

        // ------------------- the hazard the single writer connection made
        // Writes share ONE connection now, so sqlite3_last_insert_rowid is
        // a property of that connection rather than of the caller: two
        // workers inserting at once would each read whichever insert landed
        // last, and a client would be handed somebody else's id. db.zig
        // captures the rowid under the same lock that did the insert; this
        // is the gate that proves it.
        const conc = await Promise.all(
            Array.from({ length: 60 }, (_, i) => call("notes", "create", { title: "conc" + i })));
        const ids = conc.map(x => x.json && x.json.data && x.json.data.id);
        check("60 concurrent creates all succeed",
            conc.every(x => x.status === 200 && x.json.code === 0));
        check("...and every returned id is distinct",
            new Set(ids).size === 60, "got " + new Set(ids).size + " distinct of 60");
        check("...and each id names the row it created",
            (await Promise.all(conc.map((x, i) =>
                call("notes", "get", { id: x.json.data.id })
                    .then(g => g.json && g.json.data && g.json.data.title === "conc" + i))))
                .every(Boolean));

        // Writes go through a different connection than reads now, so a
        // reader must still see a write the instant it commits.
        const w = await call("notes", "create", { title: "visible-immediately" });
        const back = await call("notes", "get", { id: w.json.data.id });
        check("a write is visible to a reader connection at once",
            back.status === 200 && back.json.data.title === "visible-immediately", back.text);

        check("server never died", !died);
    } finally {
        server.kill();
    }
    console.log(failed === 0
        ? "\nAll " + passed + " CRUD/contract gates passed."
        : "\n" + failed + " gate(s) FAILED (" + passed + " passed).");
    process.exit(failed ? 1 : 0);
})().catch(e => { console.error("harness crashed:", e); process.exit(1); });
