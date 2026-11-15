// ========================================
// /whip SECTION — Vehicles
//
// The list of the fleet, and one pane for the car picked (Josh, 12 Nov): its Info, always open (whose it is with
// their picture first, then what it is and where), and under it its verbs as cards (WP.verb), in four sets: WHIP
// Actions (its trunk and glovebox, garages, teleports, bringing it, its owner, keys), World Actions (eject, seat
// players, lock, a stat, freeze, the ignition's key), Fun Actions (explode, tyres, doors, fling, engine) and
// Destructive Actions (delete). A verb that needs something picked (a garage, a player, a stat) opens its form under
// its set, its card the chosen one, until it is done or Escape.
//
// LIVE DATA. The server broadcasts fresh rows ('rows') to every viewer whenever the
// fleet changes, and re-sends the selected car ('detail') after each action — nothing
// here is drawn optimistically, because an admin tool that shows you what it hoped
// would happen is worse than one that is a moment behind.
//
// Mutation callbacks (vmSelect, vmAction, vmActOn, vmSetStat…) live in tools/panel_sections/vehicles.lua; the
// server's half is server/vehicle_manager.lua.
//
// A NEW VEHICLE IS MADE WITH A WIZARD (the vehicle, the character, and where it goes), WP.stepper in the list's
// place as the garage and shop wizards are:
//
//   Vehicle  every model the catalog has, as pictures, a chip per class (pickers.js vehiclePicker; vmCatalog)
//   Owner    everyone in the game, you first, as the Player Manager lists them (vmOnlinePlayers); anyone else found
//            by name or character id (pickers.js personSearch)
//   Where    spawned here beside you (the default), or in a garage (any; a property's only if the owner may use it):
//            the choices on the left, the map on the right (your position, or the garage picked)
//   Create   the lot, checked, on the left; on the right the car's picture, the map and whose it will be. Then
//            whip_core:vmWizardCreate, and the page opens on the new car
//
// Its plate is made up for it and its trunk and glovebox are its model's (the Vehicle Adjustments page); its stats
// start at their defaults (its page edits them).
//
// With nothing picked, the pane offers it (Set up a new vehicle). The old two-box form went with the toolbar's
// + New vehicle; vmCreate stays for scripts.
// ========================================

import { WhipPanel, WP, VERB_GLYPHS } from '../whip-panel.js';
import { nuiCallback, vehicleImageUrl } from '../utils.js';
import { avatar, personSearch, vehiclePicker, VEHICLE_CLASSES, BLIP_COLOURS } from './pickers.js';
import { statValueText } from '../stat-display.js';
import { weightLine } from '../inventory.js';

let rows = [];           // the fleet, thin rows for the list
let selected = null;     // vehicleId currently open
let vehicle = null;      // the full snapshot for it
let garages = {};        // key -> garage def
let statDefs = [];       // registered vehicle stats
let search = '';
let searchMode = 'all';
let els = {};            // skeleton refs (built once)
let built = false;       // render() has run: onData may draw
let focusOn = null;      // a car to open on once the snapshot is in (onFocus: the object viewer)

let draft = null;        // the vehicle being set up, while the wizard is open
let wiz = null;          // its WP.stepper
let wizAt = 'vehicle';   // the step it is on, so the panel reopens there
let catalog = null;      // vmCatalog: { vehicles, storage: { defaults, models } }, read once
let catalogAsk = null;
let form = null;         // the verb whose form is open under its set (VERBS key), or null

/* A car's status as a few words and a tone (its dot here, its pill on a player's page), because that is what an
   admin is scanning for: out = ok, garaged = plain, impounded = warn. */
export function vehicleStatus(row) {
    if (row.session) return { text: 'street car', tone: 'ok' };
    if (row.state === 'impounded') return { text: 'impounded', tone: 'warn' };
    if (row.state === 'out') {
        return row.spawned
            ? { text: 'in the world', tone: 'ok' }
            : { text: 'out, not spawned', tone: 'ok' };
    }
    return { text: 'garaged', tone: '' };
}

// ---- the list ----

function matches(row) {
    if (!search) return true;
    const q = search.toLowerCase();
    const ownerHit = () =>
        String(row.owner && row.owner.charId || '').includes(q) ||
        (row.owner && row.owner.name || '').toLowerCase().includes(q);
    if (searchMode === 'plate') return (row.plate || '').toLowerCase().includes(q);
    if (searchMode === 'model') return (row.model || '').toLowerCase().includes(q)
        || (row.display || '').toLowerCase().includes(q);
    if (searchMode === 'owner') return ownerHit();
    return (
        (row.plate || '').toLowerCase().includes(q) ||
        (row.model || '').toLowerCase().includes(q) ||
        (row.display || '').toLowerCase().includes(q) ||
        String(row.vehicleId).includes(q) ||
        ownerHit()
    );
}

function renderList() {
    els.list.innerHTML = '';
    const shown = rows.filter(matches);
    els.count.textContent = shown.length + ' of ' + rows.length;

    if (!shown.length) {
        els.list.appendChild(WP.empty(search ? 'Nothing matches' : 'No vehicles'));
        return;
    }

    for (const row of shown) {
        const st = vehicleStatus(row);
        const item = WP.el('div', 'wp-list-item');
        item.dataset.id = row.vehicleId;
        item.dataset.action = 'vmSelect';

        const top = WP.el('div', 'wp-item-top');
        top.appendChild(WP.el('span', 'wp-dot' + (st.tone ? ' wp-dot-' + st.tone : '')));
        top.appendChild(WP.el('span', 'wp-item-title',
            (row.plate || '—') + ' · ' + (row.display || row.model || '?')));
        item.appendChild(top);

        // Owner-first sub line: "charId · name · where it is". The vehicle ID lives
        // in the Info group only, and online-ness is a detail-pane fact.
        const owner = row.session ? 'nobody'
            : (row.owner && row.owner.charId || '—')
                + ' · ' + (row.owner && row.owner.name || 'unknown');
        item.appendChild(WP.el('div', 'wp-item-sub', owner + ' · ' + st.text));

        if (row.vehicleId === selected) item.classList.add('active');
        els.list.appendChild(item);
    }
}

