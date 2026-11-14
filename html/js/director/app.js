// Director screen: the editor, the world builder's Director parts and their talk with the server. Loaded on first
// use by director-loader.js (a dynamic import, so a fault here fails the Director alone). client/director.lua owns
// the focus; this owns what is drawn.
// The Director opens in the world (/whip Director tab: Edit): the scenario opens with this page out of sight and the
// world builder on it, its Configure panel and Blueprint window drawn from here (`builder`). The window's Fullscreen
// is the editor: the column of tabs (panels.js) over the blueprint canvas (canvas.js). Scenarios are listed and
// managed in /whip (html/js/wp/director.js), not here.
// What is open survives closing the screen, with any unsaved changes.
// Every request goes through client/director.lua: directorCall (named ops), directorSave and directorCheck (the
// document goes up as a latent event), directorBuild (the world builder).

import { NuiRouter } from '../router.js';
import { nuiCallback, escapeHtml, itemImageUrl, fitPicture } from '../utils.js';
import { getItemDefs } from '../core/item-defs.js';
import { normalise, History, makeNode, duplicateNodes, removeNodes, findNode, findWorld, freeId, worldIds,
    slug, isId, renameWorld, renameVar, usesOfWorld, usesOfWorlds, usesOfVar, addLink, problemCards,
    copyNodes, pasteNodes, makeComment, removeComment, findComment, insertReroute,
    unpackDoc, packDoc, eachVariant, newVariant, removeVariant, renameVariant, moveVariant, variantList, variantLabel,
    sharedIds, MAX_VARIANTS, listOf } from './doc.js';
import { plural, clock } from '../wp/format.js';
import { Canvas, GEO, REROUTE, couldNot, opensMenu } from './canvas.js';
import { openSearch, openMenu, closeSearch, isSearchOpen, CATEGORY_TITLE } from './search.js';
import { thingIs } from './things-data.js';
import { groupName, expandThings } from './refs.js';
import { TABS, isTab, ICON, renderTab, writeField, writeSeg, writeValue, refreshMenuUnder, growRows,
         tasksOf, pointNumbers, taskPoints, sliderPct, sliderText, renderCards, takesOf, rollLoot, worldsOf,
         dhmsChoices, carModels, MAX_CAR_MODELS, problemsFor, outfitRandom, defaultLore, FREEMODE, lookOf, repeatShown,
         MANY, multiThings, sharedOf } from './panels.js';
import { initTutorial, tutorialOpened, tutorialKey, tutorialMenu, tutorialRunning } from './tutorial.js';
import { initPad, padAnalog, padNav, padHints, padHide } from './pad.js';
import { trySkillCheck, tryProgress } from './try.js';
import { mountMap } from './map.js';
import { watchSelects, openChoices, isDropdownOpen, closeDropdown } from './dropdown.js';
import { emoteMenuUp } from '../emotes.js';
import { primeLorePortraits } from '../lore-faces.js';
import { testWindowMessage } from './testwin.js';

const e = escapeHtml;

const ed = {
    cards: new Map(),
    cardsRev: -1,          // the card list's revision on the server (another resource's cards come and go)
    jobs: [],              // whip's jobs, for a card's `job` field: { key, name }
    lore: [],              // the lore characters in use, for a `lore` field and an NPC's Lore character
    providers: null,       // the open scenario's other-resource cards: { [type]: the resource it came from }
    page: 'none',          // 'none' (nothing open yet) | 'editor'
    hub: null,             // the last list answer (the keys taken, Isolate world)
    doc: null, key: null, baseRev: 0, scenario: null, on: false, onRev: null, editors: [], pack: null,
    history: null,
    selected: new Set(), selectedLink: null, selectedNote: null,
    problems: new Map(), problemList: [], checkedAt: 0,
    // `tab` is a tab (panels.js TABS) or a page over one ('card', 'check'); `homeTab` the tab under a page.
    tab: 'cards', homeTab: 'cards', paletteQuery: '', worldOpen: null, revisions: null,
    palScroll: 0,          // where the card list was scrolled to, kept while the page redraws
    colHidden: false,      // the column away (its X, in the full editor): the grid the whole screen (drawColHidden)
    colHiddenTab: null,    // the tab under it as it went: the page showing another one brings it back
    repeatOpen: {},        // a card's numbered sets shown past the ones written (its Add): '<card id>:<set>' -> the last
    picker: null,          // the item picker, over the page it was opened from: { t, k, label, from, required, query, kind, scroll }
    weapons: [],           // GTA's weapons this game has: { name, label, group } (directorOpen)
    tasks: null,           // what a placed thing's Tasks can hold (readTasks): { groups, types, order, max }
    taskOpen: null,        // the task row open on a thing's page: '<worldId>~<step key>'
    taskPick: null,        // the thing whose + Task picker is up, over its page
    taskCopy: null,        // Copy existing, over a thing's page: { id, from } (from: the thing whose tasks are shown, or null)
    voicePick: null,       // a GTA Speech step's voice picker, over its thing's page: { id, k, query, group }
    cardPickFor: null,     // a Wait step picking its card: { id, k } (the next card clicked on the grid: ed.select)
    speech: null,          // the game's voices and their lines, once read (loadSpeech)
    pedOpts: {},           // what each ped model can wear, once read (askPedOpts): { [model]: { c, p } | { failed } }
    takeOpen: null,        // the take row open on a car's page: '<worldId>#<take id>'
    recordAfter: null,     // a car to record a take in once the world builder's Done has written the world
    // Other resources' buttons on placed things (client/director_buttons.lua): { id, owner, label, icon, hint, kinds,
    // where, takesOver }; and one that takes over, pressed in the world builder, to press once its Done has written
    // the world: { id, button }.
    buttons: [],
    pressAfter: null,
    // Variants (doc.js): every variant's problems (problemList is the open one's and the shared), the variant to open
    // once the world builder's Done has written the world, the one whose name is being typed, and each one's last view
    // of the grid.
    problemsAll: [],
    variantAfter: null,
    variantRename: null,
    views: null,
    lastTest: null,        // readTrace(): what the last test ran, drawn on the canvas and in Check
    busy: false,
    isolated: false,       // in a world of your own (Isolate world: server/director/hub.lua)
    demo: null,            // an example open only to look at (the tutorial: openDemo), by name
    testedAt: 0,           // when the last test started (the tutorial waits for one)
};

let root, colEl, sideEl, canvas, statusTimer = null;
let drawnView = '';   // the tab or page the column last drew (drawColumn keeps its scroll while it stays)
let sideView = '';    // the same for the card's page on the right (drawSide)
let shown = false, away = false;
let framePending = false;   // the scenario was opened out of sight: its grid is framed once the page shows
let modal = null;   // { resolve }
// What Copy took (doc.js copyNodes): kept while the page lives, so cards go from one scenario into
// another.
let clip = null;
let replayToken = 0;   // a test's playback under way (a newer one, or leaving, stops it)

// ============================================================
// Talking to the server
// ============================================================

async function call(op, args) {
    const r = await nuiCallback('directorCall', { op, args: args || {} });
    if (r && r.ok) return { ok: true, data: r.data || {} };
    return { ok: false, why: (r && r.why) || 'No answer from the server' };
}

async function send(name, payload) {
    const r = await nuiCallback(name, payload);
    if (r && r.ok) return { ok: true, data: r.data || {} };
    return { ok: false, why: (r && r.why) || 'No answer from the server' };
}

/** Another resource's card wears its own colour, a token name (DESIGN.md: never a hex), slate if none. */
const TINTS = new Set(['blue', 'teal', 'green', 'amber', 'red', 'violet', 'slate']);

/** The card list. `force`: asked for again (another resource added or took away cards). */
async function loadCards(force) {
    if (ed.cards.size && !force) return true;
    quietChecked = null;   // (other cards now: the same scenario may check differently)
    const r = await call('cards');
    if (!r.ok) { status(r.why, 'error'); return false; }
    const list = listOf(r.data.cards);
    ed.cards.clear();
    for (const def of list) {
        def.inputs = Array.isArray(def.inputs) ? def.inputs : [];
        def.outputs = Array.isArray(def.outputs) ? def.outputs : [];
        def.props = Array.isArray(def.props) ? def.props : [];
        def.bad = listOf(def.bad);
        for (const f of def.props) if (f.options) f.options = listOf(f.options);
        // Another resource's card: the colour it asked for; else, in one of whip_core's groups (Whiplash's Customise
        // Vehicle in Goals), that group's own, as its neighbours; else slate.
        if (def.owner && def.owner !== 'whip_core') {
            if (TINTS.has(def.color)) def.tint = 'c-' + def.color;
            else if (!CATEGORY_TITLE[def.category]) def.tint = 'c-slate';
        }
        ed.cards.set(def.type, def);
    }
    ed.cardsRev = typeof r.data.rev === 'number' ? r.data.rev : -1;
    ed.jobs = listOf(r.data.jobs);
    ed.lore = listOf(r.data.lore);
    primeLorePortraits(ed.lore);   // their headshots, where they have no picture link (lore-faces.js)
    ed.tasks = readTasks(r.data.tasks);
    loadSpeech();
    loadButtons();
    return true;
}

/** Other resources' buttons on placed things: this game keeps them (client/director_buttons.lua), not the server. */
async function loadButtons() {
    const r = await nuiCallback('directorButtons', {});
    ed.buttons = readButtons(r && r.buttons);
    if (ed.page === 'editor' && ed.worldOpen) redrawWhenFree();
}

function readButtons(list) {
    return listOf(list).filter((b) => b && typeof b.id === 'string').map((b) => ({ ...b, kinds: listOf(b.kinds) }));
}

/** The buttons for a kind of thing in one place ('page' | 'bubble'). */
function buttonsFor(kind, where) {
    return ed.buttons.filter((b) => b.kinds.includes(kind) && (b.where === 'both' || b.where === where));
}

/** A button pressed on thing `w`. One that takes over, pressed in the world builder: the builder's Done first (the
 *  camera kept, its Save still to press), then the press once the world is written (directorShow), the builder open
 *  again on the thing when it is over (client/director_buttons.lua). */
function pressButton(w, b, model) {
    commitField();
    if (b.takesOver && building) {
        ed.pressAfter = { id: w.id, button: b.id, model };
        nuiCallback('directorBuilderDone', { aside: true });
        return;
    }
    sendPress(w, b, building, model);
}

// ---- A CARD'S LIST (another resource's entries field: panels.js entriesField) ----
//
// Its button (that resource's Director button for kind 'card') adds an entry or changes one; what it saves is the
// entry (cardEntryData). The card's placed things go with the press, so the resource knows what it names.

/** A press that adds: the entry its first save made, so its later saves change that one. [press token] = index. */
const pressAdds = new Map();

/** The card as a button's thing: its list and entry (`i`, or none: a new one), its fields, its placed things. */
function cardThing(node, def, f, i) {
    const world = {};
    for (const p of def.props || []) {
        const w = p.kind === 'world' && typeof node.props[p.key] === 'string' ? findWorld(ed.doc, node.props[p.key]) : null;
        if (!w) continue;
        world[p.key] = { id: w.id, kind: w.kind, label: w.label || w.id, model: w.def.model, coords: w.def.coords,
                         models: w.kind === 'vehicle' && w.def.random ? carModels(w).map((m) => m.model) : undefined };
    }
    const props = {};
    for (const p of def.props || []) if (node.props[p.key] !== undefined) props[p.key] = node.props[p.key];
    const list = Array.isArray(node.props[f.key]) ? node.props[f.key] : [];
    const first = Object.values(world)[0];
    return { id: node.id, kind: 'card', label: def.title, scenario: ed.key, back: first ? first.id : undefined,
             card: { type: node.type, field: f.key, entry: Number.isInteger(i) ? i + 1 : undefined,
                     value: Number.isInteger(i) ? list[i] : undefined, props, world } };
}

/** A card list's button pressed (Change on an entry: `i`; its add: none). One that takes over, in the world builder:
 *  the builder's Done first, as a thing's button (pressButton). */
function pressCardButton(node, f, b, i) {
    const def = ed.cards.get(node.type);
    if (!def) return;
    commitField();
    if (b.takesOver && building) {
        ed.pressAfter = { card: node.id, field: f.key, i, button: b.id };
        nuiCallback('directorBuilderDone', { aside: true });
        return;
    }
    nuiCallback('directorButtonPress', { button: b.id, builder: building, thing: cardThing(node, def, f, i) })
        .then((r) => { if (r && r.ok === false) status(r.why || `${b.label} did not work`, 'error'); });
}

/** What a card list's button saved: that entry (nil: taken out), a new one added once and then changed. */
function cardEntryData(d) {
    const n = ed.doc && typeof d.id === 'string' ? findNode(ed.doc, d.id) : null;
    const def = n && ed.cards.get(n.type);
    const f = def && (def.props || []).find((p) => p.key === d.card.field && p.kind === 'entries');
    if (!f) return;
    const list = Array.isArray(n.props[f.key]) ? n.props[f.key].slice() : [];
    const at = Number.isInteger(d.card.entry) ? d.card.entry - 1 : pressAdds.get(d.press);
    const has = Number.isInteger(at) && at >= 0 && at < list.length;
    if (d.data === undefined || d.data === null) {
        if (has) list.splice(at, 1);
        if (!Number.isInteger(d.card.entry)) pressAdds.delete(d.press);
    } else if (has) {
        list[at] = d.data;
    } else {
        if (list.length >= (f.max || 8)) { status(`${f.label}: ${f.max || 8} at most`, 'warn'); return; }
        list.push(d.data);
        if (d.press) pressAdds.set(d.press, list.length - 1);
    }
    if (list.length) n.props[f.key] = list;
    else delete n.props[f.key];
    ed.changed();
}

/** The world builder's bubble button that opens the character editor on a freemode NPC (another resource's buttons are
 *  '<namespace>.<name>': never this). */
const LOOK_BUTTON = 'whip_core:look';

/** A freemode NPC's look in the character editor (client/director.lua directorEditLook): the Director steps aside, and
 *  what its Save made comes back as directorLookMade. In the world builder: its Done first (the camera kept), then the
 *  editor once the world is written (directorShow: lookAfter), the builder open on the NPC again when it is over. */
async function editLook(w, fromBuilder) {
    commitField();
    if (building) {
        ed.lookAfter = w.id;
        nuiCallback('directorBuilderDone', { aside: true });
        return;
    }
    const r = await nuiCallback('directorEditLook', { id: w.id, label: w.label || w.id, model: w.def.model,
                                                      look: lookOf(w) || undefined, builder: fromBuilder === true });
    if (r && r.ok) return;
    status((r && r.why) || 'The character editor could not open', 'error');
    if (fromBuilder) openBuilder(w.id, true);
    else showPage();
}

/** `model`: a random vehicle's, pressed for that one of its models (its page's Models list); else its first. */
function sendPress(w, b, inBuilder, model) {
    const ext = w.def.ext && typeof w.def.ext === 'object' ? w.def.ext : {};
    const random = w.kind === 'vehicle' && w.def.random ? carModels(w).map((m) => m.model) : null;
    nuiCallback('directorButtonPress', {
        button: b.id, builder: inBuilder === true, data: ext[b.owner],
        thing: { id: w.id, kind: w.kind, label: w.label || w.id, model: random && random.includes(model) ? model : w.def.model,
                 models: random || undefined, coords: w.def.coords, scenario: ed.key },
    }).then((r) => { if (r && r.ok === false) status(r.why || `${b.label} did not work`, 'error'); });
}

/** What a button's resource saved on a thing (client/director_buttons.lua): an edit like any other. */
function thingData(d) {
    if (d.card && typeof d.card === 'object') return cardEntryData(d);
    const w = ed.doc && typeof d.id === 'string' ? findWorld(ed.doc, d.id) : null;
    if (!w || typeof d.owner !== 'string') return;
    const ext = { ...(w.def.ext && typeof w.def.ext === 'object' ? w.def.ext : {}) };
    if (d.data === undefined || d.data === null) delete ext[d.owner];
    else ext[d.owner] = d.data;
    if (Object.keys(ext).length) w.def.ext = ext;
    else delete w.def.ext;
    ed.changed();
}

/** The game's voices and their lines, for GTA Speech (html/js/director/speech-voices.js, generated by
 *  dev/speech_list.js): read once, in the background; until then its Line is a plain field. */
let speechLoading = null;
function loadSpeech() {
    if (ed.speech || speechLoading) return;
    speechLoading = import('./speech-voices.js').then((m) => {
        ed.speech = m.readSpeech();
        // (A speech step or the voice picker already open: drawn again with the list.)
        if (ed.voicePick || (ed.taskOpen && ed.page === 'editor')) redrawWhenFree();
    }).catch((err) => {
        console.error('[whip_core:director] the speech voices could not be read: ' + (err && err.message ? err.message : err));
    }).finally(() => { speechLoading = null; });
}

/** What a ped model can wear, for an NPC's Outfit (panels.js outfitGroup): asked of the game once a model
 *  (client/ped_outfit.lua PedOutfit.options), the page drawn again with it. Parts: { i, n, t: [colours of each style] }. */
const pedOptsAsking = new Set();
function askPedOpts(model) {
    if (!model || ed.pedOpts[model] || pedOptsAsking.has(model)) return;
    pedOptsAsking.add(model);
    const part = (x) => ({ i: Number(x.i), n: Number(x.n), t: listOf(x.t).map(Number) });
    nuiCallback('directorPedOptions', { model }).then((r) => {
        ed.pedOpts[model] = r && r.ok === true
            ? { c: listOf(r.c).map(part), p: listOf(r.p).map(part) }
            : { failed: (r && r.why) || 'the game did not answer' };
    }).finally(() => {
        pedOptsAsking.delete(model);
        if (ed.page === 'editor') redrawWhenFree();
    });
}
ed.askPedOpts = askPedOpts;

/** The task catalogue (server/director/tasks.lua DirectorTasks.wire): { groups, types: Map, order, max }, or
 *  null from a server without it. Lists from Lua may come as objects: made lists here. */
function readTasks(t) {
    if (!t || typeof t !== 'object') return null;
    const list = listOf;
    const types = new Map(), order = [];
    for (const d of list(t.types)) {
        if (!d || typeof d.t !== 'string') continue;
        d.kinds = list(d.kinds);
        d.fields = list(d.fields);
        for (const f of d.fields) if (f.options) f.options = list(f.options);
        types.set(d.t, d);
        order.push(d.t);
    }
    return { groups: list(t.groups), types, order, max: Number(t.max) || 40 };
}

// ============================================================
// Small pieces: the status line, the confirm box
// ============================================================

function status(text, tone) {
    const el = colEl && colEl.querySelector('.dr-foot');
    if (!el) return;
    // (The column away: said low on the left, over the grid, too.)
    const away = root && root.querySelector('.dr-colback-status');
    const say = (t, cls) => {
        el.textContent = t;
        el.className = 'dr-foot' + cls;
        if (away) { away.textContent = t; away.className = 'dr-colback-status' + cls; }
    };
    say(text || '', tone ? ' ' + tone : '');
    clearTimeout(statusTimer);
    if (text && tone !== 'error') statusTimer = setTimeout(() => say('', ''), 6000);
}

/** A question in the middle of the screen. Answers the pressed button's value, or null (Esc). `buttons` are given
 *  the main answer first; they are drawn in the house order, as /whip's dialogs are: on one row at the right, the
 *  quiet one on the left and the main one on the right. */
