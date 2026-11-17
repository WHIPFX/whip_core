// ========================================
// /whip SECTION — Ground Items
//
// The list of what lies on the ground on the left, each with its picture; on the right, nothing
// picked, the ground at a glance (how much, the most common things, the clean-up buttons), or the
// picked pile's page: its picture beside what it is, where, who dropped it and when, what it
// carries, and its verbs.
//
// The clean-up buttons live on the at-a-glance page, the map toggles are on/off chips, and the
// search reads every field. "Ground Items Debug" is the /w tool of that name (every pile to the sky and
// on the map, and the grid of squares round you on the ground), switched from here; a pile's own blip
// and marker pick out that one pile.
//
// "Select items within 50 m" picks every pile near you in the list (gimNear: the Lua half knows where you
// stand), for the picks bar's Delete.
//
// The destructive actions go through WP.confirm({danger:true}) — the shell dialog is the one confirm
// idiom. Mutation callbacks (gimTeleport, gimToggleBlip, gimToggleMarker, gimDebug, gimDeleteItem,
// gimDeleteItems, gimDeleteAll, gimDeleteCell) and gimNear live in tools/panel_sections/ground.lua.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback, itemImageUrl } from '../utils.js';
import { openItemTimeline } from './itemlog.js';
import { ago } from './format.js';

let items = {};          // keyed by String(id)
let itemDefs = {};       // { [itemKey]: { name, img } } — img: where its picture is (utils itemImageUrl)
let charNames = {};      // { [charId]: "FirstName LastName" }
let serverTime = 0;      // server epoch for relative time calc
let cellSize = 50;       // grid cell size, forwarded by the Lua half with the snapshot
let selectedId = null;
let search = '';
let debugOn = false;     // the /w Ground Items Debug
const NEAR_M = 50;       // "Select items within 50 m": how far from you a pile may lie
const blipOn = {};       // [id] = true: that pile's blip is on
const markerOn = {};     // [id] = true: that pile's marker is on
let els = {};

// ---- helpers ----

/** Every blip and marker off, as Lua's gimClearBlipsAndMarkers leaves them. */
function forgetMapMarks() {
    for (const id of Object.keys(blipOn)) delete blipOn[id];
    for (const id of Object.keys(markerOn)) delete markerOn[id];
}

/** A Lua list from the bridge: an empty one can arrive as {} rather than []. */
function listOf(v) {
    return Array.isArray(v) ? v : (v && typeof v === 'object' ? Object.values(v) : []);
}

function normalize(raw) {
    items = {};
    if (Array.isArray(raw)) {
        for (const it of raw) { if (it && it.id) items[String(it.id)] = it; }
    } else if (raw) {
        for (const key of Object.keys(raw)) {
            const it = raw[key];
            if (it && it.id) items[String(it.id)] = it;
        }
    }
}

function itemName(itemKey) {
    const def = itemDefs[itemKey];
    return def ? def.name : itemKey;
}

function cellKey(it) {
    if (typeof it.x !== 'number' || typeof it.y !== 'number') return '?';
    return Math.floor(it.x / cellSize) + '_' + Math.floor(it.y / cellSize);
}

function owner(it) {
    if (!it.createdBy) return 'nobody (the world)';
    return charNames[it.createdBy] || ('Character #' + it.createdBy);
}

/** How long a pile has been down, by the server's clock (the snapshot's), to the second under a minute. */
function timeAgo(createdAt) {
    return createdAt ? ago(createdAt, { now: serverTime * 1000, seconds: true }) : 'unknown';
}

function itemImg(key, size) {
    const img = document.createElement('img');
    img.width = size;
    img.height = size;
    img.alt = '';
    img.dataset.itemImg = '';   // the global missing-image fallback (utils.js)
    img.dataset.itemKey = key;
    img.src = itemImageUrl(key, itemDefs[key] && itemDefs[key].img);
    return img;
}

// ---- filtering: one search over the item, who dropped it, its id and its grid cell ----

function filteredIds() {
    const ids = Object.keys(items).sort((a, b) => parseInt(b, 10) - parseInt(a, 10));
    if (!search) return ids;
    return ids.filter((id) => {
        const it = items[id];
        return (it.item || '').toLowerCase().includes(search)
            || itemName(it.item).toLowerCase().includes(search)
            || owner(it).toLowerCase().includes(search)
            || String(it.createdBy || '') === search
            || String(it.id).includes(search)
            || cellKey(it) === search;
    });
}

