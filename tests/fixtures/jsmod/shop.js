// The MODULE form: real ES imports, and the service is an export.
import { money } from "./lib/money.js";
import { taxed, RATE } from "./lib/tax.js";

export const service = {
    async price(payload) {
        const cents = (payload.qty || 1) * (payload.unit || 0);
        const total = taxed(cents);
        return { code: 0, message: "OK",
                 data: { total, formatted: money(total), rate: RATE,
                         paid: false, ref: null } };
    },
};
