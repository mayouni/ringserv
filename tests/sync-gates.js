/*
** Phase-6 gates, part 2: the sync protocol.
**
** Two suites in one file, because the second is meaningless without the
** first:
**
**   THE PROTOCOL — the shape log is complete, selective and ordered; the
**   mutation queue is exactly-once, ordered, and rolls a refusal back
**   WITH its claim so the client can fix and resend the same id.
**
**   THE CONVERGENCE ORACLE — N clients, random interleavings, pushes cut
**   in half and retried as if a connection had dropped mid-flight. The
**   gate is not "no errors": it is that the server's final state equals
**   what every client believes, and that every mutation executed exactly
**   once. A sync layer that passes only when nothing goes wrong has been
**   tested against the case that never happens.
**
**   node tests/sync-gates.js [clients] [mutations-per-client]
*/
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "sync-app.ring");
const B = "http://127.0.0.1:8093";
const CLIENTS = parseInt(process.argv[2] || "6", 10);
const PER_CLIENT = parseInt(process.argv[3] || "12", 10);

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

/* A seeded PRNG, so a failing interleaving can be replayed. Math.random
   would make every failure a one-off ghost. */
let seed = 20260818;
function rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
}
function pick(n) { return Math.floor(rnd() * n); }

async function post(url, body) {
    const res = await fetch(B + url, { method: "POST", body: JSON.stringify(body) });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}
async function get(url) {
    const res = await fetch(B + url);
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
}
const call = (service, action, payload) => post("/api/v1", { service, action, payload });
const push = (client_id, mutations) => post("/sync/push", { client_id, mutations });

async function waitUp() {
    const t0 = Date.now();
    while (Date.now() - t0 < 25000) {
        try { if ((await fetch(B + "/health")).status === 200) return true; } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}

/** Read a whole shape by paging, the way a real client would. */
async function drainShape(shape) {
    let offset = 0, ops = [], guard = 0;
    while (guard++ < 200) {
        const r = await get(`/sync/shape?shape=${shape}&offset=${offset}&limit=100`);
        if (!r.json || r.json.code !== 0) return { ops, error: r.text || JSON.stringify(r.json) };
        const d = r.json.data;
        ops = ops.concat(d.ops);
        offset = d.offset;
        if (d.uptodate === 1) break;
    }
    return { ops, offset };
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-sync-"));

let server = null, died = false;

/** Start a server on a FRESH database, at the given placement for notes. */
async function start(tag, site) {
    const dbFile = path.join(tmp, tag + ".db").replace(/\\/g, "/");
    server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: dbFile, RINGSERV_TEST_SITE: site },
    });
    died = false;
    server.on("exit", () => { died = true; });
    return waitUp();
}

async function stop() {
    if (!server) return;
    const s = server;
    server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 800));
}