// ---- list ----

// Piles picked in the list, deleted together from the bar over it (one server call: gimDeleteItems).
const pilePicks = WP.picks({ id: 'gim-piles', one: 'pile', many: 'piles',
    actions: [{ label: (n) => 'Delete ' + n + (n === 1 ? ' pile' : ' piles'), action: 'gimDeleteMany', kind: 'danger' }] });

function renderList() {
    els.list.innerHTML = '';
    const ids = filteredIds();
    const total = Object.keys(items).length;
    pilePicks.keep(Object.keys(items));
    els.list.appendChild(pilePicks.bar());

    for (const id of ids) {
        const it = items[id];
        const row = WP.listItem({
            title: itemName(it.item),
            pill: '×' + it.amount,
            sub: owner(it) + ' · ' + timeAgo(it.createdAt),
            id: id,
            action: 'gimSelect',
        });
        row.classList.add('wp-has-icon');
        row.insertBefore(itemImg(it.item, 32), row.firstChild);
        row.querySelector('.wp-item-top').prepend(pilePicks.box(id));
        if (selectedId === id) row.classList.add('active');
        els.list.appendChild(row);
    }

    if (ids.length === 0) {
        els.list.appendChild(WP.empty(search ? 'No matches' : 'Nothing on the ground'));
    }
    els.count.textContent = ids.length + ' of ' + total;
}

function paintToggles() {
    if (!els.debugBtn) return;
    els.debugBtn.classList.toggle('active', debugOn);
    els.debugBtn.textContent = 'Ground Items Debug' + (debugOn ? ' · on' : '');
}

// ---- the right pane: the ground at a glance, or one pile ----

function renderOverview() {
    selectedId = null;
    const body = els.detailBody;
    body.innerHTML = '';
    els.detailTitle.textContent = 'On the ground';

    const list = Object.values(items);
    const byItem = {};
    let oldest = null, byWorld = 0;
    for (const it of list) {
        const e = byItem[it.item] || (byItem[it.item] = { key: it.item, piles: 0, amount: 0 });
        e.piles += 1;
        e.amount += Number(it.amount) || 0;
        if (it.createdAt && (!oldest || it.createdAt < oldest.createdAt)) oldest = it;
        if (!it.createdBy) byWorld += 1;
    }
    const kinds = Object.values(byItem).sort((a, b) => b.piles - a.piles || b.amount - a.amount);

    const stats = WP.el('div', 'wp-stats');
    stats.appendChild(WP.stat('Piles', String(list.length), list.length === 1 ? 'one thing lying about' : 'things lying about'));
    stats.appendChild(WP.stat('Kinds of item', String(kinds.length)));
    stats.appendChild(WP.stat('Oldest', oldest ? timeAgo(oldest.createdAt) : '—', oldest ? itemName(oldest.item) + ', by ' + owner(oldest) : ''));
    stats.appendChild(WP.stat('Dropped by players', String(list.length - byWorld), byWorld ? byWorld + ' left by the world' : ''));
    body.appendChild(stats);

    body.appendChild(WP.el('div', 'wp-section-title', 'Most common'));
    const tallies = WP.el('div', 'wp-tallies');
    const max = kinds.reduce((m, k) => Math.max(m, k.piles), 0) || 1;
    for (const k of kinds.slice(0, 8)) {
        const b = WP.el('button', 'wp-tally');
        b.type = 'button';
        b.dataset.action = 'gimShowItem';
        b.dataset.arg = k.key;
        b.title = 'Show only these in the list';
        b.appendChild(WP.el('span', 'wp-tally-name', itemName(k.key)));
        b.appendChild(WP.el('span', 'wp-tally-value', k.piles + (k.piles === 1 ? ' pile' : ' piles')));
        b.appendChild(WP.el('span', 'wp-tally-sub', k.amount.toLocaleString('en-US') + ' in all'));
        const bar = WP.el('span', 'wp-tally-bar');
        const fill = WP.el('span');
        fill.style.width = Math.max(2, Math.round((k.piles / max) * 100)) + '%';
        bar.appendChild(fill);
        b.appendChild(bar);
        tallies.appendChild(b);
    }
    if (!kinds.length) tallies.appendChild(WP.empty('Nothing is lying on the ground'));
    body.appendChild(tallies);

    // The sweeps, on the page that shows what they would sweep.
    body.appendChild(WP.el('div', 'wp-section-title', 'Clean up'));
    body.appendChild(WP.el('div', 'wp-hint', 'The ground is cut into squares of ' + cellSize + ' m (Ground Items Debug shows them). '
        + '"Delete what is in my square" clears the one you are standing in; "Delete everything" clears the lot.'));
    const actions = WP.el('div', 'wp-actions-row');
    const cell = WP.btn('Delete what is in my square', 'gimDeleteCell', 'danger');
    const all = WP.btn('Delete everything (' + list.length + ')', 'gimDeleteAll', 'danger');
    // Nothing on the ground: nothing for either to delete.
    cell.disabled = all.disabled = list.length === 0;
    actions.appendChild(cell);
    actions.appendChild(all);
    body.appendChild(actions);
}

