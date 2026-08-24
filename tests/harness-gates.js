/*
** The harness's own record, READ BACK. HARNESS-AUTHORITY 4.2, 4.3, 5 and
** 3.1(g) oblige an unattended run to leave a trail; nothing ever checked that
** it did.
**
** WHY THIS SUITE EXISTS, and it is not a hypothetical. On 2026-08-23 a session
** in this repository opened a public pull request -- an act that leaves this
** machine -- and left no run log, no cost line and no outbox block.
** principal-desk ruled the general half on the same day
** (RINGSERV-PRBOUNDARY-01) and its measurement of this tree said the useful
** part out loud: "3.1(g) already obliged the record; what was missing is that
** nothing reads it back, and asking the author does not scale to the next one."
**
** So this reads it back. What it CAN check is narrow and worth stating exactly,
** because a gate believed to cover more than it does is worse than none:
**
**   IT CAN     catch a run that claims to be automated and left no repair
**              path -- an Autopilot-Run trailer with no matching run log, a
**              log naming no restore tag, a log that does not say whether it
**              was attended, a tag with no log.
**   IT CANNOT  catch an unattended act that left NO trailer at all. Nothing
**              can: an untrailered commit is indistinguishable from a person's,
**              which is 4.2's own sentence. That gap is the reason 3.1(b) makes
**              the CLAIM carry the Principal's words rather than making the
**              absence of a claim mean anything.
**
** THE LOGS ARE GITIGNORED (.central/runs/), so a fresh clone has none and every
** gate here SKIPS BY NAME. That is correct rather than convenient: this suite
** audits THIS WORKING COPY's history, and a clone has no history of runs to
** audit. A suite that went red on a clone would be reporting a defect in the
** clone.
**
**   node tests/harness-gates.js
*/
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RUNS = path.join(ROOT, ".central", "runs");

let passed = 0, failed = 0, skipped = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  - " + detail : "")); }
}
function skip(name, why) { skipped++; console.log("SKIP  " + name + "  - " + why); }
function note(text) { console.log("      " + text); }

function git(args) {
    const r = spawnSync("git", ["-C", ROOT, ...args], { encoding: "utf8" });
    return (r.stdout || "").trim();
}

console.log("== the harness's own record, read back ==\n");

// ------------------------------------------------- is there anything to audit?
const inGit = git(["rev-parse", "--is-inside-work-tree"]) === "true";
if (!inGit) {
    skip("everything", "not a git work tree");
    console.log("\n0 passed, 0 failed, 1 skipped");
    process.exit(0);
}

// Every stamp the history claims, and every stamp the logs and tags carry.
const trailers = new Set(
    git(["log", "--format=%B"]).split("\n")
        .map(l => (/^\s*Autopilot-Run:\s*(\S+)/.exec(l) || [])[1])
        .filter(Boolean));

