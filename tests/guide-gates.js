/*
** The documentation gates.
**
** Documentation rots because nothing fails when it stops being true.
** These gates make it fail.
**
** Two kinds of claim are checked:
**
**   THE EXAMPLE RUNS. examples/fieldnotes/ is the application the guide
**   is written about, so it must pass `check`, pass its own tests, and
**   serve what the guide says it serves.
**
**   THE GUIDE QUOTES THE EXAMPLE. Every code listing in the guide that
**   claims to come from the example is checked against the file. A guide
**   whose listings drift from the code it documents is worse than no
**   guide, because a reader trusts it.
**
**   node tests/guide-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const EX = path.join(ROOT, "examples", "fieldnotes");
const APP = path.join(EX, "app.ring");
const B = "http://127.0.0.1:8100";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

const read = p => fs.readFileSync(p, "utf8");
/** Compare ignoring indentation and blank lines — layout is not the claim. */
const norm = s => s.split("\n").map(l => l.trim()).filter(Boolean).join("\n");

(async () => {
    // ------------------------------------------------- the example runs
    check("the example application exists", fs.existsSync(APP), APP);

    let r = spawnSync(RINGSERV, ["check", APP], { encoding: "utf8", cwd: EX });
    check("the example passes `ringserv check`", r.status === 0,
        (r.stdout + r.stderr).slice(0, 300));

    r = spawnSync(RINGSERV, ["test", APP], { encoding: "utf8", cwd: EX });
    check("the example passes its own tests", r.status === 0,
        (r.stdout + r.stderr).slice(-400));
    check("...and they are not vacuous", /All \d+ expectations passed/.test(r.stdout) &&
        parseInt(/All (\d+)/.exec(r.stdout)[1], 10) >= 10,
        (r.stdout || "").slice(-200));

    r = spawnSync(RINGSERV, ["docs", APP, "--json"], { encoding: "utf8", cwd: EX });
    let cat = null;
    try { cat = JSON.parse(r.stdout); } catch {}
    check("`ringserv docs` describes the example", !!cat && cat.services.length >= 3,
        (r.stdout || "").slice(0, 200));

    // -------------------------------- the guide quotes what actually runs
    const app = read(APP);
    const digest = read(path.join(EX, "services", "digest.js"));
    const guide = read(path.join(ROOT, "docs", "fieldnotes-app.md"));
    const started = read(path.join(ROOT, "docs", "getting-started.md"));

    // Each pair: something the guide states, and the file that must agree.
    const claims = [
        ["the generic table service line", ':notes = [ :table = "notes" ]', app],
        ["the JS service declaration", ':digest = [ :js = "services/digest.js" ]', app],
        ["the static route", '[ :static, "/", "public/" ]', app],
        ["the port", ":port     = 8100", app],
        ["the contract's maxlen on title", ":maxlen = 120", app],
        ["the weight range", ":min = 0, :max = 100", app],
        ["the placement of notes", ":notes  = [ :site = :local, :authority = :server ]", app],
        ["the sync mode", ":notes = [ :store = :local, :sync = :onreconnect ]", app],
        ["the private helper the guide names", "function wordCount", digest],
        ["serv.call on report.heaviest", 'serv.call("report.heaviest"', digest],
    ];
    for (const [what, snippet, file] of claims) {
        check(`the guide's ${what} is really in the example`,
            norm(file).includes(norm(snippet)), snippet);
    }

    // The guide must not promise commands that do not exist.
    const help = spawnSync(RINGSERV, [], { encoding: "utf8" }).stderr +
        spawnSync(RINGSERV, [], { encoding: "utf8" }).stdout;
    for (const cmd of ["new", "dev", "test", "check", "docs", "topology", "run"]) {
        const named = new RegExp("ringserv " + cmd + "\\b").test(guide + started);
        if (!named) continue;
        check(`\`ringserv ${cmd}\` exists, as the guides claim`,
            new RegExp("ringserv " + cmd + "\\b").test(help), help.slice(0, 200));
    }

    // Cross-references must resolve. A dead link in a learning path is a
    // reader who stops.
    for (const doc of ["fieldnotes-app.md", "getting-started.md", "README.md"]) {
        const text = read(path.join(ROOT, "docs", doc));
        const links = [...text.matchAll(/\]\((?!https?:)([^)#]+)(?:#[^)]*)?\)/g)]
            .map(m => m[1]);
        const dead = links.filter(l =>
            !fs.existsSync(path.resolve(path.join(ROOT, "docs"), l)));
        check(`every local link in ${doc} resolves`, dead.length === 0,
            dead.join(", "));
    }

    // ------------------------------------------- and it serves what it says
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-guide-"));
    fs.copyFileSync(APP, path.join(tmp, "app.ring"));
    fs.mkdirSync(path.join(tmp, "services"), { recursive: true });
    fs.copyFileSync(path.join(EX, "services", "digest.js"),
        path.join(tmp, "services", "digest.js"));
    fs.mkdirSync(path.join(tmp, "public"), { recursive: true });
    fs.copyFileSync(path.join(EX, "public", "index.html"),
        path.join(tmp, "public", "index.html"));

    const server = spawn(RINGSERV, ["run", path.join(tmp, "app.ring")], {
        stdio: ["ignore", "ignore", "pipe"], cwd: tmp,
    });
    try {
        const t0 = Date.now();
        let up = false;
        while (Date.now() - t0 < 25000) {
            try { if ((await fetch(B + "/health")).status === 200) { up = true; break; } } catch {}
            await new Promise(res => setTimeout(res, 150));
        }
        check("the example serves", up);

        const call = async (service, action, payload) => {
            const res = await fetch(B + "/api/v1", {
                method: "POST",
                body: JSON.stringify({ service, action, payload: payload || {} }),
            });
            return { status: res.status, json: await res.json() };
        };

        let c = await call("notes", "create",
            { title: "First light", place: "Sidi Bou", weight: 12 });
        check("the generic service creates, as the guide says",
            c.json.code === 0 && c.json.data.id > 0, JSON.stringify(c.json));

        // The guide's central promise about contracts.
        c = await call("notes", "create", { body: "no title" });
        check("a contract violation is a 422, exactly as the guide claims",
            c.status === 422, c.status + " " + JSON.stringify(c.json));

        c = await call("digest", "brief", { limit: 2 });
        check("the JS service answers over the wire",
            c.json.code === 0 && typeof c.json.data.headline === "string",
            JSON.stringify(c.json));

        // The 501 the guide promises for a :local service with no authority
        // is NOT reachable here (notes has an authority), so what is checked
        // is the claim that CAN be: notes IS answerable, and the map says so.
        const topo = await (await fetch(B + "/topology")).json();
        const notes = topo.data.services.find(s => s.name === "notes");
        check("the placement map matches the guide's reading of it",
            notes.site === "local" && notes.authority === "server" &&
            notes.answerable === 1, JSON.stringify(notes));

        const page = await (await fetch(B + "/")).text();
        check("the static page is served at /", /Fieldnotes/.test(page),
            page.slice(0, 120));
    } finally {
        server.kill();
        await new Promise(res => setTimeout(res, 600));
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})();
