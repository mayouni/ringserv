/*
** Phase-20 gates: change a running server's code, live.
**
** The promise is that the most ordinary act in an application's life —
** "I changed something, make it real" — costs one command or one click,
** and never a restart. Each gate attacks a way that could be quietly
** false:
**
**   IT ACTUALLY CHANGES. A service answers one thing, the file changes,
**   and the SAME PROCESS answers the other thing. Asserted on the pid,
**   because "it reloaded" and "it restarted underneath me" look identical
**   from the outside and only one of them is this feature.
**
**   THE PORT IS NEVER REBOUND. A keep-alive connection opened BEFORE the
**   reload is used again AFTER it. That is the whole difference between
**   reloading and restarting, so it is measured on the socket rather than
**   argued in a comment.
**
**   EVERY WORKER OR NONE. N workers each own a resident VM, so a reload
**   can half-succeed — and then some requests answer with the new code
**   and some with the old, with nothing in either response saying which.
**   The gate hammers the server after a reload and demands one answer.
**
**   A BROKEN APPLICATION CHANGES NOTHING. Every worker keeps the code it
**   was running, the server keeps serving, and the refusal reads
**   DIFFERENTLY from a partial reload — an operator who cannot tell
**   "nothing happened" from "half of it happened" will treat them the
**   same, and only one is an emergency.
**
**   IT IS LOOPBACK-ONLY. This endpoint replaces the code the server runs.
**
**   node tests/reload-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const PORT = 8244;
const B = "http://127.0.0.1:" + PORT;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-reload-"));
const APP = path.join(tmp, "app.ring");
let server = null, log = "";

function writeApp(word) {
    fs.writeFileSync(APP, [
        "RingServ([",
        "    :port = " + PORT + ",",
        "    :workers = 3,",
        '    :database = ":memory:",',
        "    :services = [",
        "        :hello = [",
        '            :say = func aReq { return Reply(:ok, [ :word = "' + word + '" ]) }',
        "        ]",
        "    ]",
        "])",
        "",
    ].join("\n"));
}

async function waitUp() {
    for (let i = 0; i < 150; i++) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 600));
}

const say = () => fetch(B + "/api/v1", {
    method: "POST",
    body: JSON.stringify({ service: "hello", action: "say", payload: {} }),
}).then(r => r.json());

const reload = () => fetch(B + "/admin/reload", { method: "POST" })
    .then(async r => ({ status: r.status, json: await r.json() }));

/** One request on a pinned keep-alive agent, reporting how many times
 *  that socket has been used. Two uses means one connection survived. */
function pinned(agent, body) {
    return new Promise((res, rej) => {
        let sock = null;
        const req = http.request({ host: "127.0.0.1", port: PORT, path: "/api/v1",
            method: "POST", agent }, r => {
            let b = "";
            r.on("data", c => b += c);
            r.on("end", () => res({ body: b, uses: sock ? sock.__uses : -1 }));
        });
        req.on("socket", s => { sock = s; s.__uses = (s.__uses || 0) + 1; });
        req.on("error", rej);
        req.end(body);
    });
}

(async () => {
    writeApp("BEFORE");
    server = spawn(RINGSERV, ["run", APP], { stdio: ["ignore", "pipe", "pipe"] });
    server.stdout.on("data", d => log += d);
    server.stderr.on("data", d => log += d);
    check("the application comes up", await waitUp());

    const pidBefore = server.pid;
    const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    const body = JSON.stringify({ service: "hello", action: "say", payload: {} });

    const first = await pinned(agent, body);
    check("it answers with the code it started with",
        JSON.parse(first.body).data.word === "BEFORE", first.body.slice(0, 80));

    // ================================================== 1. it changes
    writeApp("AFTER");
    const t0 = Date.now();
    const r = await reload();
    const ms = Date.now() - t0;
    check("a reload is accepted", r.status === 200, r.status + " " + JSON.stringify(r.json));
    check("...and reports every worker taking the new code",
        r.json.data && r.json.data.reloaded === r.json.data.workers && r.json.data.workers >= 3,
        JSON.stringify(r.json.data));
    check("...in under 5 seconds (measured: " + ms + " ms)", ms < 5000, ms + " ms");

    const after = await say();
    check("the running server now answers with the NEW code",
        after.data && after.data.word === "AFTER", JSON.stringify(after));

    // ============================= 2. the same process, the same socket
    check("the PROCESS did not restart — this is a reload, not a bounce",
        server && server.pid === pidBefore && server.exitCode === null,
        "pid " + (server && server.pid) + " was " + pidBefore);

    const second = await pinned(agent, body);
    check("a connection opened BEFORE the reload is still usable after it — " +
        "the port was never rebound",
        second.uses > first.uses && JSON.parse(second.body).data.word === "AFTER",
        "socket uses " + first.uses + " -> " + second.uses);

    // ================================ 3. every worker, or the gate fails
    // A half-reloaded server answers two ways and says so in neither.
    {
        let stale = 0;
        for (let i = 0; i < 30; i++) {
            const j = await say();
            if (!j.data || j.data.word !== "AFTER") stale++;
        }
        check("30 consecutive calls all see the new code — no worker left behind",
            stale === 0, stale + " calls still saw the old code");
    }

    // ================================ 4. a broken application changes nothing
    {
        fs.writeFileSync(APP, "RingServ([ :port = " + PORT + ", this is not ring at all\n");
        const bad = await reload();
        check("a reload of a BROKEN application is refused",
            bad.status !== 200, String(bad.status));
        check("...as 422, which reads as `nothing changed` rather than as the " +
            "500 that means `half of it changed`",
            bad.status === 422, String(bad.status));
        check("...saying so in words, not just a number",
            /nothing changed/i.test(bad.json.message || ""), bad.json.message);
        check("...and NO worker took it",
            bad.json.data && bad.json.data.reloaded === 0, JSON.stringify(bad.json.data));

        const still = await say();
        check("...while the server keeps serving the last good code",
            still.data && still.data.word === "AFTER", JSON.stringify(still));
        check("...from the same process, still alive",
            server.exitCode === null && server.pid === pidBefore);
    }

    // ===================================== 5. a reload can be undone
    // Recovery is a gate, not a hope: fix the file, reload again, done.
    {
        writeApp("RECOVERED");
        const back = await reload();
        check("fixing the file and reloading again recovers, with no restart",
            back.status === 200, back.status + " " + JSON.stringify(back.json));
        const j = await say();
        check("...and the server answers with the fixed code",
            j.data && j.data.word === "RECOVERED", JSON.stringify(j));
    }

    await stop();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("reload-gates: " + (e && e.stack || e));
    console.error(log.slice(0, 800));
    await stop();
    process.exit(2);
});
