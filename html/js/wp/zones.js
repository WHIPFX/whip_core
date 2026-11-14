// ========================================
// /whip SECTION — Zones
//
// The list of zones on the left; on the right, the picked zone as a summary — its shape, its rules,
// who may be in it, what it says and tracks — each part with a Change button.
//
// ONE WIZARD SETS ZONES UP AND CHANGES THEM. WP.stepper, as the shop, job and
// container wizards use it, in the section's place:
//
//   Name     what it is called, and its group (a name scripts find zones by)
//   Shape    a box, a sphere, a polygon or a scanned room — drawn in the world: the zone editor opens
//            straight into that shape (tools/zones.lua zwDraw) and hands the finished shape back
//   Rules    what happens inside: no weapons, no PvP, a speed limit, healing…
//   Who      everyone, or only some people (jobs, an ACE, characters) with anyone else put out
//   Options  a message on the way in and out, keeping track of cars in it, its priority
//   Review   the lot, checked; Create / Save changes
//
// A zone's KIND of shape is fixed once it exists (the server's editable fields): changing one redraws
// the same kind, or ADJUSTS it — a box's or a sphere's numbers on the Shape step, a polygon's floor and
// ceiling there and its corners in the world (Move corners: tools/zones.lua zwAdjust). The free
// editor (every zone at once) is still "Open the editor".
//
// The page's calls are tools/zones.lua's: zwDraw / zwCreate / zwUpdate for the wizard; zmTeleportToZone,
// zmToggleDebug, zmDeleteZone, zmToggleAllDebug and zmEnterEditor as before. They answer with the
// LEGACY 'zmRefresh' router action, registered here; fresh 'all' payloads arrive via wpSectionData on
// section enter and on editor exit.
// ========================================

import { NuiRouter } from '../router.js';
import { nuiCallback } from '../utils.js';
import { WhipPanel, WP } from '../whip-panel.js';
import { personSearch } from './pickers.js';
import { plural } from './format.js';

let zones = [];
let selectedId = null;
let allDebug = false;
let search = '';
let els = {};
const charNames = {};   // charId -> name, as found (wpCharSearch)

let draft = null;       // the zone being set up or changed, while the wizard is open
let wiz = null;
let wizAt = 'name';
let pendingSelect = null;   // { known: Set of ids before a create, label }: opened once it is listed

const STEPS = [
    { key: 'name', label: 'Name' },
    { key: 'shape', label: 'Shape' },
    { key: 'rules', label: 'Rules' },
    { key: 'who', label: 'Who' },
    { key: 'options', label: 'Options' },
    { key: 'review', label: 'Review' },
];

const SHAPES = [
    { key: 'box', type: 'box', title: 'A box', text: 'Four straight sides and a height: a room, a car park, a building.' },
    { key: 'sphere', type: 'sphere', title: 'A sphere', text: 'Everything within so many metres of a point.' },
    { key: 'poly', type: 'poly', title: 'A polygon', text: 'Click its corners one by one: any outline, with a floor and a ceiling.' },
    { key: 'scan', type: 'poly', title: 'Scan a room', text: 'Walk round inside and the walls are traced for you: an odd-shaped room.' },
];

/** What each rule does, in the words the page uses. ejectUnauthorized is Who's, not here. */
const RULES = [
    { key: 'noPvP', label: 'No fighting', text: 'nobody can shoot or punch anyone, and nobody in it can be hurt by players' },
    { key: 'disableFiring', label: 'No shooting', text: 'guns do not fire' },
    { key: 'noMelee', label: 'No punching', text: 'no fists or melee' },
    { key: 'noWeapons', label: 'Weapons away', text: 'weapons are put away while they are in it' },
    { key: 'noVehicles', label: 'No cars', text: 'anyone driving in is made to get out' },
    { key: 'noWantedLevel', label: 'No wanted level', text: 'a wanted level is cleared' },
    { key: 'noFallDamage', label: 'No fall damage', text: 'falls do not hurt' },
    { key: 'noCollision', label: 'Pass through people', text: 'players walk through each other' },
    { key: 'heal', label: 'Heals', text: 'heals whoever stands in it' },
];

// Not format.js's fixed(): with no places it drops trailing zeros, as the Lua it writes wants ("vec3(12.5, 3, 40)").
const fmt = (n, dp) => { const v = Number(n) || 0; return dp === undefined ? String(Math.round(v * 100) / 100) : v.toFixed(dp); };
const xyz = (v) => (v && typeof v === 'object' ? { x: Number(v.x !== undefined ? v.x : v[0]) || 0, y: Number(v.y !== undefined ? v.y : v[1]) || 0, z: Number(v.z !== undefined ? v.z : v[2]) || 0 } : null);

function findZone(id) {
    return zones.find((z) => z.id === id);
}

