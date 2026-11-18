// ========================================
// SYSTEMS — the Systems Creator's screen: the hub, the editor, and their talk with the server
//
// Loaded on first use by systems-loader.js (a dynamic import: a fault in any Systems file fails the
// Systems Creator alone, never the rest of whip's page). client/systems_editor.lua owns the focus;
// this owns what is drawn. Its own screen, in red,
// beside the Director's, sharing only the blueprint canvas and the card search underneath:
//
//   THE HUB      the left column lists every system (on, off, or switched itself off and why; who
//                has it open, who is testing it) with its actions
//   THE EDITOR   the column becomes the editor's tabs (panels.js) over the blueprint canvas
//                (director/canvas.js, with typed value pins: pins.js), with Save, Check, Test, undo
//
// What is open SURVIVES closing the screen: /systems again comes back to the same system, with any
// unsaved changes still there. A test keeps running while the screen is closed (you play it), and
// the screen shows it going when it comes back (F9).
//
// Every request goes through client/systems_editor.lua: systemsCall (named ops), systemsSave,
// systemsCheck and systemsTest (the document goes up as a latent event there), systemsPlace (aim
// in the world), systemsHere (where the player stands).
// ========================================

import { NuiRouter } from '../router.js';
import { nuiCallback, escapeHtml } from '../utils.js';
import { uiIcon } from '../ui-icons.js';
import { normalise, normaliseDef, History, makeNode, duplicateNodes, removeNodes, findNode, freeId, slug, isId,
    addLink, breakPin, problemCards, copyNodes, pasteNodes, makeComment, removeComment, findComment,
    placesOf, placeValue } from './doc.js';
import { Canvas, GEO } from '../director/canvas.js';
import { openSearch, openMenu, closeSearch, isSearchOpen } from '../director/search.js';
import { watchSelects, isDropdownOpen, closeDropdown } from '../director/dropdown.js';
import { TABS, renderTab, writeField, writeSeg, when, targetOf, powersText, CAT_ORDER, CAT_TITLE } from './panels.js';
import { makeTyped, compatible } from './pins.js';
import { formulaPins } from './formula.js';

const e = escapeHtml;

// Outcomes that mean "it did not happen", beside the Director's own (director/canvas.js BAD_PINS).
const BAD_PINS = ['cantPay', 'notEnough', 'gone', 'notOut', 'refused', 'busy'];

const ed = {
    cards: new Map(),
    types: {},
    typed: null,             // director/canvas.js's typed value pins (pins.js), once the cards are in
    badPins: new Set(BAD_PINS),
    page: 'hub',             // 'hub' | 'editor'
    hub: null, hubSel: null, form: null,
    doc: null, key: null, baseRev: 0, system: null, on: false, onRev: null, editors: [], admin: false,
    powers: '', approvedOk: false, approvedBy: null,
    history: null,
    selected: new Set(), selectedLink: null, selectedNote: null,
    problems: new Map(), problemList: [], checkedAt: 0,
    serverPins: new Map(),   // [nodeId] = { inputs, outputs }: Check's word on a card's own pins
    tab: 'cards', paletteQuery: '', revisions: null,
    lastTest: null,          // { nodes: Set, links: Set, fault }: what ran, lit on the canvas
    test: null,              // the test's report while it runs (server/systems/hub.lua report)
    lastReport: null,        // the last one, once it stopped
    testValues: null,        // [nodeId] = { [pin] = text }
    logLevel: '', logQuery: '',
    busy: false,
};

let root, colEl, canvas, statusTimer = null, tipEl = null;
let shown = false, away = false;
let modal = null;
let clip = null;
let pollTimer = null;

// ============================================================
// Talking to the server
// ============================================================

async function call(op, args) {
    const r = await nuiCallback('systemsCall', { op, args: args || {} });
    if (r && r.ok) return { ok: true, data: r.data || {} };
    return { ok: false, why: (r && r.why) || 'No answer from the server' };
}

async function send(name, payload) {
    const r = await nuiCallback(name, payload);
    if (r && r.ok) return { ok: true, data: r.data || {} };
    return { ok: false, why: (r && r.why) || 'No answer from the server' };
}

const listOf = (x) => (Array.isArray(x) ? x : Object.values(x || {}));

async function loadCards() {
    if (ed.cards.size) return true;
    const r = await call('cards');
    if (!r.ok) { status(r.why, 'error'); return false; }
    ed.types = r.data.types && typeof r.data.types === 'object' ? r.data.types : {};
    for (const def of listOf(r.data.cards)) ed.cards.set(def.type, normaliseDef(def));
    ed.typed = makeTyped(ed, ed.types);
    return true;
}

// ============================================================
// Small pieces: the status line, the confirm box, the pin tip
// ============================================================

function status(text, tone) {
    const el = colEl && colEl.querySelector('.dr-foot');
    if (!el) return;
    el.textContent = text || '';
    el.className = 'dr-foot' + (tone ? ' ' + tone : '');
    clearTimeout(statusTimer);
    if (text && tone !== 'error') statusTimer = setTimeout(() => { el.textContent = ''; el.className = 'dr-foot'; }, 6000);
}

/** `buttons` are given the main answer first and drawn in the house order (the Director's ask): the main one on the
 *  right. */
function ask(title, text, buttons) {
    closeAsk(null);
    const back = document.createElement('div');
    back.className = 'dr-modal-back';
    back.innerHTML = `<div class="dr-modal"><div class="dr-modal-title">${e(title)}</div>`
        + `<div class="dr-modal-text">${e(text)}</div><div class="dr-btns">`
        + buttons.map((b, i) => `<button class="dr-btn ${b.tone || 'ghost'}" data-i="${i}">${e(b.label)}</button>`).reverse().join('')
        + '</div></div>';
    root.appendChild(back);
    return new Promise((resolve) => {
        modal = { el: back, resolve };
        back.addEventListener('click', (ev) => {
            const btn = ev.target.closest('button[data-i]');
            if (btn) closeAsk(buttons[Number(btn.dataset.i)].value);
        });
    });
}

function closeAsk(value) {
    if (!modal) return;
    const m = modal;
    modal = null;
    m.el.remove();
    m.resolve(value);
}

/** A pin's last value (a test), at the pointer. */
function showTip(pinEl, ev) {
    const card = pinEl.closest('.dr-card');
    const vals = card && ed.testValues && ed.testValues[card.dataset.id];
    const v = vals && vals[pinEl.dataset.pin];
    if (v === undefined) { hideTip(); return; }
    if (!tipEl) {
        tipEl = document.createElement('div');
        tipEl.className = 'sy-tip';
        root.appendChild(tipEl);
    }
    tipEl.textContent = 'Last: ' + v;
    tipEl.style.left = ev.clientX + 14 + 'px';
    tipEl.style.top = ev.clientY + 12 + 'px';
    tipEl.style.display = 'block';
}

function hideTip() { if (tipEl) tipEl.style.display = 'none'; }

/** Is the builder typing somewhere on the screen (a field in the column, a comment's name on the
 *  grid)? A redraw from a reply or the test's poll then waits: it would take the field away, and the
 *  next keys would be shortcuts (S2 review: Backspace deleted the comment being named). */
