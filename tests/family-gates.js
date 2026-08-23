/*
** Phase-12 gates: the family handshake.
**
** The promise is zero-config symbiosis, and each gate attacks one way
** it could quietly be false:
**
**   DISCOVERY — two processes with no configuration find each other,
**   and the identity fields (custody axis, algorithm) round-trip.
**
**   THE PLACED CALL — alpha calls beta BY NAME, address supplied by the
**   handshake, and beta's ordinary dispatcher answers (contracts,
**   placement and actors still govern — family is a stranger with a
**   known address).
**
**   REFUSAL IS ABSENCE — `:announce = false` is proven by PACKET
**   CAPTURE, not by trust: a raw UDP listener shares the port and
**   asserts the quiet app's name never crosses the wire while a loud
**   one's does.
**
**   NOT-FAMILY IS IGNORED BY SHAPE — garbage, wrong family, wrong
**   version: none of it reaches the roster.
**
**   node tests/family-gates.js
*/
const { spawn } = require("child_process");
const dgram = require("dgram");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FAM = p => path.join(ROOT, "tests", "fixtures", "family", p);
const FPORT = 47474;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function call(port, service, action, payload) {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1`, {
        method: "POST", body: JSON.stringify({ service, action, payload }),
    });
    return { status: res.status, json: await res.json() };
}
async function waitUp(port) {
    for (let i = 0; i < 150; i++) {
        try { if ((await fetch(`http://127.0.0.1:${port}/health`)).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}

const procs = [];
function boot(fixture) {
    const p = spawn(RINGSERV, ["run", FAM(fixture)], { stdio: ["ignore", "ignore", "pipe"] });
    procs.push(p);
    return p;
}
async function stopAll() {
    for (const p of procs) p.kill();
    await new Promise(r => setTimeout(r, 800));
}

(async () => {
    // The capture socket FIRST, so it hears every beacon from boot on.
    const heardApps = new Set();
    const cap = dgram.createSocket({ type: "udp4", reuseAddr: true });
    cap.on("message", m => {
        try {
            const d = JSON.parse(m.toString());
            if (d && d.family === "ringserv" && d.app) heardApps.add(d.app);
        } catch {}
    });
    await new Promise((res, rej) => { cap.once("error", rej); cap.bind(FPORT, res); });

    boot("alpha.ring");
    boot("beta.ring");
    boot("gamma.ring");
    check("alpha comes up", await waitUp(8123));
    check("beta comes up", await waitUp(8124));
    check("gamma (:announce = false) comes up and serves", await waitUp(8125));

    // ============================================== 1. discovery
    let sibs = [];
    for (let i = 0; i < 40; i++) {
        const r = await call(8123, "me", "family", {});
        sibs = r.json.data.siblings || [];
        if (sibs.some(s => s.app === "beta")) break;
        await new Promise(r2 => setTimeout(r2, 300));
    }
    const beta = sibs.find(s => s.app === "beta");
    check("alpha discovers beta with ZERO configuration", !!beta, JSON.stringify(sibs));
    check("...at a loopback address, so the call can actually land",
        beta && /^127\./.test(beta.host), beta && beta.host);
    check("...identity round-trips: custody is the axis",
        beta && beta.custody === "L1", beta && beta.custody);
    check("...and the algorithm column is not decorative",
        beta && beta.alg === "ES256", beta && beta.alg);
    check("the roster excludes the speaker itself",
        !sibs.some(s => s.app === "alpha"), JSON.stringify(sibs));

    // ============================================== 2. the placed call
    const ask = await call(8123, "me", "ask", { name: "gate" });
    check("alpha calls beta BY NAME, address from the handshake",
        ask.json.code === 0 && ask.json.data.beta_said === "Ahlan, gate! — beta here",
        JSON.stringify(ask.json));

    // Beta's own door still governs: a family call is dispatched like any
    // other, so an unknown action refuses exactly as it would for a stranger.
    const nf = await call(8124, "hello", "nosuch", {});
    check("family is a stranger with a known address — refusals unchanged",
        nf.status === 404, nf.status + "");

    // ============================================== 3. refusal is absence
    // Six seconds of listening — three beacon periods. The loud apps must
    // be on the wire; the quiet one must not, BY PACKET CAPTURE.
    await new Promise(r => setTimeout(r, 6000));
    check("alpha and beta are audible on the wire (the capture works)",
        heardApps.has("alpha") && heardApps.has("beta"),
        [...heardApps].join(","));
    check(":announce = false is proven silent by packet capture, not trust",
        !heardApps.has("gamma"), [...heardApps].join(","));

    // ============================================== 4. not-family, ignored
    const tx = dgram.createSocket("udp4");
    const junk = [
        Buffer.from("not json at all"),
        Buffer.from(JSON.stringify({ family: "other", v: 1, app: "evil", port: 9999 })),
        Buffer.from(JSON.stringify({ family: "ringserv", v: 99, app: "evil", port: 9999 })),
        Buffer.from(JSON.stringify({ family: "ringserv", v: 1, app: "", port: 9999 })),
    ];
    for (const b of junk) {
        await new Promise(r => tx.send(b, FPORT, "127.0.0.1", r));
    }
    tx.close();
    await new Promise(r => setTimeout(r, 1500));
    const after = (await call(8123, "me", "family", {})).json.data.siblings || [];
    check("garbage, wrong family and wrong version never reach the roster",
        !after.some(s => s.app === "evil"), JSON.stringify(after));

    cap.close();
    await stopAll();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("family-gates: " + (e && e.stack || e));
    await stopAll();
    process.exit(2);
});
