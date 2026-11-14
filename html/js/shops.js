/* ========================================
   THE SHOP SCREEN — the shopfront and the basket

   While a shop is open its goods replace the inventory's middle column and the basket fills the
   right, where the panels are: its lines,
   whether it will all fit in the pockets (which are hidden, and still where a purchase lands), the
   total, how to pay, and Buy.

   THE GOODS ARE CARDS: six across, each with its picture, name, what is left and what one weighs, the price, and a +.
   One already in the basket shows its count there with a minus and a plus. Above them the shop's
   categories as chips, a sort (shelf order, price, A to Z) and a search. A card is still a slot to
   inventory.js (.inv-slot, data-container 'shop'), so a click adds one, a right-click asks how
   many, and the item card, the controller and Edit Shelf's preview all work on it as they did.

   EVERYTHING HERE IS DRAWN FROM THE SERVER'S SCREEN STATE (Shops.buildScreenState): the shelf, the
   basket at today's prices, and whether it fits. This file keeps no basket of its own. It asks —
   add this item, set that line — and draws what comes back.
   ======================================== */

import { NuiRouter } from './router.js';
import { nuiCallback, itemImageUrl } from './utils.js';
import { showBasketQuantity, weightLine } from './inventory.js';
import { weightText } from './weight.js';
import { invItemDefs } from './core/item-defs.js';
import { inv, shop, invRegisterShopHooks } from './core/inv-state.js';
import { talkOpen, talkClose, talkFit } from './shop-talk.js';   // the visit's /me lines in the header

// The shop object (open/data/items/basket) lives in core/inv-state.js — inventory.js's slot
// factory reads it, so it is shared core state. This file OWNS it: nothing else writes shop.*.
//   shop.items   the shelf, keyed by its place on the shelf (1, 2, 3 ...): { item, price, stock, category }
//   shop.basket  the basket, keyed by line (the basket slot): { slot, item, amount, metadata, price }

const ALL   = 'all';
const OTHER = '\u0000other';     // the tab for goods with no category; never a category's own name

let screen = null;      // the last screen state the server sent
let tab = ALL;          // the category chip on show
let sort = 'shelf';     // 'shelf' (the shop's own order) | 'price' | 'az'
let query = '';         // the search box, lower case
let payMethod = 'cash';
let paying = false;     // a purchase is on its way
let payingTimer = 0;
let buyFlash = null;    // { text, cls }: what the till said, on Buy for a moment (shopPurchaseResult)
let buyFlashTimer = 0;
const BUY_FLASH_MS = 2600;
// Edit Shelf, while it is open: { cats: [tab names, in order], order: [item keys, in order],
// cat: { [item]: tab name or null } }. Nothing reaches the server until Save.
let editing = null;
const MAX_TABS = 12, MAX_TAB_LEN = 24;   // the server's own limits (Shops.setLayout)

// ---- AHEAD OF THE SERVER ----
// A number must not wait a round trip (a quarter of a second on a long ping). A change sets the total the
// item SHOULD be (want) and the screen draws that at once; one request per item goes to the server with
// the newest total (basketSetItem: server/shops.lua Shops.setItemTotal), and when it lands the next goes
// if the player has moved on, else the server's own count is drawn again. The server still decides: a
// total it cannot make (the shelf ran out, the basket is full) is drawn as what it did.
const want = new Map();      // item -> { n, from }: the total asked for and not landed yet (from: the basket lines
                             // to take from first, newest first — several taken out in one round trip are all kept)
const flying = new Set();    // items with a request on its way
const MAX_QTY = 999;         // the server's own limit (basketSetItem), and basketAdd's before it
const LAND_MS = 8000;        // a request with no answer by then is given up on
const RETRY_MS = 150;        // a 'Rate limited' refusal is sent again this much later...
const RETRIES = 4;           // ...this many times, before the server's own count is drawn again
let visit = 0;               // bumped by each open and close: an answer for an old visit is ignored

// ---- held buttons ----
// A held plus or minus — the mouse's, or the pad's A on a card or a basket button — steps again and again,
// faster the longer it is held, and in bigger steps after a while (ones, then fives, then tens), landing
// on round numbers. Each step only moves the number on screen; the server hears the newest total.
const HOLD_DELAY_MS = 350;   // before a held button starts repeating
const HOLD_FIRST_MS = 140;   // its first repeats, each a little quicker than the last...
const HOLD_MIN_MS = 40;      // ...down to this
let hold = null;             // { step(size) -> moved?, by: 'mouse' | 'pad', k, timer }
let padA = false;            // the pad's A is down (inventory.js, from the stick's messages)

/** A list from either shape msgpack may hand over: an empty Lua table arrives as {} or []. */
function toList(x) {
    if (Array.isArray(x)) return x;
    return x && typeof x === 'object' ? Object.values(x) : [];
}

/** Does this shop take money (banknotes or the bank), or an item (gold, crypto)? */
function takesMoney() {
    const c = shop.data && shop.data.currency;
    return !c || c.money !== false;
}

/** A price as the screen says it: "$1,250", "12 Gold Bar", or "Free". */
function priceText(n) {
    n = Number(n) || 0;
    if (n === 0) return 'Free';
    if (takesMoney()) return '$' + n.toLocaleString('en-US');
    return n.toLocaleString('en-US') + ' ' + ((shop.data.currency && shop.data.currency.name) || '');
}

function itemName(key) {
    const def = invItemDefs[key];
    return (def && def.name) || key;
}

// ============================================
// Open / Close
// ============================================

function openShop(data) {
    shop.data = data;
    shop.open = true;
    tab = ALL;
    sort = 'shelf';
    query = '';
    document.getElementById('inv-shop-search').value = '';
    payMethod = 'cash';
    editing = null;
    setPaying(false);
    forgetAhead();

    document.getElementById('inv-overlay').classList.add('shop-mode');
    document.getElementById('inv-player-panel').style.display = 'none';
    document.getElementById('inv-shopfront').style.display = '';
    document.getElementById('inv-ground-panel').style.display = 'none';
    document.getElementById('inv-basket-panel').style.display = '';
    document.getElementById('inv-shop-name').textContent = data.name || 'Shop';
    talkOpen(data);

    // The accounts this character can pay from (the server lists only those). None, or a
    // shop that takes an item, and Bank is not offered.
    const accountSelect = document.getElementById('inv-basket-account');
    accountSelect.innerHTML = '';
    for (const acct of toList(data.accounts)) {
        const opt = document.createElement('option');
        opt.value = acct.accountId;
        opt.textContent = `${acct.label} · ${acct.accountNumber} · $${(Number(acct.balance) || 0).toLocaleString('en-US')}`;
        accountSelect.appendChild(opt);
    }

    applyScreen(data.screen);
}

