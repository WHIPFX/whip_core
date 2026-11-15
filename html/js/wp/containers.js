// ========================================
// /whip SECTION — Containers
//
// The list of containers on the left, each with its prop's picture; on the right, the picked one as
// a summary — its model, where it stands, what it holds, who can open it, what it takes — each part
// with a Change button.
//
// ONE WIZARD SETS CONTAINERS UP AND CHANGES THEM (the prop picked from a visual list, as NPCs and
// shops are). WP.stepper, as the shop and property wizards use it, in the section's place:
//
//   Name & Model  what it is called, beside the props' search; the furnisher's props as pictures, the new-vehicle
//                 wizard's way (pickers.js propPicker), or a model typed in. Every new one is a stash.
//   Where    put it in the world — a see-through copy where you aim, the placer's card saying the keys — or where
//            you stand
//   Holds    how many slots and how much weight, down the left; the container opened, on the right
//   Access   who can open it: anyone near it, one character, or nobody (locked); and whose it is. The choices down
//            the left, everyone to pick from on the right (pickers.js personList)
//   Items    anything, or only the items picked from their pictures (pickers.js itemPicker)
//   Review   the lot, checked; Create / Save changes
//
// + New Container starts it empty, a step at a time. Change on a container's page opens it filled in
// with the container as it is, on that part, every step open from the rail; the last step says what
// changed. Esc there goes back to that summary, then out.
//
// The calls: cmCreateContainer / cmUpdateContainer / cmDeleteContainer / cmTeleport / cmGetPlayerPos /
// cmOpenContainer, unchanged (client/containers.lua, tools/panel_sections/containers.lua); the
// wizard's own two are cmPropCatalog (the props with pictures) and cmPlace (placing it in the world,
// answered with a 'spot'). The item list is the Item Log's alSetup: every item with its picture.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback, propImageUrl, itemImageUrl } from '../utils.js';
import { propPicker, propPortrait, itemPicker, personList, knownCharName, avatar, inventoryPreview, iconInput } from './pickers.js';
import { plural, fixed } from './format.js';

let containers = {};     // keyed by String(containerId)
let selectedId = null;   // the container whose page is open
let els = {};
let search = '';

let catalog = null;      // the furnisher's props (cmPropCatalog), read the first time it is needed
let catalogAsk = null;
let items = null;        // every item, { key: { name, img, resource } } (alSetup), for the Items step
let itemsAsk = null;
const charNames = {};    // charId -> name, as found (wpCharSearch)

let draft = null;        // the container being set up or changed, while the wizard is open
let wiz = null;          // its WP.stepper
let wizAt = 'name';      // the step it is on, so the panel reopens there
let pendingSelect = false;   // a container just made: opened when the server says it exists

const DEFAULT_PROP = 'prop_cs_cardbox_01';   // Config.ContainerDefaultProp's

const STEPS = [
    { key: 'name', label: 'Name & Model' },
    { key: 'where', label: 'Where' },
    { key: 'holds', label: 'Holds' },
    { key: 'access', label: 'Access' },
    { key: 'items', label: 'Items' },
    { key: 'review', label: 'Review' },
];

/** The step a summary row's part is on: its name and its model share one. */
const stepOf = (part) => (part === 'model' ? 'name' : part);

const SIZES = [
    { key: 'small', title: 'Small', slots: 10, weight: 50 },
    { key: 'medium', title: 'Medium', slots: 20, weight: 100 },
    { key: 'large', title: 'Large', slots: 40, weight: 250 },
    { key: 'huge', title: 'Huge', slots: 80, weight: 500 },
];

// 'one' and 'nobody' are the keys a container kept before there could be several (a draft's openBy).
const OPEN_BY = [
    { key: 'anyone', title: 'Anyone near it', text: 'Whoever walks up to it can open it.' },
    { key: 'one', title: 'Specific players only', text: 'Only the players you pick. Everyone else is told no.' },
    { key: 'nobody', title: 'Admin only', text: 'Locked shut. Only an admin can open it, from this page.' },
];

/* WHO CAN OPEN IT, SEVERAL (Josh): its rules' `charIds`, any one of whom may open it (Containers.canAccess: the
   doors' shape). An older one's single accessCharId joins them, and is cleared when it is saved. Any other rule a
   resource gave it (jobs, items, ace) is kept as it is. */

/** Its rules' charIds, as numbers, whichever shape they came in (a list; a set if a script wrote one). */
function ruleIds(req) {
    const ids = req && req.charIds;
    if (!ids || typeof ids !== 'object') return [];
    return (Array.isArray(ids) ? ids : Object.values(ids)).map(Number).filter((n) => n > 0);
}

/** Its rules other than who: a resource's, which the wizard never changes. null for none. */
function otherRules(req) {
    if (!req || typeof req !== 'object') return null;
    const out = {};
    for (const k of Object.keys(req)) if (k !== 'charIds') out[k] = req[k];
    return Object.keys(out).length ? out : null;
}

// ---- the lists it reads ----

function loadCatalog() {
    if (catalog) return Promise.resolve(catalog);
    if (!catalogAsk) {
        catalogAsk = Promise.resolve(nuiCallback('cmPropCatalog', {})).then((res) => {
            catalogAsk = null;
            const props = res && (Array.isArray(res.props) ? res.props : Object.values(res.props || {}));
            if (props && props.length) catalog = res;
            return catalog;
        });
    }
    return catalogAsk;
}

function loadItems() {
    if (items) return Promise.resolve(items);
    if (!itemsAsk) {
        itemsAsk = Promise.resolve(nuiCallback('alSetup', {})).then((res) => {
            itemsAsk = null;
            if (res && res.items && typeof res.items === 'object') items = res.items;
            return items;
        });
    }
    return itemsAsk;
}

