/*
** The published benchmark — the MEASURING half of docs/BENCHMARKS.md.
**
** This file exists so the numbers in that document can be reproduced by
** someone who does not trust them, which is the only kind of benchmark
** worth publishing. It therefore does several things that make the
** numbers look worse and make them true:
**
**   IT WARMS UP AND DISCARDS. The first requests pay for a cold VM, a
**   cold page cache and a cold JIT-less interpreter warming its own
**   caches. Reporting those as steady state flatters the server.
**
**   IT REPORTS p50, p90 AND p99, never a mean. A mean over a latency
**   distribution with a tail is a number that describes nobody's
**   experience — and docs/WRITES.md records the day a 20-sample mean
**   moved 2 ms because of one outlier.
**
**   IT VERIFIES THE WORK HAPPENED. Every operation checks its reply, and
**   the row count is asserted at the end. A benchmark that measures
**   failed requests measures how fast a server can say no.
**
**   IT KILLS THE PREVIOUS SERVER AND PROVES IT. `pkill` does not kill
**   processes on Windows, and two of the numbers first published in
**   docs/WRITES.md were measured against a STALE server still bound to
**   the port. That mistake cost an afternoon and is now impossible here.
**
**   node tests/bench.js [--json] [ops]
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "bench-pub.ring");
const PORT = 8096;
const B = "http://127.0.0.1:" + PORT;

const asJson = process.argv.includes("--json");
const OPS = parseInt(process.argv.find(a => /^\d+$/.test(a)) || "400", 10);
const WARMUP = Math.max(20, Math.floor(OPS / 10));

function log(...a) { if (!asJson) console.log(...a); }

/** Nothing may be listening on our port when we start, or we measure it. */
function killStale() {
    if (process.platform === "win32") {
        spawnSync("powershell", ["-NoProfile", "-Command",
            "Get-Process ringserv -ErrorAction SilentlyContinue | Stop-Process -Force"],
            { encoding: "utf8" });
    } else {
        spawnSync("pkill", ["-f", "ringserv"], { encoding: "utf8" });
    }
}

async function nothingListening() {
    try {
        await fetch(B + "/health", { signal: AbortSignal.timeout(500) });
        return false;   // something answered — that is a stale server
    } catch { return true; }
}

async function call(service, action, payload) {
    const res = await fetch(B + "/api/v1", {
        method: "POST",
        body: JSON.stringify({ service, action, payload }),
    });
    return { status: res.status, json: await res.json() };
}

function stats(samples) {
    const s = samples.slice().sort((a, b) => a - b);
    const at = q => s[Math.min(s.length - 1, Math.floor(s.length * q))];
    return {
        n: s.length,
        p50: +at(0.50).toFixed(3),
        p90: +at(0.90).toFixed(3),
        p99: +at(0.99).toFixed(3),
        max: +s[s.length - 1].toFixed(3),
    };
}

/** Run `fn` n times, timing each, discarding a warmup prefix. */
async function measure(name, n, fn) {
    for (let i = 0; i < WARMUP; i++) await fn(i);
    const samples = [];
    let failures = 0;
    for (let i = 0; i < n; i++) {
        const t = process.hrtime.bigint();
        const ok = await fn(i + WARMUP);
        samples.push(Number(process.hrtime.bigint() - t) / 1e6);
        if (!ok) failures++;
    }
    const st = stats(samples);
    st.name = name;
    st.failures = failures;
    log(`  ${name.padEnd(34)} p50 ${String(st.p50).padStart(7)}  ` +
        `p90 ${String(st.p90).padStart(7)}  p99 ${String(st.p99).padStart(7)}  ` +
        `max ${String(st.max).padStart(8)}` + (failures ? `  ${failures} FAILED` : ""));
    return st;
}

