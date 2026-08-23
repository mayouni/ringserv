// A leaf module, imported by two others — the diamond's bottom.
export function money(cents) {
    return new Intl.NumberFormat("fr-FR",
        { style: "currency", currency: "EUR" }).format(cents / 100);
}