/** A character's name, found once (the panel's character search, by id). Redraws `then` after. */
function charName(id, then) {
    id = Number(id);
    if (!(id > 0)) return '';
    if (charNames[id]) return charNames[id];
    const known = knownCharName(id);   // Access's list has read everyone
    if (known) { charNames[id] = known; return known; }
    if (charNames[id] !== undefined) return charNames[id];
    charNames[id] = '';   // asked once
    nuiCallback('wpCharSearch', { q: String(id) }).then((list) => {
        const hit = Array.isArray(list) && list.find((p) => Number(p.charId) === id);
        if (hit && hit.name) { charNames[id] = hit.name; if (then) then(); }
    });
    return '';
}

function personText(id, then) {
    const n = charName(id, then);
    return n ? n + ' (#' + id + ')' : 'character #' + id;
}

/** A model's catalog name, or the model. */
function propName(model) {
    if (!model) return '';
    const p = catalog && (catalog.props || []).find((x) => x.model === model);
    return p && p.name ? p.name : model;
}

// ---- normalising ----

function normalize(raw) {
    containers = {};
    const add = (c) => { if (c && c.containerId) containers[String(c.containerId)] = c; };
    if (Array.isArray(raw)) raw.forEach(add);
    else if (raw) Object.keys(raw).forEach((k) => add(raw[k]));
}

/* The whitelist as names, whichever of its two shapes it came in. whip reads a
   list — { 'food', 'drink' } — and a set — { food = true } — the same way (Stores.itemAllowedBy),
   and a set reaches this page as an object, not an array. A number key holding a string is a list
   entry (a mixed table); any other key is the name itself. */
function allowedNames(a) {
    if (!a) return [];
    if (Array.isArray(a)) return a.map(String);
    if (typeof a !== 'object') return [];
    return Object.keys(a).map((k) => (/^\d+$/.test(k) && typeof a[k] === 'string') ? a[k] : k);
}

// ---- drafts ----

function newDraft(pos) {
    return {
        editing: null,
        name: '',
        type: 'stash',
        prop: DEFAULT_PROP,
        noProp: false,
        spot: null,
        here: pos || null,   // where the admin stood when the section opened: Where's "here"
        slots: 20,
        maxWeight: 100,
        openBy: 'anyone',
        access: [],          // the charIds who may open it, when openBy is 'one' (Specific players only)
        owner: 0,
        onlyItems: false,
        allowed: [],
    };
}

function draftFrom(c) {
    const allowed = allowedNames(c.allowedItems);
    const access = [...new Set((Number(c.accessCharId) > 0 ? [Number(c.accessCharId)] : []).concat(ruleIds(c.requirements)))];
    return {
        editing: String(c.containerId),
        name: c.name || '',
        type: c.type || 'stash',
        prop: c.prop === false ? '' : (c.prop || DEFAULT_PROP),
        noProp: c.prop === false,   // a Director run's container in a room with its own safe: no prop
        placed: c.placed === true,  // stands exactly at its spot, not snapped to the ground (client/containers.lua)
        spot: { x: Number(c.x) || 0, y: Number(c.y) || 0, z: Number(c.z) || 0, heading: Number(c.heading) || 0 },
        here: null,
        slots: Number(c.slots) || 20,
        maxWeight: Number(c.maxWeight) || 100,
        openBy: c.locked ? 'nobody' : (access.length ? 'one' : 'anyone'),
        access,
        owner: Number(c.ownerCharId) || 0,
        onlyItems: allowed.length > 0,
        allowed,
        requirements: c.requirements || null,
    };
}

const PARTS = ['name', 'type', 'prop', 'spot', 'slots', 'maxWeight', 'openBy', 'access', 'owner', 'onlyItems', 'allowed'];

function snapshot(d) {
    const out = {};
    for (const k of PARTS) out[k] = d[k];
    return JSON.parse(JSON.stringify(out));
}

/** The parts of a container being changed that differ from it as it is, by step. */
function changedParts(d) {
    const out = new Set();
    const o = d && d.original;
    if (!o) return out;
    if (d.name.trim() !== o.name.trim() || d.type !== o.type) out.add('name');
    if (d.prop !== o.prop) out.add('model');
    const a = d.spot || {}, b = o.spot || {};
    if (Math.abs(a.x - b.x) > 0.005 || Math.abs(a.y - b.y) > 0.005 || Math.abs(a.z - b.z) > 0.005
        || Math.abs(a.heading - b.heading) > 0.05) out.add('where');
    if (Number(d.slots) !== Number(o.slots) || Number(d.maxWeight) !== Number(o.maxWeight)) out.add('holds');
    const sameIds = (x, y) => x.slice().sort((m, n) => m - n).join() === y.slice().sort((m, n) => m - n).join();
    if (d.openBy !== o.openBy || (d.openBy === 'one' && !sameIds(d.access, o.access)) || d.owner !== o.owner) out.add('access');
    if (d.onlyItems !== o.onlyItems || (d.onlyItems && d.allowed.slice().sort().join() !== o.allowed.slice().sort().join())) out.add('items');
    return out;
}

// ---- a container, said in words: its page and the wizard's last step share these ----

/** Which way it faces: where it is, the map under the row shows (WP.place). */
function spotText(p) {
    return p ? 'facing ' + fixed(p.heading, 0) + '°' : '';
}

function openText(d, then) {
    if (d.openBy === 'nobody') return 'admin only: locked (an admin can, from here)';
    if (d.openBy === 'one') {
        if (!d.access.length) return 'specific players, none picked yet';
        const names = d.access.slice(0, 3).map((id) => personText(id, then));
        return 'only ' + names.join(', ') + (d.access.length > 3 ? ', and ' + (d.access.length - 3) + ' more' : '');
    }
    return 'anyone near it';
}

