/*
** Phase-6 gates, part 1: placement.
**
** Three claims are under test, and each one is a promise this project
** makes in prose somewhere:
**
**   THE TOPOLOGY IS PUBLISHED. A page cannot compile `serv.call` into a
**   local dispatch or a fetch unless the server will tell it which is
**   which. GET /topology is that answer.
**
**   THE TOPOLOGY IS ENFORCED. A deployment declaration the runtime does
**   not hold to is a comment. A :local service with no server authority
**   must be refused over the wire — and a :local service WITH one must
**   be answered, because that is the whole difference between the two.
**
**   THE MOVE IS ONE WORD. docs/topology.md says moving a service between
**   :local and :server "is a one-word deployment decision, not a
**   refactor". The same suite runs against both configurations of the
**   same fixture, and identical results are the gate.
**
** Plus the manifest: emitted for an app inside a Zing solution, refused
** for a standalone one, and merged rather than overwritten — the ratified
** jurisdiction sentence, executable.
**
**   node tests/topology-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

/** The codes in a `check --json` report.
 *
 * C2 v1.1 puts the diagnostics inside a report object rather than a
 * top-level array — Ring's own jsonlib misreads a bare array, so the
 * outer object is the contract's, not a preference. The array form is
 * still accepted here so this helper reads either. */
function codesOf(stdout) {
    const parsed = JSON.parse(stdout);
    const list = Array.isArray(parsed) ? parsed : parsed.diagnostics;
    return (list || []).map(x => x.code);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-topo-"));

function startServer(fixture, port, env) {
    const srv = spawn(RINGSERV, ["run", path.join(ROOT, "tests", "fixtures", fixture)], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, ...env },
    });
    return srv;
}

