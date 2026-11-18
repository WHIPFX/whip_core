import { NuiRouter } from './router.js';
import { padGlyph } from './pad-glyphs.js';

// ============================================
// Editor HUD — the in-world editor overlay, for any tool
//
// The zone and door editors each carry a HUD written for them alone: fixed markup, fixed rows.
// The Property Configurator has a dozen in-world modes (drawing a space, picking doors, placing a
// sign, a Verify tour), and a hand-written HUD each would be a dozen copies of the same box. This
// is that box once, built from what Lua sends: a title, a line under it, rows of label and value,
// an optional progress bar, the key hints, and a status line.
//
// THE DOOR EDITOR'S LOOK, by its own classes (.de-panel and friends, css/doors.css), so every
// in-world editor reads as one family. css/editor-hud.css adds only what that HUD never needed.
//
// Driven by tools/editor_hud.lua:
//   ehShow   { state }   replace everything and show
//   ehUpdate { patch }   change some fields (title, sub, rows, hints, progress) and redraw
//   ehStatus { text, kind }   a line under the panel for three seconds; kind 'ok' | 'err' | 'warn'
//   ehHide
//
// Everything is textContent: labels and values can carry names people typed.
// ============================================

let state = {};
let body = null;
let statusEl = null;
let statusTimer = null;

function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
}

function ensureRoot() {
    const root = document.getElementById('editor-hud');
    if (!root) return null;
    if (!body) {
        body = el('div', 'eh-body');
        statusEl = el('div', 'de-status eh-status');
        statusEl.style.display = 'none';
        root.appendChild(body);
        root.appendChild(statusEl);
    }
    return root;
}

// A row or hint can be written either way round from Lua: { label, value } or { 'Label', 'value' }.
function pair(item, a, b) {
    if (Array.isArray(item)) return [item[0], item[1]];
    return [item[a], item[b]];
}

// ============================================
// THE HOUSE LOOK — a mode that sends `house = true` (css/editor-hud.css says how it looks)
//
// The state it reads, beside the old one's title / rows / hints:
//   icon     a 3D-prompt glyph's name for the disc (js/glyphs.js: 'door')
//   sub      what is happening, beside the target's state
//   chip     { text, tone } — the target's state, 'ok' | 'warn' | 'err' or none
//   progress { done, total } — a bar under the head (Verify's tour)
//   rows     { label, value, tone, wrap } — `wrap` lets a long value (a problem) run onto more lines
//   hints    { key, pad, text, off, group } — `key` the keyboard's (a string; ' / ' and ' + ' make
//            several caps), `pad` a button's picture or a list of them (js/pad-glyphs.js), or false for
//            a keyboard's only (it is not there on a pad); group = 'fly' puts it in the camera's small group
//   wide     the actions in two columns on a wider card, for a mode with many (the Camera Creator)
//
// BUILT ONCE, CHANGED IN PLACE: a mode sends a patch whenever its readings move (the door editor, as
// the camera flies), and a card rebuilt each time would replay its entrance and drop its fades.
// ============================================

let house = null;   // the house card's parts while it is up (buildHouse)

const GLYPHS = () => (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};

/** A keyboard key as caps: 'Shift + Scroll' is two caps joined by +, 'Space / Ctrl' two joined by /. */
function keyCaps(key, forPad) {
    const box = el('span', 'eh-keys ' + (forPad ? 'eh-k-pad' : 'eh-k-kbm'));
    String(key).split(/\s+([+/])\s+/).forEach((part) => {
        if (part === '+' || part === '/') box.appendChild(el('span', 'eh-join', part));
        else if (part !== '') box.appendChild(el('span', 'eh-key', part));
    });
    return box;
}

/** A pad's buttons as their pictures (a name, or a list of them). */
function padCaps(pad) {
    const box = el('span', 'eh-keys eh-k-pad');
    (Array.isArray(pad) ? pad : [pad]).forEach((name, i) => {
        if (i > 0) box.appendChild(el('span', 'eh-join', '/'));
        const img = padGlyph(String(name), 'eh-pad');
        if (img) box.appendChild(img);
    });
    return box;
}

/** One control: its keycaps (keyboard) and its buttons (pad) — one of the two shows — then what it does. A
 *  hint with no `pad` shows its keycaps on a pad as well; `pad = false` is a keyboard's alone, gone on a pad. */
