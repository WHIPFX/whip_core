// ========================================
// WEIGHTS AS A PLAYER READS THEM
//
// Every weight whip holds is in kilograms. They are shown in the player's unit (Settings → Server → Map & HUD →
// Weight unit, whose default is Config.WeightUnit): grams under a kilo and kilograms from one up, or ounces under a pound and
// pounds from one up.
//
//     weightText(0.05)       // "50 g", or "1.8 oz"
//     weightLine(13.95, 80)  // "13.95 / 80 kg", or "30.75 / 176.37 lb"
// ========================================

import { pref } from './prefs.js';

const LB_PER_KG = 2.20462262;

/** Up to `places` decimals, none when there are none ("80", "13.95", "0.5"). */
function num(n, places) {
    const f = Math.pow(10, places);
    return String(Math.round(n * f) / f);
}

/** A small number with enough decimals to say something: "250", "4.5", "0.35", "0.035". */
function small(n) {
    const a = Math.abs(n);
    return num(n, a >= 10 ? 0 : a >= 1 ? 1 : a >= 0.1 ? 2 : 3);
}

/** [number, unit] for a weight in kg. */
function parts(kg) {
    kg = Number(kg) || 0;
    const imperial = pref('inv.weightUnit', 'kg') === 'lb';
    const big = imperial ? kg * LB_PER_KG : kg;
    const unit = imperial ? 'lb' : 'kg';
    if (big === 0) return ['0', unit];
    const under = imperial ? big * 16 : big * 1000;   // ounces, grams
    const top = imperial ? 16 : 1000;
    // Under one, in the small unit, unless it rounds up to a whole one ("1000 g" is "1 kg").
    if (Math.abs(big) < 1 && Math.abs(Number(small(under))) < top) return [small(under), imperial ? 'oz' : 'g'];
    return [num(big, 2), unit];
}

/** "500 g", "13.95 kg", "1.8 oz", "2.2 lb". */
export function weightText(kg) {
    const [n, unit] = parts(kg);
    return n + ' ' + unit;
}

/** "13.95 / 80 kg": ONE format for every weight line. Each side keeps its own unit when they differ ("500 g / 80 kg"). */
export function weightLine(current, max) {
    const [a, ua] = parts(current);
    const [b, ub] = parts(max);
    return ua === ub ? a + ' / ' + b + ' ' + ub : a + ' ' + ua + ' / ' + b + ' ' + ub;
}