function ask(title, text, buttons) {
    closeAsk(null);
    const back = document.createElement('div');
    // (In the world builder the Director's page is away: the question is asked over the builder.)
    back.className = 'dr-modal-back' + (building ? ' dr-float dr-modal-over' : '');
    back.innerHTML = `<div class="dr-modal"><div class="dr-modal-title">${e(title)}</div>`
        + `<div class="dr-modal-text">${e(text)}</div><div class="dr-btns">`
        + buttons.map((b, i) => `<button class="dr-btn ${b.tone || 'ghost'}" data-i="${i}">${e(b.label)}</button>`).reverse().join('')
        + '</div></div>';
    (building ? document.body : root).appendChild(back);
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

// ============================================================
// The editor's state
// ============================================================

// ---- variants (Multi Run Variants): ed.doc is the open variant's view (doc.js unpackDoc) ----

/** The tasks' catalogue: it says which of a step's fields name a thing (doc.js sharedIds). */
const taskTypes = () => (ed.tasks ? ed.tasks.types : null);
/** The document as the server keeps it: every variant, Variant 1 at its top (doc.js packDoc). What leaves the editor. */
const packed = (doc) => packDoc(doc || ed.doc, taskTypes());
/** The variant open: 'v1' (the document itself) or another's id. */
const openVariant = () => (ed.doc && ed.doc.variantOpen) || 'v1';

/** The cards of every variant but the open one, to read or change in place: Variant 1's (when another is open) and the
 *  others'. What every variant shares (a variable, a shared thing) is named from them too. */
function otherVariantNodes() {
    const out = [];
    if (!ed.doc) return out;
    if (ed.doc._base) out.push(ed.doc._base.nodes);
    for (const v of ed.doc.variants || []) if (Array.isArray(v.nodes)) out.push(v.nodes);
    return out;
}

/** How many of the other variants' cards read a variable ('var') or name a placed thing ('world'). */
function otherUses(kind, id) {
    let n = 0;
    for (const nodes of otherVariantNodes()) n += (kind === 'var' ? usesOfVar : usesOfWorld)({ nodes }, ed.cards, id).length;
    return n;
}

/** The problems a check found. `quiet`: the check after an edit (quietCheck), which is not Check pressed, so
 *  checkedAt (when Check last ran: the tutorial waits on it) stays as it was. Every variant's are kept
 *  (ed.problemsAll: Check's count, its list); the cards badged are the open one's, and what all of them share. */
function setProblems(list, quiet) {
    ed.problemsAll = listOf(list);
    const open = openVariant();
    ed.problemList = ed.problemsAll.filter((p) => !p.variant || p.variant === open);
    ed.problems = new Map();
    for (const p of ed.problemList) {
        for (const id of problemCards(p)) {
            const cur = ed.problems.get(id) || { error: false, messages: [] };
            if (p.severity === 'error') cur.error = true;
            cur.messages.push(p.message);
            ed.problems.set(id, cur);
        }
    }
    if (!quiet) ed.checkedAt = Date.now();
}

// ---- the quiet check: Check's count kept current a moment after an edit stops ----
//
// One at a time, and never over a save, a test or a Check: the server keeps one uploaded document per
// player (hub.lua takeUpload), so those wait for it (settleQuiet) before sending theirs.

let quietTimer = null, quietRun = null;
const QUIET_MS = 500;

function scheduleQuiet() {
    clearTimeout(quietTimer);
    quietTimer = null;
    if (ed.page !== 'editor' || !ed.doc || ed.demo) return;
    quietTimer = setTimeout(quietCheck, QUIET_MS);
}

/** What Check reads of a packed document, as text: where the cards and comment boxes sit on the grid is left out (a
 *  card moved, or a box, changes no problem). */
function checkText(p) {
    const strip = (d) => (d && typeof d === 'object'
        ? { ...d, comments: undefined, nodes: Array.isArray(d.nodes) ? d.nodes.map((n) => ({ ...n, x: undefined, y: undefined })) : d.nodes }
        : d);
    return JSON.stringify({ ...strip(p), variants: Array.isArray(p.variants) ? p.variants.map(strip) : p.variants });
}
let quietChecked = null;   // { key, text }: what the last quiet check that was answered looked at

async function quietCheck() {
    quietTimer = null;
    if (ed.page !== 'editor' || !ed.doc || ed.demo || ed.busy || quietRun) return;
    const key = ed.key, doc = ed.doc;
    const sent = packed(doc);
    // (Nothing Check reads has changed since the last one: the whole scenario is not sent up again for it.)
    const text = checkText(sent);
    if (quietChecked && quietChecked.key === key && quietChecked.text === text) return;
    quietRun = send('directorCheck', { doc: sent });
    const r = await quietRun;
    quietRun = null;
    if (r.ok) quietChecked = { key, text };
    // Another scenario open since, or the document swapped (undo, a revision): this answer is not its.
    if (!r.ok || ed.page !== 'editor' || ed.key !== key || ed.doc !== doc) return;
    // (The same as before, as after most edits: nothing to draw again.)
    const was = problemSig();
    setProblems(r.data.problems, true);
    if (problemSig() === was) return;
    if (!canvas.drag) canvas.render();
    drawHead();
    showChecked();
}

const problemSig = () => JSON.stringify((ed.problemsAll || []).map((p) => [p.severity, p.message, p.node, p.world, p.variant]));

// A press under way (between its mousedown and mouseup) is not drawn under: a redraw that takes away the element
// pressed means no click in the game's browser. The page is drawn once it is let go.
// (A release never heard, off the page: a press is over after a few seconds anyway.)
let pressedAt = 0, showAfterPress = false;
const PRESS_MS = 3000;
const pressing = () => pressedAt > 0 && Date.now() - pressedAt < PRESS_MS;
window.addEventListener('mousedown', () => { pressedAt = Date.now(); }, true);
window.addEventListener('mouseup', () => {
    pressedAt = 0;
    if (showAfterPress) { showAfterPress = false; setTimeout(showChecked, 0); }   // (after the click it makes)
}, true);
window.addEventListener('blur', () => { pressedAt = 0; });

/** Is a field of the Director's pages being typed in, or a list open? A redraw then takes it away (focus lost mid-word,
 *  and the next Backspace deleted the card). */
function fieldInHand() {
    const a = document.activeElement;
    const inPage = !!a && [colEl, sideEl, pane && pane.el].some((el) => el && el.contains(a));
    const typing = inPage && (a.tagName === 'TEXTAREA' || (a.tagName === 'INPUT' && !/^(checkbox|radio|button)$/.test(a.type)) || a.isContentEditable);
    return typing || isDropdownOpen();
}

/** A redraw that comes from outside (an answer or a message arriving: other resources' buttons, the voices, a model's
 *  outfit, the cards, the builder's preview): now, or once the field in hand is left and no press is under way (looked
 *  at again every half second meanwhile). `all`: the grid too (drawAll), else the column. */
let freeRedraw = 0;   // waiting: 1 the column, 2 everything
function redrawWhenFree(all) {
    const waiting = freeRedraw > 0;
    freeRedraw = Math.max(freeRedraw, all ? 2 : 1);
    if (waiting) return;
    const go = () => {
        if (pressing() || fieldInHand()) { setTimeout(go, 500); return; }
        const what = freeRedraw;
        freeRedraw = 0;
        if (what === 2) { if (shown) drawAll(); }
        else if (ed.page === 'editor') drawColumn();
    };
    go();
}

/** What a check found, on every page open: the column, the card's page on the right, the world builder's panel (a
 *  card's own problems, a thing's pills, the Check list, the tabs' counts). They are drawn again as they are, unless a
 *  field there is being typed in or a list is open, which a redraw would take away: then only the problems boxes at
 *  the top of the pages change, in place, and the rest follows the next redraw. */
function showChecked() {
    if (ed.page !== 'editor' || !ed.doc) return;
    if (pressing()) {
        // (Drawn when it is let go, or once the press is too old to be one: never left undrawn.)
        if (!showAfterPress) setTimeout(() => { if (showAfterPress) { showAfterPress = false; showChecked(); } }, PRESS_MS);
        showAfterPress = true;
        return;
    }
    if (!fieldInHand()) { drawColumn(); return; }
    for (const host of [colEl, sideEl, pane && pane.body]) {
        if (!host) continue;
        host.querySelectorAll('[data-probs]').forEach((el) => { el.innerHTML = problemsFor(ed, el.dataset.probs); });
    }
}

/** A quiet check under way finishes first; one waiting to start does not start. */
async function settleQuiet() {
    clearTimeout(quietTimer);
    quietTimer = null;
    if (quietRun) await quietRun;
}

/** After a refusal: to the tab that fixes it. Things to place go to the World tab with the first one
 *  open; anything else to Check. Answers the first error's text, for the status line. */
function showProblems() {
    const errors = ed.problemList.filter((p) => p.severity === 'error');
    const worldOnes = errors.filter((p) => p.tab === 'world' && p.world);
    if (errors.length && worldOnes.length === errors.length) {
        ed.tab = 'world';
        ed.worldOpen = worldOnes[0].world;
    } else {
        ed.tab = 'check';
    }
    canvas.render();
    drawColumn();
    return errors.length ? errors[0].message + (errors.length > 1 ? ` (and ${errors.length - 1} more)` : '') : '';
}

/** A card picked opens its page over the tab showing (not over Check); nothing picked, the page goes and the
 *  tab under it is back (drawColumn). */
ed.select = function (ids) {
    // Picking a card for a step's Wait (task-card-pick): the card clicked is the step's, its outcomes picked afresh, and
    // the step's page stays.
    if (ed.cardPickFor && ids.length === 1 && findNode(ed.doc, ids[0])) {
        const f = ed.cardPickFor;
        ed.cardPickFor = null;
        const w = findWorld(ed.doc, f.id);
        const s = w && tasksOf(w).list.find((x) => x.k === f.k);
        canvas.render();
        status('');
        if (!s) return drawColumn();
        if (s.card !== ids[0]) s.outs = [];
        s.card = ids[0];
        ed.tab = 'world';
        ed.worldOpen = w.id;
        ed.taskOpen = w.id + '~' + s.k;
        return ed.changed();
    }
    const wasCard = ed.tab === 'card';
    ed.selected = new Set(ids);
    ed.selectedLink = null;
    ed.selectedNote = null;
    ed.picker = null;   // it was for a field of the page the selection showed
    canvas.render();
    // On the world builder's grid a card picked is its page, whatever the column had open; let go of, the
    // panel goes back to what it showed before the card (the card list, a thing's page), or it goes. Never
    // to an older page underneath, one the panel had already closed.
    if (building && grid) {
        if (ids.length && !wasCard) {
            paneBefore = !pane ? null : ed.tab === 'cards' ? 'cards' : ed.tab === 'world' && ed.worldOpen ? ed.worldOpen : null;
        }
        if (!ids.length && wasCard) {
            if (paneBefore === 'cards') {
                ed.tab = 'cards';
            } else {
                ed.tab = ed.homeTab = 'world';
                ed.worldOpen = paneBefore && findWorld(ed.doc, paneBefore) ? paneBefore : null;
            }
            paneBefore = null;
        }
    }
    if (ids.length && grid) ed.tab = 'card';
    // (From Check too, when the page goes on the right: the list stays in the column beside it.)
    if (ids.length === 1 && (ed.tab !== 'check' || sideMode())) ed.tab = 'card';
    if (ed.tab === 'card' || ed.tab === 'check' || (building && pane)) drawColumn();
    else drawHead();
    // The world builder's grid: what the cards name is lit, and its panel shows the card's page.
    if (building) {
        builderLit();
        if (grid && ids.length && grid.hooks && grid.hooks.picked) grid.hooks.picked();
    }
};

/** A card picked already, pressed again on the world builder's grid: its page in the panel when the panel is not
 *  showing it (closed with its X, on a thing's Configure, or the card added with the panel shut). The selection stays. */
ed.pressedPicked = function () {
    if (!building || !grid || !ed.selected.size || (pane && ed.tab === 'card')) return;
    ed.select([...ed.selected]);
};

ed.selectLink = function (id) {
    // Already the one picked: no redraw. A redraw takes away the wire under the pointer between its
    // press and its release, and then the game's browser sends no click, and so no double-click:
    // a Reroute could never be made.
    if (ed.selectedLink === id && !ed.selected.size && !ed.selectedNote) return;
    ed.selected = new Set();
    ed.selectedLink = id;
    ed.selectedNote = null;
    canvas.render();
    if (ed.tab === 'card') drawColumn();
};

/** A comment box picked (its title or corner): nothing else is. */
ed.selectNote = function (id) {
    if (ed.selectedNote === id && !ed.selected.size && !ed.selectedLink) return;
    ed.selected = new Set();
    ed.selectedLink = null;
    ed.selectedNote = id;
    canvas.render();
    if (ed.tab === 'card') drawColumn();
};

/** The document changed on the canvas or in a tab: undo, redraw. */
ed.changed = function () {
    syncShared();
    ed.history.commit(ed.doc);
    for (const id of [...ed.selected]) if (!findNode(ed.doc, id)) ed.selected.delete(id);
    if (ed.selectedLink && !ed.doc.links.some((l) => l.id === ed.selectedLink)) ed.selectedLink = null;
    if (ed.selectedNote && !findComment(ed.doc, ed.selectedNote)) ed.selectedNote = null;
    canvas.render();
    if (ed.tab !== 'cards') drawColumn(); else drawHead();
    scheduleQuiet();
    builderSync();
    docTouched();
};

/** In the world builder, its Save says whether there is anything to save, the scenario's own changes (its
 *  Configure, its Blueprint) included: html/js/furnisher.js hears 'director-doc' and asks builder.docDirty. */
function docTouched() { if (building) window.dispatchEvent(new Event('director-doc')); }

/** A field is being typed in: the canvas follows at once, undo waits for the field to be left. One of a guard's
 *  Eye sight (`spec` 'vision:<id>'), a spot's Marker ('marker:<id>') or an NPC's Outfit ('outfit:<id>'), its cone,
 *  marker or copy in the world builder follows as it moves (builderSyncOne). */
function touched(spec) {
    // A card's own field: that card drawn again, not the grid (each key drew every card and measured each). Anything
    // else (a placed thing's name is on the cards that name it): the grid. Leaving the field draws it all (its change).
    if (typeof spec === 'string' && spec.startsWith('node:')) canvas.renderCard(spec.slice(5));
    else canvas.render();
    // (Not saved already, a key more is not saved either: the whole document is not written out again to say so.)
    drawHead(headDirty === true);
    scheduleQuiet();
    if (typeof spec === 'string' && (spec.startsWith('vision:') || spec.startsWith('marker:') || spec.startsWith('outfit:'))) {
        builderSyncOne(spec.slice(spec.indexOf(':') + 1));
    }
    else builderSync();
    docTouched();
}

ed.ui = {
    status,
    // (In the world builder's window the grid has no column over it.)
    leftEdge: () => (grid ? 0 : colEl ? colEl.getBoundingClientRect().right : 0),
    // (A card's page on the right covers that side.)
    rightEdge: () => (!grid && sideEl && !sideEl.hidden ? sideEl.getBoundingClientRect().left : Infinity),
    search: (o) => {
        const accept = o.from ? (def) => (o.from.side === 'out' ? def.inputs.length > 0 : def.outputs.length > 0) : null;
        openSearch({
            at: { x: o.x, y: o.y }, cards: ed.cards, accept,
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
            { label: 'Remove Comment Box', danger: true, run: () => { removeComment(ed.doc, id); ed.changed(); } },
        ] });
    },
    /** A Reroute dot on a wire, where it was double-clicked (canvas.js). */
    reroute: (linkId, at) => {
        const def = ed.cards.get(REROUTE);
        if (!def) { status('This server has no Reroute card', 'warn'); return; }
        const dot = insertReroute(ed.doc, linkId, def, { x: Math.round(at.x / GEO.SNAP) * GEO.SNAP, y: Math.round(at.y / GEO.SNAP) * GEO.SNAP });
        if (!dot) return;
        ed.selected = new Set([dot.id]);
        ed.selectedLink = null;
        ed.selectedNote = null;
        ed.changed();
    },
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

/** Copy the selected cards (and the wires between them). */
function copySelected() {
    const c = copyNodes(ed.doc, [...ed.selected]);
    if (!c) { status('Select the cards to copy first'); return false; }
    c.from = ed.key;
    clip = c;
    status(`${plural(c.nodes.length, 'card')} copied`, 'ok');
    return true;
}

/** The first of these cards (or nodes) kept to a permission this builder has not got, or null. */
function lockedAmong(nodes) {
    for (const n of nodes) {
        const def = n && ed.cards.get(n.type);
        if (def && def.locked) return def;
    }
    return null;
}

/** A locked card that names this placed thing (or variable): renaming it would change that card. */
function lockedUsing(id, isWorld) {
    for (const n of ed.doc.nodes) {
        const def = ed.cards.get(n.type);
        if (!def || !def.locked) continue;
        for (const f of def.props || []) {
            const v = n.props[f.key];
            if (isWorld ? (f.kind === 'world' && v === id) : ((f.kind === 'var' && v === id) || (v && typeof v === 'object' && v.var === id))) return def;
        }
    }
    return null;
}

/** Put what was copied where the pointer is (or the middle of the view), selected. Into another
 *  scenario, what named the first one's placed things and variables is cleared: their ids (npc1,
 *  spot1...) are every scenario's, and would quietly name this one's. */
function pasteClip() {
    if (!clip) { status('Nothing copied yet'); return; }
    // A locked card is not added this way either (the server refuses the save regardless).
    const kept = lockedAmong(clip.nodes || []);
    if (kept) { status(`${kept.title} needs the permission ${kept.permission || '?'}: it cannot be pasted by you`, 'warn'); return; }
    const made = pasteNodes(ed.doc, clip, canvas.pastePoint(), GEO.SNAP);
    let cleared = 0;
    if (clip.from !== ed.key) {
        for (const id of made) {
            const n = findNode(ed.doc, id);
            const def = n && ed.cards.get(n.type);
            for (const f of (def && def.props) || []) {
                const v = n.props[f.key];
                if (v === undefined) continue;
                if (f.kind === 'world' || f.kind === 'worlds' || f.kind === 'var' || (v && typeof v === 'object' && v.var !== undefined)) {
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
    status(`${plural(made.length, 'card')} pasted`
        + (cleared ? ` (from another scenario: ${plural(cleared, 'field')} naming its placed things or variables cleared)` : ''),
        cleared ? 'warn' : 'ok');
}

/** A comment box round the selected cards, or an empty one in the middle of the view; then its name. */
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

function addCard(def, at, from) {
    // A card another resource keeps to a permission this builder has not got (the server refuses the
    // save too: cards_api.lua, Director.gatedChange).
    if (def.locked) {
        status(`${def.title} needs the permission ${def.permission || '?'}: it cannot be added by you`, 'warn');
        return;
    }
    const node = makeNode(ed.doc, def, at.x - (from && from.side === 'in' ? 236 : 0), at.y - GEO.HEAD / 2);
    node.x = Math.round(node.x / GEO.SNAP) * GEO.SNAP;
    node.y = Math.round(node.y / GEO.SNAP) * GEO.SNAP;
    if (from) {
        if (from.side === 'out' && def.inputs.length) addLink(ed.doc, { node: from.node, pin: from.pin }, { node: node.id, pin: def.inputs[0] });
        else if (from.side === 'in' && def.outputs.length) addLink(ed.doc, { node: node.id, pin: def.outputs[0] }, { node: from.node, pin: from.pin });
    }
    ed.selected = new Set([node.id]);
    ed.selectedLink = null;
    if (ed.tab !== 'check' || sideMode()) ed.tab = 'card';
    ed.changed();
}

function addAtCentre(def) {
    const c = canvas.centre();
    // Not on top of the last card added there.
    let x = c.x - 118, y = c.y - 40;
    while (ed.doc.nodes.some((n) => Math.abs(n.x - x) < 24 && Math.abs(n.y - y) < 24)) { x += 32; y += 32; }
    addCard(def, { x: x, y: y + GEO.HEAD / 2 }, null);
}

function deleteSelected() {
    if (canvas.deleteSelected()) return;
    if (ed.selectedNote) {
        // The box goes; what is in it stays.
        removeComment(ed.doc, ed.selectedNote);
        ed.selectedNote = null;
        ed.changed();
        return;
    }
    if (!ed.selected.size) return;
    // The last Scenario Enabled stays: its page is where the scenario's settings are (how a run starts).
    const starts = ed.doc.nodes.filter((n) => n.type === 'scenario.started');
    if (starts.length && starts.every((n) => ed.selected.has(n.id))) {
        ed.selected.delete(starts[0].id);
        status('Scenario Enabled stays: its page says how the scenario starts', 'warn');
        if (!ed.selected.size) { drawColumn(); return; }
    }
    // A Reroute dot going joins its wires up again: what came into it goes everywhere it went.
    for (const id of ed.selected) {
        const n = findNode(ed.doc, id);
        if (!n || n.type !== REROUTE) continue;
        const outs = ed.doc.links.filter((l) => l.from.node === id && !ed.selected.has(l.to.node));
        const ins = ed.doc.links.filter((l) => l.to.node === id && !ed.selected.has(l.from.node));
        for (const out of outs) {
            for (const inn of ins) addLink(ed.doc, { node: inn.from.node, pin: inn.from.pin }, { node: out.to.node, pin: out.to.pin });
        }
    }
    removeNodes(ed.doc, [...ed.selected]);
    ed.selected = new Set();
    ed.changed();
}

function duplicateSelected() {
    if (!ed.selected.size) return;
    const kept = lockedAmong([...ed.selected].map((id) => findNode(ed.doc, id)));
    if (kept) { status(`${kept.title} needs the permission ${kept.permission || '?'}: it cannot be duplicated by you`, 'warn'); return; }
    const made = duplicateNodes(ed.doc, [...ed.selected], 48, 48);
    ed.selected = new Set(made);
    ed.changed();
}

function undo() {
    commitField();
    const d = ed.history.undo(ed.doc);
    if (!d) { status('Nothing to undo'); return; }
    viewOf(d, ed.history.lastVariant);
    ed.changedNoCommit();
}

function redo() {
    const d = ed.history.redo();
    if (!d) { status('Nothing to redo'); return; }
    viewOf(d, ed.history.lastVariant);
    ed.changedNoCommit();
}

/** A document back from undo: open on the variant the step was made in (or Variant 1, if that one is gone). */
function viewOf(canon, variant) {
    const was = openVariant();
    ed.doc = unpackDoc(canon, variant, taskTypes());
    if (openVariant() !== was) {
        resetPicks();
        status(`${variantLabel(ed.doc, openVariant())}: undone where it was made`);
        drawVariants();
    }
}

ed.changedNoCommit = function () {
    for (const id of [...ed.selected]) if (!findNode(ed.doc, id)) ed.selected.delete(id);
    ed.selectedLink = null;
    if (ed.selectedNote && !findComment(ed.doc, ed.selectedNote)) ed.selectedNote = null;
    canvas.render();
    drawColumn();
    scheduleQuiet();
};

/** What is picked or open in the editor, by id: another scenario's (or another variant's: ids repeat across them) 'note1',
 *  'd1' or 'guard' is not this one's. */
function resetPicks() {
    ed.selected = new Set();
    ed.selectedLink = null;
    ed.selectedNote = null;
    ed.worldOpen = null;
    ed.multi = null;       // several selected in the world builder: their ids (builder.configureMany)
    ed.lastTest = null;
    ed.repeatOpen = {};
    ed.lootSel = null;     // a container's slot picked, its roll, an icon field open
    ed.lootSim = null;
    ed.glyphOpen = null;
    ed.picker = null;
    ed.taskOpen = null;
    ed.takeOpen = null;
    ed.taskPick = null;
    ed.taskCopy = null;
    ed.voicePick = null;
    ed.cardPickFor = null;
}

/** A field being typed in is committed when it is left; Save and undo leave it first. */
function commitField() {
    const a = document.activeElement;
    if (a && (colEl.contains(a) || (sideEl && sideEl.contains(a))) && a.dataset && a.dataset.t) a.blur();
    if (canvas) canvas.commitRename();   // a comment's name being typed (Ctrl+S in it saves it too)
    if (ed.history) ed.history.commit(ed.doc);
}

// ============================================================
// Opening, saving, checking, switching on
// ============================================================

/** Open a scenario here. Answers null once it is open, or why it is not. */
async function openScenario(key, rev) {
    if (!(await loadCards())) return 'The card list did not come';
    status('Opening…');
    const r = await call('open', { key, rev: rev || 0 });
    if (!r.ok) { status(r.why, 'error'); return r.why; }
    const d = r.data;
    // The card list moved since this page asked for it (another resource's cards): asked for again.
    if (typeof d.cardsRev === 'number' && d.cardsRev !== ed.cardsRev && !(await loadCards(true))) return 'The card list did not come';
    // The lore characters as they are now (one may have changed in /whip since the card list came: loreAsNow).
    if (d.lore && typeof d.lore === 'object') {
        ed.lore = listOf(d.lore);
        primeLorePortraits(ed.lore);
    }
    ed.providers = d.providers && typeof d.providers === 'object' ? d.providers : null;
    ed.page = 'editor';
    ed.demo = null;
    ed.key = key;
    ed.scenario = d.scenario;
    // As it opens, every variant: its lore characters' peds as they are now, and its Scenario Enabled card. (A document
    // is read the one way on the server, server/director/doc.lua: no old shape reaches the editor.)
    ed.doc = eachVariant(normalise(d.doc), (doc) => {
        loreAsNow(doc);
        startCardAlways(doc);
    }, taskTypes());
    ed.baseRev = d.scenario.draftRev;
    ed.on = !!d.on;
    ed.onRev = d.onRev || null;
    ed.pack = typeof d.pack === 'string' ? d.pack : null;   // shipped by a pack: read-only here
    ed.editors = Array.isArray(d.editors) ? d.editors : [];
    ed.history = new History(ed.doc, (doc) => packed(doc));
    resetPicks();
    ed.views = null;
    ed.variantRename = null;
    ed.revisions = null;
    ed.tab = 'cards';
    ed.palScroll = 0;
    ed.colHidden = false;
    setProblems(d.problems);
    // Things still to place (a new scenario from an example): open on the World tab, saying which.
    const toPlace = ed.problemList.filter((p) => p.severity === 'error' && p.tab === 'world' && p.world);
    if (toPlace.length) {
        ed.tab = 'world';
        ed.worldOpen = toPlace[0].world;
    }
    if (ed.pack) {
        status(`Shipped by ${ed.pack}: read-only here. Duplicate it (in /whip) to make your own`, 'warn');
    } else if (rev && rev !== ed.baseRev) {
        // An older revision opened to restore: it is the working copy, saved on top of the draft.
        ed.history.markSaved({});
        status(`Revision ${rev} is open: Save makes it the draft again`, 'warn');
    } else if (toPlace.length) {
        const names = [...new Set(toPlace.map((p) => { const w = findWorld(ed.doc, p.world); return w ? (w.label || w.id) : p.world; }))];
        status(`Before testing, place ${names.join(' and ')}: open each from the World list and press Place in the world`, 'warn');
    } else {
        status(ed.editors.length ? `${ed.editors.join(', ')} has this open too: the first to save wins` : '',
            ed.editors.length ? 'warn' : '');
    }
    drawAll();
    canvas.frame();
    // Opened out of sight (straight into the world): the grid has no size to frame in yet, so it is framed again the
    // first time the page shows (showPage).
    framePending = away;
    return null;
}

/** Save the scenario. Answers whether it saved; `opts.quiet` (the world builder's Save, with the Director hidden):
 *  { ok, why, rev, nothing } instead, and never a question (someone saved first is only said). */
async function save(note, opts = {}) {
    const quiet = opts.quiet === true;
    const done = (ok, extra) => (quiet ? { ok, ...(extra || {}) } : ok);
    if (ed.busy) return done(false, { why: 'Busy: try again in a moment' });
    if (ed.pack) {
        status(`Shipped by ${ed.pack}: read-only here. Duplicate it to make your own`, 'warn');
        return done(false, { why: `Shipped by ${ed.pack}: read-only. Duplicate it in the Director to change it` });
    }
    commitField();
    if (!ed.history.isDirty(ed.doc)) { status('Nothing to save'); return done(true, { nothing: true }); }
    ed.busy = true;
    status('Saving…');
    await settleQuiet();
    // What is sent, as text now: edits made while the save is on its way are not part of it, and stay unsaved (an Undo
    // or another variant shown meanwhile too: told apart from the saved text). The reply is this scenario's: another
    // opened meanwhile keeps its own revision.
    const key = ed.key;
    const sent = packed();
    const sentText = JSON.stringify(sent);
    const r = await send('directorSave', { key, baseRev: ed.baseRev, doc: sent, note: note || '' });
    ed.busy = false;
    if (ed.key !== key) return done(r.ok, r.ok ? { rev: r.data.rev } : { why: r.why });
    if (r.ok) {
        ed.baseRev = r.data.rev;
        ed.history.markSavedText(sentText);
        setProblems(r.data.problems);
        const errs = ed.problemList.filter((p) => p.severity === 'error').length;
        status(`Saved as revision ${ed.baseRev}` + (errs ? ` (${plural(errs, 'problem')}: see Check)` : ''), errs ? 'warn' : 'ok');
        canvas.render();
        drawColumn();
        docTouched();
        return done(true, { rev: ed.baseRev });
    }
    if (quiet) {
        status(r.why, 'error');
        return done(false, { why: /changed by/i.test(r.why) ? 'Someone else saved it first: Exit, then save from the Director' : r.why });
    }
    if (/changed by/i.test(r.why)) {
        const pick = await ask('Someone saved first', r.why + '. Your changes are still here.', [
            { label: 'Save mine as a copy', value: 'copy', tone: 'primary' },
            { label: 'Open theirs (lose mine)', value: 'theirs', tone: 'danger' },
            { label: 'Cancel', value: null },
        ]);
        if (pick === 'theirs') { await openScenario(ed.key); return false; }
        if (pick === 'copy') return saveAsCopy();
        return false;
    }
    status(r.why, 'error');
    return false;
}

async function saveAsCopy() {
    const name = (ed.doc.name || ed.key) + ' (copy)';
    const used = new Set(((ed.hub && ed.hub.scenarios) || []).map((s) => s.key));
    used.add(ed.key);
    const key = freeId(used, slug(ed.key, 'scenario') + '_copy');
    const made = await call('create', { key, name, from: 'copy:' + ed.key });
    if (!made.ok) { status(made.why, 'error'); return false; }
    ed.key = key;
    ed.baseRev = made.data.scenario.draftRev;
    ed.scenario = made.data.scenario;
    ed.pack = null;   // a copy is this server's own, even of a shipped one
    ed.on = false;
    ed.onRev = null;
    ed.doc.name = name;
    ed.history.markSaved({});
    return save('saved as a copy');
}

/** Check the document. `quiet`: the badges and lists refresh where you are (after placing a thing),
 *  without going to the Check tab. */
async function check(quiet) {
    commitField();
    if (!quiet) status('Checking…');
    await settleQuiet();
    const r = await send('directorCheck', { doc: packed() });
    if (!r.ok) { if (!quiet) status(r.why, 'error'); return; }
    setProblems(r.data.problems);
    if (!quiet) {
        status(r.data.ok ? 'It passes its check' : 'It does not pass its check yet', r.data.ok ? 'ok' : 'warn');
        // (A card's page on the right stays open beside it.)
        if (sideOn()) ed.homeTab = 'check';
        else ed.tab = 'check';
    }
    canvas.render();
    drawColumn();
}

async function activate() {
    if (ed.history.isDirty(ed.doc)) { status('Save first: what is switched on is a saved revision', 'warn'); return; }
    status('Switching on…');
    let r = await call('activate', { key: ed.key, rev: ed.baseRev });
    // On already, with players in a run: switching revision ends their runs, so nothing changed yet
    // (server/director/hub.lua). Asked, then again with endRuns.
    if (r.ok && r.data && r.data.going) {
        const n = r.data.going;
        const pick = await ask(`Make revision ${ed.baseRev} live?`, `${ed.doc.name} has ${plural(n, 'run')} going now. `
            + `${n === 1 ? 'It ends for its players' : 'They end for their players'}, and new runs use revision ${ed.baseRev}`
            + `${ed.onRev ? ` instead of revision ${ed.onRev}` : ''}.`, [
            { label: `Make revision ${ed.baseRev} live`, value: true, tone: 'danger' }, { label: 'Cancel', value: null },
        ]);
        if (!pick) { status(''); return; }
        r = await call('activate', { key: ed.key, rev: ed.baseRev, endRuns: true });
    }
    if (!r.ok) { status(r.why, 'error'); return; }
    if (r.data.ok === false) {
        setProblems(r.data.problems);
        status('Not ready to switch on: ' + showProblems(), 'error');
        return;
    }
    ed.on = true;
    ed.onRev = ed.baseRev;
    setProblems(r.data.problems);
    status(`On at revision ${ed.baseRev}`, 'ok');
    drawColumn();
}

/** Test mode: the document as it is now, played by you alone (client/director.lua takes it from here). */
async function test() {
    if (ed.busy) return;
    commitField();
    status('Starting a test…');
    await settleQuiet();
    // (The variant open: the one the test plays.)
    const r = await send('directorTest', { key: ed.key, doc: packed(), variant: openVariant() });
    if (!r.ok) { status(r.why, 'error'); return; }
    if (r.data.ok === false) {
        setProblems(r.data.problems);
        status('Not ready to test: ' + showProblems(), 'error');
        return;
    }
    ed.lastTest = null;
    ed.testedAt = Date.now();
    status('');
}

/** What a test's trace says ran: the cards, the wires between them, and the steps in order. */
function readTrace(d) {
    const list = listOf(d.trace).filter((x) => x && x.node);
    const nodes = new Set(), links = new Set(), steps = [];
    const t0 = list.length ? list[0].t : 0;
    const stepOf = (node) => { for (let i = steps.length - 1; i >= 0; i--) if (steps[i].node === node) return steps[i]; return null; };
    for (const x of list) {
        nodes.add(x.node);
        const at = Math.max(0, ((x.t || 0) - t0) / 1000);
        if (x.kind === 'enter' || x.kind === 'skipped') {
            if (x.from) {
                const l = ed.doc.links.find((k) => k.from.node === x.from && k.from.pin === x.fromPin && k.to.node === x.node && k.to.pin === x.pin);
                if (l) links.add(l.id);
            }
            // (An Only Once card reached again: skipped, straight on. runtime.lua exec)
            steps.push(x.kind === 'skipped' ? { node: x.node, at, pins: [], note: 'only once: skipped' } : { node: x.node, at, pins: [] });
        } else if ((x.kind === 'out' || x.kind === 'resume') && x.pin) {
            // On the card's own step: its outputs, or the answer to the wait it started. An event
            // card has no step until it fires.
            const s = stepOf(x.node);
            if (s && (x.kind === 'out' || s.pins.length === 0)) s.pins.push(x.pin);
            else steps.push({ node: x.node, at, pins: [x.pin] });
            // Why a wait went on (its time came, it heard something, the tester took it: runtime.lua WHY).
            const on = s && s.pins.includes(x.pin) ? s : steps[steps.length - 1];
            if (x.kind === 'resume' && typeof x.text === 'string' && on && (on.note || '').length < 300) on.note = on.note ? on.note + '; ' + x.text : x.text;
        } else if (x.kind === 'rewind' && x.pin) {
            // The tester went back here in the test window, and on from this outcome.
            steps.push({ node: x.node, at, pins: [x.pin], note: `${x.text || 'gone back'}: taken by the tester` });
        } else if (x.kind === 'ignored' || x.kind === 'busy') {
            steps.push({ node: x.node, at, pins: [], note: x.kind === 'busy' ? 'already busy' : 'ignored (still waiting)' });
        } else if (x.kind === 'broken') {
            // A Fail Condition's rule broken (runtime.lua R.broken): a step of its own, with its Why.
            steps.push({ node: x.node, at, pins: [], note: `rule broken: ${x.text || ''}` });
        } else if (x.kind === 'log' && typeof x.text === 'string') {
            // What the card said as it ran (why it Could not: runtime.lua CTX:log), beside its step.
            const s = stepOf(x.node);
            if (s && (s.note || '').length < 300) s.note = s.note ? s.note + '; ' + x.text : x.text;
        }
    }
    // Its colour on the grid: green it succeeded, red it failed, yellow it could not
    // go on (went wrong, or was called off). Where it ended: the card it went wrong at, or its last step.
    const outcome = d.outcome || null;
    const fault = typeof d.faultNode === 'string' ? d.faultNode : null;
    // Nothing left to wait for (server/director/runtime.lua): no card failed, a branch went nowhere. What ran is
    // green, the card it stopped at red.
    const deadEnd = outcome === 'failed' && typeof d.reason === 'string' && d.reason.startsWith('nothing left to wait for');
    const tone = outcome === 'succeeded' || deadEnd ? 'ok' : outcome === 'failed' ? 'bad' : 'stuck';
    const end = fault || (steps.length ? steps[steps.length - 1].node : null);
    // A card whose last outcome means it could not do its work (Could not, Took too long, Didn't work) is red whatever
    // the run did, and so is a wire out of such an outcome (canvas.js ranTone). A Bad deal or Walked away is not.
    const lastPins = new Map();
    for (const s of steps) if (s.pins.length) lastPins.set(s.node, s.pins);
    const badNodes = new Set();
    for (const [id, pins] of lastPins) if (pins.every((p) => couldNot(p))) badNodes.add(id);
    if (deadEnd && end) {
        badNodes.add(end);
        const s = steps[steps.length - 1];
        if (s) s.note = (s.note ? s.note + '; ' : '') + 'the scenario stopped here: nothing wired on, nothing left to wait for';
    }
    const badLinks = new Set();
    for (const id of links) {
        const l = ed.doc.links.find((k) => k.id === id);
        if (l && couldNot(l.from.pin)) badLinks.add(id);
    }
    // What the playback has lit so far (canvas.js reveal / finishRun), and whether it is over.
    return { nodes, links, steps, outcome, reason: d.reason || null, fault, tone, end, badNodes, badLinks,
             shownNodes: new Set(), shownLinks: new Set(), done: false };
}

async function deactivate(key) {
    let r = await call('deactivate', { key });
    // Players in a run of it: switching off ends their runs, so nothing changed yet. Asked, then again.
    if (r.ok && r.data && r.data.going) {
        const n = r.data.going;
        const name = key === ed.key ? ed.doc.name : key;
        const pick = await ask(`Switch off ${name}?`, `${name} has ${plural(n, 'run')} going now. `
            + `${n === 1 ? 'It ends for its players' : 'They end for their players'}.`, [
            { label: 'Switch off', value: true, tone: 'danger' }, { label: 'Cancel', value: null },
        ]);
        if (!pick) return false;
        r = await call('deactivate', { key, endRuns: true });
    }
    if (!r.ok) { status(r.why, 'error'); return false; }
    if (key === ed.key) { ed.on = false; ed.onRev = null; }
    status('Switched off', 'ok');
    return true;
}

async function startRun(key) {
    const r = await call('startRun', { key });
    if (!r.ok) { status(r.why, 'error'); return; }
    status(`Run ${r.data.runId} started for you: close the editor to play it`, 'ok');
}

// ---- pulses: a card lights, and the wire it came along, as a run goes ----

const REPLAY_STEP_MS = 160;
const REPLAY_MAX = 80;   // the last steps of a long test: a playback of a few seconds, not minutes

/** The wire a step came in along: an entered card's, from the card and pin before it (null: none). */
function linkOfStep(s) {
    if ((s.kind !== 'enter' && s.kind !== 'skipped') || !s.from) return null;
    const l = ed.doc.links.find((k) => k.from.node === s.from && k.from.pin === s.fromPin && k.to.node === s.node && k.to.pin === s.pin);
    return l ? l.id : null;
}

/** One step of a live run, on the canvas: a card entered (and its wire), or a wait answered. */
function pulseStep(s) {
    if (!s || typeof s.node !== 'string') return;
    if (s.kind === 'enter' || s.kind === 'skipped' || s.kind === 'resume') canvas.pulse(s.node, linkOfStep(s));
}

/** A test, played back on the canvas in the order it ran, once it is over: each card
 *  and wire lit in the run's colour as it is reached, no flashing, then the card it ended on flashes. A
 *  long test's earlier steps are lit at once, the playback being its last REPLAY_MAX. */
function replay(trace) {
    const token = ++replayToken;
    const t = ed.lastTest;
    if (!t) return;
    const all = trace.filter((s) => s && typeof s.node === 'string' && (s.kind === 'enter' || s.kind === 'skipped' || s.kind === 'resume'));
    const steps = all.slice(-REPLAY_MAX);
    for (const s of all.slice(0, all.length - steps.length)) canvas.reveal(s.node, linkOfStep(s), false);
    const live = () => token === replayToken && ed.lastTest === t && ed.page === 'editor' && ed.doc;
    steps.forEach((s, i) => setTimeout(() => { if (live()) canvas.reveal(s.node, linkOfStep(s), true); }, 400 + i * REPLAY_STEP_MS));
    setTimeout(() => { if (live()) canvas.finishRun(); }, 400 + steps.length * REPLAY_STEP_MS);
}

/** The full editor's Back to the world (and its Esc): the world builder again, on the thing whose page is open, the
 *  camera where Fullscreen left it. */
function toWorld() {
    if (ed.page !== 'editor' || !ed.doc || ed.demo) return;
    replayToken++;
    commitField();
    const focus = ed.tab === 'world' && ed.worldOpen && findWorld(ed.doc, ed.worldOpen) ? ed.worldOpen : null;
    openBuilder(focus, true);
}

/** Before another scenario takes this one's place: its unsaved changes saved, thrown away, or kept (false: it
 *  stays open). The page shows while it asks. */
async function letGo() {
    commitField();
    if (!ed.doc || ed.demo || !ed.history || !ed.history.isDirty(ed.doc)) return true;
    const pick = await ask('Unsaved changes', `${ed.doc.name} has changes that are not saved.`, [
        { label: 'Save', value: 'save', tone: 'primary' },
        { label: 'Throw them away', value: 'drop', tone: 'danger' },
        { label: 'Keep editing', value: null },
    ]);
    if (pick === null) return false;
    if (pick === 'save' && !(await save())) return false;
    return true;
}

// ============================================================
// The list (the keys taken, for a copy's key; whether this player is in a world of their own)
// ============================================================

async function refreshHub() {
    const r = await call('list');
    if (!r.ok) { status(r.why, 'error'); return; }
    const d = r.data;
    d.scenarios = listOf(d.scenarios);
    ed.hub = d;
    if (typeof d.isolated === 'boolean' && d.isolated !== ed.isolated) { ed.isolated = d.isolated; drawDock(); }
}

/** The tutorial's own scenario (My first scenario): a new, empty one called `name`, opened here. Answers whether. */
async function newScenario(name) {
    if (!(await letGo())) return false;
    await refreshHub();
    const used = new Set(((ed.hub && ed.hub.scenarios) || []).map((s) => s.key));
    let key = slug(name, 'scenario'), i = 2;
    while (used.has(key)) key = slug(name, 'scenario') + '_' + (i++);
    const r = await call('create', { key, name, from: '' });
    if (!r.ok) { status(r.why, 'error'); return false; }
    await openScenario(key);
    return ed.key === key;
}



// ============================================================
// Lore characters: the story's named NPCs (server/director/lore.lua; made and changed in /whip)
// ============================================================

/** An NPC was made a lore character (World tab): it wears their ped and their name. */
function applyLore(w) {
    const c = w && w.def && (ed.lore || []).find((x) => x.key === w.def.lore);
    if (!c) return;
    if (c.model) w.def.model = c.model;
    w.label = c.name;
}

/** Opened: each lore character's NPC wears their ped as it is now. It may have changed in /whip since the scenario was
 *  saved, and a run makes them in it anyway (server/npcs.lua). Not a change of its own: the next save keeps it. */
function loreAsNow(doc) {
    let moved = false;
    for (const w of doc.world || []) {
        if (!w || w.kind !== 'npc' || !w.def || !w.def.lore) continue;
        const c = (ed.lore || []).find((x) => x.key === w.def.lore);
        if (c && c.model && w.def.model !== c.model) { w.def.model = c.model; moved = true; }
    }
    return moved;
}

/** The same for every variant's things: the open one's (the view), Variant 1's own (when another is open) and the
 *  others' own. */
function loreAsNowAll(doc) {
    let moved = loreAsNow(doc);
    if (doc._base) moved = loreAsNow({ world: doc._base.world }) || moved;
    for (const v of doc.variants || []) if (Array.isArray(v.world)) moved = loreAsNow({ world: v.world }) || moved;
    return moved;
}

// ============================================================
// Drawing the column
// ============================================================

// What the head and the bar were last drawn as. They are drawn again in place, not rebuilt: a typed field let go of by
// pressing Save (or Back) redraws them between that press and its release, and a rebuilt button lost the click.
let headDrawn = null;
let headDirty = false;   // what the head said last: not saved

/** `dirtyKnown` true: it is not saved, known already (a key typed): no need to compare the document with the saved one. */
function drawHead(dirtyKnown) {
    const head = colEl.querySelector('.dr-head');
    const bar = colEl.querySelector('.dr-bar');
    if (ed.page !== 'editor') {
        headDrawn = null;
        head.innerHTML = '<div class="dr-head-main"><div class="dr-title">Director</div></div>'
            + `<button class="dr-icon" data-act="close" aria-label="Close" title="Close (Esc)">${ICON.close}</button>`;
        bar.innerHTML = '';
        return;
    }
    const dirty = dirtyKnown === true || ed.history.isDirty(ed.doc);
    headDirty = dirty;
    // Under the name: the key and draft, whether it is on, and not saved. Back to the world: the builder again (an example
    // the tutorial shows is not in the world).
    const state = ed.on ? `<span class="dr-pill ok">On · r${ed.onRev}</span>` : '<span class="dr-pill">Off</span>';
    const html = (ed.demo ? ''
        : `<button class="dr-icon" data-act="world" aria-label="Back to the world" title="Back to the world (Esc)">${ICON.back}</button>`)
        + `<div class="dr-head-main"><div class="dr-title">${e(ed.doc.name)}</div>`
        + (ed.demo ? '<div class="dr-sub">An example, open only to look at</div></div>'
            : `<div class="dr-sub dr-state"><span>${e(ed.key)} · draft r${ed.baseRev}</span>${state}</div></div>`)
        // Its X puts the column away, the grid the whole screen (Add card brings it back); an example's closes.
        + (ed.demo ? `<button class="dr-icon" data-act="close" aria-label="Close" title="Close (Esc)">${ICON.close}</button>`
            : `<button class="dr-icon" data-act="col-hide" aria-label="Hide this panel" title="Hide this panel: the blueprint full screen">${ICON.close}</button>`);
    if (headDrawn !== html || !head.firstChild) { head.innerHTML = html; headDrawn = html; }
    const stateRow = head.querySelector('.dr-state');
    const mark = stateRow && stateRow.querySelector('.dr-dirty');
    if (stateRow && dirty && !mark) stateRow.insertAdjacentHTML('beforeend', '<b class="dr-dirty">not saved</b>');
    else if (mark && !dirty) mark.remove();
    // Check carries what the last check found, in every variant: the errors in red (they stop it switching on), else
    // the warnings.
    const all = ed.problemsAll || ed.problemList;
    const errs = all.filter((p) => p.severity === 'error').length;
    const warns = all.length - errs;
    const count = errs ? `<span class="dr-count">${errs}</span>` : warns ? `<span class="dr-count warn">${warns}</span>` : '';
    const checkTitle = errs ? `${plural(errs, 'problem')} to fix before it can be switched on`
        : warns ? plural(warns, 'warning') : 'What is wrong, the last test, and switching it on';
    if (!bar.querySelector('[data-act="save"]')) {
        bar.innerHTML = '<button class="dr-btn primary" data-act="save">Save</button>'
            + '<button class="dr-btn" data-act="test" title="Play it now, alone, with nothing of value. In the game, F5 starts it again and F9 comes back here">Test</button>'
            + '<button class="dr-btn" data-act="check">Check</button>'
            + '<span class="dr-bar-gap"></span>'
            + `<button class="dr-ibtn" data-act="undo" aria-label="Undo" title="Undo (Ctrl+Z)">${ICON.undo}</button>`
            + `<button class="dr-ibtn" data-act="redo" aria-label="Redo" title="Redo (Ctrl+Y)">${ICON.redo}</button>`;
    }
    bar.querySelector('[data-act="save"]').disabled = !(dirty && !ed.pack);
    const chk = bar.querySelector('[data-act="check"]');
    chk.title = checkTitle;
    if (chk.dataset.count !== count) { chk.innerHTML = 'Check' + count; chk.dataset.count = count; }
    bar.querySelector('[data-act="undo"]').disabled = !(ed.history.canUndo() || dirty);
    bar.querySelector('[data-act="redo"]').disabled = !ed.history.canRedo();
}

/** THE DOCK, top right over the grid: Isolate world (puts you in your own routing bucket), lit while
 *  you are in it, and the tutorial's stages. */
function drawDock() {
    const dock = root && root.querySelector('.dr-dock');
    if (!dock) return;
    const on = ed.isolated;
    dock.innerHTML = `<button class="dr-dock-btn${on ? ' on' : ''}" data-act="isolate" title="${on
        ? 'You are in a world of your own: no other players and no traffic, and your tests are made here. Press to go back to the shared world (closing the Director does too).'
        : 'A world of your own while you build: no other players and no traffic, and your tests are made in it. It ends when you close the Director.'}">`
        + `<span class="dr-dock-dot"></span>${on ? 'Own world' : 'Isolate world'}</button>`
        + '<button class="dr-dock-btn" data-act="tutorial" title="The Director tutorial: go through any of its stages again">'
        + '<span class="dr-dock-q">?</span>Tutorial</button>';
}

/** Isolate world on or off. The server says where you are; a refusal (in a car, in a job) is said. */
async function toggleIsolate() {
    const r = await call('isolate', { on: !ed.isolated });
    if (!r.ok) { status(r.why, 'error'); return; }
    ed.isolated = r.data.isolated === true;
    drawDock();
    status(ed.isolated ? 'In a world of your own: your tests are made here too' : 'Back in the shared world', 'ok');
}

/** A scenario always has a Scenario Enabled card: its page is where the settings are (how a run starts). One opened
 *  with none gets it, left of its cards, as it opens (before its undo history: not a change of its own). */
function startCardAlways(doc) {
    if ((doc.nodes || []).some((n) => n.type === 'scenario.started')) return;
    const xs = doc.nodes.map((n) => n.x), ys = doc.nodes.map((n) => n.y);
    doc.nodes.push({ id: freeId(new Set(doc.nodes.map((n) => n.id)), 'start'), type: 'scenario.started', v: 1,
                     x: (xs.length ? Math.min(...xs) : 0) - 336, y: ys.length ? Math.min(...ys) : 0, props: {} });
}

function drawColumn() {
    // (The Settings tab is the Scenario Enabled card's page now: a page left on it goes home.)
    if (ed.tab === 'settings') ed.tab = 'cards';
    if (ed.homeTab === 'settings') ed.homeTab = 'cards';
    // A card's page with no card picked is gone: the tab under it is back. A tab shown is the one a page
    // goes back to.
    if (ed.tab === 'card' && !ed.selected.size) ed.tab = ed.homeTab;
    if (isTab(ed.tab)) ed.homeTab = ed.tab;
    // The column away, and the page showing something else in it (Check after a refused save, a thing to place): it is
    // back. A card picked is not that: its page is on the right, the column as it was.
    if (ed.colHidden && colShows() !== ed.colHiddenTab) {
        if (sideOn()) ed.colHiddenTab = colShows();
        else ed.colHidden = false;
    }
    drawColHidden();
    drawHead();
    // A card's page on the right: the column keeps the tab under it (and the item picker is the page's).
    const side = sideOn();
    const tab = ed.tab, picker = ed.picker;
    if (side) { ed.tab = ed.homeTab; ed.picker = null; }
    const body = colEl.querySelector('.dr-body');
    // Where it was scrolled to, kept while the same tab or page redraws; another one opens at its top.
    const view = ed.page + ':' + ed.tab + ':' + (ed.tab === 'world' ? (ed.worldOpen || '') + ':' + (ed.thingTab || '') : '')
        + (ed.picker ? ':pick' : '') + (ed.taskPick ? ':tasks' : '') + (ed.taskCopy ? ':copy:' + (ed.taskCopy.from || '') : '');
    const scroll = view === drawnView ? body.scrollTop : 0;
    drawnView = view;
    const palette = ed.page === 'editor' && ed.tab === 'cards' && !ed.picker;
    // The card list and the item picker scroll inside, under their search.
    body.classList.toggle('split', palette || (ed.page === 'editor' && !!ed.picker));
    body.innerHTML = ed.page === 'editor' ? renderTab(ed) : '';
    body.scrollTop = scroll;
    if (side) { ed.tab = tab; ed.picker = picker; }
    drawSide();
    if (palette) {
        const list = body.querySelector('.dr-pal-list');
        if (list) list.scrollTop = ed.palScroll;
    }
    const tabs = colEl.querySelector('.dr-tabs');
    tabs.querySelectorAll('.dr-tab').forEach((t) => t.classList.toggle('on', t.dataset.tab === ed.homeTab));
    showUses(false);
    // The world builder's panel draws the same page (builder.page), and hears what changed.
    drawPane();
    builderSync();
}

// ---- THE CARD'S PAGE ON THE RIGHT (the full editor) ----
//
// A card picked opens its settings in a panel on the right, as the world builder's Configure does, and the
// column keeps its tab: the card list, the World tab, Check. The world builder has its own panel (drawPane).

/** Does a card's page go on the right? In the full editor, not the world builder. */
const sideMode = () => !building;
/** Is a card's page on the right now? */
const sideOn = () => sideMode() && ed.page === 'editor' && !!ed.doc && ed.tab === 'card' && ed.selected.size > 0;
/** Where the page being worked on is drawn: the panel on the right, or the column. */
const pageBody = () => (sideOn() ? sideEl.querySelector('.dr-side-body') : colEl.querySelector('.dr-body'));
/** What the column shows, as drawColumn draws it: with a card's page on the right, the tab under it. */
function renderColumn() {
    if (!sideOn()) return renderTab(ed);
    const tab = ed.tab, picker = ed.picker;
    ed.tab = ed.homeTab;
    ed.picker = null;
    try { return renderTab(ed); } finally { ed.tab = tab; ed.picker = picker; }
}

function drawSide() {
    if (!sideEl) return;
    const on = sideOn();
    const body = sideEl.querySelector('.dr-side-body');
    root.classList.toggle('side-open', on);
    if (!on) {
        if (!sideEl.hidden) { sideEl.hidden = true; body.innerHTML = ''; sideView = ''; }
        return;
    }
    sideEl.hidden = false;
    const view = (ed.picker ? 'pick:' : '') + [...ed.selected].join(',');
    const scroll = view === sideView ? body.scrollTop : 0;
    sideView = view;
    body.classList.toggle('split', !!ed.picker);
    // (No way back at its top: its X is.)
    ed.sidePage = true;
    body.innerHTML = renderTab(ed);
    ed.sidePage = false;
    body.scrollTop = scroll;
}

// ---- THE COLUMN AWAY (the full editor): the blueprint the whole screen ----
//
// The column's X puts it away; Add card, at its top left over the grid, as the world builder's Blueprint window has, brings
// it back on the card list. A card's page still opens on the right. What the column would say is said low on the left
// (status). Not while the tutorial runs: it points into the column.

/** What the column shows: its tab, or the page over it (Check, a thing's); with a card's page on the right, its tab. */
const colShows = () => (sideOn() ? ed.homeTab : ed.tab);

function drawColHidden() {
    if (!root) return;
    if (ed.colHidden && (ed.page !== 'editor' || !ed.doc || ed.demo || tutorialRunning())) ed.colHidden = false;
    root.classList.toggle('col-hidden', ed.colHidden);
}

function hideCol() {
    commitField();
    ed.colHidden = true;
    ed.colHiddenTab = colShows();
    drawColumn();
}

function showCol() {
    ed.colHidden = false;
    ed.homeTab = 'cards';
    if (ed.tab !== 'card') ed.tab = 'cards';
    drawColumn();
}

/** The item picker away: back on the page it was opened from, scrolled where it was. */
function closePicker() {
    if (!ed.picker) return;
    const scroll = ed.picker.scroll || 0;
    ed.picker = null;
    drawColumn();
    pageBody().scrollTop = scroll;
}

/** THE CARDS THAT USE A PLACED THING: lit white
 *  on the grid while its World row is open, flashing as it opens. None when no row is open or the World
 *  tab is not the one showing. */
function showUses(flash) {
    if (!canvas) return;
    // (In the world builder: only while its panel shows that thing's page, Configure's. With a card's page on the
    // right, the column's World tab.)
    const world = ed.tab === 'world' || (sideOn() && ed.homeTab === 'world');
    const id = ed.page === 'editor' && ed.doc && world && (!building || pane) ? ed.worldOpen : null;
    canvas.setUses(id ? usesOfWorld(ed.doc, ed.cards, id).map((u) => u.node.id) : [], flash);
}

// ---- THE VARIANT BUTTONS over the grid (Multi Run Variants: doc.js) ----
//
// One per variant ("1 · Mirror Park", "2 · Vespucci"), the open one lit, then + Variant (a copy of the open one, to
// change). The open one's ⋯ renames, copies, moves or deletes it. A scenario with one variant shows + Variant alone.
// The strip lives in the grid's host, so the world builder's Blueprint window carries it too.

function drawVariants() {
    const strip = root && root.querySelector('.dr-variants');
    if (!strip) return;
    if (ed.page !== 'editor' || !ed.doc || ed.demo) { strip.innerHTML = ''; strip.hidden = true; return; }
    const list = variantList(ed.doc);
    const open = openVariant();
    const readOnly = !!ed.pack;
    strip.hidden = readOnly && list.length < 2;
    let html = '';
    if (list.length > 1) {
        html = list.map((v, i) => {
            const on = v.id === open;
            const errs = (ed.problemsAll || []).filter((p) => p.variant === v.id && p.severity === 'error').length;
            if (on && ed.variantRename === v.id) {
                return `<span class="dr-var on editing"><b>${i + 1}</b><input class="dr-var-input" maxlength="40" value="${e(v.name)}"`
                    + ` placeholder="Variant ${i + 1}" aria-label="Variant ${i + 1}'s name" spellcheck="false"></span>`;
            }
            return `<button class="dr-var${on ? ' on' : ''}" data-act="variant-open" data-id="${e(v.id)}"`
                + ` title="${on ? 'Open: its own cards and things' : 'Open this variant'}${errs ? ` · ${plural(errs, 'problem')}` : ''}">`
                + `<b>${i + 1}</b><span class="dr-var-name">${e(v.name || `Variant ${i + 1}`)}</span>`
                + (errs ? `<i class="dr-var-err">${errs}</i>` : '')
                + (on && !readOnly ? '<span class="dr-var-more" data-act="variant-menu" title="Rename, copy, move or delete it">'
                    + '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="3.5" cy="8" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="12.5" cy="8" r="1.4"/></svg></span>' : '')
                + '</button>';
        }).join('');
    }
    if (!readOnly && list.length < MAX_VARIANTS) {
        html += '<button class="dr-var add" data-act="variant-new" title="A new variant of this job: a copy of the open one, to change. What is always present and the start are every variant\'s">+ Variant</button>';
    }
    strip.innerHTML = html;
    const input = strip.querySelector('.dr-var-input');
    if (input) {
        input.focus();
        input.select();
    }
}

/** Open another variant: its cards, wires, boxes and own things; what every variant shares stays as it is. */
function switchVariant(id) {
    if (!ed.doc || id === openVariant()) return;
    if (ed.busy) { status('Wait for it to finish first', 'warn'); return; }
    if (building) { builderSwitchVariant(id); return; }
    commitField();
    ed.views = ed.views || new Map();
    ed.views.set(openVariant(), { ...canvas.view });
    ed.doc = unpackDoc(packed(), id, taskTypes());
    resetPicks();
    setProblems(ed.problemsAll, true);
    const view = ed.views.get(id);
    if (view) { canvas.view = { ...view }; canvas.applyView(); }
    drawAll();
    builderSync();
    status(`${variantLabel(ed.doc, id)}: its own cards and things. What is always present, and the start, are every variant's`);
}

/** In the world builder, which holds one variant's things: its Done first (the camera kept, its Save still to press),
 *  then, once the world is written (directorShow), the switch, and the builder open again on the other's things. */
function builderSwitchVariant(id) {
    commitField();
    ed.variantAfter = id;
    nuiCallback('directorBuilderDone', { aside: true });
}

/** A change to the variants themselves (one made, renamed, moved or taken out), on the document as kept; then `open`
 *  (default: the one open now, else Variant 1) is the one open. */
function changeVariants(fn, open) {
    commitField();
    const canon = packed();
    fn(canon);
    const want = open || openVariant();
    const exists = variantList(canon).some((v) => v.id === want);
    const was = openVariant();
    ed.doc = unpackDoc(canon, exists ? want : 'v1', taskTypes());
    if (openVariant() !== was) resetPicks();
    setProblems(ed.problemsAll, true);
    ed.changed();
    drawVariants();
}

function addVariant() {
    if (ed.pack) return;
    let made = null;
    let freed = false;
    changeVariants((canon) => {
        const before = variantList(canon).length;
        made = newVariant(canon, openVariant(), taskTypes());
        // Runs at once at what it was (one, by default) would let only that many variants play at once: emptied, it is
        // one run per variant.
        const s = canon.settings || {};
        if (made && typeof s.maxConcurrentRuns === 'number' && s.maxConcurrentRuns <= before) {
            delete s.maxConcurrentRuns;
            freed = true;
        }
    });
    if (!made) { status(`At most ${MAX_VARIANTS} variants`, 'warn'); return; }
    switchVariant(made);
    status(`${variantLabel(ed.doc, made)} is a copy of the one you had open: change it as you like`
        + (freed ? '. Runs at once is now one per variant (Scenario Enabled)' : ''), 'ok');
}

/** The open variant's ⋯: rename it, make a copy, move it, or delete it (Variant 1, the document itself, is never
 *  deleted or moved: it is renamed only). */
function variantMenu(anchor) {
    const id = openVariant();
    const list = variantList(ed.doc);
    const i = list.findIndex((v) => v.id === id);
    const items = [{ value: 'rename', label: 'Rename' }];
    if (list.length < MAX_VARIANTS) items.push({ value: 'copy', label: 'Make a copy of it' });
    if (i > 1) items.push({ value: 'earlier', label: 'Move earlier' });
    if (i > 0 && i < list.length - 1) items.push({ value: 'later', label: 'Move later' });
    if (id !== 'v1') items.push({ value: 'delete', label: 'Delete it', sub: 'Its cards and its own things go (Ctrl+Z brings them back)' });
    openChoices(anchor, items, null, (what) => {
        if (what === 'rename') { ed.variantRename = id; drawVariants(); }
        else if (what === 'copy') addVariant();
        else if (what === 'earlier' || what === 'later') changeVariants((canon) => moveVariant(canon, id, what === 'earlier' ? -1 : 1));
        else if (what === 'delete') {
            const name = variantLabel(ed.doc, id);
            changeVariants((canon) => removeVariant(canon, id), 'v1');
            status(`${name} deleted: Ctrl+Z brings it back`, 'ok');
        }
    }, { label: 'This variant' });
}

/** The name being typed into the lit button, kept (Enter, or leaving it) or not (Esc). */
function finishRename(keep) {
    const id = ed.variantRename;
    ed.variantRename = null;
    const input = root && root.querySelector('.dr-var-input');
    if (!id || !input) { drawVariants(); return; }
    const name = input.value;
    if (keep && name.trim() !== (variantList(ed.doc).find((v) => v.id === id) || {}).name) {
        changeVariants((canon) => renameVariant(canon, id, name));
    } else {
        drawVariants();
    }
}

function drawAll() {
    drawVariants();
    const editing = ed.page === 'editor';
    colEl.classList.toggle('editing', editing);
    colEl.querySelector('.dr-bar').style.display = editing ? '' : 'none';
    colEl.querySelector('.dr-tabs').style.display = editing ? '' : 'none';
    root.querySelector('.dr-empty').textContent = editing
        ? 'Right-click the grid to add a card, or pick one in Cards.'
        : 'Open a scenario from /whip: Director.';
    drawColumn();
    canvas.render();
    if (!editing) root.querySelector('.dr-empty').style.display = '';
}

// ============================================================
// The column's clicks and fields
// ============================================================

async function onAct(act, el) {
    switch (act) {
        // ---- the screen ----
        case 'close': return closeScreen();
        case 'world': return toWorld();
        case 'col-hide': return hideCol();
        case 'col-show': return showCol();
        case 'isolate': return toggleIsolate();
        case 'tutorial': commitField(); if (ed.colHidden) showCol(); return tutorialMenu();
        // ---- the editor ----
        case 'save': return save();
        case 'check': return check(false);
        case 'undo': return undo();
        case 'redo': return redo();
        case 'variant-open': return switchVariant(el.dataset.id);
        case 'variant-new': return addVariant();
        case 'variant-menu': return variantMenu(el);
        // ---- In order: the list of variants a new run takes in turn (panels.js variantsGroup) ----
        case 'vorder-fill':
        case 'vorder-add':
        case 'vorder-move':
        case 'vorder-remove': {
            commitField();
            const s = ed.doc.settings;
            const known = new Set(variantList(ed.doc).map((v) => v.id));
            const order = (Array.isArray(s.variantOrder) ? s.variantOrder : []).filter((id) => known.has(id));
            const i = Number(el.dataset.i);
            if (act === 'vorder-fill') order.splice(0, order.length, ...known);
            else if (act === 'vorder-add' && known.has(el.dataset.id) && !order.includes(el.dataset.id)) order.push(el.dataset.id);
            else if (act === 'vorder-remove' && order[i]) order.splice(i, 1);
            else if (act === 'vorder-move') {
                const j = i + Number(el.dataset.by);
                if (order[i] && order[j]) [order[i], order[j]] = [order[j], order[i]];
            }
            s.variantOrder = order;
            return ed.changed();
        }
        case 'activate': return activate();
        case 'test': return test();
        case 'clear-test': ed.lastTest = null; canvas.render(); return drawColumn();
        case 'deactivate': await deactivate(ed.key); return drawColumn();
        case 'start-run': return startRun(ed.key);
        case 'dup-sel': return duplicateSelected();
        case 'del-sel': return deleteSelected();
        case 'clear-prop': {
            const n = findNode(ed.doc, el.dataset.id);
            if (n) { delete n.props[el.dataset.k]; ed.changed(); }
            return;
        }
        case 'goto-prob': {
            // Every card the problem is about, selected and in view.
            const p = ed.problemList[Number(el.dataset.i)];
            const ids = p ? problemCards(p).filter((id) => findNode(ed.doc, id)) : [];
            if (ids.length) {
                ed.selected = new Set(ids);
                ed.selectedLink = null;
                ed.selectedNote = null;   // or Delete would take the box, not the cards shown picked
                canvas.render();
                canvas.frame(ids);
                drawColumn();
            }
            return;
        }
        case 'prob-fix': {
            // To where it is fixed: the placed thing in the World tab, or the Scenario Enabled card's page (its settings).
            const p = ed.problemList[Number(el.dataset.i)];
            if (!p) return;
            if (p.tab === 'world' && p.world) { ed.tab = 'world'; ed.worldOpen = p.world; }
            else if (p.tab === 'settings') {
                const s = ed.doc.nodes.find((n) => n.type === 'scenario.started');
                if (s) {
                    ed.selected = new Set([s.id]);
                    ed.selectedLink = null;
                    ed.selectedNote = null;
                    ed.tab = 'card';
                    canvas.render();
                    canvas.frame([s.id]);
                }
            }
            return drawColumn();
        }
        case 'goto-node': {
            if (findNode(ed.doc, el.dataset.id)) {
                ed.selected = new Set([el.dataset.id]);
                ed.selectedLink = null;
                ed.selectedNote = null;
                canvas.render();
                canvas.frame([el.dataset.id]);
                // Its page on the right, the list it was picked from still in the column.
                if (sideMode()) { ed.tab = 'card'; drawColumn(); }
            }
            return;
        }
        // A placed thing's page, and the way back to the list.
        case 'world-open':
            commitField();
            ed.worldOpen = el.dataset.id;
            ed.taskPick = null;
            ed.taskCopy = null;
            drawColumn();
            showUses(true);   // the cards that use it flash
            return;
        case 'world-back': commitField(); ed.worldOpen = null; ed.multi = null; ed.taskPick = null; ed.taskCopy = null; ed.voicePick = null; return drawColumn();
        // A page's way back (a card's settings: unpicked; Check), to the tab under it.
        case 'page-back':
            commitField();
            if (ed.tab === 'card') return ed.select([]);
            ed.tab = ed.homeTab;
            return drawColumn();
        // One more of a card's numbered sets (its `repeats`: a Dialog Line's answer, NPC /me's alternative): shown,
        // and typed into at once (panels.js repeatShown).
        case 'repeat-add': {
            const n = findNode(ed.doc, el.dataset.id);
            const def = n && ed.cards.get(n.type);
            const r = Number(el.dataset.r);
            if (!def || !def.repeats || !def.repeats[r]) return;
            commitField();
            const rep = def.repeats[r];
            const next = Math.min(rep.to, repeatShown(ed, n, def, r) + 1);
            ed.repeatOpen[n.id + ':' + r] = next;
            drawColumn();
            const box = pageBody().querySelector(`.dr-field[data-t="node:${CSS.escape(n.id)}"][data-k="${CSS.escape(rep.keys[0].replace('%d', next))}"]`);
            if (box) box.focus();
            return;
        }
        // THE ITEM PICKER (panels.js itemPicker): opened from an item field, over its page; a pick (or
        // Clear) writes the field and goes back to where it was.
        case 'item-pick':
            commitField();
            return openItemPicker(el.dataset.t, el.dataset.k, el.dataset.label || 'Item', el.dataset.req === '1', el);
        // ---- a card's several placed things (kind 'worlds': Spawn NPC's NPCs; panels.js worldsField) ----
        // One's page, from the card's: the World tab, on it.
        case 'card-world-open': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            ed.tab = 'world';
            ed.homeTab = 'world';
            ed.worldOpen = w.id;
            ed.taskPick = null;
            ed.taskCopy = null;
            drawColumn();
            showUses(true);
            return;
        }
        case 'worlds-remove': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            setWorlds(n, el.dataset.k, worldsOf(n, el.dataset.k).filter((x) => x !== el.dataset.w));
            ed.changed();
            return;
        }
        // A new one for the card: in the World tab (made by a run, not standing), and the world builder opened on it,
        // so the next ped picked is it, put down where it is wanted.
        // A time box's chevron (panels.js timeField): its unit's list, the pick written as typing it would be.
        case 'dhms-pick': {
            const box = el.closest('.dr-dhms-box');
            const input = box && box.querySelector('input[data-part]');
            if (!input) return;
            openChoices(box, dhmsChoices(input.dataset.part, input.value || input.placeholder), input.value || input.placeholder, (v) => {
                input.value = v;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                drawColumn();   // (picked, not typed: its page says the new length at once)
            }, { label: input.getAttribute('aria-label') || '' });
            return;
        }
        // A car's key spot (its Key settings, Placed in the world: panels.js carKeyGroup), made and placed in the builder.
        case 'key-spot': {
            const car = findWorld(ed.doc, el.dataset.id);
            if (!car || car.kind !== 'vehicle') return;
            commitField();
            const id = freeId(worldIds(ed.doc), car.id + '_key');
            const w = newWorldThing('groundItem', { label: `${car.label || car.id}'s key` }, id);
            w.def = { item: 'vehicle_key', amount: 1, keyOf: car.id };
            ed.doc.world.push(w);
            if (!car.def.key || typeof car.def.key !== 'object') car.def.key = { exists: true, where: 'world' };
            car.def.key.spot = id;
            ed.changed();
            if (building && putInBuilder(w)) return;
            return openBuilder(id);
        }
        // ---- Create Container's slots (panels.js lootEditor) ----
        case 'loot-slot': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            const slot = Number(el.dataset.slot);
            ed.lootSel = ed.lootSel && ed.lootSel.node === n.id && ed.lootSel.slot === slot ? null : { node: n.id, slot };
            return drawColumn();
        }
        case 'loot-add': {
            const n = findNode(ed.doc, el.dataset.id);
            const slot = Number(el.dataset.slot);
            if (!n || !(slot >= 1)) return;
            commitField();
            if (!Array.isArray(n.props.loot)) n.props.loot = [];
            const used = n.props.loot.filter((x) => x && Number(x.slot) === slot).reduce((t, x) => t + (Number(x.chance) || 100), 0);
            n.props.loot.push({ slot, item: '', min: 1, max: 1, chance: Math.max(1, 100 - used) });
            ed.changed();
            // Straight to what it is: the item picker, for the new one.
            return openItemPicker(`loot:${n.id}:${n.props.loot.length - 1}`, 'item', `Slot ${slot}`, true, el);
        }
        case 'loot-remove': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n || !Array.isArray(n.props.loot)) return;
            commitField();
            n.props.loot.splice(Number(el.dataset.i), 1);
            if (!n.props.loot.length) delete n.props.loot;
            ed.changed();
            return;
        }
        // Simulate randomness: one roll of every slot in place of the layout (Roll again), until Return to edit.
        case 'loot-sim': {
            const n = findNode(ed.doc, el.dataset.id);
            const c = n && typeof n.props.container === 'string' && findWorld(ed.doc, n.props.container);
            if (!c) return;
            commitField();
            const slots = Math.max(1, Math.min(100, Math.floor(Number(c.def.slots) || 10)));
            const loot = Array.isArray(n.props.loot) ? n.props.loot
                : (n.props.item ? [{ slot: 1, item: n.props.item, min: n.props.amount || 1, max: n.props.amount || 1, chance: 100 }] : []);
            ed.lootSim = { node: n.id, items: rollLoot(loot, slots) };
            return drawColumn();
        }
        case 'loot-edit':
            ed.lootSim = null;
            return drawColumn();
        case 'pick-back': return closePicker();
        case 'pick-kind':
            if (!ed.picker) return;
            ed.picker.kind = el.dataset.kind;
            ed.picker.query = '';
            return drawColumn();
        case 'pick-item':
        case 'pick-clear': {
            const p = ed.picker;
            if (!p) return;
            const changed = writeValue(ed, p.t, p.k, act === 'pick-item' ? el.dataset.key : '');
            closePicker();
            if (changed) ed.changed();
            return;
        }
        // The card list's chips: the list scrolled to that kind.
        case 'pal-jump': {
            // (The list beside these chips: the column's, or the Blueprint window's in the world builder.)
            const top = el.closest('.dr-pal-top');
            const list = (top && top.parentNode.querySelector('.dr-pal-list')) || colEl.querySelector('.dr-pal-list');
            const head = list && list.querySelector(`.dr-cat[data-cat="${CSS.escape(el.dataset.cat)}"]`);
            if (head) list.scrollTop = head.offsetTop - 4;   // the list is the heads' offset parent
            return;
        }
        // A Dialog Line answer's rules (panels.js ruleField): open one at a time, or take them off.
        case 'rule-open': {
            const k = el.dataset.id + ':' + el.dataset.k;
            commitField();
            ed.ruleOpen = ed.ruleOpen === k ? null : k;
            return drawColumn();
        }
        case 'rule-clear': {
            const n = findNode(ed.doc, el.dataset.id);
            ed.ruleOpen = null;
            if (n && n.props[el.dataset.k] !== undefined) { delete n.props[el.dataset.k]; return ed.changed(); }
            return drawColumn();
        }
        // Everything in the World tab is placed in the world builder (the furnisher): its
        // Props, NPCs, Vehicles and More tabs, or by name.
        case 'build-open': return openBuilder(null);
        case 'autosave': {
            try { localStorage.setItem(AUTOSAVE_KEY, autosaveOn() ? 'off' : 'on'); } catch (_) { /* no storage: it stays on */ }
            return drawColumn();
        }
        case 'card-style': {
            const style = el.dataset.style === 'classic' ? 'classic' : 'board';
            try { localStorage.setItem(CARD_STYLE_KEY, style); } catch (_) { /* no storage: for this time only */ }
            canvas.setStyle(style);
            return drawColumn();
        }
        case 'build': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (building && w && putInBuilder(w)) return;
            return openBuilder(el.dataset.id);
        }
        case 'remove-world': {
            const id = el.dataset.id;
            const uses = usesOfWorld(ed.doc, ed.cards, id).length;
            // (One every variant shares goes from all of them.)
            const elsewhere = sharedIds(ed.doc, taskTypes()).has(id) ? otherUses('world', id) : 0;
            if (uses || elsewhere) {
                const here = `${uses} card${uses === 1 ? ' names' : 's name'} it`;
                const there = elsewhere ? `${uses ? ', and ' : ''}${elsewhere} in the other variants (every variant has it)` : '';
                const pick = await ask('Remove it?', `${uses ? here : ''}${there}; they will need another.`, [
                    { label: 'Remove', value: true, tone: 'danger' }, { label: 'Cancel', value: null },
                ]);
                if (!pick) return;
            }
            ed.doc.world = ed.doc.world.filter((w) => w.id !== id);
            ed.worldOpen = null;
            return ed.changed();
        }
        // ---- a placed thing's page: its tabs (panels.js thingTabs) ----
        case 'thing-tab': commitField(); ed.thingTab = el.dataset.tab; ed.taskPick = null; ed.taskCopy = null; ed.voicePick = null; return drawColumn();
        // ---- another resource's button on a thing's page (panels.js thingButtons) ----
        case 'thing-button': {
            const w = findWorld(ed.doc, el.dataset.id);
            const b = ed.buttons.find((x) => x.id === el.dataset.button);
            // (On a random vehicle's model row: for that model.)
            if (w && b) pressButton(w, b, el.dataset.model || undefined);
            return;
        }
        // ---- another resource's card list (panels.js entriesField): its button, on an entry or to add one; x ----
        case 'entry-press':
        case 'entry-remove': {
            const n = findNode(ed.doc, el.dataset.id);
            const def = n && ed.cards.get(n.type);
            const f = def && (def.props || []).find((p) => p.key === el.dataset.k && p.kind === 'entries');
            if (!f) return;
            const i = el.dataset.i !== undefined ? Number(el.dataset.i) : undefined;
            if (act === 'entry-press') {
                const b = ed.buttons.find((x) => x.id === f.button);
                if (b) pressCardButton(n, f, b, i);
                return;
            }
            const list = Array.isArray(n.props[f.key]) ? n.props[f.key].slice() : [];
            if (!Number.isInteger(i) || !list[i]) return;
            commitField();
            list.splice(i, 1);
            if (list.length) n.props[f.key] = list;
            else delete n.props[f.key];
            return ed.changed();
        }
        // ---- a random vehicle's models (panels.js carModelsGroup) ----
        case 'car-model-remove': {
            const w = findWorld(ed.doc, el.dataset.id);
            const list = w ? carModels(w) : [];
            const i = Number(el.dataset.i);
            if (!list[i]) return;
            commitField();
            list.splice(i, 1);
            fillChances(list);
            setCarModels(w, list);
            return ed.changed();
        }
        // Picked in the world builder's Vehicles: a vehicle pressed there joins the list (builder.addModel), until Done.
        case 'car-model-pick': {
            if (!building || !findWorld(ed.doc, el.dataset.id)) return;
            commitField();
            ed.modelPick = el.dataset.id;
            drawColumn();
            if (pane && pane.hooks && pane.hooks.vehicles) pane.hooks.vehicles(true);
            return;
        }
        case 'car-model-pick-end': return endModelPick();
        // An NPC's Outfit (panels.js outfitGroup): a random one of what its ped has, or none (as the game makes it).
        case 'outfit-random': {
            const w = findWorld(ed.doc, el.dataset.id);
            const o = w && outfitRandom(ed, w);
            if (!o) return;
            commitField();
            w.def.outfit = o;
            return ed.changed();
        }
        case 'outfit-reset': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !w.def.outfit) return;
            commitField();
            delete w.def.outfit;
            return ed.changed();
        }
        // A freemode NPC's look in the character editor (panels.js lookGroup); in the world builder, its Done first.
        case 'npc-look': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (w) editLook(w);
            return;
        }
        case 'npc-look-off': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !w.def.look) return;
            commitField();
            delete w.def.look;
            status('Its look is taken off: it is the game\'s own freemode ped again', 'ok');
            return ed.changed();
        }
        // Typed by its name: this game must have it, and it must be a vehicle (client/director.lua asks the game).
        case 'car-model-add': {
            const w = findWorld(ed.doc, el.dataset.id);
            const box = el.classList.contains('dr-carmodel-input') ? el : el.parentNode && el.parentNode.querySelector('.dr-carmodel-input');
            const name = box ? box.value.trim().toLowerCase() : '';
            if (!w || !name) return;
            const r = await nuiCallback('directorVehicleModel', { model: name });
            if (!r || r.ok !== true) { sayOnPage((r && r.why) || `Could not check ${name}`, 'error'); return; }
            const why = addCarModel(w, r.model);
            if (why) sayOnPage(why, 'warn');
            return;
        }
        // ---- a placed thing's tasks (panels.js tasksGroup) ----
        case 'task-add': commitField(); ed.taskPick = el.dataset.id; ed.taskOpen = null; return drawColumn();
        case 'task-pick-back': commitField(); ed.taskPick = null; ed.taskCopy = null; return drawColumn();
        // Copy existing (panels.js taskCopier): another thing of its kind, its tasks looked at, then copied onto this one.
        case 'task-copy': commitField(); ed.taskCopy = { id: el.dataset.id, from: null }; ed.taskOpen = null; return drawColumn();
        case 'task-copy-from': if (ed.taskCopy) ed.taskCopy.from = el.dataset.from || null; return drawColumn();
        case 'task-copy-back': ed.taskCopy = null; return drawColumn();
        case 'task-copy-do': return el.dataset.id === MANY ? copyTasksToMany(el.dataset.from) : copyTasks(el.dataset.id, el.dataset.from);
        // ---- several selected in the world builder (panels.js multiPage) ----
        // A kind's chip, or one of them on the Tasks tab: the builder's selection narrowed to those (furnisher.js).
        case 'multi-kind':
        case 'multi-one': {
            const ids = act === 'multi-one' ? [el.dataset.id] : multiThings(ed).filter((w) => w.kind === el.dataset.kind).map((w) => w.id);
            commitField();
            window.dispatchEvent(new CustomEvent('director-builder-select', { detail: { ids } }));
            return;
        }
        case 'multi-task-add': commitField(); ed.taskPick = MANY; ed.taskCopy = null; ed.taskOpen = null; return drawColumn();
        case 'multi-task-copy': commitField(); ed.taskCopy = { id: MANY, from: null }; ed.taskPick = null; ed.taskOpen = null; return drawColumn();
        case 'multi-task-clear': return clearTasksOfMany();
        // A step sharing another's point: a point of its own from now on, where the shared one is.
        case 'task-unshare': {
            const w = findWorld(ed.doc, el.dataset.id);
            const s = w && tasksOf(w).list.find((x) => x.k === el.dataset.k);
            if (!s || typeof s.share !== 'string') return;
            commitField();
            delete s.share;
            return ed.changed();
        }
        case 'task-jump': {
            const chips = el.closest('.dr-chips');
            const list = chips && chips.nextElementSibling;
            const head = list && list.querySelector(`.dr-cat[data-cat="${CSS.escape(el.dataset.cat)}"]`);
            if (head) list.parentNode.scrollTop = head.offsetTop - 8;
            return;
        }
        case 'task-pick': {
            const w = findWorld(ed.doc, el.dataset.id);
            const def = ed.tasks && ed.tasks.types.get(el.dataset.type);
            if (ed.taskPick === MANY && ed.multi) return taskForAll(def);
            if (!w || !def) return;
            if (!w.def.tasks || typeof w.def.tasks !== 'object') w.def.tasks = { list: [] };
            if (!Array.isArray(w.def.tasks.list)) w.def.tasks.list = [];
            const k = stepKey(w.def.tasks.list, w);
            w.def.tasks.list.push(newStep(k, def));
            ed.taskPick = null;
            ed.taskCopy = null;
            ed.taskOpen = w.id + '~' + k;
            ed.changed();
            // One that goes somewhere: its point at once, in front of the camera, when the world builder is open.
            if (building && def.fields.some((f) => f.kind === 'point')) placePoint(w, k);
            return;
        }
        case 'task-open': {
            const key = el.dataset.id + '~' + el.dataset.k;
            commitField();
            ed.taskOpen = ed.taskOpen === key ? null : key;
            return drawColumn();
        }
        case 'task-move': {
            const w = findWorld(ed.doc, el.dataset.id);
            const list = w ? tasksOf(w).list : [];
            const i = list.findIndex((s) => s.k === el.dataset.k), j = i + Number(el.dataset.by);
            if (i < 0 || j < 0 || j >= list.length) return;
            commitField();
            [list[i], list[j]] = [list[j], list[i]];
            return ed.changed();
        }
        case 'task-remove': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !w.def.tasks || !Array.isArray(w.def.tasks.list)) return;
            commitField();
            w.def.tasks.list = w.def.tasks.list.filter((s) => s.k !== el.dataset.k);
            if (!w.def.tasks.list.length) delete w.def.tasks;
            ed.taskOpen = null;
            return ed.changed();
        }
        // ---- A Wait for a card: Pick a card (the next card clicked on the grid is the step's: ed.select), its outcomes ----
        case 'task-card-pick': {
            commitField();
            ed.cardPickFor = { id: el.dataset.id, k: el.dataset.k };
            // In the world builder the grid is in the Blueprint window: up, if it is not.
            if (building) window.dispatchEvent(new CustomEvent('director-open-blueprint'));
            status('Click the card it waits for', 'warn');
            return drawColumn();
        }
        case 'task-card-cancel': ed.cardPickFor = null; status(''); return drawColumn();
        case 'task-out': {
            const w = findWorld(ed.doc, el.dataset.id);
            const s = w && tasksOf(w).list.find((x) => x.k === el.dataset.k);
            const pin = el.dataset.pin;
            if (!s || !pin) return;
            commitField();
            const outs = new Set(Array.isArray(s.outs) ? s.outs : []);
            if (outs.has(pin)) outs.delete(pin); else outs.add(pin);
            s.outs = [...outs];
            return ed.changed();
        }
        // ---- GTA Speech: its voice (panels.js voicePicker) and Preview ----
        case 'voice-open': {
            commitField();
            ed.voicePick = { id: el.dataset.id, k: el.dataset.k, query: '', group: 'a' };
            const w = findWorld(ed.doc, el.dataset.id);
            const cur = w && tasksOf(w).list.find((x) => x.k === el.dataset.k);
            const v = cur && cur.voice && ed.speech && ed.speech.byName.get(cur.voice);
            if (v) ed.voicePick.group = v.group;   // (opened on the group its voice is in)
            loadSpeech();
            return drawColumn();
        }
        case 'voice-back': ed.voicePick = null; return drawColumn();
        case 'voice-group':
            if (!ed.voicePick) return;
            ed.voicePick.group = el.dataset.group;
            ed.voicePick.query = '';
            return drawColumn();
        case 'voice-pick':
        case 'voice-clear': {
            const p = act === 'voice-pick' ? ed.voicePick : { id: el.dataset.id, k: el.dataset.k };
            const w = p && findWorld(ed.doc, p.id);
            const s = w && tasksOf(w).list.find((x) => x.k === p.k);
            if (!s) return;
            if (act === 'voice-pick' && el.dataset.voice) s.voice = el.dataset.voice.slice(0, 64);
            else delete s.voice;
            ed.voicePick = null;
            return ed.changed();
        }
        case 'voice-hear':
        case 'speech-hear': {
            const id = act === 'voice-hear' ? ed.voicePick && ed.voicePick.id : el.dataset.id;
            const k = act === 'voice-hear' ? ed.voicePick && ed.voicePick.k : el.dataset.k;
            const w = id && findWorld(ed.doc, id);
            const s = w && tasksOf(w).list.find((x) => x.k === k);
            if (!s) return;
            commitField();
            const voice = act === 'voice-hear' ? el.dataset.voice : (s.voice || '');
            // (The step's line, when this voice has it; else a hello, which nearly every voice has.)
            const v = voice && ed.speech && ed.speech.byName.get(voice);
            const has = (n) => !v || v.lines.some((i) => ed.speech.lines[i] === n);
            const line = s.line && has(s.line) ? s.line : (has('GENERIC_HI') ? 'GENERIC_HI' : (v && ed.speech.lines[v.lines[0]]) || 'GENERIC_HI');
            return nuiCallback('directorSpeechHear', { id: w.id, voice, line });
        }
        // Play Custom Voice Line's Play: its recording heard at the builder through the voice bot, as it sounds from the
        // NPC (server/director/lore_voice.lua loreVoiceTest, as the Lore form's Play).
        case 'lore-hear': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            const url = String(n.props.url || '').trim();
            if (!url) { sayOnPage('Paste the recording\'s link first', 'warn'); return; }
            const own = defaultLore(ed);
            const key = (typeof n.props.lore === 'string' && n.props.lore) || (own && own.key) || 'test';
            el.disabled = true;
            const r = await call('loreVoiceTest', { key, url });
            el.disabled = false;
            sayOnPage(r.ok ? 'Playing it at you, as it sounds from their NPC' : r.why, r.ok ? 'ok' : 'error');
            return;
        }
        // Play Emote's Choose from the emote menu: the players' emote menu opens over this screen, and each emote clicked
        // in it is this step's (directorEmotePicked); it stays open to try another.
        case 'task-emote-pick': {
            const w = findWorld(ed.doc, el.dataset.id);
            const s = w && tasksOf(w).list.find((x) => x.k === el.dataset.k);
            if (!s) return;
            commitField();
            ed.emoteFor = { id: w.id, k: s.k };
            return nuiCallback('directorPickEmote', { current: typeof s.emote === 'string' ? s.emote : null });
        }
        // A card's emote field (Progress): the same emote menu, its pick written into the card's field.
        case 'card-emote-pick': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            ed.emoteFor = { node: n.id, k: el.dataset.k };
            const cur = n.props[el.dataset.k];
            return nuiCallback('directorPickEmote', { current: typeof cur === 'string' && cur ? cur : null });
        }
        // An icon field (panels.js glyphField): every icon to pick from, or put away.
        case 'glyph-open': {
            const key = el.dataset.t + '|' + el.dataset.k;
            commitField();
            ed.glyphOpen = ed.glyphOpen === key ? null : key;
            return drawColumn();
        }
        // Skill Check's Play skill check: the ring at its difficulty, here (try.js), and how it went beside the button.
        case 'try-skill': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            const def = ed.cards.get(n.type);
            const f = def && (def.props || []).find((x) => x.key === 'difficulty');
            const difficulty = typeof n.props.difficulty === 'string' && n.props.difficulty ? n.props.difficulty : (f && f.default) || 'hard';
            // (The page may be up twice: the editor's column and the world builder's panel.)
            const out = (text) => document.querySelectorAll(`[data-try-out="${CSS.escape(n.id)}"]`).forEach((o) => { o.textContent = text; });
            out('');
            nuiCallback('directorSkillLevel', { difficulty }).then((r) => {
                if (!r || !r.ok) { out((r && r.why) || 'The ring could not be drawn'); return; }
                trySkillCheck(r.level, (passed) => out(passed === true ? 'Passed' : passed === false ? 'Missed' : 'Stopped'));
            });
            return;
        }
        // A card's look at its thing (Lock / Unlock Door's door): in the world builder, the camera to it; from the
        // editor, the builder opened with it selected.
        case 'look-world': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            if (ed.inBuilder) return nuiCallback('directorBuilderLook', { id: w.id });
            return openBuilder(w.id);
        }
        // Progress's Simulate: its bar, for its length (try.js).
        case 'try-progress': {
            const n = findNode(ed.doc, el.dataset.id);
            if (!n) return;
            commitField();
            const p = n.props;
            return tryProgress({ label: typeof p.label === 'string' && p.label ? p.label : 'Working...',
                seconds: typeof p.seconds === 'number' ? p.seconds : 8, canCancel: p.canCancel !== false });
        }
        case 'task-point': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            // In the world builder: select it, or Place marker (on the pointer, a click puts it down). Else open the
            // builder on it.
            if (building) return placePoint(w, el.dataset.k, el.dataset.carry === '1');
            return openBuilder(pointId(w.id, el.dataset.k));
        }
        // ---- a route's points (panels.js routeGroups) ----
        case 'place-open': {
            const key = el.dataset.id + '~' + el.dataset.k;
            commitField();
            ed.taskOpen = ed.taskOpen === key ? null : key;
            return drawColumn();
        }
        case 'place-add': {
            const w = findWorld(ed.doc, el.dataset.id);
            const list = el.dataset.list;
            if (!w || list !== 'points') return;
            commitField();
            if (!Array.isArray(w.def[list])) w.def[list] = [];
            const k = stepKey(w.def[list], w);
            w.def[list].push({ k });
            ed.taskOpen = w.id + '~' + k;
            ed.changed();
            // In the world builder, in hand at once: it rides the pointer until a left click puts it down. Else the
            // builder opens on it.
            if (building) return placePoint(w, k, true);
            return openBuilder(pointId(w.id, k));
        }
        case 'place-move': {
            const w = findWorld(ed.doc, el.dataset.id);
            const list = w && Array.isArray(w.def[el.dataset.list]) ? w.def[el.dataset.list] : [];
            const i = list.findIndex((s) => s && s.k === el.dataset.k), j = i + Number(el.dataset.by);
            if (i < 0 || j < 0 || j >= list.length) return;
            commitField();
            [list[i], list[j]] = [list[j], list[i]];
            return ed.changed();
        }
        case 'place-remove': {
            const w = findWorld(ed.doc, el.dataset.id);
            const name = el.dataset.list;
            if (!w || !Array.isArray(w.def[name])) return;
            commitField();
            w.def[name] = w.def[name].filter((s) => s && s.k !== el.dataset.k);
            ed.taskOpen = null;
            return ed.changed();
        }
        // ---- a car's riders and takes (panels.js ridersGroup, takesGroup) ----
        case 'rider-add': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            if (!Array.isArray(w.def.riders)) w.def.riders = [];
            const taken = new Set(w.def.riders.map((r) => r.seat));
            const seat = ['driver', 'front passenger', 'back left', 'back right'].find((s) => !taken.has(s)) || 'back right';
            const npc = ed.doc.world.find((x) => x.kind === 'npc' && !w.def.riders.some((r) => r.npc === x.id));
            w.def.riders.push({ npc: npc ? npc.id : '', seat });
            return ed.changed();
        }
        case 'rider-remove': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !Array.isArray(w.def.riders)) return;
            commitField();
            w.def.riders.splice(Number(el.dataset.i), 1);
            if (!w.def.riders.length) delete w.def.riders;
            return ed.changed();
        }
        // NPC rides in this vehicle? On: one, in the driver's seat (the first NPC placed, to change); off: every rider out.
        case 'riders-toggle': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || w.kind !== 'vehicle') return;
            commitField();
            if (Array.isArray(w.def.riders) && w.def.riders.length) {
                delete w.def.riders;
            } else {
                const npc = ed.doc.world.find((x) => x.kind === 'npc');
                w.def.riders = [{ npc: npc ? npc.id : '', seat: 'driver' }];
            }
            return ed.changed();
        }
        // Change model, the last row of a thing's General tab in the world builder (furnisher.js startRemodel, on the
        // selection: the page is the selection's).
        case 'thing-remodel':
            commitField();
            window.dispatchEvent(new CustomEvent('director-remodel'));
            return;
        case 'take-open': {
            const key = el.dataset.id + '#' + el.dataset.take;
            commitField();
            ed.takeOpen = ed.takeOpen === key ? null : key;
            // In the world builder, the open take's line is drawn where it goes while its car is selected
            // (client/director_preview.lua).
            if (building) nuiCallback('directorPreviewPath', { take: ed.takeOpen ? Number(el.dataset.take) : null, car: el.dataset.id });
            return drawColumn();
        }
        // ---- the world builder's preview (panels.js previewBlock; client/director_preview.lua) ----
        case 'preview-play': return previewPlay(el.dataset.id);
        case 'preview-stop':
            nuiCallback('directorPreviewStop', {});
            return;
        case 'preview-with': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            if (!w.def.tasks || typeof w.def.tasks !== 'object') w.def.tasks = { list: [] };
            const set = new Set(Array.isArray(w.def.tasks.playWith) ? w.def.tasks.playWith : []);
            if (set.has(el.dataset.with)) set.delete(el.dataset.with); else set.add(el.dataset.with);
            if (set.size) w.def.tasks.playWith = [...set]; else delete w.def.tasks.playWith;
            return ed.changed();
        }
        case 'take-preview': {
            const w = findWorld(ed.doc, el.dataset.id);
            const take = w ? takesOf(w).find((t) => String(t.id) === el.dataset.take) : null;
            if (!w || !take || !building) return;
            commitField();
            // The car drives the take on its copy, and the trailers it hitched their own tracks beside it (`tow`, as a
            // task's take gets it: previewPlay); each rider's copy sits in its seat first.
            const runs = [{ id: w.id, kind: 'vehicle', label: w.label || w.id, plan: { after: 'stop', steps: [
                { k: 'take', t: 'take', timing: 'until', giveUpMs: (Number(take.ms) || 60000) + 20000,
                  p: { take: Number(take.id), tow: towToWatch(w, take.id) } },
            ] } }];
            for (const r of Array.isArray(w.def.riders) ? w.def.riders : []) {
                const n = r && findWorld(ed.doc, r.npc);
                if (n) runs.push({ id: n.id, kind: 'npc', label: n.label || n.id, plan: { after: 'stop', steps: [
                    { k: 'seat', t: 'warpIn', timing: 'instant', p: { car: w.id, seatN: SEAT_N[r.seat] ?? -1 } },
                ] } });
            }
            ed.takeOpen = w.id + '#' + take.id;
            nuiCallback('directorPreviewPath', { take: Number(take.id), car: w.id });
            nuiCallback('directorPreviewPlay', { runs });
            return drawColumn();
        }
        case 'take-record': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w) return;
            commitField();
            // In the world builder: its Done first (the car where it stands now; its Save stays open, so not that), then
            // the drive (directorShow), then the builder again where it was (directorShow's `reopen`).
            if (building) {
                ed.recordAfter = w.id;
                nuiCallback('directorBuilderDone', { record: true });
                return;
            }
            recordTake(w);
            return;
        }
        case 'take-watch': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !w.def.model) return;
            commitField();
            return nuiCallback('directorTakeWatch', { id: Number(el.dataset.take), car: w.id, model: w.def.model, ext: extOf(w),
                                                      tow: towToWatch(w, el.dataset.take) });
        }
        case 'take-remove': {
            const w = findWorld(ed.doc, el.dataset.id);
            if (!w || !Array.isArray(w.def.takes)) return;
            commitField();
            w.def.takes = w.def.takes.filter((t) => String(t.id) !== el.dataset.take);
            if (!w.def.takes.length) delete w.def.takes;
            // (What played it has none picked now, until the car's next recording fills it: directorTakeSaved.)
            for (const r of takeRefsOf(w)) if (String(r.at[r.key]) === el.dataset.take) delete r.at[r.key];
            ed.takeOpen = null;
            // (No take open now: no line in the world builder either.)
            if (building) nuiCallback('directorPreviewPath', { take: null });
            return ed.changed();
        }
        case 'add-var': {
            const id = freeId(new Set(ed.doc.vars.map((v) => v.id)), 'var');
            ed.doc.vars.push({ id, type: 'number', default: 0 });
            return ed.changed();
        }
        case 'remove-var': {
            const id = el.dataset.id;
            // (Every variant's cards: the variables are the scenario's.)
            const uses = usesOfVar(ed.doc, ed.cards, id).length + otherUses('var', id);
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
            return openScenario(ed.key, rev);
        }
        default: return;
    }
}

