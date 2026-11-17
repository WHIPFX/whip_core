// ========================================
// THE OBJECT VIEWER'S OPTIONS — the column down the right (tools/ov_panel.lua) and Move's bar (tools/ov_move.lua)
//
// The Director's card list, on the right: the search, a chip for each group, the groups' coloured headings, an
// option a line, and the strip under the list saying what the one pointed at does (and, after a press, how it
// went). Built from the Director's own classes (css/director.css: .dr-pal-*, .dr-cat, .dr-chip, .dr-btn ...), which
// read the --dr-* sizes .ov-col sets, so the two cannot drift apart; css/ov-panel.css has only what is new here.
//
// An option is pressed, flipped (a switch on its line), or opens its page (›): a stat, an owner, a model, a walk,
// a kick or a ban, a delete to confirm. Back (or Esc, or B) returns to the list; Esc on the list closes it.
//
// MOVE borrows the furnisher's markers (furnisher-gizmo.js, FurnishGizmo.route): #furnisher shows the SVG alone
// (.fz-solo) and the drags go to tools/ov_move.lua. Its bar here: what is being moved, Move | Rotate (R), Done (Esc).
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback, escapeHtml as e, pedImageUrl, vehicleImageUrl, propImageUrl, fitPicture } from './utils.js';
import { createPadCursor } from './pad-cursor.js';
import { PED_CATEGORIES, PEDS } from './builder-peds.js';
import { FurnishGizmo } from './furnisher-gizmo.js';

const ICON = {
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/></svg>',
    back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg>',
    close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>',
    open: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>',
};
const KIND_GLYPH = { object: 'object', npc: 'ped', player: 'ped', vehicle: 'car' };
const BAN_FOR = [
    { label: '1 hour', s: 3600 }, { label: '1 day', s: 86400 }, { label: '3 days', s: 259200 },
    { label: '1 week', s: 604800 }, { label: '30 days', s: 2592000 }, { label: 'Permanent', s: 0 },
];

const root = document.createElement('div');
root.id = 'ov-panel';
document.body.appendChild(root);
const col = document.createElement('div');
col.className = 'ov-col';
root.appendChild(col);
const bar = document.createElement('div');
bar.className = 'ov-move';
root.appendChild(bar);

let st = null;        // the open list: { head, groups, options, data, note, query, page, pick }
let busy = false;     // a press waiting for its answer
let move = null;      // Move on: { name, mode, pad }

function glyph(name) {
    const g = window.WhipGlyphs && window.WhipGlyphs.glyphs;
    return (g && g[name]) || '';
}

/** The head's art: the thing's picture when a media pack has one (fitted as the Director fits it, an NPC's head), else
 *  the kind's glyph in its ring. A picture that will not load shows the glyph (the error listener below). */
function headArt(h) {
    const g = `<span class="ov-art-glyph">${glyph(KIND_GLYPH[h.kind] || 'object')}</span>`;
    const p = h.pic;
    if (!p || !p.model) return `<div class="ov-disc k-${e(h.kind)}">${glyph(KIND_GLYPH[h.kind] || 'object')}</div>`;
    const url = p.dir === 'vehicles' ? vehicleImageUrl(p.model) : p.dir === 'peds' ? pedImageUrl(p.model) : propImageUrl(p.model);
    const fit = p.dir === 'vehicles' ? 'vehicle' : p.dir === 'peds' ? 'npc' : 'prop';
    return `<div class="ov-art k-${e(h.kind)}"><img src="${e(url)}" alt="" data-fit="${fit}" data-model="${e(p.model)}"${fit === 'npc' ? ' data-fit-head' : ''}>${g}</div>`;
}

// ---- the list ----

function matches(o) {
    const q = (st.query || '').trim().toLowerCase();
    return !q || o.label.toLowerCase().includes(q) || (o.hint || '').toLowerCase().includes(q);
}

function row(o) {
    // `locked`: a full admin's only (it lasts past a restart): greyed, and said so (tools/ov_panel.lua ADMIN_ONLY).
    const end = o.locked ? '<span class="ov-lock">Admins only</span>'
        : o.how === 'toggle' ? `<span class="dr-switch${o.on ? ' on' : ''}"></span>`
        : o.how === 'page' ? `<span class="ov-chev">${ICON.open}</span>` : '';
    return `<button class="dr-pal-row line ov-row${o.danger ? ' danger' : ''}${o.locked ? ' locked' : ''}" data-key="${e(o.key)}" type="button"`
        + `${o.locked ? ' aria-disabled="true"' : ''}><b>${e(o.label)}</b>${end}</button>`;
}