// ---- the detail pane ----

function infoRow(grid, label, value, mono) {
    grid.appendChild(WP.el('span', 'wp-info-label', label));
    grid.appendChild(WP.el('span', 'wp-info-value' + (mono ? ' wp-info-value-mono' : ''),
        value === null || value === undefined ? '—' : String(value)));
}

const garageName = (key) => (key && ((garages[key] && garages[key].name) || key)) || null;

/** Info, always open: whose it is first (their picture, name and character), then what it is and where, with its
 *  place on the map while it has one and its picture. */
function fillInfo(body) {
    body.innerHTML = '';
    const v = vehicle;
    const who = WP.el('div', 'vm-owner');
    if (v.session) {
        who.appendChild(avatar('?', undefined, null, true));
        const text = WP.el('div', 'vm-owner-text');
        text.appendChild(WP.el('div', 'vm-owner-name', 'Nobody'));
        text.appendChild(WP.el('div', 'wp-item-sub', 'A street car whip adopted: nothing about it is kept'));
        who.appendChild(text);
    } else {
        const o = v.owner || {};
        who.appendChild(avatar(o.name || '?', !!o.online, o.charId, true));
        const text = WP.el('div', 'vm-owner-text');
        text.appendChild(WP.el('div', 'vm-owner-name', o.name || 'Unknown'));
        text.appendChild(WP.el('div', 'wp-item-sub', 'Character #' + (o.charId || '?') + (o.online ? '  ·  in the game now' : '')));
        who.appendChild(text);
    }
    body.appendChild(who);

    // Text grid left, the car's picture filling the dead space on the right
    // (data-veh-img = utils.js's missing.png fallback for a model with no picture).
    const wrap = WP.el('div', 'wp-info-split');
    const grid = WP.el('div', 'wp-info-grid');
    infoRow(grid, 'Vehicle', v.displayName || v.model || '?');
    infoRow(grid, 'Plate', v.plate || '—', true);
    infoRow(grid, 'ID', '#' + v.vehicleId, true);
    infoRow(grid, 'Category', VEHICLE_CLASSES[v.class] || 'Not in the vehicle list');
    infoRow(grid, 'Garage', garageName(v.garage) || '—');
    infoRow(grid, 'Status', v.state === 'out' || v.session ? 'Out' : 'Garaged');
    if (v.occupants && v.occupants.length) {
        infoRow(grid, 'Occupants',
            v.occupants.map((o) => (o.name || o.source) + (o.seat === -1 ? ' (driving)' : ' (passenger)')).join(', '));
    }
    wrap.appendChild(grid);
    if (v.coords) wrap.appendChild(WP.place({ x: v.coords.x, y: v.coords.y, name: v.plate || 'The car' }));

    const img = WP.el('img', 'wp-info-media');
    img.dataset.vehImg = '';
    img.src = vehicleImageUrl(v.model);
    img.alt = v.displayName || v.model || '';
    wrap.appendChild(img);

    body.appendChild(wrap);
}

// ---- its verbs ----

const atlas = (name) => ((window.WhipGlyphs && window.WhipGlyphs.glyphs) || {})[name];
const notInWorld = (v) => (v.spawned ? null : v.state === 'out' ? 'Out, not in the world' : 'In its garage');
const street = (v) => (v.session ? 'A street car has none' : null);
const storageLine = (v, kind) => {
    const s = v.storage && v.storage[kind];
    return s ? weightLine(s.used || 0, s.maxWeight || 0) + '  ·  ' + s.slots + ' slots' : 'What is in it';
};

/* Every verb, in Josh's four sets. A verb: its glyph, its name (or a function of the car), what it says it does,
   `off(v)` a reason it cannot be used on this car now (its card dimmed, the reason its line), and what it does:
   `run` an action the server does at once (vmAction), `form` one that needs something picked first (a garage, a
   player, a stat), or `go` its own call. */