function typing() {
    const a = document.activeElement;
    if (canvas && canvas.renaming) return true;
    return !!(a && root && root.contains(a) && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT'));
}

// ============================================================
// The editor's state
// ============================================================

function setProblems(list) {
    ed.problemList = listOf(list);
    ed.problems = new Map();
    for (const p of ed.problemList) {
        for (const id of problemCards(p)) {
            const cur = ed.problems.get(id) || { error: false, messages: [] };
            if (p.severity === 'error') cur.error = true;
            cur.messages.push(p.message);
            ed.problems.set(id, cur);
        }
    }
    ed.checkedAt = Date.now();
}

function setPins(pins) {
    ed.serverPins = new Map();
    for (const [id, p] of Object.entries(pins && typeof pins === 'object' ? pins : {})) ed.serverPins.set(id, p);
}

ed.formulaError = (node) => {
    const def = ed.cards.get(node.type);
    const f = def && (def.props || []).find((x) => x.key === 'expr');
    const r = formulaPins(node.props.expr == null ? (f ? f.default : 'a + b') : node.props.expr);
    return r.error || null;
};

ed.usesOfVar = (id) => {
    let n = 0;
    for (const node of ed.doc.nodes) {
        const def = ed.cards.get(node.type);
        for (const f of (def && def.props) || []) if (f.kind === 'var' && node.props[f.key] === id) n++;
    }
    return n;
};

ed.select = function (ids) {
    ed.selected = new Set(ids);
    ed.selectedLink = null;
    ed.selectedNote = null;
    canvas.render();
    if (ids.length === 1 && ed.tab !== 'check' && ed.tab !== 'test') ed.tab = 'card';
    if (ed.tab === 'card' || ed.tab === 'check') drawColumn();
    else drawHead();
};

ed.selectLink = function (id) {
    if (ed.selectedLink === id && !ed.selected.size && !ed.selectedNote) return;
    ed.selected = new Set();
    ed.selectedLink = id;
    ed.selectedNote = null;
    canvas.render();
    if (ed.tab === 'card') drawColumn();
};

ed.selectNote = function (id) {
    if (ed.selectedNote === id && !ed.selected.size && !ed.selectedLink) return;
    ed.selected = new Set();
    ed.selectedLink = null;
    ed.selectedNote = id;
    canvas.render();
    if (ed.tab === 'card') drawColumn();
};

ed.changed = function () {
    ed.history.commit(ed.doc);
    for (const id of [...ed.selected]) if (!findNode(ed.doc, id)) ed.selected.delete(id);
    if (ed.selectedLink && !ed.doc.links.some((l) => l.id === ed.selectedLink)) ed.selectedLink = null;
    if (ed.selectedNote && !findComment(ed.doc, ed.selectedNote)) ed.selectedNote = null;
    canvas.render();
    if (ed.tab !== 'cards') drawColumn(); else drawHead();
};

ed.changedNoCommit = function () {
    for (const id of [...ed.selected]) if (!findNode(ed.doc, id)) ed.selected.delete(id);
    ed.selectedLink = null;
    if (ed.selectedNote && !findComment(ed.doc, ed.selectedNote)) ed.selectedNote = null;
    canvas.render();
    drawColumn();
};

function touched() {
    canvas.render();
    drawHead();
}

/** Does a card take a wire from this pin (a search opened by dropping a wire on the ground)? */
function takesWire(def, from) {
    if (!from.value) return from.side === 'out' ? def.inputs.length > 0 : def.outputs.length > 0;
    // A value pin: a card with a value pin on the other side its type fits. A card whose pins come
    // from its fields (a Formula) can take anything.
    if (def.dynamicPins && def.type === 'math.formula') return true;
    const list = from.side === 'out' ? def.values.inputs : def.values.outputs;
    return list.some((p) => (from.side === 'out' ? compatible(from.type, p.type) : compatible(p.type, from.type)));
}

ed.ui = {
    status,
    leftEdge: () => (colEl ? colEl.getBoundingClientRect().right : 0),
    search: (o) => {
        openSearch({
            at: { x: o.x, y: o.y }, cards: ed.cards, order: CAT_ORDER, titles: CAT_TITLE,
            accept: o.from ? (def) => takesWire(def, o.from) : null,
            title: o.from ? 'Add a card here, wired' : 'Add a card',
            onPick: (def) => addCard(def, o.world, o.from),
        });
    },
    cardMenu: (at, id) => {
        openMenu({ at, items: [
            { label: 'Duplicate', run: menuOn(id, duplicateSelected) },
            { label: 'Copy', run: menuOn(id, copySelected) },
            { label: 'Comment round them', run: menuOn(id, commentSelected) },
            { label: 'Break its wires', run: () => {
                const before = ed.doc.links.length;
                ed.doc.links = ed.doc.links.filter((l) => l.from.node !== id && l.to.node !== id);
                if (ed.doc.links.length !== before) ed.changed();
            } },
            { label: 'Delete', danger: true, run: menuOn(id, deleteSelected) },
        ] });
    },
    noteMenu: (at, id) => {
        openMenu({ at, items: [
            { label: 'Name it', run: () => canvas.renameNote(id) },
            { label: 'Select what is in it', run: () => {
                const c = findComment(ed.doc, id);
                if (c) ed.select(ed.doc.nodes.filter((n) => canvas.inNote(n, c)).map((n) => n.id));
            } },
            { label: 'Delete the box (not its cards)', danger: true, run: () => { removeComment(ed.doc, id); ed.changed(); } },
        ] });
    },
    reroute: () => status('A wire cannot be bent here yet: move the cards instead', 'warn'),
};

/** A card menu's choice: on the selection when the card is in it, else on the card alone, picked as the choice runs
 *  (the menu itself opens no page: a right click, the pad's X, is the menu only). */
function menuOn(id, run) {
    return () => {
        if (!ed.selected.has(id)) {
            ed.selected = new Set([id]);
            ed.selectedLink = null;
            ed.selectedNote = null;
            canvas.render();
            if (ed.tab === 'card') drawColumn();
        }
        run();
    };
}

function copySelected() {
    const c = copyNodes(ed.doc, [...ed.selected]);
    if (!c) { status('Select the cards to copy first'); return false; }
    c.from = ed.key;
    clip = c;
    status(`${c.nodes.length} card${c.nodes.length === 1 ? '' : 's'} copied`, 'ok');
    return true;
}

/** Into another system, a variable a card names is cleared: its names are that system's own. */
function pasteClip() {
    if (!clip) { status('Nothing copied yet'); return; }
    const made = pasteNodes(ed.doc, clip, canvas.pastePoint(), GEO.SNAP);
    let cleared = 0;
    if (clip.from !== ed.key) {
        const names = new Set(ed.doc.vars.map((v) => v.id));
        for (const id of made) {
            const n = findNode(ed.doc, id);
            const def = n && ed.cards.get(n.type);
            for (const f of (def && def.props) || []) {
                if (f.kind === 'var' && n.props[f.key] !== undefined && !names.has(n.props[f.key])) {
                    delete n.props[f.key];
                    cleared++;
                }
            }
        }
    }
    ed.selected = new Set(made);
    ed.selectedLink = null;
    ed.selectedNote = null;
    ed.changed();
    status(`${made.length} card${made.length === 1 ? '' : 's'} pasted`
        + (cleared ? ` (${cleared} variable${cleared === 1 ? '' : 's'} this system does not have cleared)` : ''), cleared ? 'warn' : 'ok');
}

function commentSelected() {
    const box = ed.selected.size ? canvas.boxOf([...ed.selected]) : null;
    const c0 = canvas.centre();
    const c = makeComment(ed.doc, box || { x: c0.x - 160, y: c0.y - 100, w: 320, h: 200 }, '');
    ed.selected = new Set();
    ed.selectedLink = null;
    ed.selectedNote = c.id;
    ed.changed();
    canvas.renameNote(c.id);
}

/** A new card, wired to the pin a dropped wire came from: the first pin of the other side that fits. */
function addCard(def, at, from) {
    const node = makeNode(ed.doc, def, at.x - (from && from.side === 'in' ? GEO.W : 0), at.y - GEO.HEAD / 2);
    node.x = Math.round(node.x / GEO.SNAP) * GEO.SNAP;
    node.y = Math.round(node.y / GEO.SNAP) * GEO.SNAP;
    if (from) {
        if (!from.value) {
            if (from.side === 'out' && def.inputs.length) addLink(ed.doc, { node: from.node, pin: from.pin }, { node: node.id, pin: def.inputs[0] });
            else if (from.side === 'in' && def.outputs.length) addLink(ed.doc, { node: node.id, pin: def.outputs[0] }, { node: from.node, pin: from.pin });
        } else {
            const vp = ed.typed.valuePins(node, def, ed.doc);
            if (from.side === 'out') {
                const p = vp.inputs.find((x) => compatible(from.type, x.type));
                if (p) addLink(ed.doc, { node: from.node, pin: from.pin }, { node: node.id, pin: p.key });
            } else {
                const p = vp.outputs.find((x) => compatible(x.type, from.type));
                if (p) {
                    breakPin(ed.doc, from.node, from.pin, 'in');   // a value input takes one wire
                    addLink(ed.doc, { node: node.id, pin: p.key }, { node: from.node, pin: from.pin });
                }
            }
        }
    }
    ed.selected = new Set([node.id]);
    ed.selectedLink = null;
    if (ed.tab !== 'check' && ed.tab !== 'test') ed.tab = 'card';
    ed.changed();
}

function addAtCentre(def) {
    const c = canvas.centre();
    let x = c.x - 118, y = c.y - 40;
    while (ed.doc.nodes.some((n) => Math.abs(n.x - x) < 24 && Math.abs(n.y - y) < 24)) { x += 32; y += 32; }
    addCard(def, { x, y: y + GEO.HEAD / 2 }, null);
}

function deleteSelected() {
    if (canvas.deleteSelected()) return;
    if (ed.selectedNote) {
        removeComment(ed.doc, ed.selectedNote);
        ed.selectedNote = null;
        ed.changed();
        return;
    }
    if (!ed.selected.size) return;
    removeNodes(ed.doc, [...ed.selected]);
    ed.selected = new Set();
    ed.changed();
}

function duplicateSelected() {
    if (!ed.selected.size) return;
    ed.selected = new Set(duplicateNodes(ed.doc, [...ed.selected], 48, 48));
    ed.changed();
}

function undo() {
    commitField();
    const d = ed.history.undo(ed.doc);
    if (!d) { status('Nothing to undo'); return; }
    ed.doc = d;
    ed.changedNoCommit();
}

function redo() {
    const d = ed.history.redo();
    if (!d) { status('Nothing to redo'); return; }
    ed.doc = d;
    ed.changedNoCommit();
}

function commitField() {
    const a = document.activeElement;
    if (a && colEl.contains(a) && a.dataset && a.dataset.t) a.blur();
    if (canvas) canvas.commitRename();
    if (ed.history) ed.history.commit(ed.doc);
}

// ============================================================
// Opening, saving, checking, switching on
// ============================================================

function readOpen(d) {
    ed.system = d.system || ed.system;
    ed.on = !!d.on;
    ed.onRev = d.onRev || null;
    ed.editors = listOf(d.editors);
    ed.admin = d.admin === true;
    // What the SAVED revision may do (what an approval is for), and what the document may do now
    // (the same until it is edited; Check says when it changes).
    ed.savedPowers = typeof d.powers === 'string' ? d.powers : '';
    ed.powers = ed.savedPowers;
    ed.approvedOk = d.approvedOk === true;
    ed.approvedBy = ed.system && ed.system.approvedRev === d.rev ? ed.system.approvedBy : null;
}

async function openSystem(key, rev) {
    if (!(await loadCards())) return;
    status('Opening…');
    const r = await call('open', { key, rev: rev || 0 });
    if (!r.ok) { status(r.why, 'error'); return; }
    const d = r.data;
    ed.page = 'editor';
    ed.key = key;
    ed.doc = normalise(d.doc);
    ed.baseRev = d.system.draftRev;
    readOpen(d);
    ed.history = new History(ed.doc);
    ed.selected = new Set();
    ed.selectedLink = null;
    ed.selectedNote = null;
    ed.revisions = null;
    ed.lastTest = null;
    ed.testValues = null;
    ed.lastReport = null;
    ed.tab = 'cards';
    setProblems(d.problems);
    setPins(d.pins);
    const unplaced = placesOf(ed.doc, ed.cards).filter((x) => !x.value);
    if (rev && rev !== ed.baseRev) {
        ed.history.markSaved({});
        status(`Revision ${rev} is open: Save makes it the draft again`, 'warn');
    } else if (unplaced.length) {
        ed.tab = 'places';
        status(`Before testing, place ${unplaced.length === 1 ? 'one place' : unplaced.length + ' places'}: Places tab`, 'warn');
    } else {
        status(ed.editors.length ? `${ed.editors.join(', ')} has this open too: the first to save wins` : '', ed.editors.length ? 'warn' : '');
    }
    drawAll();
    canvas.frame();
    // A test of this one already going (the screen closed and came back): its report.
    pollTest(true);
}

async function save(note) {
    if (ed.busy) return false;
    commitField();
    if (!ed.history.isDirty(ed.doc)) { status('Nothing to save'); return true; }
    ed.busy = true;
    status('Saving…');
    const r = await send('systemsSave', { key: ed.key, baseRev: ed.baseRev, doc: ed.doc, note: note || '' });
    ed.busy = false;
    if (r.ok) {
        ed.baseRev = r.data.rev;
        ed.history.markSaved(ed.doc);
        setProblems(r.data.problems);
        setPins(r.data.pins);
        if (typeof r.data.powers === 'string') ed.savedPowers = ed.powers = r.data.powers;
        ed.approvedOk = r.data.approvedOk === true;   // a new revision is approved afresh
        ed.approvedBy = null;
        const errs = ed.problemList.filter((p) => p.severity === 'error').length;
        status(`Saved as revision ${ed.baseRev}` + (errs ? ` (${errs} problem${errs === 1 ? '' : 's'}: see Check)` : ''), errs ? 'warn' : 'ok');
        canvas.render();
        drawColumn();
        return true;
    }
    if (/changed by/i.test(r.why)) {
        const pick = await ask('Someone saved first', r.why + '. Your changes are still here.', [
            { label: 'Save mine as a copy', value: 'copy', tone: 'primary' },
            { label: 'Open theirs (lose mine)', value: 'theirs', tone: 'danger' },
            { label: 'Cancel', value: null },
        ]);
        if (pick === 'theirs') { await openSystem(ed.key); return false; }
        if (pick === 'copy') return saveAsCopy();
        return false;
    }
    status(r.why, 'error');
    return false;
}

async function saveAsCopy() {
    const name = (ed.doc.name || ed.key) + ' (copy)';
    const used = new Set(((ed.hub && ed.hub.systems) || []).map((s) => s.key));
    used.add(ed.key);
    const key = freeId(used, slug(ed.key, 'system') + '_copy');
    const made = await call('create', { key, name, from: 'copy:' + ed.key });
    if (!made.ok) { status(made.why, 'error'); return false; }
    ed.key = key;
    ed.baseRev = made.data.system.draftRev;
    ed.system = made.data.system;
    ed.on = false;
    ed.onRev = null;
    ed.doc.name = name;
    ed.history.markSaved({});
    return save('saved as a copy');
}

async function check(quiet) {
    if (!ed.doc) return;
    commitField();
    if (!quiet) status('Checking…');
    const key = ed.key, doc = ed.doc;
    const r = await send('systemsCheck', { doc });
    // AFTER THE WAIT, ASKED AGAIN: still the same system open (its problems are not another's).
    if (ed.key !== key || ed.doc !== doc || !ed.history) return;
    if (!r.ok) { if (!quiet) status(r.why, 'error'); return; }
    setProblems(r.data.problems);
    setPins(r.data.pins);
    // What it may do now: the check's while edited, else the saved revision's (an undo back to it).
    if (typeof r.data.powers === 'string') ed.powers = ed.history.isDirty(ed.doc) ? r.data.powers : ed.savedPowers;
    if (!quiet) {
        status(r.data.ok ? 'It passes its check' : 'It does not pass its check yet', r.data.ok ? 'ok' : 'warn');
        ed.tab = 'check';
    }
    if (quiet && typing()) { drawHead(); return; }   // the builder is typing: the badges come with the next redraw
    canvas.render();
    drawColumn();
}

async function approve() {
    // An approval is for the SAVED revision: what it may do, as saved (the server compares exactly).
    const p = powersText(ed.savedPowers);
    const pick = await ask('Approve this revision?', `Revision ${ed.baseRev} of ${ed.doc.name} may ${p}. Approving lets it be switched on; a new revision asks again.`, [
        { label: 'Approve', value: true, tone: 'primary' }, { label: 'Cancel', value: null },
    ]);
    if (!pick) return false;
    const r = await call('approve', { key: ed.key, rev: ed.baseRev, powers: ed.savedPowers });
    if (!r.ok) { status(r.why, 'error'); return false; }
    ed.approvedOk = true;
    status(`Revision ${ed.baseRev} approved to ${p}`, 'ok');
    drawColumn();
    return true;
}

async function activate(key, rev) {
    const own = key === undefined;
    key = own ? ed.key : key;
    if (own && ed.history.isDirty(ed.doc)) { status('Save first: what is switched on is a saved revision', 'warn'); return; }
    status('Switching on…');
    let r = await call('activate', { key, rev: own ? ed.baseRev : (rev || 0) });
    if (r.ok && r.data.ok === false && r.data.needsApproval !== undefined) {
        // Its powers need an admin's approval for this revision first: asked here, then on again.
        if (!own) { status(`Revision ${r.data.rev} may ${powersText(r.data.needsApproval)}: open it and approve it (Check)`, 'warn'); return; }
        ed.savedPowers = ed.powers = r.data.needsApproval;
        if (!(await approve())) return;
        r = await call('activate', { key, rev: ed.baseRev });
    }
    if (!r.ok) { status(r.why, 'error'); return; }
    if (r.data.ok === false) { status(`It may ${powersText(r.data.needsApproval)}: approve it first (Check)`, 'warn'); return; }
    if (own) { ed.on = true; ed.onRev = r.data.rev; }
    status(`On at revision ${r.data.rev}`, 'ok');
    if (own) drawColumn(); else refreshHub();
}

async function deactivate(key) {
    const r = await call('deactivate', { key });
    if (!r.ok) { status(r.why, 'error'); return false; }
    if (key === ed.key) { ed.on = false; ed.onRev = null; }
    status('Switched off', 'ok');
    return true;
}

// ============================================================
// Test (server/systems/hub.lua)
// ============================================================

async function test() {
    if (ed.busy) return;
    commitField();
    status('Starting a test…');
    // Its places go too: drawn in the world for as long as the test runs.
    const { points, lines } = worldPlaces(null, null);
    const r = await send('systemsTest', { key: ed.key, doc: ed.doc, points, lines });
    if (!r.ok) { status(r.why, 'error'); return; }
    if (r.data.ok === false) {
        setProblems(r.data.problems);
        ed.tab = 'check';
        canvas.render();
        drawColumn();
        status('Not ready to test: see Check', 'error');
        return;
    }
    // client/systems_editor.lua closes the screen: the game is played as normal, the test going.
    ed.lastTest = { nodes: new Set(), links: new Set(), fault: null };
    ed.testValues = null;
    ed.test = { status: 'running', steps: 0, pulses: 0, seconds: 0, log: [] };
    ed.tab = 'test';
}

async function testStop() {
    stopPolling();
    const r = await send('systemsTestStop', {});
    if (!r.ok) { status(r.why, 'error'); return; }
    if (r.data.status && r.data.status !== 'none') takeReport(r.data);
    ed.lastReport = ed.test;
    ed.test = null;
    status('Test stopped: what ran is lit, and each pin keeps its last value (hover it)', 'ok');
    canvas.render();
    drawColumn();
}

/** A test's report into the editor: its log and counts, what ran (lit), each pin's last value. */
function takeReport(rep) {
    ed.test = rep;
    rep.log = listOf(rep.log);
    ed.testValues = rep.values && typeof rep.values === 'object' ? rep.values : null;
    const nodes = new Set(), links = new Set();
    for (const s of listOf(rep.trace)) {
        if (!s || typeof s.node !== 'string') continue;
        nodes.add(s.node);
        if (s.kind === 'enter' && s.from) {
            const l = ed.doc && ed.doc.links.find((k) => k.from.node === s.from && k.from.pin === s.fromPin && k.to.node === s.node && k.to.pin === s.pin);
            if (l) links.add(l.id);
        }
    }
    // A value card is never in the trace (it is worked out when something reads it): one that has
    // values was worked out, so it ran. Then value wires into a card that ran carried something: lit.
    if (ed.doc && ed.testValues) {
        for (const id of Object.keys(ed.testValues)) {
            const n = findNode(ed.doc, id);
            const def = n && ed.cards.get(n.type);
            if (def && def.kind === 'value') nodes.add(id);
        }
    }
    if (ed.doc) {
        for (const l of ed.doc.links) {
            if (nodes.has(l.to.node) && ed.testValues && ed.testValues[l.to.node] && ed.testValues[l.to.node][l.to.pin] !== undefined) links.add(l.id);
        }
    }
    const fault = listOf(rep.log).filter((l) => l.level === 'error' && l.node).pop();
    ed.lastTest = { nodes, links, fault: fault ? fault.node : null, reason: fault ? fault.msg : null };
}

/** While the editor is up with a test going: its report every second and a half. */
async function pollTest(first) {
    if (!shown || away || ed.page !== 'editor') return;
    const key = ed.key;
    const r = await call('testReport');
    // AFTER THE WAIT, ASKED AGAIN: the screen closed, the editor left, another system opened.
    if (!r.ok || !shown || away || ed.page !== 'editor' || ed.key !== key) return;
    if (r.data.status === 'none') {
        stopPolling();
        if (ed.test && ed.test.status === 'running') { ed.lastReport = ed.test; ed.test = null; drawColumn(); }
        return;
    }
    if (r.data.key !== ed.key) {
        if (first) status(`You are testing ${r.data.name || r.data.key}: open it to see the test`, 'warn');
        return;
    }
    takeReport(r.data);
    if (first) ed.tab = 'test';
    // Not under the builder's fingers: the next poll draws what this one could not.
    if (!typing()) {
        canvas.render();
        drawColumn();
    } else {
        drawHead();
    }
    if (!pollTimer) pollTimer = setInterval(() => pollTest(false), 1500);
}

function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
}

