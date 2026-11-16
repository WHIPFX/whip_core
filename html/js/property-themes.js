// ========================================
// A HOME'S THEME (the sign's Theme; client/property_themes.lua)
//
// The looks the resource that built this home's interior offers (server/property_themes.lua), as
// cards: a strip of the room in each — walls, trim, floor — its name, and "In use" on the one in
// force, like whip_autos' paints. Using one repaints the
// home around the player; the page stays, so the next can be tried.
//
// Lua → page:  propertyThemesOpen { title, label, current, themes: [{ id, name, walls, trim, floor }] }
//              propertyThemeSet { ok, id }      the server's answer to a Use
//              propertyThemesClose
// Page → Lua:  propertyThemePick { id }   propertyThemesClose
//
// Mouse: a card chooses, double-click (or Use this theme) uses it; the cross or right-click closes.
// Keys: arrows choose, Enter uses, Escape closes. Pad: the D-pad or stick chooses, A uses, B closes.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback, escapeHtml } from './utils.js';
import { ICON_PATH } from './ui-icons.js';

const CROSS = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"'
    + ' aria-hidden="true">' + ICON_PATH.close + '</svg>';
const COLS = 2;
const GREY = '#6b6b6b';

let open = false;
let data = { title: '', label: '', current: 0, themes: [] };
let focus = 0;          // index into data.themes
let busy = null;        // the id a Use is waiting on the server for
let root = null;

function build() {
    if (root) return root;
    root = document.createElement('div');
    root.id = 'property-themes';
    root.innerHTML = '<div class="pt-scale"><div class="pt-panel">'
        + '<div class="pt-head"><div><div class="pt-title" id="pt-title"></div><div class="pt-sub" id="pt-sub"></div></div>'
        + '<button type="button" class="pt-x" data-pt="close" aria-label="Close">' + CROSS + '</button></div>'
        + '<div class="pt-list" id="pt-list"></div>'
        + '<div class="pt-foot">'
        + '<button type="button" class="pt-btn pt-btn-main" data-pt="use" id="pt-use">Use this theme</button>'
        + '<button type="button" class="pt-btn pt-btn-quiet" data-pt="close">Close</button>'
        + '</div></div></div>';
    document.body.appendChild(root);

    root.addEventListener('click', (e) => {
        if (!open) return;
        const btn = e.target.closest('[data-pt]');
        if (btn) {
            btn.blur();
            if (btn.dataset.pt === 'close') requestClose();
            else if (btn.dataset.pt === 'use') use(focus);
            return;
        }
        const card = e.target.closest('.pt-card');
        if (card) { focus = Number(card.dataset.i); markFocus(); }
    });
    root.addEventListener('dblclick', (e) => {
        if (!open) return;
        const card = e.target.closest('.pt-card');
        if (card) use(Number(card.dataset.i));
    });
    root.addEventListener('contextmenu', (e) => {
        if (!open) return;
        e.preventDefault();
        requestClose();
    });
    return root;
}

function colour(v) {
    return typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v) ? v : null;
}

function render() {
    build();
    root.querySelector('#pt-title').textContent = data.title || 'Theme';
    root.querySelector('#pt-sub').textContent = 'Theme  ·  ' + (data.label || 'its interior') + '  ·  '
        + data.themes.length + ' look' + (data.themes.length === 1 ? '' : 's');
    let html = '';
    data.themes.forEach((t, i) => {
        const walls = colour(t.walls) || GREY;
        const trim = colour(t.trim) || walls;
        const floor = colour(t.floor) || walls;
        let tag = '';
        if (busy === t.id) tag = '<span class="pt-tag pt-busy">Applying…</span>';
        else if (t.id === data.current) tag = '<span class="pt-tag">In use</span>';
        html += '<button type="button" class="pt-card' + (i === focus ? ' pt-focus' : '') + '" data-i="' + i + '">'
            + '<span class="pt-room">'
            + '<span class="pt-walls" style="background:' + walls + '"></span>'
            + '<span class="pt-trim" style="background:' + trim + '"></span>'
            + '<span class="pt-floor" style="background:' + floor + '"></span>'
            + '</span>'
            + '<span class="pt-name-row"><span class="pt-name">' + escapeHtml(t.name) + '</span>' + tag + '</span>'
            + '</button>';
    });
    root.querySelector('#pt-list').innerHTML = html;
    updateUse();
}