function closeShop() {
    shop.open = false;
    shop.data = null;
    shop.items = {};
    shop.basket = {};
    screen = null;
    editing = null;
    setPaying(false);
    forgetAhead();
    talkClose();

    document.getElementById('inv-overlay').classList.remove('shop-mode');
    document.getElementById('inv-shopfront').style.display = 'none';
    document.getElementById('inv-basket-panel').style.display = 'none';
    document.getElementById('inv-shelf-edit-panel').style.display = 'none';
    document.getElementById('inv-shop-edit-btn').style.display = 'none';
    document.getElementById('inv-player-panel').style.display = '';
    document.getElementById('inv-ground-panel').style.display = '';
    document.getElementById('inv-shop-grid').innerHTML = '';
    document.getElementById('inv-basket-lines').innerHTML = '';
}

// ============================================
// Screen state — straight from the server
// ============================================

/** Take a screen state from the server and draw all of it. */
function applyScreen(state) {
    if (!state) return;
    screen = state;

    shop.items = {};
    toList(state.shelf).forEach((entry, i) => { shop.items[String(i + 1)] = entry; });
    shop.basket = {};
    for (const line of toList(state.basket)) shop.basket[String(line.slot)] = line;

    // Edit Shelf: no longer allowed (demoted meanwhile) ends it; goods that came onto the shelf while
    // it was open join the end of its list, in the tab the server has them in.
    if (editing && !state.canArrange) editing = null;
    if (editing) {
        for (const e of toList(state.shelf)) {
            if (editing.order.indexOf(e.item) === -1) {
                editing.order.push(e.item);
                editing.cat[e.item] = e.category && editing.cats.indexOf(e.category) !== -1 ? e.category : null;
            }
        }
    }

    // A tab whose last item has gone (sold, or moved to another tab) falls back to All.
    const tabs = tabList();
    if (tab === OTHER ? !tabs.other : (tab !== ALL && tabs.cats.indexOf(tab) === -1)) tab = ALL;

    renderTabs();
    renderSort();
    renderShelf();
    renderBasket();
    renderEditMode();
    talkFit();   // the talk rows fill the header down to the chips, or the goods when there are none
}

/** The tabs to show: the server's, or (while editing) the ones the edit puts goods in. */
function tabList() {
    if (!editing) {
        return { cats: toList(screen && screen.categories), other: !!(screen && screen.uncategorised) };
    }
    const used = new Set();
    let other = false;
    for (const key in shop.items) {
        const c = editing.cat[shop.items[key].item];
        if (c) used.add(c); else other = true;
    }
    return { cats: editing.cats.filter((c) => used.has(c)), other: other };
}

/** A shelf entry's tab, as the edit has it while editing. */
function categoryOf(entry) {
    if (editing) return editing.cat[entry.item] || null;
    return entry.category || null;
}

/** Something changed on either side of the screen (this player's action, or another's). */
function shopScreenUpdate(state) {
    if (!shop.open) return;
    applyScreen(state);
}

// ============================================
// The shopfront
// ============================================

/** The category chips, each with how many goods it holds. None when the shop has no categories. */
function renderTabs() {
    const box = document.getElementById('inv-shop-tabs');
    box.innerHTML = '';
    const list = tabList();
    if (list.cats.length === 0) {
        box.style.display = 'none';
        return;
    }
    box.style.display = '';
    const count = { [ALL]: 0, [OTHER]: 0 };
    for (const key in shop.items) {
        const c = categoryOf(shop.items[key]);
        count[ALL]++;
        if (c) count[c] = (count[c] || 0) + 1; else count[OTHER]++;
    }
    const tabs = [[ALL, 'All']];
    for (const c of list.cats) tabs.push([c, c]);
    if (list.other) tabs.push([OTHER, 'Other']);
    tabs.forEach(([key, label], i) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.id = 'inv-shop-tab-' + i;   // the controller keeps its place by id (inventory.js padKeyOf)
        b.className = 'inv-shop-tab inv-pad-btn' + (key === tab ? ' on' : '');
        b.dataset.tab = key;
        const name = document.createElement('span');
        name.textContent = label;
        const n = document.createElement('span');
        n.className = 'inv-shop-tab-n';
        n.textContent = String(count[key] || 0);
        b.append(name, n);
        box.appendChild(b);
    });
}

function renderSort() {
    for (const b of document.querySelectorAll('#inv-shop-sort .inv-sort-opt')) {
        b.classList.toggle('on', b.dataset.sort === sort);
    }
}

/** How many of each item the basket holds, and its last line (the one a card's minus takes from). */
function basketByItem() {
    const out = {};
    for (const key in shop.basket) {
        const line = shop.basket[key];
        const o = out[line.item] || (out[line.item] = { n: 0, last: null });
        o.n += Number(line.amount) || 0;
        if (!o.last || line.slot > o.last.slot) o.last = line;
    }
    return out;
}

// ============================================
// Ahead of the server: the number on screen, at once
// ============================================

/** How many of an item the server says the basket holds. */
function heldOf(item) {
    const h = basketByItem()[item];
    return h ? h.n : 0;
}

/** How many the screen shows: what the player asked for while it is on its way, else the server's. */
function shownOf(item) {
    const w = want.get(item);
    return w ? w.n : heldOf(item);
}

/** The most the basket can hold of an item: what it has plus what the shelf has left (an infinite
 *  shelf, the server's limit). The server decides in the end; this keeps the number off the shelf's end. */
function capFor(item) {
    let left = 0;
    for (const key in shop.items) {
        const e = shop.items[key];
        if (e.item !== item) continue;
        if (e.stock === undefined || e.stock === null) return MAX_QTY;
        left += Number(e.stock) || 0;
    }
    return Math.min(MAX_QTY, heldOf(item) + left);
}

/** What one of an item costs: its basket line's price, else the shelf's. */
function unitPrice(item) {
    for (const key in shop.basket) {
        const l = shop.basket[key];
        if (l.item === item && l.price !== undefined && l.price !== null) return Number(l.price) || 0;
    }
    for (const key in shop.items) if (shop.items[key].item === item) return Number(shop.items[key].price) || 0;
    return 0;
}

/** Each of an item's basket lines as the screen shows it: the server's amounts, with a change on its
 *  way laid on — more onto the last line, less off `from` first and then the last lines (as the server
 *  will). A line can show 0 until the server takes it away. Map: line slot -> amount. */
function linesShown(item) {
    const out = new Map();
    const lines = [];
    for (const key in shop.basket) {
        const l = shop.basket[key];
        if (l.item !== item) continue;
        lines.push(l);
        out.set(l.slot, Number(l.amount) || 0);
    }
    const w = want.get(item);
    if (!w || lines.length === 0) return out;
    let delta = w.n - heldOf(item);
    if (delta > 0) {
        const last = lines.reduce((a, b) => (b.slot > a.slot ? b : a));
        out.set(last.slot, out.get(last.slot) + delta);
    } else if (delta < 0) {
        // The lines pressed on first (newest first), then the last lines: Shops.setItemTotal's order.
        const rank = (slot) => { const i = w.from.indexOf(slot); return i < 0 ? Infinity : i; };
        lines.sort((a, b) => (rank(a.slot) - rank(b.slot)) || (b.slot - a.slot));
        for (const l of lines) {
            if (delta >= 0) break;
            const take = Math.min(out.get(l.slot), -delta);
            out.set(l.slot, out.get(l.slot) - take);
            delta += take;
        }
    }
    return out;
}

