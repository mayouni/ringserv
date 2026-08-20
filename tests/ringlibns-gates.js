/*
** RINGSERV-RINGLIBNS-01 — the test vocabulary is scoped to `test`.
**
** Every file in src/ringlib/ is loaded into EVERY application's VM, so a
** name defined there occupies the APPLICATION's global namespace. That is
** fine for `__dispatch` and fatal for `Ask`: an application with its own
** `Ask` verb — an ordinary English word — could not define one, and Ring
** reports it as a bare C22 "function redefinition" with nothing saying
** where the other definition came from.
**
** Ruled SCOPED, NOT RENAMED (2026-08-20): the collision goes away by
** removing the EXPOSURE rather than the word, so `Ask` keeps its name and
** no user pays a compatibility cost for a scope defect.
**
** These gates hold both halves of that ruling — the vocabulary is absent
** where it must be absent, and present where it must be present.
**
**   node tests/ringlibns-gates.js
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-ns-"));

function appDir(name, appSrc, testSrc) {
    const dir = path.join(tmp, name);
    fs.mkdirSync(path.join(dir, "tests"), { recursive: true });
    fs.writeFileSync(path.join(dir, "app.ring"), appSrc);
    if (testSrc) fs.writeFileSync(path.join(dir, "tests", "t.ring"), testSrc);
    return dir;
}

// An application that defines its OWN Ask. Note the file order: in Ring a
// statement after a func definition belongs to that function, so the
// declaration comes first and the func last.
const OWN_ASK =
    'RingServ([\n' +
    '\t:port = 8087,\n' +
    '\t:services = [\n' +
    '\t\t:q = [ :put = func aReq { return Reply(:ok, [ :said = Ask("hi") ]) } ]\n' +
    '\t]\n' +
    '])\n\n' +
    'func Ask cQuestion\n' +
    '\treturn "the app answered: " + cQuestion\n';

(async () => {
    // ------------------------------- the vocabulary is ABSENT when serving
    {
        const dir = appDir("ownask", OWN_ASK);
        const srv = spawn(RINGSERV, ["run", path.join(dir, "app.ring")],
            { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, RINGSERV_TEST_DB: ":memory:" } });
        let out = "";
        srv.stdout.on("data", d => { out += d; });
        srv.stderr.on("data", d => { out += d; });
        try {
            const t0 = Date.now();
            let up = false;
            while (Date.now() - t0 < 20000) {
                try {
                    if ((await fetch("http://127.0.0.1:8087/health")).status === 200) { up = true; break; }
                } catch {}
                await new Promise(r => setTimeout(r, 150));
            }
            check("an app that defines its own `Ask` SERVES", up, out.slice(0, 300));
            check("...without a redefinition error", !/redefinition/i.test(out),
                out.slice(0, 200));

            if (up) {
                const res = await fetch("http://127.0.0.1:8087/api/v1", {
                    method: "POST",
                    body: JSON.stringify({ service: "q", action: "put", payload: {} }),
                });
                const j = await res.json();
                check("...and the app's OWN Ask is the one that answers",
                    j.code === 0 && j.data.said === "the app answered: hi",
                    JSON.stringify(j));
            }
        } finally {
            srv.kill();
            await new Promise(r => setTimeout(r, 600));
        }
    }

    // A served app must not see ANY of the vocabulary — Ask is the one that
    // bit, but the ruling is about the file, not the word.
    {
        const probe =
            'RingServ([ :port = 8086, :services = [ :p = [ :names = func aReq {\n' +
            '\taOut = []\n' +
            '\tfor c in [ "ask", "expectok", "expectcode", "expectstatus", "rstestreport" ]\n' +
            '\t\tif isfunction(c) add(aOut, c) ok\n' +
            '\tnext\n' +
            '\treturn Reply(:ok, [ :found = aOut ])\n' +
            '} ] ] ])\n';
        const dir = appDir("probe", probe);
        const srv = spawn(RINGSERV, ["run", path.join(dir, "app.ring")],
            { stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, RINGSERV_TEST_DB: ":memory:" } });
        try {
            const t0 = Date.now();
            let up = false;
            while (Date.now() - t0 < 20000) {
                try {
                    if ((await fetch("http://127.0.0.1:8086/health")).status === 200) { up = true; break; }
                } catch {}
                await new Promise(r => setTimeout(r, 150));
            }
            check("the probe app serves", up);
            if (up) {
                const res = await fetch("http://127.0.0.1:8086/api/v1", {
                    method: "POST",
                    body: JSON.stringify({ service: "p", action: "names", payload: {} }),
                });
                const j = await res.json();
                check("NO test verb exists in a served application's namespace",
                    Array.isArray(j.data.found) && j.data.found.length === 0,
                    JSON.stringify(j.data.found));
            }
        } finally {
            srv.kill();
            await new Promise(r => setTimeout(r, 600));
        }
    }

    // ------------------------------ the vocabulary is PRESENT under `test`
    {
        const plain =
            'RingServ([ :port = 8085, :services = [\n' +
            '\t:hello = [ :hi = func aReq { return Reply(:ok, [ :ok = 1 ]) } ]\n' +
            '] ])\n';
        const dir = appDir("normal", plain,
            'aReply = Ask(:hello, :hi, [])\nExpectOk("the vocabulary is here", aReply)\n');
        const r = spawnSync(RINGSERV, ["test", path.join(dir, "app.ring")],
            { encoding: "utf8" });
        check("`ringserv test` still has the vocabulary", r.status === 0,
            (r.stdout + r.stderr).slice(-300));
        check("...and the expectation actually ran",
            /1 expectation/.test(r.stdout), (r.stdout || "").slice(-200));
    }

    // ---------------- the residue the ruling leaves, made a diagnosis
    //
    // Under `test` the vocabulary IS in the namespace by design, so an app
    // defining `Ask` collides there. That is accepted — what is not
    // accepted is Ring's bare C22 with no hint where the other definition
    // came from.
    {
        const dir = appDir("collide", OWN_ASK, 'ExpectTrue("never reached", 1)\n');
        const r = spawnSync(RINGSERV, ["test", path.join(dir, "app.ring")],
            { encoding: "utf8" });
        const all = r.stdout + r.stderr;
        check("the residual collision under `test` fails, rather than half-running",
            r.status !== 0, "exit " + r.status);
        check("...and NAMES the test vocabulary as the other definition",
            /test vocabulary/.test(all) && /ExpectOk/.test(all), all.slice(-400));
        check("...and says the application itself is fine",
            /never load the vocabulary|application itself is fine/.test(all),
            all.slice(-300));
    }

    // The scaffold `new` writes must still pass its own tests — the whole
    // ruling is worthless if the default path broke.
    {
        const r0 = spawnSync(RINGSERV, ["new", "nsscaffold"], { encoding: "utf8", cwd: tmp });
        check("`ringserv new` still scaffolds", r0.status === 0,
            (r0.stdout + r0.stderr).slice(0, 200));
        const r1 = spawnSync(RINGSERV, ["test", "app.ring"],
            { encoding: "utf8", cwd: path.join(tmp, "nsscaffold") });
        check("...and the scaffold's own tests still pass", r1.status === 0,
            (r1.stdout + r1.stderr).slice(-300));
    }

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})();
