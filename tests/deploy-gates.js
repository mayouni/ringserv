/*
** Phase-20 gates: deploy and redeploy.
**
** The promise is that putting an application up, and putting a CHANGE up,
** each cost one command — and that the second one can never eat the first
** one's data. Each gate attacks a way that could be quietly false:
**
**   THE DATA IS SOMEWHERE A CODE CHANGE CANNOT REACH. A deployment keeps
**   the record in `.ringserv/`, and redeploy replaces everything else
**   wholesale. The gate writes a row, redeploys DIFFERENT code, and reads
**   the row back — because "we are careful about the data directory" is a
**   promise, and "the code lives somewhere else entirely" is a property.
**
**   REDEPLOY MAKES THE CHANGE LIVE. Replacing files under a running
**   server that never re-reads them is a change nobody can see. A
**   redeploy of a running deployment reloads it, and the gate asks the
**   SERVER, not the filesystem.
**
**   DEPLOY REFUSES TO OVERWRITE. `deploy` and `redeploy` are different
**   words because they are different risks; a deploy that quietly
**   replaced a live one would make them the same word.
**
**   THE DEVELOPER'S SCRATCH DATABASE DOES NOT SHIP. A .db sitting beside
**   the source is test data, and installing test data as production data
**   is a mistake nobody recovers from quickly.
**
**   THE PANEL SEES IT WITH NOTHING TAUGHT TO THE PANEL. The layout is
**   `<name>/app.ring`, which the panel already scans — asserted, because
**   "it happens to fit" is exactly the kind of claim that stops being
**   true in a refactor nobody connected to it.
**
**   node tests/deploy-gates.js
*/
const { spawnSync, spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const PORT = 8252;
const B = "http://127.0.0.1:" + PORT;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-deploy-"));
const SRC = path.join(tmp, "src");
const ROOTDIR = path.join(tmp, "deployments");
let server = null;

/** An application with one table and one action that names its build. */
function writeSource(build) {
    fs.mkdirSync(SRC, { recursive: true });
    fs.mkdirSync(path.join(SRC, "public"), { recursive: true });
    fs.writeFileSync(path.join(SRC, "public", "index.html"), "<p>hello</p>\n");
    fs.writeFileSync(path.join(SRC, "app.ring"), [
        "RingServ([",
        "    :port = " + PORT + ",",
        "    :workers = 2,",
        '    :database = "notes.db",',
        "    :data = [ :notes = [ :title = :text ] ],",
        "    :services = [",
        '        :notes = [ :table = "notes" ],',
        "        :build = [",
        '            :which = func aReq { return Reply(:ok, [ :build = "' + build + '" ]) }',
        "        ]",
        "    ]",
        "])",
        "",
    ].join("\n"));
}

function ringserv(args, cwd) {
    const r = spawnSync(RINGSERV, args, { encoding: "utf8", cwd: cwd || tmp });
    return { out: (r.stdout || "") + (r.stderr || ""), status: r.status };
}

const call = (service, action, payload = {}) =>
    fetch(B + "/api/v1", { method: "POST", body: JSON.stringify({ service, action, payload }) })
        .then(r => r.json());

async function waitUp() {
    for (let i = 0; i < 120; i++) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
async function stopServer() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 700));
}