/** Ask for `n` of an item in the basket, all its lines together (`from`: a line pressed on, to take from
 *  first). The number is drawn now; the server hears it through pump. */
function setWant(item, n, from) {
    if (!shop.open || paying || typeof item !== 'string') return;
    n = Math.max(0, Math.min(capFor(item), Math.floor(Number(n)) || 0));
    const prev = want.get(item);
    if (prev ? n === prev.n : n === heldOf(item)) { paintItem(item); return; }
    // Every line pressed on while the change is on its way, newest first (three quick removals must
    // not keep the wrong line).
    const lines = (prev && prev.from || []).filter((s) => s !== from);
    if (from) lines.unshift(from);
    want.set(item, { n: n, from: lines.slice(0, 50) });
    paintItem(item);
    pump(item);
}

/** One request per item on its way, with the newest total; when it lands, the next if there is one. A
 *  'Rate limited' refusal is sent again shortly (a short ping and a held button can outrun the limit);
 *  any other refusal draws the server's own count. */
function pump(item, tries) {
    const w = want.get(item);
    if (!w || flying.has(item)) return;
    flying.add(item);
    const sent = w.n;
    const v = visit;
    const asked = nuiCallback('basketSetItem', { item: item, quantity: sent, from: w.from });
    const late = new Promise((done) => setTimeout(() => done(null), LAND_MS));
    Promise.race([asked, late]).then((res) => {
        if (v !== visit) return;
        flying.delete(item);
        const now = want.get(item);
        if (now && now.n !== sent) { pump(item); return; }   // they kept going: the newest total
        const limited = res && res.ok === false && /rate limited/i.test(String(res.why || ''));
        if (now && limited && (tries || 0) < RETRIES) {
            setTimeout(() => { if (v === visit) pump(item, (tries || 0) + 1); }, RETRY_MS);
            return;
        }
        want.delete(item);   // landed: the server's own count (its push came first) is the one drawn now
        paintItem(item);
    });
}

/** Everything ahead of the server dropped: the shop opened or closed. */
function forgetAhead() {
    visit++;
    want.clear();
    flying.clear();
    holdStop();
    padA = false;
    clearTimeout(buyFlashTimer);
    buyFlash = null;
}

/** Out of a count field, before a button, a tile or the pad changes the number: what was typed in it is
 *  taken first (its blur), and the press goes on top of that, so the blur cannot undo the clicks. */
function leaveQtyField() {
    const a = document.activeElement;
    if (!a || !a.classList || !a.classList.contains('inv-qty-input')) return;
    a.dataset.done = '1';                  // its blur has nothing left to do
    if (a.dataset.typed) commitQty(a);
    if (a.isConnected) a.blur();
}

/** Is this count field being typed in? Focused, and changed since — the one field a redraw leaves alone.
 *  (A field only clicked into still shows the number as it moves.) */
function typingIn(input) {
    return !!input && document.activeElement === input && !!input.dataset.typed;
}

/** The item's number redrawn where it shows — its cards, its basket lines, the till — without redrawing
 *  the rest (a held button steps many times a second; a field being typed in keeps its words). */
function paintItem(item) {
    if (!shop.open) return;
    const shown = shownOf(item);
    const full = shown >= capFor(item);
    for (const card of document.querySelectorAll('#inv-shop-grid .inv-shop-card')) {
        const e = shop.items[card.dataset.slot];
        if (!e || e.item !== item) continue;
        const input = card.querySelector('.inv-qty-input');
        if (input && shown > 0) {
            if (!typingIn(input)) input.value = String(shown);
            const inc = card.querySelector('button[data-act="inc"]');
            if (inc) inc.disabled = full;
        } else {
            // In the basket or out of it: the card's foot is a different thing (a + or the count). A field
            // of its own that has focus is let go of first, its blur told it is done (or the blur of a
            // field being removed comes back in here and replaces the card twice).
            const a = document.activeElement;
            if (a && card.contains(a)) { a.dataset.done = '1'; a.blur(); }
            if (card.isConnected) card.replaceWith(cardEl(Number(card.dataset.slot), e, shown));
        }
    }
    const amounts = linesShown(item);
    for (const row of document.querySelectorAll('#inv-basket-lines .inv-basket-line')) {
        const line = shop.basket[row.dataset.slot];
        if (!line || line.item !== item) continue;
        const n = amounts.get(line.slot) || 0;
        const input = row.querySelector('.inv-qty-input');
        if (input && !typingIn(input)) input.value = String(n);
        const total = row.querySelector('.inv-basket-line-total');
        if (total && line.price !== undefined && line.price !== null) total.textContent = priceText(line.price * n);
        const inc = row.querySelector('button[data-act="inc"]');
        if (inc && line.price !== undefined && line.price !== null) inc.disabled = full;
        row.classList.toggle('emptied', n === 0);
    }
    renderTill();
}

/** A held button's next step on an item: `size` more (dir 1) or fewer (-1), onto a round number of it.
 *  Answers whether the number moved (a held button stops at the shelf's end, or at none). */
function stepItem(item, dir, size, from) {
    const now = shownOf(item);
    let next = dir > 0 ? (Math.floor(now / size) + 1) * size : (Math.ceil(now / size) - 1) * size;
    next = Math.max(0, Math.min(capFor(item), next));
    if (next === now) return false;
    setWant(item, next, from);
    return true;
}

function holdStart(step, by) {
    holdStop();
    hold = { step: step, by: by, k: 0, timer: setTimeout(holdTick, HOLD_DELAY_MS) };
}

function holdTick() {
    if (!hold) return;
    // A let go (or never seen down) — or another screen opened over the shop, which then hears the pad
    // and its A is not ours to read.
    if (hold.by === 'pad' && (!padA || NuiRouter.activeNavScope() !== 'inventory')) { holdStop(); return; }
    hold.k++;
    const size = hold.k < 12 ? 1 : (hold.k < 24 ? 5 : 10);
    if (!shop.open || paying || !hold.step(size)) { holdStop(); return; }
    hold.timer = setTimeout(holdTick, Math.max(HOLD_MIN_MS, HOLD_FIRST_MS * Math.pow(0.9, hold.k)));
}

function holdStop() {
    if (hold) clearTimeout(hold.timer);
    hold = null;
}

// A held mouse button ends wherever it is let go (the button under it may have been redrawn).
window.addEventListener('mouseup', () => { if (hold && hold.by === 'mouse') holdStop(); });
window.addEventListener('blur', holdStop);

/** A redraw while a number is being typed keeps it: the same field, its words and the caret. The field
 *  being taken away is told it is done first: the blur its removal fires must not take a half-typed
 *  number (the "4" of a "40"). */
function keepTyping(draw) {
    const a = document.activeElement;
    const key = a && a.classList && a.classList.contains('inv-qty-input') ? a.dataset.qty : null;
    const kept = key ? { value: a.value, start: a.selectionStart, end: a.selectionEnd, typed: !!a.dataset.typed } : null;
    if (key) a.dataset.done = '1';
    draw();
    if (!kept) return;
    const again = document.querySelector('.inv-qty-input[data-qty="' + CSS.escape(key) + '"]');
    if (!again) return;
    again.focus();   // (its focusin starts it afresh; what was typed goes back below)
    if (kept.typed) {
        again.value = kept.value;
        again.dataset.typed = '1';
    }
    try { again.setSelectionRange(kept.start, kept.end); } catch (e) { /* not a text field */ }
}