const VERBS = [
    { title: 'WHIP Actions', verbs: [
        { key: 'trunk', glyph: () => atlas('trunk_open'), name: 'Open Trunk', sub: (v) => storageLine(v, 'trunk'), go: 'storage' },
        { key: 'glovebox', glyph: () => VERB_GLYPHS.glovebox, name: 'Open Glovebox', sub: (v) => storageLine(v, 'glovebox'),
          off: (v) => (v.class === 13 ? 'A bicycle has none' : null), go: 'storage' },
        { key: 'store', glyph: () => atlas('garage'), name: 'Return to garage',
          sub: (v) => 'Into ' + (garageName(v.garage) || 'its garage'),
          off: (v) => street(v) || (v.state !== 'out' ? 'In ' + (garageName(v.garage) || 'its garage') + ' now' : null), run: 'store' },
        { key: 'moveGarage', glyph: () => VERB_GLYPHS.into, name: 'Move to specific garage', sub: () => 'Pick a garage',
          off: street, form: 'garage' },
        { key: 'tpMe', glyph: () => atlas('pin'), name: 'Teleport me to vehicle', sub: () => 'Beside it', off: notInWorld, go: 'tpMe' },
        { key: 'tpPlayer', glyph: () => atlas('target'), name: 'Teleport player to vehicle', sub: () => 'Pick a player beside it',
          off: notInWorld, form: 'online' },
        { key: 'bringMe', glyph: () => VERB_GLYPHS.bring, name: 'Bring to me',
          sub: (v) => (v.state === 'out' ? 'Moved beside you' : 'Out of its garage, beside you'), run: 'bringToMe' },
        { key: 'bringPlayer', glyph: () => atlas('give'), name: 'Bring to player', sub: () => 'Out beside a player', form: 'online' },
        { key: 'owner', glyph: () => atlas('id'), name: 'Change owner',
          sub: (v) => 'Now ' + ((v.owner && v.owner.name) || 'nobody'), off: street, form: 'anyone' },
        { key: 'keyMe', glyph: () => VERB_GLYPHS.key, name: 'Give me a key', sub: () => 'Into your pockets', run: 'giveKey' },
        { key: 'keyTo', glyph: () => VERB_GLYPHS.key, name: 'Give another player a key', sub: () => 'Into their pockets', form: 'online' },
    ] },
    { title: 'World Actions', verbs: [
        { key: 'ejectAll', glyph: () => VERB_GLYPHS.kick, name: 'Eject all players from vehicle',
          sub: (v) => (v.occupants && v.occupants.length ? v.occupants.length + ' in it now' : 'Everyone out of it'),
          off: notInWorld, run: 'ejectAll' },
        { key: 'warpIn', glyph: () => atlas('seat'), name: 'Teleport players into vehicle', sub: () => 'Into its free seats',
          off: notInWorld, form: 'online' },
        { key: 'lock', glyph: (v) => atlas(v.locked ? 'unlock' : 'lock'), name: (v) => (v.locked ? 'Unlock' : 'Lock'),
          sub: (v) => (v.locked ? 'Locked now' : 'Unlocked now'), run: (v) => (v.locked ? 'unlock' : 'lock') },
        { key: 'stat', glyph: () => atlas('turbo'), name: 'Change stat',
          sub: () => statDefs.map((d) => d.name).join(', '), off: () => (statDefs.length ? null : 'No stats registered'), form: 'stat' },
        { key: 'freeze', glyph: () => VERB_GLYPHS.freeze, name: (v) => (v.frozen ? 'Unfreeze vehicle position' : 'Freeze vehicle position'),
          sub: (v) => (v.frozen ? 'Held where it is now' : 'Held where it is'), off: notInWorld, run: 'freeze' },
        { key: 'removeKey', glyph: () => atlas('power'), name: 'Remove key from ignition', sub: () => 'Into your pockets',
          off: (v) => (v.ignitionKey ? null : 'No key in it'), run: 'removeKey' },
        { key: 'repair', glyph: () => VERB_GLYPHS.wrench, name: 'Repair', sub: () => 'Body, engine, tyres and dirt',
          off: notInWorld, run: 'repair' },
    ] },
    { title: 'Fun Actions', verbs: [
        { key: 'explode', glyph: () => VERB_GLYPHS.burst, name: 'Explode vehicle', sub: () => 'Up it goes', off: notInWorld, run: 'explode' },
        { key: 'tyres', glyph: () => VERB_GLYPHS.tyre, name: 'Deflate tyres', sub: () => 'Every tyre burst', off: notInWorld, run: 'tyres' },
        { key: 'doorsOpen', glyph: () => atlas('door'), name: 'Force open all doors', sub: () => 'The bonnet and the boot too',
          off: notInWorld, run: 'doorsOpen' },
        { key: 'doorsClose', glyph: () => atlas('trunk_closed'), name: 'Force close all doors', sub: () => 'Every one shut',
          off: notInWorld, run: 'doorsClose' },
        { key: 'fling', glyph: () => VERB_GLYPHS.fling, name: 'Fling vehicle into air', sub: () => 'Straight up', off: notInWorld, run: 'fling' },
        { key: 'engine', glyph: () => atlas('warning'), name: 'Destroy engine', sub: () => 'Dead, and burning', off: notInWorld, run: 'engine' },
    ] },
    { title: 'Destructive Actions', verbs: [
        { key: 'delete', glyph: () => VERB_GLYPHS.trash, name: 'Delete vehicle & inventory contents from whip database',
          sub: () => 'For good, with all it holds', danger: true, go: 'delete' },
    ] },
];
const VERB_BY_KEY = {};
for (const set of VERBS) for (const d of set.verbs) VERB_BY_KEY[d.key] = d;
const call = (x, v) => (typeof x === 'function' ? x(v) : x);

/** The form a verb opens, under its set: a garage list, a player search, or a stat and its number. */
function verbForm(d) {
    const v = vehicle;
    const box = WP.el('div', 'vm-form');
    if (d.form === 'garage') {
        box.appendChild(WP.el('div', 'wp-hint', v.state === 'out'
            ? 'It is put away in the one you pick (nobody may be in it).'
            : 'It is filed in the one you pick, and comes out there.'));
        const list = WP.el('div', 'wp-list wp-flush');
        const all = Object.keys(garages).sort((a, b) => String(garageName(a)).localeCompare(String(garageName(b))));
        if (!all.length) list.appendChild(WP.empty('No garages yet'));
        for (const key of all) {
            const now = key === v.garage;
            const item = WP.listItem({ title: garageName(key), sub: key + (garages[key].private ? '  ·  private' : ''),
                pill: now ? 'Now' : undefined, pillClass: 'wp-pill-accent', action: 'vmFormGarage' });
            item.dataset.arg = key;
            list.appendChild(item);
        }
        box.appendChild(list);
    } else if (d.form === 'stat') {
        const row = WP.el('div', 'vm-stat-row');
        const pick = WP.select(statDefs.map((s) => ({ value: s.name,
            label: s.name + '  (now ' + (v.stats && v.stats[s.name] != null ? Math.round(v.stats[s.name] * 10) / 10 : '—') + ')' })),
            { changeAction: 'vmStatPick' });
        els.statPick = pick;
        row.appendChild(WP.field('Stat', pick));
        els.statValue = WP.input({ type: 'number', enterAction: 'vmStatSet', inputAction: 'vmStatType' });
        els.statValue.step = '0.1';
        const valueField = WP.field('Value', els.statValue);
        els.statReads = WP.el('span', 'wp-field-hint', '');
        valueField.appendChild(els.statReads);
        row.appendChild(valueField);
        row.appendChild(WP.btn('Set', 'vmStatSet', 'primary'));
        box.appendChild(row);
        statFill();
    } else {
        box.appendChild(WP.el('div', 'wp-hint', d.form === 'anyone'
            ? 'Anyone, in the game or not: the car is theirs, and listed on their phone.'
            : d.key === 'warpIn' ? 'Players in the game now: each goes into its next free seat. Pick as many as you like.'
                : 'Players in the game now.'));
        const find = personSearch({
            placeholder: 'Type a name or a character id…',
            onPick: (p) => {
                if (!vehicle) return;
                nuiCallback('vmActOn', { vehicleId: vehicle.vehicleId, action: d.key === 'warpIn' ? 'warpIn' : d.key, arg: p.charId });
                if (d.key !== 'warpIn') { form = null; renderDetail(); }
            },
        });
        box.appendChild(find.root);
        setTimeout(() => find.focus(), 0);
    }
    return box;
}