function itemsText(d) {
    if (!d.onlyItems) return 'anything';
    if (!d.allowed.length) return 'only the items picked: none yet';
    const names = d.allowed.slice(0, 4).map((k) => (items && items[k] && items[k].name) || k);
    return 'only ' + names.join(', ') + (d.allowed.length > 4 ? ', and ' + (d.allowed.length - 4) + ' more' : '');
}

/** One row per part, each with `rowOpts(stepKey)`'s button (Change). `changed` marks what a Save writes. `noMap`: the
 *  page shows its map beside the rows instead (a container's page), so none under Where. */
function summaryRows(body, d, rowOpts, changed, then, noMap) {
    const mark = (key, text) => (changed && changed.has(key) ? text + '  ·  changed' : text);
    const row = (label, key, status, detail) => {
        body.appendChild(WP.statusRow({ label, status, detail: mark(key, detail), ...rowOpts(key) }));
    };
    // Every one made here is a stash; one a script made as something else still says so.
    row('Name', 'name', d.name.trim() ? 'ok' : 'err', (d.name.trim() || 'none') + (d.type && d.type !== 'stash' ? '  ·  ' + d.type : ''));
    row('Model', 'model', d.prop || d.noProp ? 'ok' : 'err',
        d.noProp && !d.prop ? 'no prop: only its prompt' : propName(d.prop) + (propName(d.prop) !== d.prop ? '  ·  ' + d.prop : ''));
    row('Where', 'where', d.spot ? 'ok' : 'err', d.spot ? spotText(d.spot) : 'not set');
    if (d.spot && !noMap) body.appendChild(WP.place({ x: d.spot.x, y: d.spot.y, name: d.name.trim() || 'The container' }));
    row('Holds', 'holds', 'ok', plural(Number(d.slots), 'slot') + ', up to ' + fixed(d.maxWeight, 0) + ' kg');
    row('Who can open it', 'access', d.openBy === 'one' && !d.access.length ? 'err' : d.openBy === 'nobody' ? 'warn' : 'ok', openText(d, then));
    row('Belongs to', 'access', d.owner ? 'ok' : 'off', d.owner ? personText(d.owner, then) : 'nobody in particular');
    row('Takes', 'items', d.onlyItems && !d.allowed.length ? 'err' : 'ok', itemsText(d));
    if (otherRules(d.requirements)) {
        body.appendChild(WP.statusRow({ label: 'Set by a resource', status: 'warn',
            detail: 'it also has rules a resource gave it (who may open it); those stay as they are' }));
    }
}

// ---- list ----

function propIcon(model) {
    const img = document.createElement('img');
    img.alt = '';
    img.width = 32;
    img.height = 32;
    img.loading = 'lazy';
    img.addEventListener('error', () => { img.style.visibility = 'hidden'; });
    img.src = propImageUrl(model || DEFAULT_PROP);
    return img;
}

function renderList() {
    els.list.innerHTML = '';
    const ids = Object.keys(containers).sort((a, b) => parseInt(a, 10) - parseInt(b, 10));
    let shown = 0;

    for (const id of ids) {
        const c = containers[id];
        const hay = (c.name + ' #' + c.containerId + ' ' + (c.type || '') + ' ' + (c.prop || '')).toLowerCase();
        if (search && !hay.includes(search)) continue;
        shown += 1;
        const row = WP.listItem({
            title: c.name || 'Container',
            sub: '#' + c.containerId + (c.type && c.type !== 'stash' ? ' · ' + c.type : '') + ' · ' + plural(Number(c.slots) || 0, 'slot'),
            pill: c.locked ? 'LOCKED' : null,
            pillClass: '',   // a plain state: neutral, the same LOCKED as doors and phones
            id: id,
            action: 'cmSelect',
        });
        row.classList.add('wp-has-icon');
        row.insertBefore(propIcon(c.prop === false ? null : c.prop), row.firstChild);
        if (selectedId === id) row.classList.add('active');
        els.list.appendChild(row);
    }

    if (shown === 0) {
        els.list.appendChild(WP.empty(search ? 'No containers match "' + search + '"' : 'No containers yet'));
    }
    els.count.textContent = shown + ' of ' + ids.length;
}

// ---- a container's page ----

function selectContainer(id) {
    if (!containers[String(id)]) return;
    selectedId = String(id);
    renderList();
    renderDetail();
}

function noContainer() {
    selectedId = null;
    renderList();
    renderDetail();
}

function renderDetail() {
    const body = els.detailBody;
    body.innerHTML = '';
    const c = selectedId && containers[selectedId];
    if (!c) {
        els.detailTitle.textContent = 'Containers';
        body.appendChild(WP.el('div', 'wp-hint',
            'Pick a container to change it, or set a new one up: the wizard walks you through its model, '
            + 'where it stands, what it holds and who can open it.'));
        const go = WP.el('div', 'wp-actions-row');
        go.appendChild(WP.btn('Set up a new container', 'cmNew', 'primary'));
        body.appendChild(go);
        return;
    }
    els.detailTitle.textContent = c.name || 'Container';
    const d = draftFrom(c);
    const again = () => { if (selectedId === String(c.containerId) && !draft) renderDetail(); };
    // The props' names, and the items' (for Takes): read once, then this page again.
    if (!catalog) loadCatalog().then((cat) => { if (cat) again(); });
    if (d.onlyItems && !items) loadItems().then((it) => { if (it) again(); });

    const split = WP.el('div', 'wp-info-split');
    const left = WP.el('div');
    left.style.flex = '1';
    left.style.minWidth = '0';
    left.appendChild(WP.el('div', 'wp-item-sub', 'Container #' + c.containerId + '  ·  Change opens the wizard on that part'));
    summaryRows(left, d, (key) => ({ action: 'cmEdit', arg: key, actionLabel: 'Change' }), null, again, true);
    split.appendChild(left);
    // On the right, its picture and, under it, where it is on the map (Josh: out from under Where).
    const side = WP.el('div', 'cw-detail-side');
    side.appendChild(propPortrait(d.prop, true, 'box'));
    if (d.spot) side.appendChild(WP.place({ x: d.spot.x, y: d.spot.y, name: d.name.trim() || 'The container' }));
    split.appendChild(side);
    body.appendChild(split);

    // Destructive far-left, the rest far-right — Delete never neighbours the others.
    const actions = WP.el('div', 'wp-actions-row');
    actions.appendChild(WP.btn('Delete', 'cmDelete', 'danger'));
    actions.appendChild(WP.el('span', 'wp-actions-split'));
    actions.appendChild(WP.btn('Teleport there', 'cmTeleport'));
    actions.appendChild(WP.btn('Open it', 'cmOpenContainer'));
    actions.appendChild(WP.btn('Change everything', 'cmEdit', 'primary', 'name'));
    body.appendChild(actions);
}

