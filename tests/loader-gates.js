/*
** Load-anchor gates: a nested `load` must resolve against the directory of
** the FILE THAT CONTAINS IT, exactly as the native interpreter resolves it.
**
** Why this suite exists. RingServ hands an application's source to the VM as
** a string (the rs_getcode hook, src/bridge.zig), so the VM never opens the
** app as a real file. That is not what broke it. Ring anchors nested loads by
** chdir'ing into each loaded file's folder while it is scanned — and RingServ
** builds the VM with -DRING_LIMITEDSYS=1, which had made ring_general_chdir()
** a no-op that returned success. Every anchor move silently did nothing and
** every nested relative load collapsed to the process directory, so a library
** authored across sibling folders — which is every multi-file Ring library —
** could not be loaded at all. src/rs_path.c is the fix and this file holds it.
**
** The fixture under tests/fixtures/loadanchor depends on NOTHING outside
** itself, so these gates run on a machine with no third-party library
** installed. Where the native `ring` interpreter IS present it is used as an
** ORACLE: RingServ and Ring must resolve the same program the same way, which
** is a stronger claim than any expectation written here by hand. When it is
** absent the oracle gates are SKIPPED BY NAME, never silently dropped.
**
** Usage: node tests/loader-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { ringExe } = require("./ring-exe.js");

const root = path.join(__dirname, "..");
const RINGSERV = path.join(root, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(__dirname, "fixtures", "loadanchor");
const MW_PORT = 8099;

let passed = 0, failed = 0;
const skipped = [];

function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

/* A gate that could not run is named and counted, never dropped: a green
** nobody earned reads exactly like a green somebody did. */
function skip(name, why) {
    skipped.push(name + "  (" + why + ")");
    console.log("SKIP  " + name + "  — " + why);
}

function runServ(args, cwd) {
    const r = spawnSync(RINGSERV, args, { cwd, encoding: "utf8" });
    return { out: (r.stdout || "") + (r.stderr || ""), status: r.status };
}

function runRing(exe, args, cwd) {
    const r = spawnSync(exe, args, { cwd, encoding: "utf8" });
    return { out: (r.stdout || "") + (r.stderr || ""), status: r.status };
}

const norm = s => s.replace(/\r\n/g, "\n").trim();
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(url, ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
        try { const r = await fetch(url); if (r.status === 200) return r; } catch {}
        await sleep(200);
    }
    return null;
}

function killTree(child) {
    if (!child || child.exitCode !== null) return;
    try {
        if (process.platform === "win32") {
            spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
        } else {
            process.kill(child.pid, "SIGKILL");
        }
    } catch {}
}

