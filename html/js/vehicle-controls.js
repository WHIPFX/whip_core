// ========================================
// VEHICLE CONTROLS — a vehicle's buttons over the rev dial for a few seconds (client/pad.lua)
//
// On a controller, getting into a car shows its buttons in a column beside the dial, then fades. Lua sends the rows (vehicleControls: each its button pictures and what it does) when a pad player takes
// the driver's seat; this stacks them on the dial's top edge, lined up with its right edge, and lets them go after
// `ms`. The same message again while they show (nitrous ready a moment after sitting down) keeps the rows already
// up, slides in the new ones and starts the time again; an empty one takes them away at once (getting out).
//
// Drawn as the 3D prompts are, flat (css/vehicle-controls.css): each button in a prompt's key, in the player's
// prompt shape (`shape`: 'keycap' or 'classic', from Lua), and the words as a prompt's label. `keys = false` (the
// player's pad.vehicleControlsKeys) leaves the key out: the button pictures alone.
//
// PLACED IN WINDOW PIXELS FROM THE DIAL ITSELF: its canvas is BOX.w radii wide (js/vehicle_hud/dial.js), so its
// radius and middle come off its box whatever its size, skin or kind. Before the dial is up — it fades in after the
// rows arrive, and loads on first use — where the dial will sit for the vehicle's kind (Lua sends it): hud.js
// place() with vehicle-dial.js's DIAL_RIGHT. Only while the HUD layer is on screen.
//
// ON A KEYBOARD a row carries `keys` (words: the key it is bound to, 'E', 'SCROLL ▲') in place of `glyphs`, each
// set in the same white key; Lua sends the engine alone.
// ========================================

import { NuiRouter } from './router.js';
import { padGlyph } from './pad-glyphs.js';
import { BOX } from './vehicle_hud/dial.js';
import { DIAL_RIGHT } from './vehicle-dial.js';

const GAP = 0.14;         // of the dial's radius, between its top and the lowest row
const STAGGER_MS = 70;    // between one row coming in and the next
const LEAVE_MS = 650;     // css: the rows' fade out (0.6 s), and a little over

const statusHud = document.getElementById('status-hud');

let root = null;          // #vehicle-controls, made on first use
let list = null;          // its zoomed column
let kind = 'car';         // the vehicle's: 'car', 'boat' or 'air' (where its dial sits)
let hideTimer = 0;
let goneTimer = 0;
const enterTimers = [];

/** The HUD layer is on screen (as js/vehicle-dial.js asks). */
function hudShown() {
    return !!statusHud && statusHud.classList.contains('visible');
}

function build() {
    root = document.createElement('div');
    root.id = 'vehicle-controls';
    list = document.createElement('div');
    list.className = 'vc-list';
    root.appendChild(list);
    document.body.appendChild(root);
    addEventListener('resize', place);
}

/** The dial's radius and middle in window pixels: off its canvas while it shows, else where hud.js place() puts it
 *  for this kind (radius 12.57% of the height, at most 20% of the width; the middle DIAL_RIGHT radii in, 1.35 up).
 *  NOT hud.js's own 1.671 for every kind: that is only an aircraft's, and a car's dial sits 0.43 radii further
 *  right.
 *  Its LAID-OUT place (offsetLeft / offsetTop), not its box on screen: the dial's move out of the phone's way is a
 *  transform (--dial-dx / --dial-dy, js/vehicle-dial.js makeRoom), which css/vehicle-controls.css gives these rows
 *  too, so counting it here as well would move them twice. */
function dial() {
    const c = document.getElementById('vehicleDial');
    if (c && c.classList.contains('on') && c.offsetWidth > 0) {
        const R = c.offsetWidth / BOX.w;
        return { R, cx: c.offsetLeft + BOX.cx * R, cy: c.offsetTop + BOX.cy * R };
    }
    const R = Math.max(30, Math.floor(Math.min(0.1257 * innerHeight, 0.2 * innerWidth)));
    return { R, cx: innerWidth - (DIAL_RIGHT[kind] || DIAL_RIGHT.car) * R, cy: innerHeight - 1.35 * R };
}

function place() {
    if (!root) return;
    const d = dial();
    root.style.right = Math.max(8, Math.round(innerWidth - (d.cx + d.R))) + 'px';
    root.style.bottom = Math.round(innerHeight - (d.cy - d.R) + GAP * d.R) + 'px';
}

