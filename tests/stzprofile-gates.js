/*
** The bangalo-server profile's dependency on stzlib -- FOUR questions, asked
** and reported SEPARATELY, because they are four different repairs.
**
** WHY THIS SUITE EXISTS. Central routed a proposal on 2026-08-23 21:25: a
** dependency on stzlib should check that the SOURCE is there and that the
** LIBRARY is BUILT, and report those separately, "because they are different
** repairs". That is right and it is not enough. Measured here on 2026-08-24,
** both of those were GREEN on this machine -- the checkout is present and 92
** engine libraries are built -- and the profile still emitted 80
** `WARNING: ... not found` lines and died on `stzenginestring`.
**
** So this suite asks four:
**
**   1 SOURCE     is there an stzlib checkout, and does stzLib.ring exist in it?
**   2 BUILT      is the engine compiled? (count the artefacts, do not guess)
**   3 REACHABLE  will stzlib's OWN discovery rule find that engine from the
**                working directory this process is started in? This is the one
**                a two-part check misses, and the one that bit here.
**                stzlib walks UP from currentdir() trying <dir>/engine and
**                <dir>/libraries/stzlib/engine, then falls back to
**                exefolder()/../libraries/stzlib/engine -- the Ring-installation
**                layout. A SIBLING checkout is on neither path, so a host
**                started in its own repository finds nothing while everything
**                is present and built.
**   4 LOADABLE   can THIS binary load a native extension at all? RingServ is
**                built RING_NODLL=1, so `loadlib` does not exist. This answer
**                is NO on every machine and it is a PROPERTY, not a defect
**                (docs/LOADING.md). It outranks 1-3: with all three green the
**                run still stops at `loadlib`, measured.
**
** NOTHING HERE FAILS FOR WANT OF stzlib. Questions 1-3 SKIP BY NAME when the
** checkout is absent -- this repository must build, run and pass its own suite
** with no stzlib on the machine, and a suite that went red without one would
** have turned an optional profile into a requirement. Question 4 always runs;
** it needs nothing but RingServ.
**
**   node tests/stzprofile-gates.js
*/
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const PROFILE = path.join(ROOT, "examples", "bangalo-server", "app.ring");

let passed = 0, failed = 0, skipped = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  - " + detail : "")); }
}
function skip(name, why) { skipped++; console.log("SKIP  " + name + "  - " + why); }
function note(text) { console.log("      " + text); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-stzprofile-"));
function run(source, opts) {
    const file = path.join(tmp, "p" + (run.n = (run.n || 0) + 1) + ".ring");
    fs.writeFileSync(file, source);
    const r = spawnSync(RINGSERV, ["run", file], {
        encoding: "utf8", cwd: (opts && opts.cwd) || ROOT,
        env: { ...process.env, ...((opts && opts.env) || {}) },
    });
    return { status: r.status, out: ((r.stdout || "") + (r.stderr || "")).trim() };
}

console.log("== the stzlib profile: source, built, reachable, loadable ==\n");

// ------------------------------------------------------------------ 0. the path
//
// The profile names its own stzlib. Read the configured path OUT of the file
// rather than hardcoding one here: if someone re-points the profile, this
// suite follows, and if the two ever disagree the gate below says so.
// The DIRECTORY is what the profile configures -- variable first, quoted
// default second. Match the assignment, never the `load` line: since 08-24
// the load is an eval'd concatenation, so a regex aimed at the loaded string
// captures the concatenation source and every check below it then measures a
// path that does not exist. That happened once while this suite was written.
const src = fs.readFileSync(PROFILE, "utf8");
const envName = (/sysget\("([A-Z_]+)"\)/.exec(src) || [])[1] || null;
const defaultDir = (/\$cStzLibDir\s*=\s*"([^"]+)"/.exec(src) || [])[1] || null;

