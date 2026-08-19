// The JS side of the published benchmark, so the cost of the second
// guest is measured beside the first rather than guessed at.

const service = {
    noop() {
        return { code: 0, message: "OK", data: { ok: 1 } };
    },

    // One trampoline round: the JS action suspends, Ring dispatches, the
    // action resumes. This is what serv.call actually costs.
    async viaRing() {
        const r = await serv.call("bench.noop", {});
        return { code: 0, message: "OK", data: { inner: r.code } };
    },
};