/** The stat form's number: the picked stat's value now, and what it reads (its `display`: 14 psi, 92°C). */
function statFill() {
    const def = statDefs.find((s) => s.name === (els.statPick && els.statPick.value));
    if (!def || !els.statValue) return;
    const now = vehicle && vehicle.stats ? vehicle.stats[def.name] : null;
    els.statValue.value = now != null ? String(Math.round(now * 10) / 10) : '';
    if (def.min != null) els.statValue.min = def.min;
    if (def.max != null) els.statValue.max = def.max;
    els.statValue.placeholder = def.default != null ? 'default ' + def.default : '';
    statReads();
}

function statReads() {
    const def = statDefs.find((s) => s.name === (els.statPick && els.statPick.value));
    if (!els.statReads) return;
    els.statReads.textContent = '';
    if (!def || !def.display || !def.display.points) return;
    const lo = typeof def.min === 'number' ? def.min : 0;
    const hi = typeof def.max === 'number' && def.max > lo ? def.max : 100;
    const n = parseFloat(els.statValue.value !== '' ? els.statValue.value : def.default);
    if (Number.isFinite(n)) els.statReads.textContent = 'reads ' + statValueText(def.display, (n - lo) / (hi - lo));
}

/** The four sets, each a title and its cards three across, the open form under the set it belongs to. */
function fillVerbs(body) {
    body.innerHTML = '';
    els.statPick = els.statValue = els.statReads = null;
    const v = vehicle;
    for (const set of VERBS) {
        body.appendChild(WP.el('div', 'wp-section-title vm-verbs-title', set.title));
        const grid = WP.el('div', 'wp-verb-grid');
        let open = null;
        for (const d of set.verbs) {
            const card = WP.verb(call(d.glyph, v), call(d.name, v), 'vmVerb', d.danger, d.key);
            const why = d.off ? d.off(v) : null;
            card.disabled = !!why;
            card._sub.textContent = why || call(d.sub, v) || '';
            if (form === d.key && !why) { card.classList.add('active'); open = d; }
            grid.appendChild(card);
        }
        body.appendChild(grid);
        if (open) body.appendChild(verbForm(open));
    }
}

function renderDetail() {
    const has = !!vehicle;
    els.intro.style.display = has ? 'none' : '';
    els.detailWrap.style.display = has ? '' : 'none';
    if (!has) return;

    els.detailTitle.textContent = (vehicle.displayName || vehicle.model || '?')
        + ' — ' + (vehicle.plate || '—') + ' · #' + vehicle.vehicleId;
    fillInfo(els.infoBody);
    fillVerbs(els.verbsBody);
}

// ========================================
// THE WIZARD (see the header)
// ========================================

const STEPS = [
    { key: 'vehicle', label: 'Vehicle' }, { key: 'owner', label: 'Owner' },
    { key: 'where', label: 'Where' }, { key: 'review', label: 'Create' },
];

function newDraft() {
    return {
        model: '', owner: null,                  // owner: { charId, name, online }
        place: 'here', garage: '',               // spawned here beside you, unless a garage is chosen
        players: null,                           // who is in the game (vmOnlinePlayers), read when Owner opens
        here: null,                              // where you stand ({ x, y }: vwHere), read when Where opens
        saving: false,
    };
}

function wizardOpen() { return !!draft; }

/** The list, or the wizard while a vehicle is being set up. */
function showView() {
    if (!els.listView) return;
    els.listView.style.display = wizardOpen() ? 'none' : '';
    els.wizView.style.display = wizardOpen() ? '' : 'none';
}

/** The catalog, read once: every step that needs it draws again when it lands. */
function loadCatalog() {
    if (catalog || catalogAsk) return;
    catalogAsk = Promise.resolve(nuiCallback('vmCatalog', {})).then((res) => {
        catalogAsk = null;
        catalog = res && Array.isArray(res.vehicles) ? res : { vehicles: [], storage: {} };
        if (wiz && (wiz.current() === 'vehicle' || wiz.current() === 'review')) redrawStep();
    });
}

function carOf(model) {
    return (catalog && catalog.vehicles.find((c) => c.model === model)) || null;
}

function carName(model) {
    const c = carOf(model);
    return (c && c.name) || model || 'nothing';
}

function openWizard() {
    draft = newDraft();
    loadCatalog();
    buildWizard('vehicle');
    showView();
}

function closeWizard() {
    draft = null;
    wiz = null;
    wizAt = 'vehicle';
    if (els.wizBody) els.wizBody.innerHTML = '';
    if (els.wizRail) els.wizRail.innerHTML = '';
    showView();
}

async function discardWizard() {
    if (draft && (draft.model || draft.owner)) {
        const ok = await WP.confirm({
            title: 'Throw this vehicle away?',
            body: 'Nothing has been made yet. What you picked for it goes.',
            confirmLabel: 'Throw away', danger: true,
        });
        if (!ok) return;
    }
    closeWizard();
}

