/*
** Phase-5 gates: `check` and `docs`.
**
** The discipline is seeded defects — a checker that reports nothing is
** indistinguishable from a checker that cannot see. Each defect below
** is planted in a copy of the scaffold, and check must name it AND fail;
** the clean scaffold must stay silent.
**
** Usage: node tests/check-gates.js
*/
const { spawnSync } = require("child_process");
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-check-"));

function scaffold(name) {
    const r = spawnSync(RINGSERV, ["new", name], { cwd: tmp, encoding: "utf8" });
    if (r.status !== 0) throw new Error("scaffold failed: " + r.stderr);
    return path.join(tmp, name);
}

function run(dir, args) {
    const r = spawnSync(RINGSERV, args, { cwd: dir, encoding: "utf8" });
    return { status: r.status, out: (r.stdout || "") + (r.stderr || "") };
}

/** Plant a defect by rewriting app.ring, then check. */
function withDefect(label, mutate) {
    const dir = scaffold("d" + (withDefect.n = (withDefect.n || 0) + 1));
    const file = path.join(dir, "app.ring");
    fs.writeFileSync(file, mutate(fs.readFileSync(file, "utf8")));
    return { dir, ...run(dir, ["check"]) };
}

try {
    // ------------------------------------------------ the clean baseline
    const clean = scaffold("clean");
    let r = run(clean, ["check"]);
    check("clean scaffold: check is silent and succeeds",
        r.status === 0 && /nothing to report/.test(r.out), r.out);

    // ------------------------------------------------------ syntax pass
    r = withDefect("unclosed", src => src.replace(":services = [", ":services = [[[["));
    check("syntax error is reported and fails", r.status !== 0 &&
        /syntax error|missing syntax/.test(r.out), r.out);
    check("...with a file, line and column",
        /app\.ring:\d+:\d+:/.test(r.out), r.out);

    // A range of shapes, not just one: an unterminated string, a stray
    // paren, and a block left open.
    r = withDefect("unterminated-string", src => src + '\nsee "never closed\n');
    check("an unterminated string is caught", r.status !== 0 &&
        /missing syntax|syntax error/.test(r.out), r.out);

    r = withDefect("stray-paren", src => src + "\naX = )\n");
    check("a stray paren is caught, with the offending text", r.status !== 0 &&
        /syntax error near/.test(r.out), r.out);

    r = withDefect("unclosed-if", src => src + "\nif nX = 1\n");
    check("a block left open is caught", r.status !== 0, r.out);

    // ...and an honest limit. The grammar is young (pinned days after
    // publication) and does not reject every malformed construct: an
    // invalid function name parses cleanly. `check` is a linter with
    // Ring-shaped eyes, not a second compiler — the VM remains the
    // authority, and this gate records the boundary rather than hiding it.
    r = withDefect("bad-func-name", src => src + "\nfunc 123bad()\n");
    check("KNOWN LIMIT: an invalid function name is not caught by the grammar",
        r.status === 0, r.out);

    // A syntax error in tests/ counts too — tests are code.
    {
        const dir = scaffold("badtest");
        fs.writeFileSync(path.join(dir, "tests", "broken.ring"), "aX = [[[\n");
        const rr = run(dir, ["check"]);
        check("a syntax error under tests/ is caught", rr.status !== 0 &&
            /broken\.ring/.test(rr.out), rr.out);
    }

    // ---------------------------------------------------- semantic pass
    r = withDefect("ghost-service", src =>
        src.replace("Contract(:hello, [", "Contract(:nosuchservice, ["));
    check("a Contract for an undeclared service is caught", r.status !== 0 &&
        /not declared/.test(r.out), r.out);

    r = withDefect("ghost-action", src =>
        src.replace(/Contract\(:hello, \[\s*\n\s*:greet =/, "Contract(:hello, [\n\t:nosuchaction ="));
    check("a Contract for an action the service does not answer is caught",
        r.status !== 0 && /does not answer/.test(r.out), r.out);

    r = withDefect("empty-service", src =>
        src.replace(':notes = [ :table = "notes" ]', ":notes = [ ]"));
    check("a service with no actions and no table is caught",
        r.status !== 0 && /can never answer/.test(r.out), r.out);

    // Contracts on GENERIC actions are legitimate — the scaffold's
    // notes.create contract must not be flagged as a ghost action.
    check("a contract on a generic action is not a false positive",
        !/notes.*does not answer/.test(run(clean, ["check"]).out));

    // An action without a contract is a NOTE, not a failure: unchecked
    // payloads are a choice, not an error.
    {
        const dir = scaffold("nocontract");
        const file = path.join(dir, "app.ring");
        fs.writeFileSync(file, fs.readFileSync(file, "utf8")
            // \r?\n throughout: .gitattributes keeps the REPOSITORY on LF,
            // but a scaffold this gate just generated is whatever the
            // binary wrote, and a user's tree is whatever they checked out.
            .replace(/Contract\(:hello[\s\S]*?\r?\n\]\)\r?\n/, ""));
        const rr = run(dir, ["check"]);
        check("a missing contract is a note, not a failure",
            rr.status === 0 && /no Contract/.test(rr.out), rr.out);
    }

    // An app that cannot even be evaluated is reported as such.
    {
        const dir = scaffold("runtime-bad");
        const file = path.join(dir, "app.ring");
        fs.writeFileSync(file, "nosuchfunction()\n" + fs.readFileSync(file, "utf8"));
        const rr = run(dir, ["check"]);
        check("an app that cannot be evaluated is reported",
            rr.status !== 0 && /could not be evaluated/.test(rr.out), rr.out);
    }

    // --------------------------------------------------------- the docs
    r = run(clean, ["docs"]);
    check("docs renders markdown from the declarations", r.status === 0 &&
        /^# API/m.test(r.out) && /## hello/.test(r.out) &&
        /### hello\.greet/.test(r.out), r.out.slice(0, 300));
    check("docs documents a contract's fields and limits",
        /\| `name` \| string \| yes \| maxlen 40 \|/.test(r.out), r.out.slice(0, 600));
    check("docs covers contracts on generic actions",
        /### notes\.create/.test(r.out) && /`title`/.test(r.out), r.out.slice(0, 900));
    check("docs marks uncontracted actions plainly",
        /No contract declared/.test(r.out));

    const j = run(clean, ["docs", "--json"]);
    let parsed = null;
    try { parsed = JSON.parse(j.out); } catch {}
    check("docs --json emits valid JSON", j.status === 0 && parsed !== null,
        j.out.slice(0, 200));
    check("the JSON catalog carries services and contracts",
        parsed && Array.isArray(parsed.services) && Array.isArray(parsed.contracts) &&
        parsed.services.some(s => s.name === "hello") &&
        parsed.contracts.some(c => c.service === "hello" && c.action === "greet"),
        JSON.stringify(parsed).slice(0, 300));
    check("the catalog and the markdown agree on the service set",
        parsed && parsed.services.every(s => r.out.includes("## " + s.name)));
} finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
}

console.log(failed === 0
    ? "\nAll " + passed + " check/docs gates passed."
    : "\n" + failed + " gate(s) FAILED (" + passed + " passed).");
process.exit(failed ? 1 : 0);
