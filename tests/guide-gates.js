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

    // Cross-references must resolve — EVERYWHERE, which is not the same
    // as resolving here. This gate used fs.existsSync over three docs and
    // passed for months while six links were dead on GitHub and on Linux:
    // NTFS is case-insensitive, so `](VISION.md)` found `docs/vision.md`
    // on the machine doing the checking and 404'd for every reader.
    //
    // So the authority is git's index — the exact bytes of the tracked
    // names — not the local filesystem, and the scope is every tracked
    // markdown file rather than a hand-kept list of three.
    {
        const tracked = new Set(
            require("child_process")
                .execSync("git ls-files", { cwd: ROOT, encoding: "utf8" })
                .split("\n").map(l => l.trim()).filter(Boolean));
        const docs = [...tracked].filter(f => f.endsWith(".md"));
        const dead = [];
        for (const doc of docs) {
            const text = fs.readFileSync(path.join(ROOT, doc), "utf8");
            for (const m of text.matchAll(/\]\((?!https?:|mailto:)([^)#?]+\.md)(?:#[^)]*)?\)/g)) {
                const target = path.posix.normalize(
                    path.posix.join(path.posix.dirname(doc), m[1]));
                if (!tracked.has(target)) dead.push(`${doc} -> ${m[1]}`);
            }
        }
        check("every markdown link resolves with EXACT case, repo-wide",
            dead.length === 0, dead.join("  |  "));
        check("...over every tracked markdown file, not a hand-kept list",
            docs.length >= 20, `${docs.length} files scanned`);
    }

    // ---- the front door may not fall behind the roadmap
    //
    // Twice now an outside reader has measured readme.md claiming fewer
    // delivered phases than docs/roadmap.md records — three behind, fixed,
    // then two behind again. The cause is not carelessness: a number
    // TRANSCRIBED BY HAND into a second file drifts at the rate the first
    // file moves, and this one moves about a phase a day. So the readme no
    // longer carries the number, and this gate is what keeps it honest —
    // if the count ever comes back, it has to be right.
    {
        const readme = read(path.join(ROOT, "readme.md"));
        const roadmap = read(path.join(ROOT, "docs", "roadmap.md"));
        const delivered = [...roadmap.matchAll(/^## Phase (\d+)[^\n]*(?:✅|delivered)/gim)]
            .map(m => parseInt(m[1], 10));
        const highest = delivered.length ? Math.max(...delivered) : 0;
        check("the roadmap records delivered phases this gate can count",
            highest >= 12, `highest delivered = ${highest}`);

        // Any phase count the readme states must match the roadmap's.
        const claims = [...readme.matchAll(/\b(\w+)\s+phases?\s+(?:are\s+)?delivered/gi)]
            .map(m => m[1].toLowerCase());
        const WORDS = { one:1, two:2, three:3, four:4, five:5, six:6, seven:7,
                        eight:8, nine:9, ten:10, eleven:11, twelve:12,
                        thirteen:13, fourteen:14, fifteen:15 };
        const wrong = claims
            .map(w => (WORDS[w] !== undefined ? WORDS[w] : parseInt(w, 10)))
            .filter(n => !isNaN(n) && n !== highest);
        check("readme.md states no phase count that disagrees with the roadmap",
            wrong.length === 0,
            `readme says ${wrong.join(",")} — roadmap's highest delivered is ${highest}`);

        // ---- and the SUITE count is the same class of claim, found stale by
        // the same reasoning on 2026-08-24: readme.md said "22 suites" while
        // tests/all.js listed 23, and adding a 24th is what surfaced it. The
        // phase count above got a gate and the suite count beside it did not,
        // which is this repository's own lesson — a rule obeyed at the first
        // place you look is not yet obeyed — landing on the very file that
        // recorded it. So the count now reads from all.js, the one place that
        // cannot be wrong about how many suites there are.
        // Count the DEFAULT set only. all.js pushes the slow suites — soak,
        // bench, the oracle, the sweep — onto the same array under --full, and
        // counting those made this gate report 30 against a readme sentence
        // that is explicitly about the ~70-second run. Cut the file at the
        // --full block so the gate counts the thing the sentence counts.
        const allJs = read(path.join(ROOT, "tests", "all.js"));
        const fastPart = allJs.split(/\n\s*if\s*\(full\)/)[0];
        const listed = [...fastPart.matchAll(/\{\s*name:\s*"[^"]+",\s*(?:node|cmd):/g)].length;
        check("tests/all.js lists default suites this gate can count",
            listed >= 20 && listed < 40, `counted ${listed}`);

        const suiteClaims = [...readme.matchAll(/(\d+)\s+suites\b/gi)]
            .map(m => parseInt(m[1], 10))
            .filter(n => n !== listed);
        check("readme.md states no suite count that disagrees with tests/all.js",
            suiteClaims.length === 0,
            `readme says ${suiteClaims.join(",")} — all.js lists ${listed}`);
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
