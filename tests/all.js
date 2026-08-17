/*
** Every gate, one command: `zig build gates` (or `node tests/all.js`).
**
** Six suites are easy to run five of. This runs them in dependency
** order — bridge, then services, then data, then the CLI — stops
** nothing on failure (a full picture beats an early exit), and returns
** a CI-ready code.
**
**   node tests/all.js            everything except the slow suites
**   node tests/all.js --full     ...including soak and the oracle
*/
const { spawnSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const full = process.argv.includes("--full");
const here = __dirname;
const root = path.join(here, "..");
const RINGSERV = path.join(root, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

if (!fs.existsSync(RINGSERV)) {
    console.error("tests/all.js: build first — zig build");
    process.exit(2);
}

const suites = [
    { name: "bridge gates      ", cmd: "zig", args: ["build", "test", "--summary", "all"], cwd: root },
    { name: "service gates     ", node: "serv-gates.js" },
    { name: "schema gates      ", node: "data-gates.js" },
    { name: "CRUD + contracts  ", node: "crud-gates.js" },
    { name: "data fuzz         ", node: "fuzz-data.js" },
    { name: "CLI gates         ", node: "cli-gates.js" },
    { name: "check + docs      ", node: "check-gates.js" },
];

if (full) {
    suites.push({ name: "soak (3k requests)", node: "soak-lite.js", args: ["3000"] });
    suites.push({ name: "soak (data layer) ", node: "soak-data.js", args: ["2000"] });
    suites.push({ name: "native oracle     ", node: "oracle.js" });
    suites.push({ name: "wide sweep (samples)", node: "sweep.js" });
    // The documentation corpus is generated on demand; run it only when
    // it has been extracted (node tests/extract-doc-snippets.js).
    if (fs.existsSync(path.join(here, "doc-snippets"))) {
        suites.push({ name: "wide sweep (docs)  ", node: "sweep.js",
            args: ["--root=tests/doc-snippets", "--dirs=."] });
    }
}

const results = [];
for (const s of suites) {
    process.stdout.write("── " + s.name.trim() + "\n");
    const started = Date.now();
    const r = s.node
        ? spawnSync(process.execPath, [path.join(here, s.node), ...(s.args || [])],
            { encoding: "utf8", cwd: root })
        : spawnSync(s.cmd, s.args, { encoding: "utf8", cwd: s.cwd, shell: process.platform === "win32" });
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    const out = (r.stdout || "") + (r.stderr || "");
    const ok = r.status === 0;
    // One summary line per suite; the detail only when it failed.
    const summary = out.split("\n").reverse()
        .find(l => /passed|match|PASSED|FAILED|tests passed/.test(l)) || "";
    console.log((ok ? "   ok   " : "   FAIL ") + summary.trim() + "  (" + secs + "s)");
    if (!ok) console.log(out.split("\n").filter(l => /FAIL|error/i.test(l)).slice(0, 12).join("\n"));
    results.push({ name: s.name, ok });
}

console.log("\n" + "─".repeat(56));
for (const r of results) console.log((r.ok ? "  ok    " : "  FAIL  ") + r.name);
const failed = results.filter(r => !r.ok).length;
console.log("─".repeat(56));
console.log(failed === 0
    ? `All ${results.length} suites passed.` + (full ? "" : "  (add --full for soak + oracle)")
    : `${failed} of ${results.length} suites FAILED.`);
process.exit(failed ? 1 : 0);
