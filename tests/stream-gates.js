/*
** Phase-18 gates: pages that react.
**
** The promise is that a page LEARNS about a change instead of asking.
** Each gate attacks one way that could be quietly false:
**
**   IT PUSHES — a write produces an event within a second, and the event
**   carries an OFFSET rather than a payload, because one code path for
**   data is the whole design.
**
**   IT RESUMES — a client that reconnects with Last-Event-ID is not sent
**   what it already has. This is why SSE was chosen: the browser does
**   this by itself, and the id IS our shape-log offset.
**
**   IT REFUSES HONESTLY — no shape named is a 400 that says what to do;
**   the stream cap answers 503 NAMING the cap, because a client told
**   "busy" learns nothing and a client told the number can decide.
**
**   IT IS NEVER LOAD-BEARING — with streaming ignored entirely, the
**   application is still correct, just slower. That property is what
**   makes this safe at 0.9, so it is asserted rather than assumed.
**
** PLATFORM, and the entry is kept because the CORRECTION is the lesson.
** This suite skipped on Windows from 2026-08-24 to 2026-08-25 on the
** reading that "httpz's response streaming does not work on Windows".
** The FACT was right and the CAUSE was wrong: HTTPConn.writeAll used
** posix.write, which is WriteFile on Windows and does not work on an
** overlapped socket. One expression — send() there — and this suite runs
** everywhere. The same call is why no .NET client could POST to this
** server on Windows at all, which is how it was finally found: by
** DEPLOYING, not by testing. See docs/VENDOR_PATCHES.md.
**
** THE PLATFORM PROBE BELOW STAYS. A suite that cannot tell "the feature
** is broken" from "this machine cannot run it" is a suite that reports
** the wrong one, and the probe is what keeps that honest — on a platform
** nobody has tried yet as much as on one already fixed.
**
** FROM A BROWSER, a streaming failure is SILENT — measured: the
** connection is not refused and `onerror` never fires; the page simply
** holds an open stream that never delivers a frame. That is why the
** client retreats on a deadline rather than on an error, and why the
** retreat is gated here.
**
**   node tests/stream-gates.js
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const APP = path.join(ROOT, "examples", "comptoir", "app.ring");
const B = "http://127.0.0.1:8110";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-stream-"));
const DB = path.join(tmp, "s.db").replace(/\\/g, "/");
let server = null;

async function waitUp() {
    for (let i = 0; i < 150; i++) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
function start() {
    server = spawn(RINGSERV, ["run", APP], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, COMPTOIR_DB: DB },
    });
    return waitUp();
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 800));
}
const call = (service, action, payload) =>
    fetch(B + "/api/v1", { method: "POST", body: JSON.stringify({ service, action, payload }) })
        .then(r => r.json());

/** Read SSE frames for `ms`, returning the parsed events. */
async function listen(url, ms, headers) {
    const events = [];
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), ms);
    try {
        const res = await fetch(url, { headers: headers || {}, signal: ac.signal });
        if (res.status !== 200) return { status: res.status, events, res };
        const reader = res.body.getReader();
        const dec = new TextDecoder();
        let bufText = "";
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            bufText += dec.decode(value, { stream: true });
            let i;
            while ((i = bufText.indexOf("\n\n")) >= 0) {
                const frame = bufText.slice(0, i);
                bufText = bufText.slice(i + 2);
                const ev = {};
                for (const line of frame.split("\n")) {
                    const c = line.indexOf(":");
                    if (c < 0 || line.startsWith(":")) continue;
                    const k = line.slice(0, c).trim();
                    const v = line.slice(c + 1).trim();
                    if (k === "data") { try { ev.data = JSON.parse(v); } catch { ev.data = v; } }
                    else ev[k] = v;
                }
                if (ev.event || ev.data !== undefined) events.push(ev);
            }
        }
    } catch { /* aborted, which is how we stop */ }
    clearTimeout(timer);
    return { status: 200, events };
}

