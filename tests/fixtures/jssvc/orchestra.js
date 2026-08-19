// A JS service that calls other services — the trampoline's whole point.
//
// `serv.call` returns a promise because the dispatch happens outside this
// guest. Awaiting it is the only thing a caller has to know.

const service = {
    // Calls a RING service.
    async viaRing(payload) {
        const r = await serv.call("ringgreeter.greet", { name: payload.name });
        return { code: 0, message: "OK", data: { from: "js", inner: r.data.greeting } };
    },

    // Calls a GENERIC TABLE service — so a JS service reaches data through
    // exactly the seam a Ring service uses, with contracts and placement
    // applied on the way.
    async store(payload) {
        const created = await serv.call("notes.create", {
            title: payload.title, weight: payload.weight,
        });
        const back = await serv.call("notes.get", { id: created.data.id });
        return { code: 0, message: "OK", data: { id: created.data.id, title: back.data.title } };
    },

    // Several calls, sequentially — each is its own trampoline round.
    async chain(payload) {
        const names = [];
        for (const n of payload.names) {
            const r = await serv.call("ringgreeter.greet", { name: n });
            names.push(r.data.greeting);
        }
        return { code: 0, message: "OK", data: { greetings: names } };
    },

    // Several calls at once — one round, many requests.
    async fanout(payload) {
        const rs = await Promise.all(
            payload.names.map(n => serv.call("ringgreeter.greet", { name: n })));
        return { code: 0, message: "OK", data: { n: rs.length, first: rs[0].data.greeting } };
    },

    // Calls another JS service — two guests' worth of nothing special.
    async viaJs(payload) {
        const r = await serv.call("greeter.greet", { name: payload.name });
        return { code: 0, message: "OK", data: { inner: r.data.greeting } };
    },

    // A REFUSAL COMES BACK AS AN ENVELOPE, not as a rejection — exactly
    // what an HTTP caller sees. `serv.call` rejects only when dispatch
    // itself raises; a contract violation is a business outcome and
    // travels in `code`, which is the whole point of the envelope.
    async refused() {
        const r = await serv.call("greeter.greet", { name: "x".repeat(40) });
        return { code: 0, message: "OK", data: { code: r.code, why: r.message } };
    },

    // An unknown service is an error, not a silent undefined.
    async missing() {
        const r = await serv.call("nosuchservice.act", {});
        return { code: 0, message: "OK", data: { code: r.code } };
    },

    // A malformed target is refused before it reaches the host.
    async badtarget() {
        try {
            await serv.call("noaction", {});
            return { code: 1, message: "not refused", data: "" };
        } catch (e) {
            return { code: 0, message: "OK", data: { caught: String(e.message) } };
        }
    },
};
