/*
** The wide oracle: run Ring's own sample programs through native
** ring.exe AND `ringserv run`, and compare byte-for-byte.
**
** This is the RingScript sweep transposed to a NATIVE runtime, and the
** transposition is mostly subtraction: RingScript had to skip every
** sample touching files, because a browser has no filesystem. RingServ
** has one, so files, `load`, and multi-file samples are all comparable
** here. What remains excluded is only what genuinely differs:
**
**   · things the server deliberately disables (system(), chdir — the
**     RING_LIMITEDSYS decision; loadlib — RING_NODLL)
**   · things whose output is environment-specific by nature (pointer
**     addresses, host OS probes, the C-function registry — into which
**     the bridge legitimately registers its own hooks, and filename(),
**     because ringserv evaluates the program through a shim)
**   · GUI and graphics
**
** Classification per sample:
**   compare  — deterministic: output must match native exactly
**   nocrash  — random/clock/date/input: must merely run cleanly
**   skip     — see above
**
** Usage: node tests/sweep.js [--dirs=Language,General] [--list] [--verbose]
** Env:   RING_HOME / RING_EXE point at the Ring installation.
*/
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ringWhere = require(path.join(__dirname, "ring-exe.js"));
const RING_HOME = ringWhere.ringHome();
const RING_EXE = ringWhere.ringExe();
const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

const argRoot = (process.argv.find(a => a.startsWith("--root=")) || "").replace("--root=", "");
const ROOT = argRoot ? path.resolve(argRoot) : path.join(RING_HOME, "samples");
const argDirs = (process.argv.find(a => a.startsWith("--dirs=")) || "").replace("--dirs=", "");
const DIRS = argDirs ? argDirs.split(",")
    : ["AQuickStart", "Language", "Algorithms", "DataStructure", "ProblemSolving", "General"];
const LIST_ONLY = process.argv.includes("--list");
const VERBOSE = process.argv.includes("--verbose");