function actEl(hint) {
    const row = el('div', 'eh-act' + (hint.off ? ' off' : '') + (hint.pad === false ? ' eh-kbm-only' : ''));
    const hasKey = hint.key !== undefined && hint.key !== null;
    if (hasKey) row.appendChild(keyCaps(hint.key, false));
    if (hint.pad !== undefined && hint.pad !== null && hint.pad !== false) row.appendChild(padCaps(hint.pad));
    else if (hasKey && hint.pad !== false) row.appendChild(keyCaps(hint.key, true));
    row.appendChild(el('span', 'eh-act-text', hint.text));
    return row;
}

/** What a list of hints is built of: while this is unchanged, only the words and the dimming change in place. */
const shapeOf = (hints) => hints.map((h) => [h.key, JSON.stringify(h.pad === undefined ? null : h.pad),
    h.group || ''].join('|')).join('\n');

function buildHouse() {
    body.innerHTML = '';
    const card = el('div', 'eh-house');
    const head = el('div', 'eh-head');
    const disc = el('div', 'eh-disc');
    const text = el('div', 'eh-head-text');
    const title = el('div', 'eh-title');
    const now = el('div', 'eh-now');
    text.append(title, now);
    head.append(disc, text);
    const bar = el('div', 'eh-progress');
    const barFill = el('div', 'eh-progress-fill');
    bar.appendChild(barFill);
    const readings = el('div', 'eh-readings');
    const actions = el('div', 'eh-actions');
    const fly = el('div', 'eh-fly');
    const flyList = el('div', 'eh-fly-list');
    fly.append(el('div', 'eh-fly-label', 'Camera'), flyList);
    card.append(head, bar, readings, actions, fly);
    body.appendChild(card);
    house = { card, disc, title, now, bar, barFill, readings, actions, fly, flyList, says: null, icon: null,
              shapeA: null, shapeF: null, saysTimer: null, saysGone: null };
}

/** A list of hints: rebuilt when what it is made of changes, else its words and dimming set in place (so an
 *  action coming and going fades rather than blinking). */
function fillList(h, key, shapeKey, hints) {
    const box = h[key];
    const shape = shapeOf(hints);
    if (shape !== h[shapeKey]) {
        h[shapeKey] = shape;
        box.innerHTML = '';
        hints.forEach((x) => box.appendChild(actEl(x)));
        return;
    }
    hints.forEach((x, i) => {
        const row = box.children[i];
        if (!row) return;
        row.classList.toggle('off', !!x.off);
        const words = row.querySelector('.eh-act-text');
        if (words && words.textContent !== String(x.text)) words.textContent = String(x.text);
    });
}

function renderHouse() {
    if (!house) buildHouse();
    const h = house;

    if (h.icon !== (state.icon || '')) {
        h.icon = state.icon || '';
        h.disc.innerHTML = GLYPHS()[h.icon] || '';
    }
    h.card.classList.toggle('eh-wide', !!state.wide);
    h.title.textContent = state.title || 'Editor';

    h.now.innerHTML = '';
    if (state.sub) h.now.appendChild(el('span', 'eh-now-text', state.sub));
    if (state.chip && state.chip.text) {
        h.now.appendChild(el('span', 'eh-chip' + (state.chip.tone ? ' ' + state.chip.tone : ''), state.chip.text));
    }

    const p = state.progress;
    const total = p ? Number(p.total) : 0;
    if (total > 0) {
        const done = Math.max(0, Math.min(Number(p.done) || 0, total));
        h.barFill.style.width = (100 * done / total).toFixed(1) + '%';
    }
    h.bar.style.display = total > 0 ? '' : 'none';

    const rows = Array.isArray(state.rows) ? state.rows : [];
    h.readings.innerHTML = '';
    for (const row of rows) {
        const [label, value] = pair(row, 'label', 'value');
        h.readings.appendChild(el('span', 'eh-r-label', label));
        const tone = !Array.isArray(row) && row.tone ? ' ' + row.tone : '';
        const wrap = !Array.isArray(row) && row.wrap ? ' wrap' : '';
        h.readings.appendChild(el('span', 'eh-r-value' + tone + wrap, value === undefined || value === null ? '—' : value));
    }
    h.readings.style.display = rows.length ? '' : 'none';

    const hints = (Array.isArray(state.hints) ? state.hints : []).filter((x) => x && !Array.isArray(x));
    const acts = hints.filter((x) => x.group !== 'fly');
    const flys = hints.filter((x) => x.group === 'fly');
    fillList(h, 'actions', 'shapeA', acts);
    fillList(h, 'flyList', 'shapeF', flys);
    h.actions.style.display = acts.length ? '' : 'none';
    h.fly.style.display = flys.length ? '' : 'none';
}

