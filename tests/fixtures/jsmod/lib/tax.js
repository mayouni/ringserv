// Imports a SIBLING by relative path — the diamond's other edge.
import { money } from "./money.js";
export const RATE = 0.1;
export function taxed(cents) {
    void money; // proves the shared leaf linked once
    return Math.round(cents * (1 + RATE));
}
