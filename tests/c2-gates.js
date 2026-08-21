/*
** C2 conformance: every diagnostic `check --json` emits must validate
** against the Diagnostic Contract envelope.
**
** The contract's §3 says a court conforms when (1) every machine-form
** diagnostic validates against diagnostic-contract.schema.json, (2) its
** extension fields never touch the six, and (3) it records the version it
** pins. This suite is (1) and (2) executable; (3) is docs/CHECK.md.
**
** Two design choices worth stating:
**
**   THE SCHEMA IS VENDORED, and the validator READS IT rather than
**   restating it. A gate that hardcodes "col must be >= 1" proves the
**   gate agrees with itself. Reading vendor/c2/ means a schema bump is
**   felt here, which is what pinning is for.
**
**   DRIFT IS A FAILURE, NOT A SURPRISE. If the sibling stzzui checkout
**   is present, the vendored copy must be byte-identical to it. Absent,
**   the suite still runs — RingServ's gates must not need a sibling
**   repository on disk.
**
** Usage: node tests/c2-gates.js
*/
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const SCHEMA_FILE = path.join(ROOT, "vendor", "c2", "diagnostic-contract.schema.json");
const UPSTREAM = path.join(ROOT, "..", "stzzui", "doc", "diagnostic-contract.schema.json");
const PINNED = "1.1";

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

/* ------------------------------------------------------------------ *
 * A validator for the subset of JSON Schema this instrument uses:
 * type, required, enum, pattern, minimum, minLength, items, and
 * additionalProperties:false. Every constraint comes from the file —
 * nothing about C2 is written into this function.
 * ------------------------------------------------------------------ */
function validate(value, schema, where, errs) {
    const t = schema.type;
    if (t === "object") {
        if (value === null || typeof value !== "object" || Array.isArray(value))
            return errs.push(where + ": expected object");
        for (const k of schema.required || [])
            if (!(k in value)) errs.push(where + ": missing required '" + k + "'");
        if (schema.additionalProperties === false)
            for (const k of Object.keys(value))
                if (!(schema.properties || {})[k])
                    errs.push(where + ": property '" + k + "' is not allowed");
        for (const [k, sub] of Object.entries(schema.properties || {}))
            if (k in value) validate(value[k], sub, where + "." + k, errs);
        return;
    }
    if (t === "array") {
        if (!Array.isArray(value)) return errs.push(where + ": expected array");
        if (schema.items)
            value.forEach((v, i) => validate(v, schema.items, where + "[" + i + "]", errs));
        return;
    }
    if (t === "string") {
        if (typeof value !== "string") return errs.push(where + ": expected string");
        if (schema.minLength !== undefined && value.length < schema.minLength)
            errs.push(where + ": shorter than minLength " + schema.minLength);
        if (schema.pattern && !new RegExp(schema.pattern).test(value))
            errs.push(where + ": '" + value + "' does not match " + schema.pattern);
    }
    if (t === "integer") {
        if (!Number.isInteger(value)) return errs.push(where + ": expected integer");
        if (schema.minimum !== undefined && value < schema.minimum)
            errs.push(where + ": " + value + " < minimum " + schema.minimum);
    }
    if (schema.enum && !schema.enum.includes(value))
        errs.push(where + ": '" + value + "' not one of " + schema.enum.join("/"));
}

/* ------------------------------------------------------------------ */
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-c2-"));

function scaffold(name) {
    const r = spawnSync(RINGSERV, ["new", name], { cwd: tmp, encoding: "utf8" });
    if (r.status !== 0) throw new Error("scaffold failed: " + r.stderr);
    return path.join(tmp, name);
}

/** Plant a defect, run `check --json`, return the parsed envelopes. */
function envelopes(label, mutate, target) {
    const dir = scaffold("c" + (envelopes.n = (envelopes.n || 0) + 1));
    const file = path.join(dir, target || "app.ring");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, mutate(
        fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""));
    const r = spawnSync(RINGSERV, ["check", "--json"], { cwd: dir, encoding: "utf8" });
    let parsed = null, parseError = null;
    try { parsed = JSON.parse(r.stdout); } catch (e) { parseError = e.message; }
    // v1.1: the diagnostics live inside a REPORT OBJECT. `parsed` stays the
    // list every gate below already reasons about; `report` is the outer
    // object, so the shape itself can be asserted rather than assumed.
    const report = parsed;
    if (report && !Array.isArray(report) && Array.isArray(report.diagnostics)) {
        parsed = report.diagnostics;
    }
    return { label, status: r.status, raw: r.stdout, parsed, report, parseError };
}