function listHtml() {
    const shown = st.options.filter(matches);
    const groups = st.groups.filter((g) => shown.some((o) => o.group === g.key));
    const chips = groups.map((g) => `<button class="dr-chip kind-c-${e(g.tint)}" data-act="jump" data-group="${e(g.key)}" type="button">`
        + `${e(g.title)} <em>${shown.filter((o) => o.group === g.key).length}</em></button>`).join('');
    const rows = groups.map((g) => `<div class="dr-cat line kind-c-${e(g.tint)}" data-group="${e(g.key)}">${e(g.title)}</div>`
        + shown.filter((o) => o.group === g.key).map(row).join('')).join('');
    return '<div class="dr-pal-top">'
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-search" type="text" placeholder="Search ${st.options.length} options" value="${e(st.query || '')}" spellcheck="false" aria-label="Search options"></div>`
        + `<div class="dr-chips">${chips}</div></div>`
        + `<div class="dr-pal-list">${rows || '<div class="dr-none">No option matches</div>'}</div>`;
}

// ---- the pages ----

function num(v) {
    if (typeof v !== 'number') return '';
    return Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100);
}

function statsHtml(list, key) {
    if (!list || !list.length) return '<div class="dr-none">No stats</div>';
    return list.map((s) => `<div class="ov-stat"><div class="ov-stat-name"><b>${e(s.name)}</b><small>${e(num(s.min))} to ${e(num(s.max))}</small></div>`
        + `<input class="dr-field ov-num" type="number" step="any" value="${e(num(s.value))}" data-stat="${e(s.name)}" aria-label="${e(s.name)}">`
        + `<button class="dr-btn" data-act="stat" data-key="${e(key)}" data-stat="${e(s.name)}" type="button">Set</button></div>`).join('');
}

/** `onSid`, `onSays`: the one picked now, and what its line adds (a Dungeon car's key holder: "has its key"). */
function peopleHtml(list, act, extra, onSid, onSays) {
    if (!list || !list.length) return '<div class="dr-none">Nobody</div>';
    return list.map((p) => {
        const on = onSid && p.sid === onSid;
        return `<button class="ov-person${on ? ' on' : ''}" data-act="${act}" ${extra(p)} type="button">`
            + `<b>${e(p.name || '?')}</b><small>${p.me ? 'You' : p.sid ? 'Player ' + e(p.sid) : p.online ? 'Online' : 'Character #' + e(p.charId)}`
            + `${on && onSays ? ' · ' + e(onSays) : ''}</small></button>`;
    }).join('');
}

