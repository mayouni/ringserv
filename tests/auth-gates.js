/*
** Phase-8 gates: the actor seam.
**
** Auth code is the code most likely to be wrong in a way nobody notices,
** because the happy path passing proves almost nothing. So most of what
** is below is REFUSALS — and each one is a real vulnerability if it ever
** stops holding:
**
**   `alg: none` accepted        → anyone mints any identity
**   signature not checked       → the same, with extra steps
**   expiry ignored              → a leaked token is permanent
**   401 and 403 collapsed       → not a vulnerability, but an afternoon
**                                 lost by every caller who meets it
**
**   node tests/auth-gates.js
*/
const { spawn } = require("child_process");
const crypto = require("crypto");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "auth-app.ring");
const B = "http://127.0.0.1:8088";
const SECRET = "test-secret-do-not-ship";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const b64 = buf => Buffer.from(buf).toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Mint a JWT. `alg` and `secret` are parameters so forgeries are easy. */
function jwt(claims, opts) {
    const o = opts || {};
    const alg = o.alg || "HS256";
    const secret = o.secret || SECRET;
    const h = b64(JSON.stringify({ alg, typ: "JWT" }));
    const p = b64(JSON.stringify(claims));
    if (o.sig !== undefined) return h + "." + p + "." + o.sig;
    const s = b64(crypto.createHmac("sha256", secret).update(h + "." + p).digest());
    return h + "." + p + "." + s;
}

const now = () => Math.floor(Date.now() / 1000);

async function call(service, action, payload, token) {
    const headers = {};
    if (token) headers.authorization = "Bearer " + token;
    const res = await fetch(B + "/api/v1", {
        method: "POST", headers,
        body: JSON.stringify({ service, action, payload: payload || {} }),
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}

const server = spawn(RINGSERV, ["run", FIXTURE], { stdio: ["ignore", "ignore", "pipe"] });
let died = false;
server.on("exit", () => { died = true; });

(async () => {
    const t0 = Date.now();
    let up = false;
    while (Date.now() - t0 < 25000) {
        try { if ((await fetch(B + "/health")).status === 200) { up = true; break; } } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    check("the auth fixture comes up", up);

    // ------------------------------------------------ nothing required
    let r = await call("public", "ping");
    check("a service with no :auth is reachable without a token",
        r.status === 200 && r.json.code === 0, r.status + " " + JSON.stringify(r.json));

    r = await call("public", "ping", {}, jwt({ sub: "u1" }));
    check("...and is not broken by presenting one anyway",
        r.status === 200 && r.json.code === 0, JSON.stringify(r.json));

    // ------------------------------------------------ :auth = :required
    r = await call("me", "who");
    check("no token where one is required is 401",
        r.status === 401, r.status + " " + JSON.stringify(r.json));
    check("...and says what is missing, not just that something is",
        /authentication required/.test(r.json.message), r.json.message);

    r = await call("me", "who", {}, jwt({ sub: "alice", exp: now() + 300 }));
    check("a valid token is accepted", r.status === 200 && r.json.code === 0,
        r.status + " " + JSON.stringify(r.json));
    check("...and the ACTION sees the verified actor",
        r.json.data.sub === "alice" && r.json.data.anon === 0,
        JSON.stringify(r.json.data));

    // ------------------------------------------------------- forgeries
    //
    // Each of these is a real, named way JWT verification has been broken
    // in shipped software.
    r = await call("me", "who", {}, jwt({ sub: "mallory" }, { alg: "none", sig: "" }));
    check("`alg: none` is REFUSED", r.status === 401,
        r.status + " " + JSON.stringify(r.json));

    r = await call("me", "who", {}, jwt({ sub: "mallory" }, { secret: "wrong-secret" }));
    check("a signature made with the wrong secret is refused", r.status === 401,
        r.status + " " + JSON.stringify(r.json));

    {
        // Keep the signature, swap the payload — the classic.
        const good = jwt({ sub: "alice", exp: now() + 300 });
        const parts = good.split(".");
        const forged = [parts[0],
            b64(JSON.stringify({ sub: "root", exp: now() + 300 })), parts[2]].join(".");
        r = await call("me", "who", {}, forged);
        check("a tampered payload with a valid-looking signature is refused",
            r.status === 401, r.status + " " + JSON.stringify(r.json));
    }

    r = await call("me", "who", {}, jwt({ sub: "alice", exp: now() - 10 }));
    check("an EXPIRED token is refused", r.status === 401,
        r.status + " " + JSON.stringify(r.json));

    r = await call("me", "who", {}, jwt({ sub: "alice", nbf: now() + 300 }));
    check("a not-yet-valid token is refused", r.status === 401,
        r.status + " " + JSON.stringify(r.json));

    const malformed = [
        ["a token with two segments", "aaa.bbb"],
        ["a token with four segments", "aaa.bbb.ccc.ddd"],
        ["a token that is not base64url", "!!!.???.###"],
        ["a signature of the wrong length", jwt({ sub: "x" }, { sig: b64("short") })],
    ];
    for (const pair of malformed) {
        r = await call("me", "who", {}, pair[1]);
        check(pair[0] + " is refused", r.status === 401, r.status + "");
    }

    // The scheme matters: only Bearer is read.
    {
        const res = await fetch(B + "/api/v1", {
            method: "POST",
            headers: { authorization: "Basic " + jwt({ sub: "alice" }) },
            body: JSON.stringify({ service: "me", action: "who", payload: {} }),
        });
        check("a non-Bearer scheme is not read as a token", res.status === 401,
            res.status + "");
    }

    // ------------------------------------------------ named permissions
    const plain = jwt({ sub: "alice", exp: now() + 300 });
    r = await call("orders", "place", {}, plain);
    check("a verified caller may reach an action needing only :required",
        r.status === 200, r.status + " " + JSON.stringify(r.json));

    r = await call("orders", "refund", {}, plain);
    check("...but NOT one needing a permission they lack", r.status === 403,
        r.status + " " + JSON.stringify(r.json));
    check("403 and 401 stay distinct — a different problem deserves a different answer",
        /permission denied/.test(r.json.message) && /orders\.manage/.test(r.json.message),
        r.json.message);

    const shapes = [
        ["scope (space-separated, the OAuth convention)",
            { sub: "a", scope: "orders.read orders.manage", exp: now() + 300 }],
        ["permissions (a list)", { sub: "a", permissions: ["orders.manage"], exp: now() + 300 }],
        ["roles (a list)", { sub: "a", roles: ["orders.manage"], exp: now() + 300 }],
    ];
    for (const pair of shapes) {
        r = await call("orders", "refund", {}, jwt(pair[1]));
        check("a permission carried in " + pair[0] + " is honoured", r.status === 200,
            r.status + " " + JSON.stringify(r.json));
    }

    r = await call("orders", "refund", {},
        jwt({ sub: "a", scope: "orders.manageX", exp: now() + 300 }));
    check("a permission that merely STARTS THE SAME is not a match",
        r.status === 403, r.status + "");

    check("the server never died", !died);
})().catch(e => {
    check("the suite ran to completion", false, e.stack || String(e));
}).finally(async () => {
    server.kill();
    await new Promise(r => setTimeout(r, 600));
    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed ? 1 : 0);
});