// (A new thing's id and name, by kind: its base and label, things-data.js.)

/** What names a placed thing, as the world builder warns before removing it: each card (by title), the
 *  start and Where it happens. Empty when nothing does. */
/** The cards (and settings) that name a placed thing, by title. `all` (optional): usesOfWorlds, worked out once. */
function usedBy(id, all) {
    const out = [];
    for (const u of (all ? all.get(id) || [] : usesOfWorld(ed.doc, ed.cards, id))) {
        const def = ed.cards.get(u.node.type);
        const t = (def && def.title) || u.node.type;
        if (!out.includes(t)) out.push(t);
    }
    if (ed.doc.settings.start && ed.doc.settings.start.world === id) out.push('the start');
    if (ed.doc.settings.where === id) out.push('Where it happens');
    return out;
}

const textOf = (v) => (typeof v === 'string' && v.trim() !== '' ? v : '');
const numOf = (v, d) => (v !== '' && v != null && Number.isFinite(Number(v)) ? Number(v) : d);

/** An Interaction Menu's top choices, as its prompt lists them: a choice with choices under it ends ' ›'
 *  (client/runtime_points.lua mount). */
function menuTop(n) {
    const out = [];
    for (let i = 1; i <= 8; i++) {
        const t = textOf(n.props['item' + i]);
        if (!t) continue;
        const under = n.props['item' + i + 'Under'];
        if (under != null && under !== 'top') continue;
        out.push(t + (opensMenu(n, i) ? '  ›' : ''));
    }
    return out;
}

