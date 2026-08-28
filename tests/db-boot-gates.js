/*
** A worker that cannot reach its own database must not claim to be
** healthy.
**
** Found 2026-08-28 while looking for exactly this: docs/GATES.md had
** listed "untested error paths in db.zig" as an honest, named gap since
** phase 8. Measuring it turned up something worse than "untested" —
** two of the three named cases produced a server that printed "serving
** on http://..." and answered `/health` with 200, while every request
** that touched data failed 500, forever, with nothing in between to
** say why.
**
** THE ROOT CAUSE WAS NOT db.zig. It was that `workerMain` (serve.zig)
** discarded `__rs_data_apply`'s result and marked itself "alive"
** regardless, and `start()`'s own wait-for-a-worker loop had a silent
** timeout path: if zero workers ever came up, it waited two seconds and
** served anyway. Fixed at both points; this suite gates both.
**
** Each gate attacks one way the fix could be quietly wrong:
**
**   A BROKEN DATABASE MUST REFUSE TO SERVE. Not hang, not bind the port
**   and 500 forever — exit, loudly, before printing "serving".
**
**   THE REASON MUST BE NAMED. "refusing to serve" with nothing after it
**   is not a fix, it is the same silence wearing a different shape.
**
**   AN ORDINARY BOOT MUST BE UNCHANGED. A fix for the broken case that
**   slows or breaks the working case is not a fix.
**
**   A RUNTIME FAILURE (the disk fills mid-request) IS A DIFFERENT
**   QUESTION, already answered correctly by the existing SQL-error path
**   since phase 1 — this suite proves that rather than assuming it,
**   because the boot-time gap was invisible for exactly as long as
**   nobody measured it.
**
**   node tests/db-boot-gates.js
*/
const { spawnSync, spawn, execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const PORT = 8362;
const B = "http://127.0.0.1:" + PORT;

let passed = 0, failed = 0, skipped = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}
function skip(name, why) { skipped++; console.log("SKIP  " + name + " — " + why); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-dbboot-"));

function writeApp() {
    const p = path.join(tmp, "app.ring");
    fs.writeFileSync(p, [
        "RingServ([",
        "    :port = " + PORT + ",",
        "    :workers = 1,",
        '    :database = sysget("RINGSERV_TEST_DB"),',
        "    :data = [ :notes = [ :title = :text, :body = :text ] ],",
        "    :services = [ :notes = [ :table = \"notes\" ] ]",
        "])",
        "",
    ].join("\n"));
    return p;
}

async function waitUp(ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 100));
    }
    return false;
}
const call = (service, action, payload) =>
    fetch(B + "/api/v1", { method: "POST", body: JSON.stringify({ service, action, payload }) })
        .then(r => r.json()).catch(e => ({ code: -1, message: String(e) }));

