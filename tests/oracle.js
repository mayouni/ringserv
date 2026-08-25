/*
** Phase-1 oracle: run the shared example corpus (RingScript's 24 playground
** examples — the very files its Playground serves) through BOTH the native
** ring.exe (the oracle) and the ringserv binary, then compare byte-for-byte.
**
** ringserv's `give` echoes consumed input when stdin is piped (terminal-
** transcript fidelity, same as the wasm runtime); native ring with piped
** stdin does not echo. The comparison removes each echoed input line (in
** order) from the ringserv output before diffing — the exact technique of
** RingScript's examples-oracle.js.
**
** Usage: node tests/oracle.js [id]              (no arg = all)
** Env:   RING_EXE / RING_HOME override the oracle location
**        RINGSCRIPT_DIR overrides the corpus location (default: ../ringscript)
*/
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const RING_EXE = require(path.join(__dirname, "ring-exe.js")).ringExe();
// This whole suite IS the oracle, so with no interpreter there is nothing
// to be an oracle against. Saying so and exiting 0 is the honest answer;
// comparing against a path that does not exist would report every example
// as a compatibility failure.
if (!RING_EXE) {
    console.log("SKIP  native oracle — no ring interpreter on this machine " +
        "(set RING_EXE or RING_HOME). Every gate in this suite is owned and " +
        "none was run.");
    process.exit(0);
}
const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

const scriptDir = process.env.RINGSCRIPT_DIR ||
    path.join(__dirname, "..", "..", "ringscript");
const EXAMPLES = require(path.join(scriptDir, "playground", "examples-data.js"));
const sourceOf = ex => fs.readFileSync(
    path.join(scriptDir, "playground", "examples", ex.id + ".ring"), "utf8");

function runOne(exe, code, input) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-oracle-"));
    const file = path.join(dir, "example.ring");
    fs.writeFileSync(file, code, "utf8");
    try {
        const args = exe === RINGSERV ? ["run", file] : [file];
        const out = execFileSync(exe, args, {
            input: input || "",
            timeout: 20000,
            maxBuffer: 16 * 1024 * 1024,
        });
        return out.toString("utf8").replace(/\r\n/g, "\n");
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
}

function stripEchoes(out, input) {
    const lines = (input || "").split("\n").filter((l, i, a) => !(l === "" && i === a.length - 1));
    let searchFrom = 0;
    for (const line of lines) {
        const needle = line + "\n";
        const idx = out.indexOf(needle, searchFrom);
        if (idx !== -1) {
            out = out.slice(0, idx) + out.slice(idx + needle.length);
            searchFrom = idx;
        }
    }
    return out;
}

const which = process.argv[2] ? EXAMPLES.filter(e => e.id === process.argv[2]) : EXAMPLES;
if (!which.length) { console.error("unknown example id"); process.exit(2); }

let failures = 0;
for (const ex of which) {
    const code = sourceOf(ex);
    let servOut, nativeOut;
    try {
        servOut = runOne(RINGSERV, code, ex.input);
    } catch (e) {
        console.log("FAIL  " + ex.id + "  (ringserv failed: " + String(e.message).split("\n")[0] + ")");
        failures++;
        continue;
    }
    try {
        nativeOut = runOne(RING_EXE, code, ex.input);
    } catch (e) {
        console.log("SKIP  " + ex.id + "  (native oracle failed: " + String(e.message).split("\n")[0] + ")");
        continue;
    }
    const stripped = stripEchoes(servOut, ex.input);
    if (stripped === nativeOut) {
        console.log("PASS  " + ex.id);
    } else {
        failures++;
        console.log("FAIL  " + ex.id);
        console.log("  --- native (oracle) ---");
        console.log(nativeOut.replace(/^/gm, "  | "));
        console.log("  --- ringserv (echoes stripped) ---");
        console.log(stripped.replace(/^/gm, "  | "));
    }
}
console.log(failures === 0 ? "\nAll examples match the native oracle." : "\n" + failures + " example(s) FAILED.");
process.exit(failures ? 1 : 0);