function charName(id, then) {
    id = Number(id);
    if (!(id > 0)) return '';
    if (charNames[id] !== undefined) return charNames[id];
    charNames[id] = '';
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

// ---- adopt (both inbound paths land here) ----

function adopt(list) {
    zones = list || [];
    if (pendingSelect) {
        const made = zones.filter((z) => !pendingSelect.known.has(z.id));
        const hit = made.find((z) => z.label === pendingSelect.label) || made[0];
        if (hit) {
            pendingSelect = null;
            if (!draft) selectedId = hit.id;
        }
    }
    renderList();
    if (draft) return;
    const z = selectedId && findZone(selectedId);
    if (z) renderDetail();
    else if (selectedId) noZone();
}

// ---- a zone, said in words: its page and the wizard's last step share these ----

/** The geometry as the wizard keeps it, from a zone or a drawn shape. */
function geometryOf(z) {
    if (!z || !z.type) return null;
    const g = { type: z.type, pos: xyz(z.pos) };
    if (z.type === 'box') { g.size = xyz(z.size) || { x: 10, y: 10, z: 5 }; g.heading = Number(z.heading) || 0; }
    if (z.type === 'sphere') g.radius = Number(z.radius) || 10;
    if (z.type === 'poly') {
        g.points = (z.points || []).map((p) => {
            const c = { x: Number(p.x !== undefined ? p.x : p[0]) || 0, y: Number(p.y !== undefined ? p.y : p[1]) || 0 };
            // A corner's own floor and ceiling (the editor's vertex heights) are kept with it.
            if (p.minZ != null) c.minZ = Number(p.minZ);
            if (p.maxZ != null) c.maxZ = Number(p.maxZ);
            return c;
        });
        g.minZ = z.minZ != null ? Number(z.minZ) : null;
        g.maxZ = z.maxZ != null ? Number(z.maxZ) : null;
    }
    return g;
}

function shapeText(g) {
    if (!g) return 'not drawn yet';
    if (g.type === 'box') return 'a box ' + fmt(g.size.x, 1) + ' × ' + fmt(g.size.y, 1) + ' m, ' + fmt(g.size.z, 1) + ' m high, turned ' + fmt(g.heading, 0) + '°';
    if (g.type === 'sphere') return 'a sphere ' + fmt(g.radius, 1) + ' m out from its middle';
    if (g.type === 'poly') {
        const h = g.minZ != null && g.maxZ != null ? ', from ' + fmt(g.minZ, 1) + ' to ' + fmt(g.maxZ, 1) + ' m up' : '';
        return 'a polygon of ' + plural((g.points || []).length, 'corner') + h;
    }
    return g.type;
}

function rulesOn(rules) {
    const on = RULES.filter((r) => rules[r.key]).map((r) => (r.key === 'heal' && rules.healRate ? 'heals ' + rules.healRate + ' a tick' : r.label.toLowerCase()));
    if (rules.speedLimit) on.push('cars kept under ' + rules.speedLimit + ' km/h');
    return on;
}

function whoText(d, then) {
    if (!d.eject) return 'everyone';
    const bits = [];
    if (d.jobs.length) bits.push('works at ' + d.jobs.join(', '));
    if (d.ace) bits.push('has the ' + d.ace + ' permission');
    if (d.chars.length) bits.push(d.chars.length <= 2 ? d.chars.map((c) => personText(c, then)).join(', ') : plural(d.chars.length, 'character'));
    return bits.length ? 'only whoever ' + bits.join(', or ') + ': anyone else is put out' : 'only some people: none named yet';
}

function summaryRows(body, d, rowOpts, changed, then) {
    const mark = (key, text) => (changed && changed.has(key) ? text + '  ·  changed' : text);
    const row = (label, key, status, detail) => {
        body.appendChild(WP.statusRow({ label, status, detail: mark(key, detail), ...rowOpts(key) }));
    };
    row('Name', 'name', d.label.trim() ? 'ok' : 'err', (d.label.trim() || 'none') + (d.group.trim() ? '  ·  group ' + d.group.trim() : ''));
    row('Shape', 'shape', d.geo ? 'ok' : 'err', shapeText(d.geo));
    const on = rulesOn(d.rules);
    row('Rules', 'rules', on.length ? 'ok' : 'off', on.length ? on.join(', ') : 'none: it only knows who is in it');
    row('Who may be in it', 'who', d.eject && !(d.jobs.length || d.ace || d.chars.length) ? 'err' : 'ok', whoText(d, then));
    row('Says when you', 'options', d.notify ? 'ok' : 'off', d.notify ? 'come in and leave' : 'nothing');
    row('Keeps track of cars', 'options', d.trackVehicles ? 'ok' : 'off', d.trackVehicles ? 'in it, for scripts' : 'no');
    row('Priority', 'options', 'ok', String(d.priority) + (d.priority ? '  ·  where zones overlap, the higher number\'s speed limit and weather win' : ''));
}

// ---- list ----

function renderList() {
    els.list.innerHTML = '';
    let shown = 0;
    for (const z of zones) {
        if (search) {
            const hay = ((z.label || '') + ' ' + (z.group || '') + ' ' + z.type + ' ' + z.id).toLowerCase();
            if (!hay.includes(search)) continue;
        }
        shown += 1;
        const subBits = [z.type];
        if (z.group) subBits.push(z.group);
        if (z._owner) subBits.push(z._owner);
        const item = WP.listItem({
            title: z.label || z.id,
            sub: subBits.join(' · '),
            pill: z._dbZone ? null : 'SCRIPT',
            pillClass: 'wp-pill-accent',
            id: z.id,
            action: 'zmSelect',
        });
        if (z.id === selectedId) item.classList.add('active');
        const top = item.querySelector('.wp-item-top');
        // Lights for presence stay dots, and say their meaning in words too.
        if (z.inside) {
            const dot = WP.el('span', 'wp-dot wp-dot-ok');
            dot.title = 'You are inside this zone';
            top.appendChild(dot);
        }
        if (z.debug) {
            const dot = WP.el('span', 'wp-dot wp-dot-warn');
            dot.title = 'Its outline is showing';
            top.appendChild(dot);
        }
        els.list.appendChild(item);
    }
    if (shown === 0) els.list.appendChild(WP.empty(search ? 'No zones match "' + search + '"' : 'No zones yet'));
    els.count.textContent = shown + ' of ' + plural(zones.length, 'zone');
}

// ---- a zone's page ----

function draftFrom(z) {
    const rules = Object.assign({}, z.rules || {});
    return {
        editing: z.id,
        dbZone: !!z._dbZone,
        owner: z._owner || null,
        label: z.label || '',
        group: z.group || '',
        geo: geometryOf(z),
        drawShape: z.type === 'poly' ? 'poly' : z.type,
        rules,
        eject: !!rules.ejectUnauthorized,
        jobs: Array.isArray(rules.jobWhitelist) ? rules.jobWhitelist.slice() : [],
        ace: typeof rules.aceWhitelist === 'string' ? rules.aceWhitelist : '',
        chars: Array.isArray(rules.charWhitelist) ? rules.charWhitelist.map(Number) : [],
        notify: !!z.notify,
        trackVehicles: !!z.trackVehicles,
        priority: Number(z.priority) || 0,
    };
}

function newDraft() {
    return {
        editing: null, dbZone: true, owner: null, label: '', group: '', geo: null, drawShape: 'box',
        rules: {}, eject: false, jobs: [], ace: '', chars: [], notify: false, trackVehicles: false, priority: 0,
    };
}

function selectZone(id) {
    if (!findZone(id)) return;
    selectedId = id;
    renderList();
    renderDetail();
}

function noZone() {
    selectedId = null;
    renderList();
    renderDetail();
}

function renderDetail() {
    const body = els.detailBody;
    body.innerHTML = '';
    const z = selectedId && findZone(selectedId);
    if (!z) {
        els.detailTitle.textContent = 'Zones';
        body.appendChild(WP.el('div', 'wp-hint',
            'Pick a zone to change it, or set a new one up: the wizard walks you through drawing it in the world, '
            + 'what happens inside it and who may be there. Open the editor to work on every zone at once.'));
        const go = WP.el('div', 'wp-actions-row');
        go.appendChild(WP.btn('Set up a new zone', 'zmNew', 'primary'));
        body.appendChild(go);
        return;
    }
    els.detailTitle.textContent = z.label || z.id;
    const d = draftFrom(z);
    const again = () => { if (selectedId === z.id && !draft) renderDetail(); };
    body.appendChild(WP.el('div', 'wp-item-sub', z.id + (z._dbZone ? '  ·  saved' : '  ·  made by ' + (z._owner || 'a script'))
        + '  ·  Change opens the wizard on that part'));
    if (!z._dbZone) {
        body.appendChild(WP.statusRow({ label: 'Made by a script', status: 'warn',
            detail: (z._owner || 'a resource') + ' makes it: changes here last until it starts again' }));
    }
    summaryRows(body, d, (key) => ({ action: 'zmEdit', arg: key, actionLabel: 'Change' }), null, again);
    body.appendChild(WP.statusRow({ label: 'You', status: z.inside ? 'ok' : 'off', detail: z.inside ? 'are inside it' : 'are not in it' }));

    const actions = WP.el('div', 'wp-actions-row wp-apart');
    actions.appendChild(WP.btn('Delete', 'zmDelete', 'danger'));
    actions.appendChild(WP.el('span', 'wp-actions-split'));
    const outline = WP.el('button', 'wp-toggle' + (z.debug ? ' active' : ''), 'Outline' + (z.debug ? ' · on' : ' · off'));
    outline.type = 'button';
    outline.dataset.action = 'zmToggleDebug';
    actions.appendChild(outline);
    actions.appendChild(WP.btn('Copy code', 'zmCopyCode'));
    actions.appendChild(WP.btn('Teleport there', 'zmTeleport'));
    actions.appendChild(WP.btn('Change everything', 'zmEdit', 'primary', 'name'));
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
    draft = newDraft();
    buildWizard('name');
    showView();
}

function openEdit(id, at) {
    const z = findZone(id);
    if (!z) return;
    draft = draftFrom(z);
    draft.original = JSON.parse(JSON.stringify(partsOf(draft)));
    buildWizard(at);
    showView();
}

function closeWizard() {
    draft = null;
    wiz = null;
    wizAt = 'name';
    if (els.wizBody) els.wizBody.innerHTML = '';
    showView();
    renderDetail();
}

function partsOf(d) {
    return { label: d.label, group: d.group, geo: d.geo, rules: rulesOf(d), notify: d.notify, trackVehicles: d.trackVehicles, priority: d.priority };
}

/** The rules as saved: the toggles, the numbers, and Who's whitelist — anything else a script put in
 *  the zone's rules (an enter message, its weather) kept as it was. */
function rulesOf(d) {
    const r = Object.assign({}, d.rules);
    for (const k of ['ejectUnauthorized', 'jobWhitelist', 'aceWhitelist', 'charWhitelist']) delete r[k];
    if (d.eject) {
        r.ejectUnauthorized = true;
        if (d.jobs.length) r.jobWhitelist = d.jobs.slice();
        if (d.ace) r.aceWhitelist = d.ace;
        if (d.chars.length) r.charWhitelist = d.chars.slice();
    }
    for (const k of Object.keys(r)) if (r[k] === false || r[k] === null || r[k] === '') delete r[k];
    if (!r.heal) delete r.healRate;
    return r;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function changedParts(d) {
    const out = new Set();
    const o = d && d.original;
    if (!o) return out;
    const now = partsOf(d);
    if (now.label.trim() !== o.label.trim() || now.group.trim() !== o.group.trim()) out.add('name');
    if (!same(now.geo, o.geo)) out.add('shape');
    const ruleKeys = (r) => { const c = Object.assign({}, r); for (const k of ['ejectUnauthorized', 'jobWhitelist', 'aceWhitelist', 'charWhitelist']) delete c[k]; return c; };
    const whoKeys = (r) => ({ e: !!r.ejectUnauthorized, j: r.jobWhitelist || null, a: r.aceWhitelist || null, c: r.charWhitelist || null });
    if (!same(ruleKeys(now.rules), ruleKeys(o.rules))) out.add('rules');
    if (!same(whoKeys(now.rules), whoKeys(o.rules))) out.add('who');
    if (now.notify !== o.notify || now.trackVehicles !== o.trackVehicles || now.priority !== o.priority) out.add('options');
    return out;
}

function draftTouched() {
    if (!draft) return false;
    if (draft.editing) return changedParts(draft).size > 0;
    return !!(draft.label.trim() || draft.geo || Object.keys(draft.rules).length);
}

async function discardWizard() {
    if (draftTouched()) {
        const editing = !!draft.editing;
        const ok = await WP.confirm({
            title: editing ? 'Stop changing this zone?' : 'Throw this zone away?',
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
        id: 'zm-wizard',
        steps: STEPS,
        onGo: (k, from, body) => { wizAt = k; fillStep(k, body); },
        canLeave: (from) => canLeave(from),
        onFinish: finish,
        finishLabel: draft.editing ? 'Save changes' : 'Create zone',
    });
    els.wizBody.appendChild(wiz.root);
    const target = STEPS.some((s) => s.key === at) ? at : 'name';
    if (draft.editing) {
        wiz.start('review');
        if (target !== 'review') wiz.go(target);
    } else {
        wiz.start(target);
    }
    renderWizHead();
}

function renderWizHead() {
    const name = draft && draft.label.trim();
    els.wizTitle.textContent = draft && draft.editing ? 'Change — ' + (name || draft.editing) : 'New zone' + (name ? ' — ' + name : '');
    els.wizDiscard.textContent = draft && draft.editing ? 'Cancel' : 'Discard';
}

function fillStep(key, body) {
    if (!draft) return;
    body.innerHTML = '';
    const fill = { name: stepName, shape: stepShape, rules: stepRules, who: stepWho, options: stepOptions, review: stepReview }[key];
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

function choices(body, list, value, action, disabledFn) {
    const row = WP.el('div', 'wp-choices');
    for (const k of list) {
        const b = WP.el('button', 'wp-choice' + (value === k.key ? ' active' : ''));
        b.type = 'button';
        b.dataset.action = action;
        b.dataset.arg = k.key;
        if (disabledFn && disabledFn(k)) b.disabled = true;
        b.appendChild(WP.el('span', 'wp-choice-title', k.title));
        if (k.text) b.appendChild(WP.el('span', 'wp-choice-text', k.text));
        row.appendChild(b);
    }
    body.appendChild(row);
    return row;
}

function numberBox(value, placeholder, action, width) {
    const i = WP.input({ type: 'number', value: value || '', placeholder, inputAction: action });
    const f = WP.el('label', 'wp-field');
    f.appendChild(i);
    i.classList.add('wp-input-short');
    f.style.width = width || 'auto';
    return f;
}

// ---- step: name ----

function stepName(body) {
    const name = WP.input({ placeholder: 'e.g. Mission Row station', value: draft.label, inputAction: 'zwName' });
    name.maxLength = 100;
    body.appendChild(WP.field('Name', name, true));
    const group = WP.input({ placeholder: 'e.g. police (optional)', value: draft.group, inputAction: 'zwGroup' });
    group.maxLength = 60;
    body.appendChild(WP.field('Group', group, true));
    hint(body, 'A group is a name scripts find zones by ("every police zone"). Leave it empty if nothing asks.');
}

// ---- step: shape ----

/** A number changed in place (on Enter or leaving the box): `action` with `arg` naming the part. */
function geoBox(value, arg, step) {
    const i = WP.input({ type: 'number', value: value == null ? '' : fmt(value, 2) });
    i.dataset.change = 'zwGeo';
    i.dataset.arg = arg;
    i.step = step || '0.5';
    i.classList.add('wp-input-short');
    const f = WP.el('label', 'wp-field');
    f.appendChild(i);
    f.style.width = '110px';
    return f;
}

/** ADJUSTING A SHAPE by hand: its numbers, here, and a
 *  polygon's corners in the world (Move corners: tools/zones.lua zwAdjust). Saved with the rest. */
function adjustRows(body, g) {
    body.appendChild(WP.el('div', 'wp-section-title', 'Adjust it'));
    const m = (text) => WP.el('span', 'wp-item-sub', text);
    if (g.type === 'box') {
        body.appendChild(WP.statusRow({ label: 'Length', status: 'ok', detail: 'one side', control: [geoBox(g.size.x, 'size.x'), m('m')] }));
        body.appendChild(WP.statusRow({ label: 'Width', status: 'ok', detail: 'the other side', control: [geoBox(g.size.y, 'size.y'), m('m')] }));
        body.appendChild(WP.statusRow({ label: 'Height', status: 'ok', detail: 'floor to ceiling, around its middle', control: [geoBox(g.size.z, 'size.z'), m('m')] }));
        body.appendChild(WP.statusRow({ label: 'Turned', status: 'ok', detail: 'which way it faces', control: [geoBox(g.heading, 'heading', '5'), m('°')] }));
    } else if (g.type === 'sphere') {
        body.appendChild(WP.statusRow({ label: 'Size', status: 'ok', detail: 'metres out from its middle', control: [geoBox(g.radius, 'radius'), m('m')] }));
    } else if (g.type === 'poly') {
        const corners = (g.points || []).length;
        body.appendChild(WP.statusRow({ label: 'Corners', status: 'ok',
            detail: plural(corners, 'corner') + ': move them, add them or take them off where they are',
            control: [WP.btn('Move corners', 'zwAdjust', 'primary')] }));
        body.appendChild(WP.statusRow({ label: 'Ceiling', status: 'ok', detail: 'how high it reaches (the map\'s height, in metres)',
            control: [geoBox(g.maxZ, 'maxZ', '0.25'), m('m')] }));
        body.appendChild(WP.statusRow({ label: 'Floor', status: 'ok', detail: 'how low it goes',
            control: [geoBox(g.minZ, 'minZ', '0.25'), m('m')] }));
        hint(body, 'Move corners opens the zone editor over it: aim at a corner and E picks it up, E again puts it down; '
            + 'F adds a corner where you aim, R takes the aimed one off; scroll raises the ceiling, Ctrl+scroll the floor. '
            + 'G brings it back here, Esc leaves it as it was. Nothing is saved until Save changes.');
    }
}

function stepShape(body) {
    const fixedType = draft.editing && draft.geo ? draft.geo.type : null;
    choices(body, SHAPES, draft.drawShape, 'zwShape', (k) => fixedType && k.type !== fixedType);
    if (fixedType) hint(body, 'A zone keeps its kind of shape once made: redraw it as ' + (fixedType === 'poly' ? 'a polygon (or scan the room again)' : 'a ' + fixedType) + '.');
    body.appendChild(WP.statusRow({ label: 'Shape', status: draft.geo ? 'ok' : 'todo', detail: shapeText(draft.geo) }));
    const row = WP.el('div', 'wp-actions-row');
    if (draft.geo && draft.geo.pos) row.appendChild(WP.btn('Teleport there', 'zwTeleport'));
    row.appendChild(WP.el('span', 'wp-actions-split'));
    row.appendChild(WP.btn(draft.geo ? 'Draw it again' : 'Draw it in the world', 'zwDraw', draft.geo ? '' : 'primary'));
    body.appendChild(row);
    const how = {
        box: 'The panel steps aside and the zone editor opens on a box where you look: fly with WASD, scroll to size it, G to put it down.',
        sphere: 'The zone editor opens on a sphere where you look: fly with WASD, scroll to size it, G to put it down.',
        poly: 'The zone editor opens for corners: G drops one where you look, F closes the outline, scroll sets its height, G again to finish.',
        scan: 'The zone editor opens: press H, walk round the room and its walls are traced, then G to finish.',
    }[draft.drawShape];
    if (how) hint(body, (draft.geo ? 'Draw it again: ' : '') + how + ' Esc comes back here.');
    if (draft.geo) adjustRows(body, draft.geo);
}

// ---- step: rules ----

// Each rule a yes or no: its tick or cross is the switch, as is its name.
function stepRules(body) {
    hint(body, 'Click a tick or a cross to switch a rule on or off.');
    const r = draft.rules;
    for (const rule of RULES) {
        const controls = rule.key === 'heal' && r.heal
            ? [numberBox(r.healRate, '2', 'zwHealRate'), WP.el('span', 'wp-item-sub', 'a tick')] : null;
        body.appendChild(WP.statusRow({ label: rule.label, detail: rule.text, control: controls,
            yesNo: { on: !!r[rule.key], action: 'zwRule', arg: rule.key } }));
    }
    body.appendChild(WP.statusRow({ label: 'Speed limit',
        detail: r.speedLimit ? 'cars kept under ' + r.speedLimit + ' km/h' : 'cars go as fast as they like',
        control: r.speedLimit ? [numberBox(r.speedLimit, 'km/h', 'zwSpeed'), WP.el('span', 'wp-item-sub', 'km/h')] : null,
        yesNo: { on: !!r.speedLimit, action: 'zwSpeedOn' } }));
}

// ---- step: who ----

function stepWho(body) {
    choices(body, [
        { key: 'everyone', title: 'Everyone', text: 'Anyone can be in it. The rules apply to them all.' },
        { key: 'some', title: 'Only some people', text: 'Anyone who is not one of them is put out as they come in.' },
    ], draft.eject ? 'some' : 'everyone', 'zwWho');
    if (!draft.eject) return;
    hint(body, 'Matching any one of these lets them stay.');
    const jobs = WP.input({ placeholder: 'e.g. police, ems', value: draft.jobs.join(', ') });
    jobs.dataset.change = 'zwJobs';
    const jf = WP.el('label', 'wp-field');
    jf.appendChild(jobs);
    jf.style.width = '280px';
    body.appendChild(WP.statusRow({ label: 'Jobs', status: draft.jobs.length ? 'ok' : 'off',
        detail: draft.jobs.length ? 'whoever works at ' + draft.jobs.join(', ') : 'no job named', control: [jf] }));
    const ace = WP.input({ placeholder: 'e.g. whip.vip', value: draft.ace });
    ace.dataset.change = 'zwAce';
    const af = WP.el('label', 'wp-field');
    af.appendChild(ace);
    af.style.width = '280px';
    body.appendChild(WP.statusRow({ label: 'Permission', status: draft.ace ? 'ok' : 'off',
        detail: draft.ace ? 'whoever has the ' + draft.ace + ' permission' : 'no permission named', control: [af] }));
    body.appendChild(WP.el('div', 'wp-section-title', 'Characters'));
    for (const c of draft.chars) {
        const rm = WP.btn('Take off', 'zwCharOff', 'ghost', String(c));
        body.appendChild(WP.statusRow({ label: 'Character', status: 'ok', sub: true, detail: personText(c, redrawStep), control: [rm] }));
    }
    const find = personSearch({ placeholder: 'Add a character: type a name or an id…', skip: (id) => draft.chars.indexOf(id) >= 0,
        onPick: (p) => { charNames[p.charId] = p.name; draft.chars.push(p.charId); redrawStep(); } });
    body.appendChild(find.root);
}

// ---- step: options ----

function stepOptions(body) {
    body.appendChild(WP.statusRow({ label: 'Say so',
        detail: draft.notify ? 'a message as people come in and leave' : 'nothing on the way in or out',
        yesNo: { on: !!draft.notify, action: 'zwNotify' } }));
    body.appendChild(WP.statusRow({ label: 'Cars in it',
        detail: draft.trackVehicles ? 'kept track of, for scripts that ask' : 'not tracked',
        yesNo: { on: !!draft.trackVehicles, action: 'zwVehicles' } }));
    body.appendChild(WP.statusRow({ label: 'Priority', status: 'ok',
        detail: 'where zones overlap, the higher number acts first (0 to 100)',
        control: [numberBox(String(draft.priority), '0', 'zwPriority')] }));
}

// ---- step: review ----

function stepReview(body) {
    const changed = draft.editing ? changedParts(draft) : null;
    summaryRows(body, draft, (key) => ({ action: 'zwJump', arg: key, actionLabel: 'Change' }), changed, redrawStep);
    const last = draft.editing
        ? hint(body, changed.size ? 'Save changes writes what changed, for everyone at once.' : 'Nothing has changed yet: Change any part above.')
        : hint(body, 'Create makes it at once, for everyone: its rules start the moment someone walks in.');
    last.classList.add('wp-apart');
}

// ---- leaving a step, and saving ----

function canLeave(from) {
    const d = draft;
    if (!d) return 'There is no zone being set up';
    if (from === 'name') return d.label.trim() ? true : 'Give it a name';
    if (from === 'shape') return d.geo ? true : 'Draw it in the world';
    if (from === 'rules') {
        if (d.rules.speedLimit && !(d.rules.speedLimit > 0 && d.rules.speedLimit <= 500)) return 'A speed limit is 1 to 500 km/h';
        return true;
    }
    if (from === 'who') return !d.eject || d.jobs.length || d.ace || d.chars.length ? true : 'Name who may be in it, or let everyone';
    if (from === 'options') return d.priority >= 0 && d.priority <= 100 ? true : 'Priority is 0 to 100';
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

function finish() {
    const d = draft;
    if (!d) return;
    const changed = d.editing ? changedParts(d) : null;
    if (d.editing && !changed.size) { wiz.say('Nothing has changed', 'err'); return; }
    const problem = firstProblem();
    if (problem) { wiz.setStatus(problem.key, 'error'); wiz.say(problem.why, 'err'); return; }

    const g = d.geo;
    const geoFields = {};
    if (g.type === 'box') Object.assign(geoFields, { pos: g.pos, size: g.size, heading: g.heading });
    if (g.type === 'sphere') Object.assign(geoFields, { pos: g.pos, radius: g.radius });
    if (g.type === 'poly') Object.assign(geoFields, { pos: g.pos, points: g.points, minZ: g.minZ, maxZ: g.maxZ });

    if (d.editing) {
        const updates = {};
        if (changed.has('name')) {
            updates.label = d.label.trim();
            // An emptied group is taken off (`clear`): an empty value would arrive in Lua as no key.
            if (d.group.trim()) updates.group = d.group.trim();
            else if (d.original.group.trim()) updates.clear = ['group'];
        }
        if (changed.has('shape')) Object.assign(updates, geoFields);
        if (changed.has('rules') || changed.has('who')) updates.rules = rulesOf(d);
        if (changed.has('options')) Object.assign(updates, { notify: d.notify, trackVehicles: d.trackVehicles, priority: d.priority });
        wiz.say('Saving…');
        const id = d.editing;
        nuiCallback('zwUpdate', { id, updates }).then((res) => {
            if (draft !== d) return;
            if (!res || res.ok !== true) { wiz.say((res && res.why) || 'The zone was not saved', 'err'); return; }
            WP.result('Zone saved', 'ok');
            selectedId = id;
            closeWizard();
            renderList();
        });
    } else {
        // No group: left out of the payload rather than sent empty.
        const payload = Object.assign({ type: g.type, label: d.label.trim(), group: d.group.trim() || undefined,
            priority: d.priority, rules: rulesOf(d), notify: d.notify, trackVehicles: d.trackVehicles }, geoFields);
        wiz.say('Creating…');
        pendingSelect = { known: new Set(zones.map((z) => z.id)), label: payload.label };
        nuiCallback('zwCreate', payload).then((res) => {
            if (draft !== d) return;
            if (!res || res.ok !== true) { pendingSelect = null; wiz.say((res && res.why) || 'The zone was not made', 'err'); return; }
            WP.result('Zone created', 'ok');
            closeWizard();
        });
    }
}

// ---- copy code (ported verbatim; clipboard + execCommand fallback) ----

function buildZoneCode(z) {
    let code = '';
    const p = xyz(z.pos) || { x: 0, y: 0, z: 0 };
    if (z.type === 'box') {
        const s = xyz(z.size) || { x: 0, y: 0, z: 0 };
        code = "local id = exports.whip_core:RegisterZone({\n    type    = 'box',\n";
        code += "    pos     = vec3(" + fmt(p.x) + ", " + fmt(p.y) + ", " + fmt(p.z) + "),\n";
        code += "    size    = vec3(" + fmt(s.x) + ", " + fmt(s.y) + ", " + fmt(s.z) + "),\n";
        if (z.heading) code += "    heading = " + fmt(z.heading) + ",\n";
    } else if (z.type === 'sphere') {
        code = "local id = exports.whip_core:RegisterZone({\n    type   = 'sphere',\n";
        code += "    pos    = vec3(" + fmt(p.x) + ", " + fmt(p.y) + ", " + fmt(p.z) + "),\n";
        code += "    radius = " + fmt(z.radius) + ",\n";
    } else if (z.type === 'poly') {
        code = "local id = exports.whip_core:RegisterZone({\n    type   = 'poly',\n";
        code += "    points = {\n";
        for (const pt of z.points || []) {
            const px = pt.x !== undefined ? pt.x : pt[1];
            const py = pt.y !== undefined ? pt.y : pt[2];
            code += "        vec2(" + fmt(px) + ", " + fmt(py) + "),\n";
        }
        code += "    },\n";
        if (z.minZ != null) code += "    minZ = " + fmt(z.minZ) + ",\n";
        if (z.maxZ != null) code += "    maxZ = " + fmt(z.maxZ) + ",\n";
    }
    // Quoted for Lua, so a group like bob's garage still pastes. JSON.stringify of
    // text is a valid Lua double-quoted string (its escapes are Lua's too).
    if (z.group) code += "    group = " + JSON.stringify(String(z.group)) + ",\n";
    code += "    onEnter = function(zone)\n";
    code += "        -- entered\n";
    code += "    end,\n";
    code += "    onExit = function(zone)\n";
    code += "        -- exited\n";
    code += "    end,\n";
    code += "})";
    return code;
}

// SAYS WHETHER IT COPIED (the Player Manager's and utils.js's copy do the same): execCommand's answer counts.
function flashCopied(btnEl, ok = true) {
    btnEl.textContent = ok ? 'Copied' : 'Could not copy';
    setTimeout(() => { btnEl.textContent = 'Copy code'; }, 1500);
}

function fallbackCopy(text, btnEl) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy') === true; } catch (e) { ok = false; }
    document.body.removeChild(ta);
    flashCopied(btnEl, ok);
}

// ---- section ----

WhipPanel.registerSection({
    id: 'zones',
    group: 'world',
    label: 'Zones',
    order: 20,

    render(root) {
        els = {};

        els.wizView = WP.el('div', 'wp-section-solo wp-section-wide');
        els.wizView.style.display = 'none';
        const head = WP.el('div', 'wp-actions-row wp-head-row');
        els.wizTitle = WP.el('div', 'wp-pane-title', 'New zone');
        head.appendChild(els.wizTitle);
        head.appendChild(WP.el('span', 'wp-actions-split'));
        els.wizDiscard = WP.btn('Discard', 'zwDiscard', 'ghost');
        head.appendChild(els.wizDiscard);
        els.wizView.appendChild(head);
        els.wizBody = WP.el('div', 'wp-view');
        els.wizView.appendChild(els.wizBody);
        root.appendChild(els.wizView);

        els.listView = WP.el('div', 'wp-view');
        els.debugAllBtn = WP.el('button', 'wp-toggle' + (allDebug ? ' active' : ''), 'All outlines' + (allDebug ? ' · on' : ' · off'));
        els.debugAllBtn.type = 'button';
        els.debugAllBtn.dataset.action = 'zmToggleAllDebug';
        els.listView.appendChild(WP.toolbar({
            left: [WP.btn('+ New Zone', 'zmNew'), WP.btn('Open the editor', 'zmEnterEditor', 'ghost'), els.debugAllBtn],
            search: { inputAction: 'zmSearch', placeholder: 'Search zones…' },
        }));
        const split = WP.el('div', 'wp-split');
        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);
        const detail = WP.el('div', 'wp-detail');
        els.detailTitle = WP.el('div', 'wp-pane-title', 'Zones');
        detail.appendChild(els.detailTitle);
        els.detailBody = WP.el('div');
        detail.appendChild(els.detailBody);
        split.appendChild(detail);
        els.listView.appendChild(split);
        root.appendChild(els.listView);

        renderList();
        renderDetail();
        if (draft) buildWizard(wizAt);
        showView();
    },

    onData(kind, payload) {
        if (kind === 'all') adopt(payload.zones);
        else if (kind === 'shape' && draft) {
            // Shape: drawn in the world for the wizard (tools/zones.lua zeCreate).
            const g = geometryOf(payload);
            // A zone being changed keeps its kind (the server keeps the old type): the editor's 1/2/3
            // can still draw another kind, so that drawing is refused here.
            const fixed = draft.editing && draft.geo ? draft.geo.type : null;
            if (g && fixed && g.type !== fixed) {
                const word = (t) => (t === 'poly' ? 'a polygon' : 'a ' + t);
                if (wiz) wiz.say('That was ' + word(g.type) + ': this zone stays ' + word(fixed) + '. Draw it again as one.', 'err');
                return;
            }
            if (g) {
                draft.geo = g;
                // A new zone drawn as another kind than the card picked: the card follows the drawing.
                if (g.type !== draft.drawShape && !(draft.drawShape === 'scan' && g.type === 'poly')) draft.drawShape = g.type;
                if (wiz && wiz.current() === 'shape') redrawStep();
            }
        }
    },

    onLeave() {
        // The editor forces outlines on; a stray "all outlines" must not outlive the section.
        if (allDebug) {
            allDebug = false;
            nuiCallback('zmToggleAllDebug', { enabled: false });
            if (els.debugAllBtn) {
                els.debugAllBtn.classList.remove('active');
                els.debugAllBtn.textContent = 'All outlines · off';
            }
        }
    },

    onEscape() {
        if (wizardOpen()) {
            if (draft.editing && wiz && wiz.current() !== 'review') { wiz.go('review'); return true; }
            if (draft.editing || !(wiz && wiz.escape())) discardWizard();
            return true;
        }
        if (selectedId !== null) { noZone(); return true; }
        return false;
    },

    actions: {
        zmSearch: (el) => { search = el.value.toLowerCase(); renderList(); },
        zmSelect: (el) => selectZone(el.dataset.id),
        zmNew: () => openWizard(),
        zmEdit: (el) => { if (selectedId) openEdit(selectedId, el.dataset.arg); },
        zmEnterEditor: () => nuiCallback('zmEnterEditor', {}),
        zmToggleAllDebug: (el) => {
            allDebug = !allDebug;
            el.classList.toggle('active', allDebug);
            el.textContent = 'All outlines' + (allDebug ? ' · on' : ' · off');
            nuiCallback('zmToggleAllDebug', { enabled: allDebug });
        },
        zmToggleDebug: () => { if (selectedId) nuiCallback('zmToggleDebug', { id: selectedId }); },
        zmTeleport: () => { if (selectedId) nuiCallback('zmTeleportToZone', { id: selectedId }); },
        zmDelete: async () => {
            if (!selectedId) return;
            const z = findZone(selectedId);
            const ok = await WP.confirm({
                title: 'Delete zone?',
                body: (z && (z.label || z.id)) + (z && !z._dbZone
                    ? ' is made by a script: it goes from your own game only, and comes back when you rejoin or that script starts again. Everyone else keeps it.'
                    : ' will be removed for good.'),
                confirmLabel: 'Delete',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('zmDeleteZone', { id: selectedId });
            noZone();
        },
        zmCopyCode: (el) => {
            const z = selectedId && findZone(selectedId);
            if (!z) return;
            const code = buildZoneCode(z);
            try {
                navigator.clipboard.writeText(code).then(() => flashCopied(el)).catch(() => fallbackCopy(code, el));
            } catch (e) { fallbackCopy(code, el); }
        },

        // ---- the wizard ----
        zwDiscard: () => discardWizard(),
        zwJump: (el) => { if (wiz) wiz.jump(el.dataset.arg); },
        zwName: (el) => { if (draft) { draft.label = el.value; renderWizHead(); } },
        zwGroup: (el) => { if (draft) draft.group = el.value; },
        zwShape: (el) => { if (draft) { draft.drawShape = el.dataset.arg; redrawStep(); } },
        zwDraw: () => {
            if (!draft) return;
            const g = draft.geo;
            nuiCallback('zwDraw', { shape: draft.drawShape, size: g && g.size, radius: g && g.radius }).then((res) => {
                if (res && res.ok === false && wiz) wiz.say(res.why || 'The zone editor could not open', 'err');
            });
        },
        zwAdjust: () => {
            if (!draft || !draft.geo || draft.geo.type !== 'poly') return;
            nuiCallback('zwAdjust', { geo: draft.geo }).then((res) => {
                if (res && res.ok === false && wiz) wiz.say(res.why || 'The zone editor could not open', 'err');
            });
        },
        // A shape's number, changed on the page (adjustRows). Kept sane: sizes over half a metre, a
        // ceiling over its floor; a corner with its own height moves with the ceiling or floor.
        zwGeo: (el) => {
            const g = draft && draft.geo;
            const v = Number(el.value);
            if (!g || !Number.isFinite(v)) { redrawStep(); return; }
            const arg = el.dataset.arg;
            if (arg.startsWith('size.') && g.size) g.size[arg.slice(5)] = Math.max(0.5, Math.min(500, v));
            else if (arg === 'radius') g.radius = Math.max(0.5, Math.min(500, v));
            else if (arg === 'heading') g.heading = ((v % 360) + 360) % 360;
            else if (arg === 'maxZ' || arg === 'minZ') {
                const other = arg === 'maxZ' ? g.minZ : g.maxZ;
                const ok = other == null || (arg === 'maxZ' ? v > other + 0.5 : v < other - 0.5);
                if (ok) {
                    const delta = g[arg] != null ? v - g[arg] : 0;
                    g[arg] = v;
                    for (const p of g.points || []) if (p[arg] != null) p[arg] += delta;
                } else if (wiz) wiz.say('The ceiling must be over the floor', 'err');
            }
            redrawStep();
        },
        zwTeleport: () => {
            const p = draft && draft.geo && draft.geo.pos;
            if (p) nuiCallback('zwTeleport', { x: p.x, y: p.y, z: p.z });
        },
        zwRule: (el) => {
            if (!draft) return;
            const k = el.dataset.arg;
            if (draft.rules[k]) delete draft.rules[k]; else draft.rules[k] = true;
            redrawStep();
        },
        zwHealRate: (el) => { if (draft) { const n = parseInt(el.value, 10); if (n > 0) draft.rules.healRate = n; else delete draft.rules.healRate; } },
        zwSpeed: (el) => { if (draft) { const n = parseInt(el.value, 10); if (n > 0) draft.rules.speedLimit = n; else delete draft.rules.speedLimit; } },
        // The speed limit's tick: on at 50 km/h to start with (the number is then changed beside it).
        zwSpeedOn: () => {
            if (!draft) return;
            if (draft.rules.speedLimit) delete draft.rules.speedLimit; else draft.rules.speedLimit = 50;
            redrawStep();
        },
        zwWho: (el) => { if (draft) { draft.eject = el.dataset.arg === 'some'; redrawStep(); } },
        zwJobs: (el) => { if (draft) { draft.jobs = el.value.split(',').map((s) => s.trim()).filter(Boolean); redrawStep(); } },
        zwAce: (el) => { if (draft) { draft.ace = el.value.trim(); redrawStep(); } },
        zwCharOff: (el) => { if (draft) { draft.chars = draft.chars.filter((c) => String(c) !== el.dataset.arg); redrawStep(); } },
        zwNotify: () => { if (draft) { draft.notify = !draft.notify; redrawStep(); } },
        zwVehicles: () => { if (draft) { draft.trackVehicles = !draft.trackVehicles; redrawStep(); } },
        zwPriority: (el) => { if (draft) draft.priority = Math.max(0, Math.min(100, parseInt(el.value, 10) || 0)); },
    },
});

// LEGACY LIVE ACTION — tools/zones.lua's callbacks answer with this (the documented exception to
// sections receiving everything via wpSectionData).
NuiRouter.register('zmRefresh', (d) => adopt(d.zones));