function buildWizard(at) {
    els.wizBody.innerHTML = '';
    els.wizRail.innerHTML = '';
    wiz = WP.stepper({
        id: 'vw-wizard',
        steps: STEPS,
        railInto: els.wizRail,
        onGo: (k, from, body) => {
            wizAt = k;
            // Read again on the way in: someone may have joined, and you may have walked off.
            if (draft && k === 'owner') draft.players = null;
            if (draft && (k === 'where' || k === 'review')) draft.here = null;
            fillStep(k, body);
        },
        canLeave: (from) => canLeave(from),
        onFinish: finish,
        finishLabel: 'Create vehicle',
    });
    els.wizBody.appendChild(wiz.root);
    wiz.start(STEPS.some((s) => s.key === at) ? at : 'vehicle');
    renderWizHead();
}

function renderWizHead() {
    els.wizTitle.textContent = 'New vehicle' + (draft && draft.model ? ' — ' + carName(draft.model) : '');
}

function fillStep(key, body) {
    if (!draft) return;
    body.innerHTML = '';
    const fill = { vehicle: stepVehicle, owner: stepOwner, where: stepWhere, review: stepReview }[key];
    if (fill) fill(body);
}

function redrawStep() {
    if (wiz && wiz.current()) fillStep(wiz.current(), wiz.body);
}

/** A step just answered: the refusal its Next left is wrong now. */
function answered(key) {
    if (!wiz) return;
    wiz.say('');
    wiz.setStatus(key, null);
}

function hint(body, text) {
    const el = WP.el('div', 'wp-hint', text);
    body.appendChild(el);
    return el;
}

function choice(action, arg, active, title, text) {
    const b = WP.el('button', 'wp-choice' + (active ? ' active' : ''));
    b.type = 'button';
    b.dataset.action = action;
    b.dataset.arg = arg;
    b.appendChild(WP.el('span', 'wp-choice-title', title));
    b.appendChild(WP.el('span', 'wp-choice-text', text));
    return b;
}

// ---- step: vehicle ----

function stepVehicle(body) {
    if (!catalog) {
        loadCatalog();
        body.appendChild(WP.empty('Reading the vehicle list…'));
        return;
    }
    if (!draft.pickState) draft.pickState = {};
    const pick = vehiclePicker({
        id: 'vw-cars',
        state: draft.pickState,   // the chip and the search last as long as this vehicle's set-up: a new one opens on All
        vehicles: catalog.vehicles,
        value: draft.model,
        onPick: (model) => { draft.model = model; answered('vehicle'); renderWizHead(); },
    });
    body.appendChild(pick.root);
}

// ---- step: owner ----

/** Who is in the game (vmOnlinePlayers): you first, then everyone else by name, as the Player Manager lists them.
 *  Read each time the step is gone to (buildWizard's onGo), so someone who joined meanwhile is there. */
function loadPlayers() {
    if (!draft || draft.playersAsk) return;
    const d = draft;
    d.playersAsk = Promise.resolve(nuiCallback('vmOnlinePlayers', {})).then((list) => {
        d.playersAsk = null;
        d.players = Array.isArray(list) ? list : [];
        if (draft === d && wiz && wiz.current() === 'owner') redrawStep();
    });
}

/** One person in the game, as the Player Manager's list has them: their face with the online light, their name,
 *  and their server id and character. */
function personRow(p) {
    const item = WP.el('div', 'wp-list-item wp-has-icon');
    item.dataset.action = 'vwOwnerPick';
    item.dataset.arg = p.charId;
    const face = avatar(p.name, true, p.charId);
    const dot = face.querySelector('.wp-dot');
    if (dot) dot.title = 'Online';
    item.appendChild(face);
    const top = WP.el('div', 'wp-item-top');
    top.appendChild(WP.el('span', 'wp-item-title', p.name || 'Character #' + p.charId));
    if (p.me) top.appendChild(WP.el('span', 'wp-pill wp-pill-accent', 'YOU'));
    item.appendChild(top);
    const sub = WP.el('div', 'wp-item-sub');
    sub.appendChild(WP.el('span', 'wp-info-value-mono', '#' + p.source));
    sub.appendChild(document.createTextNode(' · character #' + p.charId));
    item.appendChild(sub);
    return item;
}

function stepOwner(body) {
    hint(body, 'Whose it is: it is filed under them, they can store and bring it out at any garage they may use, '
        + 'and it is listed on their phone. You get a key too if it is yours.');
    if (draft.owner) {
        const line = WP.el('div', 'wp-line');
        line.style.gridTemplateColumns = '36px minmax(0, 1fr) auto';
        line.appendChild(avatar(draft.owner.name, !!draft.owner.online, draft.owner.charId));
        const text = WP.el('div');
        text.style.flex = '1';
        text.appendChild(WP.el('div', 'wp-item-title', draft.owner.name));
        text.appendChild(WP.el('div', 'wp-item-sub', 'character #' + draft.owner.charId + (draft.owner.online ? '  ·  online now' : '')));
        line.appendChild(text);
        line.appendChild(WP.btn('Someone else', 'vwOwnerClear', 'ghost'));
        body.appendChild(line);
        return;
    }
    // Everyone in the game first, as the player list has them, you at the top.
    body.appendChild(WP.el('div', 'wp-section-title', 'In the game'));
    const list = WP.el('div', 'wp-list wp-flush vw-people');
    if (!draft.players) {
        loadPlayers();
        list.appendChild(WP.empty('Reading who is in the game…'));
    } else if (!draft.players.length) {
        list.appendChild(WP.empty('Nobody is in the game'));
    } else {
        for (const p of draft.players) list.appendChild(personRow(p));
    }
    body.appendChild(list);

    // Anyone else, in the game or not, by name or character id.
    body.appendChild(WP.el('div', 'wp-section-title', 'Someone else'));
    const find = personSearch({
        placeholder: 'Type a name or a character id…',
        onPick: (p) => { draft.owner = p; answered('owner'); redrawStep(); },
    });
    body.appendChild(find.root);
}