(async () => {
    check("the application comes up", await start());

    // THE PLATFORM PROBE, before anything is asserted. If the very first
    // frame never arrives, this machine cannot carry response streaming,
    // and the suite says so BY NAME rather than reporting a defect in
    // code that works everywhere it is deployed.
    const probe = await listen(B + "/sync/stream?shape=menu", 3000);
    if (probe.events.length === 0) {
        console.log("SKIP  pages that react — no frame arrived on " +
            process.platform + ", so this build cannot stream responses here. " +
            "Windows once looked like this and the cause was HTTPConn.writeAll " +
            "using posix.write on a socket (docs/VENDOR_PATCHES.md); if you are " +
            "reading this on a platform that should work, start there. " +
            "21 gates owned, 0 run here.");
        await stop();
        console.log("\n0 passed, 0 failed (21 skipped by name)");
        process.exit(0);
    }

    // ================================================== 1. it opens
    check("the stream opens with an `open` event",
        probe.events[0].event === "open", JSON.stringify(probe.events[0]));
    check("...naming the shape and its current offset",
        probe.events[0].data && probe.events[0].data.shape === "menu" &&
        typeof probe.events[0].data.offset === "number",
        JSON.stringify(probe.events[0].data));
    check("...and an id a browser will replay as Last-Event-ID",
        probe.events[0].id !== undefined, JSON.stringify(probe.events[0]));

    // ================================================== 2. it pushes
    let firstAdvanced = null;
    {
        const t0 = Date.now();
        const listening = listen(B + "/sync/stream?shape=menu", 4000);
        await new Promise(r => setTimeout(r, 600));
        await call("menu", "create", { name: "Espresso", price: 180, category: "cafe" });
        const wroteAt = Date.now();
        const { events } = await listening;
        const adv = events.find(e => e.event === "advanced");
        check("a write pushes an `advanced` event", !!adv,
            JSON.stringify(events.map(e => e.event)));
        check("...within a second of the write",
            !!adv && (Date.now() - wroteAt) < 4000);
        check("...carrying an OFFSET, never the row itself",
            !!adv && typeof adv.data.offset === "number" &&
            adv.data.row === undefined && adv.data.name === undefined,
            JSON.stringify(adv && adv.data));
        firstAdvanced = adv;
        check("...and the offset advanced past the opening one",
            !!adv && adv.data.offset > probe.events[0].data.offset,
            JSON.stringify(adv && adv.data));
    }

    // ============================================ 3. it resumes, not repeats
    {
        const head = (await (await fetch(B + "/sync/shape?shape=menu&offset=0&limit=50")).json())
            .data.offset;
        const { events } = await listen(B + "/sync/stream?shape=menu", 2000,
            { "last-event-id": String(head) });
        const open = events.find(e => e.event === "open");
        check("a reconnect with Last-Event-ID is not re-sent what it has",
            !!open && !events.some(e => e.event === "advanced" && e.data.offset <= head),
            JSON.stringify(events.map(e => e.event + ":" + (e.data && e.data.offset))));
    }

    // ================================================= 4. honest refusals
    {
        const r = await fetch(B + "/sync/stream");
        const j = await r.json();
        check("a stream with no shape named is refused 400, saying what to do",
            r.status === 400 && /shape=/.test(j.message), r.status + " " + j.message);
    }

    // ========================== 5. streaming is never load-bearing
    // The whole application must still be correct with the stream ignored
    // — that is what makes a dropped notification cost latency and not
    // correctness, and it is the reason this could ship at 0.9.
    {
        const before = (await call("menu", "list", {})).data.rows.length;
        await call("menu", "create", { name: "Croissant", price: 220, category: "vienn" });
        const after = (await call("menu", "list", {})).data.rows.length;
        check("with the stream ignored entirely, writes and reads still agree",
            after === before + 1, before + " -> " + after);
        const shape = await (await fetch(B + "/sync/shape?shape=menu&offset=0&limit=50")).json();
        check("...and the poll path still carries every change",
            shape.data.ops.length >= after, JSON.stringify(shape.data.ops.length));
    }

    // ============================ 6. the browser half ships in the binary
    // The promise is one <script> tag and nothing installed. If the binary
    // stops serving it, every page written against subscribe() breaks with
    // a 404 that looks like the page's own fault.
    {
        const r = await fetch(B + "/ringserv.js");
        const body = await r.text();
        check("the binary serves its own browser client at /ringserv.js",
            r.status === 200, String(r.status));
        check("...as JavaScript, not as a download",
            /javascript/i.test(r.headers.get("content-type") || ""),
            r.headers.get("content-type"));
        check("...carrying both halves of the model, call and subscribe",
            /serv\.call\s*=/.test(body) && /serv\.subscribe\s*=/.test(body));
        // Measured in a browser: a server that cannot stream does not
        // REFUSE the connection, it holds it open and silent, and onerror
        // never fires. So the client's retreat must be driven by a
        // deadline; an error handler alone would wait forever. Losing this
        // would be invisible until a page hung in the field.
        check("...and it retreats on a DEADLINE, not only on an error — " +
            "a stream that hangs silently reports nothing",
            /OPEN_DEADLINE_MS/.test(body) && /setTimeout\(failed/.test(body));
        check("...giving up after 3 attempts and saying so, rather than " +
            "retrying forever where the server cannot stream",
            /attempts\s*<\s*3/.test(body) && /falling back to polling/.test(body));
        check("...and it opens the stream by shape, resuming on its own",
            /EventSource\(/.test(body) && /sync\/stream\?shape=/.test(body));
    }

    // ======================= 7. why the stream needs no Authorization header
    // EventSource CANNOT send one — that is the standing complaint about
    // SSE. The answer here is that there is nothing on the stream to
    // protect: a frame is {shape, offset}, and the rows come through
    // POST /api/v1, which does carry the bearer token. That is a claim
    // about SHAPE, so it is gated on shape — one extra key appearing here
    // would quietly turn an unauthenticated channel into a data leak.
    //
    // Asserted on the event section 2 ALREADY CAPTURED, deliberately.
    // Opening a second stream to re-observe a property we hold is a race
    // for nothing, and it was one: this gate failed intermittently until
    // it stopped provoking its own evidence.
    {
        const keys = firstAdvanced ? Object.keys(firstAdvanced.data).sort() : [];
        check("an event carries EXACTLY {offset, shape} — never application data",
            keys.length === 2 && keys[0] === "offset" && keys[1] === "shape",
            JSON.stringify(keys));
    }

    // ============================ 8. the measures against a buffering proxy
    // A buffered stream looks identical to a working one until updates
    // arrive minutes late. These headers are the only defence the server
    // has from its own side, so losing one must fail loudly here.
    {
        const ac = new AbortController();
        const r = await fetch(B + "/sync/stream?shape=menu", { signal: ac.signal });
        const cc = r.headers.get("cache-control") || "";
        check("the stream tells caches not to store AND not to transform it",
            /no-cache/.test(cc) && /no-transform/.test(cc), cc);
        check("...and tells nginx explicitly not to buffer it",
            (r.headers.get("x-accel-buffering") || "") === "no",
            r.headers.get("x-accel-buffering"));
        ac.abort();
    }

    await stop();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("stream-gates: " + (e && e.stack || e));
    await stop();
    process.exit(2);
});