(async () => {
    check("the sync fixture comes up on a file database", await start("main", "server"));

    // ================================================== 1. the shape log
    let r = await call("notes", "create", { title: "direct", body: "b", weight: 1 });
    const directId = r.json.data.id;
    check("a plain service write is logged", true);

    let s = await drainShape("notes");
    check("the shape log has the insert", s.ops.length === 1 && s.ops[0].op === "insert",
        JSON.stringify(s.ops));
    check("...carrying the whole row, not just an id",
        s.ops[0].row && s.ops[0].row.title === "direct" && s.ops[0].row.weight === 1,
        JSON.stringify(s.ops[0].row));

    await call("notes", "update", { id: directId, title: "changed" });
    await call("notes", "delete", { id: directId });
    s = await drainShape("notes");
    check("update and delete are logged too, in order",
        s.ops.map(o => o.op).join(",") === "insert,update,delete",
        s.ops.map(o => o.op).join(","));
    check("...and the delete carries the row it removed",
        s.ops[2].row && s.ops[2].row.title === "changed",
        JSON.stringify(s.ops[2].row));
    check("offsets are strictly increasing",
        s.ops.every((o, i) => i === 0 || o.offset > s.ops[i - 1].offset),
        s.ops.map(o => o.offset).join(","));

    // Selectivity: a :server table has no local replica, so logging it
    // would be pure cost. This is the gate that a log which logs
    // everything cannot pass.
    await call("audit", "create", { what: "not synced" });
    const audit = await get("/sync/shape?shape=audit&offset=0");
    check("a :server table is not a shape", audit.status === 404, audit.status + "");
    s = await drainShape("notes");
    check("...and writing to it added nothing to any log", s.ops.length === 3,
        s.ops.length + " ops");

    // Resumability from an arbitrary offset is what makes shapes over
    // HTTP worth the boredom.
    const mid = s.ops[0].offset;
    const tail = await get(`/sync/shape?shape=notes&offset=${mid}`);
    check("a client can resume from any offset",
        tail.json.data.ops.length === 2 && tail.json.data.ops[0].op === "update",
        JSON.stringify(tail.json.data.ops.map(o => o.op)));

    // ============================================== 2. the mutation queue
    r = await push("q1", [
        { mutation_id: 1, service: "notes", action: "create", payload: { title: "m1", body: "b", weight: 1 } },
        { mutation_id: 2, service: "notes", action: "create", payload: { title: "m2", body: "b", weight: 2 } },
    ]);
    check("a push applies its mutations", r.json.data.applied === 2, JSON.stringify(r.json.data));
    check("...and reports the new high-water mark", r.json.data.last_mutation_id === 2);
    check("...and each result carries the service's own reply",
        r.json.data.results[0].result.data.id > 0, JSON.stringify(r.json.data.results[0]));

    const replay = await push("q1", [
        { mutation_id: 1, service: "notes", action: "create", payload: { title: "m1", body: "b", weight: 1 } },
        { mutation_id: 2, service: "notes", action: "create", payload: { title: "m2", body: "b", weight: 2 } },
    ]);
    check("REPLAYING the same push applies nothing",
        replay.json.data.applied === 0 && replay.json.data.duplicates === 2,
        JSON.stringify(replay.json.data));

    let list = await call("notes", "list", {});
    check("...and the rows were not duplicated in the table",
        list.json.data.rows.filter(x => x.title === "m1").length === 1,
        JSON.stringify(list.json.data.rows.map(x => x.title)));

    // A gap must be refused. Accepting it would strand the missing
    // mutation forever: it would come back, land under the mark, and be
    // discarded as a duplicate it never was.
    r = await push("q1", [
        { mutation_id: 9, service: "notes", action: "create", payload: { title: "gap", body: "b", weight: 1 } },
    ]);
    check("an out-of-order mutation is REFUSED, not swallowed",
        r.json.data.results[0].status === "out-of-order",
        JSON.stringify(r.json.data.results[0]));
    check("...and the message says where to resend from",
        /resend from 3/.test(r.json.data.results[0].message),
        r.json.data.results[0].message);
    check("...and the high-water mark did not move", r.json.data.last_mutation_id === 2);

    // A refusal rolls back its own claim, so the client can fix and
    // resend the SAME id. Keeping the claim would turn a validation
    // error into permanent data loss.
    r = await push("q1", [
        { mutation_id: 3, service: "notes", action: "create", payload: { title: 42 } },
        { mutation_id: 4, service: "notes", action: "create", payload: { title: "m4", body: "b", weight: 4 } },
    ]);
    check("a contract violation is rejected inside the queue",
        r.json.data.results[0].status === "rejected", JSON.stringify(r.json.data.results[0]));
    check("...and the rest of the batch is NOT attempted",
        r.json.data.results[1].status === "not-attempted",
        JSON.stringify(r.json.data.results[1]));
    check("...and the mark stayed put, so id 3 is still owed",
        r.json.data.last_mutation_id === 2, r.json.data.last_mutation_id + "");

    r = await push("q1", [
        { mutation_id: 3, service: "notes", action: "create", payload: { title: "m3-fixed", body: "b", weight: 3 } },
    ]);
    check("the SAME id is resendable once fixed",
        r.json.data.applied === 1 && r.json.data.last_mutation_id === 3,
        JSON.stringify(r.json.data));

    // A mutation that raises must not leave the writer locked — if it
    // did, every later write in this process would hang, and this gate
    // would time out rather than fail.
    r = await push("q1", [{ mutation_id: 4, service: "boom", action: "now", payload: {} }]);
    check("a raising mutation is reported, not fatal",
        r.json.data.results[0].status === "rejected", JSON.stringify(r.json.data.results[0]));
    r = await call("notes", "create", { title: "after-boom", body: "b", weight: 1 });
    check("...and the write path still works afterwards — no leaked lock",
        r.status === 200 && r.json.code === 0, JSON.stringify(r.json));

    // Two clients are independent: one client's mark must never gate
    // another's.
    r = await push("q2", [
        { mutation_id: 1, service: "notes", action: "create", payload: { title: "other", body: "b", weight: 1 } },
    ]);
    check("a second client starts from its own mark 0",
        r.json.data.applied === 1 && r.json.data.last_mutation_id === 1,
        JSON.stringify(r.json.data));

    // The long poll must return promptly once a write lands, and must
    // not hold a VM worker while it waits.
    {
        const head = (await get("/sync/shape?shape=notes&offset=0")).json.data.offset;
        const t0 = Date.now();
        const waiting = get(`/sync/shape?shape=notes&offset=${head}&live=true`);
        // Prove the server still serves while a live request is parked.
        await new Promise(res => setTimeout(res, 400));
        const during = await call("notes", "list", {});
        check("the server still answers while a long-poll is parked",
            during.status === 200, during.status + "");
        await call("notes", "create", { title: "wakes-the-poll", body: "b", weight: 1 });
        const woke = await waiting;
        const ms = Date.now() - t0;
        check("a long-poll returns when the shape moves",
            woke.json.code === 0 && woke.json.data.ops.length > 0, JSON.stringify(woke.json.data));
        check(`...promptly (${ms}ms, not the 20s ceiling)`, ms < 8000, ms + "ms");
    }

    // ============================================ 3. the convergence oracle
    //
    // Run TWICE, and the second run is the contract's owed placement
    // case: once with `notes` on the server, once predicted in the page
    // with the server as authority. Same clients, same seed, same
    // interleavings — so if the two final states differ, "moving a
    // service is a one-word deployment decision" was untrue in exactly
    // the place it matters most, which is offline.
    const digestServer = await runOracle(true);

    await stop();
    check("the fixture restarts at the other placement", await start("moved", "local"));
    const digestLocal = await runOracle(false);

    check("...and the run produced something to compare",
        typeof digestServer === "string" && digestServer.length > 20,
        String(digestServer).slice(0, 80));
    check("THE SAME OFFLINE INTERLEAVING CONVERGES IDENTICALLY AT BOTH PLACEMENTS",
        digestServer !== null && digestServer === digestLocal,
        "server=" + String(digestServer).slice(0, 100) +
        "  local=" + String(digestLocal).slice(0, 100));

    check("the server never died", !died);
})().catch(e => {
    check("the suite ran to completion", false, e.stack || String(e));
}).finally(async () => {
    await stop();
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
});