async function waitUp(port) {
    const t0 = Date.now();
    while (Date.now() - t0 < 25000) {
        try {
            if ((await fetch(`http://127.0.0.1:${port}/health`)).status === 200) return true;
        } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}

async function call(port, service, action, payload) {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1`, {
        method: "POST",
        body: JSON.stringify({ service, action, payload }),
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}

/** Write a variant of a fixture into tmp, with substitutions applied. */
function variant(name, fixture, subs) {
    const dir = path.join(tmp, name);
    fs.mkdirSync(dir, { recursive: true });
    let src = fs.readFileSync(path.join(ROOT, "tests", "fixtures", fixture), "utf8");
    for (const [from, to] of subs) src = src.replace(from, to);
    const file = path.join(dir, "app.ring");
    fs.writeFileSync(file, src);
    return { dir, file };
}

(async () => {
    // ============================================ 1. published and enforced
    const PORT = 8097;
    const srv = startServer("topo-app.ring", PORT, { RINGSERV_TEST_DB: ":memory:" });
    try {
        check("the placement fixture comes up", await waitUp(PORT));

        const topo = await (await fetch(`http://127.0.0.1:${PORT}/topology`)).json();
        check("GET /topology answers an envelope", topo.code === 0, JSON.stringify(topo).slice(0, 200));
        const d = topo.data || {};
        check("...declaring itself declared", d.declared === 1);
        check("...naming the app", d.app === "topo-fixture", d.app);

        const by = {};
        for (const s of d.services || []) by[s.name] = s;
        check("a :server service is published answerable",
            by.report && by.report.site === "server" && by.report.answerable === 1,
            JSON.stringify(by.report));
        check("a :local service with no authority is published NOT answerable",
            by.draft && by.draft.site === "local" && by.draft.answerable === 0,
            JSON.stringify(by.draft));
        check("a :local service WITH :authority = :server is published answerable",
            by.notes && by.notes.site === "local" &&
            by.notes.authority === "server" && by.notes.answerable === 1,
            JSON.stringify(by.notes));
        check("an unplaced service is absent from the map, not invented",
            by.hello === undefined, JSON.stringify(by.hello));

        // The data half is published too — a page needs to know which
        // tables it may hold locally before it holds any.
        const dat = (d.data || []).find(x => x.name === "notes");
        check("synced data is published with its store and mode",
            dat && dat.store === "local" && dat.sync === "live", JSON.stringify(dat));

        // --- enforcement, which is the half that can actually be wrong
        let r = await call(PORT, "report", "build", {});
        check("a :server service is answered", r.status === 200 && r.json.code === 0,
            r.status + " " + JSON.stringify(r.json));

        r = await call(PORT, "draft", "preview", {});
        check("a :local service with no authority is REFUSED over the wire",
            r.status === 501, r.status + " " + JSON.stringify(r.json));
        check("...and the refusal says where to call it instead",
            r.json && /in the page/.test(r.json.message), r.json && r.json.message);
        check("...and offers the fix, not just the complaint",
            r.json && /:authority = :server/.test(r.json.message), r.json && r.json.message);

        r = await call(PORT, "notes", "create", { title: "t", body: "b", weight: 1 });
        check("a :local service WITH authority IS answered — the server decides",
            r.status === 200 && r.json.code === 0, r.status + " " + JSON.stringify(r.json));

        r = await call(PORT, "hello", "greet", {});
        check("an unplaced service still answers — silence is not a refusal",
            r.status === 200 && r.json.code === 0, r.status + " " + JSON.stringify(r.json));

        // A refusal must not be mistakable for a missing service: the
        // codes differ, and so does the reason.
        r = await call(PORT, "nosuchservice", "x", {});
        check("an unknown service is still 404, not 501",
            r.status === 404, r.status + "");
    } finally {
        srv.kill();
        await new Promise(r => setTimeout(r, 600));
    }

    // ================================================ 2. the move is one word
    //
    // Same fixture, same tests, one word of topology different. Results
    // are compared as data, so a difference cannot hide in phrasing.
    const results = {};
    for (const site of ["server", "local"]) {
        const db = path.join(tmp, `move-${site}.db`).replace(/\\/g, "/");
        const s = startServer("move-app.ring", 8094, {
            RINGSERV_TEST_DB: db,
            RINGSERV_TEST_SITE: site,
        });
        try {
            if (!(await waitUp(8094))) { check(`move fixture (:${site}) comes up`, false); continue; }
            check(`move fixture (:${site}) comes up`, true);

            const seen = [];
            let c = await call(8094, "notes", "create", { title: "a", body: "b", weight: 7 });
            seen.push([c.status, c.json.code]);
            const id = c.json.data.id;
            let g = await call(8094, "notes", "get", { id });
            seen.push([g.status, g.json.code, g.json.data.title, g.json.data.weight]);
            let u = await call(8094, "notes", "update", { id, title: "a2" });
            seen.push([u.status, u.json.code]);
            let l = await call(8094, "notes", "list", {});
            seen.push([l.status, l.json.code, l.json.data.count]);
            let t = await call(8094, "sum", "total", {});
            seen.push([t.status, t.json.code, t.json.data.n]);
            let del = await call(8094, "notes", "delete", { id });
            seen.push([del.status, del.json.code]);
            // A contract violation must fail the same way on both sides —
            // this is where a "local" service that quietly skipped
            // validation would show up.
            let bad = await call(8094, "notes", "create", { title: 42 });
            seen.push([bad.status, bad.json.code]);

            results[site] = seen;
        } finally {
            s.kill();
            await new Promise(r => setTimeout(r, 600));
        }
    }
    check("the :server and :local+:authority configurations agree exactly",
        JSON.stringify(results.server) === JSON.stringify(results.local),
        "server=" + JSON.stringify(results.server) + "  local=" + JSON.stringify(results.local));
    check("...and both actually did work, rather than both failing identically",
        Array.isArray(results.server) && results.server[0] &&
        results.server[0][0] === 200, JSON.stringify(results.server));

    // ==================================================== 3. the manifest
    //
    // The ratified jurisdiction sentence, executable: inside a Zing
    // solution the manifest is a MUST; a standalone RingServ app owes
    // none and must not be given one.
    {
        const v = variant("standalone", "topo-app.ring", []);
        const r = spawnSync(RINGSERV, ["topology", v.file, "--emit"], { encoding: "utf8", cwd: v.dir });
        check("a standalone app is told it owes no manifest",
            /owes no manifest/.test(r.stdout), r.stdout.slice(0, 200));
        check("...and nothing is written",
            !fs.existsSync(path.join(v.dir, "zing.json")));
        check("...and that is not an error — declaring membership you do not have is worse",
            r.status === 0, "exit " + r.status);
    }
    {
        const v = variant("insolution", "topo-app.ring",
            [[':app = "topo-fixture",', ':app = "topo-fixture",\n\t:solution = "fieldwork",']]);
        let r = spawnSync(RINGSERV, ["topology", v.file], { encoding: "utf8", cwd: v.dir });
        check("an app in a solution prints what --emit would write",
            /placement \(what --emit would write/.test(r.stdout), r.stdout.slice(0, 200));
        check("...and printing writes nothing",
            !fs.existsSync(path.join(v.dir, "zing.json")));

        r = spawnSync(RINGSERV, ["topology", v.file, "--emit"], { encoding: "utf8", cwd: v.dir });
        check("--emit writes zing.json", fs.existsSync(path.join(v.dir, "zing.json")), r.stdout);
        const m = JSON.parse(fs.readFileSync(path.join(v.dir, "zing.json"), "utf8"));
        check("the manifest carries the contract's placement shape",
            m.placement && m.placement.services && m.placement.data,
            JSON.stringify(m).slice(0, 200));
        check("...with site and authority as SEPARATE fields, per C3",
            m.placement.services.notes.site === "local" &&
            m.placement.services.notes.authority === "server",
            JSON.stringify(m.placement.services.notes));
        check("...and no :both anywhere in it",
            !/"both"/.test(JSON.stringify(m)));
        check("...and data keeps store and sync, not a site",
            m.placement.data.notes.store === "local" &&
            m.placement.data.notes.sync === "live" &&
            m.placement.data.notes.site === undefined,
            JSON.stringify(m.placement.data.notes));

        // The merge: RingServ owns `placement` and nothing else. A build
        // step that renames a solution or drops its governance has turned
        // a merge into a loss.
        fs.writeFileSync(path.join(v.dir, "zing.json"), JSON.stringify({
            solution: "named-by-zing",
            version: "0.3.0",
            governance: { roles: ["operator"] },
            targets: { portal: { platform: "web" } },
            placement: { services: { stale: { site: "device" } } },
        }, null, 2));
        r = spawnSync(RINGSERV, ["topology", v.file, "--emit"], { encoding: "utf8", cwd: v.dir });
        const m2 = JSON.parse(fs.readFileSync(path.join(v.dir, "zing.json"), "utf8"));
        check("a second emit UPDATES rather than replaces", /updated/.test(r.stdout), r.stdout);
        check("...Zing's own sections survive untouched",
            m2.version === "0.3.0" && m2.governance.roles[0] === "operator" &&
            m2.targets.portal.platform === "web", JSON.stringify(m2).slice(0, 200));
        check("...the solution name is NOT overwritten by the server's idea of it",
            m2.solution === "named-by-zing", m2.solution);
        check("...and the stale placement is gone, because placement IS ours",
            m2.placement.services.stale === undefined &&
            m2.placement.services.notes !== undefined,
            JSON.stringify(m2.placement.services));

        // A manifest that is not JSON must never be clobbered.
        fs.writeFileSync(path.join(v.dir, "zing.json"), "{ not json at all");
        r = spawnSync(RINGSERV, ["topology", v.file, "--emit"], { encoding: "utf8", cwd: v.dir });
        check("an unparseable manifest is refused, not overwritten",
            r.status !== 0 && /refusing to overwrite/.test(r.stdout + r.stderr),
            r.stdout + r.stderr);
        check("...and its bytes are still there",
            fs.readFileSync(path.join(v.dir, "zing.json"), "utf8") === "{ not json at all");
    }

    // ==================================== 4. check sees placement defects
    {
        const v = variant("defects", "topo-app.ring", [
            [":report = [ :site = :server ],", ":report = [ :site = :orbit ],\n\t\t:ghost  = [ :site = :server ],"],
            [":notes = [ :store = :local, :sync = :live ]", ":notes = [ :store = :server, :sync = :live ]"],
            [":draft  = [ :site = :local ],", ":draft  = [ :site = :local, :authority = :device ],"],
        ]);
        const r = spawnSync(RINGSERV, ["check", v.file, "--json"], { encoding: "utf8", cwd: v.dir });
        let found = [];
        try { found = codesOf(r.stdout); } catch {}
        for (const code of [
            "RS_TOPOLOGY_UNKNOWN_SITE",
            "RS_TOPOLOGY_UNKNOWN_SERVICE",
            "RS_TOPOLOGY_SYNC_WITHOUT_LOCAL",
            "RS_TOPOLOGY_AUTHORITY_NOT_SERVER",
        ]) {
            check(`check reports ${code}`, found.includes(code), found.join(","));
        }
        check("...and a placement defect FAILS the command", r.status !== 0, "exit " + r.status);

        // The clean fixture must stay silent about placement, or the
        // reports above prove nothing.
        const clean = variant("clean", "topo-app.ring", []);
        const rc = spawnSync(RINGSERV, ["check", clean.file, "--json"], { encoding: "utf8", cwd: clean.dir });
        let cleanCodes = [];
        try { cleanCodes = codesOf(rc.stdout); } catch {}
        check("a correct topology produces no placement findings",
            !cleanCodes.some(c => c.startsWith("RS_TOPOLOGY_")), cleanCodes.join(","));
    }

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})();