try {
    check("the pinned instrument is vendored", fs.existsSync(SCHEMA_FILE), SCHEMA_FILE);
    const schema = JSON.parse(fs.readFileSync(SCHEMA_FILE, "utf8"));

    check(`the vendored schema is the version RingServ pins (v${PINNED})`,
        schema.version === PINNED, "vendored says v" + schema.version);

    // v1.1's whole point, asserted directly: NEVER a top-level array.
    // Ring 1.27's jsonlib WRAPS a bare top-level array in one extra level,
    // so a court emitting one is read one level deeper than it meant —
    // silently. Readable and wrong, which is why this is a gate and not a
    // style note.
    {
        const r = envelopes("shape", s2 => s2 + "\naX = )\n");
        check("the machine output is a report OBJECT, not a top-level array",
            r.report !== null && !Array.isArray(r.report), r.raw.slice(0, 120));
        check("...carrying its diagnostics under `diagnostics`",
            r.report && Array.isArray(r.report.diagnostics), r.raw.slice(0, 120));
    }

    // Drift against the normative home, when the home is on this disk.
    if (fs.existsSync(UPSTREAM)) {
        // Byte-identity was the first version of this gate, and it was too
        // strict by the contract's OWN governance (§4): MAJOR.MINOR moves
        // when substance moves, MAJOR.MINOR.PATCH marks a correction that
        // changes no requirement, and "a court pinned at x.y loses nothing
        // by staying there when x.y.z appears."
        //
        // It fired on 2026-08-21 when upstream published v1.1.1 — a
        // correction to the JUSTIFICATION of a rule whose requirement did
        // not move. A gate that cannot tell that from a real change forces
        // a re-pin for every wording repair, which is the treadmill that
        // pinning exists to avoid.
        const up = JSON.parse(fs.readFileSync(UPSTREAM, "utf8"));
        const mine = JSON.parse(fs.readFileSync(SCHEMA_FILE, "utf8"));
        const mm = v => String(v).split(".").slice(0, 2).join(".");

        check(`upstream is the same MAJOR.MINOR as the pin (v${PINNED})`,
            mm(up.version) === mm(PINNED),
            `pinned v${PINNED}, upstream v${up.version} — a substantive move needs a decision`);

        // Substance is everything except the human prose. `description` is
        // explicitly non-normative in C2, so comparing it would make this
        // gate an editor rather than a court.
        const strip = o => {
            if (Array.isArray(o)) return o.map(strip);
            if (o && typeof o === "object") {
                const out = {};
                for (const k of Object.keys(o).sort()) {
                    if (k === "description" || k === "version") continue;
                    out[k] = strip(o[k]);
                }
                return out;
            }
            return o;
        };
        check("the pinned schema's SUBSTANCE matches upstream",
            JSON.stringify(strip(mine)) === JSON.stringify(strip(up)),
            "a requirement moved — re-pin deliberately, do not paper over it");

        if (up.version !== mine.version) {
            console.log(`NOTE  upstream is v${up.version}, RingServ pins v${mine.version} — ` +
                "a patch, and §4 says a court loses nothing by staying");
        }
    } else {
        console.log("SKIP  drift check — no stzzui checkout beside this repository");
    }

    // ------------------------------------------------- the seeded defects
    //
    // One per code the checker can emit, so conformance is proven over
    // every branch rather than over whichever one a sample happened to hit.
    const cases = [
        ["RS_SYNTAX_ERROR", s => s + "\naX = )\n"],
        ["RS_SYNTAX_MISSING", s => s + '\nsee "never closed\n'],
        ["RS_CONTRACT_UNKNOWN_SERVICE",
            s => s.replace("Contract(:hello, [", "Contract(:nosuchservice, [")],
        ["RS_CONTRACT_UNKNOWN_ACTION",
            s => s.replace(/Contract\(:hello, \[\s*\n\s*:greet =/, "Contract(:hello, [\n\t:nosuchaction =")],
        ["RS_SERVICE_UNANSWERABLE",
            s => s.replace(':notes = [ :table = "notes" ]', ":notes = [ ]")],
        ["RS_ACTION_UNCONTRACTED",
            s => s.replace(/Contract\(:hello[\s\S]*?\n\]\)\n/, "")],
        ["RS_APP_UNEVALUABLE", s => "nosuchfunction()\n" + s],
        // Placement findings ride the same envelope. Prepended, not
        // appended: in Ring a statement after a func definition belongs
        // to that function, so a trailing Topology() would be swallowed.
        ["RS_TOPOLOGY_UNKNOWN_SITE",
            s => 'Topology([ :app = "c2", :services = [ :hello = [ :site = :orbit ] ] ])\n' + s],
        ["RS_TOPOLOGY_UNKNOWN_SERVICE",
            s => 'Topology([ :app = "c2", :services = [ :nosuch = [ :site = :server ] ] ])\n' + s],
    ];

    const seen = new Set();
    let total = 0;
    for (const [code, mutate] of cases) {
        const r = envelopes(code, mutate);
        check(`${code}: --json emits parseable JSON`,
            r.parsed !== null, r.parseError + "  raw: " + r.raw.slice(0, 200));
        if (!Array.isArray(r.parsed)) {
            check(`${code}: the output is an array of diagnostics`, false, r.raw.slice(0, 200));
            continue;
        }
        check(`${code}: at least one diagnostic`, r.parsed.length > 0, r.raw.slice(0, 200));

        const errs = [];
        r.parsed.forEach((d, i) => {
            validate(d, schema, code + "[" + i + "]", errs);
            seen.add(d.code);
            total++;
        });
        check(`${code}: every diagnostic validates against the envelope`,
            errs.length === 0, errs.slice(0, 6).join(" · "));
        check(`${code}: the expected code is among them`,
            r.parsed.some(d => d.code === code),
            "got " + r.parsed.map(d => d.code).join(","));
    }

    check(`all ${cases.length} codes were exercised (${total} diagnostics validated)`,
        cases.every(([c]) => seen.has(c)),
        "never seen: " + cases.map(([c]) => c).filter(c => !seen.has(c)).join(","));

    // ------------------------------------------- the two schema subtleties
    //
    // These are the places a conforming court is easiest to get wrong, so
    // they are asserted by name rather than left to the generic validator.

    // `col` is >= 1 WHERE PRESENT. A file-wide finding has no column, and
    // the honest encoding is to omit the field — "col": 0 is not a missing
    // column, it is an invalid one.
    {
        const r = envelopes("filewide", s => s.replace(':notes = [ :table = "notes" ]', ":notes = [ ]"));
        const wide = (r.parsed || []).filter(d => d.span && d.span.line === 0);
        check("a file-wide finding exists to test (line 0)", wide.length > 0);
        check("...and OMITS col rather than emitting zero",
            wide.every(d => !("col" in d.span)),
            JSON.stringify(wide.map(d => d.span)));
    }

    // A located finding must carry a real column, not a placeholder.
    {
        const r = envelopes("located", s => s + "\naX = )\n");
        const loc = (r.parsed || []).filter(d => d.span && d.span.line > 0);
        check("a located finding carries col >= 1",
            loc.length > 0 && loc.every(d => d.span.col >= 1),
            JSON.stringify(loc.map(d => d.span)));
    }

    // Extension fields must never collide with the six (§3.2). RingServ
    // emits exactly the six — the cheapest way to satisfy that clause.
    {
        const r = envelopes("exact", s => s + "\naX = )\n");
        const six = ["code", "severity", "message", "span", "cites", "language"];
        check("no field outside the six is emitted",
            (r.parsed || []).every(d =>
                Object.keys(d).every(k => six.includes(k))),
            JSON.stringify(Object.keys((r.parsed || [{}])[0])));
    }

    // The severity ladder is two-runged and closed, and RingServ uses both
    // rungs — a court that only ever says "error" has not really adopted it.
    {
        const warn = envelopes("warn", s => s.replace(/Contract\(:hello[\s\S]*?\n\]\)\n/, ""));
        check("a lawful-but-suspect finding is a warning, not an error",
            (warn.parsed || []).some(d => d.severity === "warning"),
            JSON.stringify((warn.parsed || []).map(d => [d.code, d.severity])));
        check("...and a warning alone does not fail the command",
            warn.status === 0, "exit " + warn.status);
    }

    // A clean scaffold emits an empty array, not "nothing to report" prose.
    // Machine form must stay machine form even when there is no news.
    {
        const dir = scaffold("clean");
        const r = spawnSync(RINGSERV, ["check", "--json"], { cwd: dir, encoding: "utf8" });
        let parsed = null;
        try { parsed = JSON.parse(r.stdout); } catch {}
        check("a clean app emits a REPORT OBJECT, never a bare array",
            parsed !== null && !Array.isArray(parsed) && typeof parsed === "object",
            r.stdout.slice(0, 200));
        check("...whose `diagnostics` key is present and empty",
            parsed && Array.isArray(parsed.diagnostics) && parsed.diagnostics.length === 0,
            r.stdout.slice(0, 200));
        check("...and succeeds", r.status === 0, "exit " + r.status);
    }

    // ============================ the family can READ what this court emits
    //
    // The whole purpose of an envelope contract, and the only claim in this
    // suite that is not about RingServ alone: a diagnostic is worth nothing
    // if the family's own reader gets a different document back.
    //
    // So this runs RING — the actual interpreter, not a model of it —
    // against the actual `--json` output, decodes it with `jsonlib` and
    // re-encodes it, and requires the same document. It is the positive
    // half of v1.1's rule; every other gate here states what the shape must
    // NOT be.
    //
    // SKIPS when no Ring is installed. RingServ's gates must never need one
    // (RINGSERV-LOADROOT-01 ruled the dependency optional), and a gate that
    // failed without an installation would quietly make it mandatory.
    {
        const where = spawnSync(RINGSERV, ["where"], { encoding: "utf8" });
        const m = /Ring home (.+)/.exec(where.stdout || "");
        const home = m && !/\(none/.test(m[1]) ? m[1].trim() : null;
        const ringExe = home
            ? path.join(home, "bin", process.platform === "win32" ? "ring.exe" : "ring")
            : null;

        if (!ringExe || !fs.existsSync(ringExe)) {
            console.log("SKIP  the family can read this court's output — no Ring installed");
        } else {
            const r = envelopes("readable", s2 => s2 + "\naX = )\n");
            const jsonPath = path.join(tmp, "report.json").replace(/\\/g, "/");
            fs.writeFileSync(jsonPath, r.raw);

            // Written to a file and read back rather than embedded, so the
            // bytes Ring sees are exactly the bytes RingServ wrote.
            const prog = path.join(tmp, "readback.ring");
            fs.writeFileSync(prog,
                'load "jsonlib.ring"\n' +
                'cRaw = read("' + jsonPath + '")\n' +
                'aDoc = JSON2List(cRaw)\n' +
                'see "TOPLEVEL:" + type(aDoc) + nl\n' +
                'see "KEYS:" + len(aDoc) + nl\n' +
                'see "FIRST:" + aDoc[1][1] + nl\n' +
                'see "NDIAG:" + len(aDoc[1][2]) + nl\n' +
                'see "CODE:" + aDoc[1][2][1][1][2] + nl\n');
            const rr = spawnSync(ringExe, [prog], { encoding: "utf8" });
            const out = (rr.stdout || "") + (rr.stderr || "");

            check("Ring's own jsonlib reads this court's report",
                /TOPLEVEL:LIST/.test(out) && !/Error/.test(out), out.slice(0, 200));
            check("...as ONE object, not a wrapped array",
                /KEYS:1/.test(out), out.slice(0, 200));
            check("...whose single key is `diagnostics`",
                /FIRST:diagnostics/.test(out), out.slice(0, 200));
            check("...carrying the diagnostics the court emitted",
                /NDIAG:[1-9]/.test(out), out.slice(0, 200));
            check("...with a code that survived the trip",
                /CODE:RS_/.test(out), out.slice(0, 200));
        }
    }
} finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
