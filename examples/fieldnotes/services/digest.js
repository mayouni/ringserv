// A JavaScript service in a Ring application.
//
// The `service` object's methods are the actions. Everything else in this
// file is private — which is why `wordCount` below can never be called
// over the wire.

function wordCount(s) {
    return String(s || "").split(/\s+/).filter(Boolean).length;
}

const service = {
    // Calls other services by NAME through the same seam a Ring service
    // uses. The topology decides where those names live; this file never
    // needs to know.
    async brief(payload) {
        const limit = payload && payload.limit ? payload.limit : 5;

        const heavy = await serv.call("report.heaviest", { limit });
        const places = await serv.call("report.summary", {});

        const lines = heavy.data.rows.map(
            r => `${r.title} (${r.weight})`);

        return {
            code: 0,
            message: "OK",
            data: {
                generated: new Date(0).toISOString().slice(0, 10),
                headline: lines.join("; "),
                places: places.data.count,
                words: wordCount(lines.join(" ")),
            },
        };
    },
};
