/* ========================================
   ITEM NOTICES — a box at the side of the screen when an item comes or goes

   client/item_notices.lua hands over { item, name, img, amount, count, added, position }. Each one is a
   picture of the item, its name, and "+2" in green or "−1" in red, for a few seconds. The same item
   arriving again while its box is still up adds to that box instead of making another (buying five
   one at a time shows "+5"). At most MAX at once: the oldest goes first.
   ======================================== */

import { NuiRouter } from './router.js';
import { setItemImage } from './utils.js';
import { getItemDefs } from './core/item-defs.js';

const SHOW_MS = 3500;
const OUT_MS = 300;    // css: .item-notice.out
const MAX = 5;

const POSITIONS = new Set(['right', 'left', 'bottom']);

let stack = null;
const live = new Map();   // ['item|+' or 'item|-'] = { el, amount, timer }

function ensureStack(position) {
    if (!stack) {
        stack = document.createElement('div');
        stack.id = 'item-notices';
        document.body.appendChild(stack);
    }
    stack.dataset.position = POSITIONS.has(position) ? position : 'right';
    return stack;
}

function remove(key) {
    const n = live.get(key);
    if (!n) return;
    live.delete(key);
    clearTimeout(n.timer);
    n.el.classList.add('out');
    setTimeout(() => n.el.remove(), OUT_MS);
}

function arm(key) {
    const n = live.get(key);
    clearTimeout(n.timer);
    n.timer = setTimeout(() => remove(key), SHOW_MS);
}

function amountText(added, amount) {
    return (added ? '+' : '−') + amount;
}

function show(d) {
    if (!d || typeof d.item !== 'string') return;
    const added = d.added !== false;
    const amount = Math.max(1, Math.floor(Number(d.amount) || 1));
    const key = d.item + (added ? '|+' : '|-');
    const host = ensureStack(d.position);

    const had = live.get(key);
    if (had) {
        had.amount += amount;
        had.el.querySelector('.item-notice-amount').textContent = amountText(added, had.amount);
        had.el.classList.remove('bump');
        void had.el.offsetWidth;   // restart the bump
        had.el.classList.add('bump');
        arm(key);
        return;
    }

    const defs = getItemDefs();
    const def = defs && defs[d.item];

    const el = document.createElement('div');
    el.className = 'item-notice ' + (added ? 'added' : 'removed');

    const pic = document.createElement('div');
    pic.className = 'item-notice-pic';
    const img = document.createElement('img');
    img.alt = '';
    setItemImage(img, { item: d.item });
    // A satellite's item the page has no definition for yet: the server's own answer for its picture.
    if (!def && typeof d.img === 'string' && d.img) img.src = d.img;
    pic.appendChild(img);

    const amt = document.createElement('span');
    amt.className = 'item-notice-amount';
    amt.textContent = amountText(added, amount);
    pic.appendChild(amt);

    const verb = document.createElement('div');
    verb.className = 'item-notice-verb';
    verb.textContent = added ? 'Received' : 'Removed';

    const name = document.createElement('div');
    name.className = 'item-notice-name';
    name.textContent = d.name || (def && def.name) || d.item;

    el.append(pic, verb, name);
    host.appendChild(el);
    live.set(key, { el, amount, timer: 0 });
    arm(key);

    // Too many: the oldest goes.
    while (live.size > MAX) remove(live.keys().next().value);
}

NuiRouter.register('itemNotice', show);
