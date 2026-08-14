/*
** Phase-4 gates: the CLI as a developer meets it —
** new → test → dev → edit → reload, with nothing installed.
**
** Usage: node tests/cli-gates.js
*/
const { spawn, spawnSync, execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(url, ms) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
        try { const r = await fetch(url); if (r.status === 200) return r; } catch {}
        await sleep(250);
    }
    return null;
}

function killTree(child) {
    if (!child || child.exitCode !== null) return;
    try {
        if (process.platform === "win32") {
            // dev spawns a child `run`; /T takes the whole tree.
            spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
        } else {
            process.kill(-child.pid, "SIGKILL");
        }
    } catch {}
}

(async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-cli-"));
    const appDir = path.join(tmp, "demo");
    let dev = null;
    try {
        // ------------------------------------------------------- new
        let r = spawnSync(RINGSERV, ["new", "demo"], { cwd: tmp, encoding: "utf8" });
        check("new exits cleanly", r.status === 0, r.stderr);
        check("new writes app.ring", fs.existsSync(path.join(appDir, "app.ring")));
        check("new writes the page", fs.existsSync(path.join(appDir, "public", "index.html")));
        check("new writes tests", fs.existsSync(path.join(appDir, "tests", "app.ring")));
        check("the app name reached the templates",
            fs.readFileSync(path.join(appDir, "app.ring"), "utf8").includes("demo") &&
            !fs.readFileSync(path.join(appDir, "app.ring"), "utf8").includes("__APPNAME__"));

        r = spawnSync(RINGSERV, ["new", "demo"], { cwd: tmp, encoding: "utf8" });
        check("new refuses to overwrite an existing folder", r.status !== 0);

        // ------------------------------------------------------ test
        r = spawnSync(RINGSERV, ["test"], { cwd: appDir, encoding: "utf8" });
        check("the scaffold's own tests pass", r.status === 0 &&
            /All \d+ expectations passed/.test(r.stdout), r.stdout + r.stderr);
        check("test uses a scratch database (no file written)",
            !fs.existsSync(path.join(appDir, "demo.db")), "demo.db was created by test");

        // A failing expectation must actually fail the run — a test
        // runner that cannot fail is decoration.
        fs.writeFileSync(path.join(appDir, "tests", "zz-failing.ring"),
            'aReply = Ask(:hello, :greet, [ :name = "x" ])\n' +
            'Expect("deliberately wrong", aReply[:data][:message], "nope")\n');
        r = spawnSync(RINGSERV, ["test"], { cwd: appDir, encoding: "utf8" });
        check("a failing expectation fails the run", r.status !== 0 &&
            /FAILED/.test(r.stdout), r.stdout);
        fs.unlinkSync(path.join(appDir, "tests", "zz-failing.ring"));

        // An erroring test file is reported, not silently skipped.
        fs.writeFileSync(path.join(appDir, "tests", "zz-error.ring"), "nosuchfunction()\n");
        r = spawnSync(RINGSERV, ["test"], { cwd: appDir, encoding: "utf8" });
        check("an erroring test file fails the run", r.status !== 0, r.stdout);
        fs.unlinkSync(path.join(appDir, "tests", "zz-error.ring"));

        // ------------------------------------------------------- dev
        dev = spawn(RINGSERV, ["dev"], {
            cwd: appDir, stdio: ["ignore", "pipe", "pipe"],
            detached: process.platform !== "win32",
        });
        let devOut = "";
        dev.stdout.on("data", d => { devOut += d; });
        dev.stderr.on("data", d => { devOut += d; });

        let res = await waitFor("http://127.0.0.1:8080/health", 25000);
        check("dev serves the app", res !== null);

        res = await fetch("http://127.0.0.1:8080/");
        const html = await res.text();
        check("dev serves the scaffold page", res.status === 200 &&
            html.includes("<!doctype html>") && html.includes("demo"));

        let api = await fetch("http://127.0.0.1:8080/api/v1", {
            method: "POST",
            body: JSON.stringify({ service: "hello", action: "greet", payload: { name: "Mansour" } }),
        });
        let body = await api.json();
        check("dev answers the API", body.code === 0 &&
            body.data.message === "Ahlan, Mansour!", JSON.stringify(body));

        api = await fetch("http://127.0.0.1:8080/api/v1", {
            method: "POST",
            body: JSON.stringify({ service: "notes", action: "create", payload: { title: "via dev" } }),
        });
        body = await api.json();
        check("the scaffold's generic CRUD works over HTTP", body.code === 0 &&
            typeof body.data.id === "number", JSON.stringify(body));

        // ------------------------------------------------ edit → reload
        const appFile = path.join(appDir, "app.ring");
        const edited = fs.readFileSync(appFile, "utf8")
            .replace('"Ahlan, " + cName + "!"', '"Marhaba, " + cName + "!"');
        fs.writeFileSync(appFile, edited);

        let reloaded = false;
        const t0 = Date.now();
        while (Date.now() - t0 < 30000) {
            await sleep(500);
            try {
                const a = await fetch("http://127.0.0.1:8080/api/v1", {
                    method: "POST",
                    body: JSON.stringify({ service: "hello", action: "greet", payload: { name: "Mansour" } }),
                });
                const b = await a.json();
                if (b.data && b.data.message === "Marhaba, Mansour!") { reloaded = true; break; }
            } catch {}
        }
        check("dev reloads on save", reloaded, devOut.slice(-400));

        // ------------------------------------------------ where/version
        r = spawnSync(RINGSERV, ["where"], { cwd: appDir, encoding: "utf8" });
        check("where reports the versions inside", r.status === 0 &&
            /RingServ/.test(r.stdout) && /SQLite/.test(r.stdout) && /Ring VM/.test(r.stdout),
            r.stdout);
    } finally {
        killTree(dev);
        await sleep(500);
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    }
    console.log(failed === 0
        ? "\nAll " + passed + " CLI gates passed."
        : "\n" + failed + " gate(s) FAILED (" + passed + " passed).");
    process.exit(failed ? 1 : 0);
})().catch(e => { console.error("harness crashed:", e); process.exit(1); });