const buttons = (row) => row.glyphs || row.keys;
const keyOf = (row) => (row.glyphs ? 'g:' : 'k:') + buttons(row).join('+') + '|' + row.label;

/** One row: its button's pictures, each in a prompt's key (LB's first, joined by a +), then what it does. */
function rowEl(row) {
    const el = document.createElement('div');
    el.className = 'vc-row';
    el.dataset.key = keyOf(row);
    const btns = document.createElement('span');
    btns.className = 'vc-btns';
    buttons(row).forEach((g) => {
        let img = null;
        if (row.glyphs) {
            img = padGlyph(g, 'vc-glyph');
        } else {
            img = document.createElement('span');
            img.className = 'vc-keytext';
            img.textContent = g;
        }
        if (!img) return;
        if (btns.childElementCount > 0) {
            const plus = document.createElement('span');
            plus.className = 'vc-plus';
            plus.textContent = '+';
            btns.appendChild(plus);
        }
        const key = document.createElement('span');
        key.className = 'vc-key';
        key.appendChild(img);
        btns.appendChild(key);
    });
    const label = document.createElement('span');
    label.className = 'vc-label';
    label.textContent = row.label;
    el.append(btns, label);
    return el;
}

function clearTimers() {
    clearTimeout(hideTimer);
    clearTimeout(goneTimer);
    while (enterTimers.length) clearTimeout(enterTimers.pop());
}

/** Away: at once (getting out, the HUD hidden), or faded (its time is up). */
function leave(now) {
    if (!root) return;
    clearTimers();
    const done = () => { root.classList.remove('up', 'leaving'); list.replaceChildren(); };
    if (now) return done();
    root.classList.add('leaving');
    goneTimer = setTimeout(done, LEAVE_MS);
}

function show(rows, ms) {
    if (!root) build();
    clearTimers();
    root.classList.remove('leaving');
    // The rows already up stay as they are; only the new ones come in.
    const up = new Map([...list.children].map((el) => [el.dataset.key, el]));
    const els = rows.map((row) => up.get(keyOf(row)) || rowEl(row));
    list.replaceChildren(...els);
    root.classList.add('up');
    place();
    setTimeout(place, 450);        // the dial may still be fading in on the same vehicle
    void list.offsetWidth;          // the new rows' out state is drawn first, so they slide from it
    // EVERY ROW NOT IN YET, NOT ONLY THE NEW ONES. Nitrous comes ready from whip_core's watcher, often in the same
    // tick as getting in, so a second message can land before the first one's rows have slid in; clearTimers()
    // above took their pending slide, so they are brought in here too.
    els.filter((el) => !el.classList.contains('in'))
        .forEach((el, i) => enterTimers.push(setTimeout(() => el.classList.add('in'), i * STAGGER_MS)));
    hideTimer = setTimeout(() => leave(false), ms);
}

const valid = (row) => row && typeof row.label === 'string' && row.label !== ''
    && [row.glyphs, row.keys].some((b) => Array.isArray(b) && b.length > 0 && b.every((g) => typeof g === 'string' && g !== ''));

NuiRouter.register('vehicleControls', (d) => {
    const rows = (d && Array.isArray(d.rows)) ? d.rows.filter(valid) : [];
    if (rows.length === 0 || !hudShown()) return leave(true);
    kind = d.kind === 'air' || d.kind === 'boat' ? d.kind : 'car';
    if (!root) build();
    const shape = d.shape === 'classic' ? 'classic' : 'keycap';
    root.classList.toggle('vc-classic', shape === 'classic');
    root.classList.toggle('vc-keycap', shape === 'keycap');
    root.classList.toggle('vc-bare', d.keys === false && rows.every((r) => r.glyphs));   // no white key: the button pictures alone
    show(rows, Math.max(500, Number(d.ms) || 5000));
});

// The HUD layer hidden (the pause menu, a cutscene, the HUD switched off) takes them with it.
if (statusHud) {
    new MutationObserver(() => { if (root && root.classList.contains('up') && !hudShown()) leave(true); })
        .observe(statusHud, { attributes: true, attributeFilter: ['class'] });
}