function modelHtml() {
    const q = (st.pick.query || '').trim().toLowerCase();
    const cat = st.pick.cat || PED_CATEGORIES[0].key;
    const list = q ? PEDS.filter((p) => (p.model + ' ' + p.name).toLowerCase().includes(q)) : PEDS.filter((p) => p.category === cat);
    const chips = PED_CATEGORIES.map((c) => `<button class="dr-chip plain${!q && c.key === cat ? ' on' : ''}" data-act="cat" data-cat="${e(c.key)}" type="button">${e(c.label)}</button>`).join('');
    const tiles = list.slice(0, 240).map((p) => `<button class="ov-tile${st.data.model === p.model ? ' on' : ''}" data-act="model" data-model="${e(p.model)}" title="${e(p.model)}" type="button">`
        + `<img src="${e(pedImageUrl(p.model))}" alt="" loading="lazy"><span>${e(p.name)}</span></button>`).join('');
    return (st.data.model ? `<button class="dr-btn ov-wide" data-act="ownLook" type="button">Back to their own look</button>` : '')
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-pick-search" type="text" placeholder="Search ${PEDS.length} peds" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Search peds"></div>`
        + `<div class="dr-chips">${chips}</div><div class="ov-tiles">${tiles || '<div class="dr-none">Nobody matches that</div>'}</div>`;
}

/** Give a weapon: None, then every weapon by its group, the one picked lit. */
function weaponHtml(list) {
    const q = (st.pick.query || '').trim().toLowerCase();
    const shown = (list || []).filter((w) => !q || (w.name + ' ' + (w.label || '')).toLowerCase().includes(q));
    const groups = [...new Set(shown.map((w) => w.group || 'other'))];
    return `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-pick-search" type="text" placeholder="Search ${(list || []).length} weapons" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Search weapons"></div>`
        + `<button class="ov-person" data-act="weapon" data-weapon="" type="button"><b>No weapon</b><small>Bare hands</small></button>`
        + groups.map((g) => `<div class="dr-cat line kind-c-slate">${e(g)}</div>`
            + shown.filter((w) => (w.group || 'other') === g).map((w) => `<button class="ov-person" data-act="weapon" data-weapon="${e(w.name)}" type="button">`
                + `<b>${e(w.label || w.name)}</b><small>${e(w.name)}</small></button>`).join('')).join('');
}

/** Spawn a car for them: search, then the cars as tiles with their pictures. */
function carHtml(list) {
    const q = (st.pick.query || '').trim().toLowerCase();
    const all = list || [];
    const shown = q ? all.filter((v) => (v.model + ' ' + (v.name || '')).toLowerCase().includes(q)) : all;
    const tiles = shown.slice(0, 240).map((v) => `<button class="ov-tile" data-act="car" data-model="${e(v.model)}" title="${e(v.model)}" type="button">`
        + `<img src="${e(vehicleImageUrl(v.model))}" alt="" loading="lazy"><span>${e(v.name || v.model)}</span></button>`).join('');
    return `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-pick-search" type="text" placeholder="Search ${all.length} cars" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Search cars"></div>`
        + `<div class="ov-tiles">${tiles || '<div class="dr-none">No car matches that</div>'}</div>`;
}

// Change model, Swap for a Dungeon prop: GTA's props whip has pictures of (js/picture-bounds.js), found by name, and
// any prop this game has by the name as typed (tools/ov_panel.lua checks it is one).
let propNames = null;
function loadPropNames() {
    if (propNames) return;
    propNames = [];
    import('./picture-bounds.js').then((m) => {
        propNames = Object.keys((m.BOUNDS && m.BOUNDS.p) || {}).sort();
        if (st && st.page && st.page.page === 'propmodel') redrawKeeping(col.querySelector('.ov-pick-search'), '.ov-pick-search');
    }, () => {});
}

const PROP_TILES = 120;

function propModelHtml() {
    const q = (st.pick.query || '').trim().toLowerCase();
    const list = q.length >= 2 ? propNames.filter((n) => n.includes(q)) : [];
    const tiles = list.slice(0, PROP_TILES).map((n) => `<button class="ov-tile ov-tile-prop" data-act="propModel" data-model="${e(n)}" title="${e(n)}" type="button">`
        + `<img src="${e(propImageUrl(n))}" alt="" loading="lazy"><span>${e(n)}</span></button>`).join('');
    const typed = /^[a-z0-9_]{3,64}$/.test(q) && !list.includes(q)
        ? `<button class="ov-person" data-act="propModel" data-model="${e(q)}" type="button"><b>Use ${e(q)}</b><small>Any prop this game has, by its name</small></button>`
        : '';
    return `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-pick-search" type="text" placeholder="Search ${propNames.length ? propNames.length + ' ' : ''}props by name" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Search props"></div>`
        + typed
        + (q.length < 2
            ? '<div class="dr-none">Type part of a prop\'s name: barrier, crate, cone</div>'
            : `<div class="ov-tiles">${tiles || '<div class="dr-none">No pictured prop matches: use the name as typed</div>'}</div>`
                + (list.length > PROP_TILES ? `<p class="dr-hint">${list.length - PROP_TILES} more: type more of the name</p>` : ''));
}

/** A ground item's Change item: how many, then whip's items by name (the one it is now lit). */
function itemHtml(d) {
    const q = (st.pick.query || '').trim().toLowerCase();
    const all = d.items || [];
    const shown = q ? all.filter((i) => (i.key + ' ' + i.name).toLowerCase().includes(q)) : all;
    const now = d.pile && d.pile.item;
    const amount = st.pick.amount || (d.pile && d.pile.amount) || 1;
    return `<div class="dr-row"><div class="dr-label">How many</div><input class="dr-field ov-num ov-amount" type="number" min="1" step="1" value="${e(amount)}" aria-label="How many"></div>`
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-pick-search" type="text" placeholder="Search ${all.length} items" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Search items"></div>`
        + (shown.slice(0, 120).map((i) => `<button class="ov-person${i.key === now ? ' on' : ''}" data-act="pileItem" data-item="${e(i.key)}" type="button">`
            + `<b>${e(i.name)}</b><small>${e(i.key)}${i.stack ? '' : ' · one only'}${i.key === now ? ' · it is this now' : ''}</small></button>`).join('')
            || '<div class="dr-none">No item matches that</div>')
        + (shown.length > 120 ? `<p class="dr-hint">${shown.length - 120} more: type more of the name</p>` : '');
}

/** A ground item's Set how many. */
function amountHtml(d) {
    const p = d.pile || {};
    return `<p class="dr-hint">${e(p.label || p.item || 'It')} stacks to ${e(p.max || 1)}.</p>`
        + `<div class="dr-row"><div class="dr-label">How many</div><input class="dr-field ov-num ov-amount" type="number" min="1" max="${e(p.max || 1)}" step="1" value="${e(st.pick.amount || p.amount || 1)}" aria-label="How many"></div>`
        + '<div class="ov-btns"><button class="dr-btn primary" data-act="pileAmount" type="button">Set</button></div>';
}

const HUNT_N = [1, 2, 3, 4, 6];
const HUNT_GUN = [{ key: 'pistol', label: 'Pistols' }, { key: 'smg', label: 'SMGs' }, { key: 'shotgun', label: 'Shotguns' },
                  { key: 'rifle', label: 'Rifles' }, { key: 'none', label: 'Fists' }];

