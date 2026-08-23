/*
** Phase-7 gates, part 1: the JS guest as a runtime.
**
** The same discipline phase 1 applied to the Ring VM, applied to the
** second guest before anything is built on it. What is under test is not
** "does QuickJS work" — it does — but whether THIS host's contract holds:
**
**   js_call's contract equals rs_call's, so the dispatcher can stop
**   knowing which guest it is talking to;
**
**   an error is a trappable error with a LINE NUMBER, not a dead worker;
**
**   an `async function` answers with its value, not with a promise —
**   otherwise "may I write this service as async?" becomes a question
**   with consequences, when the whole point is that it is not one;
**
**   the guest cannot reach the machine. No `require`, no `std`, no `os`,
**   no filesystem: quickjs-libc is deliberately not vendored, and this
**   suite is what keeps that true.
**
**   node tests/js-gates.js
*/
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const RINGSERV = path.join(__dirname, "..", "zig-out", "bin",
    process.platform === "win32" ? "ringserv.exe" : "ringserv");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("PASS  " + name); }
    else { failed++; console.log("FAIL  " + name + (detail ? "  — " + detail : "")); }
}

/** ringserv js-eval "<code>" [fn json] */
function js(code, fn, arg) {
    const args = ["js-eval", code];
    if (fn) args.push(fn, arg === undefined ? "{}" : arg);
    const r = spawnSync(RINGSERV, args, { encoding: "utf8" });
    return { status: r.status, out: ((r.stdout || "") + (r.stderr || "")).trim() };
}

// ------------------------------------------------------------ it lives
let r = js('console.log("alive", 6*7)');
check("the guest evaluates and prints", r.status === 0 && /alive 42/.test(r.out), r.out);

r = js('console.log([1,2,3].map(x => x*2).join(","))');
check("modern syntax works (arrow functions, array methods)",
    r.status === 0 && /2,4,6/.test(r.out), r.out);

r = js('console.log(JSON.stringify({a:[1,{b:2}]}))');
check("JSON is present and correct", /\{"a":\[1,\{"b":2\}\]\}/.test(r.out), r.out);

r = js('console.log("ok " + /a(b+)c/.exec("xabbbc")[1])');
check("the regexp engine is linked", /ok bbb/.test(r.out), r.out);

r = js('console.log("héllo".length, [..."日本"].length)');
check("unicode tables are linked", /5 2/.test(r.out), r.out);

// ------------------------------------------------- js_call === rs_call
r = js('function greet(p){ return { code:0, message:"OK", data:{ hello:p.name, n:p.n*2 } }; }',
    "greet", '{"name":"world","n":21}');
check("a function is called with the decoded JSON argument",
    r.status === 0 && /"hello":"world"/.test(r.out), r.out);
check("...and its return value comes back JSON-encoded",
    /"n":42/.test(r.out), r.out);

r = js('function f(){ return 1; }', "nosuchfunction", "{}");
check("calling a function that does not exist is an error, not a crash",
    r.status !== 0 && /no JS function named/.test(r.out), r.out);

r = js('function f(p){ return p; }', "f", "not json at all");
check("a malformed argument is reported, not swallowed", r.status !== 0, r.out);

// ------------------------------------------------------------- errors
r = js('function f(){\n  throw new Error("boom");\n}', "f", "{}");
check("a thrown error is trapped", r.status !== 0 && /boom/.test(r.out), r.out);
check("...with the real line number", /line 2:/.test(r.out), r.out);

r = js('function ( {');
check("a syntax error is reported with a line", r.status !== 0 && /line 1:/.test(r.out), r.out);

r = js('function f(){ throw "a bare string"; }', "f", "{}");
check("throwing a non-Error still reports something usable",
    r.status !== 0 && /bare string/.test(r.out), r.out);

// ------------------------------------------------------------- promises
r = js('async function slow(p){ await null; return {code:0,message:"OK",data:{n:p.n}}; }',
    "slow", '{"n":7}');
check("an async service answers with its VALUE, not a promise",
    r.status === 0 && /"n":7/.test(r.out), r.out);
check("...and the envelope survives intact", /"code":0/.test(r.out), r.out);

r = js('async function bad(){ await null; throw new Error("async boom"); }', "bad", "{}");
check("a rejected async fails exactly like a thrown sync",
    r.status !== 0 && /async boom/.test(r.out), r.out);

r = js('function hang(){ return new Promise(() => {}); }', "hang", "{}");
check("a promise that never settles is REPORTED, not silently {}",
    r.status !== 0 && /never settled/.test(r.out), r.out);