// ========================================
// THE WIZARD
// ========================================

function wizardOpen() { return !!draft; }

function showView() {
    if (!els.listView) return;
    els.listView.style.display = wizardOpen() ? 'none' : '';
    els.wizView.style.display = wizardOpen() ? '' : 'none';
}

function openWizard() {
    draft = newDraft(els.here);
    buildWizard('name');
    showView();
}

/** Change a container: the wizard, filled in with it, on the part asked for. */
function openEdit(id, at) {
    const c = containers[String(id)];
    if (!c) return;
    draft = draftFrom(c);
    draft.original = snapshot(draft);
    buildWizard(at);
    showView();
}

function closeWizard() {
    draft = null;
    wiz = null;
    wizAt = 'name';
    if (els.wizBody) els.wizBody.innerHTML = '';
    showView();
}

function draftTouched() {
    if (!draft) return false;
    if (draft.editing) return changedParts(draft).size > 0;
    return !!(draft.name.trim() || draft.spot || draft.prop !== DEFAULT_PROP || draft.allowed.length);
}

async function discardWizard() {
    if (draftTouched()) {
        const editing = !!draft.editing;
        const ok = await WP.confirm({
            title: editing ? 'Stop changing this container?' : 'Throw this container away?',
            body: editing ? 'Nothing you changed here is saved.' : 'Nothing has been made yet. Everything you set up for it goes.',
            confirmLabel: editing ? 'Stop' : 'Throw away', danger: true,
        });
        if (!ok) return;
    }
    closeWizard();
}

function buildWizard(at) {
    els.wizBody.innerHTML = '';
    wiz = WP.stepper({
        id: 'cm-wizard',
        steps: STEPS,
        onGo: (k, from, body) => { wizAt = k; fillStep(k, body); },
        canLeave: (from) => canLeave(from),
        onFinish: finish,
        finishLabel: draft.editing ? 'Save changes' : 'Create container',
    });
    els.wizBody.appendChild(wiz.root);
    const target = STEPS.some((s) => s.key === stepOf(at)) ? stepOf(at) : 'name';
    if (draft.editing) {
        wiz.start('review');                 // the last step reached: every step can be jumped to
        if (target !== 'review') wiz.go(target);
    } else {
        wiz.start(target);
    }
    renderWizHead();
}

function renderWizHead() {
    const name = draft && draft.name.trim();
    els.wizTitle.textContent = draft && draft.editing
        ? 'Change — ' + (name || 'Container #' + draft.editing)
        : 'New container' + (name ? ' — ' + name : '');
    els.wizDiscard.textContent = draft && draft.editing ? 'Cancel' : 'Discard';
}

function fillStep(key, body) {
    if (!draft) return;
    body.innerHTML = '';
    const fill = { name: stepNameModel, where: stepWhere, holds: stepHolds,
                   access: stepAccess, items: stepItems, review: stepReview }[key];
    if (fill) fill(body);
}

function redrawStep() {
    if (wiz && wiz.current()) fillStep(wiz.current(), wiz.body);
}

function hint(body, text) {
    const el = WP.el('div', 'wp-hint', text);
    body.appendChild(el);
    return el;
}

/** A row of choice cards (.wp-choice): `list` of { key, title, text }, the one `value` picked. */
function choices(body, list, value, action) {
    const row = WP.el('div', 'wp-choices');
    for (const k of list) {
        const b = WP.el('button', 'wp-choice' + (value === k.key ? ' active' : ''));
        b.type = 'button';
        b.dataset.action = action;
        b.dataset.arg = k.key;
        b.appendChild(WP.el('span', 'wp-choice-title', k.title));
        if (k.text) b.appendChild(WP.el('span', 'wp-choice-text', k.text));
        row.appendChild(b);
    }
    body.appendChild(row);
    return row;
}

// ---- step: name & model ----

/** Its name's box, as the props' search looks (an icon, and what to type in it). */
function nameField() {
    const box = iconInput({ icon: 'name', placeholder: 'Name container…', value: draft.name, inputAction: 'cwName' });
    box.querySelector('input').maxLength = 100;
    return box;
}

/** Its name and its prop on one page (Josh): the name, the props' search and a model typed on one row, then the props
 *  as the new-vehicle wizard shows its cars. */