/** The house card's status strip, inside the card: its kind's colour and drawn mark, for three seconds. */
const SAYS_MARK = { ok: 'success', err: 'fail', warn: 'warning', info: 'info' };

function houseSays(text, kind) {
    const h = house;
    if (!h) return;
    if (h.saysTimer) clearTimeout(h.saysTimer);
    if (h.saysGone) clearTimeout(h.saysGone);
    if (h.says) h.says.remove();
    h.says = null;
    if (!text) return;
    const k = (kind === 'err' || kind === 'warn' || kind === 'info') ? kind : 'ok';
    const says = el('div', 'eh-says ' + k);
    says.innerHTML = GLYPHS()[SAYS_MARK[k]] || '';
    says.appendChild(el('span', '', text));
    h.card.appendChild(says);
    h.says = says;
    h.saysTimer = setTimeout(() => {
        says.classList.add('gone');
        h.saysGone = setTimeout(() => { if (h.says === says) { says.remove(); h.says = null; } }, 420);
    }, 3000);
}

function render() {
    if (!ensureRoot()) return;
    if (state.house) { renderHouse(); return; }
    house = null;
    body.innerHTML = '';
    const panel = el('div', 'de-panel eh-panel');

    panel.appendChild(el('div', 'de-title', state.title || 'Editor'));
    if (state.sub) panel.appendChild(el('div', 'eh-sub', state.sub));

    const p = state.progress;
    if (p && Number(p.total) > 0) {
        const done = Math.max(0, Math.min(Number(p.done) || 0, Number(p.total)));
        const bar = el('div', 'eh-progress');
        const fill = el('div', 'eh-progress-fill');
        fill.style.width = (100 * done / Number(p.total)).toFixed(1) + '%';
        bar.appendChild(fill);
        panel.appendChild(bar);
    }

    const rows = Array.isArray(state.rows) ? state.rows : [];
    if (rows.length) {
        const info = el('div', 'de-info');
        for (const row of rows) {
            const [label, value] = pair(row, 'label', 'value');
            const line = el('div', 'de-row');
            line.appendChild(el('span', 'de-label', label));
            const tone = !Array.isArray(row) && row.tone ? ' eh-val-' + row.tone : '';
            line.appendChild(el('span', 'de-value' + tone, value === undefined || value === null ? '—' : value));
            info.appendChild(line);
        }
        panel.appendChild(info);
    }

    const hints = Array.isArray(state.hints) ? state.hints : [];
    if (hints.length) {
        const box = el('div', 'de-hints');
        for (const hint of hints) {
            const [key, text] = pair(hint, 'key', 'text');
            // A hint whose key does nothing right now stays in place, dimmed, so the list does
            // not jump about as a mode's options come and go.
            const off = !Array.isArray(hint) && hint.off;
            box.appendChild(el('span', off ? 'eh-hint-off' : '', '[' + key + '] ' + text));
        }
        panel.appendChild(box);
    }

    body.appendChild(panel);
}

function show(next) {
    const root = ensureRoot();
    if (!root) return;
    state = next || {};
    house = null;   // a fresh show builds the card afresh, so it rises in
    render();
    root.style.display = 'block';
}

function update(patch) {
    if (!patch) return;
    Object.assign(state, patch);
    render();
}

function hide() {
    const root = document.getElementById('editor-hud');
    if (root) root.style.display = 'none';
    if (statusEl) statusEl.style.display = 'none';
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (house) {
        if (house.saysTimer) clearTimeout(house.saysTimer);
        if (house.saysGone) clearTimeout(house.saysGone);
        house = null;
    }
    state = {};
}

function status(text, kind) {
    if (!ensureRoot()) return;
    // The house card says it inside itself (houseSays); the old box under itself.
    if (state.house) { houseSays(text, kind); return; }
    statusEl.textContent = text || '';
    statusEl.className = 'de-status eh-status' + (kind ? ' eh-status-' + kind : '');
    statusEl.style.display = text ? 'block' : 'none';
    if (statusTimer) clearTimeout(statusTimer);
    statusTimer = setTimeout(() => { statusEl.style.display = 'none'; }, 3000);
}

// ROUTER REGISTRATION — see router.js's header. No key scope: the editor's game-side key thread
// owns the keyboard while the HUD shows, exactly as with the zone and door editors.
NuiRouter.register('ehShow', (d) => show(d.state));
NuiRouter.register('ehUpdate', (d) => update(d.patch));
NuiRouter.register('ehStatus', (d) => status(d.text, d.kind));
NuiRouter.register('ehHide', () => hide());
