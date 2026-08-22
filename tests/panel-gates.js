/*
** Panel gates: the admin panel is an operations surface, so every gate
** here is about TRUTH — what the panel reports must be what is actually
** happening in the processes it manages:
**
**   the scan finds both shapes (an app.ring subdirectory, a bare gesture
**   file) and reads their ports from the same files the apps read;
**
**   start actually starts (the app's own port answers), stop actually
**   stops (the port refuses), and status follows the PROCESS, not the
**   button — an app killed behind the panel's back must be reported
**   stopped without any operator action;
**
**   the call proxy speaks to the app's real /api/v1 and returns the
**   app's own envelope, byte for byte;
**
**   logs are the child's real output; shutdown leaves no orphans.
**
**   node tests/panel-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const P = "http://127.0.0.1:8078";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function get(url) { return (await fetch(P + url)).text(); }
async function post(url, body) {
    const res = await fetch(P + url, { method: "POST", body: JSON.stringify(body) });
    return { status: res.status, text: await res.text() };
}
async function state() { return JSON.parse(await get("/panel/state")); }
async function appOf(name) { return (await state()).apps.find(a => a.name === name); }

async function portAnswers(port) {
    try { return (await fetch(`http://127.0.0.1:${port}/health`)).status === 200; }
    catch { return false; }
}
async function until(fn, ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < (ms || 20000)) {
        if (await fn()) return true;
        await new Promise(r => setTimeout(r, 200));
    }
    return false;
}

// ------------------------------------------- a fresh hosting directory
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-panel-"));
fs.writeFileSync(path.join(tmp, "calc.ring"), [
    "func add a, b",
    "\treturn a + b",
    "",
].join("\n"));
fs.writeFileSync(path.join(tmp, "ringserv.yaml"), "port: 8071\n");
fs.mkdirSync(path.join(tmp, "notes"));
const db = path.join(tmp, "notes.db").replace(/\\/g, "/");
fs.writeFileSync(path.join(tmp, "notes", "app.ring"), [
    "RingServ([",
    "\t:port = 8072,",
    `\t:database = "${db}",`,
    "\t:services = [ :notes = [ :table = \"notes\" ] ],",
    "\t:data = [ :notes = [ :title = :string ] ]",
    "])",
    "",
].join("\n"));

let panel = null;
(async () => {
    panel = spawn(RINGSERV, ["panel", tmp, "--port", "8078"],
        { stdio: ["ignore", "pipe", "pipe"] });
    check("the panel comes up", await until(async () => {
        try { return (await fetch(P + "/health")).status === 200; } catch { return false; }
    }));

    // ================================================== 1. the scan
    let st = await state();
    check("the scan finds both shapes", st.apps.length === 2,
        JSON.stringify(st.apps.map(a => a.name)));
    const calc = st.apps.find(a => a.name === "calc");
    const notes = st.apps.find(a => a.name === "notes");
    check("the gesture file is mode `serve`, its port from ringserv.yaml",
        calc && calc.mode === "serve" && calc.port === 8071, JSON.stringify(calc));
    check("the app directory is mode `run`, its port from the declaration",
        notes && notes.mode === "run" && notes.port === 8072, JSON.stringify(notes));
    check("everything starts stopped", st.apps.every(a => a.status === "stopped"));

    // ============================================ 2. start is real
    let r = await post("/panel/start", { name: "calc" });
    check("start answers ok", /"ok":1/.test(r.text), r.text);
    check("...and the app's OWN port answers /health",
        await until(() => portAnswers(8071)));
    check("...and the panel reports running with a pid",
        await until(async () => {
            const a = await appOf("calc");
            return a.status === "running" && a.pid > 0;
        }));
    r = await post("/panel/start", { name: "calc" });
    check("starting a running app is refused, not doubled",
        r.status === 409, r.status + " " + r.text);

    // ============================================ 3. the call proxy
    await post("/panel/start", { name: "notes" });
    await until(() => portAnswers(8072));
    r = await post("/panel/call",
        { name: "calc", request: { service: "calc", action: "add", payload: { a: 19, b: 23 } } });
    check("the proxy returns the app's own envelope",
        r.text === '{"code":0,"message":"OK","data":42}', r.text);
    r = await post("/panel/call",
        { name: "notes", request: { service: "notes", action: "create", payload: { title: "from the gate" } } });
    check("...for the declarative app too", /"id":1/.test(r.text), r.text);

    // ================================================== 4. the logs
    const logs = await get("/panel/logs?app=calc");
    check("logs are the child's real output", /serving on/.test(logs),
        logs.split("\n")[0]);

    // ============================================= 5. stop is real
    r = await post("/panel/stop", { name: "calc" });
    check("stop answers ok", /"ok":1/.test(r.text), r.text);
    check("...the panel reports stopped",
        await until(async () => (await appOf("calc")).status === "stopped"));
    check("...and the app's port actually refuses",
        await until(async () => !(await portAnswers(8071))));
    r = await post("/panel/call",
        { name: "calc", request: { service: "calc", action: "add", payload: { a: 1, b: 1 } } });
    check("calling a stopped app is refused, with the reason",
        r.status === 409 && /not running/.test(r.text), r.text);

    // ============== 6. status follows the process, not the button
    const notesApp = await appOf("notes");
    process.kill(notesApp.pid);
    check("an app killed behind the panel's back is reported stopped",
        await until(async () => (await appOf("notes")).status === "stopped"),
        "status still " + JSON.stringify(await appOf("notes")));
    check("...and its log says the process ended",
        /process ended/.test(await get("/panel/logs?app=notes")));

    // =============================================== 7. refusals
    r = await post("/panel/start", { name: "ghost" });
    check("an unknown app is 404", r.status === 404, r.status + "");
    r = await post("/panel/start", {});
    check("a start without a name is 400", r.status === 400, r.status + "");

    // ================== 8. the server toggle — the panel stays resident
    r = await post("/panel/server/start", {});
    check("Start server starts every stopped app", /"ok":1/.test(r.text), r.text);
    check("...both ports answer", await until(async () =>
        (await portAnswers(8071)) && (await portAnswers(8072))));
    check("...and state counts them", await until(async () => (await state()).running === 2));
    r = await post("/panel/server/stop", {});
    check("Stop server stops every running app", /"ok":1/.test(r.text), r.text);
    check("...both ports refuse", await until(async () =>
        !(await portAnswers(8071)) && !(await portAnswers(8072))));
    check("...and THE PANEL ITSELF STAYS — stop is not a trap",
        (await fetch(P + "/health")).status === 200);
    check("...so it can start everything again", await (async () => {
        await post("/panel/server/start", {});
        return until(() => portAnswers(8071));
    })());
    await post("/panel/server/stop", {});
    await until(async () => (await state()).running === 0);

    // ========================================== 9. shutdown, clean
    await post("/panel/start", { name: "calc" });
    await until(() => portAnswers(8071));
    await post("/panel/shutdown", {});
    check("shutdown stops the panel itself",
        await until(async () => {
            try { await fetch(P + "/health"); return false; } catch { return true; }
        }));
    check("...and leaves no orphan on the app's port",
        await until(async () => !(await portAnswers(8071)), 8000));

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(e => {
    console.error("panel-gates: " + (e && e.stack || e));
    if (panel) panel.kill();
    process.exit(2);
});