/** Send NPCs after them: how many, with what, and Send. */
function huntHtml(d) {
    const n = st.pick.n || 2, gun = st.pick.gun || 'pistol';
    return `<p class="dr-hint">They come for ${e(d.name || 'them')} from 25 to 40 metres away. They are yours: Remove takes them away, Calm down stops one.</p>`
        + `<div class="dr-row"><div class="dr-label">How many</div><div class="dr-chips">${HUNT_N.map((k) => `<button class="dr-chip plain${k === n ? ' on' : ''}" data-act="huntN" data-n="${k}" type="button">${k}</button>`).join('')}</div></div>`
        + `<div class="dr-row"><div class="dr-label">With</div><div class="dr-chips">${HUNT_GUN.map((g) => `<button class="dr-chip plain${g.key === gun ? ' on' : ''}" data-act="huntGun" data-gun="${g.key}" type="button">${e(g.label)}</button>`).join('')}</div></div>`
        + `<div class="ov-btns"><button class="dr-btn danger" data-act="hunt" type="button">Send ${n === 1 ? 'one' : n} after ${e(d.name || 'them')}</button></div>`;
}

/** A yes or no on a page: the Director's switch row (director.css .dr-sw), the whole row pressed to flip it. */
function switchRow(act, label, on, hint) {
    return `<button class="dr-sw" role="switch" aria-checked="${on}" data-act="${act}" type="button">`
        + `<span class="dr-sw-name">${e(label)}${hint ? `<small>${e(hint)}</small>` : ''}</span>`
        + `<span class="dr-switch${on ? ' on' : ''}"></span></button>`;
}

// A Dungeon car's Key settings (the Director's, for a car made in Dungeon Mode: server/director/live.lua setKey).
const KEY_WHERE = [
    { key: 'none', label: 'No key' }, { key: 'player', label: 'A player' }, { key: 'ignition', label: 'Ignition' },
    { key: 'glovebox', label: 'Glovebox' }, { key: 'trunk', label: 'Boot' }, { key: 'ground', label: 'On the ground' },
];
const KEY_SAYS = {
    none: 'No key exists. Starting it takes hotwiring, unless only its key opens it.',
    player: 'Its key goes in their pocket.',
    ignition: 'Its key is in the ignition: whoever takes the driver\'s seat can start it.',
    glovebox: 'Its key is in its glovebox.',
    trunk: 'Its key is in its boot.',
    ground: 'Its key lies on the ground beside it, for anyone to pick up.',
};

function carKeyHtml(d) {
    const k = st.pick;
    const chips = KEY_WHERE.map((w) => `<button class="dr-chip plain${w.key === k.where ? ' on' : ''}" data-act="keyWhere" data-where="${w.key}" type="button">${e(w.label)}</button>`).join('');
    let html = `<div class="dr-row"><div class="dr-label">Where its key is</div><div class="dr-chips">${chips}</div></div>`
        + `<p class="dr-hint">${e(KEY_SAYS[k.where] || '')}</p>`;
    if (k.where === 'player') html += '<div class="dr-cat line kind-c-slate">Who has it</div>' + peopleHtml(d.players, 'keyWho', (p) => `data-sid="${e(p.sid)}"`, k.sid, 'gets its key');
    return html
        + '<div class="ov-sws">'
        + switchRow('keyLocked', 'Locked', k.locked === true, 'Until someone with its key opens it. Getting out of it unlocks it.')
        + switchRow('keySecure', 'Only its key opens it', k.secure === true, 'No lockpicking, no hotwiring. A key cut before this stops fitting: a new one is cut.')
        + '</div>'
        + '<div class="ov-btns"><button class="dr-btn primary" data-act="keySave" type="button">Save</button></div>';
}