function infoRow(grid, label, value, mono) {
    grid.appendChild(WP.el('span', 'wp-info-label', label));
    grid.appendChild(WP.el('span', 'wp-info-value' + (mono ? ' wp-info-value-mono' : ''), value));
}

/** What a pile carries: its id in the log (a link to its life), its plain values as rows, and
 *  anything deeper (a wallet's contents) as readable data. */
function renderMetadata(body, it) {
    const meta = it.metadata && typeof it.metadata === 'object' ? it.metadata : null;
    body.appendChild(WP.el('div', 'wp-section-title', 'What it carries'));
    if (!meta || !Object.keys(meta).length) {
        body.appendChild(WP.el('div', 'wp-hint', 'Nothing of its own: a plain ' + itemName(it.item) + '.'));
        return;
    }
    if (typeof meta.uid === 'string') {
        body.appendChild(WP.statusRow({ label: 'Item id', status: 'ok', detail: meta.uid,
            action: 'gimItemLife', arg: meta.uid, actionLabel: 'Its life' }));
    }
    const flat = [], deep = {};
    for (const k of Object.keys(meta)) {
        if (k === 'uid') continue;
        const v = meta[k];
        if (v === null || typeof v !== 'object') flat.push([k, v]); else deep[k] = v;
    }
    if (flat.length) {
        const grid = WP.el('div', 'wp-info-grid wp-after');
        for (const [k, v] of flat) infoRow(grid, k, String(v), true);
        body.appendChild(grid);
    }
    if (Object.keys(deep).length) {
        body.appendChild(WP.el('pre', 'wp-code wp-after', JSON.stringify(deep, null, 2)));
    }
}

function showDetail(id) {
    const it = items[String(id)];
    if (!it) { renderOverview(); return; }
    const body = els.detailBody;
    body.innerHTML = '';
    els.detailTitle.textContent = itemName(it.item) + (it.amount > 1 ? ' ×' + it.amount : '');

    // What it is, where, by whom, beside its picture.
    const split = WP.el('div', 'wp-info-split');
    const left = WP.el('div');
    left.style.flex = '1';
    left.style.minWidth = '0';
    left.appendChild(WP.el('div', 'wp-item-sub', 'Pile #' + it.id + '  ·  ' + it.item));
    left.appendChild(WP.statusRow({ label: 'Amount', status: 'ok', detail: String(it.amount) }));
    left.appendChild(WP.statusRow({ label: 'Where', status: 'ok',
        detail: 'square ' + cellKey(it),
        action: 'gimTeleport', arg: it.id, actionLabel: 'Teleport' }));
    left.appendChild(WP.place({ x: it.x, y: it.y, name: itemName(it.item) + ' ×' + it.amount }));
    left.appendChild(WP.statusRow({ label: 'Dropped by', status: it.createdBy ? 'ok' : 'off',
        detail: owner(it) + (it.createdBy ? '  ·  #' + it.createdBy : '') }));
    left.appendChild(WP.statusRow({ label: 'When', status: 'ok', detail: timeAgo(it.createdAt) }));
    split.appendChild(left);
    const hero = WP.el('div', 'wp-pick-hero wp-hero-square');
    const big = itemImg(it.item, 160);
    big.removeAttribute('width');
    big.removeAttribute('height');
    hero.appendChild(big);
    split.appendChild(hero);
    body.appendChild(split);

    // Its verbs: delete far left, the rest far right. Blip and marker are this admin's own, on or off.
    const actions = WP.el('div', 'wp-actions-row wp-after');
    actions.appendChild(WP.btn('Delete', 'gimDeleteItem', 'danger', it.id));
    actions.appendChild(WP.el('span', 'wp-actions-split'));
    const blip = WP.el('button', 'wp-toggle' + (blipOn[it.id] ? ' active' : ''), 'On my map' + (blipOn[it.id] ? ' · on' : ''));
    blip.type = 'button';
    blip.dataset.action = 'gimToggleBlip';
    blip.dataset.arg = it.id;
    actions.appendChild(blip);
    const marker = WP.el('button', 'wp-toggle' + (markerOn[it.id] ? ' active' : ''), 'Marker over it' + (markerOn[it.id] ? ' · on' : ''));
    marker.type = 'button';
    marker.dataset.action = 'gimToggleMarker';
    marker.dataset.arg = it.id;
    actions.appendChild(marker);
    actions.appendChild(WP.btn('Teleport there', 'gimTeleport', 'primary', it.id));
    body.appendChild(actions);

    renderMetadata(body, it);
}