/** Steps a running system (live, or the test) took: the cards light as they go. */
function pulseSteps(steps) {
    const latest = new Map();
    for (const s of listOf(steps)) if (s && typeof s.node === 'string' && (s.kind === 'enter' || s.kind === 'resume' || s.kind === 'trigger')) latest.set(s.node, s);
    for (const s of latest.values()) {
        const l = s.from ? ed.doc.links.find((k) => k.from.node === s.from && k.from.pin === s.fromPin && k.to.node === s.node && k.to.pin === s.pin) : null;
        canvas.pulse(s.node, l ? l.id : null);
    }
}

// ============================================================
// Places: Here, Aim in the world (client/systems_editor.lua)
// ============================================================

function round3(n) { return Math.round(n * 1000) / 1000; }

function writePlace(t, k, c) {
    const obj = targetOf(ed, t);
    if (!obj || !c || typeof c.x !== 'number') return false;
    obj[k] = { x: round3(c.x), y: round3(c.y), z: round3(c.z) };
    return true;
}

async function placeHere(t, k) {
    const r = await send('systemsHere', {});
    if (!r.ok) { status(r.why, 'error'); return; }
    if (writePlace(t, k, r.data)) { ed.changed(); status('Set to where you stand', 'ok'); check(true); }
}

/** The system's places as the world draws them: a card with two (a line's ends) is a line, the rest
 *  points. `skipNode` / `skipKey`: the one being placed, left out (and its line's other end answered
 *  as `partner`). */