function pageHtml() {
    const o = st.page;
    const d = st.data || {};
    let body = '';
    switch (o.page) {
        case 'carkey':
            body = carKeyHtml(d);
            break;
        case 'propmodel':
            body = `<p class="dr-hint">${e(o.hint)}</p>${propModelHtml()}`;
            break;
        case 'item':
            body = itemHtml(d);
            break;
        case 'amount':
            body = amountHtml(d);
            break;
        case 'pick':
            body = `<p class="dr-hint">${e(o.hint)}</p>${peopleHtml(d.players, 'pick', (p) => `data-sid="${e(p.sid)}"`)}`;
            break;
        case 'weapon':
            body = weaponHtml(d.weapons);
            break;
        case 'car':
            body = carHtml(d.vehicles);
            break;
        case 'hunt':
            body = huntHtml(d);
            break;
        case 'confirm':
            body = `<p class="dr-hint">${e(o.hint)}</p><div class="ov-btns"><button class="dr-btn danger" data-act="do" data-key="${e(o.key)}" type="button">${e(o.label)}</button>`
                + '<button class="dr-btn ghost" data-act="back" type="button">Cancel</button></div>';
            break;
        case 'vstats': case 'pstats':
            body = statsHtml(d.stats, o.key);
            break;
        case 'owner':
            body = `<div class="dr-search-box">${ICON.search}<input class="dr-field ov-owner-search" type="text" placeholder="Find a character by name" value="${e(st.pick.query || '')}" spellcheck="false" aria-label="Find a character"></div>`
                + (st.pick.found ? `<div class="dr-cat line kind-c-slate">Found</div>${peopleHtml(st.pick.found, 'owner', (p) => `data-char="${e(p.charId)}"`)}` : '')
                + `<div class="dr-cat line kind-c-slate">Online</div>${peopleHtml(d.players, 'owner', (p) => `data-char="${e(p.charId)}"`)}`;
            break;
        case 'own':
            body = `<p class="dr-hint">Who it is for: it goes in their list of cars, here where it stands.</p>${peopleHtml(d.players, 'own', (p) => `data-sid="${e(p.sid)}"`)}`;
            break;
        case 'model':
            body = modelHtml();
            break;
        case 'walk':
            body = `<button class="ov-person" data-act="walk" data-walk="" type="button"><b>Normal</b><small>The game's own walk</small></button>`
                + (d.walks || []).map((w) => `<button class="ov-person" data-act="walk" data-walk="${e(w.cmd)}" type="button"><b>${e(w.label || w.cmd)}</b><small>/walk ${e(w.cmd)}</small></button>`).join('');
            break;
        case 'kick':
            body = `<div class="dr-row"><div class="dr-label">Reason</div><textarea class="dr-field ov-reason" rows="3" maxlength="200" placeholder="Kicked by admin"></textarea></div>`
                + `<div class="ov-btns"><button class="dr-btn danger" data-act="do" data-key="kick" type="button">Kick ${e(d.name || '')}</button></div>`;
            break;
        case 'ban': {
            const at = st.pick.banFor === undefined ? 1 : st.pick.banFor;
            body = `<div class="dr-row"><div class="dr-label">Reason</div><textarea class="dr-field ov-reason" rows="3" maxlength="500" placeholder="Kept with the ban">${e(st.pick.reason || '')}</textarea></div>`
                + `<div class="dr-row"><div class="dr-label">For</div><div class="dr-chips">${BAN_FOR.map((b, i) => `<button class="dr-chip plain${i === at ? ' on' : ''}" data-act="banFor" data-i="${i}" type="button">${e(b.label)}</button>`).join('')}</div></div>`
                + `<div class="ov-btns"><button class="dr-btn danger" data-act="do" data-key="ban" type="button">Ban ${e(d.name || '')}</button></div>`;
            break;
        }
    }
    return `<button class="dr-back" data-act="back" type="button">${ICON.back}Options</button>`
        + `<div class="dr-title2 ov-page-title">${e(o.label)}</div><div class="ov-page-body">${body}</div>`;
}

// ---- drawing ----

function draw() {
    if (!st) { root.classList.remove('open'); col.innerHTML = ''; return; }
    root.classList.add('open');
    const h = st.head || {};
    const listScroll = col.querySelector('.dr-pal-list');
    const keep = listScroll && !st.page ? listScroll.scrollTop : 0;
    col.innerHTML = `<div class="dr-head">${headArt(h)}`
        + `<div class="dr-head-main"><div class="dr-title">${e(h.name || '')}</div><div class="dr-sub">${e(h.sub || '')}</div></div>`
        + `<button class="dr-icon" data-act="close" aria-label="Close" type="button">${ICON.close}</button></div>`
        + `<div class="dr-body${st.page ? '' : ' split'}">${st.page ? pageHtml() : listHtml()}</div>`
        + '<div class="dr-pal-strip ov-strip"><b></b><p></p></div>';
    const list = col.querySelector('.dr-pal-list');
    if (list && keep) list.scrollTop = keep;
    const art = col.querySelector('.ov-art img');
    if (art) fitPicture(art);
    say(st.said || (st.note ? { title: 'Only some options', text: st.note, tone: 'warn' } : null));
}

/** The strip: what the one pointed at does, or how a press went. */
function say(s) {
    const strip = col.querySelector('.ov-strip');
    if (!strip) return;
    strip.className = 'dr-pal-strip ov-strip' + (s && s.tone ? ' ' + s.tone : '');
    strip.querySelector('b').textContent = s ? s.title || '' : '';
    strip.querySelector('p').textContent = s ? s.text || '' : '';
}

function optionOf(key) { return st && st.options.find((o) => o.key === key); }

