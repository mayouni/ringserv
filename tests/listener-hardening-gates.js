/*
** Malformed bytes on the wire must never take the process down.
**
** Routed here 2026-08-26 via Central's mailbox: zing's own dev server
** panicked on an empty HTTP request-line target -- `GET  HTTP/1.1`,
** the target sliced down to a zero-length string and indexed anyway.
** Their handler was wrapped in `catch {}`, and a catch cannot see a
** panic: it exits the WHOLE PROCESS, not the one connection, because
** Zig has no per-thread unwind to stop it at. Wrapping request
** handling in error-handling code proves nothing about that class of
** bug -- the two look identical in the source and behave nothing alike.
**
** zing's own words: they had not read RingServ's server and made no
** claim about it either way. This suite is that claim, made and
** checked rather than assumed:
**
**   RingServ parses HTTP through a vendored library (vendor/httpz),
**   not a hand-rolled parser -- and its request-line/header parser
**   guards every fixed-size index with an explicit length check
**   (`if (buf_len == 0) return false`, `if (buf.len < 10) return
**   false`, ...) rather than leaning on Zig's compiled-in bounds
**   checking, which is exactly as well as it matters: RingServ ships
**   ReleaseFast (build.zig), where that compiled-in safety net does
**   not exist. An unchecked index in ReleaseFast is not a clean
**   panic -- it is silent undefined behaviour, worse than a crash.
**
** This suite does not re-derive that from the source. It fires the
** bytes at a live process and reads /health afterward, because a
** reading of the parser proves what the code says, not what the
** process does when the bytes actually land.
**
**   node tests/listener-hardening-gates.js
*/
const { spawn } = require("child_process");
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const PORT = 8371;
const B = "http://127.0.0.1:" + PORT;

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

function raw(bytes, waitMs) {
    return new Promise((resolve) => {
        const sock = net.createConnection(PORT, "127.0.0.1", () => sock.write(bytes));
        sock.on("data", () => {});
        sock.on("error", () => {});
        setTimeout(() => { try { sock.destroy(); } catch {} resolve(); }, waitMs);
    });
}
async function health() {
    try {
        const r = await fetch(B + "/health", { signal: AbortSignal.timeout(1000) });
        return r.status;
    } catch (e) { return -1; }
}

// One line per case: the malformed bytes a client could send, no
// well-formedness assumed. Named after what makes each one adversarial,
// so a failure reads as "this shape broke it" rather than "case 7 broke".
const CASES = [
    ["empty target — the exact zing shape", "GET  HTTP/1.1\r\n\r\n"],
    ["bare CRLF, no request line at all", "\r\n\r\n"],
    ["method with no trailing space", "GET\r\n\r\n"],
    ["target with no leading method", "/ HTTP/1.1\r\n\r\n"],
    ["malformed asterisk target", "GET *X HTTP/1.1\r\n\r\n"],
    ["header line with no colon", "GET / HTTP/1.1\r\nnocolon\r\n\r\n"],
    ["header name containing a space", "GET / HTTP/1.1\r\nBad Header: x\r\n\r\n"],
    ["absolute-form target (unsupported, not undefined)", "GET http://evil/ HTTP/1.1\r\n\r\n"],
    ["a single oversized header line (17 KB)", "GET / HTTP/1.1\r\nX-Pad: " + "a".repeat(17000) + "\r\n\r\n"],
    ["garbage protocol version", "GET / XTTP/9.9\r\n\r\n"],
    ["one byte, then the client vanishes", "G"],
    ["embedded NUL bytes in the target", "GET /\x00\x00 HTTP/1.1\r\n\r\n"],
    ["a bare CR inside a header value", "GET / HTTP/1.1\r\nX: a\rb\r\n\r\n"],
    ["a negative content-length", "POST /api/v1 HTTP/1.1\r\nContent-Length: -1\r\n\r\n"],
    ["a non-numeric content-length", "POST /api/v1 HTTP/1.1\r\nContent-Length: abc\r\n\r\n"],
];

(async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-panicprobe-"));
    fs.writeFileSync(path.join(tmp, "app.ring"), `RingServ([ :port = ${PORT}, :workers = 1 ])\n`);

    const server = spawn(RINGSERV, ["run", path.join(tmp, "app.ring")], {
        stdio: ["ignore", "pipe", "pipe"],
    });
    let log = "";
    server.stdout.on("data", d => log += d);
    server.stderr.on("data", d => log += d);

    let up = false;
    for (let i = 0; i < 50 && !up; i++) {
        if (await health() === 200) up = true;
        else await new Promise(r => setTimeout(r, 100));
    }
    check("the server comes up before any adversarial byte is sent", up, log.slice(0, 300));

    if (up) {
        for (const [name, bytes] of CASES) {
            await raw(bytes, 250);
            const h = await health();
            check(name + " — process survives, /health still answers",
                h === 200, "health returned " + h + " (server exit code: " + server.exitCode + ")");
        }
    }

    server.kill();
    await new Promise(r => setTimeout(r, 300));
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(e => {
    console.error("listener-hardening-gates: " + (e && e.stack || e));
    process.exit(2);
});