/** THE 3D PROMPT A RUN PUTS ON THIS THING, as players will see it: the world builder shows it instead of a
 *  marker. Where and how the server puts it (server/director): `ride` 'entity' is on the NPC
 *  or car itself, `lift` above its middle; 'coords' is at the thing's spot, `lift` above it. A press and a
 *  menu have no glyph (the key letter); a Talk has the talk glyph. The start comes first (it is up all the
 *  while the scenario is on), then the first card that puts one there, then a container's own Open.
 *  null when nothing does. */
function promptOf(w) {
    const st = ed.doc.settings.start;
    if (st && st.world === w.id && (st.mode === 'press' || st.mode === 'interaction')) {
        const talk = st.mode === 'interaction';
        // A standing NPC or car carries it (main.lua: its netId, 0.3 up); anything else, at its spot.
        const rides = (w.kind === 'npc' || w.kind === 'vehicle') && w.layer === 'standing';
        return { label: textOf(st.label) || (talk ? 'Talk' : 'Use'), icon: textOf(st.icon) || (talk ? 'talk' : null),
                 reach: talk ? 2.5 : 2, ride: rides ? 'entity' : 'coords', lift: rides ? 0.3 : 0 };
    }
    for (const n of ed.doc.nodes) {
        const p = n.props || {};
        const def = ed.cards.get(n.type);
        // A card that puts a prompt on the thing its `at` names (its def.prompt: server/director/nodes_heist.lua): riding
        // the kinds it rides, its `lift` above by kind, else at the thing's spot; a menu's top choices with it.
        const pr = def && def.prompt;
        if (pr && p[pr.at] === w.id) {
            const out = { label: textOf(p.label) || 'Use', icon: null, reach: numOf(p.reach, 2),
                          ride: pr.rides && pr.rides[w.kind] ? 'entity' : 'coords', lift: (pr.lift && pr.lift[w.kind]) || 0 };
            if (pr.menu) out.options = menuTop(n);
            return out;
        }
        // (A card that talks, its conversation's Talk prompt on its NPC: its def.talks, server/director/talk.lua.)
        if (def && def.talks && p.npc === w.id) {
            return { label: textOf(p.talk) || 'Talk', icon: 'talk', reach: 2.5, ride: 'entity', lift: 0.3 };
        }
    }
    // A container is a prompt of its own in the world: Open, by its name (nodes_heist.lua Containers.create).
    if (w.kind === 'container') return { label: textOf(w.label) || 'Container', icon: null, reach: null, ride: 'coords', lift: 0 };
    return null;
}