// ---- step: where ----

function garageList() {
    return Object.keys(garages).map((k) => ({ key: k, g: garages[k] }))
        .sort((a, b) => (a.g.private ? 1 : 0) - (b.g.private ? 1 : 0)
            || String(a.g.name || a.key).localeCompare(String(b.g.name || b.key)));
}

/** Where you stand (vwHere: your game's own reading), for the map while it is to be spawned here. Read each time
 *  Where or Create is gone to (buildWizard's onGo): you may have walked off meanwhile. */
function loadHere() {
    if (!draft || draft.hereAsk) return;
    const d = draft;
    d.hereAsk = Promise.resolve(nuiCallback('vwHere', {})).then((p) => {
        d.hereAsk = null;
        d.here = p && Number.isFinite(Number(p.x)) && Number.isFinite(Number(p.y)) ? { x: Number(p.x), y: Number(p.y) } : false;
        const at = wiz && wiz.current();
        if (draft === d && (at === 'where' || at === 'review')) redrawStep();
    });
}

/** A garage's mark: its own icon and colour, as the Garages page shows it. */
function garageMark(key, g) {
    const colour = BLIP_COLOURS.find((c) => c[0] === Number(g.blipColor));
    return { x: Number(g.x), y: Number(g.y), name: g.name || key, sprite: Number(g.blipSprite) || 357,
        colour: colour ? colour[2] : '#ffffff' };
}

/** The map of where it will be: your position when it is spawned here, the garage picked, or every garage while
 *  none is (WP.place: the small map, Open map to see it big). */
function whereMap() {
    const d = draft;
    if (d.place === 'here') {
        if (d.here === null) { loadHere(); return WP.empty('Finding where you are…'); }
        if (!d.here) return WP.empty('Where you stand could not be read');
        return WP.place({ x: d.here.x, y: d.here.y, name: 'Here, beside you' });
    }
    const g = d.garage && garages[d.garage];
    if (g && Number.isFinite(Number(g.x))) return WP.place(garageMark(d.garage, g));
    const marks = garageList().filter(({ g }) => Number.isFinite(Number(g.x)) && Number.isFinite(Number(g.y)))
        .map(({ key, g }) => garageMark(key, g));
    if (!marks.length) return WP.empty('No garage on the map yet');
    return WP.place({ name: 'Garages', marks });
}

/** A step in two: what is chosen on the left, what it comes to on the right (the map, the car, whose it is). */
function splitInto(body) {
    const split = WP.el('div', 'vw-split');
    const main = WP.el('div', 'vw-main');
    const side = WP.el('div', 'vw-side');
    split.appendChild(main);
    split.appendChild(side);
    body.appendChild(split);
    return { main, side };
}

function stepWhere(body) {
    const { main, side } = splitInto(body);
    side.appendChild(whereMap());

    const row = WP.el('div', 'wp-choices');
    row.appendChild(choice('vwPlace', 'here', draft.place === 'here', 'Spawn here',
        'Brought out where you stand, in the world. It is filed under the default garage for when it is put away.'));
    row.appendChild(choice('vwPlace', 'garage', draft.place === 'garage', 'In a garage',
        'Stored there: its owner takes it out at that garage\'s bays.'));
    main.appendChild(row);
    if (draft.place !== 'garage') return;

    main.appendChild(WP.el('div', 'wp-section-title', 'Which garage'));
    const list = WP.el('div', 'wp-list wp-flush');
    const all = garageList();
    if (!all.length) list.appendChild(WP.empty('No garages yet: set one up in Vehicles → Garages, or bring it out here'));
    for (const { key, g } of all) {
        const item = WP.listItem({ title: g.name || key,
            sub: key + (g.private ? '  ·  private: ' + (g.managedBy || 'a property') + ', its owner and keyholders only' : ''),
            pill: draft.garage === key ? 'Picked' : undefined, pillClass: 'wp-pill-accent' });
        item.dataset.action = 'vwGarage';
        item.dataset.arg = key;
        if (draft.garage === key) item.classList.add('active');
        list.appendChild(item);
    }
    main.appendChild(list);
}

// ---- step: create ----

function stepReview(body) {
    const d = draft;
    const { main, side } = splitInto(body);

    // The ticks, on the left.
    const row = (label, key, status, detail) =>
        main.appendChild(WP.statusRow({ label, status, detail, action: 'vwJump', arg: key, actionLabel: 'Change' }));
    const c = carOf(d.model);
    row('Vehicle', 'vehicle', d.model ? 'ok' : 'err', d.model
        ? carName(d.model) + '  ·  ' + d.model + (c && VEHICLE_CLASSES[c.cls] ? '  ·  ' + VEHICLE_CLASSES[c.cls] : '')
        : 'none picked');
    row('Owner', 'owner', d.owner ? 'ok' : 'err', d.owner ? d.owner.name + '  ·  #' + d.owner.charId : 'nobody yet');
    const g = d.garage && garages[d.garage];
    row('Where', 'where', d.place === 'here' || g ? 'ok' : 'err', d.place === 'here' ? 'spawned here, beside you'
        : g ? 'in ' + (g.name || d.garage) + (g.private ? ' (private)' : '') : 'no garage picked');
    hint(main, 'Its plate is made up for it, and its trunk and glovebox are its model\'s (Vehicle Adjustments). '
        + 'Create makes it at once, and its page opens.').classList.add('wp-apart');

    // What it comes to, on the right: the car and whose it will be side by side, where it will be under them.
    const glance = WP.el('div', 'vw-glance');
    if (d.model) {
        const img = WP.el('img', 'wp-info-media vw-car');
        img.dataset.vehImg = '';   // utils.js's missing.png for a model with no picture
        img.src = vehicleImageUrl(d.model);
        img.alt = carName(d.model);
        glance.appendChild(img);
    }
    if (d.owner) {
        const who = WP.el('div', 'vm-owner vw-owner');
        who.appendChild(avatar(d.owner.name, !!d.owner.online, d.owner.charId, true));
        const text = WP.el('div', 'vm-owner-text');
        text.appendChild(WP.el('div', 'vm-owner-name', d.owner.name));
        text.appendChild(WP.el('div', 'wp-item-sub', 'Character #' + d.owner.charId + (d.owner.online ? '  ·  in the game now' : '')));
        who.appendChild(text);
        glance.appendChild(who);
    }
    side.appendChild(glance);
    side.appendChild(whereMap());
}

