/*
** The library search root — RINGSERV-LOADROOT-01, ruled DEPEND.
**
** A general Ring application server MAY require a Ring installation and
** need not carry its own search root. So RingServ FINDS one rather than
** shipping one, and this suite holds both halves of what that buys:
**
**   it buys   Ring's own libraries resolving by bare name, and their
**             `/../../libraries/...` dependencies with them;
**   it does   NOT make a library that needs a native extension RUN —
**             `loadlib` is absent by design (RING_NODLL), and the gate
**             asserts that boundary rather than letting someone discover
**             it.
**
** EVERY GATE HERE SKIPS when no Ring installation is on this machine.
** That is the point of the ruling: RingServ must build, run and pass its
** own suite with no Ring installed, and a suite that failed without one
** would have quietly turned MAY into MUST.
**
**   node tests/loadroot-gates.js
*/
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

let passed = 0, failed = 0, skipped = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}
function skip(name, why) {
    skipped++;
    console.log("SKIP  " + name + "  — " + why);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-loadroot-"));

/** Run a one-off program and return everything it said. */
function run(source, env) {
    const file = path.join(tmp, "p" + (run.n = (run.n || 0) + 1) + ".ring");
    fs.writeFileSync(file, source);
    const r = spawnSync(RINGSERV, ["run", file], {
        encoding: "utf8",
        env: { ...process.env, ...(env || {}) },
    });
    return { status: r.status, out: ((r.stdout || "") + (r.stderr || "")).trim() };
}

// ------------------------------------------------- is a Ring installed?
const where = spawnSync(RINGSERV, ["where"], { encoding: "utf8" });
const homeLine = /Ring home (.+)/.exec(where.stdout || "");
const HOME = homeLine && !/\(none/.test(homeLine[1]) ? homeLine[1].trim() : null;

check("`ringserv where` reports the search root either way",
    /Ring home/.test(where.stdout || ""), (where.stdout || "").slice(0, 200));

if (HOME === null) {
    skip("everything below", "no Ring installation found — the ruling makes that legal");
} else {
    check(`...and it names one (${HOME})`, fs.existsSync(HOME), HOME);

    // ---------------------------------------------- a library by bare name
    {
        const r = run('load "stdlibcore.ring"\nsee "loaded" + nl\n');
        check("a Ring library resolves by BARE NAME from the installation",
            /loaded/.test(r.out), r.out.slice(0, 200));
    }

    // The half that took the longest to find: a library's own dependencies
    // are written `/../../libraries/...`, relative to where IT lives. If the
    // anchor does not follow the file into the installation, they resolve
    // against the application and miss.
    {
        const r = run('load "stdlib.ring"\nsee "ran" + nl\n');
        check("a library's OWN `/../../` dependencies resolve too",
            !/libraries[\\/]stdlib/.test(r.out),
            "still failing inside the graph: " + r.out.slice(0, 200));
        check("...and the graph stops exactly at `loadlib`, as designed",
            /loadlib/.test(r.out),
            "expected the RING_NODLL boundary, got: " + r.out.slice(0, 200));
    }

    // -------------------------------------------- the explicit override
    {
        const r = run('load "stdlibcore.ring"\nsee "loaded" + nl\n',
            { RINGSERV_RING_HOME: HOME });
        check("RINGSERV_RING_HOME is honoured", /loaded/.test(r.out), r.out.slice(0, 160));
    }
    {
        const r = run('load "stdlibcore.ring"\nsee "loaded" + nl\n',
            { RINGSERV_RING_HOME: path.join(tmp, "nowhere") });
        check("...and a wrong one is not silently ignored",
            !/loaded/.test(r.out), r.out.slice(0, 160));
    }

    // ------------------------------- the application always wins
    //
    // The rule that keeps this safe: the installation is consulted ONLY
    // after the ordinary answer has failed, so a library upgrade can never
    // take over a name the author owns.
    {
        const dir = path.join(tmp, "own");
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, "stdlibcore.ring"),
            'see "MINE" + nl\n');
        fs.writeFileSync(path.join(dir, "app.ring"),
            'load "stdlibcore.ring"\n');
        // Run FROM that directory: docs/LOADING.md records that a bare
        // `load` in the application file anchors to the process working
        // directory, so that is where an application's own library lives
        // as far as this rule is concerned.
        const r = spawnSync(RINGSERV, ["run", "app.ring"],
            { encoding: "utf8", cwd: dir });
        check("an application's OWN file of the same name wins",
            /MINE/.test((r.stdout || "") + (r.stderr || "")),
            ((r.stdout || "") + (r.stderr || "")).slice(0, 160));
    }

    // A path the AUTHOR wrote with a directory in it is never satisfied
    // from the installation — `load "mylib/util.ring"` means their file.
    {
        const r = run('load "nosuchdir/stdlibcore.ring"\nsee "loaded" + nl\n');
        check("a directory-qualified path is NOT rescued by the installation",
            !/loaded/.test(r.out), r.out.slice(0, 160));
    }
}

try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped`);
process.exit(failed ? 1 : 0);