/** The count as a field: it reads as the number until it is clicked, then takes a typed one. `key` finds
 *  it again after a redraw: 'card:<item>' (by item, not by
 *  place: a shelf rearranged under it keeps the same thing) or 'line:<slot>'. */
function qtyInput(key, n, label) {
    const i = document.createElement('input');
    i.type = 'text';
    i.inputMode = 'numeric';
    i.className = 'inv-qty-input';
    i.dataset.qty = key;
    i.maxLength = String(MAX_QTY).length;
    i.value = String(n);
    i.autocomplete = 'off';
    i.spellcheck = false;
    i.setAttribute('aria-label', label);
    return i;
}

/** The number a count field stands for now: a card's, its item's total; a line's, that line's. */
function qtyShown(input) {
    const key = input.dataset.qty || '';
    if (key.indexOf('card:') === 0) return shownOf(key.slice(5));
    const line = shop.basket[key.slice(5)];
    return line ? (linesShown(line.item).get(line.slot) || 0) : 0;
}

/** A typed number, taken: a card's is the item's total; a line's is that line's, the rest kept. The
 *  field then shows what it came to (a number past the shelf's end is what the shelf has). */
function commitQty(input) {
    if (!input.isConnected || !shop.open) return;   // redrawn away: keepTyping has its words
    const key = input.dataset.qty || '';
    const typed = parseInt(input.value, 10);
    delete input.dataset.typed;
    if (!isNaN(typed)) {
        if (key.indexOf('card:') === 0) {
            const item = key.slice(5);
            const sold = Object.keys(shop.items).some((k) => shop.items[k].item === item);
            if (sold || heldOf(item) > 0) setWant(item, typed);
        } else if (key.indexOf('line:') === 0) {
            const line = shop.basket[key.slice(5)];
            if (line) setWant(line.item, shownOf(line.item) - qtyShown(input) + typed, line.slot);
        }
    }
    if (input.isConnected) input.value = String(qtyShown(input));
}

/** The goods on the chosen chip that match the search, in the chosen order, as cards. */
function renderShelf() {
    keepTyping(drawShelf);
}

function drawShelf() {
    const grid = document.getElementById('inv-shop-grid');
    grid.innerHTML = '';

    let places = Object.keys(shop.items).map(Number).sort((a, b) => a - b);
    // While editing, the shelf shows the edit's order: what Save will make it.
    if (editing) {
        const rank = new Map(editing.order.map((item, i) => [item, i]));
        const at = (n) => { const r = rank.get(shop.items[String(n)].item); return r === undefined ? 1e9 : r; };
        places.sort((a, b) => (at(a) - at(b)) || (a - b));
    }
    const all = places.length;
    const q = query.trim().toLowerCase();

    places = places.filter((n) => {
        const e = shop.items[String(n)];
        const c = categoryOf(e);
        if (tab === OTHER ? !!c : (tab !== ALL && c !== tab)) return false;
        if (!q) return true;
        const def = invItemDefs[e.item] || {};
        return itemName(e.item).toLowerCase().includes(q)
            || String(def.desc || '').toLowerCase().includes(q)
            || e.item.toLowerCase().includes(q);
    });
    if (sort === 'price') {
        places.sort((a, b) => (shop.items[String(a)].price - shop.items[String(b)].price) || (a - b));
    } else if (sort === 'az') {
        places.sort((a, b) => itemName(shop.items[String(a)].item).localeCompare(itemName(shop.items[String(b)].item)) || (a - b));
    }

    for (const n of places) grid.appendChild(cardEl(n, shop.items[String(n)], shownOf(shop.items[String(n)].item)));

    if (places.length === 0 && all > 0) {
        const none = document.createElement('div');
        none.className = 'inv-shop-none';
        none.textContent = q ? 'Nothing here matches “' + query.trim() + '”.' : 'Nothing in this tab right now.';
        grid.appendChild(none);
    }

    let sub = all === 0 ? 'Nothing for sale right now'
        : (places.length < all ? places.length + ' of ' + all + ' shown'
            : (all === 1 ? '1 thing for sale' : all + ' things for sale'));
    if (all > 0 && !takesMoney()) sub += ' · paid in ' + ((shop.data.currency && shop.data.currency.name) || 'goods');
    document.getElementById('inv-shop-sub').textContent = sub;
}

/**
 * One card: the picture (with "Only 3" or "Sold out" over it), the name, what is left and what one
 * weighs, the price, and a + — or, for something already in the basket, its count with a minus and a
 * plus. Clicking the card adds one (inventory.js, the shop branch of the slot listeners); the minus
 * and plus are their own buttons (.inv-shop-card-ctl, which those listeners leave alone), and the
 * count between them is a field a number can be typed into.
 *
 * A stocked shop's `stock` is what is left on the shelf — what is in baskets has already come off it.
 * An infinite shop has none: its goods never run out. `inBag` is the count the screen shows (shownOf),
 * so what is left is drawn less whatever is on its way to the basket.
 */
function cardEl(n, e, inBag) {
    const def = invItemDefs[e.item] || {};
    const counted = e.stock !== undefined && e.stock !== null;
    const left = counted ? Math.max(0, (Number(e.stock) || 0) - (inBag - heldOf(e.item))) : Infinity;
    const gone = counted && left <= 0;

    const card = document.createElement('div');
    card.className = 'inv-slot inv-shop-card has-item'
        + (inBag > 0 ? ' in-bag' : '') + (gone && inBag === 0 ? ' out-of-stock' : '');
    card.dataset.container = 'shop';
    card.dataset.slot = n;

    // ---- the picture ----
    const art = document.createElement('div');
    art.className = 'inv-shop-card-art';
    const item = document.createElement('div');
    item.className = 'inv-item';
    item.dataset.item = e.item;          // what the slot listeners, the item card and the pad read
    item.dataset.container = 'shop';
    item.dataset.slot = n;
    const img = document.createElement('img');
    img.className = 'inv-item-img';
    img.dataset.itemImg = '';
    img.dataset.itemKey = e.item;        // so the picture fallback knows what to retry
    img.alt = '';
    img.draggable = false;
    img.src = itemImageUrl(e.item);
    item.appendChild(img);
    art.appendChild(item);
    if (gone || (counted && left <= 3)) {
        const flag = document.createElement('span');
        flag.className = 'inv-shop-card-flag ' + (gone && inBag === 0 ? 'out' : 'low');
        flag.textContent = gone ? (inBag > 0 ? 'None left' : 'Sold out') : 'Only ' + left;
        art.appendChild(flag);
    }

    // ---- the words ----
    const name = document.createElement('div');
    name.className = 'inv-shop-card-name';
    name.textContent = itemName(e.item);
    const meta = document.createElement('div');
    meta.className = 'inv-shop-card-meta';
    const weight = def.weight !== undefined ? weightText(def.weight) : '';
    meta.textContent = gone && inBag === 0 ? 'Sold out'
        : (counted ? left.toLocaleString('en-US') + ' left' + (weight ? ' · ' + weight : '') : weight);

    // ---- the price, and the + or the count ----
    const foot = document.createElement('div');
    foot.className = 'inv-shop-card-foot';
    const price = document.createElement('span');
    price.className = 'inv-shop-card-price';
    price.textContent = priceText(e.price);
    foot.appendChild(price);
    if (inBag > 0) {
        const ctl = document.createElement('div');
        ctl.className = 'inv-shop-card-ctl';
        const dec = document.createElement('button');
        dec.type = 'button';
        dec.dataset.act = 'dec';
        dec.setAttribute('aria-label', 'One fewer');
        dec.textContent = '−';
        const count = qtyInput('card:' + e.item, inBag, 'How many of ' + itemName(e.item));
        const inc = document.createElement('button');
        inc.type = 'button';
        inc.dataset.act = 'inc';
        inc.setAttribute('aria-label', 'One more');
        inc.textContent = '+';
        inc.disabled = gone || inBag >= capFor(e.item);
        ctl.append(dec, count, inc);
        foot.appendChild(ctl);
    } else if (!gone) {
        // Not a button of its own: the whole card is the click that adds one.
        const plus = document.createElement('span');
        plus.className = 'inv-shop-card-plus';
        plus.setAttribute('aria-hidden', 'true');
        plus.textContent = '+';
        foot.appendChild(plus);
    }

    card.append(art, name, meta, foot);
    return card;
}

