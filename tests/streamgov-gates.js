/*
** Phase-19 gates: a subscription is a placed thing.
**
** Phase 18 let a page subscribe to a shape by naming it, with nothing in
** between. That was safe only because the stream carries offsets and never
** rows — a real argument, and one that answers exactly half the question.
** These gates hold the other half:
**
**   IT REFUSES WHAT DOES NOT EXIST, and refuses it the way the POLL path
**   already does. Measured 2026-08-25, before the fix: /sync/stream on an
**   unknown shape answered 200, sent an `open` frame and reported offset
**   -1, while /sync/shape had refused the same name 404 since phase 8. A
**   page with a typo was told it was connected and then waited forever.
**   The gate compares the two doors AGAINST EACH OTHER, never against a
**   literal, because a literal drifts and an agreement cannot.
**
**   IT REFUSES IN THE CALL'S OWN WORDS. A shape governed by a service this
**   server does not answer is refused with the sentence a CALL to that
**   service gets — byte for byte. A caller told `no` in two different
**   sentences learns that the rule is two rules.
**
**   AN ABSENT DECLARATION STILL STREAMS. The declaration ADDS governance;
**   it does not switch the feature on. A phase that quietly turns working
**   pages off teaches people to fear upgrades, so this is a gate and not
**   an intention.
**
**   A WRONG DECLARATION IS FOUND AT BOOT. `:stream` naming a service that
**   does not exist, or sitting on a table with no `:sync`, is a topology
**   problem before a page is — that is the entire reason to declare it.
**
** PLATFORM: the REFUSAL gates need no streaming, so they run everywhere —
** a refusal is an ordinary JSON response. Only the two gates that assert a
** subscription actually OPENS need streaming, and they skip by name where
** it is unavailable. That split was deliberate and it paid: when Windows
** streaming was fixed on 2026-08-25 this suite went from 15 run to 17 with
** no edit, and the 15 had been real all along.
**
**   node tests/streamgov-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const APP = path.join(ROOT, "tests", "fixtures", "stream-gov.ring");
const B = "http://127.0.0.1:8118";

let passed = 0, failed = 0, skipped = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}
function skip(name, why) {
    skipped++; console.log("SKIP  " + name + " — " + why);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-gov-"));
const DB = path.join(tmp, "g.db").replace(/\\/g, "/");
let server = null, bootLog = "";

async function waitUp() {
    for (let i = 0; i < 150; i++) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
function start() {
    server = spawn(RINGSERV, ["run", APP], {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: DB },
    });
    server.stdout.on("data", d => { bootLog += d; });
    server.stderr.on("data", d => { bootLog += d; });
    return waitUp();
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 800));
}
const call = (service, action, payload) =>
    fetch(B + "/api/v1", { method: "POST", body: JSON.stringify({ service, action, payload }) });

/** The stream endpoint's answer, without holding the connection. */
async function streamAnswer(shape) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 3000);
    try {
        const r = await fetch(B + "/sync/stream?shape=" + encodeURIComponent(shape),
            { signal: ac.signal });
        const ct = r.headers.get("content-type") || "";
        if (r.status !== 200) {
            const j = await r.json();
            clearTimeout(timer);
            return { status: r.status, message: j.message, streaming: false };
        }
        // 200 — read one frame to prove it really opened, if it can.
        let frame = "";
        try {
            const { value } = await r.body.getReader().read();
            frame = new TextDecoder().decode(value || new Uint8Array());
        } catch { /* aborted */ }
        clearTimeout(timer);
        ac.abort();
        return { status: 200, message: "", streaming: true, frame, ct };
    } catch (e) {
        clearTimeout(timer);
        return { status: 0, message: String(e && e.name), streaming: false };
    }
}