function stepNameModel(body) {
    if (draft.noProp && !draft.prop) {
        body.appendChild(WP.statusRow({ label: 'No prop', status: 'warn',
            detail: 'it was made with no prop (only its prompt shows): pick one to give it one' }));
    }
    if (!catalog) {
        body.appendChild(nameField());
        hint(body, 'Reading the props…');
        loadCatalog().then((cat) => {
            if (wiz && wiz.current() === 'name') {
                if (cat) redrawStep();
                else { body.innerHTML = ''; stepModelTyped(body); }
            }
        });
        return;
    }
    const pick = propPicker({
        id: 'cw-props',
        catalog,
        value: draft.prop,
        first: 'crates',
        lead: nameField(),
        onPick: (m) => { draft.prop = m; },
    });
    body.appendChild(pick.root);
    // A new one starts at its name.
    if (!draft.name.trim()) {
        setTimeout(() => { const i = body.querySelector('[data-input="cwName"]'); if (i) i.focus(); }, 0);
    }
}

/** No catalog to show (it never arrived): the model by name. */
function stepModelTyped(body) {
    const top = WP.el('div', 'wp-pick-top');
    top.appendChild(nameField());
    top.appendChild(iconInput({ icon: 'model', placeholder: 'Input model name…', value: draft.prop, inputAction: 'cwProp' }));
    body.appendChild(top);
    hint(body, 'The props\' pictures could not be read, so type the model\'s name.');
}

// ---- step: where ----

function stepWhere(body) {
    body.appendChild(WP.statusRow({ label: 'Where', status: draft.spot ? 'ok' : 'todo',
        detail: draft.spot ? spotText(draft.spot) : 'not set yet' }));
    if (draft.spot) body.appendChild(WP.place({ x: draft.spot.x, y: draft.spot.y, name: draft.name.trim() || 'The container' }));
    const row = WP.el('div', 'wp-actions-row');
    if (draft.spot) row.appendChild(WP.btn('Teleport there', 'cwTeleport'));
    row.appendChild(WP.el('span', 'wp-actions-split'));
    row.appendChild(WP.btn('Where I stand', 'cwHere'));
    row.appendChild(WP.btn(draft.spot ? 'Place it again' : 'Place it in the world', 'cwPlace', 'primary'));
    body.appendChild(row);
    hint(body, 'Place it in the world: the panel steps aside and a see-through '
        + (propName(draft.prop) || 'copy') + ' goes where you aim. The card at the top right says the keys.');
}

// ---- step: holds ----

/** Holds' right side: the container as the inventory will show it opened, at the size set. */
function holdsPreview() {
    const slots = Math.min(1000, Math.max(1, Math.round(Number(draft.slots)) || 1));
    return inventoryPreview({ title: draft.name.trim() || 'New container', slots, kg: Math.max(0, Number(draft.maxWeight) || 0) });
}

function redrawHoldsPreview() {
    if (!els.cwPreview || !els.cwPreview.isConnected) return;
    els.cwPreview.innerHTML = '';
    els.cwPreview.appendChild(holdsPreview());
}

function stepHolds(body) {
    const split = WP.el('div', 'cw-split');
    const left = WP.el('div', 'cw-left');
    const right = WP.el('div', 'cw-right');
    split.appendChild(left);
    split.appendChild(right);
    body.appendChild(split);

    const size = SIZES.find((s) => s.slots === Number(draft.slots) && s.weight === Number(draft.maxWeight));
    choices(left, SIZES.map((s) => ({ key: s.key, title: s.title, text: s.slots + ' slots, up to ' + s.weight + ' kg' })),
        size ? size.key : '', 'cwSize');
    const cols = WP.el('div', 'wp-cols-2');
    const slots = WP.input({ type: 'number', value: draft.slots, inputAction: 'cwSlots' });
    slots.min = 1; slots.max = 1000;
    const weight = WP.input({ type: 'number', value: draft.maxWeight, inputAction: 'cwWeight' });
    weight.min = 0; weight.max = 10000;
    cols.appendChild(WP.field('Slots', slots));
    cols.appendChild(WP.field('Max kg', weight));
    left.appendChild(cols);
    hint(left, 'Or set your own: 1 to 1,000 slots, up to 10,000 kg.');

    right.appendChild(WP.el('div', 'wp-section-title', 'Opened, it looks like this'));
    els.cwPreview = WP.el('div');
    els.cwPreview.appendChild(holdsPreview());
    right.appendChild(els.cwPreview);
}

// ---- step: access ----

/** Which of the two the list on the right picks: 'access' (who can open it) or 'owner' (whose it is). */
let whoFor = 'access';

/** One of the two, on the left: the face and name of who is picked, or that nobody is. A click points the list at it.
 *  `sub`: what it says under its name (who is picked, or what to do). */
function whoRow(key, label, faceId, sub, clearAction) {
    const row = WP.el('div', 'wp-list-item wp-has-icon cw-who' + (whoFor === key ? ' active' : ''));
    row.dataset.action = 'cwWho';
    row.dataset.arg = key;
    const name = faceId ? charName(faceId, paintAccess) : '';
    row.appendChild(avatar(name || (faceId ? '#' + faceId : ''), undefined, faceId || undefined));
    const top = WP.el('div', 'wp-item-top');
    top.appendChild(WP.el('span', 'wp-item-title', label));
    if (clearAction) top.appendChild(WP.btn('Clear', clearAction, 'ghost'));
    row.appendChild(top);
    row.appendChild(WP.el('div', 'wp-item-sub', sub));
    return row;
}

/** A picked one's row (a player, an item): its picture and name. Over the picture it turns red and the name asks
 *  "Remove?"; a click on the picture runs `action` with `arg` (Josh: no Remove button). */
function removableRow(picture, name, action, arg, round) {
    const row = WP.el('div', 'cw-picked-row');
    const photo = WP.el('button', 'cw-picked-photo' + (round ? ' cw-picked-face' : ''));
    photo.type = 'button';
    photo.dataset.action = action;
    photo.dataset.arg = arg;
    photo.setAttribute('aria-label', 'Remove ' + name);
    photo.appendChild(picture);
    const label = WP.el('span', 'cw-picked-name', name);
    photo.addEventListener('mouseenter', () => { label.textContent = 'Remove?'; row.classList.add('cw-removing'); });
    photo.addEventListener('mouseleave', () => { label.textContent = name; row.classList.remove('cw-removing'); });
    row.appendChild(photo);
    row.appendChild(label);
    return row;
}

