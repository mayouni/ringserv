/*
** Phase-7 gates, part 2: a JS service is just a service.
**
** The claim under test is a negative one, which is why it needs a gate:
** NOTHING around a service changes when its implementation is JS. The
** envelope, the contract, the placement, the status codes and the
** catalog all behave identically, and the strongest way to say that is
** not to assert each behaviour twice — it is to run the SAME assertions
** against a Ring service and a JS service and compare the two as data.
**
** The fixture therefore carries `greeter` (JS) and `ringgreeter` (Ring)
** answering the same shape, so a difference has nowhere to hide.
**
**   node tests/jsserv-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "js-app.ring");
const B = "http://127.0.0.1:8092";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function call(service, action, payload) {
    const res = await fetch(B + "/api/v1", {
        method: "POST",
        body: JSON.stringify({ service, action, payload }),
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}

async function waitUp() {
    const t0 = Date.now();
    while (Date.now() - t0 < 25000) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-jssvc-"));
const server = spawn(RINGSERV, ["run", FIXTURE], {
    stdio: ["ignore", "ignore", "pipe"],
    env: { ...process.env, RINGSERV_TEST_DB: path.join(tmp, "js.db").replace(/\\/g, "/") },
});
let died = false;
server.on("exit", () => { died = true; });

(async () => {
    check("an app with a JS service comes up", await waitUp());

    // =============================== 1. the two guests are indistinguishable
    for (const name of ["Ring", "world", "a-name"]) {
        const js = await call("greeter", "greet", { name });
        const rg = await call("ringgreeter", "greet", { name });
        check(`greet(${name}): the JS and Ring services answer identically`,
            js.status === rg.status &&
            JSON.stringify(js.json) === JSON.stringify(rg.json),
            "js=" + JSON.stringify(js.json) + " ring=" + JSON.stringify(rg.json));
    }
    {
        const js = await call("greeter", "greet", {});
        check("...including the default path with an empty payload",
            js.json.data.greeting === "Hello, world!", JSON.stringify(js.json));
    }

    // ============================================= 2. the service form itself
    let r = await call("greeter", "slow", { n: 21 });
    check("an async action answers with its value", r.json.data.n === 42,
        JSON.stringify(r.json));

    r = await call("greeter", "loud", { name: "js" });
    check("an action reaches a sibling through `this`",
        r.json.data.greeting === "HELLO, JS!", JSON.stringify(r.json));

    // Privacy by structure, not by naming convention: `shout` is a
    // top-level function in the same file and must be unreachable.
    r = await call("greeter", "shout", {});
    check("a private helper is NOT an action", r.status === 404,
        r.status + " " + JSON.stringify(r.json));

    r = await call("greeter", "nosuchaction", {});
    check("an unknown action is 404, the same as on the Ring side",
        r.status === 404, r.status + "");

    // ================================ 3. everything around it is unchanged
    r = await call("greeter", "refuse", {});
    check("business failure travels in the envelope, not the status",
        r.status === 200 && r.json.code === 1, r.status + " " + JSON.stringify(r.json));

    r = await call("greeter", "boom", {});
    check("a thrown JS error is a clean 500, not a dead worker",
        r.status === 500 && r.json.code === 1, r.status + " " + JSON.stringify(r.json));
    check("...carrying the JS line number", /line \d+:/.test(r.json.message),
        r.json.message);
    r = await call("greeter", "greet", { name: "after" });
    check("...and the worker still serves afterwards",
        r.status === 200 && r.json.code === 0, JSON.stringify(r.json));

    // The contract runs BEFORE dispatch, so the guest never sees a bad
    // payload — the same guarantee a Ring service gets, from the same code.
    r = await call("greeter", "greet", { name: "x".repeat(40) });
    check("a contract violation is a 422 before the guest runs",
        r.status === 422 && /at most 20/.test(r.json.message),
        r.status + " " + JSON.stringify(r.json));

    r = await call("greeter", "slow", {});
    check("a required field missing is a 422 too",
        r.status === 422, r.status + " " + JSON.stringify(r.json));

    // Placement governs a JS service exactly as it governs a Ring one.
    const topo = await (await fetch(B + "/topology")).json();
    const placed = (topo.data.services || []).find(s => s.name === "greeter");
    check("a JS service appears in the placement map",
        placed && placed.site === "server" && placed.answerable === 1,
        JSON.stringify(placed));

    // And a Ring service in the same app still works — two guests share
    // one worker, and neither breaks the other.
    r = await call("notes", "create", { title: "from ring", weight: 1 });
    check("a Ring data service still works beside the JS guest",
        r.status === 200 && r.json.data.id > 0, JSON.stringify(r.json));

    check("the server never died", !died);


    // ============================================ serv.call, by trampoline
    //
    // The claim: a JS service calling another service gets the SAME
    // dispatch a Ring service gets — contracts, placement, generic table
    // services and all — rather than a second, weaker path that would
    // drift from it. Every gate below is one way that could be false.

    r = await call("orchestra", "viaRing", { name: "Ring" });
    check("a JS service can call a RING service",
        r.json.data.inner === "Hello, Ring!", JSON.stringify(r.json));

    r = await call("orchestra", "viaJs", { name: "deep" });
    check("...and another JS service", r.json.data.inner === "Hello, deep!",
        JSON.stringify(r.json));

    r = await call("orchestra", "store", { title: "note-1", weight: 3 });
    check("...and a GENERIC TABLE service, so data arrives through the same seam",
        r.json.data.id > 0 && r.json.data.title === "note-1", JSON.stringify(r.json));

    r = await call("orchestra", "chain", { names: ["a", "b", "c"] });
    check("sequential calls each get their own trampoline round",
        JSON.stringify(r.json.data.greetings) ===
        JSON.stringify(["Hello, a!", "Hello, b!", "Hello, c!"]),
        JSON.stringify(r.json.data));

    r = await call("orchestra", "fanout", { names: ["x", "y", "z"] });
    check("Promise.all sends several calls in ONE round",
        r.json.data.n === 3 && r.json.data.first === "Hello, x!",
        JSON.stringify(r.json.data));

    // A refusal comes back as an ENVELOPE, exactly what an HTTP caller
    // sees. serv.call rejects only when dispatch itself raises; a contract
    // violation is a business outcome and travels in `code`.
    r = await call("orchestra", "refused", {});
    check("a contract violation crosses the seam as an envelope, not a throw",
        r.json.data.code === 1 && /at most 20/.test(r.json.data.why),
        JSON.stringify(r.json.data));

    r = await call("orchestra", "missing", {});
    check("calling an unknown service answers code 1, not undefined",
        r.json.data.code === 1, JSON.stringify(r.json.data));

    r = await call("orchestra", "badtarget", {});
    check("a malformed target is refused before it reaches the host",
        /service\.action/.test(r.json.data.caught), JSON.stringify(r.json.data));

    // The guest must not be able to hang a worker by calling itself.
    {
        const dir = path.join(tmp, "cycle");
        fs.mkdirSync(path.join(dir, "s"), { recursive: true });
        fs.writeFileSync(path.join(dir, "s", "loop.js"),
            "const service = { async go() { return await serv.call('loop.go', {}); } };\n");
        fs.writeFileSync(path.join(dir, "app.ring"),
            'RingServ([ :port = 8090, :services = [ :loop = [ :js = "s/loop.js" ] ] ])\n');
        const srv2 = spawn(RINGSERV, ["run", path.join(dir, "app.ring")],
            { stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, RINGSERV_TEST_DB: ":memory:" } });
        try {
            const t0 = Date.now();
            let up = false;
            while (Date.now() - t0 < 20000) {
                try { if ((await fetch("http://127.0.0.1:8090/health")).status === 200) { up = true; break; } } catch {}
                await new Promise(res => setTimeout(res, 150));
            }
            check("the cycle fixture comes up", up);
            const res = await fetch("http://127.0.0.1:8090/api/v1", {
                method: "POST",
                body: JSON.stringify({ service: "loop", action: "go", payload: {} }),
            });
            const body = await res.text();
            check("a service that calls ITSELF is stopped, not left to hang",
                /cycle|nested/.test(body), body.slice(0, 200));
        } finally {
            srv2.kill();
            await new Promise(res => setTimeout(res, 600));
        }
    }

    // ==================================== 4. the catalog asks the guest
    const docs = spawnSync(RINGSERV, ["docs", FIXTURE, "--json"], { encoding: "utf8" });
    let cat = null;
    try { cat = JSON.parse(docs.stdout); } catch {}
    const svc = cat && (cat.services || []).find(s => s.name === "greeter");
    check("`docs` sees the JS service", !!svc, docs.stdout.slice(0, 200));
    check("...with the actions the GUEST reports, not a parse of the file",
        svc && ["greet", "slow", "loud", "refuse", "boom"].every(a => svc.actions.includes(a)),
        JSON.stringify(svc && svc.actions));
    check("...and not the private helper",
        svc && !svc.actions.includes("shout"), JSON.stringify(svc && svc.actions));

    // A missing file must fail the REQUEST with a usable message, not the
    // boot — `dev` reloads on save, and a half-written tree is normal.
    {
        const dir = path.join(tmp, "missing");
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, "app.ring"),
            'RingServ([ :port = 8091, :services = [ :ghost = [ :js = "nope.js" ] ] ])\n');
        const rr = spawnSync(RINGSERV, ["check", path.join(dir, "app.ring")], { encoding: "utf8" });
        check("a :js file that does not exist is reported, not crashed into",
            /does not exist|can never answer|nope\.js/.test(rr.stdout + rr.stderr),
            (rr.stdout + rr.stderr).slice(0, 200));
    }

    // A .js file with no `service` object is a diagnostic, not a mystery.
    {
        const dir = path.join(tmp, "noservice");
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, "bad.js"), "const notService = { a(){ return 1; } };\n");
        fs.writeFileSync(path.join(dir, "app.ring"),
            'RingServ([ :port = 8091, :services = [ :bad = [ :js = "bad.js" ] ] ])\n');
        const rr = spawnSync(RINGSERV, ["docs", path.join(dir, "app.ring"), "--json"],
            { encoding: "utf8" });
        check("a .js file that declares no `service` object does not crash the catalog",
            rr.status === 0, (rr.stdout + rr.stderr).slice(0, 200));
    }

    // ==================================== phase 11: the ES module story
    //
    // Ring walks the import graph and stages every file; the guest can
    // only import what was staged — the no-filesystem property survives
    // the module story instead of being weakened by it.
    {
        const modApp = path.join(ROOT, "tests", "fixtures", "jsmod", "app.ring");
        const srv = spawn(RINGSERV, ["run", modApp], { stdio: ["ignore", "ignore", "pipe"] });
        let up = false;
        for (let i = 0; i < 100; i++) {
            try { if ((await fetch("http://127.0.0.1:8118/health")).status === 200) { up = true; break; } } catch {}
            await new Promise(r => setTimeout(r, 150));
        }
        check("a module-form service (export const service) comes up", up);
        const res = await (await fetch("http://127.0.0.1:8118/api/v1", {
            method: "POST",
            body: JSON.stringify({ service: "shop", action: "price",
                payload: { qty: 3, unit: 180 } }),
        })).json();
        check("its import graph linked — a diamond, sibling-relative paths",
            res.code === 0 && res.data.total === 594, JSON.stringify(res));
        // The space before the euro sign is U+00A0 — real fr-FR
        // formatting uses a no-break space, and so does ours.
        check("Intl works inside a module", res.data.formatted === "5,94 €",
            JSON.stringify(res.data.formatted));
        check("a re-exported const crossed the graph", res.data.rate === 0.1);
        check("false and null still survive to the wire from a module",
            res.data.paid === false && res.data.ref === null, JSON.stringify(res.data));
        srv.kill();
        await new Promise(r => setTimeout(r, 700));
    }

    // The three refusals, each named. Boot-time for static imports;
    // call-time for dynamic ones the walk could never see.
    for (const [label, source, want] of [
        ["an npm bare specifier is refused, naming the boundary",
            'import _ from "lodash";\nexport const service = { async go(p){ return {code:0,message:"OK",data:1}; } };\n',
            /npm packages are not available/],
        ["an import that escapes the application is refused, naming the rule",
            'import { x } from "../../outside.js";\nexport const service = { async go(p){ return {code:0,message:"OK",data:1}; } };\n',
            /escapes the application/],
        ["a missing module is reported by its resolved name",
            'import { x } from "./ghost.js";\nexport const service = { async go(p){ return {code:0,message:"OK",data:1}; } };\n',
            /ghost\.js.*does not exist/],
        ["a dynamic import of an undeclared file is refused at call time",
            'export const service = { async go(p){ await import("./late.js"); return {code:0,message:"OK",data:1}; } };\n',
            /not one of this application's loaded modules/],
        ["a module that exports no `service` says what one looks like",
            'export const other = 1;\n',
            /exports no `service`/],
    ]) {
        const dir = path.join(tmp, "mod-" + label.slice(0, 12).replace(/\W/g, ""));
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, "svc.js"), source);
        fs.writeFileSync(path.join(dir, "app.ring"),
            'RingServ([ :port = 8117, :services = [ :m = [ :js = "svc.js" ] ] ])\n');
        const srv = spawn(RINGSERV, ["run", path.join(dir, "app.ring")],
            { stdio: ["ignore", "ignore", "pipe"] });
        for (let i = 0; i < 100; i++) {
            try { if ((await fetch("http://127.0.0.1:8117/health")).status === 200) break; } catch {}
            await new Promise(r => setTimeout(r, 150));
        }
        const res = await (await fetch("http://127.0.0.1:8117/api/v1", {
            method: "POST",
            body: JSON.stringify({ service: "m", action: "go", payload: {} }),
        })).json();
        check(label, res.code === 1 && want.test(res.message),
            JSON.stringify(res).slice(0, 180));
        srv.kill();
        await new Promise(r => setTimeout(r, 700));
    }
})().catch(e => {
    check("the suite ran to completion", false, e.stack || String(e));
}).finally(async () => {
    server.kill();
    await new Promise(r => setTimeout(r, 700));
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
});