/** THE WORLD BUILDER: the furnisher, anywhere, on this scenario's things (the kinds it places: their builder,
 *  things-data.js; client/director.lua). `focusId`: open with that one selected (or put down, not placed yet). */
let builderSent = null;   // the ids handed to the builder, so Done can tell what was removed

/** What the builder makes a thing from: its model (a prop's, a ped's, a car's; a door's number), a
 *  container's prop. */
function builderModel(w) {
    const d = w.def || {};
    if (w.kind === 'container') return d.prop || '';
    if (w.kind === 'spot' || w.kind === 'groundItem' || w.kind === 'route') return '';
    return d.model == null ? '' : d.model;
}

/** What else the builder draws for a thing: a guard's cone (its Sees players: client/vision.lua's VisionCone, redrawn
 *  as a field changes), whether a route goes round. */
function builderExtras(w) {
    const d = w.def || {};
    // An NPC: its Eye sight's cone; the lore character it is and its weapon, which its copy wears and holds
    // (client/furnish_builder.lua dressNpc).
    if (w.kind === 'npc') {
        const out = {};
        if (d.vision && d.vision.on) {
            const v = d.vision;
            out.vision = { range: Number(v.range) || 20, cone: Number(v.cone) || 100, spotS: Number(v.spotS) || 2,
                           farS: Number(v.farS) || 8, sneak: v.sneak !== false };
        }
        if (typeof d.lore === 'string' && d.lore) out.lore = d.lore;
        if (typeof d.weapon === 'string' && d.weapon) out.weapon = d.weapon;
        // (Its look from the character editor, else its Outfit: a lore character wears their own look.)
        if (!out.lore && lookOf(w)) out.look = d.look;
        else if (!out.lore && d.outfit && typeof d.outfit === 'object' && Object.keys(d.outfit).length) out.outfit = d.outfit;
        return out;
    }
    if (w.kind === 'route') return { loops: (d.order || 'loop') === 'loop' };
    // A Fixed Weapon: the gun it is (its aim line in the builder: client/furnish_builder.lua drawAim).
    if (w.kind === 'prop' && typeof d.weapon === 'string' && d.weapon) return { weapon: d.weapon };
    // A random vehicle: the models its copy goes through (client/furnish_builder.lua).
    if (w.kind === 'vehicle' && d.random) return { random: true, models: carModels(w).map((m) => m.model) };
    // A spot's marker, drawn where it stands (client/director_spots.lua): its look and size, and the symbol in its
    // middle (a garage bay's own unless another is picked; a circle's or a square's only when it has one).
    const m = d.marker;
    if (w.kind === 'spot' && m && (m.look === 'circle' || m.look === 'square' || m.look === 'garage')) {
        const mw = Number(m.w) || 4;
        return { zone: { look: m.look, w: mw, l: m.look === 'square' ? Number(m.l) || mw : mw,
                         icon: typeof m.icon === 'string' && m.icon ? m.icon : undefined } };
    }
    return {};
}

/** What a thing's mark in the world builder says (client/world_marks.lua): the line under its name (what
 *  it is, and the card that uses it), and an item spot's item, by name and picture. */
const MARK_KIND = { spot: 'Spot', groundItem: 'Item spot', container: 'Container', door: 'Door', npc: 'NPC',
    vehicle: 'Car', prop: 'Prop', route: 'Route' };
function markOf(w, uses) {
    const d = w.def || {};
    const used = uses.length ? ' · used by ' + (uses.length === 1 ? uses[0] : uses.length + ' cards') : '';
    if (w.kind === 'route') {
        const n = Array.isArray(d.points) ? d.points.length : 0;
        return { detail: `Route · ${plural(n, 'point')}${used}` };
    }
    if (w.kind === 'container') {
        return { detail: (Number(d.slots) || 10) + ' slots · ' + (Number(d.maxWeight) || 100) + ' kg' + used };
    }
    if (w.kind === 'groundItem' && d.item) {
        const def = (getItemDefs() || {})[d.item];
        return { name: ((def && def.name) || d.item) + ' ×' + (Number(d.amount) || 1), detail: 'Item spot' + used,
                 pic: itemImageUrl(d.item) };
    }
    if (w.kind === 'prop' && d.weapon) return { detail: 'Fixed Weapon' + (d.attach && d.attach.to ? ' · attached' : '') + used };
    return { detail: (MARK_KIND[w.kind] || 'Thing') + used };
}

// ---- recording a take (client/director_takes.lua) ----

const SEAT_N = { 'driver': -1, 'front passenger': 0, 'back left': 1, 'back right': 2 };
const OTHER_CARS_MAX = 8;

/** A car's riders as the game seats them: { model, seat }. */
function ridersOf(w) {
    return (Array.isArray(w.def.riders) ? w.def.riders : []).map((r) => {
        const n = r && findWorld(ed.doc, r.npc);
        return n && n.def && n.def.model ? { model: n.def.model, seat: SEAT_N[r.seat] ?? -1 } : null;
    }).filter(Boolean);
}

/** The scenario's other cars that have takes, each with the one it plays (its tasks' Play a Take, else a Play Take
 *  card's, else its newest), to drive beside a take being recorded: { car, label, model, take, riders }. */
function otherTakes(w) {
    const out = [];
    for (const x of ed.doc.world) {
        if (x.id === w.id || x.kind !== 'vehicle' || !x.def || !x.def.model) continue;
        const takes = (Array.isArray(x.def.takes) ? x.def.takes : []).filter((t) => t && Number(t.id) > 0);
        if (!takes.length) continue;
        const has = (id) => takes.some((t) => Number(t.id) === Number(id));
        const list = x.def.tasks && Array.isArray(x.def.tasks.list) ? x.def.tasks.list : [];
        // (A take is named by a field of kind 'take': a task's, or a card's that names this car in its `of` field.)
        const stepTake = (s) => {
            const d = s && ed.tasks && ed.tasks.types.get(s.t);
            const f = d && d.fields.find((y) => y.kind === 'take');
            return f ? s[f.key] : undefined;
        };
        const cardTake = (n) => {
            const d = ed.cards.get(n.type);
            const f = d && d.props.find((y) => y.kind === 'take' && y.of);
            return f && n.props && n.props[f.of] === x.id ? n.props[f.key] : undefined;
        };
        const task = list.map(stepTake).find(has);
        const card = ed.doc.nodes.map(cardTake).find(has);
        const newest = takes.reduce((a, b) => ((Number(b.made) || 0) > (Number(a.made) || 0) ? b : a));
        const take = Number(task !== undefined ? task : card !== undefined ? card : newest.id);
        // (Its trailers on their own tracks beside it, as a Watch drives them: towToWatch. Not the car being recorded,
        // nor its own trailer: that one is on its hitch.)
        const tow = towToWatch(x, take);
        if (tow) tow.tracks = tow.tracks.filter((tr) => tr.w !== w.id && tr.w !== w.def.tow);
        out.push({ car: x.id, label: x.label || x.id, model: x.def.model, take, riders: ridersOf(x), ext: extOf(x),
                   tow: tow && tow.tracks.length ? tow : undefined });
    }
    return out.slice(0, OTHER_CARS_MAX);
}

/** What plays one of a car's takes: its own Play a Scripted Driving Event tasks, and each card's take field whose car
 *  is this one (Play Scripted Driving Event's). Each { at, key }: at[key] is the take's id. */
function takeRefsOf(w) {
    const out = tasksOf(w).list.filter((s) => s && s.t === 'take').map((s) => ({ at: s, key: 'take' }));
    for (const n of ed.doc.nodes) {
        const def = ed.cards.get(n.type);
        for (const f of def ? def.props : []) {
            if (f.kind === 'take' && f.of && n.props && n.props[f.of] === w.id) out.push({ at: n.props, key: f.key });
        }
    }
    return out;
}

/** The scenario's other placed cars with no take of their own, parked where they are placed beside a recording
 *  (client/director_takes.lua makeParked): a trailer to back into among them, the car's own trailer (its Tows) first.
 *  A Vehicle pool has no one model: left out. */
const PARKED_MAX = 8;
function parkedFor(w, others) {
    // (An other car's trailer drives its own track beside it: not parked too.)
    const taken = new Set(others.map((o) => o.car));
    for (const o of others) for (const tr of (o.tow && o.tow.tracks) || []) taken.add(tr.w);
    const list = ed.doc.world.filter((x) => x.id !== w.id && x.kind === 'vehicle' && x.def && x.def.model && !x.def.random
        && x.def.coords && typeof x.def.coords.x === 'number' && !taken.has(x.id));
    list.sort((a, b) => Number(b.id === w.def.tow) - Number(a.id === w.def.tow));
    return list.slice(0, PARKED_MAX).map((x) => ({ car: x.id, model: x.def.model, label: x.label || x.id, coords: x.def.coords,
                                                   ext: extOf(x) }));
}

/** What other resources keep on a placed thing (its `ext`: a car's Whiplash look), for a copy of it made by this game
 *  (a recording's, a watch's) to be dressed as a run makes it; undefined when none. */
function extOf(w) {
    const ext = w && w.def && w.def.ext;
    return ext && typeof ext === 'object' && Object.keys(ext).length ? ext : undefined;
}

/** A take's trailers as a watch drives them beside it (client/director_takes.lua directorTakeWatch, the world builder's
 *  Play here): { tracks: [{ w, id, model, ext }], events }, or undefined. */
function towToWatch(w, takeId) {
    const t = (Array.isArray(w.def.takes) ? w.def.takes : []).find((x) => x && Number(x.id) === Number(takeId));
    const tow = t && t.tow && typeof t.tow === 'object' ? t.tow : null;
    if (!tow || !tow.tracks) return undefined;
    const tracks = Object.entries(tow.tracks).map(([wid, id]) => {
        const x = findWorld(ed.doc, wid);
        return x && x.def && x.def.model ? { w: wid, id: Number(id), model: x.def.model, ext: extOf(x) } : null;
    }).filter(Boolean);
    return tracks.length ? { tracks, events: Array.isArray(tow.events) ? tow.events : [] } : undefined;
}

/** Record a take in a car, from where it is placed, its riders in their seats, the scenario's other cars driving their
 *  takes beside it (otherTakes), the rest parked where they are placed (parkedFor: a trailer to hook among them; its own
 *  trailer, its Tows, hitched before the count). `builder`: pressed in the world builder, which opens again on the car
 *  once the take is over. Answers whether it was asked for. */
function recordTake(w, builder) {
    if (!ed.key || !w.def.model || !w.def.coords) return false;
    const others = otherTakes(w);
    nuiCallback('directorTakeRecord', { key: ed.key, car: w.id, model: w.def.model, label: w.label || w.id,
                                         coords: w.def.coords, riders: ridersOf(w), ext: extOf(w), others,
                                         parked: parkedFor(w, others), tow: typeof w.def.tow === 'string' ? w.def.tow : undefined,
                                         builder: builder === true });
    return true;
}

/** What is on screen while a take is recorded: the capsule, the count, the keys (the page is out of the way). */
function recHud(d) {
    let el = document.getElementById('dr-rec');
    if (d.off) { if (el) el.remove(); return; }
    if (!el) {
        el = document.createElement('div');
        el.id = 'dr-rec';
        el.className = 'dr-rec';
        el.innerHTML = '<div class="dr-rec-top"><div class="dr-rec-cap"><span class="dr-rec-dot"></span><b class="dr-rec-tag"></b>'
            + '<span class="dr-rec-bar"></span><span class="dr-rec-name"></span><span class="dr-rec-bar"></span>'
            + '<span class="dr-rec-time"></span><span class="dr-rec-of"></span></div><div class="dr-rec-sub"></div></div>'
            + '<div class="dr-rec-count"></div>'
            + '<div class="dr-rec-keys"><span><kbd>F10</kbd>Save</span><span><kbd>F11</kbd>Start again</span><span><kbd>F4</kbd>Throw away</span></div>';
        document.body.appendChild(el);
    }
    el.className = 'dr-rec ' + (d.phase || '');
    const q = (s) => el.querySelector(s);
    q('.dr-rec-tag').textContent = d.phase === 'held' ? 'HELD' : d.phase === 'saving' ? 'SAVING' : d.phase === 'count' ? 'READY' : 'REC';
    q('.dr-rec-name').textContent = d.label || 'Driving event';
    q('.dr-rec-time').textContent = clock((d.ms || 0) / 1000, true);
    q('.dr-rec-of').textContent = 'of ' + clock(Math.round((d.max || 0) / 1000));
    q('.dr-rec-sub').textContent = d.phase === 'held' ? `Stopped: ${d.why || 'held'}. Save it, or start again`
        : d.phase === 'saving' ? `Sending it to the server${d.why ? ` (${d.why})` : ''}` : d.phase === 'count' ? 'The car is held on its spot' : 'Drive';
    q('.dr-rec-count').textContent = d.phase === 'count' && d.count ? String(d.count) : '';
}

// ---- points: placed and moved in the world builder like a spot ----
//
// Two kinds of list have points, each a builder thing: kind 'point', id '<worldId>~<key>', numbered as its page
// numbers them, shown while its thing (or one of its points) is selected (client/furnish_builder.lua):
//   tasks   a step of a thing's Tasks that goes somewhere (Go To, Slide To, a target that is a point): joined to
//           its thing by a line
//   points  a route's points, joined in order
// Done writes each one's spot back; one removed there leaves its step or point with no place.

const pointId = (worldId, k) => worldId + '~' + k;

/** A thing's lists of points: { list, items }. */
function pointLists(w) {
    const out = [];
    if (thingIs(w.kind, 'tasks')) out.push({ list: 'tasks', items: tasksOf(w).list });
    if (w.kind === 'route' && Array.isArray(w.def.points)) out.push({ list: 'points', items: w.def.points });
    return out;
}

/** '<worldId>~<k>' -> { w, s, list } (the thing, its step or point, and which list), or null. */
function pointOf(id) {
    const i = typeof id === 'string' ? id.lastIndexOf('~') : -1;
    if (i < 1 || !ed.doc) return null;
    const w = findWorld(ed.doc, id.slice(0, i));
    if (!w) return null;
    for (const l of pointLists(w)) {
        const s = l.items.find((x) => x && x.k === id.slice(i + 1));
        if (s) return { w, s, list: l.list };
    }
    return null;
}

/** A new key for a step or a point: short, and not one of its thing's. */
function stepKey(list, w) {
    const used = new Set(list.map((s) => s.k));
    if (w) for (const l of pointLists(w)) for (const s of l.items) used.add(s && s.k);
    for (;;) {
        const k = Math.random().toString(36).slice(2, 7);
        if (!used.has(k)) return k;
    }
}

/** A new step of type `def` with key `k`: one that can go on until stopped (Shoot At, Wander) starts at its `startSec`,
 *  0, no end (shared/director/steps.lua THE TIMING); a step with no time of its own plays its type's. */
function newStep(k, def) {
    const s = { k, t: def.t };
    if (typeof def.startSec === 'number') s.sec = def.startSec;
    return s;
}

/** Copy existing: `fromId`'s tasks become `id`'s, their points where `fromId`'s are, asked first when `id` has tasks of
 *  its own (they are replaced). Each step gets a key of its own, so none is taken for one of the old steps' points. */
async function copyTasks(id, fromId) {
    const w = findWorld(ed.doc, id), x = findWorld(ed.doc, fromId);
    if (!w || !x || w === x || w.kind !== x.kind) return;
    const from = tasksOf(x).list, had = tasksOf(w).list;
    if (!from.length) return;
    const name = w.label || w.id, other = x.label || x.id;
    if (had.length) {
        const go = await ask(`Replace ${name}'s tasks?`, `${name} has ${plural(had.length, 'task')}. `
            + `${had.length === 1 ? 'It is' : 'They are'} replaced by ${other}'s ${from.length}.`, [
            { label: 'Replace them', value: true, tone: 'danger' }, { label: 'Cancel', value: null }]);
        if (!go || findWorld(ed.doc, id) !== w || findWorld(ed.doc, fromId) !== x) return;
    }
    commitField();
    const tasks = JSON.parse(JSON.stringify(x.def.tasks));
    const list = [];
    for (const s of tasks.list) {
        s.k = stepKey(list, w);
        list.push(s);
    }
    tasks.list = list;
    if (Array.isArray(tasks.playWith)) tasks.playWith = tasks.playWith.filter((p) => p !== w.id);
    w.def.tasks = tasks;
    ed.taskCopy = null;
    ed.taskOpen = null;
    ed.thingTab = 'tasks';
    ed.changed();
    sayOnPage(`${plural(from.length, 'task')} copied from ${other}`, 'ok');
}

/** A task picked for several (the multi page's + Task for all): on the end of each one's list. One that goes somewhere
 *  gets ONE point, the primary's, put in front of the camera as one's is; the others' steps share it (syncShared). */
function taskForAll(def) {
    const things = def ? multiThings(ed).filter((w) => def.kinds.includes(w.kind)) : [];
    if (!things.length) return;
    commitField();
    const prim = things[things.length - 1];
    const placed = def.fields.some((f) => f.kind === 'point');
    const pointed = placed || def.fields.some((f) => f.kind === 'target');
    let primK = null, n = 0;
    for (const w of [prim].concat(things.filter((x) => x !== prim))) {
        if (!w.def.tasks || typeof w.def.tasks !== 'object') w.def.tasks = { list: [] };
        if (!Array.isArray(w.def.tasks.list)) w.def.tasks.list = [];
        if (w.def.tasks.list.length >= (ed.tasks.max || 40)) continue;
        const s = newStep(stepKey(w.def.tasks.list, w), def);
        if (w === prim) primK = s.k;
        else if (pointed && primK) s.share = pointId(prim.id, primK);
        w.def.tasks.list.push(s);
        n++;
    }
    ed.taskPick = null;
    ed.taskCopy = null;
    ed.thingTab = 'tasks';
    ed.changed();
    if (building && placed && primK) placePoint(prim, primK);
    sayOnPage(`${def.label}: added to ${n === things.length ? `all ${n}` : `${n} of ${things.length}`}`, 'ok');
}

/** Copy tasks onto several: `fromId`'s tasks become each selected one's (but its own), asked first when any has tasks of
 *  its own. A step that goes somewhere shares `fromId`'s point (syncShared): no new points. */
async function copyTasksToMany(fromId) {
    const x = findWorld(ed.doc, fromId);
    const onto = x ? multiThings(ed).filter((w) => w !== x && w.kind === x.kind) : [];
    const from = x ? tasksOf(x).list : [];
    if (!onto.length || !from.length) return;
    const had = onto.filter((w) => tasksOf(w).list.length);
    if (had.length) {
        const who = had.length === 1 ? `${had[0].label || had[0].id} has tasks` : `${had.length} of them have tasks`;
        const go = await ask('Replace their tasks?', `${who}. They are replaced by ${x.label || x.id}'s ${from.length}.`, [
            { label: 'Replace them', value: true, tone: 'danger' }, { label: 'Cancel', value: null }]);
        if (!go || findWorld(ed.doc, fromId) !== x) return;
    }
    commitField();
    for (const w of onto) {
        const tasks = JSON.parse(JSON.stringify(x.def.tasks));
        const list = [];
        tasks.list.forEach((s, i) => {
            const o = from[i];
            s.k = stepKey(list, w);
            const def = ed.tasks && ed.tasks.types.get(o.t);
            if (def && taskPoints(def, o).length) s.share = typeof o.share === 'string' ? o.share : pointId(x.id, o.k);
            list.push(s);
        });
        tasks.list = list;
        if (Array.isArray(tasks.playWith)) tasks.playWith = tasks.playWith.filter((p) => p !== w.id);
        w.def.tasks = tasks;
    }
    ed.taskCopy = null;
    ed.taskOpen = null;
    ed.thingTab = 'tasks';
    ed.changed();
    sayOnPage(`${plural(from.length, 'task')} copied from ${x.label || x.id} onto ${onto.length}`, 'ok');
}

/** Clear their tasks (the multi page's Tasks tab), asked first. */
async function clearTasksOfMany() {
    const things = multiThings(ed).filter((w) => tasksOf(w).list.length);
    if (!things.length) return;
    const n = things.reduce((sum, w) => sum + tasksOf(w).list.length, 0);
    const go = await ask(`Clear the tasks of ${things.length}?`, `${plural(n, 'task')} between them go.`, [
        { label: 'Clear them', value: true, tone: 'danger' }, { label: 'Cancel', value: null }]);
    if (!go) return;
    commitField();
    for (const w of things) if (findWorld(ed.doc, w.id) === w) delete w.def.tasks;
    ed.taskOpen = null;
    ed.changed();
}

/** What the builder is handed for one point: what it shows, and where (null: not placed). A route's say whether it
 *  goes round (the line back to point 1). */
function pointThing(w, s, n, list, name) {
    return { id: pointId(w.id, s.k), kind: 'point', model: '', label: `${w.label || w.id} · ${n}`,
             coords: s.at && typeof s.at.x === 'number' ? s.at : null, of: w.id, n, glyph: String(n), list, uses: [],
             prompt: null, mark: { name, detail: w.label || w.id },
             loops: list === 'points' ? (w.def.order || 'loop') === 'loop' : undefined };
}

/** A route just put down in the world builder (client/furnish_builder.lua): the route made, its marker its point 1. */
function routePlaced(index, c) {
    if (!building || !ed.doc || !c || typeof c.x !== 'number') return;
    const id = freeId(worldIds(ed.doc), thingIs('route', 'base'));
    const w = newWorldThing('route', { label: 'Route' }, id);
    const k = stepKey([], w);
    w.def.points = [{ k, at: { x: +c.x.toFixed(3), y: +c.y.toFixed(3), z: +c.z.toFixed(3), heading: +(c.heading || 0).toFixed(1) } }];
    ed.doc.world.push(w);
    builderAdopted.add(id);   // (an Exit without a Save takes it out again, as every thing put down since)
    if (builderSent) builderSent.add(pointId(id, k));
    ed.changed();
    const t = pointThings(false).find((x) => x.id === pointId(id, k));
    if (t) nuiCallback('directorBuilderConvert', { index, thing: t });
}