(async () => {
    killStale();
    await new Promise(r => setTimeout(r, 800));
    if (!(await nothingListening())) {
        console.error("bench: something is already answering on " + B +
            " — refusing to measure it. Stop it and try again.");
        process.exit(2);
    }

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-bench-"));
    const dbFile = path.join(tmp, "bench.db").replace(/\\/g, "/");
    const server = spawn(RINGSERV, ["run", FIXTURE], {
        stdio: ["ignore", "ignore", "pipe"],
        env: { ...process.env, RINGSERV_TEST_DB: dbFile },
    });
    let died = false;
    server.on("exit", () => { died = true; });

    const results = [];
    let buildMode = "UNKNOWN";
    try {
        const t0 = Date.now();
        let up = false;
        while (Date.now() - t0 < 25000) {
            try { if ((await fetch(B + "/health")).status === 200) { up = true; break; } } catch {}
            await new Promise(r => setTimeout(r, 100));
        }
        if (!up) { console.error("bench: server did not come up"); process.exit(2); }
        const bootMs = Date.now() - t0;

        log(`\nRingServ benchmark — ${OPS} operations each, ${WARMUP} discarded as warmup`);
        log(`  ${os.cpus().length} CPUs · ${os.platform()} · node ${process.versions.node}`);
        log(`  server answered /health after ${bootMs} ms`);

        // MICRORING-DEBUGBENCH-01, taken here and not only in the binary.
        // The binary already prints its build mode, which lets a careful
        // reader check. This makes the check unnecessary: a number measured
        // on a non-release build is NAMED unpublishable at the moment it is
        // produced. The failure mode is never a reader who looks and
        // misreads — it is a number copied into a document by someone who
        // never looked.
        const ver = spawnSync(RINGSERV, ["version"], { encoding: "utf8" });
        const verOut = (ver.stdout || "") + (ver.stderr || "");
        const mode = (verOut.match(/(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)/) || [])[1]
            || "UNKNOWN";
        buildMode = mode;
        log(`  build mode: ${mode}` + (
            mode === "ReleaseFast" || mode === "ReleaseSmall" ? "" :
            mode === "UNKNOWN"
                ? "  — COULD NOT BE READ; treat these numbers as unpublishable"
                : "  — NOT A RELEASE BUILD; diagnostic only, do not publish"));
        log("");
        log("  operation                             p50      p90      p99       max   (ms)");
        log("  " + "─".repeat(76));

        // The floor: what a request costs when the service does nothing.
        // Every number below includes this, so it is worth knowing.
        results.push(await measure("health (no VM at all)", OPS, async () => {
            const r = await fetch(B + "/health");
            return r.status === 200;
        }));
        results.push(await measure("dispatch, empty service", OPS, async () => {
            const r = await call("bench", "noop", {});
            return r.json.code === 0;
        }));

        // The data path, one row at a time.
        const ids = [];
        results.push(await measure("create (one row, one commit)", OPS, async i => {
            const r = await call("notes", "create",
                { title: "b" + i, body: "x".repeat(80), weight: i % 100 });
            if (r.json.code === 0) ids.push(r.json.data.id);
            return r.json.code === 0;
        }));
        results.push(await measure("get by id", OPS, async i => {
            const r = await call("notes", "get", { id: ids[i % ids.length] });
            return r.json.code === 0;
        }));
        results.push(await measure("update one field", OPS, async i => {
            const r = await call("notes", "update", { id: ids[i % ids.length], title: "u" + i });
            return r.json.code === 0;
        }));
        results.push(await measure("list, limit 50", OPS, async () => {
            const r = await call("notes", "list", { limit: 50 });
            return r.json.code === 0 && r.json.data.rows.length > 0;
        }));
        results.push(await measure("list, limit 500 (encoding-bound)", Math.min(OPS, 200), async () => {
            const r = await call("notes", "list", { limit: 500 });
            return r.json.code === 0;
        }));

        // The second guest, so the cost of the JS path is published beside
        // the Ring one rather than guessed at.
        results.push(await measure("dispatch, JS service", OPS, async () => {
            const r = await call("jsbench", "noop", {});
            return r.json.code === 0;
        }));
        results.push(await measure("JS service calling a Ring service", Math.min(OPS, 200), async () => {
            const r = await call("jsbench", "viaRing", {});
            return r.json.code === 0;
        }));

        // Concurrency: a SWEEP, not a single number.
        //
        // A single concurrency figure hides the shape, and the shape is
        // the interesting part here: throughput climbs to roughly 2,400/s
        // and then falls off a cliff somewhere near 20 simultaneous
        // connections. docs/BENCHMARKS.md publishes that cliff as an
        // unexplained finding rather than quietly benchmarking below it.
        {
            const sweep = [];
            for (const conc of [1, 2, 4, 8, 16, 20, 24]) {
                const total = Math.max(conc * 3, 48);
                const t = process.hrtime.bigint();
                let ok = 0;
                for (let round = 0; round < total / conc; round++) {
                    const rs = await Promise.all(Array.from({ length: conc }, (_, k) =>
                        call("notes", "get", { id: ids[(round * conc + k) % ids.length] })));
                    ok += rs.filter(x => x.json.code === 0).length;
                }
                const secs = Number(process.hrtime.bigint() - t) / 1e9;
                const rps = Math.round(total / secs);
                sweep.push({ concurrency: conc, requests: total,
                    seconds: +secs.toFixed(3), rps, failures: total - ok });
                log(`  ${String(conc).padStart(3)} concurrent readers: ` +
                    `${String(rps).padStart(6)}/s   (${total} in ${secs.toFixed(2)}s` +
                    (total - ok ? `, ${total - ok} FAILED` : "") + ")");
            }
            const best = sweep.reduce((a2, b2) => (b2.rps > a2.rps ? b2 : a2));
            log(`
  peak ${best.rps}/s at concurrency ${best.concurrency}`);
            results.push({ name: "concurrency sweep", sweep, peak: best });
        }

        // The work must have happened. A benchmark that measured failures
        // measured how fast a server can say no.
        const count = (await call("notes", "list", { limit: 100000 })).json.data.count;
        const expected = (OPS + WARMUP) * 1;
        log(`\n  rows created: ${count} (expected ${expected})`);
        const verified = count === expected;
        if (!verified) console.error("bench: ROW COUNT WRONG — these numbers are not trustworthy");
        results.push({ name: "verification", rows: count, expected, verified, died });

        if (asJson) {
            console.log(JSON.stringify({
                cpus: os.cpus().length, platform: os.platform(),
                // The build mode travels WITH the numbers, so a consumer of
                // this JSON cannot strip it by accident the way a reader of
                // the header can (MICRORING-DEBUGBENCH-01).
                buildMode,
                publishable: buildMode === "ReleaseFast" || buildMode === "ReleaseSmall",
                ops: OPS, warmup: WARMUP, bootMs, results,
            }, null, 2));
        }
        process.exit(verified && !died ? 0 : 1);
    } finally {
        server.kill();
        await new Promise(r => setTimeout(r, 500));
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
    }
})();
