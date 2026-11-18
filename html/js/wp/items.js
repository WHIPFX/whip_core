// ========================================
// /whip SECTION — Items
//
// Every item the server knows on the left, each with its picture. On the right, with nothing picked,
// the items at a glance: how many, from which resources, and which ones an admin has changed. With one
// picked, its page: what it is beside its picture (its weight, whether it stacks), Give, its settings, and
// What players see: its pictures.
//
// ITS SETTINGS are server/item_settings.lua's: every item's name, description and weight (config.lua's
// items keep theirs as Config's own rows, with stacking, how many to a slot, the cooldown and its kind),
// then any its resource declared for it (`settings` in its definition: a magazine's capacity, a gun's
// reload time). Laid out across the page (LAYOUT), drawn, worded and checked the way the Config page does it
// (wp/config.js), held here until Apply, and sent through the same cfgApply. Reset puts the item's own value
// back. How it is picked up and the player's walk are the hand position editor's (tools/hand_edit.lua); whether
// it is used and its prop are config.lua's. Only a permanent admin may change them: the server says so (mayEdit)
// and refuses anyone else regardless.
//
// ITS PICTURES are its `pictures` setting, a row each ({ image, field, op, value }): Default (its own picture)
// first, then each row, the first that fits drawn. An admin changes a row's test, moves it, removes it, or adds
// one with a pasted link (Config.LorePictureLinks' sites); the server checks it all again.
//
// The Lua half is tools/panel_sections/items.lua.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback, itemImageUrl } from '../utils.js';
import { settingValue, describeSetting, checkSetting, sameSetting, unitParts } from './config.js';
import { plural } from './format.js';

let items = {};             // { key: { name, desc, weight, type, stack, maxStack, ..., images, imgRoot, changed, ownSettings } }
let selectedKey = null;
let search = '';
let resFilter = '';
let els = {};
let detail = null;          // the picked item's settings: { key, mayEdit, groups }, or { key, why }, or { key, loading }
let asked = 0;              // the latest ask for them: an older answer is dropped
const pending = new Map();  // 'owner|path' -> { item, value } | { item, reset: true }: edits waiting for Apply
let sending = null;         // what the Apply on its way sent (same keys), or null
let makers = null;          // the game's car makers, asked for once (ibVehicleMakes)
const probed = new Map();   // picture url -> Promise<boolean>: whether it exists

// A picture that is not there (not made yet): a frame with a mountain, in place of a broken image.
const NO_PICTURE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="2"/><path d="M21 17l-5-5-9 8"/></svg>';

// ---- small helpers ----

/** A weight as people write it: to four places at most ("0.2 kg", "0.0001 kg"). */
const kg = (n) => (typeof n === 'number' ? String(Math.round(n * 10000) / 10000) : '0') + ' kg';

const keyOf = (s) => s.owner + '|' + s.path;
const savedOf = (s) => settingValue(s, s.saved);
const defaultOf = (s) => settingValue(s, s.default);

function current(s) {
    const p = pending.get(keyOf(s));
    if (p && p.reset) return defaultOf(s);
    if (p) return p.value;
    return savedOf(s);
}

/** Every setting of the picked item. */
function allSettings() {
    const out = [];
    for (const g of (detail && detail.groups) || []) for (const s of g.settings || []) out.push(s);
    return out;
}

const settingAt = (k) => allSettings().find((s) => keyOf(s) === k) || null;

/** Edits waiting for one item (the list says so). */
const pendingFor = (key) => [...pending.values()].filter((p) => p.item === key).length;

/** The item's icon, with utils.js's missing-image fallback (data-item-img). */
function itemImg(key, size) {
    const img = document.createElement('img');
    img.width = size;
    img.height = size;
    img.alt = '';
    img.dataset.itemImg = '';
    img.dataset.itemKey = key;
    img.src = itemImageUrl(key, items[key] && items[key].img);
    return img;
}

/** A Lua list from the bridge: an empty one can arrive as {} rather than []. */
const listOf = (v) => (Array.isArray(v) ? v : (v && typeof v === 'object' ? Object.values(v) : []));

const nameOf = (key) => (items[key] && items[key].name) || key;

// ---- pictures (server/item_settings.lua: the `pictures` setting, a row per picture) ----

/** A picture row as the page edits it: every field a string. */
const picRow = (r) => ({
    image: String((r && r.image) || ''),
    field: String((r && r.field) || ''),
    op: String((r && r.op) || 'is'),
    value: r && r.value !== undefined && r.value !== null ? String(r.value) : '',
});

// The tests each kind of field takes, as the menu words them.
const PIC_OPS = {
    number: [['atLeast', 'at least'], ['atMost', 'at most'], ['above', 'over'], ['below', 'under'], ['is', 'exactly']],
    text: [['is', 'is'], ['has', 'is set'], ['empty', 'is not set']],
};
const PIC_NUMBER_OPS = new Set(['above', 'below', 'atLeast', 'atMost']);

/** What a picture can be shown by, for the item picked: { key, label, type }, or a stand-in for one not offered. */
function picField(key) {
    if (!key) return null;
    return listOf(detail && detail.pictureFields).find((f) => f.key === key) || { key, label: key, type: 'text' };
}

/** A number as people read it: 1,000. */
const picNum = (v) => (v !== '' && Number.isFinite(Number(v)) ? Number(v).toLocaleString('en-US') : v);