// ============================================
// The basket
// ============================================

function renderBasket() {
    keepTyping(drawBasket);
}

function drawBasket() {
    const box = document.getElementById('inv-basket-lines');
    box.innerHTML = '';
    const lines = toList(screen && screen.basket);
    const size = (screen && screen.basketSlots) || 0;

    document.getElementById('inv-basket-count').textContent = lines.length === 0
        ? 'Empty'
        : `${lines.length} of ${size} ${size === 1 ? 'line' : 'lines'}`;

    if (lines.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'inv-basket-empty';
        empty.textContent = 'Pick anything on the shelf to put it here.';
        box.appendChild(empty);
    }
    const shown = new Map();   // item -> its lines as the screen shows them (linesShown)
    for (const line of lines) {
        if (!shown.has(line.item)) shown.set(line.item, linesShown(line.item));
        box.appendChild(lineEl(line, shown.get(line.item).get(line.slot) || 0));
    }
    renderTill();
}

/** One basket line: the picture, the name and what one costs, minus / count / plus, the line's total,
 *  and remove. A line the shop has stopped selling says so instead of a price. `amount` is the line as
 *  the screen shows it (with a change on its way); the count is a field a number can be typed into. */
function lineEl(line, amount) {
    const priced = line.price !== undefined && line.price !== null;
    const row = document.createElement('div');
    row.className = 'inv-basket-line' + (priced ? '' : ' unpriced') + (amount === 0 ? ' emptied' : '');
    row.dataset.slot = line.slot;

    const art = document.createElement('div');
    art.className = 'inv-basket-art';
    const img = document.createElement('img');
    img.className = 'inv-item-img';
    img.dataset.itemImg = '';
    img.dataset.itemKey = line.item;   // so the picture fallback knows what to retry (utils.js)
    img.alt = '';
    img.draggable = false;
    img.src = itemImageUrl(line.item);
    art.appendChild(img);

    const info = document.createElement('div');
    info.className = 'inv-basket-info';
    const name = document.createElement('div');
    name.className = 'inv-basket-name';
    name.textContent = itemName(line.item);
    const each = document.createElement('div');
    each.className = 'inv-basket-each';
    each.textContent = priced ? (line.price === 0 ? 'Free' : priceText(line.price) + ' each') : 'No longer for sale';
    info.append(name, each);

    const qty = document.createElement('div');
    qty.className = 'inv-basket-qty';
    const n = qtyInput('line:' + line.slot, amount, 'How many of ' + itemName(line.item));
    n.classList.add('inv-basket-n');
    const inc = lineButton(line, 'inc', '+', 'One more');
    if (priced && shownOf(line.item) >= capFor(line.item)) inc.disabled = true;
    qty.append(lineButton(line, 'dec', '−', 'One fewer'), n, inc);

    const total = document.createElement('div');
    total.className = 'inv-basket-line-total';
    total.textContent = priced ? priceText(line.price * amount) : '—';

    row.append(art, info, qty, total, lineButton(line, 'remove', '×', 'Take it out'));
    return row;
}

function lineButton(line, act, text, label) {
    const b = document.createElement('button');
    b.type = 'button';
    b.id = `inv-bl-${line.slot}-${act}`;   // stable across redraws, so the controller keeps its place
    b.className = (act === 'remove' ? 'inv-line-remove' : 'inv-qty-btn') + ' inv-pad-btn';
    b.dataset.act = act;
    b.title = label;
    b.setAttribute('aria-label', label);
    b.textContent = text;
    // Nothing more to add of something the shop no longer sells.
    if (act === 'inc' && (line.price === undefined || line.price === null)) b.disabled = true;
    return b;
}

/** The till: what the pockets will weigh, the total, how to pay, and Buy. */
function renderTill() {
    const s = screen || {};
    const lines = toList(s.basket);
    const unpriced = lines.some((l) => l.price === undefined || l.price === null);

    // The server's figures, with the changes on their way laid on (they are drawn at once), and a
    // basket that has anything in it on screen.
    let basketTotal = Number(s.basketTotal) || 0;
    let basketWeight = Number(s.basketWeight) || 0;
    const items = new Set(lines.map((l) => l.item));
    for (const [item, w] of want) {
        const d = w.n - heldOf(item);
        basketTotal += d * unitPrice(item);
        basketWeight += d * (Number((invItemDefs[item] || {}).weight) || 0);
        items.add(item);
    }
    let has = false;
    for (const item of items) if (shownOf(item) > 0) { has = true; break; }
    // A change still on its way: Buy waits for it (the till would price the basket as it was).
    const settling = want.size > 0 || flying.size > 0;

    // ---- will it fit ----
    // The pockets as the inventory reads them (the accessory strip counts towards the total), plus
    // the basket. The server's verdict (cannotCarry) is the one that counts — it is what the till
    // asks, and it may be pocket SLOTS rather than weight, so the gauge colours only for the weight
    // and the words below it say whatever the reason is.
    const now = (inv.weights.player || 0) + (inv.weights.accessory || 0);
    const max = inv.maxWeight.player || 0;
    const after = now + basketWeight;
    const f = max > 0 ? after / max : 0;
    document.getElementById('inv-basket-carry-figure').textContent = weightLine(after, max);
    document.getElementById('inv-basket-carry-fill').style.transform =
        'scaleX(' + Math.min(1, Math.max(0, f)).toFixed(3) + ')';
    const carry = document.getElementById('inv-basket-carry');
    const refused = !!s.cannotCarry;
    const over = f > 1 + 1e-6;
    carry.classList.toggle('full', over);
    carry.classList.toggle('near', !over && f >= 0.85);

    const warn = document.getElementById('inv-basket-warn');
    warn.textContent = s.cannotCarry
        || (unpriced ? 'Take out what is no longer for sale to buy the rest' : '');
    warn.style.display = warn.textContent ? '' : 'none';

    // ---- the total ----
    document.getElementById('inv-basket-total').textContent =
        has ? priceText(basketTotal) : (takesMoney() ? '$0' : priceText(0));

    // ---- how to pay ----
    const money = takesMoney();
    const accounts = document.getElementById('inv-basket-account');
    const canBank = money && accounts.options.length > 0;
    if (!canBank && payMethod === 'bank') payMethod = 'cash';
    document.getElementById('inv-basket-pay').style.display = money ? '' : 'none';
    for (const b of document.querySelectorAll('#inv-basket-pay .inv-pay-opt')) {
        b.classList.toggle('on', b.dataset.method === payMethod);
        b.disabled = b.dataset.method === 'bank' && !canBank;
    }
    accounts.style.display = money && payMethod === 'bank' ? '' : 'none';
    const paysIn = document.getElementById('inv-basket-pays-in');
    paysIn.style.display = money ? 'none' : '';
    paysIn.textContent = money ? '' : 'Paid in ' + ((shop.data && shop.data.currency && shop.data.currency.name) || 'goods');

    // ---- Buy ----
    const buy = document.getElementById('inv-basket-buy-btn');
    buy.disabled = paying || settling || !has || refused || unpriced;
    buy.textContent = paying ? 'Paying…' : (has && !unpriced ? 'Buy · ' + priceText(basketTotal) : 'Buy');
    // What the till said, for a moment (shopPurchaseResult), over whatever Buy would say.
    const flash = !paying && buyFlash;
    if (flash) buy.textContent = flash.text;
    for (const cls of ['buy-ok', 'buy-err', 'buy-warn']) buy.classList.toggle(cls, !!flash && flash.cls === cls);
}