const tags = new Set(
    git(["tag", "-l", "autopilot/*"]).split("\n")
        .filter(Boolean).map(t => t.replace(/^autopilot\//, "")));

// Key logs by their DATE-TIME stamp, not by filename. 5 specifies
// <stamp>-<repo>.log and the two oldest logs here are <stamp>.md, from before
// that shape settled. Keying on the filename made this suite report four
// orphans that were nothing of the kind -- an accounting artefact reads exactly
// like a finding, and it was the first thing this gate got wrong.
const logs = new Map();
const logFile = new Map();
if (fs.existsSync(RUNS)) {
    for (const f of fs.readdirSync(RUNS)) {
        if (!/\.(log|md)$/.test(f)) continue;
        const dt = (/^(\d{8}-\d{4})/.exec(f) || [])[1];
        if (!dt) continue;
        logs.set(dt, fs.readFileSync(path.join(RUNS, f), "utf8"));
        logFile.set(dt, f);
    }
}
const stampDate = s => (/^(\d{8}-\d{4})/.exec(s) || [])[1] || null;

note(`${trailers.size} trailered stamp(s), ${tags.size} restore tag(s), `
    + `${logs.size} run log(s)`);

// 5 names the path <repo>\.central\runs\<stamp>-<repo>.log. Reported, never
// failed: a run whose log is readable and correctly named for its own era has
// left the repair path, and renaming another run's record buys nothing.
{
    const oddNames = [...logFile.entries()]
        .filter(([, f]) => !/^\d{8}-\d{4}-[a-z0-9-]+\.log$/.test(f))
        .map(([, f]) => f);
    if (oddNames.length) {
        note("log filenames not in 5's <stamp>-<repo>.log shape (older runs, "
            + "reported not failed): " + oddNames.join(", "));
    }
}

// ------------------------------------------------- 1. a trailer owes a log
//
// 4.2 makes the trailer "load-bearing, not bookkeeping" -- 4.4 selects on it.
// A trailer whose stamp names no log is a set of commits with no stated repair
// path, which is the one thing the whole of section 4 exists to guarantee.
if (logs.size === 0) {
    skip("1 every Autopilot-Run trailer has a run log",
        ".central/runs/ is gitignored and empty here - a clone has no runs to "
        + "audit, so this is an ANSWER and not a gap");
} else if (trailers.size === 0) {
    skip("1 every Autopilot-Run trailer has a run log", "no trailered commits");
} else {
    // Only stamps that have a log SOMEWHERE are in scope: a log deleted by a
    // person is their business, and this gate is not a retention policy.
    const orphans = [...trailers].filter(s => !logs.has(stampDate(s)));
    const auditable = trailers.size - orphans.length;
    check(`1 every auditable trailer has a run log (${auditable}/${trailers.size})`,
        auditable > 0,
        "no trailered stamp has a log - either the logs were pruned or no run "
        + "ever wrote one");
    if (orphans.length) {
        note("stamps with no log in this working copy (pruned, never written, or "
            + "a run still open): " + orphans.join(", "));
    }
}

// ---------------------------------------- 2. a log names its restore tag,
//                                             and says whether it was attended
//
// 5 requires the log to name its own tag: "a run whose log does not name its
// own tag has not left a repair path". 3.1(g) requires the attendance to be
// recorded IN THE LOG "so a later reader can separate the two kinds without a
// judgement about which commits look supervised". Both are checked here, and
// the second one is the whole reason this suite exists.
if (logs.size === 0) {
    skip("2 every run log names its restore tag and its attendance",
        ".central/runs/ is empty here");
} else {
    // 3.1(g) was ruled 2026-08-21 (PRINCIPAL-HARNESSATTEND-01). A log written
    // before that date owes no `attended:` line, and demanding one would mean
    // somebody retro-fitting an attendance claim about a run they did not make
    // -- which is the forged record 3.1(b) is written to prevent, arrived at by
    // way of a green gate. So the obligation is DATE-SCOPED, and the date is in
    // the code rather than in a comment about the code.
    const ATTEND_RULED = "20260821";
    const noTag = [], noAttend = [], preRule = [];
    for (const [dt, body] of logs) {
        if (!body.includes("autopilot/" + dt)) noTag.push(dt);
        if (dt.slice(0, 8) < ATTEND_RULED) { preRule.push(dt); continue; }
        if (!/^\s*attended:\s*\S/im.test(body)) noAttend.push(dt);
    }
    check(`2a every run log names its own restore tag (${logs.size - noTag.length}/${logs.size})`,
        noTag.length === 0, "missing the tag: " + noTag.join(", "));

    const inScope = logs.size - preRule.length;
    check(`2b every run log since 3.1(g) states whether it was attended `
        + `(${inScope - noAttend.length}/${inScope})`,
        noAttend.length === 0,
        "no `attended:` line: " + noAttend.join(", ") + " - 3.1(g). A log that "
        + "does not say leaves a later reader guessing from which commits look "
        + "supervised, which is exactly the judgement the rule removes");
    if (preRule.length) {
        note(`${preRule.length} log(s) predate 3.1(g) (ruled 2026-08-21) and owe `
            + "no attendance line: " + preRule.join(", "));
    }
}

// ------------------------------------------------ 3. a restore tag owes a log
//
// The weaker direction, and deliberately not a failure. A tag with no log means
// a run tagged its start and then wrote nothing -- which is what a correctly
// deferring run does, and 5b makes deferral legitimate. So this REPORTS.
if (tags.size === 0) {
    skip("3 every restore tag has a run log", "no autopilot tags in this copy");
} else {
    const tagsNoLog = [...tags].filter(s => !logs.has(stampDate(s)));
    if (tagsNoLog.length === 0) {
        check(`3 every restore tag has a run log (${tags.size}/${tags.size})`, true);
    } else {
        skip("3 every restore tag has a run log",
            tagsNoLog.length + " tag(s) with no log: " + tagsNoLog.join(", ")
            + " - legitimate for a run that tagged its start and then deferred "
            + "(5b), so this is REPORTED and not failed");
    }
}

// ------------------------------- 4. what this suite cannot see, said out loud
//
// A gate suite that lists only what it checks is read as a boundary. This one
// prints its blind spot every run, because the blind spot is where the incident
// that caused this suite actually lives.
console.log("\nBLIND SPOT, stated every run rather than documented once:");
console.log("  An off-machine act -- a push, a public pull request, a message");
console.log("  to a person -- that carries NO Autopilot-Run trailer is invisible");
console.log("  to every gate above, and to every gate that could be written.");
console.log("  HARNESS-AUTHORITY 4.2: a commit with no trailer is");
console.log("  indistinguishable from a person's. The record is what closes");
console.log("  that, not a check: 3.1(b) makes the claim carry the Principal's");
console.log("  own words, and 5 makes the run log carry it.");

console.log("\n" + passed + " passed, " + failed + " failed, " + skipped + " skipped");
process.exit(failed ? 1 : 0);