r = js('async function chain(){ let n = 0; for (let i=0;i<5;i++) n = await (n+i); ' +
    'return {code:0,message:"OK",data:{n}}; }', "chain", "{}");
check("a chain of awaits is drained to completion", /"n":10/.test(r.out), r.out);

// ------------------------------------------------ the guest is fenced in
//
// quickjs-libc is deliberately not vendored (build.zig says why). These
// gates are what keep that decision true as the host surface grows —
// each one is a way a guest could otherwise reach the machine.
for (const [name, expr] of [
    ["require", "typeof require"],
    ["std (quickjs-libc)", "typeof std"],
    ["os (quickjs-libc)", "typeof os"],
    ["scriptArgs", "typeof scriptArgs"],
    ["process", "typeof process"],
]) {
    const rr = js(`console.log(${expr})`);
    check(`the guest cannot reach \`${name}\``, /undefined/.test(rr.out), rr.out);
}

// eval and Function stay — they are the language, not a door to the host,
// and QuickJS has no filesystem behind them here.
r = js('console.log(typeof eval, typeof Function)');
check("the language itself is intact (eval, Function)",
    /function function/.test(r.out), r.out);

// A guest cannot take the worker down by exhausting memory: the runtime
// carries a limit, and hitting it is an error like any other.
r = js('function f(){ const a = []; for(;;) a.push(new Array(100000).fill(0)); }', "f", "{}");
check("an out-of-memory guest is an error, not a dead worker",
    r.status !== 0 && r.out.length > 0, r.out.slice(0, 120));

// ============================================ the WinterTC conformance list
//
// Graded against tests/wintertc.json — SOMEONE ELSE'S list, which is the
// point: a surface graded by its own author grades itself generous.
//
// Both directions are checked. A name claimed `present` must exist; a name
// claimed `absent` must be genuinely absent. The second half matters as
// much as the first, because a capability that quietly appears is as much
// a defect as one that quietly disappears — and `fetch` appearing by
// accident would silently undo the reason placement exists.
{
    const list = JSON.parse(fs.readFileSync(path.join(__dirname, "wintertc.json"), "utf8"));
    const claimed = list.entries.filter(e => e.status === "present");
    const absent = list.entries.filter(e => e.status === "absent");

    // One process for the whole sweep: thirty spawns would cost more than
    // the rest of this suite together.
    const probe = claimed.map(e => JSON.stringify(e.name) + '+":"+(' + e.probe + ")").join(",");
    const r = js("console.log([" + probe + '].join("\\n"))');
    const got = {};
    for (const line of r.out.split("\n")) {
        const i = line.indexOf(":");
        if (i > 0) got[line.slice(0, i)] = line.slice(i + 1);
    }
    const missing = claimed
        .filter(e => got[e.name] === undefined || got[e.name] === "undefined")
        .map(e => e.name);
    check(`every claimed WinterTC name is present (${claimed.length} of them)`,
        missing.length === 0, "missing: " + missing.join(", "));

    const wrong = [];
    for (const e of absent) {
        const expr = e.expect === "false" ? e.probe : "(" + e.probe + ') === "undefined"';
        const rr = js("console.log(" + expr + ")");
        const ok = e.expect === "false" ? /false/.test(rr.out) : /true/.test(rr.out);
        if (!ok) wrong.push(e.name);
    }
    check(`every name recorded ABSENT really is absent (${absent.length} of them)`,
        wrong.length === 0, "unexpectedly present: " + wrong.join(", "));

    // The list must explain itself: an absence with no reason is an
    // omission wearing a checklist's clothes.
    const unexplained = absent.filter(e => !e.why || e.why.length < 20).map(e => e.name);
    check("every absence carries a reason a reader can act on",
        unexplained.length === 0, unexplained.join(", "));
}

// ---------------------------------------- the surface behaves, not just exists
//
// Presence is the cheap half. These are the places a hand-written platform
// surface is usually wrong.
r = js('const b = new TextEncoder().encode("héllo 日"); ' +
    'console.log(b.length, b instanceof Uint8Array, new TextDecoder().decode(b));');
check("TextEncoder/TextDecoder round-trip non-ASCII as UTF-8",
    /10 true héllo 日/.test(r.out), r.out);

r = js('console.log(btoa("hello world"), atob("aGVsbG8gd29ybGQ="));');
check("base64 round-trips", /aGVsbG8gd29ybGQ= hello world/.test(r.out), r.out);