function select(id) {
    selectedId = String(id);
    showDetail(selectedId);
    renderList();
}

// ---- section ----

WhipPanel.registerSection({
    id: 'ground',
    group: 'world',
    label: 'Ground Items',
    order: 30,

    render(root) {
        els = {};
        // The map toggles are on/off chips; the deletes are on the at-a-glance page.
        els.debugBtn = WP.el('button', 'wp-toggle', 'Ground Items Debug');
        els.debugBtn.type = 'button';
        els.debugBtn.dataset.action = 'gimDebug';
        els.debugBtn.title = 'Every pile marked to the sky and on your map, and the squares round you on the ground: '
            + 'the same as /w Ground Items Debug';
        // Every pile near you picked at once, for the picks bar's Delete (a throw test's clean-up)
        const nearBtn = WP.btn('Select items within ' + NEAR_M + ' m', 'gimPickNear');
        nearBtn.title = 'Pick every pile within ' + NEAR_M + ' m of you in the list, to delete them together';
        root.appendChild(WP.toolbar({
            left: [els.debugBtn, nearBtn],
            search: { inputAction: 'gimFilter', placeholder: 'Item, who dropped it, id…', id: 'wp-gim-search' },
        }));

        const split = WP.el('div', 'wp-split');

        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        const detail = WP.el('div', 'wp-detail');
        els.detailTitle = WP.el('div', 'wp-pane-title', 'On the ground');
        detail.appendChild(els.detailTitle);
        els.detailBody = WP.el('div');
        detail.appendChild(els.detailBody);
        split.appendChild(detail);

        root.appendChild(split);
        els.search = root.querySelector('#wp-gim-search');
        paintToggles();
        renderOverview();
        renderList();
    },

    onData(kind, payload) {
        if (kind === 'all') {
            // Section-enter snapshot: reset the search and selection, adopt everything.
            normalize(payload.items);
            itemDefs = payload.defs || {};
            charNames = payload.charNames || {};
            serverTime = payload.serverTime || 0;
            if (payload.cellSize) cellSize = payload.cellSize;
            search = '';
            els.search.value = '';
            // The blips and markers as Lua has them: they stay on after the menu closes, so a reopen shows them.
            // And the /w debug, which may have been switched there.
            forgetMapMarks();
            debugOn = !!payload.debugOn;
            for (const id of listOf(payload.blipIds)) blipOn[id] = true;
            for (const id of listOf(payload.markerIds)) markerOn[id] = true;
            paintToggles();
            renderOverview();
            renderList();
        } else if (kind === 'refresh') {
            // Server-side change while open — keep the search and selection where possible.
            normalize(payload.items);
            if (payload.charNames) charNames = payload.charNames;
            if (payload.serverTime) serverTime = payload.serverTime;
            renderList();
            if (selectedId && items[selectedId]) showDetail(selectedId);
            else renderOverview();
        }
    },

    onEscape() {
        // Drill-down stage: an open pile backs out to the ground at a glance first.
        if (selectedId !== null) { renderOverview(); renderList(); return true; }
        return false;
    },

    actions: {
        gimFilter: () => {
            search = (els.search.value || '').trim().toLowerCase();
            renderList();
        },
        gimSelect: (el) => select(el.dataset.id),
        gimShowItem: (el) => {
            search = itemName(el.dataset.arg).toLowerCase();
            els.search.value = itemName(el.dataset.arg);
            renderList();
        },
        gimItemLife: (el) => openItemTimeline(el.dataset.arg),
        gimDebug: () => {
            nuiCallback('gimDebug', {}).then((result) => {
                debugOn = !!(result && result.on);
                paintToggles();
            });
        },
        // The piles within NEAR_M of you, by the Lua half (it knows where you stand): they replace what was picked,
        // the search clears so every one shows in the list, and the picks bar offers to delete them.
        gimPickNear: async () => {
            const res = await nuiCallback('gimNear', { range: NEAR_M });
            if (!res || !res.ok) { WP.result('Could not tell where you are', 'err'); return; }
            const near = listOf(res.ids).map(String).filter((id) => items[id]);
            pilePicks.clear();
            if (!near.length) { WP.result('Nothing on the ground within ' + NEAR_M + ' m of you', 'ok'); return; }
            pilePicks.add(near);
            if (search) { search = ''; els.search.value = ''; }
            renderList();
            WP.result('Picked ' + near.length + (near.length === 1 ? ' pile' : ' piles') + ' within ' + NEAR_M + ' m', 'ok');
        },
        gimDeleteCell: async () => {
            const ok = await WP.confirm({
                title: 'Delete what is in your square?',
                body: 'Every ground item in the ' + cellSize + ' m square you are standing in will be removed.',
                confirmLabel: 'Delete',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('gimDeleteCell', {});
        },
        gimDeleteAll: async () => {
            const count = Object.keys(items).length;
            if (count === 0) return;
            const ok = await WP.confirm({
                title: 'Delete everything on the ground?',
                body: count + ' pile' + (count !== 1 ? 's' : '') + ' will be removed from the world.',
                confirmLabel: 'Delete everything',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('gimDeleteAll', {});
            // Lua drops every blip and marker with them (gimClearBlipsAndMarkers).
            forgetMapMarks();
            paintToggles();
        },
        gimDeleteMany: async () => {
            const ids = pilePicks.keys().filter((id) => items[id]);
            if (!ids.length) return;
            const ok = await WP.confirm({
                title: 'Delete ' + ids.length + (ids.length === 1 ? ' pile?' : ' piles?'),
                body: (ids.length === 1 ? 'It is' : 'They are') + ' removed from the world.',
                confirmLabel: 'Delete', danger: true,
            });
            if (!ok) return;
            nuiCallback('gimDeleteItems', { ids: ids.map(Number) });
            for (const id of ids) { delete blipOn[id]; delete markerOn[id]; }
            pilePicks.clear();
        },
        gimTeleport: (el) => nuiCallback('gimTeleport', { id: Number(el.dataset.arg) }),
        gimToggleBlip: (el) => {
            const id = Number(el.dataset.arg);
            nuiCallback('gimToggleBlip', { id }).then((res) => {
                if (res && res.on) blipOn[id] = true; else delete blipOn[id];
                if (String(selectedId) === String(id)) showDetail(selectedId);
            });
        },
        gimToggleMarker: (el) => {
            const id = Number(el.dataset.arg);
            nuiCallback('gimToggleMarker', { id }).then((res) => {
                if (res && res.on) markerOn[id] = true; else delete markerOn[id];
                if (String(selectedId) === String(id)) showDetail(selectedId);
            });
        },
        gimDeleteItem: async (el) => {
            const id = Number(el.dataset.arg);
            const it = items[String(id)];
            const ok = await WP.confirm({
                title: 'Delete this pile?',
                body: (it ? itemName(it.item) + ' ×' + it.amount + ' ' : '') + '(#' + id + ') will be removed.',
                confirmLabel: 'Delete',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('gimDeleteItem', { id: id });
        },
    },
});