/** One player who can open it, under its row. */
function accessRow(id) {
    const name = charName(id, paintAccess);
    return removableRow(avatar(name || '#' + id, undefined, id), (name || 'Character') + '  #' + id, 'cwUnaccess', String(id), true);
}

/** Access's left column below the choices, and the list's title and lit rows: after a pick, in place, so the list keeps
 *  its scroll and its search. */
function paintAccess() {
    if (!els.cwWho || !els.cwWho.isConnected) return;
    els.cwWho.innerHTML = '';
    if (draft.openBy === 'one') {
        const n = draft.access.length;
        els.cwWho.appendChild(whoRow('access', 'Can open it', draft.access[0],
            n ? plural(n, 'player') + (whoFor === 'access' ? ': click in the list to add or take away' : ': click to add more')
              : whoFor === 'access' ? 'nobody yet: pick from the list' : 'nobody yet: click to pick',
            n ? 'cwClearAccess' : null));
        for (const id of draft.access) els.cwWho.appendChild(accessRow(id));
    }
    els.cwWho.appendChild(whoRow('owner', 'Belongs to (optional)', draft.owner,
        draft.owner ? personText(draft.owner, paintAccess)
            : whoFor === 'owner' ? 'nobody yet: pick from the list' : 'nobody yet: click to pick',
        draft.owner ? 'cwClearOwner' : null));
    els.cwWhoTitle.textContent = whoFor === 'access' ? 'Pick who can open it' : 'Pick whose it is';
    if (els.cwPeople) els.cwPeople.refresh();
}

function stepAccess(body) {
    if (draft.openBy !== 'one' && whoFor === 'access') whoFor = 'owner';
    const split = WP.el('div', 'cw-split');
    const left = WP.el('div', 'cw-left');
    const right = WP.el('div', 'cw-right');
    split.appendChild(left);
    split.appendChild(right);
    body.appendChild(split);

    choices(left, OPEN_BY, draft.openBy, 'cwOpenBy');
    left.appendChild(WP.el('div', 'wp-section-title', 'Who'));
    els.cwWho = WP.el('div', 'cw-who-list');   // not a .wp-list: that scrolls on its own; the column scrolls instead
    left.appendChild(els.cwWho);
    hint(left, 'Belongs to is a record, for you and for scripts. Who can open it is the rule above.');

    els.cwWhoTitle = WP.el('div', 'wp-section-title');
    right.appendChild(els.cwWhoTitle);
    els.cwPeople = personList({
        id: 'cw-people',
        picked: (id) => (whoFor === 'access' ? draft.access.indexOf(id) >= 0 : id === draft.owner),
        onPick: (p) => {
            charNames[p.charId] = p.name;
            if (whoFor === 'access') {
                // Several: a click adds them, a click again takes them off.
                const at = draft.access.indexOf(p.charId);
                if (at >= 0) draft.access.splice(at, 1); else draft.access.push(p.charId);
            } else {
                draft.owner = p.charId;
            }
            paintAccess();
        },
        onLoad: paintAccess,   // the two rows' names, now known
    });
    right.appendChild(els.cwPeople.root);
    paintAccess();
}

// ---- step: items ----

/** One item picked: its picture and its name (removableRow, above). */
function pickedRow(k) {
    const img = document.createElement('img');
    img.alt = '';
    img.dataset.itemImg = '';   // the item icon's own two-step fallback (utils.js)
    img.dataset.itemKey = k;
    img.src = itemImageUrl(k, items[k] && items[k].img);
    return removableRow(img, (items[k] && items[k].name) || k, 'cwUnpick', k, false);
}

/** Items' side column: the choice, then the items picked. */
function paintItemsSide() {
    const side = els.cwItemsSide;
    if (!side || !side.isConnected) return;
    side.innerHTML = '';
    choices(side, [
        { key: 'any', title: 'Anything', text: 'It takes whatever fits.' },
        { key: 'only', title: 'Only the items picked', text: 'Pick them from the pictures. Anything else is refused.' },
    ], draft.onlyItems ? 'only' : 'any', 'cwOnly');
    if (!draft.onlyItems || !draft.allowed.length) return;
    const scroll = WP.el('div', 'wp-pick-scroll');
    const list = WP.el('div', 'cw-picked');
    for (const k of draft.allowed) list.appendChild(pickedRow(k));
    scroll.appendChild(list);
    side.appendChild(scroll);
}

function stepItems(body) {
    if (!items) {
        hint(body, 'Reading the items…');
        loadItems().then((it) => { if (it && wiz && wiz.current() === 'items') redrawStep(); });
        return;
    }
    els.cwItemsSide = WP.el('div', 'cw-items-side');
    els.cwItemsSide.style.cssText = 'display:flex;flex-direction:column;min-height:0;flex:1';
    els.cwItems = itemPicker({
        id: 'cw-items',
        items,
        picked: (k) => draft.onlyItems && draft.allowed.indexOf(k) >= 0,
        onToggle: (k) => {
            // A picture picked while it takes anything: it takes only the picked from now.
            if (!draft.onlyItems) draft.onlyItems = true;
            const at = draft.allowed.indexOf(k);
            if (at >= 0) draft.allowed.splice(at, 1); else draft.allowed.push(k);
            els.cwItems.refresh();
            paintItemsSide();
        },
        side: [els.cwItemsSide],
    });
    body.appendChild(els.cwItems.root);
    paintItemsSide();
}