(async () => {
    writeSource("v1");
    // A scratch database beside the source, exactly as a developer's tree
    // looks after one `ringserv run`.
    fs.writeFileSync(path.join(SRC, "notes.db"), "SCRATCH-NOT-FOR-PRODUCTION");

    // ======================================================= 1. deploy
    {
        const r = ringserv(["deploy", SRC, "--as", "notes", "--port", String(PORT),
            "--root", ROOTDIR]);
        check("one command deploys an application", r.status === 0, r.out.slice(0, 200));

        const dir = path.join(ROOTDIR, "notes");
        check("...as a named directory", fs.existsSync(dir));
        check("...with the code at the top", fs.existsSync(path.join(dir, "app.ring")) &&
            fs.existsSync(path.join(dir, "public", "index.html")));
        check("...and a private corner for everything it will write",
            fs.existsSync(path.join(dir, ".ringserv", "data")) &&
            fs.existsSync(path.join(dir, ".ringserv", "deployment.yaml")));

        // The layout IS the panel's layout. Asserted rather than assumed:
        // "it happens to fit" stops being true in a refactor nobody
        // connected to it.
        check("...in the shape `ringserv panel` already scans — <name>/app.ring",
            fs.existsSync(path.join(ROOTDIR, "notes", "app.ring")));

        check("the developer's scratch database is NOT deployed",
            !fs.existsSync(path.join(dir, "notes.db")),
            "notes.db was copied into the deployment");

        const man = fs.readFileSync(path.join(dir, ".ringserv", "deployment.yaml"), "utf8");
        check("the manifest records the port and where it came from",
            /port:\s*8252/.test(man) && man.includes("source:"), man.slice(0, 160));
    }

    // ============================================ 2. deploy refuses twice
    {
        const r = ringserv(["deploy", SRC, "--as", "notes", "--root", ROOTDIR]);
        check("deploying the same name again is REFUSED, not silently done",
            r.status !== 0, String(r.status));
        check("...and the refusal names the verb that IS right",
            /redeploy notes/.test(r.out), r.out.slice(0, 160));
    }

    // ================================================= 3. run it, write data
    const dataDir = path.join(ROOTDIR, "notes", ".ringserv", "data");
    {
        server = spawn(RINGSERV, ["run", path.join(ROOTDIR, "notes", "app.ring"),
            "--port", String(PORT), "--data", dataDir],
            { stdio: ["ignore", "ignore", "ignore"] });
        check("the deployment runs", await waitUp());

        const made = await call("notes", "create", { title: "written before the redeploy" });
        check("...and accepts a write", made.code === 0, JSON.stringify(made).slice(0, 120));
        check("the database landed in the private corner, NOT beside the code",
            fs.existsSync(path.join(dataDir, "notes.db")) &&
            !fs.existsSync(path.join(ROOTDIR, "notes", "notes.db")));

        const v = await call("build", "which");
        check("it answers with the code that was deployed",
            v.data && v.data.build === "v1", JSON.stringify(v));
    }

    // ============================== 4. redeploy: new code, same data, live
    {
        writeSource("v2");
        const r = ringserv(["redeploy", "notes", "--root", ROOTDIR]);
        check("one command redeploys it", r.status === 0, r.out.slice(0, 200));
        check("...and says the data was not touched",
            /data untouched/i.test(r.out), r.out.slice(0, 160));
        check("...and reloads the RUNNING server, without being asked twice",
            /reloaded it live/i.test(r.out), r.out.slice(0, 200));

        // Ask the SERVER, not the filesystem: replacing files under a
        // process that never re-reads them is a change nobody can see.
        const v = await call("build", "which");
        check("the running server now answers with the NEW code",
            v.data && v.data.build === "v2", JSON.stringify(v));

        const rows = await call("notes", "list", {});
        check("...and the row written BEFORE the redeploy is still there",
            rows.data && rows.data.count === 1, JSON.stringify(rows).slice(0, 140));
        check("...because the record never lived where the code lives",
            fs.existsSync(path.join(dataDir, "notes.db")));
    }

    // ===================================== 5. ls tells the truth, quietly
    {
        const r = ringserv(["ls", "--root", ROOTDIR]);
        check("`ls` lists the deployment", /notes/.test(r.out), r.out.slice(0, 200));
        check("...saying it is running, because it asked the port",
            /running/.test(r.out), r.out.slice(0, 200));
        // A listing that prints a diagnostic per row is a listing nobody
        // reads. This one leaked `got 74: {...}` until it was measured.
        check("...and prints nothing else — no probe chatter in a table",
            !/got \d+:/.test(r.out) && !/malformed/.test(r.out), r.out.slice(0, 200));

        await stopServer();
        const r2 = ringserv(["ls", "--root", ROOTDIR]);
        check("...and says `stopped` once it is stopped",
            /stopped/.test(r2.out), r2.out.slice(0, 200));
    }

    // ============================ 6. redeploy refuses what it cannot do
    {
        const r = ringserv(["redeploy", "nosuchthing", "--root", ROOTDIR]);
        check("redeploying something that was never deployed is refused by name",
            r.status !== 0 && /not a deployment/.test(r.out), r.out.slice(0, 160));
        check("...and points at the verb that would create it",
            /ringserv deploy/.test(r.out), r.out.slice(0, 200));
    }

    // ============================ 7. the panel starts it the way it says
    // THE BRIDGE, and it is not cosmetic: a deployment started without its
    // own port and its own data directory binds a port nobody expects and
    // writes the database beside the code, where the NEXT REDEPLOY deletes
    // it. The panel would become a second, quieter way to lose the record.
    {
        const panelPort = 8081;
        const panelProc = spawn(RINGSERV, ["panel", ROOTDIR, "--port", String(panelPort)],
            { stdio: ["ignore", "ignore", "ignore"] });
        const P = "http://127.0.0.1:" + panelPort;
        let up = false;
        for (let i = 0; i < 100; i++) {
            try { if ((await fetch(P + "/health")).status === 200) { up = true; break; } } catch {}
            await new Promise(r => setTimeout(r, 150));
        }
        check("the panel comes up over the deployments root", up);

        const st = await (await fetch(P + "/panel/state")).json();
        const row = (st.apps || []).find(a => a.name === "notes");
        check("the panel sees the deployment with NO configuration",
            !!row, JSON.stringify(st.apps));
        check("...on the port the MANIFEST records, not one guessed from the source",
            !!row && row.port === PORT, row && String(row.port));

        await fetch(P + "/panel/start", { method: "POST", body: JSON.stringify({ name: "notes" }) });
        let serving = false;
        for (let i = 0; i < 100; i++) {
            try { if ((await fetch(B + "/health")).status === 200) { serving = true; break; } } catch {}
            await new Promise(r => setTimeout(r, 150));
        }
        check("...and starting it from the panel serves on the deployed port", serving);
        check("...with the database in the deployment's private corner, " +
            "never beside the code a redeploy deletes",
            fs.existsSync(path.join(dataDir, "notes.db")) &&
            !fs.existsSync(path.join(ROOTDIR, "notes", "notes.db")));

        await fetch(P + "/panel/stop", { method: "POST", body: JSON.stringify({ name: "notes" }) });
        await new Promise(r => setTimeout(r, 800));
        panelProc.kill();
        await new Promise(r => setTimeout(r, 400));
    }

    await stopServer();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("deploy-gates: " + (e && e.stack || e));
    await stopServer();
    process.exit(2);
});
