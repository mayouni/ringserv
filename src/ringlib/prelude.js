// prelude.js — the ECMA-429 / WinterTC minimum surface, installed into
// every worker's guest at context creation.
//
// WHY THIS FILE IS JAVASCRIPT. The roadmap asks for the surface
// "implemented once in Zig". The load-bearing word is ONCE, not Zig: what
// must not happen is each guest, or each application, growing its own
// idea of what `URL` means. Zig implements what genuinely needs the host
// — randomness, base64, UTF-8 transcoding, timers — and everything that
// is pure computation over those primitives is written here, once, and
// shared by every worker. Writing `URLSearchParams` in Zig would buy
// nothing and cost a week of memory management.
//
// The rule this file obeys: it may use `__host` and nothing else. If a
// capability is not in `__host`, the guest cannot have it — which is how
// "no filesystem, no processes, no sockets" stays true as this grows.

(function (g) {
    "use strict";

    // ------------------------------------------------------------ text
    //
    // Transcoding crosses the host boundary because a JS string is UTF-16
    // and the wire is UTF-8, and only the host knows how its byte buffers
    // are laid out.

    class TextEncoder {
        get encoding() { return "utf-8"; }
        encode(input = "") {
            return new Uint8Array(__host.utf8Encode(String(input)));
        }
        encodeInto(source, dest) {
            const bytes = this.encode(source);
            const n = Math.min(bytes.length, dest.length);
            dest.set(bytes.subarray(0, n));
            return { read: source.length, written: n };
        }
    }

    class TextDecoder {
        constructor(label = "utf-8") {
            const l = String(label).toLowerCase();
            if (l !== "utf-8" && l !== "utf8" && l !== "unicode-1-1-utf-8") {
                throw new RangeError("only utf-8 is supported: " + label);
            }
        }
        get encoding() { return "utf-8"; }
        decode(input) {
            if (input === undefined) return "";
            const bytes = input instanceof Uint8Array
                ? input
                : new Uint8Array(input.buffer || input);
            return __host.utf8Decode(Array.from(bytes));
        }
    }

    // ---------------------------------------------------------- base64
    g.btoa = function btoa(s) {
        const str = String(s);
        for (let i = 0; i < str.length; i++) {
            if (str.charCodeAt(i) > 255) {
                throw new Error("btoa: the string contains characters outside Latin-1");
            }
        }
        return __host.b64Encode(str);
    };
    g.atob = function atob(s) {
        const out = __host.b64Decode(String(s));
        if (out === null) throw new Error("atob: not valid base64");
        return out;
    };

    // ---------------------------------------------------------- crypto
    //
    // Randomness is the host's: a guest that could seed its own would be
    // a guest whose "random" is reproducible by anyone who can read the
    // application.
    const crypto = {
        getRandomValues(array) {
            const bytes = __host.randomBytes(array.byteLength);
            const view = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
            view.set(bytes);
            return array;
        },
        randomUUID() {
            const b = __host.randomBytes(16);
            b[6] = (b[6] & 0x0f) | 0x40;   // version 4
            b[8] = (b[8] & 0x3f) | 0x80;   // variant 10
            const h = [];
            for (let i = 0; i < 16; i++) h.push(b[i].toString(16).padStart(2, "0"));
            return h.slice(0, 4).join("") + "-" + h.slice(4, 6).join("") + "-" +
                h.slice(6, 8).join("") + "-" + h.slice(8, 10).join("") + "-" +
                h.slice(10, 16).join("");
        },
    };

    // ------------------------------------------------- URL, and its query
    //
    // A deliberately small parser: absolute URLs and the one relative form
    // a server actually meets. It does not pretend to be WHATWG-complete,
    // and `docs/JS.md` says so rather than letting a caller discover it.

    class URLSearchParams {
        constructor(init = "") {
            this._p = [];
            if (typeof init === "string") {
                const s = init.startsWith("?") ? init.slice(1) : init;
                if (s) for (const pair of s.split("&")) {
                    if (!pair) continue;
                    const i = pair.indexOf("=");
                    const k = i < 0 ? pair : pair.slice(0, i);
                    const v = i < 0 ? "" : pair.slice(i + 1);
                    this._p.push([decode(k), decode(v)]);
                }
            } else if (init instanceof URLSearchParams) {
                this._p = init._p.map(x => [x[0], x[1]]);
            } else if (Array.isArray(init)) {
                for (const [k, v] of init) this._p.push([String(k), String(v)]);
            } else if (init && typeof init === "object") {
                for (const k of Object.keys(init)) this._p.push([k, String(init[k])]);
            }
        }
        append(k, v) { this._p.push([String(k), String(v)]); }
        delete(k) { this._p = this._p.filter(x => x[0] !== String(k)); }
        get(k) { const f = this._p.find(x => x[0] === String(k)); return f ? f[1] : null; }
        getAll(k) { return this._p.filter(x => x[0] === String(k)).map(x => x[1]); }
        has(k) { return this._p.some(x => x[0] === String(k)); }
        set(k, v) { this.delete(k); this.append(k, v); }
        forEach(fn, thisArg) { for (const [k, v] of this._p) fn.call(thisArg, v, k, this); }
        keys() { return this._p.map(x => x[0])[Symbol.iterator](); }
        values() { return this._p.map(x => x[1])[Symbol.iterator](); }
        entries() { return this._p.map(x => [x[0], x[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        get size() { return this._p.length; }
        toString() {
            return this._p.map(([k, v]) => encode(k) + "=" + encode(v)).join("&");
        }
    }

    function encode(s) {
        return encodeURIComponent(String(s)).replace(/%20/g, "+");
    }
    function decode(s) {
        try { return decodeURIComponent(String(s).replace(/\+/g, " ")); }
        catch { return String(s); }
    }

    class URL {
        constructor(input, base) {
            let s = String(input);
            if (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s)) {
                const b = base instanceof URL ? b : new URL(String(base));
                s = joinRelative(b, s);
            }
            const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(s);
            if (!m) throw new TypeError("Invalid URL: " + input);
            this.protocol = m[1].toLowerCase() + ":";
            let host = m[2];
            const at = host.lastIndexOf("@");
            this.username = "";
            this.password = "";
            if (at >= 0) {
                const cred = host.slice(0, at);
                host = host.slice(at + 1);
                const ci = cred.indexOf(":");
                this.username = ci < 0 ? cred : cred.slice(0, ci);
                this.password = ci < 0 ? "" : cred.slice(ci + 1);
            }
            const pi = host.lastIndexOf(":");
            if (pi >= 0 && host.indexOf("]") < pi) {
                this.hostname = host.slice(0, pi);
                this.port = host.slice(pi + 1);
            } else {
                this.hostname = host;
                this.port = "";
            }
            this.host = this.port ? this.hostname + ":" + this.port : this.hostname;
            this.pathname = m[3] || "/";
            this.search = m[4] || "";
            this.hash = m[5] || "";
            this.searchParams = new URLSearchParams(this.search);
            this.origin = this.protocol + "//" + this.host;
        }
        get href() {
            const q = this.searchParams.toString();
            return this.origin + this.pathname + (q ? "?" + q : "") + this.hash;
        }
        toString() { return this.href; }
        toJSON() { return this.href; }
    }

    function joinRelative(base, rel) {
        if (rel.startsWith("//")) return base.protocol + rel;
        if (rel.startsWith("/")) return base.origin + rel;
        const dir = base.pathname.replace(/[^/]*$/, "");
        return base.origin + dir + rel;
    }

    // -------------------------------------------------- events, aborting
    class Event {
        constructor(type, init = {}) {
            this.type = String(type);
            this.defaultPrevented = false;
            this.cancelable = !!init.cancelable;
            this.target = null;
        }
        preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
        stopPropagation() {}
    }

    class EventTarget {
        constructor() { this._l = Object.create(null); }
        addEventListener(type, fn, opts) {
            if (!fn) return;
            (this._l[type] = this._l[type] || []).push({ fn, once: !!(opts && opts.once) });
        }
        removeEventListener(type, fn) {
            const a = this._l[type];
            if (a) this._l[type] = a.filter(x => x.fn !== fn);
        }
        dispatchEvent(ev) {
            ev.target = this;
            const a = (this._l[ev.type] || []).slice();
            for (const l of a) {
                if (l.once) this.removeEventListener(ev.type, l.fn);
                (typeof l.fn === "function" ? l.fn : l.fn.handleEvent).call(this, ev);
            }
            return !ev.defaultPrevented;
        }
    }

    class AbortSignal extends EventTarget {
        constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
        throwIfAborted() { if (this.aborted) throw this.reason; }
        static abort(reason) {
            const s = new AbortSignal();
            s.aborted = true;
            s.reason = reason !== undefined ? reason : new Error("This operation was aborted");
            return s;
        }
    }

    class AbortController {
        constructor() { this.signal = new AbortSignal(); }
        abort(reason) {
            const s = this.signal;
            if (s.aborted) return;
            s.aborted = true;
            s.reason = reason !== undefined ? reason : new Error("This operation was aborted");
            if (typeof s.onabort === "function") s.onabort.call(s, new Event("abort"));
            s.dispatchEvent(new Event("abort"));
        }
    }

    // ------------------------------------------- headers, request, response
    //
    // Fetch-SHAPED, which is the promise RingServ actually makes: a
    // programmer who knows the web platform recognises the objects. There
    // is no network `fetch` here — a service reaches other services
    // through `serv.call`, which is the seam the topology compiles.

    class Headers {
        constructor(init) {
            this._h = [];
            if (init instanceof Headers) this._h = init._h.map(x => [x[0], x[1]]);
            else if (Array.isArray(init)) for (const [k, v] of init) this.append(k, v);
            else if (init && typeof init === "object")
                for (const k of Object.keys(init)) this.append(k, init[k]);
        }
        append(k, v) { this._h.push([String(k).toLowerCase(), String(v)]); }
        delete(k) { this._h = this._h.filter(x => x[0] !== String(k).toLowerCase()); }
        get(k) {
            const all = this.getAll(k);
            return all.length ? all.join(", ") : null;
        }
        getAll(k) {
            return this._h.filter(x => x[0] === String(k).toLowerCase()).map(x => x[1]);
        }
        has(k) { return this._h.some(x => x[0] === String(k).toLowerCase()); }
        set(k, v) { this.delete(k); this.append(k, v); }
        forEach(fn, thisArg) { for (const [k, v] of this._h) fn.call(thisArg, v, k, this); }
        keys() { return this._h.map(x => x[0])[Symbol.iterator](); }
        values() { return this._h.map(x => x[1])[Symbol.iterator](); }
        entries() { return this._h.map(x => [x[0], x[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
    }

    class Body {
        constructor(body) { this._body = body === undefined ? null : body; this.bodyUsed = false; }
        async text() { this.bodyUsed = true; return this._body === null ? "" : String(this._body); }
        async json() { return JSON.parse(await this.text()); }
        async arrayBuffer() { return new TextEncoder().encode(await this.text()).buffer; }
    }

    class Request extends Body {
        constructor(input, init = {}) {
            super(init.body);
            this.url = input instanceof Request ? input.url : String(input);
            this.method = (init.method || "GET").toUpperCase();
            this.headers = new Headers(init.headers);
            this.signal = init.signal || new AbortSignal();
        }
    }

    class Response extends Body {
        constructor(body, init = {}) {
            super(body);
            this.status = init.status === undefined ? 200 : init.status;
            this.statusText = init.statusText || "";
            this.headers = new Headers(init.headers);
            this.ok = this.status >= 200 && this.status < 300;
        }
        static json(data, init = {}) {
            const r = new Response(JSON.stringify(data), init);
            if (!r.headers.has("content-type")) r.headers.set("content-type", "application/json");
            return r;
        }
        static error() { return new Response(null, { status: 500 }); }
    }

    // ------------------------------------------------------ misc platform
    g.structuredClone = function structuredClone(v) {
        return clone(v, new Map());
    };
    function clone(v, seen) {
        // Functions are refused BEFORE the primitive short-circuit below:
        // `typeof fn !== "object"`, so an early return would have silently
        // passed the function through by reference — which is exactly the
        // aliasing structuredClone exists to prevent.
        if (typeof v === "function") {
            throw new Error("structuredClone: a function cannot be cloned");
        }
        if (v === null || typeof v !== "object") return v;
        if (seen.has(v)) return seen.get(v);
        if (v instanceof Date) return new Date(v.getTime());
        if (v instanceof Map) {
            const m = new Map(); seen.set(v, m);
            for (const [k, x] of v) m.set(clone(k, seen), clone(x, seen));
            return m;
        }
        if (v instanceof Set) {
            const s = new Set(); seen.set(v, s);
            for (const x of v) s.add(clone(x, seen));
            return s;
        }
        if (Array.isArray(v)) {
            const a = []; seen.set(v, a);
            for (const x of v) a.push(clone(x, seen));
            return a;
        }
        if (ArrayBuffer.isView(v)) return new v.constructor(v);
        const o = {}; seen.set(v, o);
        for (const k of Object.keys(v)) o[k] = clone(v[k], seen);
        return o;
    }

    g.queueMicrotask = function queueMicrotask(fn) {
        Promise.resolve().then(fn);
    };

    // Timers exist because `await` on anything real needs them, and they
    // are the host's because only the host knows when a request ends.
    g.setTimeout = (fn, ms, ...args) =>
        __host.setTimeout(() => fn(...args), ms === undefined ? 0 : ms);
    g.clearTimeout = id => __host.clearTimeout(id);
    g.setInterval = () => {
        throw new Error("setInterval is not available: a request-scoped guest " +
            "has nowhere to run a repeating timer. Use setTimeout.");
    };
    g.clearInterval = () => {};

    const performance = { now: () => __host.nowMs() };

    // ------------------------------------------------------- the seam
    //
    // `serv.call("service.action", payload)` — the SAME seam a Ring
    // service uses and the same one the topology compiles. It returns a
    // promise because the dispatch happens outside this guest; awaiting it
    // is the only thing a caller has to know.
    //
    // There is deliberately no network `fetch` beside it. A service that
    // wants another service asks for it by NAME, and the topology decides
    // where that name lives; a service that hardcodes a URL has made a
    // deployment decision inside application code, which is the whole
    // thing placement exists to prevent.
    const serv = {
        call(target, payload) {
            const s = String(target);
            const dot = s.indexOf(".");
            if (dot < 1 || dot === s.length - 1) {
                throw new TypeError(
                    'serv.call expects "service.action", got: ' + s);
            }
            return __host.servCall(s.slice(0, dot), s.slice(dot + 1), payload);
        },
    };

    // ------------------------------------------------------------- Intl
    //
    // A DELIBERATE SUBSET, and the reason is the same one that keeps the
    // yaml parser small: real Intl is ICU, and ICU is ~30 MB of locale
    // data. Vendoring it to format prices would cost more than the whole
    // rest of this binary and break the promise on the front page.
    //
    // But "no Intl" is not an answer either. The reference application
    // (examples/comptoir) reached for `Intl.NumberFormat` on its FIRST
    // line of money handling, which is exactly what a JS programmer does
    // — so the common case is served, and everything else is REFUSED BY
    // NAME rather than formatted wrongly. A number formatter that quietly
    // gets fr-FR's separators wrong is worse than one that says it cannot.
    const INTL_LOCALES = {
        "en-US": { group: ",", decimal: ".", before: true,  nbsp: "" },
        "en-GB": { group: ",", decimal: ".", before: true,  nbsp: "" },
        "fr-FR": { group: " ", decimal: ",", before: false, nbsp: " " },
        "de-DE": { group: ".", decimal: ",", before: false, nbsp: " " },
        "es-ES": { group: ".", decimal: ",", before: false, nbsp: " " },
        "it-IT": { group: ".", decimal: ",", before: false, nbsp: " " },
        "pt-BR": { group: ".", decimal: ",", before: true,  nbsp: " " },
        "ar-TN": { group: ",", decimal: ".", before: false, nbsp: " " },
    };
    const INTL_CURRENCIES = {
        EUR: "€", USD: "$", GBP: "£", JPY: "¥",
        CHF: "CHF", CAD: "CA$", AUD: "A$", TND: "DT", MAD: "MAD",
    };
    const INTL_DEFAULT = "en-US";

    function intlRefuse(what, detail) {
        throw new RangeError(
            "Intl." + what + ": " + detail + " is not in RingServ's Intl subset. " +
            "RingServ ships no ICU (it would be larger than the whole binary), so " +
            "it supports " + Object.keys(INTL_LOCALES).join(", ") + " and the " +
            "currencies " + Object.keys(INTL_CURRENCIES).join(", ") + ". " +
            "For anything else, format on the client or pass the formatted " +
            "string in — see docs/JS.md.");
    }

    class NumberFormat {
        constructor(locales, options) {
            const opts = options || {};
            let tag = INTL_DEFAULT;
            if (locales !== undefined) {
                const wanted = Array.isArray(locales) ? locales : [locales];
                const found = wanted.map(String).find(l => INTL_LOCALES[l]);
                if (!found) intlRefuse("NumberFormat", "locale " + wanted.join("/"));
                tag = found;
            }
            this._t = tag;
            this._l = INTL_LOCALES[tag];
            this._style = opts.style || "decimal";
            if (["decimal", "currency", "percent"].indexOf(this._style) < 0) {
                intlRefuse("NumberFormat", "style " + this._style);
            }
            this._cur = opts.currency;
            if (this._style === "currency") {
                if (!this._cur) intlRefuse("NumberFormat", "style currency with no currency");
                this._cur = String(this._cur).toUpperCase();
                if (!INTL_CURRENCIES[this._cur]) {
                    intlRefuse("NumberFormat", "currency " + this._cur);
                }
            }
            const dflt = this._style === "currency" ? 2 : (this._style === "percent" ? 0 : 0);
            this._min = opts.minimumFractionDigits !== undefined
                ? opts.minimumFractionDigits : dflt;
            this._max = opts.maximumFractionDigits !== undefined
                ? opts.maximumFractionDigits : Math.max(this._min, this._style === "decimal" ? 3 : dflt);
            this._grouping = opts.useGrouping !== false;
        }

        resolvedOptions() {
            return {
                locale: this._t, style: this._style, currency: this._cur,
                minimumFractionDigits: this._min, maximumFractionDigits: this._max,
                useGrouping: this._grouping,
            };
        }

        format(value) {
            let n = Number(value);
            if (!isFinite(n)) return String(n);
            if (this._style === "percent") n *= 100;
            const neg = n < 0 || Object.is(n, -0);
            n = Math.abs(n);

            let s = n.toFixed(this._max);
            if (this._max > this._min) s = s.replace(/0+$/, "").replace(/\.$/, "");
            let [int, frac = ""] = s.split(".");
            while (frac.length < this._min) frac += "0";
            if (this._grouping && int.length > 3) {
                int = int.replace(/\B(?=(\d{3})+(?!\d))/g, this._l.group);
            }
            let out = frac ? int + this._l.decimal + frac : int;
            if (this._style === "currency") {
                const sym = INTL_CURRENCIES[this._cur];
                out = this._l.before ? sym + out : out + this._l.nbsp + sym;
            } else if (this._style === "percent") {
                out = this._l.before ? out + "%" : out + this._l.nbsp + "%";
            }
            return neg ? "-" + out : out;
        }

        formatToParts() {
            intlRefuse("NumberFormat", "formatToParts");
        }
    }

    // Everything else under Intl is absent AND SAYS SO. A missing global
    // gives "Intl.DateTimeFormat is not a constructor"; this gives the
    // reason and the way forward.
    const Intl = {
        NumberFormat,
        getCanonicalLocales(l) {
            const w = l === undefined ? [] : (Array.isArray(l) ? l : [l]);
            return w.map(String).filter(x => INTL_LOCALES[x]);
        },
    };
    for (const missing of ["DateTimeFormat", "Collator", "RelativeTimeFormat",
                           "ListFormat", "PluralRules", "Segmenter", "DisplayNames"]) {
        Object.defineProperty(Intl, missing, {
            get() { intlRefuse(missing, missing); },
            enumerable: false, configurable: true,
        });
    }
    // Number.prototype.toLocaleString routes through the same subset, so
    // the two agree instead of disagreeing.
    Number.prototype.toLocaleString = function (locales, options) {
        return new NumberFormat(locales, options).format(this);
    };

    // ------------------------------------------------------------ install
    const surface = {
        TextEncoder, TextDecoder, URL, URLSearchParams,
        Event, EventTarget, AbortController, AbortSignal,
        Headers, Request, Response, crypto, performance, serv, Intl,
    };
    for (const k of Object.keys(surface)) {
        Object.defineProperty(g, k, {
            value: surface[k], writable: true, enumerable: false, configurable: true,
        });
    }
    g.globalThis = g;
    g.self = g;
})(globalThis);
