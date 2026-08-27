// A JS service: the `service` object's methods ARE the actions.
// Everything else in this file is private, which is the point of the
// wrapper the host evaluates it in.

function shout(s) {          // private — never reachable as an action
    return String(s).toUpperCase();
}

const service = {
    greet(payload) {
        const who = payload && payload.name ? payload.name : "world";
        return { code: 0, message: "OK", data: { greeting: "Hello, " + who + "!" } };
    },

    // An action may be async. Nothing upstream knows or cares.
    async slow(payload) {
        await null;
        return { code: 0, message: "OK", data: { n: (payload.n || 0) * 2 } };
    },

    // A sibling is reachable through `this`, the same reach a Ring
    // class-form service has.
    loud(payload) {
        const r = this.greet(payload);
        return { code: 0, message: "OK", data: { greeting: shout(r.data.greeting) } };
    },

    // Business failure is the envelope's job, not the transport's.
    refuse() {
        return { code: 1, message: "declined on purpose", data: "" };
    },

    boom() {
        throw new Error("deliberate JS failure");
    },

    // A reply that is not a JSON object -- the case the wire-path fast
    // check must still refuse, exactly as the old decode-and-inspect path
    // did (docs/BENCHMARKS.md, 2026-08-26).
    bareNumber() {
        return 42;
    },

    // Booleans and null survive the wire only because the guest's own
    // text goes out untouched. Decoding into Ring and re-encoding would
    // turn `false` into `0` and `null` into `""` -- this is what the
    // whole raw-JSON path exists to prevent.
    lossless() {
        return { code: 0, message: "OK", data: { ok: false, note: null, n: 0 } };
    },
};