// ============================================
// Edit Shelf — the shop's managers and whip's admins (Shops.canArrange)
// ============================================
//
// Shelf order and categories, set by the shop's managers or an admin. Opened from the
// shopfront's Edit Shelf button, it takes the basket's place: the tabs (add, reorder, remove) and
// the goods (their tab, and their place). The shelf beside it shows the new order as it is made.
// Save sends the whole arrangement once (whip_core:server:shopSetLayout); Cancel forgets it.

/** Which of the two panels the right-hand column shows, and the Edit Shelf button. */
function renderEditMode() {
    const can = !!(screen && screen.canArrange);
    document.getElementById('inv-shop-edit-btn').style.display = can && !editing ? '' : 'none';
    document.getElementById('inv-basket-panel').style.display = editing ? 'none' : '';
    document.getElementById('inv-shelf-edit-panel').style.display = editing ? '' : 'none';
    if (editing) renderEditor();
}

function enterEdit() {
    if (!screen || !screen.canArrange || editing) return;
    const cats = toList(screen.allCategories).slice();
    const order = [];
    const cat = {};
    for (const e of toList(screen.shelf)) {
        order.push(e.item);
        cat[e.item] = e.category && cats.indexOf(e.category) !== -1 ? e.category : null;
    }
    // rev: the shelf's layout revision this draft is made from. Save sends it, and the server refuses a save made
    // from an older one (someone else saved meanwhile) rather than letting this draft wipe theirs.
    editing = { cats: cats, order: order, cat: cat, rev: Number.isInteger(screen.layoutRev) ? screen.layoutRev : -1 };
    tab = ALL;
    // The preview is of the shelf's own order, which is what is being arranged.
    sort = 'shelf';
    renderSort();
    renderTabs();
    renderShelf();
    renderEditMode();
}

function exitEdit() {
    editing = null;
    if (!shop.open) return;
    const tabs = tabList();
    if (tab !== ALL && tab !== OTHER && tabs.cats.indexOf(tab) === -1) tab = ALL;
    renderTabs();
    renderShelf();
    renderEditMode();
}

function saveEdit() {
    if (!editing) return;
    // Every good's place, by its position in the edit; the tabs in the edit's order.
    const layout = {};
    editing.order.forEach((item, i) => {
        layout[item] = { order: i + 1, category: editing.cat[item] || false };
    });
    nuiCallback('shopSetLayout', { categories: editing.cats.slice(), layout: layout, layoutRev: editing.rev });
    // The server redraws every customer once it has saved (Shops.update); this screen with them.
    exitEdit();
}

/** Something in the edit changed: the editor, and the shelf and tabs beside it. */
function editChanged() {
    const tabs = tabList();
    if (tab !== ALL && (tab === OTHER ? !tabs.other : tabs.cats.indexOf(tab) === -1)) tab = ALL;
    renderTabs();
    renderShelf();
    renderEditor();
}

function editButton(id, act, text, label, disabled) {
    const b = document.createElement('button');
    b.type = 'button';
    b.id = id;   // stable, so the controller keeps its place through a redraw
    b.className = (act === 'remove' ? 'inv-line-remove' : 'inv-qty-btn') + ' inv-pad-btn';
    b.dataset.act = act;
    b.title = label;
    b.setAttribute('aria-label', label);
    b.textContent = text;
    b.disabled = !!disabled;
    return b;
}

function renderEditor() {
    if (!editing) return;

    // ---- the tabs ----
    const cats = document.getElementById('inv-edit-cats');
    cats.innerHTML = '';
    if (editing.cats.length === 0) {
        const none = document.createElement('div');
        none.className = 'inv-edit-none';
        none.textContent = 'No tabs: everything shows on one shelf.';
        cats.appendChild(none);
    }
    editing.cats.forEach((name, i) => {
        const row = document.createElement('div');
        row.className = 'inv-edit-row inv-edit-cat';
        row.dataset.index = i;
        const label = document.createElement('div');
        label.className = 'inv-edit-name';
        label.textContent = name;
        const n = Object.keys(editing.cat).filter((item) => editing.cat[item] === name).length;
        const count = document.createElement('div');
        count.className = 'inv-edit-count';
        count.textContent = n === 1 ? '1 thing' : n + ' things';
        row.append(label, count,
            editButton('inv-ed-cat-' + i + '-up', 'cat-up', '↑', 'Earlier', i === 0),
            editButton('inv-ed-cat-' + i + '-down', 'cat-down', '↓', 'Later', i === editing.cats.length - 1),
            editButton('inv-ed-cat-' + i + '-rm', 'remove', '×', 'Remove this tab'));
        cats.appendChild(row);
    });
    document.getElementById('inv-edit-addcat').disabled = editing.cats.length >= MAX_TABS;

    // ---- the goods ----
    const goods = document.getElementById('inv-edit-goods');
    goods.innerHTML = '';
    editing.order.forEach((item, i) => {
        const row = document.createElement('div');
        row.className = 'inv-edit-row inv-edit-good';
        row.dataset.item = item;

        const art = document.createElement('div');
        art.className = 'inv-basket-art inv-edit-art';
        const img = document.createElement('img');
        img.className = 'inv-item-img';
        img.dataset.itemImg = '';
        img.dataset.itemKey = item;
        img.alt = '';
        img.draggable = false;
        img.src = itemImageUrl(item);
        art.appendChild(img);

        const name = document.createElement('div');
        name.className = 'inv-edit-name';
        name.textContent = itemName(item);

        const pick = document.createElement('select');
        pick.className = 'inv-edit-pick';
        pick.id = 'inv-ed-g-' + item + '-tab';
        const none = document.createElement('option');
        none.value = '';
        none.textContent = 'No tab';
        pick.appendChild(none);
        for (const c of editing.cats) {
            const opt = document.createElement('option');
            opt.value = c;
            opt.textContent = c;
            pick.appendChild(opt);
        }
        pick.value = editing.cat[item] || '';

        row.append(art, name, pick,
            editButton('inv-ed-g-' + item + '-up', 'good-up', '↑', 'Earlier on the shelf', i === 0),
            editButton('inv-ed-g-' + item + '-down', 'good-down', '↓', 'Later on the shelf', i === editing.order.length - 1));
        goods.appendChild(row);
    });
}

