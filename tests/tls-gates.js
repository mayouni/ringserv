/*
** Phase-8 gates: the TLS decision, enforced.
**
** docs/TLS.md decides that RingServ terminates no TLS and expects a proxy
** in front. A decision that lives only in a document is a decision
** somebody will miss at 2am, so the runtime holds it — and this suite is
** what keeps the runtime holding it.
**
** What is under test is a REFUSAL, which is the kind of behaviour that
** rots quietly: nobody notices when a guard stops guarding.
**
**   node tests/tls-gates.js
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-tls-"));

/** An app declaring the given RingServ() fields, written to its own dir. */
function app(name, decl) {
    const dir = path.join(tmp, name);
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, "app.ring");
    fs.writeFileSync(file,
        "RingServ([\n" + decl +
        "\t:services = [ :hi = [ :now = func aReq { return Reply(:ok, \"x\") } ] ]\n])\n");
    return file;
}

/** Run a server briefly and return what it printed plus how it exited. */
function runBriefly(file, ms = 2500) {
    const p = spawn(RINGSERV, ["run", file], {
        env: { ...process.env, RINGSERV_TEST_DB: ":memory:" },
    });
    let out = "";
    p.stdout.on("data", d => { out += d; });
    p.stderr.on("data", d => { out += d; });
    return new Promise(resolve => {
        let done = false;
        const finish = code => {
            if (done) return;
            done = true;
            try { p.kill(); } catch {}
            resolve({ out, code });
        };
        p.on("exit", finish);
        setTimeout(() => finish(null), ms);   // null = still running
    });
}

(async () => {
    // ------------------------------------------------- the default is safe
    {
        const r = await runBriefly(app("default", "\t:port = 8071,\n"));
        check("the default bind is loopback, with no declaration needed",
            /serving on http:\/\/127\.0\.0\.1:8071/.test(r.out), r.out.slice(0, 200));
        check("...and it starts", r.code === null, "exited " + r.code);
    }

    // ------------------------------------- exposure without acknowledgement
    {
        const r = await runBriefly(app("exposed", '\t:port = 8072,\n\t:host = "0.0.0.0",\n'));
        check("binding a non-loopback address REFUSES to start",
            r.code === 1, "exit " + r.code);
        check("...and says what it is refusing and why",
            /refusing to serve plain HTTP/.test(r.out) && /terminates no TLS/.test(r.out),
            r.out.slice(0, 200));
        check("...and names BOTH ways forward, not just the problem",
            /behindproxy = true/.test(r.out) && /loopback/.test(r.out),
            r.out.slice(0, 400));
        check("...and never printed a serving banner",
            !/serving on/.test(r.out), r.out.slice(0, 200));
    }

    // ---------------------------------------- exposure, acknowledged
    {
        const r = await runBriefly(
            app("acked", '\t:port = 8073,\n\t:host = "0.0.0.0",\n\t:behindproxy = true,\n'));
        check("the same bind WITH :behindproxy starts", r.code === null,
            "exit " + r.code + " " + r.out.slice(0, 200));
        check("...on the address it was given",
            /serving on http:\/\/0\.0\.0\.0:8073/.test(r.out), r.out.slice(0, 200));
        check("...and says out loud that TLS is the proxy's job",
            /TLS is the proxy's job/.test(r.out), r.out.slice(0, 200));
    }

    // ----------------------------------- the whole 127/8 block is loopback
    {
        const r = await runBriefly(app("block", '\t:port = 8074,\n\t:host = "127.0.0.2",\n'));
        check("127.0.0.2 counts as loopback — it is as local as 127.0.0.1",
            !/refusing/.test(r.out), r.out.slice(0, 200));
    }

    // The acknowledgement must be hard to give by accident, but not
    // pedantic about how it is spelled: an operator who writes 1 or "yes"
    // meant the same thing as `true`.
    for (const spelling of ["true", "1", '"yes"']) {
        const r = await runBriefly(
            app("spell" + spelling.replace(/\W/g, ""),
                `\t:port = 8075,\n\t:host = "0.0.0.0",\n\t:behindproxy = ${spelling},\n`));
        check(`:behindproxy = ${spelling} is accepted`,
            !/refusing/.test(r.out), r.out.slice(0, 160));
    }

    // ...and anything that is not an acknowledgement is not one.
    for (const spelling of ["false", "0", '""']) {
        const r = await runBriefly(
            app("no" + spelling.replace(/\W/g, "x"),
                `\t:port = 8076,\n\t:host = "0.0.0.0",\n\t:behindproxy = ${spelling},\n`));
        check(`:behindproxy = ${spelling} is NOT an acknowledgement`,
            /refusing/.test(r.out), r.out.slice(0, 160));
    }

    // The decision must be findable from the refusal, and the document
    // must still exist to be found.
    check("docs/TLS.md exists to be pointed at",
        fs.existsSync(path.join(ROOT, "docs", "TLS.md")));

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})();