// ---- step: review ----

function stepReview(body) {
    const changed = draft.editing ? changedParts(draft) : null;
    if (draft.onlyItems && !items) loadItems().then((it) => { if (it && wiz && wiz.current() === 'review') redrawStep(); });
    summaryRows(body, draft, (key) => ({ action: 'cwJump', arg: key, actionLabel: 'Change' }), changed, redrawStep);
    const last = draft.editing
        ? hint(body, changed.size ? 'Save changes writes what changed. A new model or spot moves the prop at once.'
            : 'Nothing has changed yet: Change any part above.')
        : hint(body, 'Create makes it at once: the prop appears where you put it, ready to open.');
    last.classList.add('wp-apart');
}

// ---- leaving a step, and saving ----

function canLeave(from) {
    const d = draft;
    if (!d) return 'There is no container being set up';
    if (from === 'name') {
        if (!d.name.trim()) return 'Give it a name';
        return d.prop || d.noProp ? true : 'Pick its model';
    }
    if (from === 'where') return d.spot ? true : 'Put it somewhere';
    if (from === 'holds') {
        const s = Number(d.slots), w = Number(d.maxWeight);
        if (!(Number.isInteger(s) && s >= 1 && s <= 1000)) return 'Slots is a whole number, 1 to 1,000';
        if (!(w >= 0 && w <= 10000)) return 'Max weight is 0 to 10,000 kg';
        return true;
    }
    if (from === 'access') return d.openBy !== 'one' || d.access.length ? true : 'Pick at least one player who can open it';
    if (from === 'items') return !d.onlyItems || d.allowed.length ? true : 'Pick at least one item, or let it take anything';
    return true;
}

function firstProblem() {
    for (const s of STEPS) {
        if (s.key === 'review') continue;
        const why = canLeave(s.key);
        if (why !== true) return { key: s.key, why };
    }
    return null;
}

/** Its rules as saved: a resource's own kept, and who may open it as their charIds. `false` clears them. Admin only
 *  keeps its players, so unlocking it later hands it back to them. */
function rulesOf(d) {
    const others = otherRules(d.requirements);
    if (d.openBy === 'anyone' || !d.access.length) return others || false;
    return Object.assign({}, others || {}, { charIds: d.access.slice() });
}

/** What the server is sent (client/containers.lua passes it on). */
function payloadOf(d) {
    return {
        containerId: d.editing,
        name: d.name.trim(),
        type: d.type || 'stash',
        slots: Number(d.slots),
        maxWeight: Number(d.maxWeight),
        ownerCharId: d.owner || 0,
        // Who may open it is its rules' list now; the one-character column is cleared (its player is in the list).
        accessCharId: 0,
        requirements: rulesOf(d),
        locked: d.openBy === 'nobody',
        // A container made with no prop, still with none picked, keeps having none.
        prop: d.prop || (d.editing ? undefined : DEFAULT_PROP),
        x: d.spot.x, y: d.spot.y, z: d.spot.z, heading: d.spot.heading,
        allowedItems: d.onlyItems ? d.allowed.slice() : [],
    };
}

function finish() {
    const d = draft;
    if (!d) return;
    if (d.editing && !changedParts(d).size) {
        wiz.say('Nothing has changed', 'err');
        return;
    }
    const problem = firstProblem();
    if (problem) {
        wiz.setStatus(problem.key, 'error');
        wiz.say(problem.why, 'err');
        return;
    }
    const payload = payloadOf(d);
    if (d.editing) {
        nuiCallback('cmUpdateContainer', payload);
        // An unsent prop (one with none keeps none) must not wipe the kept `false`.
        const kept = Object.assign({}, payload);
        if (kept.prop === undefined) delete kept.prop;
        containers[d.editing] = Object.assign(containers[d.editing] || {}, kept, { containerId: Number(d.editing) });
        const id = d.editing;
        closeWizard();
        selectContainer(id);
    } else {
        // Made on the server, which answers with the container: it is opened when that arrives.
        nuiCallback('cmCreateContainer', payload);
        pendingSelect = true;
        closeWizard();
        noContainer();
    }
}

// ---- the section ----