function worldPlaces(skipNode, skipKey) {
    const points = [], lines = [];
    let partner = null;
    const byNode = new Map();
    for (const x of placesOf(ed.doc, ed.cards)) {
        if (!byNode.has(x.node.id)) byNode.set(x.node.id, []);
        byNode.get(x.node.id).push(x);
    }
    for (const [id, list] of byNode) {
        if (list.length === 2) {
            const [a, b] = list;
            if (id === skipNode) partner = (a.field.key === skipKey ? b.value : a.value) || null;
            else if (a.value && b.value) lines.push({ a: a.value, b: b.value });
            else for (const x of list) if (x.value) points.push(x.value);
        } else {
            for (const x of list) if (x.value && !(id === skipNode && x.field.key === skipKey)) points.push(x.value);
        }
    }
    return { points, lines, partner };
}

/** Aim in the world: the screen hides, the system's other places are drawn, and a line's other end. */
function placeAim(t, k) {
    commitField();
    const nodeId = t.slice(t.indexOf(':') + 1);
    const node = findNode(ed.doc, nodeId);
    const def = node && ed.cards.get(node.type);
    if (!node || !def) return;
    const { points, lines, partner } = worldPlaces(node.id, k);
    const field = (def.props || []).find((f) => f.key === k);
    nuiCallback('systemsPlace', { node: t, key: k, label: `${def.title}: ${field ? field.label || k : k}`, points, lines, partner });
}