check("the profile states its stzlib directory in a form this gate can read",
    defaultDir !== null && !/[$'+]/.test(defaultDir),
    "no quoted default directory found in app.ring - got " + defaultDir);
if (envName) note("override variable: " + envName);
if (defaultDir) note("default directory: " + defaultDir);

const chosenDir = (envName && process.env[envName]) || defaultDir;
const stzRoot = chosenDir ? chosenDir.replace(/\\/g, "/") : null;
const configured = stzRoot ? stzRoot + "/stzLib.ring" : null;

// ------------------------------------------------------------------- 1. SOURCE
let haveSource = false;
if (!configured) {
    skip("1 SOURCE", "no path to check - the gate above says why");
} else if (!fs.existsSync(configured)) {
    skip("1 SOURCE", "no stzlib checkout at " + configured + " - the profile is "
        + "optional, so this is legal and NOT a failure. Repair: clone stzlib, "
        + "or set " + (envName || "the path in app.ring"));
} else {
    haveSource = true;
    check("1 SOURCE    stzLib.ring exists at the configured path", true);
    note(configured);
}

// -------------------------------------------------------------------- 2. BUILT
//
// Count the artefacts. "Built" is a number here rather than a yes, because a
// PARTLY built engine is the case that reads as built and behaves as broken.
const ENGINE = stzRoot ? path.join(stzRoot, "engine") : null;
const OUTDIR = ENGINE ? path.join(ENGINE, "zig-out",
    process.platform === "win32" ? "bin" : "lib") : null;
const EXT = process.platform === "win32" ? ".dll"
    : process.platform === "darwin" ? ".dylib" : ".so";

let built = 0, bindings = 0;
if (!haveSource) {
    skip("2 BUILT", "no source - question 1 says why");
} else {
    bindings = fs.existsSync(ENGINE)
        ? fs.readdirSync(ENGINE).filter(f => f.endsWith(".ring")).length : 0;
    built = fs.existsSync(OUTDIR)
        ? fs.readdirSync(OUTDIR).filter(f => f.endsWith(EXT)).length : 0;
    if (built === 0) {
        skip("2 BUILT", "the engine is NOT built - no " + EXT + " in " + OUTDIR
            + ". Repair: build stzlib's engine. This is a DIFFERENT repair from "
            + "a missing checkout, which is why it is a separate line");
    } else {
        check("2 BUILT     the engine is compiled (" + built + " libraries, "
            + bindings + " bindings)", true);
        if (bindings > 0 && built < bindings / 2) {
            note("CAUTION: " + built + " libraries against " + bindings
                + " bindings - a partly built engine warns per missing library "
                + "and continues");
        }
    }
}

// ---------------------------------------------------------------- 3. REACHABLE
//
// THE QUESTION A TWO-PART CHECK DOES NOT ASK. Reproduce stzlib's own rule
// (core/common/stkRingLibs.ring: _stzDiscoverEngineDir) rather than trusting
// that a present, built engine is a found one.
function discoverEngineDir(startDir, exeFolder) {
    let dir = startDir.replace(/\\/g, "/");
    for (let depth = 1; depth <= 10; depth++) {
        for (const cand of [dir + "/engine", dir + "/libraries/stzlib/engine"]) {
            const probe = cand + "/zig-out/bin";
            if (fs.existsSync(probe + "/stz_string.dll")
             || fs.existsSync(probe + "/stz_sequence.dll")) return cand;
        }
        const last = dir.lastIndexOf("/");
        if (last < 2) break;
        dir = dir.slice(0, last);
    }
    return exeFolder.replace(/\\/g, "/") + "/../libraries/stzlib/engine";
}

if (!haveSource || built === 0) {
    skip("3 REACHABLE", "nothing to reach - question 1 or 2 says why");
} else {
    const exeFolder = path.dirname(RINGSERV);
    const found = discoverEngineDir(ROOT, exeFolder);
    const reachable = fs.existsSync(path.join(found, "zig-out", "bin",
        "stz_string.dll"))
        || fs.existsSync(path.join(found, "zig-out", "lib",
            "libstz_string" + EXT));

    if (!reachable) {
        skip("3 REACHABLE", "the engine is PRESENT AND BUILT and stzlib's own "
            + "discovery does NOT find it from " + ROOT + ". It resolved to "
            + found + ". Repair: start the process inside the stzlib checkout, "
            + "or place the engine where the rule looks. NOT a missing checkout "
            + "and NOT an unbuilt engine - a THIRD repair, and the one this "
            + "suite exists for");
        note("this is the state measured on the author's machine 2026-08-24: "
            + built + " libraries built, 80 'not found' warnings at run time");
    } else {
        check("3 REACHABLE  stzlib's own discovery finds the engine from this cwd",
            true);
        note("resolved to " + found);
    }

    // Whichever way that fell, the mechanism is ASSERTED rather than described:
    // the rule is anchored on the WORKING DIRECTORY, so the same machine gives
    // two different answers. A reader who does not believe the SKIP above is
    // shown both answers here.
    const fromRepo = discoverEngineDir(ROOT, exeFolder);
    const fromStz = discoverEngineDir(
        path.dirname(path.dirname(stzRoot)), exeFolder);
    check("...and the answer DEPENDS on the working directory, which is the finding",
        fromRepo !== fromStz,
        "from repo root: " + fromRepo + " | from stzlib: " + fromStz);
    note("from " + ROOT + " -> " + fromRepo);
    note("from " + path.dirname(path.dirname(stzRoot)) + " -> " + fromStz);
}

// ----------------------------------------------------------------- 4. LOADABLE
//
// Always runs. Needs no stzlib, and outranks all three above.
{
    const r = run('see "loadlib is absent" + nl\nloadlib("x")\n');
    const absent = /Calling Function without definition: loadlib/i.test(r.out);
    check("4 LOADABLE   RingServ declines native extensions - `loadlib` is ABSENT",
        absent, r.out.slice(0, 200));
    note("RING_NODLL=1 in build.zig. A single static binary that cannot load "
        + "arbitrary native code is the PROPERTY (docs/LOADING.md), not a defect");
    note("so with 1, 2 and 3 all green the profile still stops at `loadlib` - "
        + "measured 2026-08-24 with cwd inside the stzlib checkout: zero "
        + "warnings, then `Error (R3) : ... loadlib`");
}

// --------------------------------------------- 5. the record cannot drift back
//
// The profile's README carried "stzlib's Zig engine DLLs are not built on this
// machine" from 2026-08-20 until 2026-08-24, by which time they were. A stale
// premise in a document is read as a measurement, so it gets a gate rather
// than a correction -- the same shape as the readme phase-count gate.
{
    // Collapse whitespace FIRST. The sentence being gated is wrapped across a
    // line break in the file, so a naive regex passed here for the wrong
    // reason -- a gate that is green because it cannot see its subject is
    // worse than no gate, since it is read as evidence.
    const readme = fs.readFileSync(
        path.join(ROOT, "examples", "bangalo-server", "README.md"), "utf8")
        .replace(/\s+/g, " ");
    check("5 the README does not claim the engine is unbuilt (it was, then it was not)",
        !/engine DLLs are not built on this machine/i.test(readme),
        "that sentence was true on 08-20 and false on 08-24 - state the "
        + "REACHABILITY finding instead, which does not go stale");
    check("...and it names `loadlib` as the final boundary",
        /loadlib/i.test(readme),
        "the R3 on loadlib is what a reader actually hits once the engine resolves");
}

// ------------------------------------------------------------------------ exit
fs.rmSync(tmp, { recursive: true, force: true });
console.log("\n" + passed + " passed, " + failed + " failed, " + skipped + " skipped");
if (skipped) {
    console.log("A SKIP here is an ANSWER, not a gap: each one names which of "
        + "the four repairs this machine needs.");
}
process.exit(failed ? 1 : 0);