/** Under a picture: when it shows ("Quantity under 100", "Mustard"). */
function picCaption(row) {
    if (!row.field) {
        const parts = [...row.image.matchAll(/\{(\w+)\}/g)].map((m) => m[1]);
        return parts.length ? 'One for each ' + parts.join(' and ') : 'Always';
    }
    const f = picField(row.field);
    const label = f.label;
    switch (row.op) {
        case 'above': return label + ' over ' + picNum(row.value);
        case 'below': return label + ' under ' + picNum(row.value);
        case 'atLeast': return label + ' ' + picNum(row.value) + ' or more';
        case 'atMost': return label + ' ' + picNum(row.value) + ' or less';
        case 'has': return label + ' set';
        case 'empty': return label + ' not set';
        default:
            if (f.type === 'bool') return row.value === 'false' ? label + ': no' : label;
            return label + ' ' + picNum(row.value);
    }
}

/** Where a row's picture is: a pasted link as it is, one of the item's own in its resource; null for one made per
 *  field ({make}), or none yet. */
function picUrl(it, row) {
    if (/^https:\/\//.test(row.image)) return row.image;
    if (!row.image || /\{\w+\}/.test(row.image)) return null;
    return (it.imgRoot || '') + row.image;
}

/** What is wrong with these rows (the server's checkPictures, said first here), or null. */
function picProblem(rows, own) {
    const links = listOf(detail && detail.pictureLinks);
    for (let i = 0; i < rows.length; i++) {
        const r = rows[i];
        const at = 'Picture ' + (i + 1) + ': ';
        if (!own.has(r.image)) {
            if (!r.image) return at + 'paste a picture link';
            if (!links.length) return at + 'pictures are switched off (Config: Picture links accepted)';
            const start = links.find((s) => r.image.startsWith(s));
            if (!start) return at + 'a link starting with ' + links.join(' or ');
            const rest = r.image.slice(start.length);
            if (!rest || !/^[\w\-./]+$/.test(rest) || rest.includes('..')) return at + 'that link is not a picture\'s address';
        }
        if (!r.field) continue;
        const needsNumber = PIC_NUMBER_OPS.has(r.op) || (r.field === 'amount' && r.op === 'is');
        if (needsNumber && (r.value.trim() === '' || !Number.isFinite(Number(r.value)))) return at + 'needs a number';
    }
    return null;
}

/** Does a picture exist? Asked once per url. */
function probe(url) {
    if (!probed.has(url)) {
        probed.set(url, new Promise((resolve) => {
            const img = new Image();
            img.onload = () => resolve(true);
            img.onerror = () => resolve(false);
            img.src = url;
        }));
    }
    return probed.get(url);
}

// ---- the list ----

function filteredKeys() {
    const q = search;
    const out = Object.keys(items).filter((key) => {
        const it = items[key];
        if (resFilter && (it.resource || 'unknown') !== resFilter) return false;
        if (!q) return true;
        return (it.name || '').toLowerCase().includes(q) || key.toLowerCase().includes(q)
            || (it.resource || '').toLowerCase().includes(q);
    });
    out.sort((a, b) => nameOf(a).toLowerCase().localeCompare(nameOf(b).toLowerCase()));
    return out;
}

function renderList() {
    if (!els.list) return;
    els.list.innerHTML = '';
    const keys = filteredKeys();
    for (const key of keys) {
        const it = items[key];
        const unsaved = pendingFor(key);
        const row = WP.listItem({
            title: it.name || key,
            sub: key + ' · ' + (it.resource || 'whip_core'),
            // Amber, waiting to be sent, before blue, changed and saved.
            pill: unsaved ? unsaved + ' unsaved' : (it.changed ? it.changed + ' changed' : null),
            pillClass: unsaved ? 'wp-pill-warn' : 'wp-pill-accent',
            id: key,
            action: 'ibSelect',
        });
        row.classList.add('wp-has-icon');
        row.insertBefore(itemImg(key, 32), row.firstChild);
        if (key === selectedKey) row.classList.add('active');
        els.list.appendChild(row);
    }
    if (keys.length === 0) els.list.appendChild(WP.empty(search || resFilter ? 'No item matches' : 'No items'));
    els.count.textContent = keys.length + ' of ' + Object.keys(items).length;
}

/** The resource filter, from the catalogue; the choice is kept while its resource still has items. */
function renderResourceOptions() {
    if (!els.resFilter) return;
    const resources = [...new Set(Object.values(items).map((it) => it.resource || 'unknown'))].sort();
    els.resFilter.innerHTML = '';
    const all = WP.el('option', null, 'Every resource');
    all.value = '';
    els.resFilter.appendChild(all);
    for (const res of resources) {
        const opt = WP.el('option', null, res);
        opt.value = res;
        els.resFilter.appendChild(opt);
    }
    if (resFilter && !resources.includes(resFilter)) resFilter = '';
    els.resFilter.value = resFilter;
}

// ---- nothing picked: the items at a glance ----

function renderOverview() {
    const body = els.body;
    body.innerHTML = '';
    els.back.style.display = 'none';
    els.title.textContent = 'Items';
    const keys = Object.keys(items);
    const byRes = {};
    for (const key of keys) {
        const r = items[key].resource || 'unknown';
        byRes[r] = (byRes[r] || 0) + 1;
    }
    const changed = keys.filter((k) => items[k].changed > 0).sort((a, b) => nameOf(a).localeCompare(nameOf(b)));
    const own = keys.filter((k) => items[k].ownSettings > 0);
    const pictured = keys.filter((k) => listOf(items[k].images).length > 0);

    const stats = WP.el('div', 'wp-stats');
    stats.appendChild(WP.stat('Items', String(keys.length), 'from ' + plural(Object.keys(byRes).length, 'resource')));
    stats.appendChild(WP.stat('Changed here', String(changed.length), changed.length ? 'saved over their own values' : 'all as their resources made them'));
    stats.appendChild(WP.stat('With settings of their own', String(own.length), own.length ? 'declared by their resource' : 'none declared yet'));
    stats.appendChild(WP.stat('Pictures that change', String(pictured.length), pictured.length ? 'by what the item holds' : ''));
    body.appendChild(stats);

    body.appendChild(WP.el('div', 'wp-hint', 'Pick an item to see what it is and give yourself some. Every item\'s name, '
        + 'description and weight can be changed, and Reset puts its own back. Some items have settings of their own, '
        + 'made by the resource they come from: a magazine\'s size, a gun\'s reload time.'));

    body.appendChild(WP.el('div', 'wp-section-title', 'Changed here'));
    if (!changed.length) {
        body.appendChild(WP.el('div', 'wp-hint', 'Nothing yet: every item is as its resource made it.'));
    }
    for (const key of changed) {
        body.appendChild(WP.statusRow({ label: nameOf(key), status: 'ok',
            detail: plural(items[key].changed, 'setting') + ' changed  ·  ' + key,
            action: 'ibSelect', arg: key, actionLabel: 'Open' }));
    }

    body.appendChild(WP.el('div', 'wp-section-title', 'From each resource'));
    const tallies = WP.el('div', 'wp-tallies');
    const resources = Object.keys(byRes).sort((a, b) => byRes[b] - byRes[a] || a.localeCompare(b));
    const max = resources.reduce((m, r) => Math.max(m, byRes[r]), 0) || 1;
    for (const r of resources) {
        const b = WP.el('button', 'wp-tally');
        b.type = 'button';
        b.dataset.action = 'ibShowResource';
        b.dataset.arg = r;
        b.appendChild(WP.el('span', 'wp-tally-name', r));
        b.appendChild(WP.el('span', 'wp-tally-value', plural(byRes[r], 'item')));
        const bar = WP.el('span', 'wp-tally-bar');
        const fill = WP.el('span');
        fill.style.width = Math.max(2, Math.round((byRes[r] / max) * 100)) + '%';
        bar.appendChild(fill);
        b.appendChild(bar);
        tallies.appendChild(b);
    }
    if (!resources.length) tallies.appendChild(WP.empty('No items'));
    body.appendChild(tallies);
}

// ---- one item ----

function renderSummary(body, key, it) {
    const split = WP.el('div', 'wp-info-split');
    const left = WP.el('div', 'ib-summary');
    left.style.flex = '1';
    left.style.minWidth = '0';
    left.appendChild(WP.el('div', 'wp-item-sub', key + '  ·  from ' + (it.resource || 'whip_core')));
    if (it.desc) left.appendChild(WP.el('div', 'wp-hint', it.desc));
    left.appendChild(WP.statusRow({ label: 'Weight', status: 'info', detail: kg(it.weight) }));
    left.appendChild(WP.statusRow({ label: 'Stacks', status: it.stack ? 'ok' : 'err',
        detail: it.stack ? 'Up to ' + (it.maxStack || 1) + ' in one slot' : 'One to a slot' }));
    split.appendChild(left);
    const hero = WP.el('div', 'wp-pick-hero wp-hero-square');
    const big = itemImg(key, 160);
    big.removeAttribute('width');
    big.removeAttribute('height');
    hero.appendChild(big);
    split.appendChild(hero);
    body.appendChild(split);

    // Its verb, beside its picture under what it is: give the admin some.
    const give = WP.el('div', 'wp-actions-row wp-after');
    els.amount = WP.input({ type: 'number', value: 1, enterAction: 'ibGive' });
    els.amount.min = 1;
    els.amount.max = 999999;   // the server's cap (ibGiveItem)
    els.amount.classList.add('wp-input-digits');
    const amountField = WP.field('Amount', els.amount);
    amountField.classList.add('wp-field-fit');
    give.appendChild(amountField);
    give.appendChild(WP.btn('Give to me', 'ibGive', 'primary'));
    // How it sits in the hand when held out to give or throw, how it is picked up, and the walk (tools/hand_edit.lua:
    // the panel steps aside).
    give.appendChild(WP.btn('Edit hand position', 'ibHandEdit', 'ghost'));
    left.appendChild(give);
}

/** One setting's editor, as the Config page's (wp/config.js): a switch, a list, a box. */
function editor(s) {
    const v = current(s);
    const k = keyOf(s);
    if (s.type === 'bool') {
        const b = WP.btn(v ? 'On' : 'Off', 'ibToggle', v ? 'primary' : null, k);
        b.classList.add('cfg-toggle');
        return b;
    }
    if (s.type === 'enum') {
        const sel = WP.select(listOf(s.options).map((o) => ({ value: o.value, label: o.label || String(o.value) })), { changeAction: 'ibEdit' });
        sel.value = String(v);
        sel.dataset.k = k;
        return sel;
    }
    const num = s.type === 'int' || s.type === 'number';
    let box;
    // A long text (a description) gets a short paragraph's box; a name, one line of about 30 characters.
    // Longer text scrolls inside the box.
    if (s.type === 'string' && (s.maxLen || 0) > 80) {
        box = WP.el('textarea', 'wp-input cfg-input-long');
        box.rows = 3;
        box.dataset.input = 'ibEdit';
        box.value = v === null || v === undefined ? '' : String(v);
    } else {
        box = WP.input({ type: num ? 'number' : 'text', value: v === null || v === undefined || v === false ? '' : v, inputAction: 'ibEdit' });
        if (num) {
            if (s.min !== undefined && s.min !== null) box.min = s.min;
            if (s.max !== undefined && s.max !== null) box.max = s.max;
            box.step = s.step || (s.type === 'int' ? 1 : 'any');
            box.classList.add('cfg-input-num');
        } else {
            box.classList.add('cfg-input-name');
        }
    }
    if (s.nullable) box.placeholder = 'none';
    box.dataset.k = k;
    return box;
}

// The item's own fields on a 12-column grid, in this order and this wide: name, description and weight on one row,
// then (config.lua's items) stacking, how many to a slot, the cooldown and its kind.
const LAYOUT = { name: [1, 4], desc: [2, 6], weight: [3, 2], stack: [4, 3], maxStack: [5, 3], cooldown: [6, 3], type: [7, 3] };
// Set elsewhere: how it is picked up and the player's walk (Edit hand position), whether it is used and its prop
// (config.lua).
const ELSEWHERE = new Set(['grab', 'playerWalk', 'usable', 'prop']);
const fieldOf = (s) => String(s.path).split('.').pop();

/** One setting's cell: its name, the editor, its default with Reset when it differs, and who changed it last. Its
 *  help only for a resource's own settings (`withHelp`). Read only when this admin may not change it. */
function settingCell(s, mayEdit, span, withHelp) {
    const k = keyOf(s);
    const r = WP.el('div', 'cfg-row cfg-row-compact ib-cell');
    r.style.gridColumn = 'span ' + span;
    r.dataset.k = k;
    const edited = pending.has(k);
    if (edited) r.classList.add('cfg-row-edited');
    const head = WP.el('div', 'cfg-row-head');
    head.appendChild(WP.el('span', 'cfg-row-label', s.label || s.path));
    r.appendChild(head);
    if (withHelp && s.help) r.appendChild(WP.el('div', 'wp-hint cfg-help', s.help));
    const isChanged = !sameSetting(current(s), defaultOf(s));

    if (!mayEdit) {
        r.appendChild(WP.el('div', 'cfg-fixed', describeSetting(s, savedOf(s))));
        if (isChanged) r.appendChild(WP.el('div', 'cfg-default', 'Default: ' + describeSetting(s, defaultOf(s))));
    } else {
        const line = WP.el('div', 'cfg-row-edit');
        const num = s.type === 'int' || s.type === 'number';
        const u = unitParts(s);
        if (num && u.before) line.appendChild(WP.el('span', 'cfg-unit', u.before));
        line.appendChild(editor(s));
        if (num && u.after) line.appendChild(WP.el('span', 'cfg-unit', u.after));
        r.appendChild(line);
        const foot = WP.el('div', 'ib-cell-foot');
        foot.appendChild(WP.el('span', 'cfg-default', 'Default: ' + describeSetting(s, defaultOf(s))));
        if (isChanged) {
            const reset = WP.btn('Reset', 'ibReset', 'ghost', k);
            reset.classList.add('wp-btn-sm');
            foot.appendChild(reset);
        }
        r.appendChild(foot);
        const err = WP.el('div', 'wp-field-msg cfg-error');
        err.style.display = 'none';
        r.appendChild(err);
    }
    if (s.changedBy && !edited) {
        r.appendChild(WP.el('div', 'cfg-meta', 'Changed by ' + s.changedBy + (s.changedAt ? ', ' + s.changedAt : '')));
    }
    return r;
}

/** A resource's own setting: a long text across half the grid, the rest a quarter. */
const ownSpan = (s) => (s.type === 'string' && (s.maxLen || 0) > 80 ? 6 : 3);

function renderSettings(body, key) {
    if (!detail || detail.key !== key || detail.loading) {
        body.appendChild(WP.el('div', 'wp-hint wp-after', 'Reading its settings…'));
        return;
    }
    if (detail.why) {
        body.appendChild(WP.el('div', 'wp-hint wp-after', detail.why));
        return;
    }
    for (const g of listOf(detail.groups)) {
        if (g.id === 'pictures') continue;   // under What players see
        const own = g.id === 'own';
        const list = listOf(g.settings).filter((s) => own || !ELSEWHERE.has(fieldOf(s)));
        if (!list.length) continue;
        if (own) {
            body.appendChild(WP.el('div', 'wp-section-title wp-apart', 'Its own settings'));
        } else {
            const at = (s) => (LAYOUT[fieldOf(s)] || [99])[0];
            list.sort((a, b) => at(a) - at(b));
        }
        const grid = WP.el('div', 'ib-fields');
        for (const s of list) {
            grid.appendChild(settingCell(s, detail.mayEdit, own ? ownSpan(s) : (LAYOUT[fieldOf(s)] || [0, 3])[1], own));
        }
        body.appendChild(grid);
    }
}

// ---- what players see: its pictures ----

let picSel = -1;      // the picture picked to edit (its row's index), -1 for none
let picDraft = null;  // { key, rows }: the pictures as being edited, a wrong one too (the pending edit only ever holds a right one)
let picWhy = null;    // what is wrong with the draft, or null

const PLUS = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>';

/** The picked item's pictures setting (every item has one), or null before its settings are read. */
function picSetting() {
    const g = listOf(detail && detail.groups).find((x) => x.id === 'pictures');
    return g ? listOf(g.settings)[0] || null : null;
}

/** Its pictures as the page shows them: the draft, else the pending edit or what is saved. */
function picRows(s) {
    if (picDraft && picDraft.key === selectedKey) return picDraft.rows;
    return listOf(current(s)).map(picRow);
}

/** The item's own pictures (its resource's), which a row may keep without a link. */
const picOwn = (s) => new Set(listOf(defaultOf(s)).map((r) => picRow(r).image).filter(Boolean));

/** A test's starting words for a field just picked. */
function picDefaults(f) {
    if (!f) return { op: 'is', value: '' };
    if (f.type === 'bool') return { op: 'is', value: 'true' };
    if (f.type === 'number') return { op: 'atLeast', value: '' };
    return { op: 'has', value: '' };
}

/** Pictures edited: kept as the draft, and pending when they are right. `redraw` false while typing (the box keeps
 *  its caret): only the message, the list and the bar change. */
function commitPictures(rows, redraw) {
    const s = picSetting();
    if (!s || !detail.mayEdit) return;
    picDraft = { key: selectedKey, rows };
    picWhy = picProblem(rows, picOwn(s));
    if (picWhy) pending.delete(keyOf(s));
    else setPending(s, rows.map((r) => ({ ...r })));
    if (redraw) {
        renderDetailKeepingFocus();
    } else if (els.body) {
        const msg = els.body.querySelector('.ib-pic-why');
        if (msg) { msg.textContent = picWhy || ''; msg.hidden = !picWhy; }
    }
    renderList();
    renderBar();
}

/** The picked picture changed by `fn`. */
function editPic(fn, redraw) {
    const s = picSetting();
    if (!s || picSel < 0) return;
    const rows = picRows(s).map((r) => ({ ...r }));
    if (!rows[picSel]) return;
    fn(rows[picSel]);
    commitPictures(rows, redraw);
}

/** A picture: the picture filling its square, and under it, outside, its name. A button when it does something. */
function picTile(o) {
    const fig = WP.el('div', 'ib-pic' + (o.cls ? ' ' + o.cls : ''));
    const frame = WP.el(o.action ? 'button' : 'div', 'ib-pic-frame');
    if (o.action) {
        frame.type = 'button';
        frame.dataset.action = o.action;
        if (o.arg !== undefined) frame.dataset.arg = String(o.arg);
    }
    if (o.img) {
        frame.appendChild(o.img);
    } else if (o.url) {
        const img = WP.el('img');
        img.alt = '';
        img.onerror = () => { img.remove(); frame.insertAdjacentHTML('beforeend', NO_PICTURE); };
        img.src = o.url;
        frame.appendChild(img);
    } else {
        frame.innerHTML = o.icon || NO_PICTURE;   // fixed icons, no data
    }
    fig.appendChild(frame);
    fig.appendChild(WP.el('div', 'ib-pic-cap', o.caption));
    return fig;
}

/** One labelled box of the picture editor. */
function picPart(label, input, cls) {
    const f = WP.field(label, input);
    f.classList.add('ib-pic-edit-part');
    if (cls) f.classList.add(cls);
    return f;
}

/** The picked picture's editor: its link, what shows it, the test and value, and its place among the others. */
function picEditor(rows, i) {
    const row = rows[i];
    const box = WP.el('div', 'ib-pic-edit');
    const link = WP.input({ value: row.image, inputAction: 'ibPicImage',
        placeholder: (listOf(detail.pictureLinks)[0] || 'https://') + '…' });
    link.dataset.change = 'ibPicCommit';
    link.dataset.k = 'pic-image';
    box.appendChild(picPart('Picture', link, 'ib-pic-edit-link'));

    const fields = listOf(detail.pictureFields);
    const opts = [{ value: '', label: 'Always' }].concat(fields.map((f) => ({ value: f.key, label: f.label })));
    if (row.field && !fields.some((f) => f.key === row.field)) opts.push({ value: row.field, label: row.field });
    const by = WP.select(opts, { changeAction: 'ibPicField' });
    by.value = row.field;
    box.appendChild(picPart('Shown by', by));

    const f = picField(row.field);
    if (f && f.type === 'bool') {
        const yes = WP.select([{ value: 'true', label: 'Yes' }, { value: 'false', label: 'No' }], { changeAction: 'ibPicValue' });
        yes.value = row.value === 'false' ? 'false' : 'true';
        box.appendChild(picPart('Is', yes));
    } else if (f) {
        const ops = PIC_OPS[f.type === 'number' ? 'number' : 'text'];
        const op = WP.select(ops.map(([value, label]) => ({ value, label })), { changeAction: 'ibPicOp' });
        op.value = row.op;
        box.appendChild(picPart('Test', op));
        if (row.op !== 'has' && row.op !== 'empty') {
            const val = WP.input({ type: f.type === 'number' ? 'number' : 'text', value: row.value, inputAction: 'ibPicValueTyped' });
            val.dataset.change = 'ibPicCommit';
            val.dataset.k = 'pic-value';
            box.appendChild(picPart('Value', val, 'ib-pic-edit-value'));
        }
    }

    const btns = WP.el('div', 'ib-pic-edit-btns');
    const earlier = WP.btn('← Earlier', 'ibPicMove', 'ghost', '-1');
    earlier.disabled = i === 0;
    const later = WP.btn('Later →', 'ibPicMove', 'ghost', '1');
    later.disabled = i === rows.length - 1;
    btns.appendChild(earlier);
    btns.appendChild(later);
    btns.appendChild(WP.btn('Remove', 'ibPicRemove', 'ghost'));
    box.appendChild(btns);
    return box;
}

/** Which of the game's car makers have a picture at `path` ({make} in it): shown under the pictures. */
function renderMakers(into, root, path) {
    const note = WP.el('div', 'wp-hint wp-after', 'Looking for each maker\'s picture…');
    into.appendChild(note);
    const strip = WP.el('div', 'ib-pics ib-pics-small wp-after');
    into.appendChild(strip);
    const rest = WP.el('div', 'wp-hint wp-after');
    rest.hidden = true;
    into.appendChild(rest);
    const go = (list) => {
        if (!note.isConnected) return;
        if (!list.length) { note.textContent = 'This game has no cars to name makers from.'; return; }
        Promise.all(list.map((m) => probe(root + path.replace(/\{make\}/g, m)).then((ok) => ({ m, ok })))).then((found) => {
            if (!note.isConnected) return;
            const have = found.filter((f) => f.ok).map((f) => f.m);
            const missing = found.filter((f) => !f.ok).map((f) => f.m);
            note.textContent = have.length
                ? 'Pictures for ' + have.length + ' of the ' + list.length + ' makers this game has cars from. The rest show Default.'
                : 'No maker has a picture yet, so every one shows Default. Name a picture after the maker, in small letters: '
                    + path.split('/').pop().replace('{make}', list[0]) + '.';
            for (const m of have) strip.appendChild(picTile({ url: root + path.replace(/\{make\}/g, m), caption: m }));
            if (missing.length) {
                rest.textContent = 'Not made yet: ' + missing.join(', ');
                rest.hidden = false;
            }
        });
    };
    if (makers) go(makers);
    else nuiCallback('ibVehicleMakes', {}).then((res) => { makers = listOf(res && res.makes); go(makers); });
}

/** Its pictures: Default (its own) and each of its rows, the first from the left that fits drawn, Default when none
 *  does; the picked one's editor under them; Add picture; Reset when they are not its resource's. */
function renderPictures(body, key, it) {
    const s = picSetting();
    const part = WP.el('div', 'ib-pics-part');
    body.appendChild(part);
    const head = WP.el('div', 'ib-pics-head');
    head.appendChild(WP.el('div', 'wp-section-title', 'What players see'));
    part.appendChild(head);

    const mayEdit = !!(s && detail.mayEdit);
    const rows = s ? picRows(s) : [];
    if (s && pending.has(keyOf(s))) part.classList.add('ib-pics-edited');
    if (mayEdit && !sameSetting(current(s), defaultOf(s))) {
        head.appendChild(WP.el('span', 'cfg-spacer'));
        const reset = WP.btn('Reset pictures', 'ibPicReset', 'ghost');
        reset.classList.add('wp-btn-sm');
        head.appendChild(reset);
    }
    if (rows.length > 1) part.appendChild(WP.el('div', 'wp-hint', 'The first from the left that fits is shown, Default when none does.'));

    const strip = WP.el('div', 'ib-pics');
    // Default goes through the inventory's path and fallback, as everywhere else.
    const own = itemImg(key, 96);
    own.removeAttribute('width');
    own.removeAttribute('height');
    strip.appendChild(picTile({ img: own, caption: 'Default' }));
    rows.forEach((row, i) => {
        strip.appendChild(picTile({ url: picUrl(it, row), caption: picCaption(row),
            action: mayEdit ? 'ibPicSelect' : null, arg: i, cls: i === picSel ? 'ib-pic-sel' : '' }));
    });
    if (mayEdit && rows.length < 24) {
        strip.appendChild(picTile({ icon: PLUS, caption: 'Add picture', action: 'ibPicAdd', cls: 'ib-pic-add' }));
    }
    part.appendChild(strip);
    if (mayEdit && picSel >= 0 && picSel < rows.length) part.appendChild(picEditor(rows, picSel));
    const why = WP.el('div', 'wp-field-msg cfg-error ib-pic-why', picWhy || '');
    why.hidden = !(picDraft && picDraft.key === key && picWhy);
    part.appendChild(why);
    const made = new Set();
    for (const row of rows) {
        if (!row.field && /\{make\}/.test(row.image) && !made.has(row.image)) {
            made.add(row.image);
            renderMakers(part, it.imgRoot || '', row.image);
        }
    }
}

function renderItem() {
    const key = selectedKey;
    const it = items[key];
    if (!it) { selectedKey = null; renderOverview(); return; }
    const body = els.body;
    body.innerHTML = '';
    els.back.style.display = '';
    els.title.textContent = it.name || key;
    renderSummary(body, key, it);
    renderSettings(body, key);
    renderPictures(body, key, it);
}

function renderDetail() {
    if (!els.body) return;
    if (selectedKey && items[selectedKey]) renderItem();
    else { selectedKey = null; renderOverview(); }
}

/** Redraw the item, keeping the box being typed in: another admin's save redraws it, and must not take
 *  the caret (or a half-typed value) away. */
function renderDetailKeepingFocus() {
    const a = document.activeElement;
    const keep = a && els.body && els.body.contains(a) && a.dataset && a.dataset.k
        ? { k: a.dataset.k, value: a.value, start: a.selectionStart, end: a.selectionEnd } : null;
    const scroll = els.detail ? els.detail.scrollTop : 0;
    renderDetail();
    if (els.detail) els.detail.scrollTop = scroll;
    if (!keep) return;
    const box = els.body.querySelector('[data-k="' + CSS.escape(keep.k) + '"]:is(input, textarea, select)');
    if (!box) return;
    box.value = keep.value;
    box.focus();
    try { if (keep.start !== null) box.setSelectionRange(keep.start, keep.end); } catch (e) { /* not a text box */ }
}

function renderBar(msg, isErr) {
    if (!els.bar) return;
    const n = pending.size;
    els.barText.textContent = msg || (sending ? 'Saving…'
        : n === 0 ? 'No unsaved changes · Saved over each item\'s defaults'
        : n + ' unsaved change' + (n === 1 ? '' : 's'));
    els.barText.classList.toggle('cfg-bar-err', !!isErr);
    els.apply.disabled = n === 0 || !!sending;
    els.discard.disabled = n === 0 || !!sending;
    els.bar.classList.toggle('cfg-bar-live', n > 0);
}

function renderAll() {
    renderList();
    renderDetailKeepingFocus();
    renderBar();
}

/** Ask the server for the picked item's settings. */
function fetchDetail(key) {
    const n = ++asked;
    if (!detail || detail.key !== key) detail = { key, loading: true };
    nuiCallback('ibSettings', { key }).then((res) => {
        if (n !== asked || key !== selectedKey) return;
        if (!res || typeof res !== 'object' || res.why || !res.groups) {
            detail = { key, why: (res && res.why) || 'Its settings could not be read' };
        } else {
            detail = { key, mayEdit: res.mayEdit === true, groups: listOf(res.groups).map((g) => ({ ...g, settings: listOf(g.settings) })),
                       pictureFields: listOf(res.pictureFields), pictureLinks: listOf(res.pictureLinks) };
            // An edit that now matches what is saved (another admin made the same change, or a reset
            // whose default is saved) goes.
            for (const [k, p] of [...pending]) {
                if (p.item !== key) continue;
                const s = settingAt(k);
                if (!s) { pending.delete(k); continue; }
                if (p.reset ? sameSetting(savedOf(s), defaultOf(s)) : sameSetting(p.value, savedOf(s))) pending.delete(k);
            }
        }
        renderList();
        renderDetailKeepingFocus();
        renderBar();
    });
}

function select(key) {
    selectedKey = key && items[key] ? key : null;
    picSel = -1;
    picDraft = null;
    picWhy = null;
    if (selectedKey) fetchDetail(selectedKey);
    renderList();
    renderDetail();
    if (els.detail) els.detail.scrollTop = 0;
}

// ---- edits ----

function showRowError(k, why) {
    const r = els.body && els.body.querySelector('.cfg-row[data-k="' + CSS.escape(k) + '"]');
    const e = r && r.querySelector('.cfg-error');
    if (!e) return;
    e.textContent = why || '';
    e.style.display = why ? '' : 'none';
}

/** Record an edit, or drop it when it puts the value back to what is saved. */
function setPending(s, value) {
    if (sameSetting(value, savedOf(s))) pending.delete(keyOf(s));
    else pending.set(keyOf(s), { item: selectedKey, value });
}

/** An edit typed in a box: checked as it is typed, recorded only when it is allowed. */
function typed(el) {
    const s = settingAt(el.dataset.k);
    if (!s) return;
    const c = checkSetting(s, el.value);
    if (c.why) {
        showRowError(keyOf(s), s.label + ' ' + c.why);
        // Not recorded: Apply never sends a value the page already knows is wrong.
        pending.delete(keyOf(s));
    } else {
        showRowError(keyOf(s), null);
        setPending(s, c.value);
    }
    // Only the row's ring, the list and the bar redraw while typing: redrawing the row would take the
    // caret out of the box.
    const r = el.closest('.cfg-row');
    if (r) r.classList.toggle('cfg-row-edited', pending.has(keyOf(s)));
    renderList();
    renderBar();
}

// ---- section ----

WhipPanel.registerSection({
    id: 'items',
    group: 'economy',
    label: 'Items',
    order: 10,   // the Economy tab's first page (Josh), then Shops

    render(root) {
        els = {};
        search = '';
        els.resFilter = WP.select([{ value: '', label: 'Every resource' }], { changeAction: 'ibFilterRes' });
        root.appendChild(WP.toolbar({
            left: [els.resFilter],
            search: { inputAction: 'ibSearch', placeholder: 'Name, key or resource…', id: 'wp-ib-search' },
        }));

        const split = WP.el('div', 'wp-split');
        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        els.detail = WP.el('div', 'wp-detail cfg-detail');
        // Back to the items at a glance, over an item's page (as the Item Log's "Back to everything").
        els.back = WP.backBtn('All items', 'ibBack');
        els.back.classList.add('wp-log-back');
        els.back.style.display = 'none';
        els.detail.appendChild(els.back);
        els.title = WP.el('div', 'wp-pane-title', 'Items');
        els.detail.appendChild(els.title);
        els.body = WP.el('div');
        els.detail.appendChild(els.body);
        split.appendChild(els.detail);
        root.appendChild(split);

        // The Apply bar, as the Config page's: quiet until an edit is waiting.
        els.bar = WP.el('div', 'cfg-bar');
        els.barText = WP.el('span', 'cfg-bar-text', '');
        els.bar.appendChild(els.barText);
        els.bar.appendChild(WP.el('span', 'cfg-spacer'));
        els.discard = WP.btn('Discard', 'ibDiscard', 'ghost');
        els.apply = WP.btn('Apply', 'ibApply', 'primary');
        els.bar.appendChild(els.discard);
        els.bar.appendChild(els.apply);
        root.appendChild(els.bar);

        renderResourceOptions();
        renderList();
        renderDetail();
        renderBar();
        if (selectedKey) fetchDetail(selectedKey);
    },

    onData(kind, payload) {
        if (kind === 'all') {
            // The server re-pushes the whole catalogue whenever an item is registered or one's settings
            // change: the search, the filter and the pick stay.
            items = payload && typeof payload === 'object' ? payload : {};
            renderResourceOptions();
            if (selectedKey && !items[selectedKey]) selectedKey = null;
            renderList();
            renderDetailKeepingFocus();
        } else if (kind === 'settingsSaved') {
            if (selectedKey) fetchDetail(selectedKey);
        } else if (kind === 'applied') {
            // Only what was sent is done: an edit made while the save was on its way stays.
            if (sending) {
                for (const [k, sent] of sending) if (sameSetting(pending.get(k), sent)) pending.delete(k);
            }
            sending = null;
            // Saved pictures are what is saved now: the draft goes unless an edit is still waiting.
            const ps = picSetting();
            if (picDraft && !(ps && pending.has(keyOf(ps)))) { picDraft = null; picWhy = null; }
            renderAll();
        } else if (kind === 'applyFailed') {
            sending = null;
            renderBar((payload && payload.why) || 'Not saved', true);
        }
    },

    onEscape() {
        // An open item backs out to the items at a glance first.
        if (selectedKey !== null) { select(null); return true; }
        return false;
    },

    actions: {
        ibSearch: (el) => { search = (el.value || '').trim().toLowerCase(); renderList(); },
        ibFilterRes: (el) => { resFilter = el.value; renderList(); },
        ibShowResource: (el) => {
            resFilter = el.dataset.arg || '';
            if (els.resFilter) els.resFilter.value = resFilter;
            renderList();
        },
        ibSelect: (el) => select(el.dataset.id || el.dataset.arg),
        ibBack: () => select(null),
        ibGive: () => {
            if (!selectedKey || !els.amount) return;
            let amount = parseInt(els.amount.value, 10) || 1;
            if (amount < 1) amount = 1;
            if (amount > 999999) amount = 999999;
            nuiCallback('ibGiveItem', { itemKey: selectedKey, amount });
        },
        ibHandEdit: () => {
            if (selectedKey) nuiCallback('ibHandEdit', { itemKey: selectedKey, label: nameOf(selectedKey) });
        },
        ibEdit: (el) => typed(el),
        ibToggle: (el) => {
            const s = settingAt(el.dataset.arg);
            if (!s) return;
            setPending(s, !current(s));
            renderAll();
        },
        ibReset: (el) => {
            const s = settingAt(el.dataset.arg);
            if (!s) return;
            // What is saved is already its own (an unsent edit made it differ): dropping the edit is the
            // reset. Otherwise its own is saved on Apply.
            if (sameSetting(savedOf(s), defaultOf(s))) pending.delete(keyOf(s));
            else pending.set(keyOf(s), { item: selectedKey, reset: true });
            renderAll();
        },
        ibDiscard: () => {
            if (sending) return;
            pending.clear();
            picDraft = null;
            picWhy = null;
            picSel = -1;
            renderAll();
        },
        // ---- its pictures ----
        ibPicSelect: (el) => {
            const i = Number(el.dataset.arg);
            picSel = picSel === i ? -1 : i;
            renderDetailKeepingFocus();
        },
        ibPicAdd: () => {
            const s = picSetting();
            if (!s) return;
            const rows = picRows(s).map((r) => ({ ...r }));
            // Shown by the first thing it can be (the count, for an item that stacks), not Always: an Always picture
            // would stand in for Default whenever nothing before it fits.
            const first = listOf(detail.pictureFields)[0] || null;
            rows.push({ image: '', field: first ? first.key : '', ...picDefaults(first) });
            picSel = rows.length - 1;
            commitPictures(rows, true);
        },
        ibPicImage: (el) => editPic((r) => { r.image = el.value.trim(); }, false),
        ibPicValueTyped: (el) => editPic((r) => { r.value = el.value.trim(); }, false),
        // A box let go: only the picked picture's tile is drawn again (a full redraw would take away the control
        // being clicked next).
        ibPicCommit: () => {
            const s = picSetting();
            const it = items[selectedKey];
            const row = s && picSel >= 0 ? picRows(s)[picSel] : null;
            const tile = els.body && els.body.querySelector('.ib-pic-sel');
            if (!row || !it || !tile) return;
            tile.replaceWith(picTile({ url: picUrl(it, row), caption: picCaption(row), action: 'ibPicSelect', arg: picSel, cls: 'ib-pic-sel' }));
        },
        ibPicField: (el) => editPic((r) => { r.field = el.value; Object.assign(r, picDefaults(picField(r.field))); }, true),
        ibPicOp: (el) => editPic((r) => { r.op = el.value; if (r.op === 'has' || r.op === 'empty') r.value = ''; }, true),
        ibPicValue: (el) => editPic((r) => { r.value = el.value; }, true),
        ibPicMove: (el) => {
            const s = picSetting();
            if (!s || picSel < 0) return;
            const rows = picRows(s).map((r) => ({ ...r }));
            const to = picSel + Number(el.dataset.arg);
            if (to < 0 || to >= rows.length) return;
            [rows[picSel], rows[to]] = [rows[to], rows[picSel]];
            picSel = to;
            commitPictures(rows, true);
        },
        ibPicRemove: () => {
            const s = picSetting();
            if (!s || picSel < 0) return;
            const rows = picRows(s).map((r) => ({ ...r }));
            rows.splice(picSel, 1);
            picSel = -1;
            commitPictures(rows, true);
        },
        ibPicReset: () => {
            const s = picSetting();
            if (!s) return;
            picDraft = null;
            picWhy = null;
            picSel = -1;
            if (sameSetting(savedOf(s), defaultOf(s))) pending.delete(keyOf(s));
            else pending.set(keyOf(s), { item: selectedKey, reset: true });
            renderAll();
        },
        ibApply: () => {
            if (pending.size === 0 || sending) return;
            const changes = [];
            sending = new Map();
            for (const [k, p] of pending) {
                sending.set(k, p);
                const at = k.indexOf('|');
                const owner = k.slice(0, at), path = k.slice(at + 1);
                if (p.reset) changes.push({ owner, path, reset: true });
                else if (p.value === null) changes.push({ owner, path, isNil: true });
                else changes.push({ owner, path, value: p.value });
            }
            renderBar();
            // The Config page's own door (tools/panel_sections/config.lua): the answer comes back here.
            nuiCallback('cfgApply', { changes, section: 'items' });
        },
    },
});