/** Swap two places in a list. */
function swap(list, a, b) {
    if (a < 0 || b < 0 || a >= list.length || b >= list.length) return;
    const t = list[a];
    list[a] = list[b];
    list[b] = t;
}

/** The new-tab box: a name of 1-24 letters, not one the shop has (any case), and no more than 12. */
function addTab() {
    if (!editing) return;
    const input = document.getElementById('inv-edit-newcat');
    const name = input.value.trim();
    const taken = editing.cats.some((c) => c.toLowerCase() === name.toLowerCase());
    if (!name || name.length > MAX_TAB_LEN || taken || editing.cats.length >= MAX_TABS) {
        input.classList.add('bad');
        setTimeout(() => input.classList.remove('bad'), 1200);
        return;
    }
    editing.cats.push(name);
    input.value = '';
    editChanged();
}

// ============================================
// Asking the server
// ============================================

/** Put `amount` more of an item in the basket (a tile's click, the pad's A, "Add several"). `by` says a
 *  press that can be held — 'mouse' (a tile's mousedown) or 'pad' (A on a tile) — which keeps adding,
 *  faster, until it is let go. Through setWant, like every change: the number moves at once. */
function add(itemKey, amount, by) {
    if (!shop.open || paying) return;
    leaveQtyField();
    setWant(itemKey, shownOf(itemKey) + Math.max(1, Math.floor(amount) || 1));
    if (by === 'mouse' || by === 'pad') holdStart((size) => stepItem(itemKey, 1, size), by);
}

/** Set a basket line to an exact quantity; 0 takes it out (its right-click's Set Quantity). The rest of
 *  the item's lines are kept. */
function setLine(slot, quantity) {
    const line = shop.basket[slot];
    if (!line) return;
    const mine = linesShown(line.item).get(line.slot) || 0;
    setWant(line.item, shownOf(line.item) - mine + Math.max(0, Math.floor(quantity) || 0), line.slot);
}

/** A basket line's or a card's minus / plus / remove, once (`act`), from `el`. Answers the held step for
 *  minus and plus (a held button repeats it), or null. */
function pressQty(el) {
    if (!el || el.disabled || !shop.open || paying) return null;
    leaveQtyField();
    const act = el.dataset.act;
    const row = el.closest('.inv-basket-line');
    const card = !row && el.closest('.inv-shop-card');
    let item, from = 0;
    if (row) {
        const line = shop.basket[row.dataset.slot];
        if (!line) return null;
        item = line.item;
        from = line.slot;
        if (act === 'remove') {
            setLine(line.slot, 0);
            return null;
        }
    } else if (card) {
        const entry = shop.items[card.dataset.slot];
        if (!entry) return null;
        item = entry.item;
        // A card's minus takes from the item's last line, as it always did.
        const held = basketByItem()[item];
        from = held && held.last ? held.last.slot : 0;
    } else {
        return null;
    }
    const dir = act === 'inc' ? 1 : (act === 'dec' ? -1 : 0);
    if (!dir) return null;
    const step = (size) => stepItem(item, dir, size, from);
    step(1);
    return step;
}

function setPaying(on) {
    paying = on;
    clearTimeout(payingTimer);
    // The result normally clears this. A reply that never comes must not leave Buy dead for good.
    if (on) payingTimer = setTimeout(() => { paying = false; if (shop.open) renderTill(); }, 10000);
}

/**
 * Pay. THE BASKET DOES NOT TRAVEL — the server already holds it and prices it. What goes is how to
 * pay and the total on this screen, which the till compares with its own and refuses on a
 * difference (a price changed after this screen last drew) rather than charge a figure the player
 * never saw.
 */
function buy() {
    // Not while a change is on its way: the till would price the basket as it was before it.
    if (paying || !screen || toList(screen.basket).length === 0 || want.size > 0 || flying.size > 0) return;
    const method = takesMoney() ? payMethod : 'cash';
    const accountId = method === 'bank'
        ? parseInt(document.getElementById('inv-basket-account').value, 10) || 0
        : 0;
    setPaying(true);
    renderTill();
    nuiCallback('shopPurchase', {
        paymentMethod: method,
        accountId: accountId,
        expectedTotal: Number(screen.basketTotal) || 0,
    });
}

/** The till answered. The basket redraws from the server's own push (Shops.purchase), not from this; the
 *  answer goes on Buy for a moment: green "Purchase Successful!", red "Not enough
 *  cash!" (or the reason it was refused), amber "You can't carry all of this!". */
function shopPurchaseResult(res) {
    setPaying(false);
    res = res || {};
    let text, cls;
    if (res.success) {
        text = 'Purchase Successful!';
        cls = 'buy-ok';
    } else if (res.kind === 'money') {
        const c = shop.data && shop.data.currency;
        text = !takesMoney() ? 'Not enough ' + ((c && c.name) || 'to pay') + '!'
            : (payMethod === 'bank' ? 'Not enough in the bank!' : 'Not enough cash!');
        cls = 'buy-err';
    } else if (res.kind === 'carry') {
        text = "You can't carry all of this!";
        cls = 'buy-warn';
    } else {
        text = (typeof res.error === 'string' && res.error) || 'Purchase failed';
        cls = 'buy-err';
    }
    clearTimeout(buyFlashTimer);
    buyFlash = { text: text, cls: cls };
    buyFlashTimer = setTimeout(() => { buyFlash = null; if (shop.open) renderTill(); }, BUY_FLASH_MS);
    if (shop.open) renderTill();
}

// ============================================
// Listeners — bound once; the rows they serve are rebuilt on every draw
// ============================================

document.getElementById('inv-shop-tabs').addEventListener('click', (e) => {
    const b = e.target.closest('.inv-shop-tab');
    if (!b) return;
    tab = b.dataset.tab;
    renderTabs();
    renderShelf();
});

document.getElementById('inv-shop-sort').addEventListener('click', (e) => {
    const b = e.target.closest('.inv-sort-opt');
    if (!b) return;
    sort = b.dataset.sort;
    renderSort();
    renderShelf();
});

document.getElementById('inv-shop-search').addEventListener('input', (e) => {
    query = e.target.value;
    renderShelf();
});