// ============================================================
// Leaving the editor; the hub
// ============================================================

async function leaveEditor() {
    commitField();
    if (ed.history && ed.history.isDirty(ed.doc)) {
        const pick = await ask('Unsaved changes', `${ed.doc.name} has changes that are not saved.`, [
            { label: 'Save', value: 'save', tone: 'primary' },
            { label: 'Throw them away', value: 'drop', tone: 'danger' },
            { label: 'Stay', value: null },
        ]);
        if (pick === null) return false;
        if (pick === 'save' && !(await save())) return false;
    }
    stopPolling();
    // No longer editing it: who has it open, its live pulses (client/systems_editor.lua systemsLeft).
    nuiCallback('systemsLeft');
    ed.page = 'hub';
    ed.doc = null;
    ed.key = null;
    ed.history = null;
    ed.selected = new Set();
    ed.test = null;
    ed.testValues = null;
    ed.lastTest = null;
    canvas.render();
    drawAll();
    refreshHub();
    return true;
}

async function refreshHub() {
    const r = await call('list');
    if (!r.ok) { status(r.why, 'error'); return; }
    const d = r.data;
    d.systems = listOf(d.systems);
    d.examples = listOf(d.examples);
    for (const s of d.systems) { s.editors = listOf(s.editors); s.testers = listOf(s.testers); }
    ed.hub = d;
    ed.admin = d.admin === true;
    if (ed.page === 'hub') drawAll();
}

function systemRow(s) {
    const open = ed.hubSel === s.key;
    const pill = s.on ? `<span class="dr-pill ok">On · r${s.onRev}</span>`
        : s.status === 'faulted' ? '<span class="dr-pill err"><i class="sy-glyph"></i>Switched itself off</span>'
        : '<span class="dr-pill">Off</span>';
    const live = s.on ? `${s.pulses || 0} going${s.errors ? ` · ${s.errors} error${s.errors === 1 ? '' : 's'} this minute` : ''}${s.paused ? ' · paused (too busy)' : ''}` : `draft r${s.draftRev}`;
    let body = '';
    if (open) {
        const newer = s.on && s.onRev !== s.draftRev;
        body = '<div class="dr-item-body">'
            + `<div class="dr-meta">Made by ${e(s.createdBy || 'the server')} · changed by ${e(s.updatedBy || 'the server')} · draft r${s.draftRev}</div>`
            + (s.description ? `<div class="dr-hint">${e(s.description)}</div>` : '')
            + (s.status === 'faulted' && s.reason ? `<div class="dr-prob error"><i class="sy-glyph"></i>${e(s.reason)}</div>` : '')
            + (s.approvedRev ? `<div class="dr-meta">Revision ${s.approvedRev} approved to ${e(powersText(s.approvedPowers) || 'nothing')}${s.approvedBy ? ` by ${e(s.approvedBy)}` : ''}</div>` : '')
            + (newer ? `<div class="dr-hint">Draft r${s.draftRev} is newer than the live r${s.onRev}.</div>` : '')
            + (s.testers.length ? `<div class="dr-meta">Being tested by ${e(s.testers.join(', '))}</div>` : '')
            + '<div class="dr-btns">'
            + `<button class="dr-btn primary" data-act="edit" data-key="${e(s.key)}">Edit</button>`
            + (ed.admin && s.on ? `<button class="dr-btn" data-act="hub-off" data-key="${e(s.key)}">Switch off</button>` : '')
            + (ed.admin && (!s.on || newer) ? `<button class="dr-btn" data-act="hub-on" data-key="${e(s.key)}" data-rev="${s.draftRev}">Switch on r${s.draftRev}</button>` : '')
            + `<button class="dr-btn" data-act="hub-copy" data-key="${e(s.key)}">Duplicate</button>`
            + (ed.admin && !s.on ? `<button class="dr-btn danger" data-act="hub-delete" data-key="${e(s.key)}">Delete</button>` : '')
            + '</div></div>';
    }
    return `<div class="dr-item${open ? ' open' : ''}">`
        + `<div class="dr-item-head" data-act="hub-open" data-key="${e(s.key)}">`
        + `<div class="dr-item-main"><b>${e(s.name)}</b><span>${e(live)}</span>`
        + (s.editors.length ? `<span class="dr-warn-text">Open in the editor: ${e(s.editors.join(', '))}</span>` : '')
        + `</div><div class="dr-pills">${pill}</div></div>${body}</div>`;
}

function formHtml() {
    const f = ed.form;
    const from = f.mode === 'copy'
        ? `<div class="dr-hint">A copy of ${e(f.from)}, as its draft is now.</div>`
        : '<div class="dr-row"><div class="dr-label">Start from</div><div class="dr-seg">'
            + [['', 'Nothing']].concat((ed.hub.examples || []).map((x) => ['example:' + x, 'Example: ' + exampleName(x)]))
                .map(([v, t]) => `<button class="dr-seg-key${f.start === v ? ' on' : ''}" data-act="form-start" data-v="${e(v)}">${e(t)}</button>`).join('')
            + '</div></div>';
    return '<div class="dr-item open"><div class="dr-world-edit">'
        + `<div class="dr-title2">${f.mode === 'copy' ? 'Duplicate' : 'New system'}</div>`
        + `<div class="dr-row"><div class="dr-label">Name</div><input class="dr-field dr-form-name" type="text" maxlength="80" value="${e(f.name || '')}" spellcheck="false"></div>`
        + `<div class="dr-row"><div class="dr-label">Key<span>letters, digits, _ and -</span></div><input class="dr-field dr-form-key" type="text" maxlength="64" value="${e(f.key || '')}" spellcheck="false"></div>`
        + from
        + '<div class="dr-btns"><button class="dr-btn primary" data-act="form-make">Make it</button><button class="dr-btn ghost" data-act="form-cancel">Cancel</button></div>'
        + '</div></div>';
}

const EXAMPLE_NAMES = { speedcam: 'Speed Camera', carwash: 'Car Wash' };
function exampleName(x) { return EXAMPLE_NAMES[x] || x.replace(/_/g, ' '); }

function hubBody() {
    const h = ed.hub;
    if (!h) return '<div class="dr-none">Loading…</div>';
    let html = '';
    if (h.off) html += `<div class="dr-prob error"><i class="sy-glyph"></i>${e(h.off)}</div>`;
    html += '<div class="dr-btns"><button class="dr-btn primary" data-act="new">+ New system</button>'
        + '<button class="dr-btn ghost" data-act="refresh">Refresh</button></div>';
    if (h.testing) html += `<div class="dr-hint">You are testing ${e(h.testing)}: open it to see the test, or stop it.</div>`;
    if (ed.form) html += formHtml();
    html += h.systems.length ? h.systems.map(systemRow).join('')
        : '<div class="dr-none">No systems yet. A system is a mechanic that is always on: a speed camera, a car wash, a fuel pump. Make one with + New system.</div>';
    return html;
}