/** A route's point removed in the world builder: gone from its list at once, the rest numbered again as they
 *  stand. A task's point: its step stays, not placed. */
function pointRemoved(id) {
    const p = ed.doc && pointOf(id);
    if (!p) return;
    if (p.list === 'tasks') delete p.s.at;
    else {
        const i = p.w.def.points.indexOf(p.s);
        if (i >= 0) p.w.def.points.splice(i, 1);
    }
    if (ed.taskOpen === id) ed.taskOpen = null;
    if (builderSent) builderSent.delete(id);
    ed.changed();
}

/** Steps that share another's point (several given one task at once: builder.taskForAll) go where it is: its `at` is
 *  copied into each, so a run, which reads each step's own, sends them all there. Its point not placed: nor are theirs.
 *  One whose point has gone keeps where it was, a point of its own from then on. */
function syncShared() {
    if (!ed.doc) return;
    for (const w of ed.doc.world) {
        if (!thingIs(w.kind, 'tasks')) continue;
        for (const s of tasksOf(w).list) {
            if (!s || typeof s.share !== 'string') continue;
            const src = sharedOf(ed, s);
            if (!src || src.s === s || typeof src.s.share === 'string') { delete s.share; continue; }
            const at = src.s.at && typeof src.s.at.x === 'number' ? src.s.at : null;
            if (!at) delete s.at;
            else if (JSON.stringify(s.at) !== JSON.stringify(at)) s.at = { ...at };
        }
    }
}

/** Every point of every thing, placed or not (`placed`: only those placed). A step that shares another's has none of
 *  its own (syncShared). */
function pointThings(placed) {
    const out = [];
    if (!ed.doc) return out;
    for (const w of ed.doc.world) {
        for (const l of pointLists(w)) {
            if (l.list === 'tasks') {
                if (!ed.tasks) continue;
                const numbers = pointNumbers(ed, l.items);
                for (const s of l.items) {
                    const def = ed.tasks.types.get(s.t);
                    if (!def || !numbers[s.k] || !taskPoints(def, s).length || sharedOf(ed, s)) continue;
                    const t = pointThing(w, s, numbers[s.k], 'tasks', `${numbers[s.k]} · ${def.label}`);
                    if (!placed || t.coords) out.push(t);
                }
            } else {
                l.items.forEach((s, i) => {
                    if (!s || !s.k) return;
                    const t = pointThing(w, s, i + 1, l.list, `Point ${i + 1}`);
                    if (!placed || t.coords) out.push(t);
                });
            }
        }
    }
    return out;
}

/** In the world builder: a point selected there, or put in front of the camera (client/director.lua). `carry` (Place
 *  marker): then it rides the pointer until a left click puts it down. */
function placePoint(w, k, carry) {
    const t = pointThings(false).find((x) => x.id === pointId(w.id, k));
    if (t) nuiCallback('directorBuilderPoint', { thing: t, carry: carry === true });
}

/** A prop's Turn To heading as its slider moves, in the world builder: a see-through copy of the prop where it stands,
 *  turned that way (client/director.lua directorTurnGhost). `done`: the slider let go, and the copy goes soon after. */
function turnGhost(el, done) {
    if (!building || el.dataset.k !== 'heading' || !/^step:/.test(el.dataset.t || '')) return;
    const rest = el.dataset.t.slice(5), cut = rest.lastIndexOf(':');
    const w = findWorld(ed.doc, rest.slice(0, cut));
    const s = w && tasksOf(w).list.find((x) => x.k === rest.slice(cut + 1));
    if (!s || s.t !== 'turnTo') return;
    nuiCallback('directorTurnGhost', { id: w.id, heading: Number(el.value) || 0, done });
}

/** `back`: opened again after a take recorded in it (client/director.lua keeps its camera, and its Configure opens). */
/** A 'worlds' field's list written (panels.js worldsOf). */
function setWorlds(n, k, list) {
    if (list.length) n.props[k] = list; else delete n.props[k];
}

/** The item picker over the page, for field `k` of `t` (an item field's press; Create Container's new slot item).
 *  Its way back names the page it opened over: its title's own words (not a card's id beside them), else the tab. */