// ---- leaving a step, and creating ----

function canLeave(from) {
    const d = draft;
    if (!d) return 'There is no vehicle being set up';
    if (from === 'vehicle') return d.model ? true : 'Pick a vehicle';
    if (from === 'owner') return d.owner ? true : 'Pick whose it is';
    if (from === 'where') return d.place === 'here' || (d.garage && garages[d.garage]) ? true : 'Pick the garage it goes into';
    return true;
}

function finish() {
    const d = draft;
    if (!d || d.saving) return;
    for (const s of STEPS) {
        if (s.key === 'review') continue;
        const why = canLeave(s.key);
        if (why !== true) { wiz.setStatus(s.key, 'error'); wiz.say(why, 'err'); return; }
    }
    const payload = {
        model: d.model, ownerCharId: d.owner.charId,
        place: d.place, garage: d.place === 'garage' ? d.garage : undefined,
    };
    d.saving = true;
    wiz.say('Creating…');
    nuiCallback('vmWizardCreate', payload).then((res) => {
        if (draft !== d) return;
        d.saving = false;
        if (!res || res.ok !== true) {   // {} is a call that never reached the server: not a success
            wiz.say((res && res.why) || 'The vehicle was not made', 'err');
            return;
        }
        // Its page arrives as 'detail' (vmSendDetail), under the wizard; closing shows it.
        WP.result('Vehicle made: #' + res.vehicleId + (d.place === 'here' && !res.out ? '  ·  it could not be brought out: '
            + (res.why || 'it is in its garage') : ''), d.place === 'here' && !res.out ? 'err' : 'ok');
        closeWizard();
    });
}

// ---- section ----

