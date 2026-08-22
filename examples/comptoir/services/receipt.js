// The receipt, in JavaScript — the fourth hostable form.
//
// Nothing here knows it is inside a Ring application. It gets a payload,
// calls other services BY NAME through `serv.call`, and returns a value
// that leaves through the same envelope every Ring service uses. The
// topology decides where those names live; this file never asks.
//
// Money is the reason this is JS at all: formatting, rounding and
// currency are the kind of fiddly presentation work a JS programmer
// already has habits for, and the point of the JS guest is that those
// habits keep working.

const CURRENCY = "EUR";

// Private by construction — not on `service`, so unreachable from the
// wire. The JS analogue of the class form's Action suffix.
function money(cents) {
    const n = Number(cents) || 0;
    return new Intl.NumberFormat("fr-FR", {
        style: "currency", currency: CURRENCY,
    }).format(n / 100);
}

function line(label, value, width = 34) {
    const l = String(label);
    const v = String(value);
    const pad = Math.max(1, width - l.length - v.length);
    return l + " ".repeat(pad) + v;
}

const service = {
    // The receipt for one ticket. Reaches back into the Ring side for
    // the ticket itself — two languages, one dispatcher, one envelope.
    async render(payload) {
        const no = payload && payload.ticket;
        if (!no) return { code: 1, message: "which ticket?", data: "" };

        const state = await serv.call("orders.state", {});
        const jr = await serv.call("journal.read", { limit: 500 });
        const records = (jr && jr.data && jr.data.records) || [];

        // Rebuild this ticket from the JOURNAL, not from memory: a
        // receipt is a claim about what happened, so it is built from
        // the record of what happened. Ticket numbers are the count of
        // `commander` events, which is exactly how the Ring side derives
        // them — one rule, applied twice, never stored.
        let seen = 0;
        const lines = [];
        let total = 0;
        let client = "";
        let paid = false;
        let cancelled = null;
        for (const r of records) {
            const e = r.event || {};
            if (e.type === "commander") {
                seen += 1;
                if (seen === no) {
                    client = e.client || "";
                    total = e.total || 0;
                    for (const l of e.lignes || []) {
                        lines.push({
                            item: l.item || "",
                            qty: l.qty || 1,
                            price: l.price || 0,
                            amount: (l.qty || 1) * (l.price || 0),
                        });
                    }
                }
            } else if (e.ticket === no) {
                if (e.type === "encaisser") paid = true;
                if (e.type === "annuler") cancelled = e.motif || "";
            }
        }
        if (seen < no) return { code: 1, message: `no ticket ${no}`, data: "" };

        const out = [];
        out.push("        C O M P T O I R");
        out.push("");
        out.push(line(`Ticket #${no}`, client));
        out.push("-".repeat(34));
        for (const l of lines) {
            out.push(line(`${l.qty} x ${l.item}`, money(l.amount)));
        }
        out.push("-".repeat(34));
        out.push(line("TOTAL", money(total)));
        out.push(line("", paid ? "PAYE" : "A REGLER"));
        if (cancelled !== null) out.push(line("ANNULE", cancelled));
        out.push("");
        out.push(`tickets ouverts: ${state.data ? state.data.open : "?"}`);

        return {
            code: 0,
            message: "OK",
            data: {
                ticket: no,
                client,
                total,
                total_formatted: money(total),
                paid,
                cancelled,
                lines,
                text: out.join("\n"),
            },
        };
    },

    // Money maths in one place, so nothing above has to round.
    async total(payload) {
        const lines = (payload && payload.lignes) || [];
        let sum = 0;
        for (const l of lines) sum += (l.qty || 1) * (l.price || 0);
        return {
            code: 0, message: "OK",
            data: { total: sum, formatted: money(sum), currency: CURRENCY },
        };
    },
};