// ============================================================
// Drawing the column
// ============================================================

/** An element's content, changed IN PLACE where it can be. A field left by a click on a button redraws
 *  the head (its blur); rewriting the buttons took the one under the pointer away between its press and
 *  release, and the click was lost (S2 review). So when the new content has the same elements as the
 *  old, each one is kept and only its attributes and text change; only a different shape is rebuilt. */
function setHtml(el, html) {
    if (el.__html === html) return;
    el.__html = html;
    const t = document.createElement('template');
    t.innerHTML = html;
    if (!sameShape(el, t.content)) { el.innerHTML = html; return; }
    patch(el, t.content);
}

function sameShape(a, b) {
    if (a.childNodes.length !== b.childNodes.length) return false;
    for (let i = 0; i < a.childNodes.length; i++) {
        const x = a.childNodes[i], y = b.childNodes[i];
        if (x.nodeType !== y.nodeType || x.nodeName !== y.nodeName) return false;
        if (x.nodeType === 1 && !sameShape(x, y)) return false;
    }
    return true;
}

function patch(a, b) {
    for (let i = 0; i < a.childNodes.length; i++) {
        const x = a.childNodes[i], y = b.childNodes[i];
        if (x.nodeType === 3) { if (x.nodeValue !== y.nodeValue) x.nodeValue = y.nodeValue; continue; }
        if (x.nodeType !== 1) continue;
        for (const at of [...x.attributes]) if (!y.hasAttribute(at.name)) x.removeAttribute(at.name);
        for (const at of [...y.attributes]) if (x.getAttribute(at.name) !== at.value) x.setAttribute(at.name, at.value);
        patch(x, y);
    }
}

function drawHead() {
    const head = colEl.querySelector('.dr-head');
    if (ed.page === 'hub') {
        const n = ed.hub ? ed.hub.systems.length : 0;
        const on = ed.hub ? ed.hub.systems.filter((s) => s.on).length : 0;
        setHtml(head, '<div class="dr-head-main"><div class="dr-title">Systems Creator</div>'
            + `<div class="dr-sub">${n} system${n === 1 ? '' : 's'} · ${on} on</div></div>`
            + '<button class="dr-icon" data-act="close" title="Close (Esc)">' + uiIcon('close') + '</button>');
        return;
    }
    const dirty = ed.history.isDirty(ed.doc);
    const testing = ed.test && ed.test.status === 'running';
    setHtml(head, '<button class="dr-icon" data-act="back" title="Back to the list">' + uiIcon('back') + '</button>'
        + `<div class="dr-head-main"><div class="dr-title">${e(ed.doc.name)}</div>`
        + `<div class="dr-sub">${e(ed.key)} · draft r${ed.baseRev}${ed.on ? ` · on r${ed.onRev}` : ''}`
        + `${dirty ? ' · <b class="dr-dirty">not saved</b>' : ''}${testing ? ' · <b class="sy-testing">testing</b>' : ''}</div></div>`
        + '<button class="dr-icon" data-act="close" title="Close (Esc)">' + uiIcon('close') + '</button>');
    const bar = colEl.querySelector('.dr-bar');
    setHtml(bar, `<button class="dr-btn primary" data-act="save"${dirty ? '' : ' disabled'}>Save</button>`
        + '<button class="dr-btn" data-act="check">Check</button>'
        + (testing ? '<button class="dr-btn danger" data-act="test-stop" title="Stop the test">Stop</button>'
            : '<button class="dr-btn" data-act="test" title="Run it now for you alone: no money moves, and the items it gives go back when it ends">Test</button>')
        + `<button class="dr-btn ghost" data-act="undo" title="Undo (Ctrl+Z)"${ed.history.canUndo() || dirty ? '' : ' disabled'}>Undo</button>`
        + `<button class="dr-btn ghost" data-act="redo" title="Redo (Ctrl+Y)"${ed.history.canRedo() ? '' : ' disabled'}>Redo</button>`);
}

function drawColumn() {
    drawHead();
    const body = colEl.querySelector('.dr-body');
    const scroll = body.scrollTop;
    body.innerHTML = ed.page === 'hub' ? hubBody() : renderTab(ed);
    body.scrollTop = scroll;
    colEl.querySelectorAll('.dr-tab').forEach((t) => t.classList.toggle('on', t.dataset.tab === ed.tab));
}

function drawAll() {
    const editing = ed.page === 'editor';
    colEl.classList.toggle('editing', editing);
    colEl.querySelector('.dr-bar').style.display = editing ? '' : 'none';
    colEl.querySelector('.dr-tabs').style.display = editing ? '' : 'none';
    root.querySelector('.dr-empty').textContent = editing
        ? 'Right-click the grid to add a card, or pick one in Cards. Start with a "When…" card.'
        : 'Pick a system on the left, or make a new one.';
    drawColumn();
    canvas.render();
    if (!editing) root.querySelector('.dr-empty').style.display = '';
}

// ============================================================
// The column's clicks and fields
// ============================================================

async function onAct(act, el) {
    switch (act) {
        case 'close': return closeScreen();
        case 'back': return leaveEditor();
        // ---- the hub ----
        // (A New / Duplicate form half filled in keeps what was typed through a redraw.)
        case 'refresh': if (ed.form) readForm(); return refreshHub();
        case 'new': ed.form = { mode: 'new', start: '', name: '', key: '' }; return drawColumn();
        case 'form-cancel': ed.form = null; return drawColumn();
        case 'form-start': ed.form.start = el.dataset.v; readForm(); return drawColumn();
        case 'form-make': return makeFromForm();
        case 'hub-open': if (ed.form) readForm(); ed.hubSel = ed.hubSel === el.dataset.key ? null : el.dataset.key; return drawColumn();
        case 'edit': return openSystem(el.dataset.key);
        case 'hub-on': return activate(el.dataset.key, Number(el.dataset.rev) || 0);
        case 'hub-off': await deactivate(el.dataset.key); return refreshHub();
        case 'hub-copy': {
            const s = ed.hub.systems.find((x) => x.key === el.dataset.key);
            const used = new Set(ed.hub.systems.map((x) => x.key));
            ed.form = { mode: 'copy', from: el.dataset.key, name: (s ? s.name : el.dataset.key) + ' (copy)', key: freeId(used, el.dataset.key + '_') };
            return drawColumn();
        }
        case 'hub-delete': return deleteSystem(el.dataset.key);
        // ---- the editor ----
        case 'save': return save();
        case 'check': return check(false);
        case 'undo': return undo();
        case 'redo': return redo();
        case 'approve': return approve();
        case 'activate': return activate();
        case 'deactivate': await deactivate(ed.key); return drawColumn();
        case 'test': return test();
        case 'test-stop': return testStop();
        case 'test-play': return closeScreen();
        case 'clear-test': ed.lastTest = null; ed.lastReport = null; ed.testValues = null; canvas.render(); return drawColumn();
        case 'dup-sel': return duplicateSelected();
        case 'del-sel': return deleteSelected();
        case 'place-here': return placeHere(el.dataset.t, el.dataset.k);
        case 'place-aim': return placeAim(el.dataset.t, el.dataset.k);
        case 'place-clear': {
            const obj = targetOf(ed, el.dataset.t);
            if (obj && obj[el.dataset.k] !== undefined) { delete obj[el.dataset.k]; ed.changed(); }
            return;
        }
        case 'goto-prob': {
            const p = ed.problemList[Number(el.dataset.i)];
            const ids = p ? problemCards(p).filter((id) => findNode(ed.doc, id)) : [];
            if (ids.length) {
                ed.selected = new Set(ids);
                ed.selectedLink = null;
                ed.selectedNote = null;
                canvas.render();
                canvas.frame(ids);
                drawColumn();
            }
            return;
        }
        case 'goto-node': {
            if (findNode(ed.doc, el.dataset.id)) {
                ed.selected = new Set([el.dataset.id]);
                ed.selectedLink = null;
                ed.selectedNote = null;
                canvas.render();
                canvas.frame([el.dataset.id]);
                if (ed.tab !== 'test') { ed.tab = 'card'; drawColumn(); }
            }
            return;
        }
        case 'add-var': {
            const id = freeId(new Set(ed.doc.vars.map((v) => v.id)), 'var');
            ed.doc.vars.push({ id, type: 'number', scope: 'everyone', default: 0 });
            return ed.changed();
        }
        case 'remove-var': {
            const id = el.dataset.id;
            const uses = ed.usesOfVar(id);
            if (uses) {
                const pick = await ask('Remove it?', `${uses} card${uses === 1 ? ' uses' : 's use'} it; they will need another.`, [
                    { label: 'Remove', value: true, tone: 'danger' }, { label: 'Cancel', value: null },
                ]);
                if (!pick) return;
            }
            ed.doc.vars = ed.doc.vars.filter((v) => v.id !== id);
            return ed.changed();
        }
        case 'history': {
            const r = await call('history', { key: ed.key });
            if (!r.ok) { status(r.why, 'error'); return; }
            ed.revisions = listOf(r.data.revisions);
            return drawColumn();
        }
        case 'load-rev': {
            const rev = Number(el.dataset.rev);
            if (ed.history.isDirty(ed.doc)) {
                const pick = await ask('Open an older revision?', 'Your unsaved changes would be lost.', [
                    { label: 'Open it', value: true, tone: 'danger' }, { label: 'Cancel', value: null },
                ]);
                if (!pick) return;
            }
            return openSystem(ed.key, rev);
        }
        case 'delete-system': return deleteSystem(ed.key);
        default: return;
    }
}