if (!fs.existsSync(RINGSERV)) {
    console.error("tests/loader-gates.js: build first — zig build");
    process.exit(2);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-loadanchor-"));

// ---------------------------------------------------------------- anchoring
//
// app.ring loads lib/a.ring; a.ring loads its SIBLING b.ring; b.ring loads its
// CHILD deep/c.ring; c.ring loads ../up.ring, back up and over to a cousin.
// Four directories, three anchors below the top level. One working directory
// can satisfy at most one of them, which is exactly what used to happen.
const APP_OK = "app: a(b(c(up)))";
let r = runServ(["run", "app.ring"], FIXTURE);
check("nested load anchors per file: sibling, child, and up-and-over",
    norm(r.out) === APP_OK, JSON.stringify(norm(r.out)));

// The two other forms that reach ring_state_runfile by a different route:
// `load package` (a custom global scope) and `load again` (bypasses the
// already-loaded check). Both must anchor the same way.
const FORMS_OK = "forms: p(q) c(up)";
r = runServ(["run", "forms.ring"], FIXTURE);
check("`load package` and `load again` anchor per file too",
    norm(r.out) === FORMS_OK, JSON.stringify(norm(r.out)));

// The regression that matters most, and the shape the bangalo-server profile
// hit: an ABSOLUTE top-level load from an unrelated working directory. Every
// load below it is relative and must still resolve, with the process sitting
// somewhere else entirely.
const absApp = path.join(tmp, "abs.ring");
fs.writeFileSync(absApp,
    'load "' + path.join(FIXTURE, "lib", "a.ring").replace(/\\/g, "/") + '"\n' +
    'see "abs: " + a_ok() + nl\n');
r = runServ(["run", absApp], root);
check("a library loaded by absolute path resolves its own graph, from any cwd",
    norm(r.out) === "abs: a(b(c(up)))", JSON.stringify(norm(r.out)));

// `check` compiles the app without running it — the same parse, a different
// entry point, and the one the profile's report quoted. It must agree.
r = runServ(["check", path.join(FIXTURE, "app.ring")], FIXTURE);
check("`ringserv check` resolves the same graph as `ringserv run`",
    r.status === 0 && !/Can't open file/.test(r.out), norm(r.out).slice(0, 200));

// ------------------------------------------------- the top level, on purpose
//
// A `load` written in the application file itself is resolved against the
// PROCESS working directory, not against the application's own folder —
// because that is what native `ring` does with the file it was handed, and
// RingServ matches the language it hosts rather than improving on it. This
// gate exists so that rule is a decision on the record and not an accident:
// if someone anchors the top level to the app folder, this fires and they
// must say so out loud. docs/LOADING.md carries the argument both ways.
r = runServ(["run", path.join(FIXTURE, "app.ring")], root);
check("a load in the app file itself stays cwd-relative, as in native ring",
    /Can't open file lib[\\/]a\.ring/.test(r.out), norm(r.out).slice(0, 200));

// ----------------------------------------------------- the virtual directory
//
// The anchor is a per-thread VIRTUAL working directory (src/rs_path.c), so
// currentdir() finally answers — under RING_LIMITEDSYS it returned an
// uninitialised buffer — and chdir() moves that answer without ever moving
// the process. A server that relocated its own directory mid-boot would be a
// far worse bug than the one being fixed.
const cwdApp = path.join(tmp, "cwd.ring");
fs.writeFileSync(cwdApp, 'see currentdir() + nl\nchdir("tests")\nsee currentdir() + nl\n');
r = runServ(["run", cwdApp], root);
const lines = norm(r.out).split("\n");
check("currentdir() reports the launch directory",
    lines[0] !== undefined && path.resolve(lines[0].trim()) === path.resolve(root),
    JSON.stringify(lines[0]));
check("chdir() moves the virtual directory",
    lines[1] !== undefined &&
    path.resolve(lines[1].trim()) === path.resolve(path.join(root, "tests")),
    JSON.stringify(lines[1]));

// ------------------------------------------------------------------- oracle
//
// Native `ring` decides, not this file. Same fixture, same working directory,
// same bytes out — including the FAILING case, where both must refuse the
// same top-level form for the same reason. Agreeing on a refusal is the half
// of compatibility that is easy to leave untested.
const RING = ringExe();
if (!fs.existsSync(RING)) {
    skip("native-ring oracle: nested load", "no ring interpreter (set RING_EXE or RING_HOME)");
    skip("native-ring oracle: load package / load again", "no ring interpreter");
    skip("native-ring oracle: the top-level form", "no ring interpreter");
} else {
    const a = runServ(["run", "app.ring"], FIXTURE);
    const b = runRing(RING, ["app.ring"], FIXTURE);
    check("native-ring oracle: nested load", norm(a.out) === norm(b.out),
        "ringserv " + JSON.stringify(norm(a.out)) + " vs ring " + JSON.stringify(norm(b.out)));

    const c = runServ(["run", "forms.ring"], FIXTURE);
    const d = runRing(RING, ["forms.ring"], FIXTURE);
    check("native-ring oracle: load package / load again", norm(c.out) === norm(d.out),
        "ringserv " + JSON.stringify(norm(c.out)) + " vs ring " + JSON.stringify(norm(d.out)));

    const e = runServ(["run", path.join(FIXTURE, "app.ring")], root);
    const f = runRing(RING, [path.join(FIXTURE, "app.ring")], root);
    const named = s => (s.match(/Can't open file ([^\s]+)/) || [])[1];
    check("native-ring oracle: the top-level form fails the same way, naming the same file",
        named(e.out) !== undefined && named(e.out) === named(f.out),
        "ringserv " + named(e.out) + " vs ring " + named(f.out));
}

// ------------------------------------------------------------- every worker
//
// The anchor is _Thread_local, and this is the gate that says why. RingServ
// evaluates the application source ONCE PER WORKER, so eight threads walk the
// same load graph at the same moment. A process-wide chdir here would be a
// race: two workers anchored into two different folders, a graph resolved half
// in each, and a failure that does not reproduce twice. Every worker must
// return the whole chain.
const mwDir = path.join(tmp, "mw");
fs.mkdirSync(mwDir);
fs.writeFileSync(path.join(mwDir, "app.ring"),
    'load "' + path.join(FIXTURE, "lib", "a.ring").replace(/\\/g, "/") + '"\n\n' +
    "RingServ([\n" +
    "\t:port = " + MW_PORT + ",\n" +
    "\t:workers = 8,\n" +
    "\t:services = [\n" +
    "\t\t:probe = [ :chain = func aReq { return Reply(:ok, [ :chain = a_ok() ]) } ]\n" +
    "\t]\n" +
    "])\n");

(async () => {
    const child = spawn(RINGSERV, ["run", path.join(mwDir, "app.ring")],
        { cwd: root, stdio: "ignore" });
    try {
        const up = await waitFor("http://127.0.0.1:" + MW_PORT + "/health", 20000);
        if (!up) {
            skip("every worker anchors independently", "the test server did not come up");
        } else {
            const answers = [];
            for (let i = 0; i < 24; i++) {
                const res = await fetch("http://127.0.0.1:" + MW_PORT + "/api/v1", {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ service: "probe", action: "chain", payload: {} }),
                });
                answers.push(((await res.json()).data || {}).chain);
            }
            check("every worker anchors independently: 24 calls, 8 workers, one answer",
                answers.length === 24 && answers.every(a => a === "a(b(c(up)))"),
                JSON.stringify([...new Set(answers)]));
        }
    } catch (e) {
        check("every worker anchors independently: 24 calls, 8 workers, one answer",
            false, String(e));
    } finally {
        killTree(child);
    }

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}

    console.log("\n" + passed + " passed, " + failed + " failed, " + skipped.length + " skipped");
    for (const s of skipped) console.log("  skipped: " + s);
    process.exit(failed === 0 ? 0 : 1);
})();