const SKIP_PATTERNS = [
    // Disabled on purpose in the server build.
    [/\bsystem\s*\(/i, "system() — RING_LIMITEDSYS"],
    [/\b(chdir|currentdir|currentpath)\s*\(/i, "cwd functions — RING_LIMITEDSYS"],
    [/\bloadlib\s*\(|\bdynlib\b/i, "dynamic libraries — RING_NODLL"],
    // Environment-specific output, identical in kind on any two processes.
    [/\b(varptr|objectid|nullpointer|object2pointer|pointer2object|getpointer|setpointer)\b/i,
        "pointer addresses (env-specific)"],
    [/\b(filename|prevfilename)\s*\(/i, "source path — ringserv evaluates through a shim"],
    [/\bringvm_/i, "VM introspection (bridge registers its own hooks)"],
    [/\b(cfunctions|functions|globals|locals|classes|packages|packageclasses)\s*\(/i,
        "registry reflection (bridge registers its own hooks)"],
    [/\b(iswindows|iswindows64|isunix|ismacosx|islinux|isfreebsd|ismsdos|isandroid|getarch|nofprocessors|uptime)\s*\(/i,
        "host probes (env-specific)"],
    [/\b(exefilename|exefolder)\s*\(/i, "executable path (env-specific)"],
    [/\bsysargv\b|\bgetarg\b/i, "argv (differs: ringserv takes a subcommand)"],
    // Not this runtime's business.
    [/\b(new_thread|thread|mutex)\w*\s*\(/i, "threads"],
    [/\braylib|sdl|glut|opengl|qt\b/i, "graphics"],
    [/ChangeRingKeyword|ChangeRingOperator|LoadSyntax/i, "keyword changes (state-global)"],
    [/\binput\s*\(|\bgetchar\s*\(/i, "interactive input"],
];

const SKIP_PATHS = [
    /[\\/]Performance[\\/]/i,
    /RateCounter/i,
    /SendMoreMoneyMonteCarlo/i,
    /sudoku-KL02-longproblem/i,   // a solver that outruns any sane budget
];

/**
 * Samples known to diverge, each with the reason. They are reported but
 * do not fail the sweep — while anything NOT on this list does. That is
 * the whole point: the list is the ledger of what we know, so the gate
 * catches what we do not.
 *
 * Every entry here is a real limitation of `ringserv run`, which
 * evaluates a program's SOURCE where native `ring` compiles a FILE.
 *
 * `Language\SyntaxFiles\start.ring` LEFT this list on 2026-08-20, and how it
 * got here is worth keeping. It was recorded as "multi-file sample whose
 * loaded siblings produce no output under eval" — a reason that sounded right
 * and was wrong. The siblings produced no output because they were never
 * LOADED: a nested `load` had no anchor to resolve against (src/rs_path.c,
 * docs/LOADING.md). The entry sat here describing the symptom of a defect
 * nobody had named. That is the argument for this ledger and the warning
 * about it in one line: an entry with a plausible reason stops being read.
 */
const KNOWN_DIVERGENCES = new Map([
    ["Language\\OptionalFunc\\Answer.ring",
        "optionalFunc(): a later definition of the optional function is rejected as a redefinition under eval"],
    ["Language\\OptionalFunc\\Question.ring",
        "optionalFunc(): calling an undefined optional function does not no-op under eval"],
    ["Language\\MagicMenu\\magicmenu.ring",
        "interactive menu: input handling diverges from native under canned stdin"],
    // Same optionalFunc root cause, found independently in the
    // documentation corpus — which is exactly the corroboration a second
    // corpus is for.
    ["metaprog-67.ring",
        "optionalFunc(): same cause as Language\\OptionalFunc — undefined optional call does not no-op under eval"],
]);

const knownKey = rel => rel.replace(/\//g, "\\");

const NOCRASH_PATTERNS = [
    [/\brandom\s*\(|\bsrandom\s*\(/i, "random"],
    [/\bclock\s*\(|\bclockspersecond\s*\(/i, "clock"],
    [/\b(time|date|timelist|adddays|diffdays)\s*\(/i, "date/time"],
    [/\bgive\b/i, "give (canned input)"],
    [/\bget\s+\w/i, "get — second-style give"],
    [/\bbye\b/i, "bye — ends the whole program"],
    [/\btempfile\s*\(|\btempname\s*\(/i, "temp files (paths differ)"],
];

const CANNED_INPUT = "3\n7\n2\n4\n1\n9\n8\n5\n5\n5\n5\n5\n5\n5\n";

/**
 * Follow `load` TRANSITIVELY through sibling files, because what a
 * program does includes what its siblings do.
 *
 * Three outcomes matter:
 *   · a target that is not beside the sample is Ring's own installed
 *     library (internetlib, stdlibcore, guilib …). RingServ is
 *     self-contained and ships no Ring library folder, so the sample is
 *     out of scope. A SIBLING load, by contrast, works fine here — real
 *     filesystem — and is exactly the coverage RingScript never had.
 *   · a load CYCLE (a loads b, b loads a) is the one case where
 *     `ringserv run` genuinely differs: native tracks the main program
 *     as an already-loaded FILE, while ringserv evaluates its SOURCE, so
 *     the cycle re-includes it and Ring reports a redefinition. A real
 *     limitation, recorded rather than hidden — see docs/GATES.md.
 *   · otherwise, return the whole transitive source so the pattern
 *     checks below see the program as it will actually run.
 */
function gather(file, seen = new Set(), chain = new Set()) {
    const real = path.resolve(file);
    if (chain.has(real)) return { cycle: path.basename(file) };
    if (seen.has(real)) return { text: "" };
    seen.add(real);
    chain.add(real);
    let src;
    try { src = fs.readFileSync(real, "utf8"); } catch { return { text: "" }; }
    let text = src;
    const dir = path.dirname(real);
    for (const m of src.matchAll(/\bload\s+["']([^"']+)["']/gi)) {
        const target = path.join(dir, m[1]);
        if (!fs.existsSync(target)) return { library: m[1] };
        const sub = gather(target, seen, chain);
        if (sub.library || sub.cycle) return sub;
        text += "\n" + sub.text;
    }
    chain.delete(real);
    return { text };
}

function classify(src, file) {
    const g = gather(file);
    if (g.library) return { kind: "skip", why: "loads Ring's installed library: " + g.library };
    if (g.cycle) return { kind: "skip", why: "circular load — see docs/GATES.md" };
    const whole = g.text || src;
    for (const [re, why] of SKIP_PATTERNS) if (re.test(whole)) return { kind: "skip", why };
    for (const [re, why] of NOCRASH_PATTERNS) if (re.test(whole)) return { kind: "nocrash", why };
    return { kind: "compare" };
}

/**
 * Native's own output embeds the absolute source path when a program ends
 * in an uncaught error ("In raise() in file D:\ring127\samples\..."), and
 * ringserv reports trapped errors on its own channel by design. Such a run
 * is not comparable BY NATURE, so it is demoted to "must merely run"
 * rather than counted as a divergence.
 */
function nativeOutputIsEnvSpecific(out, file) {
    // Native names the SOURCE PATH in every error it prints — "in file
    // <abs path>" at runtime, "<abs path> Line (n) Error" at compile
    // time. ringserv reports the same fault against "eval", because it
    // evaluates source rather than compiling a file. Same diagnosis,
    // different provenance line: not comparable by nature.
    if (out.includes(path.dirname(file))) return true;
    return /\bin file\s+\S+/i.test(out) || /Called from line/i.test(out);
}

function run(exe, args, file, input) {
    try {
        const out = execFileSync(exe, args, {
            input: input || "",
            timeout: 20000,
            maxBuffer: 32 * 1024 * 1024,
            cwd: path.dirname(file),
        });
        return { ok: true, out: out.toString("utf8").replace(/\r\n/g, "\n") };
    } catch (e) {
        return {
            ok: false,
            out: (e.stdout || "").toString().replace(/\r\n/g, "\n"),
            err: String(e.message).split("\n")[0],
            timedOut: e.killed === true || /ETIMEDOUT/.test(String(e.code)),
        };
    }
}

/** ringserv echoes consumed `give` lines (terminal fidelity); native piped does not. */
function stripEchoes(out, input) {
    let s = out, from = 0;
    for (const line of (input || "").split("\n")) {
        if (!line) continue;
        const idx = s.indexOf(line + "\n", from);
        if (idx !== -1) { s = s.slice(0, idx) + s.slice(idx + line.length + 1); from = idx; }
    }
    return s;
}

const files = [];
for (const dir of DIRS) {
    const root = path.join(ROOT, dir);
    if (!fs.existsSync(root)) continue;
    (function walk(d) {
        for (const e of fs.readdirSync(d, { withFileTypes: true })) {
            const p = path.join(d, e.name);
            if (e.isDirectory()) walk(p);
            else if (e.name.endsWith(".ring")) files.push(p);
        }
    })(root);
}

/** Every candidate file this run could have judged, by ledger key. */
const inScope = new Set(files.map(f => knownKey(path.relative(ROOT, f))));

const tally = { match: 0, ran: 0, mismatch: 0, servfail: 0, nativefail: 0, skip: 0, known: 0 };
const failures = [];
const knownSeen = new Set();

/** Record a divergence; known ones are reported but do not fail. */
function diverge(rel, entry, label) {
    const why = KNOWN_DIVERGENCES.get(knownKey(rel));
    if (why) {
        tally.known++;
        knownSeen.add(knownKey(rel));
        if (VERBOSE) console.log('KNOWN     ' + rel + '  (' + why + ')');
        return;
    }
    tally[label === 'MISMATCH' ? 'mismatch' : 'servfail']++;
    failures.push(entry);
    console.log(label.padEnd(9) + ' ' + rel);
}

for (const file of files) {
    const rel = path.relative(ROOT, file);
    if (SKIP_PATHS.some(re => re.test(file))) {
        tally.skip++;
        if (LIST_ONLY || VERBOSE) console.log("SKIP      " + rel + "  (path)");
        continue;
    }
    let src;
    try { src = fs.readFileSync(file, "utf8"); } catch { continue; }
    const cls = classify(src, file);
    if (cls.kind === "skip") {
        tally.skip++;
        if (LIST_ONLY || VERBOSE) console.log("SKIP      " + rel + "  (" + cls.why + ")");
        continue;
    }
    if (LIST_ONLY) { console.log(cls.kind.toUpperCase().padEnd(10) + rel); continue; }

    const input = cls.kind === "nocrash" ? CANNED_INPUT : "";
    const native = run(RING_EXE, [file], file, input);
    if (!native.ok && !native.out) {
        tally.nativefail++;
        if (VERBOSE) console.log("NATFAIL   " + rel + "  (" + native.err + ")");
        continue; // the oracle itself cannot run it — not our verdict to make
    }

    // Native ending in an uncaught error is not comparable (see above).
    let kind = cls.kind;
    if (kind === "compare" && nativeOutputIsEnvSpecific(native.out, file)) kind = "nocrash";

    const serv = run(RINGSERV, ["run", file], file, input);
    if (serv.timedOut) {
        diverge(rel, { rel, kind: "TIMEOUT" }, "TIMEOUT");
        continue;
    }

    if (kind === "nocrash") {
        // Must merely run: no crash, and no error the native side did not
        // also produce.
        if (!serv.ok && native.ok) {
            diverge(rel, { rel, kind: "ERROR", detail: serv.err, out: serv.out.slice(-400) }, "ERROR");
        } else {
            tally.ran++;
            if (VERBOSE) console.log("RAN       " + rel + "  (" + cls.why + ")");
        }
        continue;
    }

    const got = stripEchoes(serv.out, input);
    if (got === native.out) {
        tally.match++;
        if (VERBOSE) console.log("MATCH     " + rel);
    } else {
        diverge(rel, { rel, kind: "MISMATCH", native: native.out.slice(0, 1200), serv: got.slice(0, 1200) }, "MISMATCH");
    }
}

if (!LIST_ONLY) {
    console.log("\n==== sweep summary ====");
    console.log("exact match : " + tally.match);
    console.log("ran (nondet): " + tally.ran);
    console.log("mismatch    : " + tally.mismatch);
    console.log("ringserv err: " + tally.servfail);
    console.log("native fail : " + tally.nativefail + "  (oracle could not run; not counted)");
    console.log("skipped     : " + tally.skip + "  (by-design exclusions)");
    console.log("known diverg: " + tally.known + "  (listed in this file, with reasons)");
    // A known divergence that stopped diverging is news too: the list
    // must not rot into a set of excuses nobody rechecks.
    // Only meaningful against the default corpus: another --root simply
    // does not contain these files.
    // Judge only entries whose file was actually IN SCOPE this run. The
    // samples corpus and the documentation corpus are swept separately,
    // so a `--root` guard was the wrong axis: it still announced the doc
    // entry as "fixed" on every samples run. Crying wolf is how a checker
    // teaches people to ignore it.
    for (const k of KNOWN_DIVERGENCES.keys()) {
        if (!inScope.has(k)) continue;
        if (!knownSeen.has(k)) console.log("NOTE: known divergence no longer diverges (remove it): " + k);
    }
    if (failures.length) {
        fs.writeFileSync(path.join(__dirname, "sweep-failures.json"), JSON.stringify(failures, null, 1));
        console.log("\nDetails in tests/sweep-failures.json");
    }
    const bad = tally.mismatch + tally.servfail;
    console.log(bad === 0
        ? "\nEvery comparable sample matches native ring."
        : "\n" + bad + " sample(s) diverge from native ring.");
    process.exit(bad > 0 ? 1 : 0);
}