/** Ask Lua to do it; the strip says how it went. */
function act(key, arg) {
    if (busy || !st) return;
    const o = optionOf(key);
    busy = true;
    nuiCallback('ovPanelDo', { key, arg: arg || {} }).then((r) => {
        busy = false;
        if (!st || !r || r.close) return;
        if (o && typeof r.on === 'boolean') o.on = r.on;
        if (r.stats) st.data.stats = r.stats;
        if (r.model !== undefined) st.data.model = r.model || null;
        if (r.carKey) st.data.carKey = r.carKey;
        const ok = r.ok !== false;
        st.said = { title: o ? o.label : '', tone: ok ? 'ok' : 'error',
                    text: r.text || (ok ? (typeof r.on === 'boolean' ? (r.on ? 'On' : 'Off') : 'Done') : 'That did not work') };
        if (ok && st.page && ['confirm', 'own', 'owner', 'walk', 'pick', 'weapon', 'car', 'hunt', 'carkey', 'propmodel', 'item', 'amount'].includes(st.page.page)) st.page = null;
        draw();
    });
}

function openPage(o) {
    st.page = o;
    st.pick = { query: '', cat: undefined };
    if (o.page === 'propmodel') loadPropNames();
    // (Key settings: a draft of what the car has now, saved together.)
    if (o.page === 'carkey') {
        const k = st.data.carKey || {};
        Object.assign(st.pick, { where: k.where || 'none', sid: k.sid || null, locked: k.locked === true, secure: k.secure === true });
    }
    st.said = { title: o.label, text: o.hint };
    draw();
    const body = col.querySelector('.dr-body');
    if (body) body.scrollTop = 0;
}

function back() {
    if (!st) return;
    if (st.page) { st.page = null; st.said = null; draw(); return; }
    nuiCallback('ovPanelClose', {});
}

// ---- the pointer ----

// A ped with no picture: its tile keeps its name, the broken picture hidden (an error does not bubble: caught going down).
col.addEventListener('error', (ev) => {
    if (!ev.target || ev.target.tagName !== 'IMG') return;
    const art = ev.target.closest('.ov-art');
    if (art) art.classList.add('ov-noimg'); else ev.target.style.visibility = 'hidden';
}, true);

col.addEventListener('mouseover', (ev) => {
    if (!st || st.page) return;
    const r = ev.target.closest('.ov-row');
    if (!r) return;
    const o = optionOf(r.dataset.key);
    if (o) { st.said = null; say({ title: o.label, text: o.locked ? `${o.hint} Only an admin can do this: it lasts past a restart.` : o.hint }); }
});

col.addEventListener('click', (ev) => {
    if (!st) return;
    const r = ev.target.closest('.ov-row');
    if (r) {
        const o = optionOf(r.dataset.key);
        if (!o || o.locked) return;
        if (o.how === 'page') openPage(o); else act(o.key);
        return;
    }
    const b = ev.target.closest('[data-act]');
    if (!b) return;
    const d = b.dataset;
    switch (d.act) {
        case 'close': nuiCallback('ovPanelClose', {}); break;
        case 'back': back(); break;
        case 'jump': {
            const head = col.querySelector(`.dr-cat[data-group="${CSS.escape(d.group)}"]`);
            if (head) head.scrollIntoView({ block: 'start' });
            break;
        }
        case 'do': {
            const reason = col.querySelector('.ov-reason');
            if (d.key === 'ban') {
                const f = BAN_FOR[st.pick.banFor === undefined ? 1 : st.pick.banFor];
                act('ban', { reason: reason ? reason.value : '', seconds: f.s, permanent: f.s === 0 });
            } else {
                act(d.key, { reason: reason ? reason.value : '' });
            }
            break;
        }
        case 'banFor': {
            const reason = col.querySelector('.ov-reason');
            st.pick.reason = reason ? reason.value : '';
            st.pick.banFor = Number(d.i);
            draw();
            break;
        }
        case 'stat': {
            const input = col.querySelector(`.ov-num[data-stat="${CSS.escape(d.stat)}"]`);
            const value = input ? Number(input.value) : NaN;
            if (!Number.isFinite(value)) { say({ title: d.stat, text: 'A number', tone: 'error' }); break; }
            act(d.key, { stat: d.stat, value });
            break;
        }
        case 'owner': act('veh.owner', { charId: Number(d.char) }); break;
        case 'own': act('veh.own', { sid: Number(d.sid) }); break;
        case 'walk': act('ply.walk', { walk: d.walk || false }); break;
        case 'model': act('ply.model', { model: d.model }); break;
        case 'ownLook': act('ply.model', { model: false }); break;
        // ---- Dungeon Mode's: a Dungeon NPC's, and what is made for a player ----
        case 'pick': if (st.page) act(st.page.key, { sid: Number(d.sid) }); break;
        case 'weapon': act('live.weapon', { weapon: d.weapon || false }); break;
        case 'car': act('ply.car', { model: d.model }); break;
        case 'huntN': st.pick.n = Number(d.n) || 2; draw(); break;
        case 'huntGun': st.pick.gun = d.gun; draw(); break;
        case 'hunt': act('ply.hunt', { n: st.pick.n || 2, weapon: st.pick.gun || 'pistol' }); break;
        case 'cat': st.pick.cat = d.cat; st.pick.query = ''; draw(); break;
        case 'propModel': if (st.page) act(st.page.key, { model: d.model, label: d.model }); break;
        // ---- a ground item's Change item and Set how many ----
        case 'pileItem': act('pile.item', { item: d.item, amount: Math.max(1, Math.floor(Number(st.pick.amount) || (st.data.pile && st.data.pile.amount) || 1)) }); break;
        case 'pileAmount': act('pile.amount', { amount: Math.max(1, Math.floor(Number(st.pick.amount) || (st.data.pile && st.data.pile.amount) || 1)) }); break;
        // ---- a Dungeon car's Key settings: a draft, then Save ----
        case 'keyWhere': st.pick.where = d.where; draw(); break;
        case 'keyWho': st.pick.sid = Number(d.sid); draw(); break;
        case 'keyLocked': st.pick.locked = !st.pick.locked; draw(); break;
        case 'keySecure': st.pick.secure = !st.pick.secure; draw(); break;
        case 'keySave':
            if (st.pick.where === 'player' && !st.pick.sid) { say({ title: 'Key settings', text: 'Pick who has its key', tone: 'error' }); break; }
            act('live.key', { where: st.pick.where, sid: st.pick.sid, locked: st.pick.locked, secure: st.pick.secure });
            break;
    }
});