r = js('console.log(btoa("a"), btoa("ab"), btoa("abc"));');
check("...including both padding cases", /YQ== YWI= YWJj/.test(r.out), r.out);

r = js('try { atob("!!!!"); console.log("accepted"); } catch (e) { console.log("refused"); }');
check("invalid base64 is refused, not silently decoded", /refused/.test(r.out), r.out);

r = js("const u = crypto.randomUUID(); console.log(" +
    "/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(u));");
check("randomUUID is a well-formed v4", /true/.test(r.out), r.out);

r = js("const a = crypto.randomUUID(), b = crypto.randomUUID(); console.log(a !== b);");
check("...and two of them differ", /true/.test(r.out), r.out);

r = js('const u = new URL("https://a.example:8443/x/y?q=1&q=2#f"); console.log(' +
    '[u.protocol,u.hostname,u.port,u.pathname,u.searchParams.getAll("q").join("|"),u.hash].join(" "));');
check("URL parses a real URL into its parts",
    /https: a\.example 8443 \/x\/y 1\|2 #f/.test(r.out), r.out);

r = js('try { new URL("not a url"); console.log("accepted"); } ' +
    'catch (e) { console.log("refused", e instanceof TypeError); }');
check("a malformed URL throws TypeError", /refused true/.test(r.out), r.out);

r = js('const p = new URLSearchParams("a=1&a=2&b=x+y"); ' +
    'console.log(p.getAll("a").join(","), p.get("b"), p.toString());');
check("URLSearchParams handles repeats and + decoding",
    /1,2 x y a=1&a=2&b=x\+y/.test(r.out), r.out);

r = js('const h = new Headers({ "Content-Type": "text/plain" }); ' +
    'h.append("x-a","1"); h.append("x-a","2"); ' +
    'console.log(h.get("content-type"), h.get("X-A"), h.has("nope"));');
check("Headers are case-insensitive and combine repeats",
    /text\/plain 1, 2 false/.test(r.out), r.out);

r = js("const res = Response.json({a:1},{status:201}); " +
    'res.json().then(v => console.log(res.status, res.ok, res.headers.get("content-type"), v.a));');
check("Response.json sets status, ok and content-type",
    /201 true application\/json 1/.test(r.out), r.out);

r = js('const a = { n: [1,2], d: new Date(0), m: new Map([["k",1]]), s: new Set([3]) }; ' +
    "a.self = a; const b = structuredClone(a); " +
    'console.log(b !== a, b.self === b, b.n[1], b.d instanceof Date, b.m.get("k"), b.s.has(3));');
check("structuredClone deep-copies, and handles cycles, Date, Map and Set",
    /true true 2 true 1 true/.test(r.out), r.out);

r = js("try { structuredClone({ f: () => 1 }); console.log(\"cloned\"); } " +
    'catch (e) { console.log("refused"); }');
check("...and refuses a function rather than dropping it", /refused/.test(r.out), r.out);

r = js('setTimeout(() => console.log("later"), 10); ' +
    'setTimeout(() => console.log("sooner"), 0); ' +
    'queueMicrotask(() => console.log("micro"));');
check("microtasks run before timers, and timers run in delay order",
    /micro[\s\S]*sooner[\s\S]*later/.test(r.out), r.out);

r = js('const id = setTimeout(() => console.log("SHOULD NOT RUN"), 0); ' +
    'clearTimeout(id); console.log("cleared");');
check("clearTimeout actually cancels", !/SHOULD NOT RUN/.test(r.out), r.out);

r = js("const c = new AbortController(); " +
    'c.signal.addEventListener("abort", () => console.log("listener", c.signal.aborted)); ' +
    'c.abort(); console.log("reason", c.signal.reason instanceof Error);');
check("AbortController fires its listener and carries a reason",
    /listener true[\s\S]*reason true/.test(r.out), r.out);

// The narrow door: the whole platform surface stands on ONE object, and
// this gate is what keeps the list of capabilities short as it grows.
r = js("console.log(Object.keys(__host).sort().join(\",\"));");
// `digest` joined in phase 11 (crypto.subtle.digest rides it) — this
// gate exists precisely so that sentence gets written each time.
check("the host door stays narrow — ten primitives, no more",
    r.out.trim() === "b64Decode,b64Encode,clearTimeout,digest,nowMs,randomBytes," +
        "servCall,setTimeout,utf8Decode,utf8Encode",
    r.out.trim());

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