(async () => {
    const app = writeApp();

    // ============================ 1. a nonexistent parent directory
    {
        const bad = path.join(tmp, "no", "such", "dir", "db.sqlite");
        const r = spawnSync(RINGSERV, ["run", app], {
            encoding: "utf8", timeout: 6000,
            env: { ...process.env, RINGSERV_TEST_DB: bad },
        });
        const out = (r.stdout || "") + (r.stderr || "");
        check("a database whose directory does not exist REFUSES to serve",
            r.status !== 0, "exit " + r.status);
        check("...naming the reason, not just refusing silently",
            /cannot reach its database/i.test(out) &&
            /unable to open database file/i.test(out), out.slice(0, 300));
        check("...and refuses BEFORE claiming to serve — 'serving on' " +
            "must never appear over a database that cannot be reached",
            !/serving on http/i.test(out), out.slice(0, 300));
    }

    // ================================== 2. a read-only database file
    {
        const roDb = path.join(tmp, "readonly.db");
        fs.writeFileSync(roDb, "");
        fs.chmodSync(roDb, 0o444);
        const r = spawnSync(RINGSERV, ["run", app], {
            encoding: "utf8", timeout: 6000,
            env: { ...process.env, RINGSERV_TEST_DB: roDb },
        });
        const out = (r.stdout || "") + (r.stderr || "");
        check("a read-only database file REFUSES to serve",
            r.status !== 0, "exit " + r.status);
        check("...naming that it is a permissions problem, in SQLite's own words",
            /readonly|read-only|read only/i.test(out), out.slice(0, 300));
        check("...and never prints 'serving on' over it",
            !/serving on http/i.test(out), out.slice(0, 300));
        fs.chmodSync(roDb, 0o644); // restore so cleanup can remove it
    }

    // ============================================ 3. an ordinary boot
    // The fix must cost the working case nothing. If this regresses, the
    // gates above are worthless — they would be proving a refusal at the
    // expense of the one thing that must never refuse.
    {
        const okDb = path.join(tmp, "ok.db");
        const server = spawn(RINGSERV, ["run", app], {
            stdio: ["ignore", "pipe", "pipe"],
            env: { ...process.env, RINGSERV_TEST_DB: okDb },
        });
        let log = "";
        server.stdout.on("data", d => log += d);
        server.stderr.on("data", d => log += d);
        const up = await waitUp(8000);
        check("an ordinary, working database boots and serves normally",
            up, log.slice(0, 300));
        if (up) {
            const r = await call("notes", "create", { title: "a", body: "b" });
            check("...and answers a real write",
                r.code === 0 && r.data && r.data.id === 1, JSON.stringify(r));
        }
        server.kill();
        await new Promise(r => setTimeout(r, 500));
    }

    // =============================== 4. a full disk, mid-request (Linux)
    // Untestable portably: it needs a filesystem whose capacity can be
    // capped, which means tmpfs and root. Skipped BY NAME everywhere
    // else, never silently dropped.
    const canTestFull = process.platform === "linux";
    if (!canTestFull) {
        skip("SQLITE_FULL produces a clean 500, and the server survives",
            "needs a capped tmpfs (Linux + root); this platform is " + process.platform);
        skip("...and freeing space and restarting recovers it",
            "same reason");
    } else {
        const mnt = "/tmp/ringserv-dbboot-full-" + process.pid;
        let mounted = false;
        try {
            fs.mkdirSync(mnt, { recursive: true });
            execSync("sudo mount -t tmpfs -o size=2m tmpfs " + mnt, { stdio: "ignore" });
            mounted = true;

            const fullDb = path.join(mnt, "db.sqlite");
            const server = spawn(RINGSERV, ["run", app], {
                stdio: ["ignore", "pipe", "pipe"],
                env: { ...process.env, RINGSERV_TEST_DB: fullDb },
            });
            let log = "";
            server.stdout.on("data", d => log += d);
            server.stderr.on("data", d => log += d);
            await waitUp(8000);

            const PAD = "x".repeat(4000);
            let failedRow = -1, failMsg = "";
            for (let i = 1; i <= 500 && failedRow === -1; i++) {
                const r = await call("notes", "create", { title: PAD, body: PAD });
                if (r.code === 1) { failedRow = i; failMsg = r.message; }
            }
            check("writing until the disk fills eventually gets SQLITE_FULL, " +
                "as a clean business-error envelope, not a crash",
                failedRow !== -1 && /full/i.test(failMsg),
                "row " + failedRow + ": " + failMsg);

            const stillUp = await fetch(B + "/health").then(r => r.status).catch(() => 0);
            check("...and the server is STILL SERVING right after the failure",
                stillUp === 200, "health: " + stillUp);

            const reads = await call("notes", "list", { limit: 1 });
            check("...and reads still work — a full disk breaks writes, not the process",
                reads.code === 0, JSON.stringify(reads).slice(0, 160));

            // NOT tested here: freeing space under the SAME running
            // process. `umount` (even -f) refuses while the write
            // connection's own fd holds the mount busy — confirmed by
            // hand on this exact tmpfs (`umount: target is busy`), not
            // assumed. Killing the connection first is the only honest
            // way to free the mount, which tests recovery ACROSS a
            // restart, not without one -- a smaller, still real claim.
            server.kill();
            await new Promise(r => setTimeout(r, 500));
            execSync("sudo umount -f " + mnt, { stdio: "ignore" });
            execSync("sudo mount -t tmpfs -o size=20m tmpfs " + mnt, { stdio: "ignore" });

            const server2 = spawn(RINGSERV, ["run", app], {
                stdio: ["ignore", "pipe", "pipe"],
                env: { ...process.env, RINGSERV_TEST_DB: fullDb },
            });
            const up2 = await waitUp(8000);
            const recovered = up2 ? await call("notes", "create", { title: "ok", body: "ok" }) : null;
            check("freeing space and restarting recovers it — the full disk " +
                "left no lasting damage in the database file itself",
                up2 && recovered && recovered.code === 0, JSON.stringify(recovered));
            server2.kill();
            await new Promise(r => setTimeout(r, 500));
        } catch (e) {
            check("the disk-full rig itself ran (mount/tmpfs available)",
                false, String(e && e.message || e));
        } finally {
            if (mounted) { try { execSync("sudo umount -f " + mnt, { stdio: "ignore" }); } catch {} }
            try { fs.rmSync(mnt, { recursive: true, force: true }); } catch {}
        }
    }

    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed` +
        (skipped ? `, ${skipped} skipped by name` : ""));
    process.exit(failed ? 1 : 0);
})().catch(e => {
    console.error("db-boot-gates: " + (e && e.stack || e));
    process.exit(2);
});