async function deleteSystem(key) {
    const pick = await ask('Delete this system?', `${key} goes from the list for good (its revisions are kept in the database). It must be off.`, [
        { label: 'Delete', value: true, tone: 'danger' }, { label: 'Cancel', value: null },
    ]);
    if (!pick) return;
    const r = await call('delete', { key });
    status(r.ok ? 'Deleted' : r.why, r.ok ? 'ok' : 'error');
    if (!r.ok) return;
    ed.hubSel = null;
    if (ed.page === 'editor' && ed.key === key) {
        ed.history.markSaved(ed.doc);   // nothing left to save it into
        await leaveEditor();
        return;
    }
    refreshHub();
}

function readForm() {
    const n = colEl.querySelector('.dr-form-name'), k = colEl.querySelector('.dr-form-key');
    if (n) ed.form.name = n.value;
    if (k) ed.form.key = k.value;
}

async function makeFromForm() {
    readForm();
    const f = ed.form;
    const name = (f.name || '').trim();
    const key = (f.key || '').trim() || slug(name, '');
    if (!name) { status('Give it a name', 'warn'); return; }
    if (!/^[A-Za-z0-9_-]{2,64}$/.test(key)) { status('A key is 2-64 letters, digits, _ and -', 'warn'); return; }
    const from = f.mode === 'copy' ? 'copy:' + f.from : (f.start || '');
    const r = await call('create', { key, name, from });
    if (!r.ok) { status(r.why, 'error'); return; }
    ed.form = null;
    await refreshHub();
    return openSystem(key);
}

function renameVar(el) {
    const old = el.dataset.id;
    const id = el.value.trim();
    if (id === old) return;
    const taken = new Set(ed.doc.vars.map((v) => v.id));
    if (!/^[A-Za-z_][A-Za-z0-9_]{0,31}$/.test(id) || taken.has(id)) {
        status(taken.has(id) ? `${id} is taken` : 'A variable name is letters, digits and _ (not starting with a digit)', 'warn');
        el.value = old;
        return;
    }
    ed.doc.vars.find((v) => v.id === old).id = id;
    for (const n of ed.doc.nodes) {
        const def = ed.cards.get(n.type);
        for (const f of (def && def.props) || []) if (f.kind === 'var' && n.props[f.key] === old) n.props[f.key] = id;
    }
    ed.changed();
}

/** A variable's type changed: its starting value follows, and Remember goes where it cannot be. */
function coerceVar(v) {
    if (v.type === 'number') v.default = typeof v.default === 'number' ? v.default : (parseFloat(v.default) || 0);
    else if (v.type === 'bool') v.default = v.default === true;
    else if (v.type === 'text') v.default = v.default === undefined || v.default === null ? '' : String(v.default);
    else delete v.default;
    if (!(['number', 'text', 'bool'].includes(v.type)) || v.scope === 'car') delete v.remember;
}

function bindColumn() {
    colEl.addEventListener('click', (ev) => {
        const seg = ev.target.closest('.dr-seg-key[data-t]');
        if (seg) {
            if (writeSeg(ed, seg)) {
                if (seg.dataset.t.startsWith('var:') && (seg.dataset.k === 'type' || seg.dataset.k === 'scope')) {
                    const v = ed.doc.vars.find((x) => 'var:' + x.id === seg.dataset.t);
                    if (v) coerceVar(v);
                }
                if (seg.dataset.t.startsWith('var:') && seg.dataset.k === 'remember') {
                    const v = ed.doc.vars.find((x) => 'var:' + x.id === seg.dataset.t);
                    if (v && v.remember !== true) delete v.remember;
                }
                ed.changed();
            }
            return;
        }
        const tab = ev.target.closest('.dr-tab');
        if (tab) {
            commitField();
            ed.tab = tab.dataset.tab;
            drawColumn();
            return;
        }
        const pal = ev.target.closest('.dr-pal-row');
        if (pal && !palDrag.moved) {
            const def = ed.cards.get(pal.dataset.type);
            if (def) addAtCentre(def);
            return;
        }
        const a = ev.target.closest('[data-act]');
        if (a && !a.disabled) onAct(a.dataset.act, a);
    });
    colEl.addEventListener('input', (ev) => {
        const el = ev.target;
        if (el.classList.contains('dr-pal-search')) {
            ed.paletteQuery = el.value;
            const body = colEl.querySelector('.dr-body');
            body.innerHTML = renderTab(ed);
            const box = body.querySelector('.dr-pal-search');
            box.focus();
            box.setSelectionRange(box.value.length, box.value.length);
            return;
        }
        if (el.classList.contains('sy-log-search')) {
            ed.logQuery = el.value;
            const body = colEl.querySelector('.dr-body');
            body.innerHTML = renderTab(ed);
            const box = body.querySelector('.sy-log-search');
            if (box) { box.focus(); box.setSelectionRange(box.value.length, box.value.length); }
            return;
        }
        if (el.dataset && el.dataset.t && el.dataset.f !== 'select') {
            if (writeField(ed, el)) touched();
        }
    });
    colEl.addEventListener('change', (ev) => {
        const el = ev.target;
        if (el.classList.contains('sy-log-level')) { ed.logLevel = el.value; drawColumn(); return; }
        if (el.dataset && el.dataset.actChange === 'rename-var') { renameVar(el); return; }
        if (el.dataset && el.dataset.t) {
            writeField(ed, el);
            if (el.dataset.t.startsWith('var:') && el.dataset.k === 'type') {
                const v = ed.doc.vars.find((x) => 'var:' + x.id === el.dataset.t);
                if (v) coerceVar(v);
            }
            // A pick redraws (it can change the card's pins); typing is committed without a redraw, so the
            // click that left the field keeps its focus.
            if (el.dataset.f === 'select') {
                ed.changed();
            } else {
                ed.history.commit(ed.doc);
                canvas.render();
                drawHead();
                // A Formula's line read: its pins and its words (the server's Check confirms them).
                if (el.dataset.k === 'expr') check(true);
            }
        }
    });
    colEl.addEventListener('mousedown', (ev) => {
        const row = ev.target.closest('.dr-pal-row');
        if (!row || ev.button !== 0) return;
        palDrag = { type: row.dataset.type, x: ev.clientX, y: ev.clientY, moved: false, ghost: null };
        window.addEventListener('mousemove', palMove);
        window.addEventListener('mouseup', palUp);
    });
}

let palDrag = { moved: false };