function openItemPicker(t, k, label, required, el) {
    // A field in the column while a card's page is on the right (a placed thing's): the picker over the column's page,
    // the card's page let go of (the card stays picked).
    if (sideOn() && el && colEl.contains(el)) ed.tab = ed.homeTab;
    const page = pageBody();
    const head = page.querySelector('.dr-title2, .dr-page-head .dr-item-main b');
    const words = head ? [...head.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').trim() : '';
    const tab = TABS.find((x) => x.id === ed.homeTab);
    // (`only`: a field for the scenario's own items: the list is those it places or gives, panels.js scenarioItems.)
    ed.picker = { t, k, label: label || 'Item', required: !!required, only: !!(el && el.dataset && el.dataset.only === '1'),
        from: words || (tab ? tab.label : 'Back'), query: '', kind: 'all', scroll: page.scrollTop };
    drawColumn();
    // The item it has now in the middle of the list (the list is the rows' offset parent).
    const list = pageBody().querySelector('.dr-pick-list'), on = list && list.querySelector('.dr-pick-row.on');
    if (on) list.scrollTop = Math.max(0, on.offsetTop - (list.clientHeight - on.offsetHeight) / 2);
    const box = pageBody().querySelector('.dr-pick-search');
    if (box) box.focus();
}

/** In the world builder already, one of the scenario's things to show or place (a car's key spot): selected where it is,
 *  or put in hand in front of the camera to put down (client/director.lua directorBuilderPut). It is the scenario's
 *  already: an Exit without a Save leaves it unplaced, not gone. Answers whether the builder can take it. */
function putInBuilder(w) {
    if (!building || !w || !thingIs(w.kind, 'builder') || w.kind === 'route') return false;
    commitField();
    nuiCallback('directorBuilderPut', { thing: { ...builderThing(w), coords: (w.def && w.def.coords) || null, rot: (w.def && w.def.rot) || null } });
    return true;
}

function openBuilder(focusId, back) {
    if (!ed.doc) return;
    commitField();
    // A route opened on: its point 1 (it has no marker of its own).
    const route = focusId && findWorld(ed.doc, focusId);
    if (route && route.kind === 'route') {
        const first = (Array.isArray(route.def.points) ? route.def.points : []).find((p) => p && p.k);
        focusId = first ? pointId(route.id, first.k) : null;
    }
    // (A route is its points: pointThings. Its own row goes to the builder only as one just put down, routePlaced.)
    const uses = usesOfWorlds(ed.doc, ed.cards);
    const things = ed.doc.world.filter((w) => thingIs(w.kind, 'builder') && w.kind !== 'route').map((w) => ({
        ...builderThing(w, uses), coords: (w.def && w.def.coords) || null, rot: (w.def && w.def.rot) || null,
    })).concat(pointThings(false).filter((t) => t.coords || t.id === focusId));   // (the one opened on, put down at once)
    // (Placed ones only: one opened on before it was placed is never the builder's to remove.)
    builderSent = new Set(things.filter((t) => t.coords).map((t) => t.id));
    builderSynced = new Map();   // (a builder new open has been sent nothing by builderSync yet)
    builderAdopted = new Set();
    building = true;
    ed.inBuilder = true;
    gridFramed = false;
    gridView = null;
    litSent = '';
    nuiCallback('directorBuild', { name: ed.doc.name || ed.key, things, focus: focusId || null, autosave: autosaveOn(),
                                   back: back === true });
}

// The world builder saves by itself every five minutes while there is something to save (html/js/furnisher.js),
// unless the World tab's switch says not: this player's choice, kept on this PC.
const AUTOSAVE_KEY = 'whip_director_autosave';
function autosaveOn() {
    try { return localStorage.getItem(AUTOSAVE_KEY) !== 'off'; } catch (_) { return true; }
}
ed.autosaveOn = autosaveOn;

// How the cards look on the grid: the Board (the heist board, the default) or Classic, the Cards tab's choice (canvas.js
// STYLES). This player's choice, kept on this PC.
const CARD_STYLE_KEY = 'whip_director_card_style';
function cardStyle() {
    try { return localStorage.getItem(CARD_STYLE_KEY) === 'classic' ? 'classic' : 'board'; } catch (_) { return 'board'; }
}
ed.cardStyle = cardStyle;

/** A new thing of a kind from the builder, as + NPC, + Car and the rest made one: what it is, and how
 *  it starts (an NPC standing, free to move and nothing else, a car locked, a container of 10 slots...). */
function newWorldThing(kind, t, id) {
    const label = String(t.label || (typeof t.model === 'string' && t.model) || thingIs(kind, 'label') || id).slice(0, 60);
    // Spawn Logic: only activates via card (a Spawn or Show card makes it in each run) until set to Always present.
    const w = { id, kind, layer: 'run', label, def: {} };
    if (kind === 'npc') {
        w.def = { model: t.model, behaviour: 'stand', fightBack: false,
                  conditions: { invincible: false, canMove: true, reacts: false } };
        // Picked as a lore character (the NPCs' Lore characters): it is them, their ped and their name.
        if (typeof t.lore === 'string' && t.lore) { w.def.lore = t.lore; applyLore(w); }
    }
    // A random vehicle (the builder's first Vehicles tile): its models on its page, its model the first of them. Locked,
    // with no key, and anyone may lockpick or hotwire it (Only its key opens it: off unless set).
    else if (kind === 'vehicle' && t.random === true) w.def = { model: '', random: true, models: [], locked: true };
    else if (kind === 'vehicle') w.def = { model: t.model, locked: true };
    else if (kind === 'groundItem') w.def = { item: '', amount: 1 };
    else if (kind === 'container') w.def = { slots: 10, maxWeight: 100 };
    else if (kind === 'door' || kind === 'prop') w.def = { model: t.model };
    // A Fixed Weapon (the builder's More, Weapons): a prop that is that gun, and fires as it (Fire Weapon).
    if (kind === 'prop' && typeof t.weapon === 'string' && /^WEAPON_[A-Z0-9_]+$/.test(t.weapon)) w.def.weapon = t.weapon;
    else if (kind === 'route') w.def = { points: [], order: 'loop', pace: 'walk' };
    return w;
}

// ---- A RANDOM VEHICLE'S MODELS (its page: panels.js carModelsGroup; a run picks one: server nodes_world.lua) ----

/** Its models written back, its model the first of them (what the builder's copy, the pictures and the map show). */
function setCarModels(w, list) {
    w.def.models = list.map((m) => ({ model: m.model, chance: m.chance }));
    w.def.model = list.length ? list[0].model : '';
}

/** Chances made to come to 100 between them, as they were shared (evenly when they had none). */
function fillChances(list) {
    if (!list.length) return;
    const had = list.reduce((t, m) => t + m.chance, 0);
    let given = 0;
    for (const m of list) {
        m.chance = had > 0 ? Math.floor((100 * m.chance) / had) : Math.floor(100 / list.length);
        given += m.chance;
    }
    for (let k = 0; given < 100; k = (k + 1) % list.length) { list[k].chance++; given++; }
}

/** One model's chance set to `v`: the others share the rest as they shared it before (evenly when they had none), so
 *  they always come to 100. */
function setChance(list, i, v) {
    const others = list.filter((_, k) => k !== i);
    const rest = 100 - v;
    const had = others.reduce((t, m) => t + m.chance, 0);
    let given = 0;
    for (const m of others) {
        m.chance = had > 0 ? Math.floor((rest * m.chance) / had) : Math.floor(rest / others.length);
        given += m.chance;
    }
    for (let k = 0; others.length && given < rest; k = (k + 1) % others.length) { others[k].chance++; given++; }
    list[i].chance = v;
}

/** A model joins a random vehicle's list, with an even share (the rest make room as they were shared). Answers why
 *  not, or null. */
function addCarModel(w, model) {
    const list = carModels(w);
    if (list.some((m) => m.model === model)) return `${model} is in its list already`;
    if (list.length >= MAX_CAR_MODELS) return `${MAX_CAR_MODELS} models at most`;
    list.push({ model, chance: 0 });
    setChance(list, list.length - 1, Math.round(100 / list.length));
    setCarModels(w, list);
    ed.changed();
    return null;
}

/** Something said about the page, where it can be seen: the world builder's notice, else the status line. */
function sayOnPage(text, tone) {
    if (building && typeof window.uiNotify === 'function') {
        window.uiNotify({ text, type: tone === 'error' || tone === 'warn' ? 'error' : 'success', duration: 3500 });
    } else {
        status(text, tone);
    }
}

/** A random vehicle's model picking in the builder's Vehicles is over: its page and the list drawn again (the Random
 *  vehicle tile back in it). */
function endModelPick() {
    if (!ed.modelPick) return;
    ed.modelPick = null;
    const hooks = pane && pane.hooks;
    drawColumn();
    if (hooks && hooks.vehicles) hooks.vehicles(false);
}

/** The chance slider being dragged: the list as it was when the drag began, so the others keep their shares however
 *  far it goes and comes back. Let go (its change): forgotten. */
let chanceDrag = null;

/** A chance slider moving (panels.js carModelsGroup): its model's chance, the others' share of the rest, every
 *  slider of the list and its number following as it goes. Written; the change on letting go is the edit. */
function chanceInput(el) {
    const w = findWorld(ed.doc, el.dataset.id);
    const i = Number(el.dataset.i);
    if (!w || !Number.isInteger(i)) return;
    if (!chanceDrag || chanceDrag.id !== w.id || chanceDrag.i !== i) chanceDrag = { id: w.id, i, base: carModels(w) };
    const list = chanceDrag.base.map((m) => ({ ...m }));
    if (!list[i]) return;
    setChance(list, i, Math.max(0, Math.min(100, Math.round(Number(el.value) || 0))));
    setCarModels(w, list);
    const group = el.closest('.dr-body, .dr-side-body, .fz-cfg-body') || document;
    group.querySelectorAll(`.dr-chance[data-id="${CSS.escape(w.id)}"]`).forEach((s) => {
        const m = list[Number(s.dataset.i)];
        if (!m) return;
        if (s !== el) s.value = String(m.chance);
        s.style.setProperty('--p', m.chance + '%');
        const out = s.parentNode && s.parentNode.querySelector('.dr-slider-val');
        if (out) out.textContent = m.chance + '%';
    });
}

/** Where the world builder left a thing, as a def's coords: its place and heading, and for a car where its wheels touch
 *  (`ground`: a run makes each of its models that model's height over it, client/director.lua carLifts). */
function builtCoords(c) {
    const out = { x: +c.x.toFixed(3), y: +c.y.toFixed(3), z: +c.z.toFixed(3), heading: +(c.heading || 0).toFixed(1) };
    if (typeof c.ground === 'number' && Number.isFinite(c.ground)) out.ground = +c.ground.toFixed(3);
    return out;
}

/** Done in the world builder: the scenario's things as the builder left them. Moved ones get their spot
 *  and turn, new ones are added (named as they were picked), the ones it removed go — only of those it
 *  says it took (`took`): one it never had (no model yet, not placed) is not its to remove.
 *  `stay`: its Save, which stays open (saveBuilt): the builder is not let go, and each new one's row is told the
 *  id it now has (directorBuilderId), so the next Save writes it there rather than adding it again. Answers
 *  { added, changed, removed }. */
function applyBuilt(things, took, stay) {
    // (Done: its panel and window let go, the grid home, before the world is written.)
    const adopted = builderAdopted;
    if (!stay) builderGone();
    if (!ed.doc || !Array.isArray(things)) return { added: 0, changed: 0, removed: 0 };
    const assigned = [];
    const seen = new Set();
    const ids = worldIds(ed.doc);
    let added = 0, changed = 0, removed = 0;
    // Task points first: each one's spot into its step (one whose step went is let go).
    for (const t of things) {
        if (!t || t.kind !== 'point' || !t.coords || typeof t.coords.x !== 'number') continue;
        const p = pointOf(t.id);
        if (!p) continue;
        const at = { x: +t.coords.x.toFixed(3), y: +t.coords.y.toFixed(3), z: +t.coords.z.toFixed(3),
                     heading: +(t.coords.heading || 0).toFixed(1) };
        if (JSON.stringify(p.s.at) !== JSON.stringify(at)) { p.s.at = at; changed++; }
        seen.add(t.id);
    }
    for (const id of Array.isArray(took) ? took : []) {
        const p = !seen.has(id) && pointOf(id);
        if (!p) continue;
        // (A route's point removed there leaves its list, as pointRemoved does at once; a task's point leaves its
        // step not placed.)
        if (p.list !== 'tasks') {
            const i = p.w.def.points.indexOf(p.s);
            if (i >= 0) { p.w.def.points.splice(i, 1); changed++; }
        } else if (p.s.at) { delete p.s.at; changed++; }
    }
    for (const t of things) {
        if (!t || !thingIs(t.kind || 'prop', 'builder') || !t.coords || typeof t.coords.x !== 'number') continue;
        const kind = t.kind || 'prop';
        const coords = builtCoords(t.coords);
        let w = t.id ? findWorld(ed.doc, t.id) : null;
        const before = w ? JSON.stringify(w.def) : null;
        if (!w) {
            const id = freeId(ids, thingIs(kind, 'base') || 'thing');
            ids.add(id);
            w = newWorldThing(kind, t, id);
            ed.doc.world.push(w);
            added++;
            if (stay && Number.isInteger(t.index)) assigned.push({ index: t.index, id });
        } else if (kind === 'door' ? typeof t.model === 'number' : (kind === 'npc' || (kind === 'vehicle' && !w.def.random) || kind === 'prop')
                   && typeof t.model === 'string' && t.model !== '' && !w.def.model) {
            // (A random vehicle's model is its page's: the builder's copy shows any of its models.)
            // Its model: the first one it was given (a door picked, an NPC or a car with none yet, opened on
            // in the builder); a door picked again is another door. One it has is the page's (Change model):
            // a Save before its copy was made again as it must not take it back.
            w.def.model = t.model;
        }
        // An NPC with no ped yet, picked as a lore character in the builder: it is them now.
        if (kind === 'npc' && typeof t.lore === 'string' && t.lore && w.def.lore !== t.lore) { w.def.lore = t.lore; applyLore(w); }
        // A Fixed Weapon without its gun (put down before the gun was kept with it): the builder knows it by its model.
        if (kind === 'prop' && !w.def.weapon && typeof t.weapon === 'string' && /^WEAPON_[A-Z0-9_]+$/.test(t.weapon)) w.def.weapon = t.weapon;
        w.def.coords = coords;
        // Only a prop is tilted; the rest stand upright.
        const rx = kind === 'prop' && t.rot ? +t.rot.x || 0 : 0, ry = kind === 'prop' && t.rot ? +t.rot.y || 0 : 0;
        if (rx || ry) w.def.rot = { x: rx, y: ry }; else delete w.def.rot;
        // (Sent only for one moved or new: the rest keep what they had.)
        if (typeof t.interior === 'boolean') w.def.interior = t.interior;
        if (kind === 'prop' && t.light === true) w.def.light = true; else delete w.def.light;
        // (One the scenario took as it was put down, directorThingPlaced, is still new to this Save.)
        if (before !== null && adopted.has(w.id)) added++;
        else if (before !== null && JSON.stringify(w.def) !== before) changed++;
        seen.add(w.id);
    }
    // (Without the game's list, nothing is removed: safer than removing what it may never have had.) The
    // things Configure made while it was open are the builder's too.
    const handed = (Array.isArray(took) ? took : []).concat([...adopted]);
    for (const id of handed) {
        if (!builderSent || !builderSent.has(id)) continue;
        if (!seen.has(id) && findWorld(ed.doc, id)) {
            ed.doc.world = ed.doc.world.filter((w) => w.id !== id);
            if (ed.worldOpen === id) ed.worldOpen = null;
            removed++;
        }
    }
    if (stay) {
        // Still open: what the builder holds is what it handed back, the new ones by their new ids (client/director.lua
        // adds each to what it holds as it hears).
        builderSent = new Set(seen);
        builderAdopted = new Set();
        for (const a of assigned) nuiCallback('directorBuilderId', a);
        if (added || removed || changed) ed.changed();
        return { added, changed, removed };
    }
    builderSent = null;
    builderAdopted = new Set();
    ed.tab = 'world';
    // Done with nothing changed leaves the scenario unedited (no unsaved mark for nothing).
    if (!added && !removed && !changed) {
        drawColumn();
        status('Nothing changed in the world', '');
        return { added, changed, removed };
    }
    ed.changed();
    const parts = [];
    if (added) parts.push(`${added} added`);
    if (changed) parts.push(`${changed} changed`);
    if (removed) parts.push(`${removed} removed`);
    status(`World updated: ${parts.join(', ')}`, 'ok');
    check(true);
    return { added, changed, removed };
}

/** The world builder's Save (and its timed one, `auto`): the set written into the scenario as Done would, and the
 *  scenario saved, without leaving; the builder hears how it went (directorBuilderSaved: its "Saved" or why not).
 *  Quiet: nothing here may wait on a question the hidden Director would ask (someone saved first). */
let savingBuilt = false;
async function saveBuilt(things, took, auto) {
    if (savingBuilt) { nuiCallback('directorBuilderSaved', { ok: false, text: 'Still saving the last one' }); return; }
    savingBuilt = true;
    try {
        applyBuilt(things, took, true);
        const r = await save(auto ? 'world builder (auto-save)' : 'world builder', { quiet: true });
        const errs = ed.problemList.filter((p) => p.severity === 'error').length;
        const text = !r.ok ? (r.why || 'Could not save')
            : r.nothing ? 'Nothing to save'
            : (auto ? 'Auto-saved' : 'Saved') + (r.rev ? `: revision ${r.rev}` : '') + (errs ? `, ${plural(errs, 'problem')} (see Check)` : '');
        nuiCallback('directorBuilderSaved', { ok: r.ok, text });
    } finally {
        savingBuilt = false;
    }
}

// ============================================================
// The Director, inside the world builder (html/js/furnisher.js)
// ============================================================
//
// While the world builder is open on this scenario (openBuilder, until Done or the Director showing again),
// two of the Director's surfaces can be in it:
//   THE PANEL   the page the column would draw (a placed thing's, from the builder's Configure; a card's,
//               picked on the grid), drawn into the builder's right-hand panel: the same fields and the
//               same writes (bindPanel), its back rows gone (ed.inBuilder, panels.js)
//   THE GRID    the blueprint canvas itself, moved into the builder's window and back
// What changes goes back to the builder at once (builderSync): a thing's name, what its mark says, the
// prompt a run puts on it, a new model (a lore character's ped). A card picked or under the pointer on
// the grid lights what it names in the world, green (builderLit).

let building = false;            // the world builder is open on this scenario
let testAfterBuilt = false;      // the builder's Test pressed: the editor's Test once its set is written in (directorBuilt)
let builderAdopted = new Set();  // things Configure made while it was open: Done may take them away too
let pane = null;                 // { el, body, hooks, view } the builder's panel, while it has a page
let pal = null;                  // { el, body } the card list in the builder's Blueprint window, while it shows
let paneBefore = null;           // what the panel showed before a card was picked: 'cards', a thing's id, or null (closed)
let grid = null;                 // { home, next, view, hooks } the canvas, while it is in the builder's window
let gridView = null;             // where the window's grid was, for the next time it opens
let gridFramed = false;          // the window's grid framed once since the builder opened
let mapView = null;              // the Map window's map, while it is up (builder.map)
let hoverCard = null;            // the card under the pointer in the window
let litSent = '';                // the world ids last lit
let syncTimer = 0;
const panesBound = new WeakSet();
const GRID_READABLE = 0.6;       // the window's grid opens no smaller than this (a card's words still read)

/** The builder's panel, after the column drew: the same page. When there is none to show (no card
 *  picked, no thing's page), the panel goes and its hooks hear so. */
function drawPane() {
    if (!pane) return;
    const thing = ed.tab === 'world' && ed.worldOpen ? findWorld(ed.doc, ed.worldOpen) : null;
    const cardPage = ed.tab === 'card' && ed.selected.size > 0;
    if (!ed.doc || !(ed.picker || cardPage || thing)) {
        const hooks = pane.hooks;
        unpage();
        if (hooks && hooks.gone) hooks.gone();
        return;
    }
    // (A model being picked for a random vehicle's page: over once the panel shows anything else.)
    if (ed.modelPick && !(thing && thing.id === ed.modelPick)) {
        ed.modelPick = null;
        if (pane.hooks && pane.hooks.vehicles) pane.hooks.vehicles(false);
    }
    const body = pane.body;
    const view = (ed.picker ? 'pick:' : ed.taskPick ? 'tasks:' : ed.taskCopy ? 'copy:' + (ed.taskCopy.from || '') + ':' : ed.voicePick ? 'voice:' : ed.tab + ':')
        + (thing ? (ed.multi ? ed.multi.join(',') : thing.id) + ':' + (ed.thingTab || '') : [...ed.selected].join(','));
    const scroll = view === pane.view ? body.scrollTop : 0;
    pane.view = view;
    body.classList.toggle('split', !!ed.picker);
    body.innerHTML = renderTab(ed);
    body.scrollTop = scroll;
    if (pane.hooks && pane.hooks.title) {
        // (Several selected: their own pickers are MANY's.)
        const mine = (v) => v === (ed.multi ? MANY : thing && thing.id);
        pane.hooks.title(cardPage ? 'Card' : thing && mine(ed.taskPick) ? 'Add a task'
            : thing && ed.taskCopy && mine(ed.taskCopy.id) ? 'Copy tasks'
            : thing && ed.voicePick && ed.voicePick.id === thing.id ? 'Choose a voice' : 'Configure');
    }
    showUses(false);   // (the cards that use a thing whose page this is, lit white; none otherwise)
}

/** The card list in the Blueprint window (builder.cards), drawn again: the Director column's list, scrolled where
 *  it was. */
function drawPal() {
    if (!pal) return;
    pal.body.innerHTML = renderCards(ed);
    const list = pal.body.querySelector('.dr-pal-list');
    if (list) list.scrollTop = ed.palScroll;
}

function unpage() {
    if (!pane) return;
    // (A model being picked for a random vehicle's page: over with it.)
    if (ed.modelPick) {
        ed.modelPick = null;
        if (pane.hooks && pane.hooks.vehicles) pane.hooks.vehicles(false);
    }
    pane.body.innerHTML = '';
    pane = null;
    paneBefore = null;
    // The page it showed is let go of with it: no thing's page left open under the grid to come back
    // later, nor its cards lit white (showUses).
    if (ed.tab === 'world') ed.worldOpen = null;
    ed.multi = null;
    showUses(false);
}

/** The world things a card names (its World fields): the one under the pointer on the window's grid, else
 *  the ones picked. */
function litIds() {
    const out = new Set();
    for (const id of hoverCard ? [hoverCard] : [...ed.selected]) {
        const n = findNode(ed.doc, id);
        const def = n && ed.cards.get(n.type);
        for (const f of (def && def.props) || []) {
            const v = n.props[f.key];
            if (f.kind === 'world' && typeof v === 'string' && v) out.add(v);
            // (A group lights each of its members.)
            if (f.kind === 'worlds' && Array.isArray(v)) for (const x of expandThings(ed.doc.world, v, f.groups ? f.worldKind : undefined)) out.add(x);
        }
    }
    return [...out];
}

/** What the window's grid lights in the world, to the builder (client/furnish_builder.lua), when it changes.
 *  Nothing is lit while the grid is not in the window. */
function builderLit() {
    if (!building || !ed.doc) return;
    const ids = grid ? litIds() : [];
    const key = ids.join('|');
    if (key === litSent) return;
    litSent = key;
    nuiCallback('furnishHighlight', { ids });
}

/** One thing as the builder is handed it on a sync. */
/** `all` (optional): usesOfWorlds, worked out once for many things. */
function builderThing(w, all) {
    const uses = usedBy(w.id, all);
    // What other resources keep on a thing with a copy in the world (a car's Whiplash look): its copy is dressed by
    // them (client/furnish_builder.lua dress).
    const ext = (w.kind === 'vehicle' || w.kind === 'npc' || w.kind === 'prop') && w.def.ext && typeof w.def.ext === 'object'
        && Object.keys(w.def.ext).length ? w.def.ext : undefined;
    return { id: w.id, kind: w.kind, model: builderModel(w), label: w.label || w.id, uses,
             prompt: promptOf(w), mark: markOf(w, uses), ext, ...builderExtras(w) };
}

/** The scenario's things as the builder should show them now (client/director.lua): at most every 150 ms while
 *  changes keep coming (each sends what is there when it goes, so the last change is never lost). Only the things that
 *  differ from what it was last sent go (builderSynced: each one's text as sent), with every point's id, so one whose
 *  task was removed goes from the world too; nothing changed, nothing is sent. */
let builderSynced = new Map();
function builderSync() {
    if (!building || !ed.doc || syncTimer) return;
    syncTimer = setTimeout(() => {
        syncTimer = 0;
        if (!building || !ed.doc) return;
        const uses = usesOfWorlds(ed.doc, ed.cards);
        const all = ed.doc.world.filter((w) => thingIs(w.kind, 'builder') && w.kind !== 'route').map((w) => builderThing(w, uses))
            .concat(pointThings(false));   // (their numbers and names follow a list changed in the panel)
        const things = [], points = [], now = new Map();
        for (const t of all) {
            const text = JSON.stringify(t);
            now.set(t.id, text);
            if (builderSynced.get(t.id) !== text) things.push(t);
            if (t.kind === 'point') points.push(t.id);
        }
        const gone = [...builderSynced.keys()].some((id) => !now.has(id));
        builderSynced = now;
        if (!things.length && !gone) return;
        nuiCallback('directorBuilderSync', { things, points, all: true });
    }, 150);
}

/** Just one thing, at most every 40 ms: a guard's Eye sight as its slider moves, so its cone in the world follows. */
let syncOneTimer = 0, syncOneId = null;
function builderSyncOne(id) {
    if (!building || !ed.doc) return;
    syncOneId = id;
    if (syncOneTimer) return;
    syncOneTimer = setTimeout(() => {
        syncOneTimer = 0;
        const w = building && ed.doc && findWorld(ed.doc, syncOneId);
        if (w && thingIs(w.kind, 'builder')) nuiCallback('directorBuilderSync', { things: [builderThing(w)] });
    }, 40);
}

/** The builder closed without Done (its Exit throws away what was placed, and the Director closes; a test): what
 *  Configure made for things placed in it goes with them. Its panel and window let go, the grid home. */
function builderLeft() {
    if (building && builderAdopted.size && ed.doc) {
        ed.doc.world = ed.doc.world.filter((w) => !builderAdopted.has(w.id));
        if (builderAdopted.has(ed.worldOpen)) ed.worldOpen = null;
        builderAdopted = new Set();
        ed.history.commit(ed.doc);
    }
    builderGone();
}

/** The builder gone (Done, Exit, the Director back): its panel and window are let go, the grid comes home. */
function builderGone() {
    building = false;
    ed.inBuilder = false;
    ed.modelPick = null;   // (a random vehicle's model picked from the builder's Vehicles: not without it)
    ed.preview = null;   // (its copies go with the builder: client/director_preview.lua stops with it)
    builder.uncanvas();
    unpage();
    hoverCard = null;
    litSent = '';
}

/** The world builder's Play here: this thing's tasks and those it plays with (its tasks' playWith), read by the server
 *  as a run reads them (from the scenario as it is here, saved or not), then played on their copies there
 *  (client/director_preview.lua). What could not be read is said under the button (Check has the why). */
async function previewPlay(id) {
    const w = findWorld(ed.doc, id);
    if (!w || !building) return;
    commitField();
    const want = [w.id].concat(w.def.tasks && Array.isArray(w.def.tasks.playWith) ? w.def.tasks.playWith : []);
    const things = [...new Set(want)].map((x) => findWorld(ed.doc, x))
        .filter((x) => x && thingIs(x.kind, 'tasks') && tasksOf(x).list.length)
        // (A car's take ids: a task's take is one of its own.)
        .map((x) => ({ id: x.id, kind: x.kind, tasks: x.def.tasks, takes: takesOf(x).map((t) => ({ id: t.id })) }));
    // (What a step may name: each thing's kind; a route's points, which Walk a Route walks.)
    const world = {};
    for (const x of ed.doc.world) {
        world[x.id] = { kind: x.kind, label: x.label, def: x.kind === 'route'
            ? { points: x.def.points, order: x.def.order, pace: x.def.pace, findWay: x.def.findWay } : {} };
    }
    ed.preview = { state: 'playing', ids: things.map((x) => x.id), note: null };
    drawColumn();
    const r = await call('previewPlans', { things, world });
    if (!r.ok) { ed.preview = { state: 'idle', ids: [], note: r.why }; drawColumn(); return; }
    const runs = [], notes = [];
    for (const p of listOf(r.data.plans)) {
        const x = findWorld(ed.doc, p.id);
        if (!x) continue;
        const probs = listOf(p.problems);
        if (probs.length) notes.push(`${x.label || x.id}: ${plural(probs.length, 'task')} left out (Check says why)`);
        if (!(p.plan && p.plan.steps)) continue;
        const steps = listOf(p.plan.steps);
        // (A car's take with the trailers it hitched: each played on its own track beside it, as a run plays them.)
        for (const s of steps) if (x.kind === 'vehicle' && s && s.t === 'take' && s.p) s.p.tow = towToWatch(x, s.p.take);
        runs.push({ id: x.id, kind: x.kind, label: x.label || x.id, plan: { steps, after: p.plan.after } });
    }
    if (notes.length) ed.preview.note = notes.join('; ');
    nuiCallback('directorPreviewPlay', { runs });
}

// ---- DUPLICATE (the world builder's bubble): a full copy of a placed thing, in hand to put down ----

// (The kinds a copy can be made of, and that Change model takes: their copy and remodel, things-data.js. A door is the
// world's, a route is its points; a model is picked from Place.)

/** A copy's name: the next number on the end of the one it copies ("Guard 2", "Ballas #3"), none taken. */
function copyLabel(label) {
    const taken = new Set(ed.doc.world.map((w) => w.label));
    const m = /^(.*?)(\d+)$/.exec(label);
    const base = m ? m[1] : label + ' ';
    let n = m ? Number(m[2]) + 1 : 2;
    while (taken.has(base + n)) n++;
    return (base + n).slice(0, 60);
}

/** Everything `w` is, as a thing of its own: its look, tasks (their points where its are), eye sight, takes, key
 *  settings and what other resources keep on it. Not what can only be one thing's: the NPCs riding in a car (an NPC
 *  sits in one car), and its key's spot on the ground (that spot is the car's). Where it stands is where `w` does
 *  until it is put down. */
function copyOfThing(w) {
    const c = JSON.parse(JSON.stringify(w));
    c.id = freeId(worldIds(ed.doc), thingIs(w.kind, 'base') || 'thing');
    c.label = copyLabel(w.label || w.id);
    if (w.kind === 'vehicle') {
        delete c.def.riders;
        if (c.def.key && typeof c.def.key === 'object') delete c.def.key.spot;
    }
    return c;
}

export const builder = {
    /** Is the world builder open on the scenario open here? */
    on: () => building && !!ed.doc,
    /** The Blueprint window's Fullscreen: the full editor. The world is handed back as Done hands it (its Save still to
     *  press), and the camera kept for Back to the world (client/director.lua directorBuilderDone). */
    fullscreen() {
        if (!building || !ed.doc) return;
        commitField();
        nuiCallback('directorBuilderDone', { full: true });
    },
    /** The builder's Test: as Fullscreen (its set written into the scenario, the editor up, Back to the world returning to
     *  this view), then the editor's Test once the set is in (directorBuilt). Refused, the editor says why. */
    test() {
        if (!building || !ed.doc) return;
        commitField();
        testAfterBuilt = true;
        nuiCallback('directorBuilderDone', { full: true });
    },
    /** A random vehicle's page picking a model from the Vehicles (its Add a model from Vehicles): { id, label }, or null. */
    modelPick() {
        const w = building && ed.modelPick && ed.doc ? findWorld(ed.doc, ed.modelPick) : null;
        return w ? { id: w.id, label: w.label || w.id } : null;
    },
    /** A vehicle pressed in the Vehicles while picking: it joins that car's list (the picking ends once it is full). */
    addModel(model) {
        const w = building && ed.modelPick && ed.doc ? findWorld(ed.doc, ed.modelPick) : null;
        if (!w || typeof model !== 'string' || !model) return false;
        const why = addCarModel(w, model);
        sayOnPage(why || `${model} added to ${w.label || w.id}`, why ? 'warn' : 'ok');
        if (carModels(w).length >= MAX_CAR_MODELS) endModelPick();
        return !why;
    },
    /** Has the scenario changes its Save would save (its Configure, its Blueprint), besides the world's? */
    docDirty: () => !!(building && ed.doc && ed.history.isDirty(ed.doc)),
    /** Is this one of the scenario's things (or one of its tasks' points)? */
    has: (id) => !!(building && id && ed.doc && (findWorld(ed.doc, id) || pointOf(id))),
    /** The lore characters, for the builder's NPCs (html/js/furnisher.js npcSource): { key, name, model, picture, ... }. */
    lore: () => (building && Array.isArray(ed.lore) ? ed.lore : []),
    /** Other resources' buttons for the bubble beside a selected thing of `kind`: { id, label, icon, hint }; first the
     *  Character editor for a freemode NPC that is no lore character (`thing`: { id, model, lore }: editLook). */
    buttons: (kind, thing) => {
        if (!building || !ed.doc) return [];
        const list = buttonsFor(kind, 'bubble');
        const t = thing || {};
        if (kind !== 'npc' || t.lore || !FREEMODE.has(t.model)) return list;
        return [{ id: LOOK_BUTTON, label: 'Character editor', icon: 'ped',
                  hint: 'Its face, hair, make-up, tattoos and clothes, as a player makes their character' }].concat(list);
    },
    /** One of them pressed on the scenario's thing `id` (made in it first: adopt). */
    press(id, buttonId) {
        const w = building && ed.doc && findWorld(ed.doc, id);
        if (w && buttonId === LOOK_BUTTON) {
            if (w.kind === 'npc') editLook(w);
            return true;
        }
        const b = ed.buttons.find((x) => x.id === buttonId);
        if (!w || !b) return false;
        // A random vehicle of several models: which one is its page's to say (each model's row has the buttons). The
        // builder opens its page (Configure) instead.
        if (w.kind === 'vehicle' && w.def.random && carModels(w).length > 1) return 'page';
        pressButton(w, b);
        return true;
    },

    /** Duplicate: a full copy of the scenario's thing `id` (copyOfThing), made in it at once and in hand on the pointer
     *  in the world (client/director.lua directorBuilderCopy) to put down where it goes; Esc takes it out again. Answers
     *  why not, or null. */
    duplicate(id) {
        const w = building && ed.doc && findWorld(ed.doc, id);
        if (!w) return 'It is not one of the scenario\'s things yet';
        if (w.kind === 'door') return 'A door is the world\'s own: it cannot be copied';
        if (!thingIs(w.kind, 'copy')) return 'That cannot be copied';
        if (w.kind === 'groundItem' && typeof w.def.keyOf === 'string') return 'A car\'s key spot comes with its car: duplicate the car';
        if (!w.def.coords) return 'Put it down first';
        commitField();
        const c = copyOfThing(w);
        ed.doc.world.push(c);
        builderAdopted.add(c.id);
        if (builderSent) builderSent.add(c.id);
        nuiCallback('directorBuilderCopy', { thing: { ...builderThing(c), coords: c.def.coords, rot: c.def.rot || null } });
        ed.changed();
        sayOnPage(`${c.label}: put it down where it goes (Esc takes it back)`, 'ok');
        return null;
    },

    /** Change model: the scenario's thing `id` made as `pick.model`, everything else it has kept (its tasks, eye sight,
     *  takes, settings). A lore character picked from the NPCs (`pick.lore`) makes it them. What fitted only the old
     *  model goes, asked first: what other resources keep on it (a car's Whiplash look) and the lore character it was
     *  (their ped is theirs). Its name follows when it was the list's name for the old model (`pick.was`); `pick.name`
     *  is the new one's. Answers true once changed, 'cancelled', or why not. */
    async remodel(id, pick) {
        const w = building && ed.doc && findWorld(ed.doc, id);
        if (!w || !thingIs(w.kind, 'remodel')) return 'That cannot change its model';
        if (w.kind === 'vehicle' && w.def.random) return 'A vehicle pool\'s models are on its page';
        const model = pick && typeof pick.model === 'string' ? pick.model : '';
        const lore = w.kind === 'npc' && pick && typeof pick.lore === 'string' && pick.lore ? pick.lore : null;
        if (!model) return 'Pick a model';
        if (lore ? w.def.lore === lore : (model === w.def.model && !w.def.lore)) return 'It is that already';
        const newName = (pick.name && String(pick.name)) || model;
        const wasLore = w.kind === 'npc' && w.def.lore ? (ed.lore || []).find((x) => x.key === w.def.lore) : null;
        const lost = [];
        if (w.kind === 'npc' && w.def.lore && w.def.lore !== lore) lost.push(`It is not ${wasLore ? wasLore.name : w.def.lore} any more: their ped is theirs.`);
        const ext = w.def.ext && typeof w.def.ext === 'object' ? Object.keys(w.def.ext) : [];
        if (ext.length) {
            const whose = ext.map((r) => { const b = (ed.buttons || []).find((x) => x.owner === r); return b ? b.label : r; });
            lost.push(`Its ${whose.join(' and ')} settings are taken off: they were made for ${pick.was || w.def.model || 'the old model'}.`);
        }
        // (An NPC's Outfit is its ped's own clothes: another ped has others.)
        const outfit = w.kind === 'npc' && w.def.outfit && typeof w.def.outfit === 'object' && Object.keys(w.def.outfit).length > 0;
        if (outfit) lost.push(`Its outfit is taken off: it was made for ${pick.was || w.def.model || 'the old ped'}.`);
        // (Its look from the character editor is its ped's own too.)
        const look = w.kind === 'npc' && w.def.look !== undefined;
        if (look) lost.push('Its look from the character editor is taken off.');
        if (lost.length) {
            const go = await ask(`Change ${w.label || w.id} to ${newName}?`, `${lost.join(' ')} Everything else it has stays.`, [
                { label: 'Change the model', value: true, tone: 'danger' }, { label: 'Cancel', value: null }]);
            if (!go || !findWorld(ed.doc, id)) return 'cancelled';
        }
        commitField();
        if (ext.length) delete w.def.ext;
        if (outfit) delete w.def.outfit;
        if (look) delete w.def.look;
        // (Named as the list names its old model, or as the lore character it was: named for the new one.)
        const named = !w.label || w.label === pick.was || w.label === w.def.model || (wasLore && w.label === wasLore.name);
        if (lore) {
            w.def.lore = lore;
            applyLore(w);
        } else {
            delete w.def.lore;
            w.def.model = model;
            if (named) w.label = newName.slice(0, 60);
        }
        ed.changed();
        sayOnPage(`${w.label || w.id}: ${newName} now`, 'ok');
        return true;
    },

    /** One the builder made that the scenario has not got yet (Configure on it): made now, as Done would, at
     *  `t.coords`. Its id, or null. */
    adopt(t) {
        if (!building || !ed.doc || !t || !thingIs(t.kind, 'builder')) return null;
        const id = freeId(worldIds(ed.doc), thingIs(t.kind, 'base') || 'thing');
        const w = newWorldThing(t.kind, t, id);
        if (t.coords && typeof t.coords.x === 'number') {
            w.def.coords = builtCoords(t.coords);
        }
        ed.doc.world.push(w);
        builderAdopted.add(id);
        if (builderSent) builderSent.add(id);
        ed.changed();
        return id;
    },

    /** The card list in the Blueprint window itself (its Cards): `el` takes its clicks, drags and search, `body` is
     *  where it is drawn. One clicked goes in the middle of the window's grid, one dragged where it is dropped on
     *  it. Answers whether it is up (only while the grid is in the window). */
    cards(el, body) {
        if (!building || !ed.doc || !grid) return false;
        if (!panesBound.has(el)) {
            bindPanel(el, () => body, () => renderCards(ed));
            watchSelects(el);
            panesBound.add(el);
        }
        pal = { el, body };
        drawPal();
        return true;
    },
    uncards() {
        if (!pal) return;
        pal.body.innerHTML = '';
        pal = null;
    },

    /** Configure: a placed thing's page, in the panel (a task's point: its thing's, with that task open). */
    configure(id) {
        if (!builder.has(id)) return false;
        commitField();
        ed.multi = null;
        ed.picker = null;
        ed.taskPick = null;
        ed.taskCopy = null;
        ed.voicePick = null;
        ed.tab = 'world';
        const p = pointOf(id);
        if (p) {
            ed.worldOpen = p.w.id;
            ed.taskOpen = id;
            ed.thingTab = p.list === 'tasks' ? 'tasks' : 'general';   // (a group's spot is on its General)
        } else {
            ed.worldOpen = id;
            // A car's page with one of its takes open (back from recording it): that take's line on the ground.
            const open = ed.takeOpen && ed.takeOpen.startsWith(id + '#') ? Number(ed.takeOpen.slice(id.length + 1)) : NaN;
            if (Number.isFinite(open)) nuiCallback('directorPreviewPath', { take: open, car: id });
        }
        drawColumn();
        return true;
    },

    /** Add task (the bubble's, on an NPC): its page on the Tasks tab with + Task's list of what it can do up, as + Task
     *  there opens it. Answers why not, or null. */
    addTask(id) {
        const w = building && ed.doc && findWorld(ed.doc, id);
        if (!w || w.kind !== 'npc') return 'Only an NPC is given tasks from here';
        if (!ed.tasks) return 'The tasks have not loaded yet';
        if (tasksOf(w).list.length >= (ed.tasks.max || 40)) return 'It has as many tasks as it can have';
        if (!builder.configure(id)) return 'It is not one of the scenario\'s things yet';
        ed.thingTab = 'tasks';
        ed.taskPick = id;
        ed.taskOpen = null;
        drawColumn();
        return null;
    },

    /** Configure with several selected (Ctrl+click): one page for all of them (panels.js multiPage). `ids`: the
     *  scenario's things, the builder's primary last (a task's point among them is left out). One alone: its own page.
     *  Answers whether a page is up. */
    configureMany(ids) {
        const list = (Array.isArray(ids) ? ids : []).filter((id) => building && ed.doc && findWorld(ed.doc, id));
        if (list.length < 2) return list.length ? builder.configure(list[0]) : false;
        commitField();
        ed.picker = null;
        ed.voicePick = null;
        // (The list of tasks to add, or Copy tasks, for all of them stays up while the selection changes under it.)
        if (ed.taskPick !== MANY) ed.taskPick = null;
        if (!(ed.taskCopy && ed.taskCopy.id === MANY)) ed.taskCopy = null;
        ed.tab = 'world';
        ed.multi = list;
        ed.worldOpen = list[list.length - 1];
        ed.taskOpen = null;
        drawColumn();
        return true;
    },

    /** Add task with several NPCs selected: their page on its Tasks tab, the list of tasks up; one picked goes on the end
     *  of every one's list (taskForAll). Answers why not, or null. */
    addTaskMany(ids) {
        const things = (Array.isArray(ids) ? ids : []).map((id) => building && ed.doc && findWorld(ed.doc, id)).filter(Boolean);
        if (things.length < 2) return things.length ? builder.addTask(things[0].id) : 'Nothing is selected';
        if (things.some((w) => w.kind !== 'npc')) return 'Only NPCs are given tasks from here';
        if (!ed.tasks) return 'The tasks have not loaded yet';
        if (things.some((w) => tasksOf(w).list.length >= (ed.tasks.max || 40))) return 'One of them has as many tasks as it can have';
        if (!builder.configureMany(ids)) return 'They are not the scenario\'s things yet';
        ed.thingTab = 'tasks';
        ed.taskPick = MANY;
        ed.taskCopy = null;
        drawColumn();
        return null;
    },

    /** Add to group (the bubble's, with several selected): each NPC and prop of `ids` in group `name`, in one undo step.
     *  Answers why not, or null. */
    setGroup(ids, name) {
        const things = (Array.isArray(ids) ? ids : []).map((id) => building && ed.doc && findWorld(ed.doc, id)).filter(Boolean);
        const can = things.filter((w) => w.kind === 'npc' || w.kind === 'prop');
        if (!can.length) return 'Only NPCs and props have a group';
        const g = String(name || '').trim().slice(0, 40);
        if (!g) return 'Type the group\'s name';
        commitField();
        for (const w of can) w.def.group = g;
        ed.changed();
        sayOnPage(`${can.length} in the group "${g}"`, 'ok');
        return null;
    },

    /** Is the panel on several's page (configureMany)? */
    multi: () => !!(building && ed.multi && pane),

    /** The groups the scenario's NPCs and props are in now, A to Z (Add to group offers them). */
    groups() {
        if (!building || !ed.doc) return [];
        const names = ed.doc.world.filter((w) => (w.kind === 'npc' || w.kind === 'prop') && typeof w.def.group === 'string')
            .map((w) => w.def.group.trim()).filter(Boolean);
        return [...new Set(names)].sort((a, b) => a.localeCompare(b));
    },

    /** The panel: `el` takes the page's clicks and fields, `body` is where it is drawn. hooks: { title(text),
     *  gone() } — gone when it has no page left to show. */
    page(el, body, hooks) {
        if (!building) return;
        if (!panesBound.has(el)) {
            bindPanel(el, () => body);
            watchSelects(el);
            panesBound.add(el);
        }
        pane = { el, body, hooks: hooks || null, view: '' };
        drawPane();
    },
    unpage() {
        commitField();
        unpage();
    },

    /** The grid, in the builder's window `el`. hooks: { picked() } — a card was picked on it. `focusId`: the
     *  thing selected in the builder, whose cards it opens on the first time. */
    canvas(el, hooks, focusId) {
        if (!building || !canvas || grid) return;
        const host = canvas.root;
        grid = { home: host.parentNode, next: host.nextSibling, view: { ...canvas.view }, hooks: hooks || null };
        el.appendChild(host);
        if (!host.dataset.builderHover) {
            // The card under the pointer lights what it names (builderLit), while the grid is in the window.
            host.dataset.builderHover = '1';
            host.addEventListener('mouseover', (e) => {
                if (!grid) return;
                const c = e.target.closest && e.target.closest('.dr-card');
                const id = c ? c.dataset.id : null;
                if (id !== hoverCard) { hoverCard = id; builderLit(); }
            });
            host.addEventListener('mouseleave', () => {
                if (grid && hoverCard) { hoverCard = null; builderLit(); }
            });
        }
        if (gridView) {
            canvas.view = { ...gridView };
            canvas.applyView();
        } else if (!gridFramed) {
            // The first time: on the cards that use the thing selected in the builder (else the cards picked,
            // else all of them), never smaller than its words can be read at in a window this size.
            gridFramed = true;
            const uses = focusId && findWorld(ed.doc, focusId) ? usesOfWorld(ed.doc, ed.cards, focusId).map((u) => u.node.id) : [];
            canvas.frame(uses.length ? uses : ed.selected.size ? [...ed.selected] : null);
            if (canvas.view.z < GRID_READABLE) {
                const r = host.getBoundingClientRect();
                canvas.zoomAt(r.left + r.width / 2, r.top + r.height / 2, GRID_READABLE);
            }
        }
        canvas.render();
        builderLit();
    },
    uncanvas() {
        if (!grid) return;
        const host = canvas.root;
        gridView = { ...canvas.view };
        grid.home.insertBefore(host, grid.next && grid.next.parentNode === grid.home ? grid.next : null);
        canvas.view = grid.view;
        canvas.applyView();
        grid = null;
        hoverCard = null;
        builderLit();
        builder.uncards();   // (the window's card list was for that grid)
        drawPane();
    },
    /** The window was resized: the grid is drawn for its new size. */
    resized() { if (grid) canvas.applyView(); },

    /** The Map window's body `el`: the scenario's things on the map (director/map.js). hooks: { configure(id) } — a
     *  mark's card's Configure (its page on the right). */
    map(el, hooks) {
        if (!building || !ed.doc || mapView) return;
        mapView = mountMap(el, { ed, call, configure: hooks && hooks.configure });
    },
    unmap() {
        if (!mapView) return;
        mapView.stop();
        mapView = null;
    },
    mapResized() { if (mapView) mapView.resized(); },
};

function renameField(el) {
    const old = el.dataset.id;
    const id = el.value.trim();
    if (id === old) return;
    const isWorld = el.dataset.actChange === 'rename-world';
    const taken = isWorld ? worldIds(ed.doc) : new Set(ed.doc.vars.map((v) => v.id));
    if (!isId(id) || taken.has(id)) {
        status(isId(id) ? `${id} is taken` : 'An id is letters, digits, _ and -', 'warn');
        el.value = old;
        return;
    }
    // A card kept to a permission this builder has not got names it: renaming would change that card.
    const kept = lockedUsing(old, isWorld);
    if (kept) {
        status(`${kept.title} uses ${old} and needs the permission ${kept.permission || '?'}: it cannot be renamed by you`, 'warn');
        el.value = old;
        return;
    }
    if (isWorld) {
        // (One every variant shares: their cards follow too. A variant's own is its alone.)
        const shared = sharedIds(ed.doc, taskTypes()).has(old);
        findWorld(ed.doc, old).id = id;
        renameWorld(ed.doc, ed.cards, taskTypes(), old, id);
        if (shared) for (const nodes of otherVariantNodes()) renameWorld({ nodes }, ed.cards, taskTypes(), old, id);
        if (ed.worldOpen === old) ed.worldOpen = id;
    } else {
        ed.doc.vars.find((v) => v.id === old).id = id;
        // (Every variant's cards: the variables are the scenario's.)
        for (const nodes of [ed.doc.nodes, ...otherVariantNodes()]) renameVar({ nodes }, ed.cards, old, id);
    }
    ed.changed();
}

/** A variable's type changed: its starting value follows. */
function coerceVar(v) {
    if (v.type === 'number') v.default = typeof v.default === 'number' ? v.default : (parseFloat(v.default) || 0);
    else if (v.type === 'bool') v.default = v.default === true;
    else v.default = v.default === undefined || v.default === null ? '' : String(v.default);
}

/** The column's clicks and fields, on `pane`: the column itself, the world builder's panel that draws the
 *  same pages (builder.page), or the card list in its Blueprint window (builder.cards). `bodyOf()` is the box the
 *  page is drawn in, `render()` what a search typed there draws again (the page it shows). */
function bindPanel(pane, bodyOf, render = () => renderTab(ed)) {
    // A placed thing's picture that says what it is (panels.js worldArt): the thing as big as its box, as it loads.
    pane.addEventListener('load', (ev) => {
        if (ev.target && ev.target.tagName === 'IMG' && ev.target.dataset.fit) fitPicture(ev.target);
    }, true);
    pane.addEventListener('click', (ev) => {
        // A segmented key, or a switch (it carries the value a press writes, as a key does).
        const seg = ev.target.closest('.dr-seg-key[data-t], .dr-sw[data-t]');
        if (seg) {
            if (seg.disabled) return;
            if (writeSeg(ed, seg)) {
                if (seg.dataset.t.startsWith('var:') && seg.dataset.k === 'type') {
                    const v = ed.doc.vars.find((x) => 'var:' + x.id === seg.dataset.t);
                    if (v) coerceVar(v);
                }
                ed.changed();
            }
            return;
        }
        const tab = ev.target.closest('.dr-tab');
        if (tab) {
            commitField();
            // A card's page on the right stays open: the column's tab changes under it.
            if (sideOn()) {
                if (tab.dataset.tab === 'world' && ed.homeTab === 'world') ed.worldOpen = null;
                ed.homeTab = tab.dataset.tab;
                drawColumn();
                return;
            }
            // World pressed again on a placed thing's page: back to the list.
            if (tab.dataset.tab === 'world' && ed.tab === 'world') ed.worldOpen = null;
            ed.picker = null;
            ed.tab = tab.dataset.tab;
            drawColumn();
            return;
        }
        // (A row with an act of its own, the task picker's, is not a card.)
        const pal = ev.target.closest('.dr-pal-row:not([data-act])');
        if (pal && !palDrag.moved) {
            const def = ed.cards.get(pal.dataset.type);
            if (def) addAtCentre(def);
            return;
        }
        const a = ev.target.closest('[data-act]');
        if (a && !a.disabled) onAct(a.dataset.act, a);
    });
    pane.addEventListener('input', (ev) => {
        const el = ev.target;
        // A random vehicle's chance (its Models): every slider of the list follows.
        if (el.classList.contains('dr-chance')) { chanceInput(el); return; }
        if (el.classList.contains('dr-pal-search')) {
            ed.paletteQuery = el.value;
            ed.palScroll = 0;
            const body = bodyOf();
            body.innerHTML = render();
            const box = body.querySelector('.dr-pal-search');
            box.focus();
            box.setSelectionRange(box.value.length, box.value.length);
            return;
        }
        // The voice picker's search (GTA Speech), as it is typed: the list again, the box kept in hand.
        if (el.classList.contains('dr-voice-search') && ed.voicePick) {
            ed.voicePick.query = el.value;
            const body = bodyOf();
            body.innerHTML = renderTab(ed);
            const box = body.querySelector('.dr-voice-search');
            box.focus();
            box.setSelectionRange(box.value.length, box.value.length);
            return;
        }
        // The item picker's search, as it is typed (the list again, the box kept in hand).
        if (el.classList.contains('dr-pick-search') && ed.picker) {
            ed.picker.query = el.value;
            const body = bodyOf();
            body.innerHTML = renderTab(ed);
            const box = body.querySelector('.dr-pick-search');
            box.focus();
            box.setSelectionRange(box.value.length, box.value.length);
            return;
        }
        // A slider, as it moves: its value beside it and its filled track (panels.js sliderField; an Outfit's says its
        // style as "2 / 5", or None: panels.js outfitSlider).
        if (el.type === 'range') {
            const out = el.parentNode && el.parentNode.querySelector('.dr-slider-val');
            if (out) out.textContent = sliderText(el);
            el.style.setProperty('--p', sliderPct(el) + '%');
            turnGhost(el, false);
        }
        // A big text box grows with what is typed (panels.js growRows), so no line is cut by its edge.
        if (el.dataset && el.dataset.grow) {
            const rows = growRows(el.value, Number(el.dataset.grow) || 3);
            if (el.rows !== rows) el.rows = rows;
        }
        if (el.dataset && el.dataset.t && el.dataset.f !== 'select') {
            if (writeField(ed, el)) touched(el.dataset.t);
        }
        // A card's look (Show Objective's card, Wait for Press's prompt: panels.js cardTry) says what is typed as it is.
        if (el.dataset && el.dataset.t && el.dataset.k) {
            const pv = pane.querySelector(`[data-preview="${CSS.escape(el.dataset.t + '|' + el.dataset.k)}"]`);
            if (pv) pv.textContent = el.value.trim() || pv.dataset.empty || '';
        }
    });
    pane.addEventListener('change', (ev) => {
        const el = ev.target;
        if (el.classList.contains('dr-chance')) { chanceDrag = null; ed.changed(); return; }
        if (el.type === 'range') turnGhost(el, true);
        if (el.dataset && el.dataset.actChange) { renameField(el); return; }
        // A 'worlds' field's Add (panels.js worldsField): the one picked joins its list.
        if (el.dataset && el.dataset.addTo) {
            const [nid, k] = el.dataset.addTo.split('|');
            const n = findNode(ed.doc, nid);
            if (n && el.value && (findWorld(ed.doc, el.value) || groupName(el.value))) {
                setWorlds(n, k, worldsOf(n, k).concat([el.value]).filter((x, i, a) => a.indexOf(x) === i));
                ed.changed();
            }
            return;
        }
        if (el.dataset && el.dataset.t) {
            writeField(ed, el);
            if (el.dataset.k === 'lore' && el.dataset.t.startsWith('def:')) {
                applyLore(ed.doc.world.find((w) => 'def:' + w.id === el.dataset.t));
            }
            // A typed field is left by clicking the NEXT field: redrawing the column now would take
            // that click's focus away, and what it shows is what was typed. A pick redraws, and so does an NPC
            // /me's How many play (Between them shows past one: panels.js cardFields).
            const shapes = el.dataset.k === 'count' && el.dataset.t.startsWith('node:')
                && /^npc\.(me|say)$/.test((findNode(ed.doc, el.dataset.t.slice(5)) || {}).type || '');
            // (An Outfit's style let go of: its colours are that style's, drawn again.)
            if (el.dataset.f === 'select' || shapes || el.dataset.t.startsWith('outfit:')) {
                ed.changed();
            } else {
                ed.history.commit(ed.doc);
                canvas.render();
                drawHead();
                builderSync();
            }
        }
    });
    // The card list: the card under the pointer (the mouse's, or the pad's circle, which moves it too) says
    // what it does in the strip under the list; and where the list is scrolled to is kept for a redraw.
    pane.addEventListener('mousemove', (ev) => {
        const row = ev.target.closest && ev.target.closest('.dr-pal-row.line:not([data-act])');
        const strip = row && pane.querySelector('.dr-pal-strip');
        if (!strip || strip.dataset.type === row.dataset.type) return;
        const def = ed.cards.get(row.dataset.type);
        if (!def) return;
        strip.dataset.type = row.dataset.type;
        strip.querySelector('b').textContent = def.title;
        strip.querySelector('p').textContent = def.desc || '';
    });
    pane.addEventListener('scroll', (ev) => {
        if (ev.target.classList && ev.target.classList.contains('dr-pal-list')) ed.palScroll = ev.target.scrollTop;
    }, true);
    // A random vehicle's model typed by its name: Enter adds it, as its Add does.
    pane.addEventListener('keydown', (ev) => {
        if (ev.key !== 'Enter' || !ev.target.classList || !ev.target.classList.contains('dr-carmodel-input')) return;
        ev.preventDefault();
        ev.stopPropagation();
        onAct('car-model-add', ev.target);
    });
    // An Interaction Menu's Under list, about to open: its choices by their text now (panels.js).
    pane.addEventListener('mousedown', (ev) => refreshMenuUnder(ed, ev.target), true);
    pane.addEventListener('focusin', (ev) => refreshMenuUnder(ed, ev.target));
    // A card dragged from the palette onto the grid.
    pane.addEventListener('mousedown', (ev) => {
        const row = ev.target.closest('.dr-pal-row:not([data-act])');
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
        // (On the page, or, in the world builder, where the Director's own screen is hidden: over everything.)
        (grid ? document.body : root).appendChild(palDrag.ghost);
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
    // The click that follows a drag must not add a second card.
    setTimeout(() => { palDrag = { moved: false }; }, 0);
    if (!d.moved) return;
    // Dropped on the grid (the page's, or the world builder's window): anywhere else adds nothing.
    const under = document.elementFromPoint(ev.clientX, ev.clientY);
    if (!under || !under.closest || under.closest('.dr-col') || !under.closest('.dr-canvas')) return;
    const def = ed.cards.get(d.type);
    if (def) addCard(def, canvas.toWorld(ev.clientX, ev.clientY), null);
}

// ============================================================
// Keys (one scope while the screen is up; a field keeps its own typing)
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
    // The tutorial's tour, showcase and stage list hold the page: its keys, none of the editor's.
    if (tutorialKey(ev)) return;
    const ctrl = ev.ctrlKey || ev.metaKey;
    const t = ev.target;
    const typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT');
    if (ed.page === 'editor' && ctrl && ev.key.toLowerCase() === 's') { ev.preventDefault(); save(); return; }
    if (typing) {
        if (ev.key === 'Escape') { ev.preventDefault(); t.blur(); }
        return;
    }
    // A list open (a boxed select's): its keys, none of the editor's (Backspace on one of its choices deleted the
    // card); Esc closes it.
    if (isDropdownOpen()) {
        if (ev.key === 'Escape') { ev.preventDefault(); closeDropdown(); }
        return;
    }
    if (ev.key === 'Escape') {
        ev.preventDefault();
        if (ed.page === 'editor' && ed.picker) { closePicker(); return; }
        if (ed.page === 'editor' && (ed.selected.size || ed.selectedLink || ed.selectedNote)) { ed.select([]); return; }
        // The full editor is the Blueprint window made big: Esc goes back to the world it came from.
        if (ed.page === 'editor' && !ed.demo) { toWorld(); return; }
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
// The tutorial's hands (tutorial.js)
// ============================================================
//
// Its tour and showcase open an example only to look at; what was open when they began comes back after as it
// was (a scenario, its unsaved changes, its undo, where the grid was). My first scenario makes its own (newScenario).

const KEPT = ['page', 'doc', 'key', 'scenario', 'baseRev', 'on', 'onRev', 'pack', 'editors', 'providers', 'history',
    'selected', 'selectedLink', 'selectedNote', 'worldOpen', 'revisions', 'lastTest', 'tab', 'homeTab', 'problems', 'problemList',
    'checkedAt', 'paletteQuery', 'palScroll', 'repeatOpen', 'picker', 'demo'];

function snapshot() {
    commitField();
    const s = { view: { ...canvas.view } };
    for (const k of KEPT) s[k] = ed[k];
    return s;
}

function restore(s) {
    replayToken++;
    for (const k of KEPT) ed[k] = s[k];
    canvas.view = { ...s.view };
    canvas.applyView();
    drawAll();
}

/** One of the examples, open only to look at: read-only (as a shipped one), never saved, the server
 *  asked for nothing but the file. Answers whether it opened. */
async function openDemo(name) {
    if (!(await loadCards())) return false;
    const r = await call('example', { name });
    if (!r.ok || !r.data.doc) return false;
    replayToken++;
    Object.assign(ed, { page: 'editor', demo: name, key: 'example_' + name, scenario: null, doc: normalise(r.data.doc),
        baseRev: 0, on: false, onRev: null, pack: 'the tutorial', editors: [], providers: null, worldOpen: null,
        revisions: null, lastTest: null, tab: 'cards', homeTab: 'cards', repeatOpen: {}, palScroll: 0, picker: null,
        selected: new Set(), selectedLink: null, selectedNote: null });
    ed.history = new History(ed.doc, (doc) => packed(doc));
    setProblems([]);
    drawAll();
    canvas.frame();
    return true;
}

/** A run played on the grid as a test's is (replay): the tutorial's "the way it goes when all goes right". */
function playFlow(trace) {
    ed.lastTest = readTrace({ trace, outcome: 'succeeded' });
    canvas.render();
    replay(trace);
}

function clearFlow() {
    replayToken++;
    if (!ed.lastTest) return;
    ed.lastTest = null;
    canvas.render();
}

// ============================================================
// The screen
// ============================================================

function build() {
    root = document.getElementById('director');
    root.className = 'dr-root';
    root.innerHTML = '<div class="dr-field-host"></div>'
        + '<div class="dr-col"><div class="dr-head"></div><div class="dr-bar tools"></div>'
        + `<div class="dr-tabs chips">${TABS.map((t) => `<button class="dr-tab" data-tab="${t.id}">${e(t.label)}</button>`).join('')}</div>`
        + '<div class="dr-body"></div><div class="dr-foot"></div></div>'
        // A card's page, on the right (drawSide); its X lets the card go, as Esc does.
        + '<div class="dr-side" hidden><div class="dr-side-head"><span class="dr-side-title">Card</span>'
        + `<button class="dr-icon" data-act="page-back" aria-label="Close" title="Close (Esc)">${ICON.close}</button></div>`
        + '<div class="dr-side-body"></div></div>'
        + '<div class="dr-dock"></div>'
        // The column away (its X): what brings it back, and what it would say (drawColHidden).
        + `<div class="dr-colback"><button class="dr-dock-btn dr-colback-btn" data-act="col-show" title="The card list, and the rest of the panel">${ICON.plus}Add card</button></div>`
        + '<div class="dr-colback-status"></div>';
    colEl = root.querySelector('.dr-col');
    sideEl = root.querySelector('.dr-side');
    canvas = new Canvas(root.querySelector('.dr-field-host'), ed);
    canvas.setStyle(cardStyle());
    // The variant buttons over the grid (drawVariants): in its host, so the Blueprint window carries them too.
    const strip = document.createElement('div');
    strip.className = 'dr-variants';
    strip.hidden = true;
    root.querySelector('.dr-field-host').appendChild(strip);
    strip.addEventListener('click', (ev) => {
        const a = ev.target.closest('[data-act]');
        if (!a || a.disabled) return;
        ev.stopPropagation();
        onAct(a.dataset.act, a);
    });
    strip.addEventListener('keydown', (ev) => {
        if (!ev.target.classList.contains('dr-var-input')) return;
        ev.stopPropagation();
        if (ev.key === 'Enter') finishRename(true);
        else if (ev.key === 'Escape') finishRename(false);
    });
    strip.addEventListener('focusout', (ev) => { if (ev.target.classList.contains('dr-var-input') && ed.variantRename) finishRename(true); });
    // (A search typed in the column with a card picked draws the card list again, not the card's page: the box is
    // kept in hand, and Backspace stays the search's.)
    bindPanel(colEl, () => colEl.querySelector('.dr-body'), renderColumn);
    bindPanel(sideEl, () => sideEl.querySelector('.dr-side-body'));
    // Every list the Director draws is whip's own (dropdown.js): here, and in the world builder's panels as each is
    // bound (builder.page / builder.cards). Not the whole page: whip's other screens change it all the time.
    watchSelects(root);
    for (const sel of ['.dr-dock', '.dr-colback']) {
        root.querySelector(sel).addEventListener('click', (ev) => {
            const a = ev.target.closest('[data-act]');
            if (a && !a.disabled) onAct(a.dataset.act, a);
        });
    }
    drawDock();
    initTutorial({
        ed, root: () => root, col: () => colEl, canvas: () => canvas, drawColumn,
        shown: () => shown && !away,
        snapshot, restore, openDemo, newScenario, playFlow, clearFlow,
        saveSeen: (bits) => nuiCallback('directorTutorial', { done: bits }),
    });
    root.addEventListener('contextmenu', (ev) => ev.preventDefault());
    // On a controller (pad.js): a circle that is the mouse, and the buttons beside it.
    initPad({
        root: () => root,
        shown: () => shown && !away,
        escape: () => onKey({ key: 'Escape', target: document.body, ctrlKey: false, metaKey: false, shiftKey: false,
                              preventDefault() {}, stopPropagation() {} }),
        fit: () => { if (ed.page === 'editor' && ed.doc) canvas.frame(ed.selected.size ? [...ed.selected] : null); },
        tab: (step) => {
            if (ed.page !== 'editor') return;
            commitField();
            // From a page, the tab under it counts as the one showing.
            const i = TABS.findIndex((t) => t.id === ed.homeTab);
            const next = TABS[(i + step + TABS.length) % TABS.length].id;
            // (A card's page on the right stays open: the column's tab changes under it.)
            if (sideOn()) ed.homeTab = next;
            else { ed.picker = null; ed.tab = next; }
            drawColumn();
        },
        pan: (dx, dy) => {
            if (ed.page !== 'editor' || !ed.doc) return;
            canvas.view.x += dx;
            canvas.view.y += dy;
            canvas.applyView();
        },
        zoomAt: (x, y, k) => { if (ed.page === 'editor' && ed.doc) canvas.zoomAt(x, y, canvas.view.z * k); },
        onGrid: (node) => !!(node && node.closest && node.closest('.dr-field-host')),
    });
    // (The emote menu up over this screen, for a step or a card to pick from: its keys and pad, not this page's.)
    NuiRouter.registerKeyScope({ name: 'director', priority: 15, isOpen: () => shown && !away && !emoteMenuUp(), onKey,
        onNav: padNav, analog: true, onAnalog: padAnalog, padHints });
}

function closeScreen() {
    commitField();
    closeSearch();
    closeAsk(null);
    hide();
    nuiCallback('directorClose');
}

function hide() {
    shown = false;
    away = false;
    padHide();
    if (root) root.classList.remove('open', 'away');
}

/** The page in sight (and the mouse's, as client/director.lua gave it). */
function showPage() {
    away = false;
    root.classList.remove('away');
    drawAll();
    if (framePending && ed.doc && !building) {
        framePending = false;
        canvas.frame();
    }
}

/** The screen: IN THE WORLD on a scenario (`d.world`, /whip's Edit: `d.openKey`), the page kept out of sight while it
 *  opens; or the editor as it was left (back from a test). */
export async function open(d) {
    // GTA's weapons this game has, for an NPC's weapon (client/director.lua).
    if (d && Array.isArray(d.weapons)) ed.weapons = d.weapons;
    if (!root) build();
    const world = !!(d && d.world === true);
    shown = true;
    away = world;
    root.classList.add('open');
    root.classList.toggle('away', world);
    if (!world) drawAll();
    await loadCards();
    const key = d && typeof d.openKey === 'string' ? d.openKey : null;
    const opening = !!key && key !== ed.key;
    if (opening) {
        // Another one open with changes not saved: the page shows to ask what becomes of them (kept, it stays open).
        if (ed.doc && !ed.demo && ed.history && ed.history.isDirty(ed.doc)) showPage();
        if (await letGo()) {
            const why = await openScenario(key);
            if (why && (ed.page !== 'editor' || !ed.doc || ed.demo)) {
                // Nothing to show instead (the Director off, the scenario gone): the screen closes, saying why.
                if (typeof window.uiNotify === 'function') window.uiNotify({ text: why, type: 'error', duration: 5000 });
                closeScreen();
                return;
            }
        }
    }
    // Back on the scenario it had open: closing the screen made the server forget it, so it is told
    // again (who is editing it, and its live runs' pulses).
    if (ed.page === 'editor' && ed.key && !ed.demo && !(opening && ed.key === key)) {
        call('watch', { key: ed.key, rev: ed.baseRev || 0 }).then((r) => {
            if (r.ok && Array.isArray(r.data.editors)) { ed.editors = r.data.editors; drawHead(); }
            // A lore character's ped changed in /whip while the screen was closed: their NPCs wear the new one, as
            // nothing of the builder's (not a step to undo, not a change to save).
            if (r.ok && r.data.lore && typeof r.data.lore === 'object' && ed.doc && !ed.demo) {
                ed.lore = listOf(r.data.lore);
                primeLorePortraits(ed.lore);
                let moved = false;
                ed.history.adopt(ed.doc, (doc) => { moved = loreAsNowAll(doc); });
                if (moved) { drawColumn(); builderSync(); }
            }
        });
    }
    if (world && ed.page === 'editor' && ed.doc && !ed.demo) {
        openBuilder(null);
        tutorialOpened(d, false);
        return;
    }
    showPage();
    if (ed.page === 'editor' && !ed.doc.nodes.length) canvas.frame();
    // The first time on this PC: the tutorial's first stage, by itself (on the page, not in the world).
    tutorialOpened(d, true);
}

/** Everything else client/director.lua says (through director-loader.js). */
export function message(d) {
    if (!root) return;
    switch (d.action) {
        case 'directorClose':
            // (Out of the world builder by its Exit: what Configure made for things it threw away goes with them.)
            builderLeft();
            closeSearch();
            closeAsk(null);
            hide();
            break;
        case 'directorHide':
            away = true;
            padHide();
            root.classList.add('away');
            break;
        case 'directorShow':
            builderLeft();
            // Back from a take recorded in the world builder: straight into it again, on the car, the screen kept
            // out of the way (client/director_takes.lua).
            if (typeof d.reopen === 'string' && ed.page === 'editor' && ed.doc && findWorld(ed.doc, d.reopen)) {
                ed.recordAfter = null;
                openBuilder(d.reopen, true);
                break;
            }
            // Another variant picked in the world builder: its Done has written the world, now the switch, and the
            // builder again where the camera was, on that variant's things.
            if (ed.variantAfter) {
                const v = ed.variantAfter;
                ed.variantAfter = null;
                if (ed.page === 'editor' && ed.doc) {
                    switchVariant(v);
                    openBuilder(null, true);
                    break;
                }
            }
            // Record a take was pressed in the world builder: its Done has written the world, now the drive, the screen
            // kept out of the way meanwhile (one that cannot start opens the builder again: client/director_takes.lua).
            if (ed.recordAfter) {
                const w = ed.doc && findWorld(ed.doc, ed.recordAfter);
                ed.recordAfter = null;
                if (w && recordTake(w, true)) break;
            }
            // An NPC's character editor opened in the world builder: its Done has written the world, now the editor.
            if (ed.lookAfter) {
                const w = ed.doc && findWorld(ed.doc, ed.lookAfter);
                ed.lookAfter = null;
                if (w && ed.page === 'editor') { editLook(w, true); break; }
            }
            // Another resource's button that takes over, pressed in the world builder: its Done has written the world,
            // now the press (the Director steps aside, and the builder opens on the thing again once it is over).
            if (ed.pressAfter) {
                const pa = ed.pressAfter;
                ed.pressAfter = null;
                const b = ed.buttons.find((x) => x.id === pa.button);
                // (A card's list: the card's thing, pressed from the builder.)
                const n = pa.card && ed.doc ? findNode(ed.doc, pa.card) : null;
                const def = n && ed.cards.get(n.type);
                const f = def && (def.props || []).find((p) => p.key === pa.field);
                if (n && f && b) {
                    nuiCallback('directorButtonPress', { button: b.id, builder: true, thing: cardThing(n, def, f, pa.i) })
                        .then((r) => { if (r && r.ok === false) status(r.why || `${b.label} did not work`, 'error'); });
                    break;
                }
                const w = ed.doc && pa.id && findWorld(ed.doc, pa.id);
                if (w && b) { sendPress(w, b, true, pa.model); break; }
            }
            showPage();
            // The full editor the first time on this PC: the tutorial's first stage, by itself.
            tutorialOpened(null, true);
            break;
        // Recording a take (client/director_takes.lua): what is on screen meanwhile, and the take once saved.
        case 'directorRec':
            recHud(d);
            break;
        case 'directorTakeSaved': {
            const w = ed.doc && findWorld(ed.doc, d.car);
            if (!w || !Number.isFinite(Number(d.id))) break;
            if (!Array.isArray(w.def.takes)) w.def.takes = [];
            const take = { id: Number(d.id), label: 'Driving event ' + (w.def.takes.length + 1), ms: Number(d.ms) || 0, made: Date.now() };
            // Its trailers, when it hitched one: each one's own movement (a take of its own), and when it was on.
            const tow = d.tow && typeof d.tow === 'object' && d.tow.tracks && typeof d.tow.tracks === 'object' ? d.tow : null;
            if (tow) {
                const tracks = {};
                for (const [wid, id] of Object.entries(tow.tracks)) if (Number(id) > 0 && findWorld(ed.doc, wid)) tracks[wid] = Number(id);
                const events = listOf(tow.events)
                    .filter((e) => e && tracks[e.w] && Number.isFinite(Number(e.t)))
                    .map((e) => ({ t: Math.max(0, Math.round(Number(e.t))), w: e.w, on: e.on === true }));
                if (Object.keys(tracks).length) take.tow = { tracks, events };
            }
            w.def.takes.push(take);
            // What plays one of the car's takes with none picked, or one it no longer has (removed), plays this one.
            let filled = 0;
            for (const r of takeRefsOf(w)) {
                if (!w.def.takes.some((t) => String(t.id) === String(r.at[r.key]))) { r.at[r.key] = take.id; filled++; }
            }
            ed.tab = 'world';
            ed.worldOpen = w.id;
            ed.takeOpen = w.id + '#' + d.id;
            ed.changed();
            status(filled ? 'Driving event saved, and picked in the task or card that had none: Save the scenario to keep it'
                : 'Driving event saved: Save the scenario to keep it on the car', 'ok');
            break;
        }
        case 'directorPlaceRefused':
            builderGone();
            status(d.why || 'That cannot be placed', 'error');
            break;
        // Isolate world went on or off from the server's side (the button's own answer says so too).
        case 'directorIsolated':
            ed.isolated = d.on === true;
            drawDock();
            if (!ed.isolated) status('Back in the shared world', 'ok');
            break;
        // Other resources' buttons (client/director_buttons.lua): the list moved; one of them saved data on a thing.
        case 'directorButtonsChanged':
            ed.buttons = readButtons(d.buttons);
            if (ed.page === 'editor' && ed.worldOpen) redrawWhenFree();
            if (building) window.dispatchEvent(new Event('director-buttons'));
            break;
        case 'directorThingData':
            thingData(d);
            break;
        // A freemode NPC's look, made in the character editor (client/director.lua directorEditLook): kept on it as an
        // edit, its ped the look's, the Outfit's own parts gone (the look has its clothes). `why`: it did not open.
        case 'directorLookMade': {
            if (d.why) { status(d.why, 'error'); break; }
            const w = ed.doc && typeof d.id === 'string' ? findWorld(ed.doc, d.id) : null;
            const look = d.look && typeof d.look === 'object' && FREEMODE.has(d.look.model) ? d.look : null;
            if (!w || w.kind !== 'npc' || !look) break;
            w.def.look = look;
            w.def.model = look.model;
            delete w.def.outfit;
            ed.changed();
            status('Its look is made: Save the scenario to keep it', 'ok');
            break;
        }
        // Done in the world builder (client/director.lua): the scenario's props as it left them.
        case 'directorBuilt':
            if (d.stay === true) saveBuilt(d.things, d.took, d.auto === true);   // its Save: it stays open
            else applyBuilt(d.things, d.took);
            // (The builder's Test: its set is in, so the test plays it.)
            if (d.stay !== true && testAfterBuilt) {
                testAfterBuilt = false;
                setTimeout(test, 0);
            }
            break;
        // A task's point just put down in the world builder: where, so its page says it is placed (Done
        // writes where it ends up).
        case 'directorPointPlaced': {
            const p = pointOf(d.id);
            const c = d.coords;
            if (!p || !c || typeof c.x !== 'number' || p.s.at) break;
            p.s.at = { x: +c.x.toFixed(3), y: +c.y.toFixed(3), z: +c.z.toFixed(3), heading: +(c.heading || 0).toFixed(1) };
            ed.changed();
            break;
        }
        // A route put down in the world builder (its marker becomes its point 1), and a route's point or a group's spot
        // removed there (the rest numbered again at once).
        case 'directorRoutePlaced':
            routePlaced(Number(d.index), d.coords);
            break;
        // Anything else put down in the world builder (client/furnish_builder.lua FurnishBuilder.placed): the scenario
        // has it at once, so every card's picker lists it before a Save; and one taken out again since the last Save.
        case 'directorThingPlaced': {
            const id = builder.adopt({ kind: d.kind, model: d.model, label: d.label, lore: d.lore, random: d.random === true,
                                       weapon: d.weapon, coords: d.coords });
            if (id && Number.isInteger(d.index)) nuiCallback('directorBuilderId', { index: d.index, id });
            break;
        }
        case 'directorThingRemoved':
            if (building && ed.doc && typeof d.id === 'string' && builderAdopted.delete(d.id)) {
                ed.doc.world = ed.doc.world.filter((w) => w.id !== d.id);
                if (builderSent) builderSent.delete(d.id);
                if (ed.worldOpen === d.id) ed.worldOpen = null;
                ed.changed();
            }
            break;
        // An emote clicked in the emote menu opened for a step (task-emote-pick): that step plays it.
        case 'directorEmotePicked': {
            const f = ed.emoteFor;
            // For a card's field (card-emote-pick): written there.
            if (f && f.node) {
                const n = ed.doc && findNode(ed.doc, f.node);
                if (!n || typeof d.cmd !== 'string' || !d.cmd) break;
                n.props[f.k] = d.cmd.slice(0, 40);
                ed.changed();
                break;
            }
            const w = f && ed.doc && findWorld(ed.doc, f.id);
            const s = w && tasksOf(w).list.find((x) => x.k === f.k);
            if (!s || typeof d.cmd !== 'string' || !d.cmd) break;
            s.by = 'emote';
            s.emote = d.cmd.slice(0, 40);
            ed.changed();
            break;
        }
        // A point moved in the world builder (once it stops): its step, route point or spot is there now, so Play Tasks
        // (and anything else read from the scenario) goes where it stands, not where it was when last saved.
        case 'directorPointMoved': {
            const p = pointOf(d.id);
            const c = d.coords;
            if (!p || !c || typeof c.x !== 'number') break;
            const at = { x: +c.x.toFixed(3), y: +c.y.toFixed(3), z: +c.z.toFixed(3), heading: +(Number(c.heading) || 0).toFixed(1) };
            const was = p.s.at;
            if (was && was.x === at.x && was.y === at.y && was.z === at.z && was.heading === at.heading) break;
            p.s.at = at;
            ed.changed();
            break;
        }
        case 'directorPointRemoved':
            if (typeof d.id === 'string') pointRemoved(d.id);
            break;
        // The world builder's preview: playing, played to its end, or stopped; a note (a step it does not play).
        case 'directorPreviewState': {
            const prev = ed.preview || {};
            if (d.state === 'note') ed.preview = { ...prev, note: d.note || null };
            else ed.preview = { state: d.state, ids: listOf(d.ids), note: d.note || (d.state === 'playing' ? prev.note : null) };
            if (building) redrawWhenFree();
            break;
        }
        // The test window (testwin.js): on and off with the test, its mouse, and the run's steps as they come.
        case 'directorTestWindow':
        case 'directorTestFlow':
            testWindowMessage(d, ed, cardStyle());
            break;
        case 'directorTestDone': {
            if (!ed.doc) break;
            ed.lastTest = readTrace(d);
            ed.tab = 'check';
            canvas.render();
            drawColumn();
            const o = ed.lastTest.outcome;
            const bad = ed.lastTest.badNodes.size;
            if (o === 'succeeded' && bad) {
                status(`The test succeeded, but ${bad === 1 ? 'a card' : bad + ' cards'} could not do ${bad === 1 ? 'its' : 'their'} work: red on the grid (Check says why)`, 'error');
            } else {
                status(o === 'succeeded' ? 'The test succeeded: what ran is lit up' : 'Test over: what ran is lit up (Check has the steps)',
                    o === 'succeeded' ? 'ok' : '');
            }
            replay(listOf(d.trace));
            break;
        }
        // A live run of the scenario open here went on (client/director.lua, hub.lua live pulses).
        // Another resource added, changed or took away cards: the palette and the grid as they are now.
        case 'directorCardsChanged':
            if (d.rev === ed.cardsRev) break;
            loadCards(true).then((ok) => { if (ok && shown) redrawWhenFree(true); });
            break;
        case 'directorPulse': {
            if (ed.page !== 'editor' || !ed.doc || d.key !== ed.key) break;
            // (Only the open variant's: another's cards share their ids.)
            const open = openVariant();
            const steps = listOf(d.steps).filter((s) => s && (s.variant || 'v1') === open);
            // Each card once a batch (a busy run sends the same one over and over): its latest step.
            const latest = new Map();
            for (const s of steps) if (s && typeof s.node === 'string' && (s.kind === 'enter' || s.kind === 'skipped' || s.kind === 'resume')) latest.set(s.node, s);
            for (const s of latest.values()) pulseStep(s);
            break;
        }
        default:
            break;
    }
}
