/*
** `dev`'s child must not outlive an ABRUPTLY killed `dev`.
**
** docs/GATES.md had carried this as a named, honest gap since phase 4:
** "dev's child can outlive its parent when the parent is killed
** abruptly (the CLI gates kill the tree explicitly to compensate)."
** Reproduced by hand before fixing it, on Windows and on Linux: kill
** ONLY the `dev` process and its child `ringserv run` kept serving,
** kept answering /health 200, and kept holding the port -- forever.
**
** WHY THE ORDINARY PATH NEVER SHOWED IT. Ctrl-C, a clean SIGTERM, and
** the CLI gates' own `killTree` all take the child down already. The
** gap is only reachable when NO userspace code in `dev` gets to run:
** SIGKILL, or `taskkill /F` without `/T`. That is exactly the case a
** crash, an OOM kill, or an impatient operator produces, so "it works
** when you exit politely" was never the claim worth gating.
**
** TWO MECHANISMS, because no single one is portable:
**
**   WINDOWS -- a Job Object with KILL_ON_JOB_CLOSE. The OS kills the
**   child when this process's handle closes, which Windows does on ANY
**   exit, including one nothing in the process could have caught.
**
**   POSIX -- the CHILD watches for the original parent's death itself
**   (prctl PR_SET_PDEATHSIG on Linux; a polling thread elsewhere).
**
** The gate below asserts the OUTCOME, not the mechanism, so it holds on
** whichever platform it runs on and would catch either half breaking.
**
** AND IT GATES THE OTHER DIRECTION TOO, which is the half a careless
** fix would break: a bare `ringserv run` must KEEP serving when the
** shell that started it goes away. That is the normal, supported way to
** run RingServ as a daemon. The guard is armed by an environment
** variable `dev` sets, precisely so it cannot fire for anyone else --
** and this suite proves that rather than trusting it.
**
**   node tests/devorphan-gates.js
*/
const { spawn, spawnSync, execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const IS_WIN = process.platform === "win32";
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    IS_WIN ? "ringserv.exe" : "ringserv");
const PORT = 8392;
const B = "http://127.0.0.1:" + PORT;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function health(timeoutMs = 1500) {
    try {
        const ctl = AbortSignal.timeout(timeoutMs);
        return (await fetch(B + "/health", { signal: ctl })).status;
    } catch { return 0; }
}
async function waitUp(ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
        if (await health() === 200) return true;
        await sleep(150);
    }
    return false;
}

/// The child `ringserv` process of a given pid, or 0. Deliberately does
/// NOT use the CLI gates' killTree: this suite must observe the child
/// independently of any mechanism that also kills it.
function childPidOf(parentPid) {
    if (IS_WIN) {
        const r = spawnSync("powershell", ["-NoProfile", "-Command",
            `(Get-CimInstance Win32_Process -Filter "ParentProcessId=${parentPid}" | ` +
            `Where-Object { $_.Name -eq 'ringserv.exe' } | Select-Object -First 1).ProcessId`],
            { encoding: "utf8" });
        return parseInt((r.stdout || "").trim(), 10) || 0;
    }
    const r = spawnSync("pgrep", ["-P", String(parentPid)], { encoding: "utf8" });
    return parseInt((r.stdout || "").trim().split("\n")[0], 10) || 0;
}

function isAlive(pid) {
    if (!pid) return false;
    if (IS_WIN) {
        const r = spawnSync("powershell", ["-NoProfile", "-Command",
            `if (Get-Process -Id ${pid} -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }`],
            { encoding: "utf8" });
        return (r.stdout || "").trim() === "yes";
    }
    try { process.kill(pid, 0); return true; } catch { return false; }
}

/// An ABRUPT kill of one process only — never the tree. That distinction
/// IS the gate: killing the tree would pass no matter what the fix does.
function killOnlyAbruptly(pid) {
    if (IS_WIN) spawnSync("taskkill", ["/PID", String(pid), "/F"], { stdio: "ignore" });
    else { try { process.kill(pid, "SIGKILL"); } catch {} }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-devorphan-"));

(async () => {
    fs.writeFileSync(path.join(tmp, "app.ring"),
        `RingServ([ :port = ${PORT}, ` +
        `:services = [ :hi = [ :go = func aReq { return Reply(:ok, 1) } ] ] ])\n`);

    // ================== 1. an abruptly killed `dev` takes its child down
    {
        const dev = spawn(RINGSERV, ["dev", path.join(tmp, "app.ring")], {
            stdio: ["ignore", "pipe", "pipe"], cwd: tmp,
        });
        let log = "";
        dev.stdout.on("data", d => log += d);
        dev.stderr.on("data", d => log += d);

        const up = await waitUp(20000);
        check("dev serves the app", up, log.slice(0, 300));

        const kid = childPidOf(dev.pid);
        check("...through a child `run` process, which is what makes " +
            "orphaning possible at all", kid !== 0, "no child found");

        if (up && kid) {
            killOnlyAbruptly(dev.pid);
            await sleep(3000);

            check("the abruptly-killed dev is gone", !isAlive(dev.pid));
            check("THE CHILD DIED WITH IT — no orphan left serving",
                !isAlive(kid), "child pid " + kid + " is still alive");
            check("...and the port is free again, not held by a ghost",
                await health() !== 200);
        }
        // Belt and braces: if the gate above FAILED, do not leak the
        // orphan into the rest of the run.
        if (kid && isAlive(kid)) killOnlyAbruptly(kid);
        if (isAlive(dev.pid)) killOnlyAbruptly(dev.pid);
        await sleep(500);
    }

    // ============ 2. a bare `run` is NOT affected — the other direction
    //
    // The guard is armed only by an environment variable `dev` sets. If
    // that ever stops being true, every `ringserv run` started from a
    // shell would die when the shell closed — breaking the ordinary way
    // to run RingServ as a daemon. Cheap to assert, expensive to miss.
    {
        const srv = spawn(RINGSERV, ["run", path.join(tmp, "app.ring")], {
            stdio: ["ignore", "pipe", "pipe"], cwd: tmp,
            detached: !IS_WIN,
        });
        let log = "";
        srv.stdout.on("data", d => log += d);
        srv.stderr.on("data", d => log += d);

        const up = await waitUp(20000);
        check("a bare `run` serves", up, log.slice(0, 300));
        if (up) {
            // It has no `dev` parent to lose, so the only claim that can
            // be made here is that it did not arm a guard against THIS
            // process and shut itself down. Give it real time to do the
            // wrong thing before concluding it did not.
            await sleep(3000);
            check("...and is STILL serving — the orphan guard is armed by " +
                "`dev` alone, never by a plain `run`", await health() === 200);
        }
        try { srv.kill("SIGKILL"); } catch {}
        if (IS_WIN) spawnSync("taskkill", ["/PID", String(srv.pid), "/T", "/F"], { stdio: "ignore" });
        await sleep(500);
    }

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(e => {
    console.error("devorphan-gates: " + (e && e.stack || e));
    process.exit(2);
});