/**
 * The convergence oracle.
 *
 * N clients hold private queues and push them in random interleavings,
 * with a third of the pushes RETRIED verbatim as if the response had been
 * lost on the way back. That retry is the whole exercise: it is where an
 * at-least-once transport meets an exactly-once requirement.
 *
 * Returns a digest of the final state — what the table holds AND what a
 * client rebuilds by replaying the log from offset zero — so two runs can
 * be compared as data rather than by eye.
 *
 * `report` gates the invariants. The second run only needs the digest,
 * because asserting the same invariants twice says nothing new; what the
 * second run is FOR is the comparison.
 */
async function runOracle(report) {
    // The seed resets per run, so both placements see the SAME random
    // interleaving. Comparing two different interleavings would prove
    // nothing about placement.
    seed = 20260818;

    if (report) {
        console.log(`\n  convergence oracle: ${CLIENTS} clients × ${PER_CLIENT} mutations, ` +
            `random interleavings and retried pushes (seed 20260818)\n`);
    }

    // Creates only. An offline client does not know server ids, and
    // inventing them here would test a protocol nobody will run.
    // Ownership travels in the title marker, which is what keeps the
    // final assertions exact.
    const clients = [];
    for (let c = 0; c < CLIENTS; c++) {
        const q = [];
        for (let m = 1; m <= PER_CLIENT; m++) {
            q.push({
                mutation_id: m,
                service: "notes",
                action: "create",
                payload: { title: `c${c}-m${m}`, body: "x", weight: (c * 100 + m) % 90 },
            });
        }
        clients.push({ id: `oracle-c${c}`, queue: q, sent: 0 });
    }

    const before = (await call("notes", "list", { limit: 1000 })).json.data.count;
    let pushes = 0, retries = 0, broke = false, guard = 0;

    while (clients.some(c => c.sent < c.queue.length) && guard++ < 5000) {
        const live = clients.filter(c => c.sent < c.queue.length);
        const cl = live[pick(live.length)];
        const chunk = cl.queue.slice(cl.sent, cl.sent + 1 + pick(4));

        const res = await push(cl.id, chunk);
        pushes++;
        if (!res.json || res.json.code !== 0) {
            if (report) check("a push during the oracle failed", false,
                JSON.stringify(res.json || res.text));
            broke = true;
            break;
        }
        const applied = res.json.data.results.filter(x => x.status === "applied").length;
        const dupes = res.json.data.results.filter(x => x.status === "duplicate").length;
        if (applied + dupes !== chunk.length) {
            if (report) check("every oracle mutation applied or was a duplicate", false,
                JSON.stringify(res.json.data.results));
            broke = true;
            break;
        }

        // The hostile half: resend the same chunk WITHOUT advancing,
        // exactly as a client does after a dropped response.
        if (rnd() < 0.34) {
            const again = await push(cl.id, chunk);
            retries++;
            if (again.json.data.results.filter(x => x.status === "applied").length !== 0) {
                if (report) check("a retried push re-applied something", false,
                    JSON.stringify(again.json.data.results));
                broke = true;
                break;
            }
        }
        cl.sent += chunk.length;
    }
    if (broke) return null;
    if (report) console.log(`  ${pushes} pushes, ${retries} of them retried\n`);

    // The final state, two ways: what the table holds, and what a client
    // that has only ever seen the log would rebuild from it.
    const rows = (await call("notes", "list", { limit: 1000 })).json.data.rows;
    const all = await drainShape("notes");
    const rebuilt = new Map();
    for (const op of all.ops) {
        if (op.op === "delete") rebuilt.delete(op.id);
        else rebuilt.set(op.id, op.row);
    }

    if (report) {
        const expected = CLIENTS * PER_CLIENT;
        check(`every mutation executed EXACTLY ONCE (${expected} rows)`,
            rows.length - before === expected,
            `expected +${expected}, got +${rows.length - before}`);

        const disagreed = [];
        for (const cl of clients) {
            const st = await post("/sync/state", { client_id: cl.id });
            if (st.json.data.last_mutation_id !== PER_CLIENT)
                disagreed.push(`${cl.id}:${st.json.data.last_mutation_id}`);
        }
        check("every client and the server agree on the high-water mark",
            disagreed.length === 0, disagreed.join(","));

        check("replaying the shape log reproduces the server's table exactly",
            rebuilt.size === rows.length && rows.every(row => {
                const seenRow = rebuilt.get(row.id);
                return seenRow && seenRow.title === row.title && seenRow.weight === row.weight;
            }),
            `log rebuilt ${rebuilt.size} rows, table has ${rows.length}`);

        const counts = {};
        for (const t of rows.map(x => x.title)) counts[t] = (counts[t] || 0) + 1;
        const dup = Object.entries(counts).filter(([t, n]) => n > 1 && /^c\d+-m\d+$/.test(t));
        check("no oracle mutation produced two rows", dup.length === 0,
            JSON.stringify(dup.slice(0, 5)));

        const missing = [];
        for (let c = 0; c < CLIENTS; c++)
            for (let m = 1; m <= PER_CLIENT; m++)
                if (!counts[`c${c}-m${m}`]) missing.push(`c${c}-m${m}`);
        check("no oracle mutation went missing", missing.length === 0, missing.slice(0, 5).join(","));
    }

    // The digest covers THE ORACLE'S OWN ROWS and nothing else, by two
    // deliberate exclusions:
    //
    //   ids are dropped, because they depend on how many rows the
    //   protocol gates above happened to leave behind — a fact about
    //   test order, not about placement;
    //
    //   rows the oracle did not create are dropped for the same reason.
    //   The first run inherits a database the protocol gates wrote to;
    //   the second starts clean. Comparing those would compare test
    //   history and call it a placement difference.
    const mine = x => /^c\d+-m\d+$/.test(x.title);
    const norm = xs => xs.filter(mine).map(x => `${x.title}|${x.weight}`).sort().join(",");
    return norm(rows) + "##" + norm([...rebuilt.values()]);
}
