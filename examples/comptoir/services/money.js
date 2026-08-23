// The money module — imported by receipt.js, never served itself.
//
// A module is private by construction: nothing here is reachable from
// the wire unless a served module re-exports it on `service`.

export const CURRENCY = "EUR";

export function money(cents) {
    const n = Number(cents) || 0;
    return new Intl.NumberFormat("fr-FR", {
        style: "currency", currency: CURRENCY,
    }).format(n / 100);
}

export function line(label, value, width = 34) {
    const l = String(label);
    const v = String(value);
    const pad = Math.max(1, width - l.length - v.length);
    return l + " ".repeat(pad) + v;
}