let searchTimer = 0;
col.addEventListener('input', (ev) => {
    if (!st) return;
    const t = ev.target;
    if (t.classList.contains('ov-search')) {
        st.query = t.value;
        redrawKeeping(t, '.ov-search');
    } else if (t.classList.contains('ov-amount')) {
        st.pick.amount = Number(t.value);
    } else if (t.classList.contains('ov-pick-search')) {
        st.pick.query = t.value;
        redrawKeeping(t, '.ov-pick-search');
    } else if (t.classList.contains('ov-owner-search')) {
        st.pick.query = t.value;
        clearTimeout(searchTimer);
        const q = t.value.trim();
        searchTimer = setTimeout(() => {
            if (q.length < 2) { st.pick.found = null; redrawKeeping(t, '.ov-owner-search'); return; }
            nuiCallback('ovPanelSearch', { q }).then((r) => {
                if (!st || !st.page || st.page.page !== 'owner' || st.pick.query.trim() !== q) return;
                st.pick.found = (r && r.list) || [];
                redrawKeeping(col.querySelector('.ov-owner-search'), '.ov-owner-search');
            });
        }, 250);
    }
});

/** Draw again with the search box still in hand, the caret where it was. */
function redrawKeeping(input, sel) {
    const at = input ? input.selectionStart : null;
    draw();
    const again = col.querySelector(sel);
    if (again) {
        again.focus();
        if (at !== null) again.setSelectionRange(at, at);
    }
}

// ---- the pad (the Director's cursor) and the keys ----

const padCursor = createPadCursor({
    name: 'ov',
    root: () => col,
    shown: () => !!st,
    targets: 'button, input, textarea, .ov-row',
});

function padHints() {
    return [['ls', 'Move'], ['a', 'Press'], ['rs', 'Scroll'], ['b', st && st.page ? 'Back' : 'Close']];
}

NuiRouter.registerKeyScope({
    name: 'ov-panel',
    priority: 26,
    isOpen: () => !!st,
    onKey: (ev) => {
        if (ev.key === 'Escape') { ev.preventDefault(); back(); }
    },
    onNav: (nav) => {
        if (padCursor.nav(nav)) return;
        if (nav === 'back') { padCursor.letGo(); back(); }
    },
    analog: true,
    onAnalog: (a) => padCursor.analog(a),
    padHints,
});

NuiRouter.register('ovPanelOpen', (d) => {
    st = { head: d.head || {}, groups: d.groups || [], options: d.options || [], data: d.data || {}, note: d.note || null,
           query: '', page: null, pick: {}, said: null };
    busy = false;
    draw();
});

NuiRouter.register('ovPanelClose', () => {
    st = null;
    busy = false;
    padCursor.hide();
    draw();
});

// ---- Move ----

const furnisher = document.getElementById('furnisher');

