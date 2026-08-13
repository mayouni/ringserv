/*
** Soak-lite: N requests through the worker pool while watching the server
** process RSS. Not the phase-8 hours-long soak — a per-commit smoke that
** catches gross per-request leaks (RSS must flatten, not climb linearly).
**
** Usage: node tests/soak-lite.js [requests]      (default 2000)
*/
const { spawn, execSync } = require("child_process");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const FIXTURE = path.join(__dirname, "fixtures", "hello-app.ring");
const BASE = "http://127.0.0.1:8093";
const N = parseInt(process.argv[2] || "2000", 10);

function rssMb(pid) {
    try {
        if (process.platform === "win32") {
            const out = execSync(
                `powershell -NoProfile -Command "(Get-Process -Id ${pid}).WorkingSet64"`,
                { timeout: 15000 }).toString().trim();
            return Math.round(parseInt(out, 10) / 1024 / 1024 * 10) / 10;
        }
        const out = execSync(`ps -o rss= -p ${pid}`).toString().trim();
        return Math.round(parseInt(out, 10) / 1024 * 10) / 10;
    } catch { return -1; }
}

(async () => {
    const server = spawn(RINGSERV, ["run", FIXTURE], { stdio: ["ignore", "ignore", "pipe"] });
    let died = false;
    server.on("exit", () => { died = true; });

    const t0 = Date.now();
    while (Date.now() - t0 < 20000) {
        try { if ((await fetch(BASE + "/health")).status === 200) break; } catch {}
        await new Promise(r => setTimeout(r, 250));
    }

    const samples = [];
    let errors = 0;
    for (let i = 0; i < N; i++) {
        const r = await fetch(BASE + "/api/v1", {
            method: "POST",
            body: JSON.stringify({ service: "math", action: "square", payload: { n: i % 1000 } }),
        }).catch(() => null);
        if (!r || r.status !== 200) errors++;
        else {
            const j = await r.json();
            if (j.data.square !== (i % 1000) * (i % 1000)) errors++;
        }
        if (i === 99 || (i + 1) % Math.max(1, Math.floor(N / 5)) === 0) {
            samples.push({ at: i + 1, mb: rssMb(server.pid) });
        }
        if (died) break;
    }
    server.kill();

    console.log("requests:", N, " errors:", errors, " died:", died);
    for (const s of samples) console.log(`  after ${s.at}: ${s.mb} MB RSS`);
    const first = samples[0], last = samples[samples.length - 1];
    const growth = last.mb - first.mb;
    const ok = !died && errors === 0 && growth < 20;
    console.log(ok
        ? `\nSoak-lite PASSED (growth ${growth.toFixed(1)} MB over ${N - first.at} requests).`
        : `\nSoak-lite FAILED (growth ${growth.toFixed(1)} MB, errors ${errors}, died ${died}).`);
    process.exit(ok ? 0 : 1);
})().catch(e => { console.error("harness crashed:", e); process.exit(1); });