function updateUse() {
    const t = data.themes[focus];
    const btn = root && root.querySelector('#pt-use');
    if (!btn) return;
    btn.disabled = !t || t.id === data.current || busy !== null;
    btn.textContent = t && t.id === data.current ? 'In use' : 'Use this theme';
}

function markFocus() {
    root.querySelectorAll('.pt-card').forEach((el) => {
        el.classList.toggle('pt-focus', Number(el.dataset.i) === focus);
    });
    const el = root.querySelector('.pt-card.pt-focus');
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
    updateUse();
}

function show(d) {
    data = {
        title: (d && d.title) || '', label: (d && d.label) || '',
        current: Number(d && d.current) || 0,
        themes: Array.isArray(d && d.themes) ? d.themes : [],
    };
    busy = null;
    const at = data.themes.findIndex((t) => t.id === data.current);
    focus = at >= 0 ? at : 0;
    open = true;
    render();
    root.classList.add('pt-open');
}

function hide() {
    if (!open) return;
    open = false;
    busy = null;
    if (root) root.classList.remove('pt-open');
}

/** The page asks; Lua closes (it holds the focus) and tells the page back. hide() is safe twice. */
function requestClose() {
    hide();
    nuiCallback('propertyThemesClose', {});
}

function use(i) {
    const t = data.themes[i];
    if (!t || t.id === data.current || busy !== null) return;
    focus = i;
    busy = t.id;
    render();
    nuiCallback('propertyThemePick', { id: t.id });
}

/** The server said: the theme is in force now, or it was refused (the reason is its own toast). */
function answered(d) {
    if (!open) return;
    if (d && d.ok) data.current = Number(d.id);
    busy = null;
    render();
}

/** Arrows and the pad, across a grid two wide. */
function step(dir) {
    const n = data.themes.length;
    if (n === 0) return;
    let next = focus;
    if (dir === 'left') next = focus % COLS === 0 ? focus : focus - 1;
    else if (dir === 'right') next = (focus % COLS === COLS - 1 || focus + 1 >= n) ? focus : focus + 1;
    else if (dir === 'up') next = focus - COLS >= 0 ? focus - COLS : focus;
    else if (dir === 'down') next = focus + COLS < n ? focus + COLS : focus;
    if (next !== focus) { focus = next; markFocus(); }
}

NuiRouter.register('propertyThemesOpen', (d) => show(d));
NuiRouter.register('propertyThemeSet', (d) => answered(d));
NuiRouter.register('propertyThemesClose', () => hide());

const ARROWS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };

// 113: beside the seat map's 112, among the small player screens (see router.js). Every key while open.
NuiRouter.registerKeyScope({
    name: 'propertyThemes',
    priority: 113,
    isOpen: () => open,
    onKey: (e) => {
        if (e.key === 'Escape') { e.preventDefault(); requestClose(); }
        else if (ARROWS[e.key]) { e.preventDefault(); step(ARROWS[e.key]); }
        else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); use(focus); }
    },
    onNav: (nav) => {
        if (nav === 'back') requestClose();
        else if (nav === 'select') use(focus);
        else if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') step(nav);
    },
    padHints: () => {
        const t = data.themes[focus];
        const hints = [['dpad', 'Choose']];
        if (t && t.id !== data.current && busy === null) hints.push(['a', 'Use this theme']);
        hints.push(['b', 'Close']);
        return hints;
    },
});