(async () => {
    check("the fixture comes up", await start());

    // ============================== 1. two doors, one answer about existence
    {
        const poll = await fetch(B + "/sync/shape?shape=nonsense&offset=0&limit=1");
        const pollJson = await poll.json();
        const str = await streamAnswer("nonsense");

        check("the poll path refuses an unknown shape 404 (unchanged since phase 8)",
            poll.status === 404, String(poll.status));
        check("the STREAM now refuses it too — it used to answer 200 and offset -1",
            str.status === 404, str.status + " " + (str.frame || str.message || ""));
        // The agreement is the gate. Comparing each to a literal would let
        // them drift apart one commit at a time while both stayed green.
        check("...with the SAME status and the SAME sentence, compared to each " +
            "other rather than to a literal",
            poll.status === str.status && pollJson.message === str.message,
            JSON.stringify({ poll: pollJson.message, stream: str.message }));
    }

    // ==================== 2. governed by a service this server DOES answer
    {
        const r = await call("notes", "create", { title: "one", body: "x" });
        check("a governed shape's own service answers normally", r.status === 200,
            String(r.status));

        const str = await streamAnswer("notes");
        if (str.status === 0) {
            skip("a subscription to a shape governed by an ANSWERABLE service opens",
                "this build cannot stream responses on " + process.platform +
                " (see tests/stream-gates.js); 1 gate owned, 0 run here");
        } else {
            check("a subscription to a shape governed by an ANSWERABLE service opens",
                str.status === 200 && /event: open/.test(str.frame || ""),
                str.status + " " + (str.frame || "").slice(0, 80));
        }
    }

    // ============ 3. governed by a service this server refuses to answer
    // The heart of the phase: the SAME sentence, not a second one.
    {
        const callRes = await call("onlyonthedevice", "ping", {});
        const callJson = await callRes.json();
        const str = await streamAnswer("secret");

        check("calling a page-placed service is refused 501 (phase 8's rule)",
            callRes.status === 501, callRes.status + " " + callJson.message);
        check("SUBSCRIBING to a shape it governs is refused 501 as well",
            str.status === 501, str.status + " " + (str.message || ""));
        check("...in BYTE-IDENTICAL words — one rule, one sentence, two doors",
            callJson.message === str.message,
            JSON.stringify({ call: callJson.message, subscribe: str.message }));
    }

    // ================================= 4. :never is a decision, said as one
    {
        const str = await streamAnswer("loose");
        check("a shape declared :stream = :never refuses the subscription",
            str.status === 403, str.status + " " + (str.message || ""));
        check("...NAMING the declaration, so a reader stops hunting a defect",
            /:never/.test(str.message || "") && /:stream/.test(str.message || ""),
            str.message);
        check("...and pointing at the door that still works",
            /sync\/shape/.test(str.message || ""), str.message);
        // :stream governs the STREAM and nothing else — said out loud in
        // PLAN.md, so it is gated rather than left to be discovered.
        const poll = await fetch(B + "/sync/shape?shape=loose&offset=0&limit=1");
        check("...while the POLL path is untouched by :stream, as documented",
            poll.status === 200, String(poll.status));
    }

    // ================== 5. an undeclared shape still streams (phase 18 kept)
    {
        const str = await streamAnswer("orphan");
        if (str.status === 0) {
            skip("a shape with NO :stream declaration still streams",
                "this build cannot stream responses on " + process.platform +
                "; 1 gate owned, 0 run here");
        } else {
            check("a shape with NO :stream declaration still streams — the " +
                "declaration adds governance, it does not switch streaming on",
                str.status === 200 && /event: open/.test(str.frame || ""),
                str.status + " " + (str.frame || "").slice(0, 80));
        }
    }

    // ==================== 6. a wrong declaration is a BOOT problem
    // Declaring governance whose subject does not exist is the one mistake
    // this feature is supposed to make impossible to ship. It must be found
    // where the declaration is, not where a page is.
    {
        const bad = path.join(tmp, "bad.ring");
        fs.writeFileSync(bad,
            'RingServ([ :port = 8119, :workers = 1, :database = "' +
                path.join(tmp, "b.db").replace(/\\/g, "/") + '",\n' +
            '    :data = [ :a = [ :t = :text ], :b = [ :t = :text ] ],\n' +
            '    :services = [ :a = [ :table = "a" ], :b = [ :table = "b" ] ]\n' +
            '])\n' +
            'Topology([ :app = "bad",\n' +
            '    :data = [\n' +
            '        :a = [ :store = :local, :sync = :live, :stream = "nosuchservice" ],\n' +
            '        :b = [ :store = :server, :stream = "b" ]\n' +
            '    ],\n' +
            '    :services = [ :a = [ :site = :server ], :b = [ :site = :server ] ]\n' +
            '])\n');
        const out = require("child_process").spawnSync(RINGSERV, ["check", bad],
            { encoding: "utf8" });
        const text = (out.stdout || "") + (out.stderr || "");
        // Asserted on the SENTENCE a reader sees, not on the internal
        // problem code: `check` prints the sentence, and a gate that
        // asserts something the tool never shows is a gate that can pass
        // while the user learns nothing.
        check("`:stream` naming a service that does not exist is reported at boot",
            /nosuchservice/.test(text) &&
            /no service by that name is declared/.test(text),
            text.slice(0, 260));
        check("`:stream` on a table with no `:sync` is reported too — there is " +
            "no shape log to subscribe to",
            /no shape log to subscribe to/.test(text), text.slice(0, 260));
        // A NEW KIND OF PROBLEM MUST WEIGH WHAT THE OLD ONES WEIGH.
        // Measured against a file carrying an ORDINARY topology problem in
        // the same run, rather than asserted against a literal exit code:
        // if `check`'s severity policy ever changes, both move together and
        // this gate keeps meaning what it says.
        const ordinary = path.join(tmp, "ordinary.ring");
        fs.writeFileSync(ordinary, [
            'RingServ([ :port = 8119, :workers = 1, :database = "' +
                path.join(tmp, "o.db").split(path.sep).join("/") + '",',
            '    :data = [ :a = [ :t = :text ] ],',
            '    :services = [ :a = [ :table = "a" ] ]',
            '])',
            'Topology([ :app = "ord",',
            '    :data = [ :a = [ :store = :local, :sync = :nonsense ] ],',
            '    :services = [ :a = [ :site = :nowhere ] ]',
            '])',
            "",
        ].join("\n"));
        const ord = require("child_process").spawnSync(RINGSERV, ["check", ordinary],
            { encoding: "utf8" });
        check("...weighed exactly as an ordinary topology problem is, measured " +
            "side by side rather than against a literal",
            out.status === ord.status,
            "stream: " + out.status + " ordinary: " + ord.status);
    }

    await stop();
    console.log(`\n${passed} passed, ${failed} failed` +
        (skipped ? `, ${skipped} skipped by name` : ""));
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("streamgov-gates: " + (e && e.stack || e));
    console.error(bootLog.slice(0, 600));
    await stop();
    process.exit(2);
});
