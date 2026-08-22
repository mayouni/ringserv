/*
** Phase-10 gates: the gesture, and the config-file form.
**
** Three promises, each gated where it would lie:
**
**   THE GESTURE IS BORING — a file of plain functions serves with zero
**   declaration lines, the mapping is exactly what --explain prints, a
**   leading underscore is private, a missing parameter is refused with
**   every missing name at once. No positional guessing, no coercion.
**
**   THE FILE FORM IS THE SAME DECLARATION — an app configured by
**   ringserv.yaml answers byte-identically to the same app configured in
**   RingServ([...]); a collision is REPORTED and the declaration wins.
**
**   THE SUBSET REFUSES BY NAME — anchors, tags, flow style, block
**   scalars, sequences, tabs, document markers: each fails the boot
**   naming the construct and the line, never a silent misread. And the
**   Norway problem specifically: `country: no` stays the string "no".
**
**   node tests/gesture-gates.js
*/
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RINGSERV = path.join(ROOT, "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");
const CALC = path.join(ROOT, "tests", "fixtures", "gesture", "calc.ring");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

async function post(port, body) {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1`,
        { method: "POST", body: JSON.stringify(body) });
    return res.text();
}
async function waitUp(port) {
    const t0 = Date.now();
    while (Date.now() - t0 < 25000) {
        try {
            if ((await fetch(`http://127.0.0.1:${port}/health`)).status === 200) return true;
        } catch {}
        await new Promise(r => setTimeout(r, 150));
    }
    return false;
}
let server = null;
function start(args, cwd) {
    server = spawn(RINGSERV, args, {
        stdio: ["ignore", "pipe", "pipe"], cwd: cwd || ROOT,
    });
    let out = "";
    server.stdout.on("data", d => { out += d; });
    server.stderr.on("data", d => { out += d; });
    server.getOutput = () => out;
    return server;
}
async function stop() {
    if (!server) return;
    const s = server; server = null;
    s.kill();
    await new Promise(r => setTimeout(r, 800));
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ringserv-gesture-"));

/** Run `ringserv eval` and hand back everything it printed, both streams. */
function evalRing(code) {
    const r = spawnSync(RINGSERV, ["eval", code], { encoding: "utf8", cwd: ROOT });
    return { status: r.status, out: (r.stdout || "") + (r.stderr || "") };
}

(async () => {
    // ================================================= 1. --explain
    const ex = spawnSync(RINGSERV, ["serve", "--explain", CALC], { encoding: "utf8" });
    const exOut = (ex.stdout || "") + (ex.stderr || "");
    check("--explain prints the mapping without serving", ex.status === 0);
    check("...every exposed function with its parameters",
        /calc\.hello\(name\)/.test(exOut) && /calc\.add\(a, b\)/.test(exOut) &&
        /calc\.stats\(xs\)/.test(exOut), exOut);
    check("...the private function, named as private",
        /private/.test(exOut) && /_secret/.test(exOut), exOut);
    check("...and the call shape", /POST \/api\/v1/.test(exOut), exOut);

    // ================================================= 2. the gesture serves
    start(["serve", CALC]);
    check("a file of plain functions comes up (port from ringserv.yaml)",
        await waitUp(8095));

    let r = JSON.parse(await post(8095, { service: "calc", action: "hello", payload: { name: "ada" } }));
    check("a string in, a string out, enveloped",
        r.code === 0 && r.data === "Hello, ada!", JSON.stringify(r));

    r = JSON.parse(await post(8095, { service: "calc", action: "add", payload: { a: 19, b: 23 } }));
    check("numbers map by name", r.code === 0 && r.data === 42, JSON.stringify(r));

    r = JSON.parse(await post(8095, { service: "calc", action: "add", payload: { B: 2, A: 1 } }));
    check("...case-insensitively, order-independently",
        r.code === 0 && r.data === 3, JSON.stringify(r));

    r = JSON.parse(await post(8095, { service: "calc", action: "stats", payload: { xs: [3, 4, 5] } }));
    check("a list in, a mapping out",
        r.code === 0 && r.data.count === 3 && r.data.sum === 12, JSON.stringify(r));

    r = JSON.parse(await post(8095, { service: "calc", action: "add", payload: { a: 1, b: 2, extra: 9 } }));
    check("extra payload keys are ignored, documented as such",
        r.code === 0 && r.data === 3, JSON.stringify(r));

    let res = await fetch("http://127.0.0.1:8095/api/v1", {
        method: "POST",
        body: JSON.stringify({ service: "calc", action: "add", payload: { a: 1 } }) });
    r = JSON.parse(await res.text());
    check("a missing parameter is refused as 422, by name",
        res.status === 422 && r.code === 1 && /missing parameter/.test(r.message) &&
        /b/.test(r.message), res.status + " " + JSON.stringify(r));

    r = JSON.parse(await post(8095, { service: "calc", action: "_secret", payload: {} }));
    check("a leading underscore is private over the wire",
        r.code === 1 && /unknown action/.test(r.message), JSON.stringify(r));
    await stop();

    // ============================================ 3. what serve refuses
    const declApp = path.join(tmp, "already.ring");
    fs.writeFileSync(declApp, 'RingServ([ :port = 8099, :services = [] ])\n');
    let sr = spawnSync(RINGSERV, ["serve", declApp], { encoding: "utf8" });
    check("a file that declares RingServ() is refused toward `run`",
        sr.status !== 0 && /already declares/.test((sr.stdout || "") + (sr.stderr || "")));

    const badName = path.join(tmp, "bad-name.ring");
    fs.writeFileSync(badName, "func f\n\treturn 1\n");
    sr = spawnSync(RINGSERV, ["serve", badName], { encoding: "utf8" });
    check("a file name that cannot be a service name is refused, with the rule",
        sr.status !== 0 && /valid/.test((sr.stdout || "") + (sr.stderr || "")));

    const empty = path.join(tmp, "empty.ring");
    fs.writeFileSync(empty, "# nothing here\n");
    sr = spawnSync(RINGSERV, ["serve", empty], { encoding: "utf8" });
    check("a file with no functions refuses to pretend it is a service",
        sr.status !== 0 && /no functions/.test((sr.stdout || "") + (sr.stderr || "")));

    // ======================================== 4. --port beats the file
    start(["serve", "--port", "8098", CALC]);
    check("--port outranks ringserv.yaml", await waitUp(8098));
    await stop();

    // ============================== 5. the file form IS the declaration
    // The same service twice: configured in Ring, configured in yaml.
    // The gate is byte identity of the answers.
    const declDir = path.join(tmp, "decl"); fs.mkdirSync(declDir);
    const fileDir = path.join(tmp, "file"); fs.mkdirSync(fileDir);
    const dbDecl = path.join(tmp, "decl.db").replace(/\\/g, "/");
    const dbFile = path.join(tmp, "file.db").replace(/\\/g, "/");
    const body = [
        ':services = [',
        '  :notes = [',
        '    :put = func aReq {',
        '      DataExec("insert into notes (title) values (?)", [ aReq[:payload][:title] ])',
        '      return Reply(:ok, [ :id = DataInsertId() ]) },',
        '    :all = func aReq {',
        '      return Reply(:ok, [ :rows = DataQuery("select id, title from notes order by id", []) ]) }',
        '  ]',
        '],',
        ':data = [ :notes = [ :title ] ]',
    ].join("\n");
    fs.writeFileSync(path.join(declDir, "app.ring"),
        `RingServ([\n:port = 8101,\n:workers = 2,\n:database = "${dbDecl}",\n${body}\n])\n`);
    fs.writeFileSync(path.join(fileDir, "app.ring"),
        `RingServ([\n${body}\n])\n`);
    fs.writeFileSync(path.join(fileDir, "ringserv.yaml"),
        `# the same configuration, as a file\nport: 8101\nworkers: 2\ndatabase: "${dbFile}"\n`);

    const answers = [];
    for (const dir of [declDir, fileDir]) {
        start(["run", path.join(dir, "app.ring")]);
        check(`the ${path.basename(dir)}-form app comes up on 8101`, await waitUp(8101));
        const a1 = await post(8101, { service: "notes", action: "put", payload: { title: "one" } });
        const a2 = await post(8101, { service: "notes", action: "all", payload: {} });
        answers.push(a1 + "###" + a2);
        await stop();
    }
    check("the two forms answer BYTE-IDENTICALLY", answers[0] === answers[1],
        answers[0] + "  vs  " + answers[1]);
    check("...and the yaml-named database file exists where it said",
        fs.existsSync(dbFile));

    // ================================================ 6. the collision
    const clashDir = path.join(tmp, "clash"); fs.mkdirSync(clashDir);
    fs.writeFileSync(path.join(clashDir, "app.ring"),
        'RingServ([ :port = 8102, :services = [ :ping = [ :go = func aReq { return Reply(:ok, 1) } ] ] ])\n');
    fs.writeFileSync(path.join(clashDir, "ringserv.yaml"), "port: 7777\n");
    start(["run", path.join(clashDir, "app.ring")]);
    check("on a collision the declaration wins the port", await waitUp(8102));
    await new Promise(r => setTimeout(r, 300));
    check("...and the collision is REPORTED, both values named",
        /collides with the declaration/.test(server.getOutput()) &&
        /7777/.test(server.getOutput()) && /8102/.test(server.getOutput()),
        server.getOutput().split("\n").slice(0, 4).join(" | "));
    await stop();

    // ==================================== 7. the subset refuses by name
    const refusals = [
        ['RsConfigParse("port: &x")', /anchors/],
        ['RsConfigParse("port: *x")', /anchors|aliases/],
        ['RsConfigParse("port: !!str 80")', /tags/],
        ['RsConfigParse("port: {a: 1}")', /flow style/],
        ['RsConfigParse("text: |")', /block scalars/],
        ['RsConfigParse("- item")', /sequences/],
        ['RsConfigParse("---")', /document markers/],
        ['RsConfigParse(char(9) + "port: 1")', /tab indentation/],
        ['RsConfigParse("a: " + char(34) + "unterminated")', /unterminated/],
    ];
    for (const [code, want] of refusals) {
        const r2 = evalRing("? " + code);
        check("refused by name: " + (want.source), r2.status !== 0 && want.test(r2.out),
            r2.out.split("\n")[0]);
    }
    check("every refusal names its line number",
        /line 1/.test(evalRing('? RsConfigParse("port: &x")').out));

    // ================================= 8. the scalars that tell the truth
    let e = evalRing('a = RsConfigParse("country: no") ? a[1][2]');
    check("the Norway problem: `no` stays the string no", /^no/.test(e.out.trim()), e.out);
    e = evalRing('a = RsConfigParse("flag: true") ? a[1][2]');
    check("true is a boolean 1", e.out.trim().startsWith("1"), e.out);
    e = evalRing('a = RsConfigParse("port: 8090  # why") ? a[1][2]');
    check("inline comments strip; the number survives", e.out.trim().startsWith("8090"), e.out);
    e = evalRing('a = RsConfigParse("db: " + char(34) + ":memory:" + char(34)) ? a[1][2]');
    check("a quoted value keeps its colons", e.out.trim().startsWith(":memory:"), e.out);

    // =============================================== 9. new --gesture
    const scaffold = path.join(tmp, "scaffold"); fs.mkdirSync(scaffold);
    const nr = spawnSync(RINGSERV, ["new", "greeter", "--gesture"], { encoding: "utf8", cwd: scaffold });
    check("new --gesture scaffolds the first-touch pair", nr.status === 0 &&
        fs.existsSync(path.join(scaffold, "greeter", "greeter.ring")) &&
        fs.existsSync(path.join(scaffold, "greeter", "ringserv.yaml")));
    const sx = spawnSync(RINGSERV,
        ["serve", "--explain", path.join(scaffold, "greeter", "greeter.ring")], { encoding: "utf8" });
    check("...and it explains cleanly, unedited",
        sx.status === 0 && /greeter\.hello\(name\)/.test((sx.stdout || "")));

    // ========================================== 10. the doc runs as written
    // The ninety-seconds example is EXTRACTED from docs/gesture.md and
    // driven — the page's own fence, not a copy that can drift.
    const doc = fs.readFileSync(path.join(ROOT, "docs", "gesture.md"), "utf8");
    const fence = /```ring\r?\n([\s\S]*?)```/.exec(doc);
    check("gesture.md carries its ring example", !!fence);
    if (fence) {
        const docDir = path.join(tmp, "doc"); fs.mkdirSync(docDir);
        const docApp = path.join(docDir, "calc.ring");
        fs.writeFileSync(docApp, fence[1]);
        start(["serve", docApp]);
        check("the doc's example serves on the default port, as the doc's curl says",
            await waitUp(8080));
        const dr = JSON.parse(await post(8080,
            { service: "calc", action: "add", payload: { a: 19, b: 23 } }));
        check("...and answers exactly what the doc prints",
            dr.code === 0 && dr.message === "OK" && dr.data === 42, JSON.stringify(dr));
        await stop();
    }

    await stop();
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
})().catch(async e => {
    console.error("gesture-gates: " + (e && e.stack || e));
    await stop();
    process.exit(2);
});