WhipPanel.registerSection({
    id: 'vehicles',
    group: 'vehicles',
    label: 'Vehicles',
    order: 10,

    render(root) {
        els = {};
        built = false;

        // ---- the wizard, in the list's place while a vehicle is set up. First in the section, as the
        // garage wizard's is (the shell's '/' takes the first search). ----
        els.wizView = WP.el('div', 'wp-section-solo wp-section-wide');
        els.wizView.style.display = 'none';
        // The title and the steps on one row (Josh, 1 Nov): the steps on the right, so the title growing a car's
        // name does not move them.
        const head = WP.el('div', 'wp-actions-row wp-head-row wp-head-steps');
        els.wizTitle = WP.el('div', 'wp-pane-title', 'New vehicle');
        head.appendChild(els.wizTitle);
        head.appendChild(WP.el('span', 'wp-actions-split'));
        els.wizRail = WP.el('div');
        head.appendChild(els.wizRail);
        head.appendChild(WP.btn('Discard', 'vwDiscard', 'ghost'));
        els.wizView.appendChild(head);
        els.wizBody = WP.el('div', 'wp-view');
        els.wizView.appendChild(els.wizBody);
        root.appendChild(els.wizView);

        els.listView = WP.el('div', 'wp-view');
        root.appendChild(els.listView);

        els.mode = WP.select([
            { value: 'all', label: 'All' }, { value: 'plate', label: 'Plate' },
            { value: 'model', label: 'Model' }, { value: 'owner', label: 'Owner' },
        ], { changeAction: 'vmMode' });
        els.mode.value = searchMode;
        const modeField = WP.field('By', els.mode);

        els.listView.appendChild(WP.toolbar({
            search: { inputAction: 'vmSearch', placeholder: 'Search plate, model, id, owner…' },
            right: [modeField],
        }));

        const split = WP.el('div', 'wp-split');

        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        const detail = WP.el('div', 'wp-detail');
        // With no vehicle picked: the way to the wizard.
        els.intro = WP.el('div');
        els.intro.appendChild(WP.el('div', 'wp-pane-title', 'Vehicles'));
        els.intro.appendChild(WP.el('div', 'wp-hint',
            'Pick a vehicle to see it and change it, or set a new one up: the wizard walks you through the model, '
            + 'whose it is, and where it goes (spawned beside you, or into a garage).'));
        const go = WP.el('div', 'wp-actions-row');
        go.appendChild(WP.btn('Set up a new vehicle', 'vwNew', 'primary'));
        els.intro.appendChild(go);
        detail.appendChild(els.intro);

        // Info and the verbs, always open (no groups to fold): renderDetail() refills both on each detail push.
        els.detailWrap = WP.el('div');
        els.detailWrap.style.display = 'none';
        els.detailTitle = WP.el('div', 'wp-pane-title', '');
        els.detailWrap.appendChild(els.detailTitle);
        els.detailWrap.appendChild(WP.el('div', 'wp-section-title vm-verbs-title', 'Info'));
        els.infoBody = WP.el('div');
        els.detailWrap.appendChild(els.infoBody);
        els.verbsBody = WP.el('div');
        els.detailWrap.appendChild(els.verbsBody);
        detail.appendChild(els.detailWrap);
        split.appendChild(detail);

        els.listView.appendChild(split);

        built = true;
        // The panel is built again each time it opens: a vehicle half set up comes back where it was.
        if (draft) buildWizard(wizAt);
        showView();
    },

    onData(kind, payload) {
        if (!built) return;
        if (kind === 'all') {
            // The section-enter snapshot: fleet rows plus the garage and stat
            // catalogues the detail pane draws from. A fresh open drops any stale
            // selection — the server has no viewer-side memory of it.
            rows = payload && payload.rows || [];
            garages = payload && payload.garages || {};
            statDefs = payload && payload.statDefs || [];
            selected = null;
            vehicle = null;
            renderList();
            renderDetail();
            // The Where step lists the garages: a fresh list reaches it.
            if (wiz && wiz.current() === 'where') redrawStep();
            // Opened on one car (onFocus): its page, now the snapshot that would have cleared it is in.
            if (focusOn !== null) {
                selected = focusOn;
                focusOn = null;
                renderList();
                nuiCallback('vmSelect', { vehicleId: selected });
            }
        } else if (kind === 'rows') {
            // Live fleet broadcast — patch the list; selection and search are module
            // state and survive untouched.
            rows = payload || [];
            renderList();
        } else if (kind === 'detail') {
            // One vehicle, in full. Empty means it is gone — clear the pane.
            // THE CAR SHOWN IS THE CAR THE BUTTONS ACT ON. A car the wizard made arrives here
            // without ever being clicked in the list, so `selected` is set from it here.
            vehicle = payload || null;
            const was = selected;
            selected = vehicle ? vehicle.vehicleId : null;
            if (selected !== was) form = null;   // another car's verbs start with none open
            renderDetail();
            renderList();
            if (selected !== null && selected !== was) {
                const row = els.list.querySelector('.wp-list-item.active');
                if (row) row.scrollIntoView({ block: 'nearest' });
            }
        }
    },

    /** Opened on one car ({ vehicleId }: the object viewer, a car on a player's page): its page once the
     *  section-enter snapshot arrives. */
    onFocus(f) {
        const id = Number(f && f.vehicleId);
        if (id > 0) focusOn = id;
    },

    onEscape() {
        // Setting a vehicle up: a step back at a time; on the first, Escape offers to throw it away.
        if (wizardOpen()) {
            if (!(wiz && wiz.escape())) discardWizard();
            return true;
        }
        // A verb's form open: it closes first.
        if (form !== null) {
            form = null;
            renderDetail();
            return true;
        }
        // Drill-down stage: a selected vehicle backs out to the pane's intro first.
        if (selected !== null) {
            selected = null;
            vehicle = null;
            renderList();
            renderDetail();
            return true;
        }
        return false;
    },

    actions: {
        vmSearch: (el) => { search = el.value; renderList(); },
        vmMode: (el) => { searchMode = el.value; renderList(); },
        vmSelect: (el) => {
            selected = parseInt(el.dataset.id, 10);
            renderList();
            nuiCallback('vmSelect', { vehicleId: selected });
        },

        // ---- the wizard ----
        vwNew: () => openWizard(),
        vwDiscard: () => discardWizard(),
        vwJump: (el) => { if (wiz) wiz.jump(el.dataset.arg); },
        vwOwnerClear: () => {
            if (!draft) return;
            draft.owner = null;
            redrawStep();
        },
        // Someone in the game, from the list (vmOnlinePlayers).
        vwOwnerPick: (el) => {
            if (!draft || !draft.players) return;
            const p = draft.players.find((x) => Number(x.charId) === Number(el.dataset.arg));
            if (!p) return;
            draft.owner = { charId: Number(p.charId), name: p.name || 'Character #' + p.charId, online: true };
            answered('owner');
            redrawStep();
        },
        vwPlace: (el) => {
            if (!draft) return;
            draft.place = el.dataset.arg === 'here' ? 'here' : 'garage';
            if (draft.place === 'here') answered('where');
            redrawStep();
        },
        vwGarage: (el) => {
            if (!draft) return;
            draft.garage = el.dataset.arg;
            answered('where');
            redrawStep();
        },
        // ---- its verbs (VERBS) ----
        vmVerb: async (el) => {
            const d = VERB_BY_KEY[el.dataset.arg];
            if (!d || !selected || !vehicle) return;
            // One that needs something picked: its form opens under its set (again: it closes).
            if (d.form) {
                form = form === d.key ? null : d.key;
                renderDetail();
                return;
            }
            form = null;
            if (d.run) {
                nuiCallback('vmAction', { vehicleId: selected, action: call(d.run, vehicle) });
            } else if (d.go === 'storage') {
                // Inventory handoff v1: the shell closes (Lua side), the inventory opens.
                nuiCallback('vmOpenStorage', { vehicleId: selected, storageType: d.key });
            } else if (d.go === 'tpMe') {
                nuiCallback('vmTeleportTo', { vehicleId: selected });
            } else if (d.go === 'delete') {
                const v = vehicle;
                const ok = await WP.confirm({
                    title: 'Delete this vehicle for good?',
                    body: `#${selected} ${v.plate ? '"' + v.plate + '" ' : ''}leaves whip's database, and what is in its trunk, `
                        + 'glovebox and ignition goes with it. It cannot be brought back.',
                    confirmLabel: 'Delete',
                    danger: true,
                });
                if (!ok) return;
                nuiCallback('vmAction', { vehicleId: selected, action: 'delete' });
            }
            renderDetail();
        },
        vmFormGarage: (el) => {
            if (!selected) return;
            form = null;
            nuiCallback('vmActOn', { vehicleId: selected, action: 'moveGarage', arg: el.dataset.arg });
            renderDetail();
        },
        vmStatPick: () => statFill(),
        vmStatType: () => statReads(),
        vmStatSet: () => {
            if (!selected || !els.statPick || !els.statValue || els.statValue.value === '') return;
            const value = parseFloat(els.statValue.value);
            if (!Number.isFinite(value)) { WP.fieldError(els.statValue, 'A number'); return; }
            nuiCallback('vmSetStat', { vehicleId: selected, stat: els.statPick.value, value });
        },
    },
});
