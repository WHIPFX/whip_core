// ========================================
// INVENTORY CORE — ON YOUR CHARACTER
//
// The ring over the player's own character while an item is dragged (Config.InventoryDragToBody): letting go on it
// equips or uses the item (actions.equip). The character is the real one in the world, behind the page, so Lua
// projects its chest onto the screen every frame of the drag (client/inventory_gestures.lua, 'bodyPoint') and this
// file only draws the ring there and answers whether a point is on it.
//
// FOR ANY RENDERER. whip's own inventory and a custom one (api.body) drive it the same way:
//   begin(at, labels?)  a drag of `at` started. Nothing shows for an item with nothing to do (actions.equipKind)
//                or with the gesture switched off. `labels` ({ equip, use }) names the ring in your own words.
//   over(x, y)   the pointer moved: lights the ring when it is on it, and answers that.
//   hit(x, y)    is (x, y) on the ring? Ask it at the release, before your own drop targets.
//   end()        the drag is over, however it ended.
// The ring is drawn over every panel, small enough to leave the slots around it reachable.
// ========================================

import { NuiRouter } from '../router.js';
import { nuiCallback } from '../utils.js';
import { invEvents } from './emitter.js';
import { equipKind } from './inv-actions.js';

const RADIUS = 44;                    // px at 1080p: how near the ring's centre a release counts
const LABELS = { equip: 'Equip', use: 'Use' };

let el = null;
let point = null;       // { x, y } in px, or null until Lua's first frame
let session = 0;        // bumped by begin and end: a late answer from an earlier drag is ignored
let live = false;       // a drag with a ring (Lua said on)
let hot = false;

const scale = () => Math.max(0.6, window.innerHeight / 1080);

function ensure() {
    if (el && el.isConnected) return el;
    el = document.createElement('div');
    el.className = 'inv-body-target';
    el.hidden = true;
    el.innerHTML = '<i class="inv-body-ring" aria-hidden="true"></i><span class="inv-body-label"></span>';
    document.body.appendChild(el);
    return el;
}

function place() {
    if (!el || !point) return;
    el.style.transform = 'translate(' + point.x + 'px,' + point.y + 'px)';
    el.hidden = !live;
}

function setHot(on) {
    if (hot === on) return;
    hot = on;
    if (el) el.classList.toggle('hot', on);
}

/** A drag of `at` started. `labels`: { equip, use }, the ring's words (whip's own: Equip, Use). */
export function begin(at, labels) {
    end();
    const kind = equipKind(at);
    if (!kind) return;
    const mine = ++session;
    nuiCallback('bodyTrack', { on: true }).then((r) => {
        if (mine !== session) return;
        if (!r || r.on !== true) return;
        live = true;
        ensure().querySelector('.inv-body-label').textContent = (labels && labels[kind]) || LABELS[kind];
        place();
    });
}

/** Is (x, y) on the ring? */
export function hit(x, y) {
    if (!live || !point) return false;
    return Math.hypot(x - point.x, y - point.y) <= RADIUS * scale();
}

/** The pointer moved: the ring lights while it is on it. */
export function over(x, y) {
    const on = hit(x, y);
    setHot(on);
    return on;
}

/** The drag is over. */
export function end() {
    session++;
    const was = live;
    live = false;
    point = null;
    setHot(false);
    if (el) el.hidden = true;
    if (was) nuiCallback('bodyTrack', { on: false });
}

/** Is a ring showing now? */
export function active() {
    return live;
}

NuiRouter.register('bodyPoint', (d) => {
    if (!live || !d) return;
    if (d.hidden) { live = false; setHot(false); if (el) el.hidden = true; return; }   // blocked mid-drag
    point = { x: Number(d.x) * window.innerWidth, y: Number(d.y) * window.innerHeight };
    place();
});

invEvents.on('close', () => end());
