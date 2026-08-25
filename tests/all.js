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
    { name: "load anchor       ", node: "loader-gates.js" },
    { name: "library root      ", node: "loadroot-gates.js" },
    { name: "check + docs      ", node: "check-gates.js" },
    { name: "C2 conformance    ", node: "c2-gates.js" },
    { name: "placement         ", node: "topology-gates.js" },
    { name: "sync + convergence", node: "sync-gates.js" },
    { name: "JS guest          ", node: "js-gates.js" },
    { name: "JS services       ", node: "jsserv-gates.js" },
    { name: "TLS decision      ", node: "tls-gates.js" },
    { name: "actor / auth      ", node: "auth-gates.js" },
    { name: "the guides        ", node: "guide-gates.js" },
    { name: "ringlib namespace ", node: "ringlibns-gates.js" },
    { name: "journal           ", node: "journal-gates.js" },
    { name: "gesture + config  ", node: "gesture-gates.js" },
    { name: "the panel         ", node: "panel-gates.js" },
    { name: "comptoir (broad)  ", node: "comptoir-gates.js" },
    { name: "family handshake  ", node: "family-gates.js" },
    { name: "pages that react   ", node: "stream-gates.js" },
    { name: "who governs a stream", node: "streamgov-gates.js" },
    { name: "stzlib profile    ", node: "stzprofile-gates.js" },
    { name: "harness record    ", node: "harness-gates.js" },
];

if (full) {
    suites.push({ name: "soak (3k requests)", node: "soak-lite.js", args: ["3000"] });
    suites.push({ name: "soak (data layer) ", node: "soak-data.js", args: ["2000"] });
    suites.push({ name: "benchmark         ", node: "bench.js", args: ["200"] });
    suites.push({ name: "native oracle     ", node: "oracle.js" });
    suites.push({ name: "wide sweep (samples)", node: "sweep.js" });
    // The documentation corpus is generated on demand; run it only when
    // it has been extracted (node tests/extract-doc-snippets.js).
    if (fs.existsSync(path.join(here, "doc-snippets"))) {
        suites.push({ name: "wide sweep (docs)  ", node: "sweep.js",
            args: ["--root=tests/doc-snippets", "--dirs=."] });
    }
}

// A gate that CANNOT run is named, never silently dropped (CLAUDE.md's
// PX law, and the same discipline loader-gates uses for its oracle).
// The bridge gates need a Zig toolchain; the platform runs that prove
// the binary works on Linux/macOS deliberately carry only the binary,
// so on those machines this suite is reported as skipped, with why.
const hasZig = (() => {
    const r = spawnSync(process.platform === "win32" ? "where" : "which",
        ["zig"], { encoding: "utf8" });
    return r.status === 0;
})();

const results = [];
for (const s of suites) {
    if (!s.node && !hasZig) {
        console.log("── " + s.name.trim());
        console.log("   SKIP  no zig toolchain on this machine — " +
            "the bridge gates compile Zig; the binary under test does not need it");
        results.push({ name: s.name, ok: true, skipped: true });
        continue;
    }
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
for (const r of results)
    console.log((r.skipped ? "  skip  " : r.ok ? "  ok    " : "  FAIL  ") + r.name);
const failed = results.filter(r => !r.ok).length;
console.log("─".repeat(56));
const skipped = results.filter(r => r.skipped).length;
if (skipped) console.log(`  (${skipped} skipped, named above)`);
console.log(failed === 0
    ? `All ${results.length - skipped} runnable suites passed.` + (full ? "" : "  (add --full for soak + oracle)")
    : `${failed} of ${results.length} suites FAILED.`);
process.exit(failed ? 1 : 0);
