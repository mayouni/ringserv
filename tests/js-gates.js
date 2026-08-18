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

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