WhipPanel.registerSection({
    id: 'containers',
    group: 'economy',
    label: 'Containers',
    order: 30,

    render(root) {
        els = {};

        // ---- the wizard, in the list's place while a container is set up or changed. First in the
        // section, so the shell's '/' finds a picker's search before the list's. ----
        els.wizView = WP.el('div', 'wp-section-solo wp-section-wide');
        els.wizView.style.display = 'none';
        const head = WP.el('div', 'wp-actions-row wp-head-row');
        els.wizTitle = WP.el('div', 'wp-pane-title', 'New container');
        head.appendChild(els.wizTitle);
        head.appendChild(WP.el('span', 'wp-actions-split'));
        els.wizDiscard = WP.btn('Discard', 'cwDiscard', 'ghost');
        head.appendChild(els.wizDiscard);
        els.wizView.appendChild(head);
        els.wizBody = WP.el('div', 'wp-view');
        els.wizView.appendChild(els.wizBody);
        root.appendChild(els.wizView);

        els.listView = WP.el('div', 'wp-view');
        els.listView.appendChild(WP.toolbar({
            left: [WP.btn('+ New Container', 'cmNew')],
            search: { inputAction: 'cmSearch', placeholder: 'Search containers…' },
        }));
        const split = WP.el('div', 'wp-split');
        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);
        const detail = WP.el('div', 'wp-detail');
        els.detailTitle = WP.el('div', 'wp-pane-title', 'Containers');
        detail.appendChild(els.detailTitle);
        els.detailBody = WP.el('div');
        detail.appendChild(els.detailBody);
        split.appendChild(detail);
        els.listView.appendChild(split);
        root.appendChild(els.listView);

        renderList();
        renderDetail();
        // The panel is built again each time it opens: a container half set up comes back where it was.
        if (draft) buildWizard(wizAt);
        showView();
    },

    onData(kind, payload) {
        if (kind === 'all') {
            normalize(payload.containers);
            if (payload.pos) els.here = { x: payload.pos.x, y: payload.pos.y, z: payload.pos.z, heading: payload.pos.h };
            if (selectedId && !containers[selectedId]) selectedId = null;
            renderList();
            if (!wizardOpen()) renderDetail();
        } else if (kind === 'created' && payload && payload.containerId) {
            containers[String(payload.containerId)] = payload;
            if (pendingSelect && !wizardOpen()) {
                pendingSelect = false;
                WP.result('Container created: #' + payload.containerId, 'ok');
                selectContainer(payload.containerId);
            } else {
                renderList();
            }
        } else if (kind === 'spot' && draft) {
            // Where: placed in the world (tools/panel_sections/containers.lua cmPlace).
            draft.spot = { x: Number(payload.x), y: Number(payload.y), z: Number(payload.z), heading: Number(payload.heading) };
            if (wiz && wiz.current() === 'where') redrawStep();
        }
    },

    onEscape() {
        if (wizardOpen()) {
            // Changing one: back to the summary of what changed first, then out.
            if (draft.editing && wiz && wiz.current() !== 'review') { wiz.go('review'); return true; }
            // Setting one up: a step back at a time; on the first, Escape offers to throw it away.
            if (draft.editing || !(wiz && wiz.escape())) discardWizard();
            return true;
        }
        if (selectedId !== null) { noContainer(); return true; }
        return false;
    },

    actions: {
        cmSearch: (el) => { search = el.value.toLowerCase(); renderList(); },
        cmNew: () => openWizard(),
        cmSelect: (el) => selectContainer(el.dataset.id),
        cmEdit: (el) => { if (selectedId) openEdit(selectedId, el.dataset.arg); },
        cmDelete: async () => {
            if (!selectedId) return;
            const c = containers[selectedId];
            const ok = await WP.confirm({
                title: 'Delete container?',
                body: `#${selectedId} "${c ? c.name : ''}" and everything in it will be removed.`,
                confirmLabel: 'Delete',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('cmDeleteContainer', { containerId: selectedId });
            delete containers[selectedId];
            noContainer();
        },
        cmTeleport: () => {
            const c = selectedId && containers[selectedId];
            if (c) nuiCallback('cmTeleport', { x: c.x, y: c.y, z: c.z });
        },
        cmOpenContainer: () => {
            if (!selectedId) return;
            // Inventory handoff v1: the shell closes (Lua side), the inventory opens.
            nuiCallback('cmOpenContainer', { containerId: parseInt(selectedId, 10) });
        },

        // ---- the wizard ----
        cwDiscard: () => discardWizard(),
        cwJump: (el) => { if (wiz) wiz.jump(stepOf(el.dataset.arg)); },
        cwName: (el) => { if (draft) { draft.name = el.value; renderWizHead(); } },
        cwProp: (el) => { if (draft) draft.prop = el.value.trim(); },
        cwPlace: () => {
            if (!draft) return;
            nuiCallback('cmPlace', { name: draft.name.trim(), prop: draft.prop || DEFAULT_PROP,
                heading: draft.spot ? draft.spot.heading : undefined, placed: !!draft.placed }).then((res) => {
                if (res && res.ok === false && wiz) wiz.say(res.why || 'It could not be placed', 'err');
            });
        },
        cwHere: () => {
            nuiCallback('cmGetPlayerPos', {}).then((pos) => {
                if (!draft || !pos || pos.x === undefined) return;
                draft.spot = { x: pos.x, y: pos.y, z: pos.z, heading: pos.h };
                redrawStep();
            });
        },
        cwTeleport: () => {
            const p = draft && draft.spot;
            if (p) nuiCallback('cmTeleport', { x: p.x, y: p.y, z: p.z });
        },
        cwSize: (el) => {
            const s = SIZES.find((x) => x.key === el.dataset.arg);
            if (!draft || !s) return;
            draft.slots = s.slots;
            draft.maxWeight = s.weight;
            redrawStep();
        },
        cwSlots: (el) => { if (draft) { draft.slots = parseInt(el.value, 10) || 0; redrawHoldsPreview(); } },
        cwWeight: (el) => { if (draft) { draft.maxWeight = parseFloat(el.value) || 0; redrawHoldsPreview(); } },
        cwOpenBy: (el) => {
            if (!draft) return;
            draft.openBy = el.dataset.arg;
            // One character: the list picks them first.
            if (draft.openBy === 'one') whoFor = 'access';
            redrawStep();
        },
        cwWho: (el) => { whoFor = el.dataset.arg === 'access' ? 'access' : 'owner'; paintAccess(); },
        cwClearAccess: () => { if (draft) { draft.access = []; whoFor = 'access'; paintAccess(); } },
        cwUnaccess: (el) => {
            if (!draft) return;
            const at = draft.access.indexOf(Number(el.dataset.arg));
            if (at >= 0) draft.access.splice(at, 1);
            paintAccess();
        },
        cwClearOwner: () => { if (draft) { draft.owner = 0; whoFor = 'owner'; paintAccess(); } },
        cwOnly: (el) => { if (draft) { draft.onlyItems = el.dataset.arg === 'only'; redrawStep(); } },
        cwUnpick: (el) => {
            if (!draft) return;
            const at = draft.allowed.indexOf(el.dataset.arg);
            if (at >= 0) draft.allowed.splice(at, 1);
            if (els.cwItems) els.cwItems.refresh();
            paintItemsSide();
        },
    },
});