function drawMove() {
    if (!move) { bar.classList.remove('open'); bar.innerHTML = ''; return; }
    bar.classList.add('open');
    // The keys as the Director shows them: a white keycap, or the pad's own button picture.
    const pad = (n) => `<img class="ov-pad" src="img/pad/${n}.svg" alt="${n.toUpperCase()}">`;
    // The caller's own keys (the hand editor's), else Move's. With its own Done (PlacePoint's Place), Esc and B leave
    // without it, and A on a pad is that button.
    const keys = move.keys
        ? move.keys.map((k) => `<span><kbd>${e(k.key)}</kbd> ${e(k.text)}</span>`).join('')
        : move.pad
        ? `<span>${pad('ls')} move</span><span>${pad('lt')}${pad('rt')} down / up</span><span>${pad('dpad')} turn</span>`
            + `<span>${pad('rs')} look</span>`
            + (move.doneText ? `<span>${pad('a')} ${e(move.doneText.toLowerCase())}</span><span>${pad('b')} cancel</span>` : `<span>${pad('b')} done</span>`)
        : '<span>Drag the arrows or the dot</span><span><kbd>R</kbd> ' + (move.mode === 'move' ? 'rotate' : 'move') + '</span>'
            + `<span><kbd>Shift</kbd> snap</span><span><kbd>Right mouse</kbd> look</span><span><kbd>Esc</kbd> ${move.doneText ? 'cancel' : 'done'}</span>`;
    bar.innerHTML = `<div class="ov-move-main"><div class="ov-move-name"><small>${e(move.caption || 'Moving')}</small><b>${e(move.name || '')}</b></div>`
        + (move.pad ? '' : `<div class="dr-chips ov-move-modes"><button class="dr-chip plain${move.mode === 'move' ? ' on' : ''}" data-mode="move" type="button">Move</button>`
            + `<button class="dr-chip plain${move.mode === 'rotate' ? ' on' : ''}" data-mode="rotate" type="button">Rotate</button></div>`)
        + `<button class="dr-btn primary" data-act="done" type="button">${e(move.doneText || 'Done')}</button></div>`
        + `<div class="ov-move-keys">${keys}</div>`;
}

function setMode(m) {
    if (!move) return;
    move.mode = m === 'rotate' ? 'rotate' : 'move';
    FurnishGizmo.setMode(move.mode);
    drawMove();
}

bar.addEventListener('click', (ev) => {
    const b = ev.target.closest('button');
    if (!b || !move) return;
    if (b.dataset.mode) setMode(b.dataset.mode);
    // Done, not Esc: one who started Move may give Done its own meaning (the hand editor saves)
    else if (b.dataset.act === 'done') nuiCallback('ovMoveExit', { done: true });
});

NuiRouter.register('ovMoveStart', (d) => {
    const text = (v) => (typeof v === 'string' && v !== '' ? v : null);
    move = { name: d.name, mode: 'move', pad: false, tilt: d.tilt === true,
             caption: text(d.caption), doneText: text(d.doneText),
             keys: Array.isArray(d.keys) && d.keys.length ? d.keys : null };
    FurnishGizmo.route({ move: 'ovMoveTo', dragTo: 'ovMoveDragTo', end: 'ovMoveEnd', click: 'ovMoveClick' });
    FurnishGizmo.reset();
    if (furnisher) furnisher.classList.add('fz-solo');
    drawMove();
});

NuiRouter.register('ovMoveView', (d) => { if (move) FurnishGizmo.setView(d); });

// The one who started Move changed what it is on (OvMove.update): the bar's name and caption, and whether the
// markers are out (put away while the hand editor's walk plays).
NuiRouter.register('ovMoveBar', (d) => {
    if (!move) return;
    move.name = d.name;
    move.caption = typeof d.caption === 'string' && d.caption !== '' ? d.caption : null;
    if (furnisher) furnisher.classList.toggle('fz-nomarkers', d.markers === false);
    drawMove();
});

NuiRouter.register('ovMoveLook', (d) => {
    if (!move) return;
    FurnishGizmo.setLooking(d.on === true);
    if (furnisher) furnisher.classList.toggle('fz-looking', d.on === true);
});

NuiRouter.register('ovMovePad', (d) => {
    if (!move) return;
    move.pad = d.pad === true;
    drawMove();
});

NuiRouter.register('ovMoveStop', () => {
    move = null;
    FurnishGizmo.reset();
    FurnishGizmo.route(null);
    if (furnisher) furnisher.classList.remove('fz-solo', 'fz-looking', 'fz-nomarkers');
    drawMove();
});

// The keyboard while Move has the screen (the game keeps its keys too: the R it would reload with is held off).
// Not a key scope: there is no list to drive with a pad, and a nav scope would take the pad Move reads itself.
window.addEventListener('keydown', (ev) => {
    if (!move || ev.repeat) return;
    const tag = document.activeElement && document.activeElement.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') return;
    if (ev.key === 'Escape' || ev.key === 'Backspace') { ev.preventDefault(); nuiCallback('ovMoveExit', {}); }
    else if (ev.key === 'r' || ev.key === 'R') setMode(move.mode === 'move' ? 'rotate' : 'move');
});