// A card's minus and plus (only on something already in the basket) and a basket line's: the minus takes
// one off (a card's, off the item's last line), the plus adds one. ON MOUSEDOWN, so a held button keeps
// going (holdStart); a click that is not the mouse's — the pad's A (inventory.js padActivate) or a key —
// steps once on 'click', and the pad's hold is started by padPressed below. Remove is its click, always.
const QTY_BUTTON = '.inv-shop-card-ctl button[data-act], .inv-basket-line button[data-act]';

function qtyMouseDown(e) {
    if (e.button !== 0) return;
    const b = e.target.closest(QTY_BUTTON);
    if (!b || b.dataset.act === 'remove') return;
    e.preventDefault();
    const step = pressQty(b);
    if (step) holdStart(step, 'mouse');
}

function qtyClick(e) {
    const b = e.target.closest(QTY_BUTTON);
    if (!b) return;
    if (b.dataset.act === 'remove' || e.detail === 0) pressQty(b);
}

for (const id of ['inv-shop-grid', 'inv-basket-lines']) {
    const box = document.getElementById(id);
    box.addEventListener('mousedown', qtyMouseDown);
    box.addEventListener('click', qtyClick);

    // ---- the count fields: click, type, Enter (Escape puts the number back) ----
    box.addEventListener('focusin', (e) => {
        if (!e.target.classList.contains('inv-qty-input')) return;
        delete e.target.dataset.done;
        delete e.target.dataset.typed;
        e.target.select();
    });
    // `typed`: something was typed since it was clicked into. Only then does leaving it take the number,
    // and only then does a redraw leave its words alone (typingIn).
    box.addEventListener('input', (e) => {
        const i = e.target;
        if (!i.classList.contains('inv-qty-input')) return;
        const digits = i.value.replace(/\D+/g, '');
        if (digits !== i.value) i.value = digits;
        i.dataset.typed = '1';
    });
    box.addEventListener('keydown', (e) => {
        const i = e.target;
        if (!i.classList.contains('inv-qty-input')) return;
        // Each answered here, not left to the blur, and marked done FIRST: taking the number can redraw
        // the card (a 0 takes it out of the basket), whose removal blurs the field, and that blur must
        // find nothing left to do (or it takes the number twice and jams Buy).
        if (e.key === 'Enter') {
            e.preventDefault();
            i.dataset.done = '1';
            commitQty(i);
            if (i.isConnected) i.blur();
        } else if (e.key === 'Escape') {
            // The field's, not the inventory's: put the number back and leave the field.
            e.preventDefault();
            e.stopPropagation();
            i.dataset.done = '1';
            delete i.dataset.typed;
            i.value = String(qtyShown(i));
            i.blur();
        }
    });
    // Clicked away from after typing: what was typed is taken, as Enter takes it.
    box.addEventListener('focusout', (e) => {
        const i = e.target;
        if (!i.classList.contains('inv-qty-input')) return;
        if (i.dataset.done) { delete i.dataset.done; return; }
        if (i.dataset.typed) commitQty(i);
    });
}

// Right-click a line: type or slide to the number wanted (inventory.js's amount panel).
document.getElementById('inv-basket-lines').addEventListener('contextmenu', (e) => {
    const row = e.target.closest('.inv-basket-line');
    if (!row) return;
    e.preventDefault();
    const line = shop.basket[row.dataset.slot];
    // From the number on screen, not the server's (a change may still be on its way).
    if (line && !paying) {
        leaveQtyField();
        const shown = linesShown(line.item).get(line.slot) || 0;
        showBasketQuantity(e.clientX, e.clientY, Object.assign({}, line, { amount: shown }), row);
    }
});

document.getElementById('inv-basket-pay').addEventListener('click', (e) => {
    const b = e.target.closest('.inv-pay-opt');
    if (!b || b.disabled) return;
    payMethod = b.dataset.method;
    renderTill();
});

document.getElementById('inv-basket-buy-btn').addEventListener('click', buy);

// ---- Edit Shelf ----
document.getElementById('inv-shop-edit-btn').addEventListener('click', enterEdit);
document.getElementById('inv-edit-cancel').addEventListener('click', exitEdit);
document.getElementById('inv-edit-save').addEventListener('click', saveEdit);
document.getElementById('inv-edit-addcat').addEventListener('click', addTab);
document.getElementById('inv-edit-newcat').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); addTab(); }
});

document.getElementById('inv-shelf-edit-panel').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-act]');
    if (!b || b.disabled || !editing) return;
    const catRow = b.closest('.inv-edit-cat');
    const goodRow = b.closest('.inv-edit-good');
    if (catRow) {
        const i = Number(catRow.dataset.index);
        if (b.dataset.act === 'cat-up') swap(editing.cats, i, i - 1);
        else if (b.dataset.act === 'cat-down') swap(editing.cats, i, i + 1);
        else if (b.dataset.act === 'remove') {
            // Its goods go back to no tab; they keep their places on the shelf.
            const gone = editing.cats.splice(i, 1)[0];
            for (const item in editing.cat) if (editing.cat[item] === gone) editing.cat[item] = null;
        }
        editChanged();
    } else if (goodRow) {
        const i = editing.order.indexOf(goodRow.dataset.item);
        if (b.dataset.act === 'good-up') swap(editing.order, i, i - 1);
        else if (b.dataset.act === 'good-down') swap(editing.order, i, i + 1);
        editChanged();
    }
});

document.getElementById('inv-shelf-edit-panel').addEventListener('change', (e) => {
    const pick = e.target.closest('.inv-edit-pick');
    const row = pick && pick.closest('.inv-edit-good');
    if (!row || !editing) return;
    editing.cat[row.dataset.item] = pick.value || null;
    editChanged();
});

// The against-the-grain call direction (inventory -> shops) goes through the shared hook registry
// — see core/inv-state.js. inventory.js never names these functions directly. Function
// declarations hoist, so registering at file bottom is safe.
invRegisterShopHooks({
    openShop: openShop,
    closeShop: closeShop,
    add: add,
    setLine: setLine,
    // The pad (inventory.js): A pressed on a button (padActivate has clicked it once — a basket line's
    // minus or plus keeps going while A stays down), and whether A is down (the stick's messages say).
    padPressed: (el) => {
        if (!el || !el.matches || !el.matches(QTY_BUTTON) || el.dataset.act === 'remove') return;
        leaveQtyField();
        const row = el.closest('.inv-basket-line');
        const line = row && shop.basket[row.dataset.slot];
        if (!line) return;
        const dir = el.dataset.act === 'inc' ? 1 : -1;
        holdStart((size) => stepItem(line.item, dir, size, line.slot), 'pad');
    },
    padA: (down) => {
        padA = down === true;
        if (!padA && hold && hold.by === 'pad') holdStop();
    },
});

// ROUTER REGISTRATION — see router.js's header.
NuiRouter.register('closeShop', () => closeShop());
NuiRouter.register('shopPurchaseResult', (d) => shopPurchaseResult(d.data));
NuiRouter.register('shopScreenUpdate', (d) => shopScreenUpdate(d.data));