function palMove(ev) {
    if (!palDrag.type) return;
    if (!palDrag.moved && Math.hypot(ev.clientX - palDrag.x, ev.clientY - palDrag.y) < 4) return;
    if (!palDrag.ghost) {
        const def = ed.cards.get(palDrag.type);
        palDrag.ghost = document.createElement('div');
        palDrag.ghost.className = 'dr-drag-ghost';
        palDrag.ghost.textContent = def ? def.title : palDrag.type;
        root.appendChild(palDrag.ghost);
    }
    palDrag.moved = true;
    palDrag.ghost.style.left = ev.clientX + 12 + 'px';
    palDrag.ghost.style.top = ev.clientY + 8 + 'px';
}

function palUp(ev) {
    window.removeEventListener('mousemove', palMove);
    window.removeEventListener('mouseup', palUp);
    const d = palDrag;
    if (d.ghost) d.ghost.remove();
    setTimeout(() => { palDrag = { moved: false }; }, 0);
    if (!d.moved) return;
    const under = document.elementFromPoint(ev.clientX, ev.clientY);
    if (!under || (under.closest && under.closest('.dr-col'))) return;
    const def = ed.cards.get(d.type);
    if (def) addCard(def, canvas.toWorld(ev.clientX, ev.clientY), null);
}

// ============================================================
// Keys
// ============================================================

function onKey(ev) {
    if (modal) {
        if (ev.key === 'Escape') { ev.preventDefault(); closeAsk(null); }
        return;
    }
    if (isSearchOpen()) {
        if (ev.key === 'Escape') { ev.preventDefault(); closeSearch(); }
        return;
    }
    const ctrl = ev.ctrlKey || ev.metaKey;
    const t = ev.target;
    const typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT');
    if (ed.page === 'editor' && ctrl && ev.key.toLowerCase() === 's') { ev.preventDefault(); save(); return; }
    if (typing) {
        if (ev.key === 'Escape') { ev.preventDefault(); t.blur(); }
        return;
    }
    // A list open (a boxed select's): its keys, none of the editor's (Backspace would delete the card); Esc closes it.
    if (isDropdownOpen()) {
        if (ev.key === 'Escape') { ev.preventDefault(); closeDropdown(); }
        return;
    }
    if (ev.key === 'Escape') {
        ev.preventDefault();
        if (ed.page === 'editor' && (ed.selected.size || ed.selectedLink || ed.selectedNote)) { ed.select([]); return; }
        if (ed.page === 'editor') { leaveEditor(); return; }
        closeScreen();
        return;
    }
    if (ed.page !== 'editor') return;
    const k = ev.key.toLowerCase();
    if (ev.key === 'Delete' || ev.key === 'Backspace') { ev.preventDefault(); deleteSelected(); }
    else if (ctrl && k === 'z' && !ev.shiftKey) { ev.preventDefault(); undo(); }
    else if (ctrl && (k === 'y' || (k === 'z' && ev.shiftKey))) { ev.preventDefault(); redo(); }
    else if (ctrl && k === 'd') { ev.preventDefault(); duplicateSelected(); }
    else if (ctrl && k === 'c') { ev.preventDefault(); copySelected(); }
    else if (ctrl && k === 'x') { ev.preventDefault(); if (copySelected()) deleteSelected(); }
    else if (ctrl && k === 'v') { ev.preventDefault(); pasteClip(); }
    else if (!ctrl && k === 'c') { ev.preventDefault(); commentSelected(); }
    else if (ctrl && k === 'a') { ev.preventDefault(); ed.select(ed.doc.nodes.map((n) => n.id)); }
    else if (k === 'f' || ev.key === 'Home') { ev.preventDefault(); canvas.frame(ed.selected.size ? [...ed.selected] : null); }
}

// ============================================================
// The screen
// ============================================================

function build() {
    root = document.getElementById('systems');
    root.className = 'dr-root sy-root';
    root.innerHTML = '<div class="dr-field-host"></div>'
        + '<div class="dr-col sy-col"><div class="dr-head"></div><div class="dr-bar"></div>'
        + `<div class="dr-tabs">${TABS.map((t) => `<button class="dr-tab" data-tab="${t.id}">${e(t.label)}</button>`).join('')}</div>`
        + '<div class="dr-body"></div><div class="dr-foot"></div></div>';
    colEl = root.querySelector('.dr-col');
    canvas = new Canvas(root.querySelector('.dr-field-host'), ed);
    bindColumn();
    // Its lists are whip's own, as the Director's are (dropdown.js), whether or not the Director was opened first.
    watchSelects(root);
    root.addEventListener('contextmenu', (ev) => ev.preventDefault());
    // A pin's last value (a test), on hover.
    const host = root.querySelector('.dr-field-host');
    host.addEventListener('mouseover', (ev) => {
        const pin = ev.target.closest && ev.target.closest('.dr-pin');
        if (pin) showTip(pin, ev); else hideTip();
    });
    host.addEventListener('mouseleave', hideTip);
    NuiRouter.registerKeyScope({ name: 'systems', priority: 15, isOpen: () => shown && !away, onKey });
}

function closeScreen() {
    commitField();
    closeSearch();
    closeAsk(null);
    hide();
    nuiCallback('systemsClose');
}

function hide() {
    shown = false;
    away = false;
    stopPolling();
    hideTip();
    document.body.classList.remove('sy-open');
    if (root) root.classList.remove('open', 'away');
}

/** /systems: the screen, on the page it was left on. */
export async function open(d) {
    if (!root) build();
    shown = true;
    away = false;
    root.classList.add('open');
    root.classList.remove('away');
    // The search and menus sit on the page's body, outside this screen: red there too (systems.css).
    document.body.classList.add('sy-open');
    drawAll();
    if (ed.page === 'editor') {
        if (!ed.cards.size) await loadCards();
        call('watch', { key: ed.key, rev: ed.baseRev || 0 }).then((r) => {
            if (r.ok && r.data.editors) { ed.editors = listOf(r.data.editors); drawHead(); }
        });
        // Always asked: back from playing a test (F9), what it has done so far; or a test that ended
        // while the screen was closed is over here too (S2 review: "testing" was still shown).
        pollTest(!!(d && d.testing));
    } else {
        await loadCards();
        refreshHub();
    }
    if (ed.page === 'editor' && !ed.doc.nodes.length) canvas.frame();
}

/** Everything else client/systems_editor.lua says (through systems-loader.js). */
export function message(d) {
    if (!root) return;
    switch (d.action) {
        case 'systemsClose':
            closeSearch();
            closeAsk(null);
            hide();
            break;
        case 'systemsHide':
            away = true;
            root.classList.add('away');
            break;
        case 'systemsShow':
            away = false;
            root.classList.remove('away');
            break;
        case 'systemsPlaced': {
            if (!ed.doc || typeof d.node !== 'string' || typeof d.key !== 'string') break;
            if (writePlace(d.node, d.key, d.coords)) {
                ed.changed();
                status('Placed', 'ok');
                check(true);
            }
            break;
        }
        case 'systemsTestSteps':
            // Only on the system being tested: another one's cards share ids (every1, the examples').
            if (ed.page === 'editor' && ed.doc && d.key === ed.key) pulseSteps(d.steps);
            break;
        case 'systemsTestEnded':
            stopPolling();
            if (ed.test) { ed.lastReport = Object.assign({}, ed.test, { reason: d.reason }); ed.test = null; }
            status('The test ended: ' + (d.reason || '?'), 'error');
            if (ed.page === 'editor') drawColumn();
            break;
        case 'systemsTestRestarted':
            status('The test started again', 'ok');
            ed.testValues = null;
            ed.lastTest = { nodes: new Set(), links: new Set(), fault: null };
            canvas.render();
            break;
        case 'systemsPulse':
            if (ed.page === 'editor' && ed.doc && d.key === ed.key && !(ed.test && ed.test.status === 'running')) pulseSteps(d.steps);
            break;
        default:
            break;
    }
}
