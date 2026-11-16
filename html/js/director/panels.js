// Director editor column: the tabs and the pages over them.
//   Cards      the palette: search, the card types by kind; click to add, or drag onto the grid
//   World      the scenario's placed things (NPCs, item spots); one opens as a page with Place in world
//   Variables  the run's variables
//   Settings   name, how a run starts, limits, and the saved revisions
// Two pages open over whichever tab is showing (ed.tab names the page, ed.homeTab the tab under it):
//   card       the selected card's fields, drawn from its type (server/director/nodes*.lua props)
//   check      the server's check of the document, the last test, and switching it on
// Each tab is HTML drawn from the document; a field names what it edits with data attributes (data-t = which object,
// data-k = which key, data-f = how to read it), so one delegated listener in app.js handles every field. A typed
// change updates the document at once and is committed to undo when the field is left; a choice is committed at once.

import { escapeHtml, propImageUrl, vehicleImageUrl, pedImageUrl, itemImageUrl } from '../utils.js';
import { plural, dateTime, clock, money } from '../wp/format.js';
import { GLYPHS } from '../furnisher-data.js';
import { uiIcon, ICON_PATH } from '../ui-icons.js';
import { getItemDefs } from '../core/item-defs.js';
import { groupCards } from './search.js';
import { findNode, findWorld, usesOfWorld, usesOfVar, problemCards, variantList } from './doc.js';
import { pinLabel, pinsOf, couldNot } from './canvas.js';
import { holds, whenKeys } from './when.js';
import { thingIs } from './things-data.js';
import { GROUP, groupName, groupOfThing } from './refs.js';

const e = escapeHtml;

// (How a run starts, its limits, its name: the Scenario Enabled card's page, scenarioSettings.)
export const TABS = [
    { id: 'cards', label: 'Cards' },
    { id: 'world', label: 'World' },
    { id: 'vars', label: 'Variables' },
];

/** Is this one of the tabs (not a page over one)? */
export const isTab = (id) => TABS.some((t) => t.id === id);

/** The column's icons: 24x24, drawn in currentColor. */
const svg = (d, w) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${w || 2.2}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
export const ICON = {
    back: svg(ICON_PATH.back, 2.4),
    close: svg(ICON_PATH.close),
    undo: svg('<path d="M9 14L4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>'),
    redo: svg('<path d="M15 14l5-5-5-5"/><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13"/>'),
    plus: svg(ICON_PATH.plus, 2.4),
    search: svg('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    bin: svg('<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12h10l1-12M9 7V4h6v3"/>', 2),
    open: svg(ICON_PATH.forward, 2.4),
    box: svg('<path d="M4 8l8-4 8 4v8l-8 4-8-4z"/><path d="M4 8l8 4 8-4M12 12v8"/>', 1.8),
    gear: svg('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>', 1.8),
};

/** The way back at a page's top, to the tab under it (`act` says which). */
function backRow(ed, act, to) {
    // (In the world builder's panel, or the full editor's on the right, there is no tab to go back to: the panel's own
    // close is the way out.)
    if (ed.inBuilder || ed.sidePage) return '';
    const tab = TABS.find((t) => t.id === (to || ed.homeTab)) || TABS[0];
    return `<button class="dr-back" data-act="${act}">${ICON.back}${e(tab.label)}</button>`;
}

/** A group of fields' head. */
const groupHead = (text) => `<div class="dr-group">${e(text)}</div>`;

// (A route is walked by its Tasks: Walk a Route. app.js routeIdleAsTask moves an older "Walks a route" there.)
const BEHAVIOURS = [['stand', 'Stands still'], ['guard', 'Guards its spot']];
const VAR_TYPES = [['text', 'Text'], ['number', 'Number'], ['bool', 'Yes / no']];

// ---- field builders ----

function label(text, hint) {
    return `<div class="dr-label">${e(text)}${hint ? `<span>${e(hint)}</span>` : ''}</div>`;
}

/** How many lines a big text box needs for `text`: at least `least` (its own rows), at most eight, so what is
 *  written shows whole and no line is cut in half by the box's edge (app.js grows it as it is typed into). */
export function growRows(text, least) {
    const lines = String(text || '').split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(l.length / 44)), 0);
    return Math.max(least, Math.min(8, lines));
}

/** A text box. `big` makes it a box of `rows` lines (three) that grows with its text. */
function textField(t, k, value, o = {}) {
    const attrs = `data-t="${e(t)}" data-k="${e(k)}" data-f="text"${o.max ? ` maxlength="${o.max}"` : ''}`
        + ` placeholder="${e(o.placeholder || '')}" spellcheck="false"`;
    const v = value === undefined || value === null ? '' : String(value);
    const least = Math.max(2, Math.min(6, o.rows || 3));
    const box = o.big
        ? `<textarea class="dr-field" rows="${growRows(v, least)}" data-grow="${least}" ${attrs}>${e(v)}</textarea>`
        : `<input class="dr-field" type="text" value="${e(v)}" ${attrs}>`;
    return `<div class="dr-row">${label(o.label || k, o.hint)}${box}</div>`;
}

function numberField(t, k, value, o = {}) {
    const v = typeof value === 'number' ? String(value) : '';
    return `<div class="dr-row">${label(o.label || k, o.hint)}<input class="dr-field" type="number" value="${e(v)}"`
        + ` data-t="${e(t)}" data-k="${e(k)}" data-f="number"${o.min !== undefined ? ` min="${o.min}"` : ''}`
        + `${o.max !== undefined ? ` max="${o.max}"` : ''} placeholder="${e(o.placeholder || '')}"></div>`;
}

/** A length of time, saved in seconds: a box a unit, its number and its letter ("8h", "42m", "5s"), typed, or picked
 *  from its list (its chevron: app.js dhms-pick, dropdown.js). writeField 'dhms' adds the boxes up. `fallback`: what an
 *  empty one runs at (shown greyed). `units: 'hms'`: no days box, its hours counting them all (a task's time). Kept to
 *  a tenth of a second (a 0.4 s Slide To shown as 0 was saved as 0 once touched: WLVF's review); the seconds box takes
 *  "0.4" and "59.5". */
function timeField(t, k, value, o = {}) {
    const total = typeof value === 'number' && value >= 0 ? Math.round(value * 10) / 10 : null;
    const shown = total === null ? (o.fallback || 0) : total;
    const secs = +(shown % 60).toFixed(1);
    const parts = o.units === 'hms'
        ? [['h', 'hours', Math.floor(shown / 3600)], ['m', 'minutes', Math.floor(shown % 3600 / 60)], ['s', 'seconds', secs]]
        : [['d', 'days', Math.floor(shown / 86400)], ['h', 'hours', Math.floor(shown % 86400 / 3600)],
            ['m', 'minutes', Math.floor(shown % 3600 / 60)], ['s', 'seconds', secs]];
    const boxes = parts.map(([p, word, n]) => `<div class="dr-dhms-box"><input class="dr-dhms-in" type="text"`
        + ` inputmode="${p === 's' ? 'decimal' : 'numeric'}" maxlength="${p === 's' ? 4 : 3}"`
        + ` value="${total === null ? '' : n}" placeholder="${n}" data-t="${e(t)}" data-k="${e(k)}" data-f="dhms" data-part="${p}"`
        + ` aria-label="${word}" spellcheck="false"><span class="dr-dhms-u">${p}</span>`
        + `<button class="dr-dhms-dd" type="button" data-act="dhms-pick" data-part="${p}" aria-label="Pick ${word}">`
        + '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICON_PATH.down + '</svg></button></div>').join('');
    return `<div class="dr-row">${label(o.label || k, o.hint)}<div class="dr-dhms${o.units === 'hms' ? ' hms' : ''}">${boxes}</div></div>`;
}

/** A time box's list (dhms-pick): its unit's usual values, the one in it among them. */
export function dhmsChoices(part, now) {
    const step = (to, by) => Array.from({ length: Math.floor(to / by) + 1 }, (_, i) => i * by);
    const values = part === 'd' ? [0, 1, 2, 3, 4, 5, 6, 7, 14, 30] : part === 'h' ? step(23, 1) : step(55, 5);
    const n = Number(now);
    if (Number.isFinite(n) && n >= 0 && !values.includes(n)) { values.push(n); values.sort((a, b) => a - b); }
    return values.map((v) => ({ value: String(v), label: v + part }));
}

/** Segmented keys: [[value, text], ...]. The value is written as given (true/false stay booleans).
 *  `inline`: on its label's line (a two-way choice with no hint). */
function segField(t, k, value, options, o = {}) {
    const keys = options.map(([v, text]) => {
        const on = v === value || (value === undefined && v === o.fallback);
        return `<button class="dr-seg-key${on ? ' on' : ''}" data-t="${e(t)}" data-k="${e(k)}" data-v="${e(JSON.stringify(v))}">${e(text)}</button>`;
    }).join('');
    return `<div class="dr-row${o.inline && !o.hint ? ' inline' : ''}">${label(o.label || k, o.hint)}<div class="dr-seg">${keys}</div></div>`;
}

/** A yes or no: /w's switch on its label's line, the whole row pressed to flip it. It carries the value a
 *  press writes (data-v), as a segmented key does, so app.js writes it the same way (writeSeg). */
function switchField(t, k, value, o = {}) {
    const on = value === true || (value === undefined && o.fallback === true);
    return `<button class="dr-sw" role="switch" aria-checked="${on}" data-t="${e(t)}" data-k="${e(k)}" data-v="${on ? 'false' : 'true'}">`
        + `<span class="dr-sw-name">${e(o.label || k)}${o.hint ? `<small>${e(o.hint)}</small>` : ''}</span>`
        + `<span class="dr-switch${on ? ' on' : ''}"></span></button>`;
}

/** A choice: [[value, text, { pic, sub }?], ...]; the list (dropdown.js) shows an option's picture and a line under it. */
function selectField(t, k, value, options, o = {}) {
    const extra = (x) => (x && x.pic ? ` data-pic="${e(x.pic)}"` : '') + (x && x.sub ? ` data-sub="${e(x.sub)}"` : '');
    // (`noEmpty`: a field with a default has no empty choice: its default is one of its choices, shown picked.)
    const opts = (o.noEmpty ? [] : [`<option value="">${e(o.none || '— pick one —')}</option>`])
        .concat(options.map(([v, text, x]) => `<option value="${e(v)}"${v === value ? ' selected' : ''}${extra(x)}>${e(text)}</option>`));
    if (value && !options.some(([v]) => v === value)) opts.push(`<option value="${e(value)}" selected>${e(value)} (missing)</option>`);
    return `<div class="dr-row">${label(o.label || k, o.hint)}<select class="dr-field" data-t="${e(t)}" data-k="${e(k)}" data-f="select">${opts.join('')}</select></div>`;
}

// ---- icons: one of whip's glyphs (js/glyphs.js), the prompts' and the objective card's ----

/** The glyphs made for the Director's own cards, shown first; then every other one the prompts wear. */
const DIRECTOR_GLYPHS = ['objective', 'target', 'pin', 'star', 'timer', 'success', 'fail', 'info', 'warning', 'ped', 'object', 'camera'];
const glyphTable = () => (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
const glyphWord = (name) => name.replace(/_/g, ' ');

/** An icon: the one picked (else the default's, else none) and Change; open, every glyph to pick from, the
 *  Director's own first. A pick is a segmented key's (app.js writeSeg): written, and the page drawn again. */
function glyphField(ed, t, k, value, o = {}) {
    const all = glyphTable();
    const now = typeof value === 'string' && value !== '' ? value : (o.fallback || '');
    // (None: a prompt's key, E; `noneText` says it for a field where none is nothing at all, a marker's symbol.)
    const none = o.noneText || 'None: the key';
    const shown = all[now] ? `<span class="dr-glyph-now" title="${e(glyphWord(now))}">${all[now]}</span>`
        : `<span class="dr-glyph-now none">${o.noneText ? '–' : 'E'}</span>`;
    const word = now ? glyphWord(now) + (value ? '' : ' (its default)') : none;
    let html = `<div class="dr-row">${label(o.label || k)}<div class="dr-glyph-row">${shown}<span class="dr-glyph-word">${e(word)}</span>`
        + `<button class="dr-btn ghost" data-act="glyph-open" data-t="${e(t)}" data-k="${e(k)}">${o.open ? 'Done' : 'Change'}</button></div></div>`;
    if (!o.open) return html;
    const key = (name) => `<button class="dr-seg-key dr-glyph-key${name === now ? ' on' : ''}" data-t="${e(t)}" data-k="${e(k)}"`
        + ` data-v="${e(JSON.stringify(name))}" title="${e(glyphWord(name))}" aria-label="${e(glyphWord(name))}">${all[name]}</button>`;
    const mine = DIRECTOR_GLYPHS.filter((n) => all[n]);
    const rest = Object.keys(all).filter((n) => !DIRECTOR_GLYPHS.includes(n) && n !== 'back');
    html += '<div class="dr-glyphs">'
        + (o.fallback ? '' : `<button class="dr-seg-key dr-glyph-key dr-glyph-none${now ? '' : ' on'}" data-t="${e(t)}" data-k="${e(k)}" data-v='""' title="${e(none)}">${o.noneText ? '–' : 'E'}</button>`)
        + mine.map(key).join('') + '</div>'
        + '<div class="dr-glyph-head">Prompts\' icons</div>'
        + '<div class="dr-glyphs">' + rest.map(key).join('') + '</div>';
    return html;
}

// ---- several placed things on one card (kind 'worlds': Spawn NPC's NPCs, Spawn Car's cars, Start Tasks' things) ----

/** The things a 'worlds' field holds: its list, each once. */
export function worldsOf(node, k) {
    const out = [];
    // (One id: a card that held one, as saved before its upgrade.)
    const raw = node.props[k];
    for (const v of Array.isArray(raw) ? raw : typeof raw === 'string' && raw ? [raw] : []) {
        if (typeof v === 'string' && v && !out.includes(v)) out.push(v);
    }
    return out;
}

/** Can Start Tasks start this one's tasks (server/director/nodes_tasks.lua hasTasks): an NPC, car or prop with a list,
 *  that a run makes (a standing car's too). */
function startable(w) {
    if (w.kind !== 'npc' && w.kind !== 'vehicle' && w.kind !== 'prop') return false;
    if (w.layer === 'standing' && w.kind !== 'vehicle') return false;
    return tasksOf(w).list.length > 0;
}

/** Each thing its own row (its picture, name, ped, Open for its page, and out of the list), then a list of the
 *  World tab's ones not in it to add (a new one is made there, never here). A list of whose tasks (`withTasks`)
 *  offers only the things with tasks it can start, of any kind. */
function worldsField(ed, node, f, lab) {
    const ids = worldsOf(node, f.key);
    const tasks = f.withTasks === true;
    const kind = f.worldKind || (tasks ? '' : 'npc');
    const car = kind === 'vehicle';
    const word = kind === 'npc' ? 'NPC' : car ? 'car' : 'thing';
    // (What its page sets: an NPC's ped, a car's model; the open button's tooltip says the same.)
    const sets = car ? 'model, plate, key and tasks' : 'ped, weapon and tasks';
    const say = tasks ? (ids.length > 1 ? `${ids.length}, all started at once` : 'each one\'s list is on its page (Tasks)')
        : ids.length > 1 ? `${ids.length}, each its own` : `its page sets its ${sets}`;
    let html = `<div class="dr-row">${label(lab, say)}</div>`;
    for (const id of ids) {
        const w = findWorld(ed.doc, id);
        if (!w) {
            html += `<div class="dr-item"><div class="dr-item-head"><div class="dr-item-main"><b>${e(id)}</b><span>Not in the World tab any more</span></div>`
                + `<button class="dr-btn ghost" data-act="worlds-remove" data-id="${e(node.id)}" data-k="${e(f.key)}" data-w="${e(id)}">Take out</button></div></div>`;
            continue;
        }
        const placed = w.def && w.def.coords && typeof w.def.coords.x === 'number';
        const n = tasksOf(w).list.length;
        const pool = car && w.def && w.def.random ? (Array.isArray(w.def.models) ? w.def.models.length : 0) : -1;
        const model = pool >= 0 ? `a pool of ${plural(pool, 'model')}`
            : w.def && w.def.model ? w.def.model : car ? 'No model yet' : 'No ped yet';
        const sub = (tasks ? [n ? plural(n, 'task') : 'no tasks yet', w.def && w.def.model ? w.def.model : null]
            : [model]).concat([placed ? null : 'not placed']).filter(Boolean).join(' · ');
        html += '<div class="dr-item dr-worlds-row"><div class="dr-item-head">' + worldArt(w)
            + `<div class="dr-item-main"><b>${e(w.label || w.id)}</b><span>${e(sub)}</span></div>`
            + `<button class="dr-icon-btn" data-act="card-world-open" data-id="${e(w.id)}" title="Its page: ${e(tasks ? 'tasks' : sets)}" aria-label="Open ${e(w.label || w.id)}">${ICON.open}</button>`
            + `<button class="dr-icon-btn danger" data-act="worlds-remove" data-id="${e(node.id)}" data-k="${e(f.key)}" data-w="${e(w.id)}"`
            + ` title="Take it off this card (it stays in the World tab)" aria-label="Take ${e(w.label || w.id)} off this card">${ICON.close}</button></div></div>`;
    }
    const free = ed.doc.world.filter((w) => (!kind || w.kind === kind) && (!tasks || startable(w)) && !ids.includes(w.id));
    const full = f.max && ids.length >= f.max;
    if (!full && free.length) {
        html += '<div class="dr-row"><select class="dr-field" data-add-to="' + e(node.id + '|' + f.key) + '" aria-label="Add one">'
            + `<option value="">+ Add ${tasks ? `${ids.length ? 'another' : 'one'} with tasks` : `${ids.length ? 'another' : 'an'} ${word}`} from the World tab</option>`
            + free.map((w) => `<option value="${e(w.id)}">${e(w.label || w.id)}${w.layer === 'standing' ? ' (standing)' : ''}</option>`).join('')
            + '</select></div>';
    }
    if (tasks) {
        if (!full && !free.length) {
            html += `<div class="dr-hint">${ids.length ? 'Everything with tasks is on it.' : 'Nothing has tasks yet.'}`
                + ' Only an NPC, car or prop with tasks (its page: Tasks) can go on this card.</div>';
        }
    } else if (!full && !ed.inBuilder && !free.length) {
        // (A new one is made in the World tab, never from here: the New NPC button went, Josh, 10 Nov 2026.)
        html += `<div class="dr-hint">A new ${word}: place it in the World tab, then add it here.</div>`;
    } else if (!full && ed.inBuilder) {
        html += `<div class="dr-hint">A new ${word}: place it from ${kind === 'npc' ? 'NPCs' : car ? 'Vehicles' : 'the tabs'} on the left, then add it here.</div>`;
    }
    if (full) html += `<div class="dr-hint">${f.max} at most on one card.</div>`;
    return html;
}

/** Several placed things and named groups on an event or action card (a 'worlds' field with `groups`: Car Entered's cars,
 *  All Killed's NPCs): each one picked on a line of its own (X takes it off the card), then a list to add another of the
 *  field's kind, or a group (every one of that kind whose page's Group it is). */
function thingsField(ed, node, f, lab) {
    const v = worldsOf(node, f.key);
    const kind = f.worldKind || '';
    const noun = kind ? thingIs(kind, 'noun') || 'thing' : 'thing';
    const many = (n) => plural(n, noun);
    const ofKind = ed.doc.world.filter((w) => !kind || w.kind === kind);
    const members = (g) => ofKind.filter((w) => groupOfThing(w) === g);
    let html = `<div class="dr-row">${label(lab, f.hint || '')}</div>`;
    for (const x of v) {
        const g = groupName(x);
        const w = g ? null : findWorld(ed.doc, x);
        const name = g ? `Group: ${g}` : w ? w.label || w.id : x;
        const sub = g ? (members(g).length ? `${many(members(g).length)} in it` : 'Nothing is in it now') : w ? '' : 'Not in the World tab any more';
        const art = w ? worldArt(w) : `<span class="dr-world-art dr-world-glyph">${GLYPHS[KIND_GLYPH[kind] || 'box'] || ''}</span>`;
        html += `<div class="dr-item dr-worlds-row"><div class="dr-item-head">${art}`
            + `<div class="dr-item-main"><b>${e(name)}</b>${sub ? `<span>${e(sub)}</span>` : ''}</div>`
            + `<button class="dr-icon-btn danger" data-act="worlds-remove" data-id="${e(node.id)}" data-k="${e(f.key)}" data-w="${e(x)}"`
            + ` title="Take it off this card" aria-label="Take ${e(name)} off this card">${ICON.close}</button></div></div>`;
    }
    const free = ofKind.filter((w) => !v.includes(w.id));
    const groups = [...new Set(ofKind.map(groupOfThing).filter(Boolean))].filter((g) => !v.includes(GROUP + g)).sort();
    if (free.length || groups.length) {
        const things = kind === 'npc' ? 'NPCs' : noun.charAt(0).toUpperCase() + noun.slice(1) + 's';
        html += `<div class="dr-row"><select class="dr-field" data-add-to="${e(node.id + '|' + f.key)}" aria-label="Add one">`
            + `<option value="">+ Add ${v.length ? 'another' : `a${/^[aeiou]/i.test(noun) ? 'n' : ''} ${noun}`}${groups.length ? ' or a group' : ''}</option>`
            + (groups.length ? `<optgroup label="Groups">${groups.map((g) => `<option value="${e(GROUP + g)}">Group: ${e(g)} (${members(g).length})</option>`).join('')}</optgroup>` : '')
            + (free.length ? `<optgroup label="${e(things)}">${free.map((w) => `<option value="${e(w.id)}">${e(w.label || w.id)}</option>`).join('')}</optgroup>` : '')
            + '</select></div>';
    } else if (!v.length) {
        html += `<div class="dr-hint">Place ${/^[aeiou]/i.test(noun) ? 'an' : 'a'} ${e(noun)} in the World tab first.</div>`;
    }
    return html;
}

// ---- trying a card here: its ring, its bar, how its card and its prompt look (app.js try-*) ----

// ---- Create Container: its slots, laid out as the inventory shows them (lootEditor) ----
//
// node.props.loot: { slot, item, min, max, chance } each, a slot's chances 100% at most; what is left is the slot
// empty (server/director/nodes_heist.lua rollLoot rolls each slot once). ed.lootSel: { node, slot } picked here;
// ed.lootSim: { node, items } a roll shown in place of the layout (Simulate randomness).

/** What a slot may hold, most likely first: [{ e, i }] (i: its place in the list, for its fields' address). */
function lootOf(node, slot) {
    const list = Array.isArray(node.props.loot) ? node.props.loot : [];
    return list.map((x, i) => ({ e: x, i })).filter((x) => x && x.e && Number(x.e.slot) === slot)
        .sort((a, b) => (Number(b.e.chance) || 100) - (Number(a.e.chance) || 100));
}

/** One roll of every slot, as the server rolls them: [slot] = { item, amount }. */
export function rollLoot(loot, slots) {
    const out = {};
    const by = {};
    for (const x of Array.isArray(loot) ? loot : []) {
        const s = Number(x && x.slot);
        if (s >= 1 && s <= slots && x.item) (by[s] = by[s] || []).push(x);
    }
    for (const s of Object.keys(by)) {
        const r = 1 + Math.floor(Math.random() * 100);
        let upTo = 0;
        for (const x of by[s]) {
            upTo += Number(x.chance) || 100;
            if (r <= upTo) {
                const mn = Math.max(1, Math.floor(Number(x.min) || 1)), mx = Math.max(mn, Math.floor(Number(x.max) || mn));
                out[s] = { item: x.item, amount: mn + Math.floor(Math.random() * (mx - mn + 1)) };
                break;
            }
        }
    }
    return out;
}

/** An amount as the inventory shows it: money as money, thousands separated. */
function lootAmount(key, n) {
    const d = itemDefs()[key];
    return (d && d.type === 'currency' ? '$' : '') + Number(n).toLocaleString('en-US');
}

/** A range in a slot's corner, short enough for it: "$2.5k–9k", "1–5". */
function lootRange(key, mn, mx) {
    const d = itemDefs()[key];
    const k = (n) => (n >= 1000 ? (n / 1000).toFixed(n % 1000 && n < 100000 ? 1 : 0).replace(/\.0$/, '') + 'k' : String(n));
    return (d && d.type === 'currency' ? '$' : '') + k(mn) + '–' + k(mx);
}

/** The container's slots, as its inventory panel shows them (inventory.css's own classes), each with what it may
 *  hold; the picked slot's list under them; or one roll of them all. */
function lootEditor(ed, node) {
    const c = typeof node.props.container === 'string' ? findWorld(ed.doc, node.props.container) : null;
    if (!c) return groupHead('What it holds') + '<div class="dr-hint">Pick its container first: its slots are laid out here.</div>';
    const slots = Math.max(1, Math.min(100, Math.floor(Number(c.def.slots) || 10)));
    const id = e(node.id);
    const sim = ed.lootSim && ed.lootSim.node === node.id ? ed.lootSim.items : null;
    const sel = ed.lootSel && ed.lootSel.node === node.id ? ed.lootSel.slot : null;
    let grid = '';
    for (let s = 1; s <= slots; s++) {
        let inner = '', cls = 'inv-slot dr-loot-slot';
        if (sim) {
            const got = sim[s];
            if (got) {
                cls += ' has-item';
                inner = `<div class="inv-item"><img class="inv-item-img" src="${e(itemImageUrl(got.item))}" alt=""></div>`
                    + (got.amount > 1 || (itemDefs()[got.item] || {}).type === 'currency' ? `<span class="inv-slot-amount">${e(lootAmount(got.item, got.amount))}</span>` : '');
            }
        } else {
            const list = lootOf(node, s);
            const top = list.find((x) => x.e.item);
            if (top) {
                const mn = Number(top.e.min) || 1, mx = Math.max(mn, Number(top.e.max) || mn);
                const total = list.reduce((n, x) => n + (Number(x.e.chance) || 100), 0);
                cls += ' has-item';
                inner = `<div class="inv-item"><img class="inv-item-img" src="${e(itemImageUrl(top.e.item))}" alt=""></div>`
                    + (mx > 1 || mn > 1 ? `<span class="inv-slot-amount">${e(mn === mx ? lootAmount(top.e.item, mn) : lootRange(top.e.item, mn, mx))}</span>` : '')
                    + (total < 100 || list.length > 1 ? `<span class="dr-loot-chance">${list.length > 1 ? list.length + ' · ' : ''}${Math.min(100, total)}%</span>` : '');
            } else if (list.length) {
                inner = '<span class="dr-loot-chance">?</span>';
            }
            if (s === sel) cls += ' dr-loot-on';
        }
        grid += `<button class="${cls}" data-act="loot-slot" data-id="${id}" data-slot="${s}" title="Slot ${s}"${sim ? ' disabled' : ''}>${inner}</button>`;
    }
    let html = groupHead('What it holds')
        + '<div class="inv-col-right dr-loot-inv"><div class="inv-panel inv-container-panel">'
        + `<div class="inv-panel-header"><div class="inv-panel-title"><div>${e(c.label || c.id)}`
        + `<div class="inv-panel-subtitle">${slots} slots · holds ${e(String(Number(c.def.maxWeight) || 100))} kg</div></div></div></div>`
        + `<div class="inv-slots-grid">${grid}</div></div></div>`;
    if (sim) {
        return html + '<div class="dr-hint">One way it could come out, each slot rolled as the scenario rolls it.</div>'
            + `<div class="dr-btns"><button class="dr-btn primary" data-act="loot-sim" data-id="${id}">Roll again</button>`
            + `<button class="dr-btn" data-act="loot-edit" data-id="${id}">Return to edit</button></div>`;
    }
    if (!sel) {
        html += '<div class="dr-hint">Pick a slot to say what may be in it, and how likely. What is left of 100% is the slot empty.</div>';
    } else {
        const list = lootOf(node, sel);
        const used = list.reduce((n, x) => n + (Number(x.e.chance) || 100), 0);
        html += `<div class="dr-loot-head">Slot ${sel}</div>`;
        for (const { e: x, i } of list) {
            const t = `loot:${node.id}:${i}`;
            html += '<div class="dr-loot-row">'
                + itemField(t, 'item', x.item, { label: 'Item', none: 'Pick an item' })
                + '<div class="dr-loot-nums">'
                + numberField(t, 'min', typeof x.min === 'number' ? x.min : undefined, { label: 'Fewest', min: 1, max: 1000000, placeholder: '1' })
                + numberField(t, 'max', typeof x.max === 'number' ? x.max : undefined, { label: 'Most', min: 1, max: 1000000, placeholder: String(x.min || 1) })
                + numberField(t, 'chance', typeof x.chance === 'number' ? x.chance : undefined, { label: 'Chance (%)', min: 1, max: 100, placeholder: '100' })
                + '</div>'
                + `<div class="dr-btns dr-btns-tight"><button class="dr-btn ghost danger" data-act="loot-remove" data-id="${id}" data-i="${i}">Take it out of this slot</button></div></div>`;
        }
        html += (used < 100 ? `<button class="dr-add" data-act="loot-add" data-id="${id}" data-slot="${sel}">${ICON.plus}Add an item to slot ${sel}</button>` : '')
            + `<div class="dr-hint">${used >= 100 ? 'Never empty: its chances make 100%.' : `Empty ${100 - Math.min(100, used)}% of the time.`}</div>`;
    }
    return html + `<div class="dr-btns"><button class="dr-btn" data-act="loot-sim" data-id="${id}">Simulate randomness</button></div>`;
}

/** What a card shows of itself under its fields (its def's ui.page: server/director/nodes.lua): Play skill check,
 *  Simulate, a preview, its slots. */
function cardTry(ed, node) {
    const def = ed.cards.get(node.type);
    const page = def && def.ui && PAGES[def.ui.page];
    return page ? page(ed, node, node.props || {}, e(node.id)) : '';
}

// ---- a card's own part of its page, by the name its ui.page gives ----

const PAGES = {
    loot: (ed, node) => lootEditor(ed, node),
    skillTry: (ed, node, p, id) => {
        // Another resource's game (the phone's) plays where it lives, on the player's phone: Test runs it there.
        // (Just the button: no Try it heading or explaining, Josh 10 Nov 2026.)
        if (typeof p.game === 'string' && p.game && p.game !== 'ring') {
            return '<div class="dr-hint">Plays on the phone: run a Test to try it.</div>';
        }
        return '<div class="dr-try">'
            + `<button class="dr-btn primary" data-act="try-skill" data-id="${id}">Play skill check</button>`
            + `<span class="dr-try-out" data-try-out="${id}"></span></div>`;
    },
    progressTry: (ed, node, p, id) => '<div class="dr-try">'
        + `<button class="dr-btn primary" data-act="try-progress" data-id="${id}">Simulate</button></div>`,
    objectivePreview: (ed, node, p, id) => {
        const all = glyphTable();
        const icon = typeof p.icon === 'string' && all[p.icon] ? p.icon : 'objective';
        const text = typeof p.text === 'string' && p.text.trim() ? p.text : 'What to do next';
        // Its Subtext: the scenario's name, none, or its own words (typed live into the preview).
        const own = p.subShown === 'other';
        const sub = p.subShown === 'none' ? '' : own ? (typeof p.sub === 'string' ? p.sub.trim() : '') : (ed.doc.name || '');
        const row = own
            ? `<span class="ob-name" data-preview="node:${id}|sub" data-empty="">${e(sub)}</span>`
            : `<span class="ob-name">${e(sub)}</span>`;
        return groupHead('How it looks') + '<div class="dr-preview dr-preview-ob">'
            + `<div class="sh-capsule ob-card visible${!own && !sub ? ' no-row' : ''}"><div class="sh-stat dt-disc"><div class="sh-disc"><div class="sh-fill"></div></div>`
            + `<div class="sh-icon">${all[icon] || ''}</div></div>`
            + `<div class="dt-body"><div class="dt-title" data-preview="node:${id}|text" data-empty="What to do next">${e(text)}</div>`
            + `<div class="dt-row">${row}<span class="ob-clock"></span></div></div></div></div>`;
    },
    doorLook: (ed, node, p) => {
        // Its doors, looked at: in the world builder, the camera to one; from here, the builder opened on it.
        const doors = worldsOf({ props: p }, 'door').map((id) => findWorld(ed.doc, id)).filter(Boolean);
        if (!doors.length) return '';
        const say = (d) => (doors.length > 1 ? `${ed.inBuilder ? 'Look at' : 'Show'} ${d.label || d.id}`
            : ed.inBuilder ? 'Look at the door' : 'Show the door in the world');
        return '<div class="dr-btns">' + doors.map((d) => `<button class="dr-btn" data-act="look-world" data-id="${e(d.id)}">${e(say(d))}</button>`).join('')
            + '</div>';
    },
    pressPreview: (ed, node, p, id) => {
        const all = glyphTable();
        const icon = typeof p.icon === 'string' && all[p.icon] ? all[p.icon] : '<b>E</b>';
        const text = typeof p.label === 'string' && p.label.trim() ? p.label : 'Use';
        return groupHead('How it looks') + '<div class="dr-preview dr-preview-prompt">'
            + `<span class="dr-pr-disc">${icon}</span><span class="dr-pr-label" data-preview="node:${id}|label" data-empty="Use">${e(text)}</span></div>`
            + '<div class="dr-hint">The prompt at the placed thing, when it is the one E acts on.</div>';
    },
};

// ---- items: picked from the item picker (a page of every item, its picture and a search) ----

/** An item's picture, with the page's own fallback for one that is missing (utils.js). */
function itemArt(key, lazy) {
    return `<img src="${e(itemImageUrl(key))}" alt="" data-item-img="" data-item-key="${e(key)}"${lazy ? ' loading="lazy"' : ''}>`;
}

/** The items this page knows (the inventory's definitions): none until the first one has arrived. */
const itemDefs = () => getItemDefs() || {};

/** An item field: the item picked, as its picture and name; pressed, the item picker opens over the
 *  page (app.js 'item-pick'). With no item list yet, a box to type an item's key in. */
function itemField(t, k, value, o = {}) {
    const defs = itemDefs();
    if (!Object.keys(defs).length) return textField(t, k, value, { label: o.label, max: 64, placeholder: 'item key' });
    const v = typeof value === 'string' ? value : '';
    const d = v ? defs[v] : null;
    const main = !v ? `<b>${e(o.none || 'Pick an item')}</b>`
        : `<b>${e((d && d.name) || v)}</b><span>${e(d ? v : v + ' · not on this server')}</span>`;
    return `<div class="dr-row">${label(o.label || k, o.hint)}`
        + `<button class="dr-pick${v ? '' : ' empty'}" data-act="item-pick" data-t="${e(t)}" data-k="${e(k)}" data-label="${e(String(o.label || 'Item').replace(/ \*$/, ''))}"${o.required ? ' data-req="1"' : ''}${o.only ? ' data-only="1"' : ''}>`
        + `<span class="dr-pick-art">${v ? itemArt(v) : ICON.box}</span><span class="dr-pick-main">${main}</span>${ICON.open}</button></div>`;
}

/** A kind of item as a chip says it: whip's own kinds by name, another resource's as it wrote it. */
const KIND_TITLE = { weapon: 'Weapons', ammo: 'Ammo', tool: 'Tools', key: 'Keys', medical: 'Medical', consumable: 'Food and drink',
    document: 'Documents', misc: 'Other', other: 'Other', clothing: 'Clothing', material: 'Materials' };
function kindTitle(type) {
    const s = String(type || 'other');
    return KIND_TITLE[s] || s.charAt(0).toUpperCase() + s.slice(1);
}

/** THE ITEM PICKER, a page over the field's own (ed.picker: { t, k, label, from, query, kind }): every item
 *  with its picture, a search across all of them, and a chip for each kind (the /whip panel's item tiles'
 *  way). A press picks one and goes back. */
function itemPicker(ed) {
    const p = ed.picker;
    const cur = peekValue(ed, p.t, p.k);
    const defs = itemDefs();
    // A field for the scenario's own items (kind runItem): only those it places or gives.
    const own = p.only ? scenarioItems(ed) : null;
    const all = (own ? [...own] : Object.keys(defs))
        .map((k) => ({ k, name: (defs[k] && defs[k].name) || k, type: (defs[k] && defs[k].type) || 'other' }));
    const counts = {};
    for (const x of all) counts[x.type] = (counts[x.type] || 0) + 1;
    const kinds = Object.keys(counts).sort((a, b) => counts[b] - counts[a] || a.localeCompare(b));
    const q = (p.query || '').trim().toLowerCase();
    const kind = kinds.includes(p.kind) ? p.kind : 'all';
    // A search reaches every item, whichever chip is lit.
    const shown = all.filter((x) => (q ? (x.name.toLowerCase().includes(q) || x.k.toLowerCase().includes(q) || x.type.toLowerCase().includes(q))
        : (kind === 'all' || x.type === kind))).sort((a, b) => a.name.localeCompare(b.name));
    const chip = (id, text, n) => `<button class="dr-chip plain${!q && kind === id ? ' on' : ''}" data-act="pick-kind" data-kind="${e(id)}">${e(text)} <em>${n}</em></button>`;
    const rows = shown.map((x) => `<button class="dr-pick-row${x.k === cur ? ' on' : ''}" data-act="pick-item" data-key="${e(x.k)}">`
        + `<span class="dr-pick-art">${itemArt(x.k, true)}</span>`
        + `<span class="dr-pick-main"><b>${e(x.name)}</b><span>${e(x.k)} · ${e(x.type)}</span></span></button>`).join('');
    return '<div class="dr-pal-top">'
        + `<button class="dr-back" data-act="pick-back">${ICON.back}${e(p.from)}</button>`
        + `<div class="dr-pick-head"><div class="dr-title2">${e(p.label)}</div>`
        + (cur && !p.required ? '<button class="dr-btn ghost" data-act="pick-clear">Clear</button>' : '') + '</div>'
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field dr-pick-search" type="text" placeholder="Search ${all.length} items" value="${e(p.query || '')}" spellcheck="false" aria-label="Search items"></div>`
        + '<div class="dr-chips">' + chip('all', 'All', all.length) + kinds.map((t) => chip(t, kindTitle(t), counts[t])).join('') + '</div>'
        + `<div class="dr-pick-count">${plural(shown.length, 'item')}${q ? ` matching “${e(p.query.trim())}”` : ''}`
        + `${own ? ' the scenario places or gives' : ''}</div>`
        + '</div>'
        + `<div class="dr-pal-list dr-pick-list">${rows || (own && !own.size
            ? '<div class="dr-none">The scenario places or gives no items yet: an item spot (World), or a Give Item, Drop Item, Put in Car or Create Container card</div>'
            : '<div class="dr-none">No item matches</div>')}</div>`;
}

/** The items a scenario itself places or gives (server/director/graph.lua scenarioItems, the same rule): its item
 *  spots (not a car's key spot) and what its cards that give items hold (a card's givesItems: Give Item, Drop Item,
 *  Put in Car, Create Container's slots). */
export function scenarioItems(ed) {
    const doc = ed.doc;
    const out = new Set();
    const add = (k) => { if (typeof k === 'string' && k) out.add(k); };
    const scan = (world, nodes) => {
        for (const w of Array.isArray(world) ? world : []) {
            if (w && w.kind === 'groundItem' && w.def && typeof w.def.keyOf !== 'string') add(w.def.item);
        }
        for (const n of Array.isArray(nodes) ? nodes : []) {
            const def = n && ed.cards.get(n.type);
            if (!def || !def.givesItems || !n.props) continue;
            add(n.props.item);
            for (const x of Array.isArray(n.props.loot) ? n.props.loot : []) if (x) add(x.item);
        }
    };
    if (doc) {
        scan(doc.world, doc.nodes);
        for (const v of Array.isArray(doc.variants) ? doc.variants : []) if (v) scan(v.world, v.nodes);
    }
    return out;
}

/** What a field holds now, read without making anything: targetOf makes a missing conditions, tilt or rules
 *  object as it answers, which only a write may do (an empty one left behind is an unsaved change). */
function peekValue(ed, spec, k) {
    const i = spec.indexOf(':');
    const kind = i < 0 ? spec : spec.slice(0, i);
    const id = i < 0 ? '' : spec.slice(i + 1);
    let obj = null;
    if (kind === 'cond' || kind === 'rot') {
        const w = findWorld(ed.doc, id);
        obj = w && w.def[kind === 'cond' ? 'conditions' : 'rot'];
    } else if (kind === 'rule') {
        const j = id.lastIndexOf(':');
        const n = j < 0 ? null : findNode(ed.doc, id.slice(0, j));
        obj = n && n.props[id.slice(j + 1)];
    } else {
        obj = targetOf(ed, spec);
    }
    return obj && typeof obj === 'object' ? obj[k] : undefined;
}

/** Write a value into what a field edits (the item picker's pick, or its Clear): empty takes the key out.
 *  Answers true when something changed. */
export function writeValue(ed, t, k, v) {
    let changed = false;
    for (const obj of targetsOf(ed, t)) {
        const before = JSON.stringify(obj[k]);
        if (v === '' || v === undefined || v === null) delete obj[k]; else obj[k] = v;
        if (JSON.stringify(obj[k]) !== before) changed = true;
    }
    tidy(ed, t);
    return changed;
}

// ---- the tabs ----

/** The card list: the search and a chip for each kind over it, a card a line, and the strip under it saying
 *  what the card pointed at does (app.js fills it in as the pointer moves; empty until one is). The Cards tab's,
 *  and the world builder's Blueprint window's (renderCards). */
export function renderCards(ed) { return cardsTab(ed); }

function cardsTab(ed) {
    const groups = groupCards(ed.cards, ed.paletteQuery);
    const all = groupCards(ed.cards, '');
    const kind = (g) => e(g.tint || g.cat);
    const rows = groups.map((g) => `<div class="dr-cat line kind-${kind(g)}" data-cat="${e(g.cat)}">${e(g.title)}</div>`
        + g.cards.map((def) => `<div class="dr-pal-row line${def.locked ? ' locked' : ''}" data-type="${e(def.type)}"><b>${e(def.title)}</b></div>`).join('')).join('');
    const total = all.reduce((n, g) => n + g.cards.length, 0);
    // How the cards look on the grid: this player's choice, kept on this PC (app.js cardStyle).
    const style = ed.cardStyle ? ed.cardStyle() : 'board';
    const styleKey = (v, text) => `<button class="dr-seg-key${style === v ? ' on' : ''}" data-act="card-style" data-style="${v}">${text}</button>`;
    return '<div class="dr-pal-top">'
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field dr-pal-search" type="text" placeholder="Search ${total} cards" value="${e(ed.paletteQuery || '')}" spellcheck="false" aria-label="Search cards"></div>`
        + '<div class="dr-chips">' + groups.map((g) => `<button class="dr-chip kind-${kind(g)}" data-act="pal-jump" data-cat="${e(g.cat)}">${e(g.title)} <em>${g.cards.length}</em></button>`).join('') + '</div>'
        + `<div class="dr-row inline">${label('Card style')}<div class="dr-seg">${styleKey('board', 'Board')}${styleKey('classic', 'Classic')}</div></div>`
        + '</div>'
        + `<div class="dr-pal-list">${rows || '<div class="dr-none">No card matches</div>'}</div>`
        + '<div class="dr-pal-strip"><b></b><p></p></div>';
}

/** The scenario's placed things for a picker: each its picture (an NPC's ped, a lore character's own, a car) and a line
 *  under it (its model). A car is named by its model alone ("sultan", Josh 10 Nov 2026), with its name under it only
 *  when another car has that model too. `weaponsOnly`: only its Fixed Weapons (props that are a gun: Fire Weapon's). */
function worldOptions(ed, worldKind, weaponsOnly) {
    const modelOf = (w) => (w.def && typeof w.def.model === 'string' ? w.def.model : '');
    const carsOf = {};
    for (const w of ed.doc.world) if (w.kind === 'vehicle' && modelOf(w)) carsOf[modelOf(w)] = (carsOf[modelOf(w)] || 0) + 1;
    return ed.doc.world.filter((w) => (!worldKind || w.kind === worldKind) && (!weaponsOnly || (w.def && w.def.weapon))).map((w) => {
        const model = modelOf(w);
        const c = w.kind === 'npc' && w.def.lore ? (ed.lore || []).find((x) => x.key === w.def.lore) : null;
        // (c.portrait: the headshot of a look made in the character editor, lore-faces.js)
        const pic = c && (c.picture || c.portrait) ? c.picture || c.portrait : w.kind === 'npc' && model ? pedImageUrl(model)
            : w.kind === 'vehicle' && model ? vehicleImageUrl(model) : '';
        if (w.kind === 'vehicle' && model) return [w.id, model, { pic, sub: carsOf[model] > 1 ? w.label || w.id : '' }];
        const sub = [c ? 'Lore character' : '', model].filter(Boolean).join(' · ');
        return [w.id, w.label || w.id, { pic, sub }];
    });
}

function propField(ed, node, f) {
    const t = 'node:' + node.id;
    const v = node.props[f.key];
    const req = f.required ? ' *' : '';
    const lab = (f.label || f.key) + req;
    if (v !== null && typeof v === 'object' && v.var !== undefined) {
        return `<div class="dr-row">${label(lab)}<div class="dr-readvar">Reads the variable <b>${e(v.var)}</b>`
            + `<button class="dr-btn ghost" data-act="clear-prop" data-id="${e(node.id)}" data-k="${e(f.key)}">Clear</button></div></div>`;
    }
    // A field with a widget of its own (its ui: server/director/nodes.lua): an Interaction Menu choice's Under, a
    // Dialog Line's answer.
    if (f.ui === 'menuUnder') return menuUnderField(node, f, v);
    if (f.ui === 'answer') return answerField(ed, node, f, v);
    // At a spot with a marker, the marker says how near and who (server/director/spots.lua): not this field.
    const spot = f.bySpot ? markedSpot(ed, node.props[f.bySpot]) : null;
    if (spot) return bySpotRow(lab, spot);
    // A field another resource's card gives a hint for (its `hint`): a line under it.
    const html = f.kind === 'entries' ? entriesField(ed, node, f, v, lab) : fieldHtml(ed, node, f, t, v, lab);
    // A recording's link (its ui hearLink: Play Custom Voice Line's): Play beside it, as a voice line's in the Lore form
    // (heard at you, as from their NPC). (Never disabled: a link pasted in is not drawn again until the box is left.)
    const hear = f.ui === 'hearLink'
        ? `<div class="dr-btns dr-btns-tight"><button class="dr-btn" data-act="lore-hear" data-id="${e(node.id)}">Play it at you</button></div>`
        : '';
    return (f.hint ? html + `<div class="dr-hint dr-field-hint">${e(f.hint)}</div>` : html) + hear;
}

// ---- a card's numbered sets (its `repeats`: a Dialog Line's answers, NPC /me's alternatives: server/director/nodes.lua) ----

/** Which of a card's numbered sets a field is in: { r (its place in def.repeats), rep, n (its number) }, or null. */
function repeatOf(def, key) {
    const list = def.repeats || [];
    for (let r = 0; r < list.length; r++) {
        const rep = list[r];
        for (let n = rep.from; n <= rep.to; n++) {
            if (rep.keys.some((k) => k.replace('%d', n) === key)) return { r, rep, n };
        }
    }
    return null;
}

/** The last of a numbered set that shows: the last one written (`min` of them at least), or more once its Add asked. */
export function repeatShown(ed, node, def, r) {
    const rep = def.repeats[r];
    let last = rep.from - 1 + (rep.min || 0);
    for (let n = rep.from; n <= rep.to; n++) {
        const v = node.props[rep.keys[0].replace('%d', n)];
        if (typeof v === 'string' ? v.trim() !== '' : v !== undefined && v !== null) last = n;
    }
    return Math.min(rep.to, Math.max(last, (ed.repeatOpen && ed.repeatOpen[node.id + ':' + r]) || 0));
}

// ---- Dialog Line's answers (opt1-opt4, each followed by its rules: server/director/nodes_world.lua) ----

/** An answer: its number, its box, then its rules' gear (Josh, 10 Nov 2026: no rules line under it). The gear opens the
 *  rules under the answer (ruleField); blue while a rule is set, grey while none, its words in its tooltip. An empty
 *  answer has no rules: its gear keeps its room, unseen, so the box does not jump as it is written. */
function answerField(ed, node, f, v) {
    const n = f.key.slice(3);
    const name = (f.label || 'Answer ' + n) + (f.required ? ' (needed)' : '');
    const key = f.key + 'Rule';
    const written = typeof v === 'string' && v.trim() !== '';
    const r = node.props[key] && typeof node.props[key] === 'object' ? node.props[key] : {};
    const sum = written ? ruleSummary(r) : '';
    const open = written && ed.ruleOpen === node.id + ':' + key;
    return `<div class="dr-row dr-ans"><span class="dr-ans-n">${e(n)}</span>`
        + `<input class="dr-field" type="text" value="${e(typeof v === 'string' ? v : '')}" data-t="node:${e(node.id)}" data-k="${e(f.key)}" data-f="text"`
        + `${f.maxLength ? ` maxlength="${f.maxLength}"` : ''} placeholder="What the player can say" aria-label="${e(name)}" spellcheck="false">`
        + `<button type="button" class="dr-ans-gear${sum ? ' on' : ''}${open ? ' open' : ''}${written ? '' : ' none'}" data-act="rule-open"`
        + ` data-id="${e(node.id)}" data-k="${e(key)}" title="${e(sum ? 'Rules: ' + sum : 'Rules')}" aria-label="Rules for answer ${e(n)}"`
        + ` aria-expanded="${open}"${written ? '' : ' tabindex="-1" disabled'}>${ICON.gear}</button></div>`;
}

function fieldHtml(ed, node, f, t, v, lab) {
    // An empty field runs at its default, so the default shows in it (greyed).
    const dflt = f.default !== undefined && f.default !== null ? String(f.default) : '';
    switch (f.kind) {
        case 'text': {
            const lines = typeof f.lines === 'number' ? f.lines : 0;
            return textField(t, f.key, v, { label: lab, max: f.maxLength, big: lines > 1 || (f.maxLength || 0) > 80, rows: lines || 3,
                placeholder: dflt, hint: f.unit });
        }
        case 'number':
        case 'duration': {
            // A number its card draws as a slider (`slider`, between its min and max: a lore line's Bonus range).
            if (f.slider && typeof f.min === 'number' && typeof f.max === 'number') {
                return sliderField(t, f.key, typeof v === 'number' ? v : undefined, { label: lab, min: f.min, max: f.max,
                    step: f.step || 1, unit: f.unit || '', fallback: typeof f.default === 'number' ? f.default : f.min });
            }
            // A duration's unit is seconds; said once, so not again when its label says it already.
            const unit = f.unit || (f.kind === 'duration' ? 'seconds' : '');
            const said = unit && String(f.label || '').toLowerCase().includes(unit.toLowerCase());
            return numberField(t, f.key, v, { label: lab, min: f.min, max: f.max, hint: said ? '' : unit, placeholder: dflt });
        }
        case 'bool':
            return switchField(t, f.key, v, { label: lab, fallback: f.default === true });
        case 'select':
        case 'players': {
            // Each choice's value is what is saved; its label (another resource's card may give one) shown.
            const labels = f.optionLabels && typeof f.optionLabels === 'object' ? f.optionLabels : {};
            const opts = (f.options || []).map((o) => [o, labels[o] || o]);
            const short = opts.length <= 4 && opts.reduce((n, [, text]) => n + String(text).length, 0) <= 26;
            // Left empty, it runs at its default: the empty choice says which.
            // Left empty, it runs at its default: that choice shows picked (never a second line for it).
            return short ? segField(t, f.key, v, opts, { label: lab, fallback: f.default, inline: opts.length <= 2 })
                : selectField(t, f.key, v != null && v !== '' ? v : dflt, opts, { label: lab, noEmpty: !!dflt });
        }
        case 'job': {
            const jobs = (ed.jobs || []).map((j) => [j.key, j.name || j.key]);
            const named = jobs.find(([k]) => k === dflt);
            return jobs.length ? selectField(t, f.key, v || (named ? dflt : ''), jobs, { label: lab, noEmpty: !!named, none: '— pick a job —' })
                : textField(t, f.key, v, { label: lab, max: 64, placeholder: dflt || 'job key' });
        }
        case 'world': {
            const opts = worldOptions(ed, f.worldKind, f.weaponsOnly === true);
            const hint = opts.length ? '' : f.weaponsOnly ? 'place one from the world builder\'s More, Weapons' : `make one in the World tab`;
            return selectField(t, f.key, v, opts, { label: lab, hint, none: '— pick a placed thing —' });
        }
        case 'item':
            return itemField(t, f.key, v, { label: lab, required: f.required });
        case 'runItem':
            // One of the scenario's own items (scenarioItems): its picker lists only those.
            return itemField(t, f.key, v, { label: lab, required: f.required, only: true });
        case 'card': {
            // Another card of the scenario, of the types the field names (its options): a Haggle's price goes to it.
            const types = new Set(f.options || []);
            const opts = ed.doc.nodes.filter((n) => n.id !== node.id && types.has(n.type)).map((n) => [n.id, cardChoice(ed, n)]);
            return selectField(t, f.key, v, opts, { label: lab, none: '— none: the price goes in its variable —',
                hint: opts.length ? '' : 'add a Pay, Charge Player or Give Item card first' });
        }
        case 'var':
            return selectField(t, f.key, v, ed.doc.vars.map((x) => [x.id, x.label || x.id]),
                { label: lab, hint: ed.doc.vars.length ? '' : 'make one in the Variables tab', none: '— pick a variable —' });
        case 'lore': {
            // Empty is the scenario's own lore character: the empty choice names it.
            const own = defaultLore(ed);
            return selectField(t, f.key, v, (ed.lore || []).map((c) => [c.key, c.name]), { label: lab,
                none: own ? `${own.name} (the scenario's own)` : '— pick a lore character —',
                hint: (ed.lore || []).length ? '' : 'make one in /whip: Director, Lore characters' });
        }
        case 'rule':
            return ruleField(ed, node, f);
        case 'glyph':
            return glyphField(ed, t, f.key, v, { label: lab, fallback: f.default, open: ed.glyphOpen === t + '|' + f.key });
        case 'loot':
            return '';   // (drawn under the fields, as the container itself: lootEditor)
        case 'worlds':
            return f.groups ? thingsField(ed, node, f, lab) : worldsField(ed, node, f, lab);
        case 'emote':
            // An /e name, typed or picked from the emote menu (opened over this screen: its pictures and videos).
            return textField(t, f.key, v, { label: lab, max: f.maxLength, placeholder: dflt || 'none' })
                + `<div class="dr-btns dr-btns-tight"><button class="dr-btn" data-act="card-emote-pick" data-id="${e(node.id)}" data-k="${e(f.key)}">Choose from the emote menu</button></div>`;
        case 'take': {
            // One of the car's takes (the car the field named by `of` holds): recorded on that car's page.
            const car = node && f.of ? findWorld(ed.doc, node.props[f.of]) : null;
            const takes = car ? takesOf(car) : [];
            const hint = !car ? 'pick the car first' : takes.length ? '' : 'record one on the car\'s page: Scripted Driving Events';
            return selectField(t, f.key, v == null ? '' : String(v), takes.map((k) => [String(k.id), takeText(k)]),
                { label: lab, hint, none: '— pick a driving event —' });
        }
        default:
            return `<div class="dr-row">${label(lab)}<div class="dr-none">${e(String(v))}</div></div>`;
    }
}

// ---- an Interaction Menu choice's place (point.menu: server/director/nodes_heist.lua) ----

/** What "Under Choice j" reads: the choice's text, as it is now. */
function menuUnderText(node, j) {
    const v = node.props['item' + j];
    const t = typeof v === 'string' ? v.trim() : '';
    return t ? `Under “${t}”` : `Under Choice ${j} (empty)`;
}

/** Where a choice sits: at the top (empty), or under another choice, named by its text. Every other
 *  choice is listed, an empty one too, so what is picked is always there to pick (Check refuses one
 *  under an empty choice, a ring, a fourth level and more than six on one level). */
function menuUnderField(node, f, v) {
    const i = f.key.match(/^item(\d)Under$/)[1];
    const opts = [];
    for (let j = 1; j <= 8; j++) {
        if (String(j) !== i) opts.push([String(j), menuUnderText(node, j)]);
    }
    return selectField('node:' + node.id, f.key, v === 'top' ? '' : v, opts, { label: f.label || 'Under', none: 'At the top' });
}

/** An Under list about to open: its choices by the text they have now. A typed field does not redraw
 *  the column (app.js: that would take the next click), so a choice named a moment ago is named here. */
export function refreshMenuUnder(ed, el) {
    if (!el || el.tagName !== 'SELECT' || !/^item\dUnder$/.test(el.dataset.k || '') || !(el.dataset.t || '').startsWith('node:')) return;
    const n = findNode(ed.doc, el.dataset.t.slice(5));
    const def = n && ed.cards.get(n.type);
    if (!def || !def.prompt || !def.prompt.menu) return;
    for (const o of el.options) {
        if (/^[1-8]$/.test(o.value)) o.textContent = menuUnderText(n, o.value);
    }
}

// ---- a Dialog Line answer's rules (kind 'rule': server/director/nodes_world.lua checkRule) ----

const RULE_ONLY = [['always', 'Always'], ['has an item', 'They have an item'], ['carries cash', 'They carry cash'],
    ['a flag is set', 'A player flag is set'], ['a flag is not set', 'A player flag is not set'], ['a variable is', 'A variable is']];
const RULE_COST = [['nothing', 'Nothing'], ['an item', 'An item'], ['money', 'Money']];
const RULE_OFFER = [['every time', 'Every time'], ['once a run', 'Once a run'], ['once ever', 'Once ever']];

function itemLabel(key) {
    const defs = getItemDefs() || {};
    return defs[key] && defs[key].name ? defs[key].name : String(key || '?');
}

/** The rules in a few words, for the closed row: "only with 1× Lockpick · $500 · once a run · 60%". */
export function ruleSummary(r) {
    if (!r || typeof r !== 'object') return '';
    const bits = [];
    const only = r.only || 'always';
    if (only === 'has an item') bits.push(`only with ${r.count || 1}× ${itemLabel(r.item)}`);
    else if (only === 'carries cash') bits.push(`only with $${r.cash || 0} cash`);
    else if (only === 'a flag is set') bits.push(`only if ${r.flag || '?'} is set`);
    else if (only === 'a flag is not set') bits.push(`only if ${r.flag || '?'} is not set`);
    else if (only === 'a variable is') bits.push(`only if ${r.onlyVar || '?'} is ${r.value === undefined ? '(empty)' : r.value}`);
    if (r.cost === 'money') bits.push(`costs $${r.costCash || 0}`);
    else if (r.cost === 'an item') bits.push(`costs ${r.costCount || 1}× ${itemLabel(r.costItem)}`);
    if (r.offer && r.offer !== 'every time') bits.push(r.offer);
    if (typeof r.chance === 'number') bits.push(`works ${r.chance}% of the time`);
    return bits.join(' · ');
}

function ruleField(ed, node, f) {
    const key = f.key;
    const pin = key.replace(/Rule$/, '');
    const answer = typeof node.props[pin] === 'string' ? node.props[pin].trim() : '';
    if (!answer) return '';   // no answer, nothing to have rules
    const r = node.props[key] && typeof node.props[key] === 'object' ? node.props[key] : {};
    const open = ed.ruleOpen === node.id + ':' + key;
    if (!open) return '';   // (closed: only the answer's gear, answerField)
    const t = 'rule:' + node.id + ':' + key;
    const only = r.only || 'always';
    const cost = r.cost || 'nothing';
    const itemPick = (k, label) => itemField(t, k, r[k], { label });
    // 'always' and 'nothing' are the empty choice (no key at all), so they are not listed twice.
    let html = '<div class="dr-rule open"><div class="dr-rule-body">'
        + selectField(t, 'only', only === 'always' ? '' : only, RULE_ONLY.slice(1), { label: 'Offered only if', none: 'Always' });
    if (only === 'has an item') {
        html += itemPick('item', 'Item') + numberField(t, 'count', r.count, { label: 'How many', min: 1, max: 1000, placeholder: '1' });
    } else if (only === 'carries cash') {
        html += numberField(t, 'cash', r.cash, { label: 'At least ($)', min: 1, max: 10000000 });
    } else if (only === 'a flag is set' || only === 'a flag is not set') {
        html += textField(t, 'flag', r.flag, { label: 'Flag', max: 64, placeholder: 'met_fence', hint: 'Set Player Flag sets one' });
    } else if (only === 'a variable is') {
        html += selectField(t, 'onlyVar', r.onlyVar, ed.doc.vars.map((x) => [x.id, x.label || x.id]),
            { label: 'Variable', hint: ed.doc.vars.length ? '' : 'make one in the Variables tab', none: '— pick a variable —' })
            + textField(t, 'value', r.value, { label: 'Is', max: 100 });
    }
    html += selectField(t, 'cost', cost === 'nothing' ? '' : cost, RULE_COST.slice(1), { label: 'Costs', none: 'Nothing' });
    if (cost === 'an item') {
        html += itemPick('costItem', 'Item it takes') + numberField(t, 'costCount', r.costCount, { label: 'How many', min: 1, max: 1000, placeholder: '1' });
    } else if (cost === 'money') {
        html += numberField(t, 'costCash', r.costCash, { label: 'How much ($)', min: 1, max: 10000000, hint: 'cash, else the bank' });
    }
    html += segField(t, 'offer', r.offer, RULE_OFFER, { label: 'Offered', fallback: 'every time' })
        + numberField(t, 'chance', r.chance, { label: 'Works (%)', min: 1, max: 99, placeholder: 'always',
            hint: 'a miss goes out of its Failed outcome' })
        + `<div class="dr-btns"><button class="dr-btn ghost" data-act="rule-clear" data-id="${e(node.id)}" data-k="${e(key)}">No rules</button></div>`;
    return html + '</div></div>';
}

/** A card's or a thing's problems at the top of its page. `key` ('node:<id>', 'world:<id>') names the box, so a check
 *  that comes back while a field is being typed in fills it in place (app.js showChecked, problemsFor). */
function problemsHtml(list, key) {
    return `<div class="dr-probs" data-probs="${e(key)}">` + probRows(list) + '</div>';
}

function probRows(list) {
    return (list || []).map((p) => `<div class="dr-prob ${p.severity === 'error' ? 'error' : 'warn'}">${e(p.message)}</div>`).join('');
}

/** What a problems box (problemsHtml) holds now. */
export function problemsFor(ed, key) {
    const i = key.indexOf(':');
    const kind = key.slice(0, i), id = key.slice(i + 1);
    return probRows(ed.problemList.filter((p) => (kind === 'node' ? p.node === id : p.world === id)));
}


/** Another resource's list on its card (an entries field: server/director/cards_api.lua): each entry's own words on its
 *  row, Change (its button, on that entry) and x; then its button again to add one, up to the most it takes. What its
 *  button saves is the entry (app.js cardEntryData). */
function entriesField(ed, node, f, v, lab) {
    const list = Array.isArray(v) ? v : [];
    const b = (ed.buttons || []).find((x) => x.id === f.button);
    const max = f.max || 8;
    const id = e(node.id), k = e(f.key);
    let html = `<div class="dr-row">${label(lab)}</div>`;
    if (!b) html += `<div class="dr-prob warn">Its button (${e(f.button)}) is not here: is ${e(String(f.button).split('.')[0])}'s resource running?</div>`;
    html += list.map((en, i) => `<div class="dr-entry"><span class="dr-entry-n">${i + 1}</span>`
        + `<span class="dr-entry-text">${e(en && typeof en.text === 'string' && en.text ? en.text : `Entry ${i + 1}`)}</span>`
        + (b ? `<button class="dr-btn ghost" data-act="entry-press" data-id="${id}" data-k="${k}" data-i="${i}" title="${e(b.hint || b.label)}">Change</button>` : '')
        + `<button class="dr-ibtn" data-act="entry-remove" data-id="${id}" data-k="${k}" data-i="${i}" aria-label="Take ${i + 1} out" title="Take it out">${ICON.close}</button>`
        + '</div>').join('');
    if (!list.length) html += '<div class="dr-none">None yet</div>';
    if (b && list.length < max) {
        html += `<button class="dr-add" data-act="entry-press" data-id="${id}" data-k="${k}" title="${e(b.hint || b.label)}">${ICON.plus}${e(f.add || b.label)}</button>`;
    } else if (list.length >= max) {
        html += `<div class="dr-hint">${max} at most.</div>`;
    }
    return html;
}

/** A card's fields in its order, a head wherever its `group` changes: each only while its `when` holds (when.js), and
 *  of a numbered set (its `repeats`: a Dialog Line's answers) the ones written and an Add button for the next. */
function cardFields(ed, node, def) {
    let html = '', inGroup = null;
    for (const f of def.props || []) {
        if (f.group && f.group !== inGroup) {
            inGroup = f.group;
            html += groupHead(f.group);
        }
        const rp = repeatOf(def, f.key);
        if (rp) {
            const upTo = repeatShown(ed, node, def, rp.r);
            if (rp.n <= upTo) html += propField(ed, node, f);
            // (Its Add after the set's very last field, shown or not.)
            const lastKey = rp.rep.keys[rp.rep.keys.length - 1].replace('%d', rp.rep.to);
            if (f.key === lastKey && upTo < rp.rep.to) {
                html += `<button class="dr-add" data-act="repeat-add" data-id="${e(node.id)}" data-r="${rp.r}">${ICON.plus}${e(rp.rep.add)}</button>`;
            }
            continue;
        }
        if (!holds(f.when, node.props, def.props)) continue;
        html += propField(ed, node, f);
    }
    // A card a Haggle agrees the price of (its def.haggle; the Haggle names it in its card field): said, so its own
    // amount is not taken for the last word.
    const haggles = def.haggle ? ed.doc.nodes.filter((n) => {
        const d = ed.cards.get(n.type);
        return d && n.props && d.props.some((f) => f.kind === 'card' && f.options && n.props[f.key] === node.id);
    }) : [];
    if (haggles.length) {
        const by = (ed.cards.get(haggles[0].type) || {}).title || 'Haggle';
        html += `<div class="dr-hint">What it pays, charges or gives is the price agreed in ${haggles.length === 1 ? 'a ' + by : plural(haggles.length, by)}`
            + ' once the scenario agrees one; until then, its own.</div>';
    }
    return html;
}

/** A card as a choice in a list: its title and what it is set to now (a Pay's amount, a Give Item's how many). */
function cardChoice(ed, n) {
    const def = ed.cards.get(n.type);
    const p = n.props || {};
    // (What a Haggle can agree of it, its def.haggle: money, or how many of its item.)
    const hg = def && def.haggle;
    const amount = hg && typeof p[hg.key] === 'number' ? p[hg.key] : null;
    const what = hg && hg.unit === 'count' ? `${amount != null ? amount : 1} × ${p.item || 'an item'}`
        : amount != null ? money(amount) : '';
    return (def ? def.title : n.type) + (what ? ` · ${what}` : '');
}

/** The selected card's page (over the tab it was picked from); Esc or the way back unselects it. */
function cardTab(ed) {
    const ids = [...ed.selected];
    const back = backRow(ed, 'page-back');
    if (ids.length === 0) return back;
    if (ids.length > 1) {
        return back + `<div class="dr-title2">${ids.length} cards selected</div>`
            + '<div class="dr-btns"><button class="dr-btn" data-act="dup-sel">Duplicate</button>'
            + '<button class="dr-btn danger" data-act="del-sel">Delete</button></div>';
    }
    const node = findNode(ed.doc, ids[0]);
    if (!node) return back;
    const def = ed.cards.get(node.type);
    const mine = ed.problemList.filter((p) => p.node === node.id);
    if (!def) {
        // Whose it was when this scenario was switched on (the server says): start that resource.
        const from = ed.providers && typeof ed.providers[node.type] === 'string' ? ed.providers[node.type] : null;
        const why = from
            ? `This card comes from <b>${e(from)}</b>, which is not running: start it, and the card is back. It is kept as it is.`
            : 'This card type is not on this server (a resource that adds it may be stopped). It is kept as it is.';
        return back + `<div class="dr-title2">${e(node.type)}</div>`
            + `<div class="dr-prob error">${why}</div>`
            + '<div class="dr-btns"><button class="dr-btn danger" data-act="del-sel">Delete</button></div>';
    }
    const other = def.owner && def.owner !== 'whip_core';
    // A card kept to a permission this builder has not got: to look at, not to change (the server holds
    // its fields to the revision they began from).
    // Scenario Enabled's page is the scenario's settings (how a run starts, its limits, its name: doc.settings), and the
    // last one of it stays (it is where they are).
    const start = node.type === 'scenario.started';
    const lastStart = start && ed.doc.nodes.filter((x) => x.type === node.type).length === 1;
    const fields = start ? scenarioSettings(ed) : cardFields(ed, node, def);
    return back + `<div class="dr-title2"><i class="dr-dot kind-${e(def.tint || def.category)}"></i>${e(def.title)}<span class="dr-idtag">${e(node.id)}</span></div>`
        + (other ? `<div class="dr-hint dr-owner">From <b>${e(def.owner)}</b>, another resource</div>` : '')
        + (def.desc ? `<div class="dr-hint">${e(def.desc)}</div>` : '')
        + (def.help ? `<div class="dr-hint dr-help">${e(def.help)}</div>` : '')
        + (def.locked ? `<div class="dr-prob warn">It needs the permission <b>${e(def.permission || '?')}</b>: you can look at it, not change it.</div>` : '')
        + problemsHtml(mine, 'node:' + node.id)
        + (def.locked ? `<fieldset class="dr-lockset" disabled>${fields}</fieldset>` : fields)
        + cardTry(ed, node)
        + '<div class="dr-btns">' + (def.locked || start ? '' : '<button class="dr-btn" data-act="dup-sel">Duplicate</button>')
        + (lastStart ? '' : '<button class="dr-btn danger" data-act="del-sel">Delete</button>') + '</div>';
}

function coordsText(c) {
    if (!c || typeof c !== 'object' || typeof c.x !== 'number') return null;
    return `${c.x.toFixed(1)}, ${c.y.toFixed(1)}, ${c.z.toFixed(1)} · facing ${Math.round(c.heading || 0)}°`;
}

/** A weapon as its list names it: "Pump Shotgun (shotgun)", and whose for one another resource adds
 *  (shared/weapon_catalog.lua): "Pump Shotgun (shotgun, gunny)". */
function weaponText(x) {
    return x.from ? `${x.label} (${x.group}, ${x.from})` : `${x.label} (${x.group})`;
}

/** An NPC's saved weapon as the list names it: any case (the server reads any), and a hand-written
 *  { name, ammo } by its name. */
function weaponValue(ed, v) {
    const name = (v && typeof v === 'object') ? v.name : v;
    if (typeof name !== 'string' || name === '') return '';
    const up = name.toUpperCase();
    return (ed.weapons || []).some((x) => x.name === up) ? up : name;
}

/** The lore character an empty lore field means (server/director/lore.lua defaultOf): the NPC that starts the
 *  scenario when it is one, else its only lore NPC. null when there is none. */
export function defaultLore(ed) {
    const live = new Map((ed.lore || []).map((c) => [c.key, c]));
    const loreOf = (w) => (w && w.kind === 'npc' && w.def && live.get(w.def.lore)) || null;
    const start = ed.doc.settings && ed.doc.settings.start;
    const first = start && loreOf(ed.doc.world.find((w) => w.id === start.world));
    if (first) return first;
    let only = null;
    for (const w of ed.doc.world) {
        const c = loreOf(w);
        if (c) {
            if (only && only.key !== c.key) return null;
            only = c;
        }
    }
    return only;
}

/** What a placed thing's row and page both say: its kind, whether it is placed, its problems. */
function worldInfo(ed, w) {
    // (A route is its points: where it is, is its first placed one.)
    const first = w.kind === 'route' && Array.isArray(w.def.points) ? w.def.points.find((p) => p && p.at && typeof p.at.x === 'number') : null;
    const placed = w.kind === 'route' ? (first ? coordsText(first.at) : null) : coordsText(w.def.coords);
    // (Its kind's title, things-data.js; a prop with a gun is a Fixed Weapon.)
    const kindText = w.kind === 'prop' && w.def.weapon ? 'Fixed Weapon' : thingIs(w.kind, 'title') || w.kind;
    // Always the run's (its kind's runOnly): Spawn Car makes a car, Lock / Unlock Door holds a door, Create Container
    // makes a container, and the run's end puts each away. A spot and a route are only places (place).
    const place = thingIs(w.kind, 'place');
    // (A car's key spot is its run's too: Spawn Car puts the key there.)
    const runOnly = place || thingIs(w.kind, 'runOnly') || (w.kind === 'groundItem' && typeof w.def.keyOf === 'string');
    const mine = ed.problemList.filter((p) => p.world === w.id);
    const broken = mine.some((p) => p.severity === 'error');
    // (Made by a card is how a thing is unless it says: only Always present is said.)
    const standing = !place && w.layer === 'standing' && !runOnly;
    const pills = `<div class="dr-pills">${standing ? '<span class="dr-pill">Always present</span>' : ''}`
        + (!placed ? `<span class="dr-pill ${broken ? 'err' : 'warn'}">Not placed</span>`
            : (broken ? '<span class="dr-pill err">Needs work</span>' : '')) + '</div>';
    const hasPills = standing || !placed || broken;
    return { placed, kindText, runOnly, mine, pills, hasPills };
}

/** A placed thing in the World list: a click opens its page. */
function worldRow(ed, w) {
    const i = worldInfo(ed, w);
    return '<div class="dr-item">'
        + `<div class="dr-item-head" data-act="world-open" data-id="${e(w.id)}">`
        + worldArt(w)
        + `<div class="dr-item-main"><b>${e(w.label || w.id)}</b><span>${e(i.kindText)} · ${e(w.id)}</span></div>`
        + i.pills + '</div></div>';
}

// ============================================================
// TASKS: what a placed thing does, one after another (server/director/tasks.lua)
// ============================================================
//
// On an NPC's, a car's and a prop's page: its list, each step a numbered row (the open one shows its fields),
// + Task (the picker: only what this kind can do), what happens after the last, and an NPC's Stops to fight.
// Saved in w.def.tasks = { list: [ { k, t, ...fields } ], after, fight }; `k` is a step's own key (its point in
// the world builder is named by it). The catalogue comes from the server with the cards (ed.tasks).

// (The kinds with tasks: their tasks, things-data.js.)
const TARGET_TEXT = { nearest: 'The nearest player', trigger: 'Who set the card off', thing: 'A placed thing', point: 'A point' };
// (A step's own words, doneText and secLabel, are its catalogue's: shared/director/steps.lua.)

const cap = (s) => String(s).charAt(0).toUpperCase() + String(s).slice(1);

/** A thing's task list as saved (an empty one when it has none). */
export function tasksOf(w) {
    const t = w && w.def && w.def.tasks && typeof w.def.tasks === 'object' ? w.def.tasks : null;
    return { list: t && Array.isArray(t.list) ? t.list : [], after: t ? t.after : undefined, fight: t ? t.fight : undefined };
}

/** Which of a list's steps have a point, numbered in order: { [k]: n } (the world builder's marks say the same). */
export function pointNumbers(ed, list) {
    const out = {};
    let n = 0;
    for (const s of list) {
        const def = ed.tasks && ed.tasks.types.get(s.t);
        if (def && taskPoints(def, s).length) out[s.k] = ++n;
    }
    return out;
}

/** The point fields a step has now: its own `at`, or its target's when that is a point. */
export function taskPoints(def, s) {
    const out = [];
    for (const f of def.fields) {
        if (f.kind === 'point') out.push(f.key);
        if (f.kind === 'target' && (s.target || f.default) === 'point') out.push('at');
    }
    return out;
}

function placedText(c) {
    return c && typeof c.x === 'number' ? `${c.x.toFixed(1)}, ${c.y.toFixed(1)}, ${c.z.toFixed(1)}` : null;
}

/** A step's time in seconds: its own, else its type's (0 for none: no end. shared/director/steps.lua THE TIMING). */
function stepTime(s, k, dflt) {
    return typeof s[k] === 'number' ? s[k] : (typeof dflt === 'number' ? dflt : 0);
}

/** A step's time as the line under its name says it: "1 h 30 min", "45 s"; 0 is "no end" (a move's length: "at once"). */
function timeText(sec, length) {
    const n = Number(sec) || 0;
    if (n <= 0) return length ? 'at once' : 'no end';
    if (n < 60) return `${+n.toFixed(1)} s`;
    const r = Math.round(n), h = Math.floor(r / 3600), m = Math.floor(r % 3600 / 60), x = r % 60;
    return [h && `${h} h`, m && `${m} min`, x && `${x} s`].filter(Boolean).join(' ');
}

/** How a step's time works now: its type's, but `until` while its `untilWhen` holds (a Wait for a card: when.js). */
function stepTiming(def, s) {
    return def.untilWhen && holds(def.untilWhen, s, def.fields) ? 'until' : def.timing;
}

/** Does a field show for this step now? One with a `when` only while it holds (when.js). */
function fieldShown(def, s, f) { return holds(f.when, s, def.fields); }

/** The line under a step's name: what it is set to. */
function taskSummary(ed, w, def, s, pointN) {
    const parts = [];
    // (A field that only says which others show, Play Emote's Plays, is said by those.)
    const switches = new Set();
    for (const f of def.fields) whenKeys(f.when, switches);
    for (const f of def.fields) {
        if (!fieldShown(def, s, f) || switches.has(f.key)) continue;
        const v = s[f.key] !== undefined ? s[f.key] : f.default;
        if (f.kind === 'point') parts.push(s[f.key] ? `Point ${pointN}` : 'not placed yet');
        else if (f.kind === 'target') {
            if (v === 'thing') { const o = s.thing && findWorld(ed.doc, s.thing); parts.push(o ? (o.label || o.id) : 'a placed thing'); }
            else if (v === 'point') parts.push(s.at ? `Point ${pointN}` : 'a point, not placed yet');
            else parts.push(TARGET_TEXT[v] || v);
        } else if (f.kind === 'world') { const o = v && findWorld(ed.doc, v); parts.push(o ? (o.label || o.id) : 'nothing picked'); }
        else if (f.kind === 'voice') parts.push(v ? voiceLabel(ed, v) : 'its own voice');
        else if (f.kind === 'speechLine') { if (v) parts.push(lineLabel(v)); }
        else if (f.kind === 'card') {
            const node = typeof v === 'string' && findNode(ed.doc, v);
            const cdef = node && ed.cards.get(node.type);
            parts.push(node ? (cdef ? cdef.title : node.type) : 'no card picked');
        } else if (f.kind === 'cardOuts') {
            const node = typeof s.card === 'string' && findNode(ed.doc, s.card);
            const cdef = node && ed.cards.get(node.type);
            const outs = Array.isArray(v) ? v : [];
            parts.push(outs.length ? 'on ' + outs.map((pin) => (cdef && pinLabel(node, cdef, pin)) || pin).join(' or ') : 'no outcome picked');
        } else if (f.kind === 'number' && f.slider) { if (v !== undefined && v !== null) parts.push(`${f.label.toLowerCase()} ${v}${f.unit || ''}`); }
        else if (f.kind === 'take') { const k = takesOf(w).find((x) => String(x.id) === String(v)); parts.push(k ? takeText(k) : 'no driving event picked'); }
        else if (f.kind === 'bool') { if (v === true) parts.push(f.label.toLowerCase()); }
        else if (f.kind === 'select') { if (v) parts.push(String(v)); }
        else if (f.kind === 'number') {
            const unit = (f.hint || '').startsWith('%') ? '%' : f.hint === 'km/h' ? ' km/h' : '';
            if (v !== undefined && v !== null) parts.push(`${v}${unit}`);
        }
        else if (v) parts.push(String(v));
    }
    let timing = stepTiming(def, s);
    if (timing === 'either') timing = (s.next || def.next) === 'time' ? 'timed' : 'until';
    if (timing === 'timed') parts.push(timeText(stepTime(s, 'sec', def.sec), def.length));
    if (timing === 'until' && def.doneText !== false) parts.push((def.doneText || 'until it is done').toLowerCase());
    return parts.join(' · ');
}

const labelHtml = (text, hint) => label(text, hint);

/** A point's buttons. In the world builder, Place marker puts it on the pointer (a left click on the world puts it
 *  down: app.js placePoint), and Select it selects one already placed; else the builder opens on it. */
function pointButtons(ed, w, k, placed, extra) {
    const at = `data-act="task-point" data-id="${e(w.id)}" data-k="${e(k)}"`;
    if (!ed.inBuilder) {
        return `<button class="dr-btn${placed ? '' : ' primary'}" ${at}>${placed ? 'Show in the world' : 'Place it in the world'}</button>${extra || ''}`;
    }
    return `<button class="dr-btn${placed ? '' : ' primary'}" ${at} data-carry="1">Place marker</button>`
        + (placed ? `<button class="dr-btn" ${at}>Select it</button>` : '') + (extra || '');
}

/** A step that goes to another one's point (several given a task at once share one: app.js syncShared): that point's
 *  thing and step, or null. */
export function sharedOf(ed, s) {
    const id = s && typeof s.share === 'string' ? s.share : '';
    const i = id.lastIndexOf('~');
    const w = i > 0 ? findWorld(ed.doc, id.slice(0, i)) : null;
    const src = w && tasksOf(w).list.find((x) => x && x.k === id.slice(i + 1));
    return src ? { w, s: src } : null;
}

/** A point field's row: which point it is (its number, as its marker in the world says), and its buttons. One shared
 *  with another's step: whose, a way to it, and Its own point (where it is now). */
function pointField(ed, w, s, key, label, n) {
    const sh = sharedOf(ed, s);
    if (sh) {
        const num = pointNumbers(ed, tasksOf(sh.w).list)[sh.s.k];
        return `<div class="dr-row">${labelHtml(label)}<div class="dr-where">${e(`${sh.w.label || sh.w.id}'s point${num ? ' ' + num : ''}, shared`)}</div></div>`
            + `<div class="dr-btns">${pointButtons(ed, sh.w, sh.s.k, !!placedText(sh.s[key]))}`
            + `<button class="dr-btn" data-act="task-unshare" data-id="${e(w.id)}" data-k="${e(s.k)}" title="A point of its own, where the shared one is now">Its own point</button></div>`;
    }
    const placed = placedText(s[key]);
    return `<div class="dr-row">${labelHtml(label)}<div class="dr-where${placed ? '' : ' none'}">${e(placed ? `Point ${n}` : 'Not placed yet')}</div></div>`
        + `<div class="dr-btns">${pointButtons(ed, w, s.k, !!placed)}</div>`;
}

/** An open step's fields, its time, and its buttons. */
function taskFields(ed, w, def, s, i, count, n) {
    const t = `step:${w.id}:${s.k}`;
    let html = '';
    for (const f of def.fields) {
        if (!fieldShown(def, s, f)) continue;
        const v = s[f.key];
        if (f.kind === 'point') html += pointField(ed, w, s, f.key, f.label, n);
        else if (f.kind === 'number' && f.slider) {
            html += sliderField(t, f.key, v, { label: f.label, hint: f.hint, min: f.min, max: f.max, step: f.step || 1,
                fallback: f.default, unit: f.unit || '' });
        }
        // A Wait for a card: which card (Pick a card, then a click on it on the grid: app.js task-card-pick), and which
        // of its outcomes end the wait.
        else if (f.kind === 'card') {
            const node = typeof v === 'string' && findNode(ed.doc, v);
            const cdef = node && ed.cards.get(node.type);
            const picking = ed.cardPickFor && ed.cardPickFor.id === w.id && ed.cardPickFor.k === s.k;
            html += `<div class="dr-row">${labelHtml(f.label)}<div class="dr-where${node ? '' : ' none'}">${e(picking ? 'Click a card in the Blueprint'
                : node ? (cdef ? cdef.title : node.type) : (v ? 'Its card is gone' : 'No card picked'))}</div></div>`
                + '<div class="dr-btns">' + (picking
                    ? `<button class="dr-btn" data-act="task-card-cancel">Cancel</button>`
                    : `<button class="dr-btn${node ? '' : ' primary'}" data-act="task-card-pick" data-id="${e(w.id)}" data-k="${e(s.k)}">${node ? 'Pick another card' : 'Pick a card'}</button>`)
                + '</div>';
        }
        else if (f.kind === 'cardOuts') {
            const node = typeof s.card === 'string' && findNode(ed.doc, s.card);
            const cdef = node && ed.cards.get(node.type);
            if (cdef) {
                const on = new Set(Array.isArray(v) ? v : []);
                // (Its outcomes as the card shows them: an empty answer or choice has none.)
                html += `<div class="dr-row"><div class="dr-label">${e(f.label)}<span>any one picked</span></div></div>`
                    + pinsOf(ed.doc, node, cdef).outputs.map(({ pin, label: text }) => `<button class="dr-sw" role="switch" aria-checked="${on.has(pin)}" data-act="task-out" data-id="${e(w.id)}" data-k="${e(s.k)}" data-pin="${e(pin)}">`
                        + `<span class="dr-sw-name">${e(text || 'Done')}</span><span class="dr-switch${on.has(pin) ? ' on' : ''}"></span></button>`).join('');
            }
        }
        // GTA Speech: whose voice (the voice picker: voicePicker) and which of its lines, heard with Preview.
        else if (f.kind === 'voice') {
            html += `<div class="dr-row">${labelHtml(f.label)}<div class="dr-where">${e(v ? voiceLabel(ed, v) : 'Its own voice')}</div></div>`
                + `<div class="dr-btns"><button class="dr-btn" data-act="voice-open" data-id="${e(w.id)}" data-k="${e(s.k)}">Choose a voice</button>`
                + (v ? `<button class="dr-btn" data-act="voice-clear" data-id="${e(w.id)}" data-k="${e(s.k)}">Its own voice</button>` : '') + '</div>';
        }
        else if (f.kind === 'speechLine') {
            const lines = speechLines(ed, s.voice);
            if (!lines) html += textField(t, f.key, v, { label: f.label, max: f.max, placeholder: f.hint || '' });
            else {
                const opts = lines.map((n) => [n, lineLabel(n)]);
                if (v && !lines.includes(v)) opts.unshift([v, `${lineLabel(v)} (not in this voice)`]);
                html += selectField(t, f.key, v, opts, { label: f.label, none: '— pick a line —',
                    hint: s.voice ? `${lines.length} lines in this voice` : 'the lines most voices have' });
            }
            html += `<div class="dr-btns"><button class="dr-btn" data-act="speech-hear" data-id="${e(w.id)}" data-k="${e(s.k)}"${v ? '' : ' disabled'}>Preview</button></div>`;
        }
        // An emote: typed, or picked from the emote menu (its pictures and videos: app.js task-emote-pick).
        else if (f.kind === 'emote') {
            html += textField(t, f.key, v, { label: f.label, max: f.max, placeholder: f.hint || '' })
                + `<div class="dr-btns"><button class="dr-btn" data-act="task-emote-pick" data-id="${e(w.id)}" data-k="${e(s.k)}">Choose from the emote menu</button></div>`;
        }
        else if (f.kind === 'select' && f.look === 'seg') html += segField(t, f.key, v, f.options.map((o) => [o, cap(o)]), { label: f.label, fallback: f.default, inline: !f.hint });
        else if (f.kind === 'select') html += selectField(t, f.key, v === undefined ? f.default : v, f.options.map((o) => [o, cap(o)]), { label: f.label, none: '— pick one —', noEmpty: f.default !== undefined });
        else if (f.kind === 'bool') html += switchField(t, f.key, v, { label: f.label, fallback: f.default === true, hint: f.hint });
        else if (f.kind === 'number') html += numberField(t, f.key, v, { label: f.label, hint: f.hint, min: f.min, max: f.max, placeholder: f.default != null ? String(f.default) : '' });
        else if (f.kind === 'text') html += textField(t, f.key, v, { label: f.label, max: f.max, placeholder: f.hint || '' });
        else if (f.kind === 'weapon') {
            html += ed.weapons && ed.weapons.length
                ? selectField(t, f.key, weaponValue(ed, v), ed.weapons.map((x) => [x.name, weaponText(x)]), { label: f.label, none: '— put it away —' })
                : textField(t, f.key, v, { label: f.label, max: 64, placeholder: f.hint || 'WEAPON_PISTOL' });
        } else if (f.kind === 'world') {
            html += selectField(t, f.key, v, worldOptions(ed, f.worldKind), { label: f.label, none: '— pick a placed thing —' });
        } else if (f.kind === 'take') {
            const takes = takesOf(w);
            html += selectField(t, f.key, v == null ? '' : String(v), takes.map((k) => [String(k.id), takeText(k)]),
                { label: f.label, none: '— pick a driving event —', hint: takes.length ? '' : 'record one: Scripted Driving Events, above' });
        } else if (f.kind === 'target') {
            const cur = v === undefined ? f.default : v;
            html += selectField(t, f.key, cur, f.options.map((o) => [o, TARGET_TEXT[o] || o]), { label: f.label, none: '— pick one —' });
            if (cur === 'thing') html += selectField(t, 'thing', s.thing, worldOptions(ed, null).filter(([id]) => id !== w.id), { label: 'Which', none: '— pick a placed thing —' });
            if (cur === 'point') html += pointField(ed, w, s, 'at', 'The point', n);
        }
    }
    // Its time: hours, minutes and seconds, each typed or picked from its list, 0 for no end. Shown as it plays, never
    // greyed (Josh, 14 Nov 2026: a greyed 3 looked like nothing set, and the step stopped after 3 seconds).
    const secField = () => timeField(t, 'sec', stepTime(s, 'sec', def.sec), { label: def.secLabel || 'For', units: 'hms',
        hint: def.length ? '0: at once' : '0: no end, it goes on' });
    const giveField = () => timeField(t, 'giveUp', stepTime(s, 'giveUp', def.giveUp), { label: 'Gives up after', units: 'hms',
        hint: 'then the next one; 0: never' });
    if (stepTiming(def, s) === 'until' && def.timing === 'timed') html += giveField();   // (a Wait for a card)
    else if (def.timing === 'timed') html += secField();
    else if (def.timing === 'until') html += giveField();
    else if (def.timing === 'either') {
        const next = s.next || def.next;
        html += segField(t, 'next', s.next, [['done', def.doneText || 'When it is done'], ['time', 'After a time']], { label: 'The next one starts', fallback: def.next });
        html += next === 'time' ? secField() : giveField();
    }
    html += '<div class="dr-btns">'
        + `<button class="dr-btn" data-act="task-move" data-id="${e(w.id)}" data-k="${e(s.k)}" data-by="-1"${i === 0 ? ' disabled' : ''}>Move up</button>`
        + `<button class="dr-btn" data-act="task-move" data-id="${e(w.id)}" data-k="${e(s.k)}" data-by="1"${i === count - 1 ? ' disabled' : ''}>Move down</button>`
        + `<button class="dr-btn danger" data-act="task-remove" data-id="${e(w.id)}" data-k="${e(s.k)}">Remove</button></div>`;
    return html;
}

/** In the world builder, over a thing's Tasks: Play Tasks (its tasks on its copy there, only on this screen:
 *  client/director_preview.lua), Stop Tasks, and the things that play with it, from the same moment (kept with its
 *  tasks, as playWith: only the preview reads it). Played to its end, it goes back by itself a moment after; a line
 *  between this and the list. ed.preview: { state: 'playing' | 'done' | 'idle', ids, note }. */
function previewBlock(ed, w, list) {
    if (!ed.inBuilder) return '';
    const pv = ed.preview || {};
    const mine = Array.isArray(pv.ids) && pv.ids.includes(w.id);
    const playing = mine && pv.state === 'playing';
    const withIds = w.def.tasks && Array.isArray(w.def.tasks.playWith) ? w.def.tasks.playWith : [];
    const others = ed.doc.world.filter((x) => x.id !== w.id && thingIs(x.kind, 'tasks') && tasksOf(x).list.length);
    let html = '<div class="dr-btns">'
        + (playing ? '<button class="dr-btn danger" data-act="preview-stop">Stop Tasks</button>'
            : `<button class="dr-btn primary" data-act="preview-play" data-id="${e(w.id)}"${list.length ? '' : ' disabled'}>Play Tasks</button>`)
        + '</div>';
    if (pv.note && (mine || pv.state === 'idle')) html += `<div class="dr-hint warn">${e(pv.note)}</div>`;
    if (others.length) {
        html += '<div class="dr-row"><div class="dr-label">Play with<span>their tasks start at the same moment</span></div></div>'
            + others.map((x) => {
                const on = withIds.includes(x.id);
                return `<button class="dr-sw" role="switch" aria-checked="${on}" data-act="preview-with" data-id="${e(w.id)}" data-with="${e(x.id)}">`
                    + `<span class="dr-sw-name">${e(x.label || x.id)}<small>${e(worldInfo(ed, x).kindText)} · ${plural(tasksOf(x).list.length, 'task')}</small></span>`
                    + `<span class="dr-switch${on ? ' on' : ''}"></span></button>`;
            }).join('');
    }
    return html + '<div class="dr-sep"></div>';
}

/** "NPC" / "car" / "prop": what a thing is called in a sentence (its noun, things-data.js). */
const nounOf = (kind) => thingIs(kind, 'noun') || 'thing';

/** A placed thing's Tasks (its page's Tasks tab: `inTab`, no head over it). */
function tasksGroup(ed, w, inTab) {
    if (!ed.tasks || !thingIs(w.kind, 'tasks')) return '';
    const tasks = tasksOf(w);
    const list = tasks.list;
    const numbers = pointNumbers(ed, list);
    const mine = ed.problemList.filter((p) => p.world === w.id && /, task \d+ \(/.test(p.message || ''));
    let html = previewBlock(ed, w, list) + (inTab ? '' : groupHead('Tasks'));
    list.forEach((s, i) => {
        const def = ed.tasks.types.get(s.t);
        const key = w.id + '~' + s.k;
        const open = ed.taskOpen === key;
        const bad = !def || mine.some((p) => (p.message || '').includes(`, task ${i + 1} (`));
        html += `<div class="dr-item${open ? ' open' : ''}">`
            + `<div class="dr-item-head" data-act="task-open" data-id="${e(w.id)}" data-k="${e(s.k)}">`
            + `<span class="dr-task-n${open ? ' on' : ''}">${i + 1}</span>`
            + `<div class="dr-item-main"><b>${e(def ? def.label : s.t)}</b><span>${e(def ? taskSummary(ed, w, def, s, numbers[s.k]) : 'not a task this server has')}</span></div>`
            + (bad ? '<div class="dr-pills"><span class="dr-pill err">Needs work</span></div>' : '')
            + '</div>'
            + (open && def ? `<div class="dr-world-edit">${taskFields(ed, w, def, s, i, list.length, numbers[s.k])}</div>` : '')
            + '</div>';
    });
    if (!list.length) html += `<div class="dr-none">There are no tasks for this ${e(nounOf(w.kind))}</div>`;
    html += '<div class="dr-btns">'
        + (list.length < (ed.tasks.max || 40) ? `<button class="dr-btn" data-act="task-add" data-id="${e(w.id)}">+ Task</button>` : '')
        + `<button class="dr-btn" data-act="task-copy" data-id="${e(w.id)}" title="Another ${e(nounOf(w.kind))}'s tasks, copied onto this one">Copy existing</button>`
        + '</div>';
    if (list.length) {
        const t = 'tasks:' + w.id;
        html += segField(t, 'after', tasks.after, [['stop', 'It stops'], ['loop', 'It starts again']], { label: 'When the last one ends', fallback: 'stop' });
        if (w.kind === 'npc') {
            html += switchField(t, 'fight', tasks.fight, { label: 'Stops to fight', fallback: true,
                hint: 'Attacked, or someone to fight: it fights, and its tasks end' });
        }
    }
    return html;
}

// ---- GTA Speech: the game's voices and their lines (html/js/director/speech-voices.js, ed.speech once it is read) ----

const VOICE_GROUPS = [['a', 'Passers-by'], ['g', 'Gangs'], ['s', 'Jobs and services'], ['n', 'Story and others']];

/** A line as people read it: GENERIC_INSULT_HIGH is "Insult high". */
export function lineLabel(name) {
    const s = String(name || '').replace(/^GENERIC_/, '').toLowerCase().replace(/_/g, ' ').trim();
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : String(name || '');
}

/** A voice's name as the picker says it (its ped and accent), or its own name when the list has not got it. */
function voiceLabel(ed, name) {
    const v = ed.speech && ed.speech.byName.get(name);
    return v ? v.label : String(name);
}

/** The lines a voice has (none picked: all of them, the most shared first), or null before the list is read. */
function speechLines(ed, voice) {
    const sp = ed.speech;
    if (!sp) return null;
    const v = voice ? sp.byName.get(voice) : null;
    return v ? v.lines.map((i) => sp.lines[i]) : sp.lines.slice();
}

/** THE VOICE PICKER, over the thing's page (ed.voicePick: { id, k, query, group }): every voice by its group, a
 *  search across all of them; each row picks its voice, and its Hear says the step's line in it (a hello when the
 *  step has none, or the voice has not got it). */
function voicePicker(ed, w) {
    const p = ed.voicePick;
    const s = tasksOf(w).list.find((x) => x.k === p.k);
    const back = `<button class="dr-back" data-act="voice-back">${ICON.back}${e(w.label || w.id)}</button>`;
    const sp = ed.speech;
    if (!sp || !s) return back + '<div class="dr-none">Reading the game\'s voices…</div>';
    const q = (p.query || '').trim().toLowerCase();
    const group = VOICE_GROUPS.some(([g]) => g === p.group) ? p.group : 'a';
    const counts = {};
    for (const v of sp.voices) counts[v.group] = (counts[v.group] || 0) + 1;
    const shown = sp.voices.filter((v) => (q ? v.label.toLowerCase().includes(q) || v.name.toLowerCase().includes(q) : v.group === group));
    const chip = (g, text) => `<button class="dr-chip plain${!q && g === group ? ' on' : ''}" data-act="voice-group" data-group="${e(g)}">${e(text)} <em>${counts[g] || 0}</em></button>`;
    const rows = shown.map((v) => `<div class="dr-voice-row"><button class="dr-pick-row${v.name === s.voice ? ' on' : ''}" data-act="voice-pick" data-voice="${e(v.name)}">`
        + `<span class="dr-pick-main"><b>${e(v.label)}</b><span>${e(v.name)} · ${v.lines.length} lines</span></span></button>`
        + `<button class="dr-btn" data-act="voice-hear" data-voice="${e(v.name)}" title="Say ${e(lineLabel(s.line || 'GENERIC_HI'))} in this voice">Hear</button></div>`).join('');
    // (In the world builder its panel's title says it already.)
    return '<div class="dr-pal-top">' + back
        + (ed.inBuilder ? '' : '<div class="dr-pick-head"><div class="dr-title2">Choose a voice</div></div>')
        + `<div class="dr-search-box">${ICON.search}<input class="dr-field dr-pick-search dr-voice-search" type="text" placeholder="Search ${sp.voices.length} voices" value="${e(p.query || '')}" spellcheck="false" aria-label="Search voices"></div>`
        + '<div class="dr-chips">' + VOICE_GROUPS.map(([g, text]) => chip(g, text)).join('') + '</div>'
        + `<div class="dr-pick-count">${plural(shown.length, 'voice')}${q ? ` matching “${e(p.query.trim())}”` : ''}</div>`
        + '</div>'
        + `<div class="dr-pal-list dr-pick-list">${rows || '<div class="dr-none">No voice matches</div>'}</div>`;
}

/** + Task: the tasks this kind can do, by group; one picked goes at the end of the list. `many`: several selected (all
 *  of `w`'s kind), and it goes on the end of each one's (app.js task-pick). */
function taskPicker(ed, w, many) {
    const kind = w.kind;
    const groups = ed.tasks.groups.map((g) => ({ ...g, types: ed.tasks.order.map((t) => ed.tasks.types.get(t))
        .filter((d) => d.group === g.key && d.kinds.includes(kind)) })).filter((g) => g.types.length);
    const TINT = { move: 'c-blue', look: 'c-teal', fight: 'c-red', act: 'c-violet', car: 'c-amber', body: 'c-green', wait: 'c-slate' };
    // Back to its page, at the top (in the world builder too: under a long list it was out of sight).
    const back = `<button class="dr-back" data-act="task-pick-back">${ICON.back}${e(many ? `${many.length} selected` : w.label || w.id)}</button>`;
    // (In the world builder the panel's own title says "Add a task": the head names the thing instead.)
    const head = many ? [e(kindCount(kind, many.length)), 'one at the end of each list']
        : ed.inBuilder ? [e(w.label || w.id), 'one at the end of its list'] : ['Add a task', 'one at the end of its list'];
    return back
        + `<div class="dr-page-head">${many ? '' : worldArt(w)}<div class="dr-item-main"><b>${head[0]}</b><span>${head[1]}</span></div></div>`
        + '<div class="dr-chips">' + groups.map((g) => `<button class="dr-chip kind-${TINT[g.key] || 'c-slate'}" data-act="task-jump" data-cat="${e(g.key)}">${e(g.title)} <em>${g.types.length}</em></button>`).join('') + '</div>'
        + '<div class="dr-pal-list dr-task-pal">' + groups.map((g) => `<div class="dr-cat line kind-${TINT[g.key] || 'c-slate'}" data-cat="${e(g.key)}">${e(g.title)}</div>`
            + g.types.map((d) => `<div class="dr-pal-row line" data-act="task-pick" data-id="${e(w.id)}" data-type="${e(d.t)}"><b>${e(d.label)}</b></div>`).join('')).join('') + '</div>';
}

/** Copy existing, over a thing's page: the scenario's other things of its kind with tasks; one picked, its tasks (to
 *  look at, not change) and Copy, which makes them this one's (app.js copyTasks: asked first when it has some). `many`:
 *  several selected, and the tasks go onto each of them but the one they come from. */
function taskCopier(ed, w, many) {
    const noun = nounOf(w.kind);
    const from = ed.taskCopy.from ? findWorld(ed.doc, ed.taskCopy.from) : null;
    // Back to its page, at the top (in the world builder too).
    const back = `<button class="dr-back" data-act="task-copy-back">${ICON.back}${e(many ? `${many.length} selected` : w.label || w.id)}</button>`;
    const foot = (html) => (html ? `<div class="dr-btns">${html}</div>` : '');
    if (!from) {
        const others = ed.doc.world.filter((x) => x.kind === w.kind && (many || x.id !== w.id) && tasksOf(x).list.length);
        const rows = others.map((x) => {
            const n = tasksOf(x).list.length;
            return `<div class="dr-item"><div class="dr-item-head" data-act="task-copy-from" data-from="${e(x.id)}">${worldArt(x)}`
                + `<div class="dr-item-main"><b>${e(x.label || x.id)}</b><span>${plural(n, 'task')}</span></div></div></div>`;
        }).join('');
        return back
            + `<div class="dr-page-head">${many ? '' : worldArt(w)}<div class="dr-item-main"><b>${e(many ? 'Copy tasks' : ed.inBuilder ? w.label || w.id : 'Copy tasks')}</b>`
            + `<span>${e(many ? `onto all ${many.length}, from one ${noun}` : `from another ${noun} in this scenario`)}</span></div></div>`
            + (rows || `<div class="dr-none">No ${many ? '' : 'other '}${e(noun)} here has tasks yet</div>`);
    }
    const tasks = tasksOf(from);
    const numbers = pointNumbers(ed, tasks.list);
    const rows = tasks.list.map((s, i) => {
        const def = ed.tasks.types.get(s.t);
        return '<div class="dr-item"><div class="dr-item-head dr-item-still">'
            + `<span class="dr-task-n">${i + 1}</span>`
            + `<div class="dr-item-main"><b>${e(def ? def.label : s.t)}</b><span>${e(def ? taskSummary(ed, from, def, s, numbers[s.k]) : 'not a task this server has')}</span></div>`
            + '</div></div>';
    }).join('');
    const onto = many ? many.filter((x) => x.id !== from.id) : [w];
    const had = onto.filter((x) => tasksOf(x).list.length);
    const replaced = !had.length ? ''
        : many ? `Copied, they replace the tasks ${had.length === 1 ? e(had[0].label || had[0].id) + ' has' : `${had.length} of them have`} now.`
        : `Copied, they replace the ${plural(tasksOf(w).list.length, 'task')} ${e(w.label || w.id)} has now.`;
    return back
        + `<div class="dr-page-head">${worldArt(from)}<div class="dr-item-main"><b>${e(from.label || from.id)}</b>`
        + `<span>${plural(tasks.list.length, 'task')} · when the last one ends, ${tasks.after === 'loop' ? 'it starts again' : 'it stops'}</span></div></div>`
        + rows
        + (replaced ? `<div class="dr-hint">${replaced}</div>` : '')
        + foot(`<button class="dr-btn primary" data-act="task-copy-do" data-id="${e(many ? MANY : w.id)}" data-from="${e(from.id)}"${onto.length ? '' : ' disabled'}>`
            + `${e(many ? `Copy onto ${onto.length === many.length ? 'all' : 'the other'} ${onto.length}` : `Copy this ${noun}'s tasks`)}</button>`
            + '<button class="dr-btn" data-act="task-copy-from" data-from="">Back to the list</button>');
}

// ============================================================
// A CAR'S SCRIPTED DRIVING EVENTS AND RIDERS (server/director/takes.lua, nodes_tasks.lua's Play Scripted Driving Event)
// ============================================================
//
// What players see as Scripted Driving Events are the code's takes: its recorded drives (w.def.takes = [ { id, label,
// ms, made } ]); the recording itself is kept by the server, by id. Riders: NPCs of the World tab who sit in it, each in
// a seat (w.def.riders = [ { npc, seat } ]), made in their seats as one plays; the page offers one, the driver (NPC
// rides in this vehicle?), and shows any more a car had from before.

const SEATS = ['driver', 'front passenger', 'back left', 'back right'];

/** A car's takes as its page keeps them. */
export function takesOf(w) {
    const list = w && w.def && Array.isArray(w.def.takes) ? w.def.takes : [];
    return list.filter((t) => t && Number.isFinite(Number(t.id)));
}

/** "Driving event 2 · 0:22" */
export function takeText(t) {
    const s = Math.round((Number(t.ms) || 0) / 100) / 10;
    return `${t.label || 'Driving event ' + t.id} · ${clock(s, true)}`;
}

/** NPC rides in this vehicle? On, the NPC who does (in the driver's seat); a car with more riders from before shows
 *  them too, each with its seat. Off takes them all out. */
function ridersGroup(ed, w) {
    const riders = Array.isArray(w.def.riders) ? w.def.riders : [];
    const npcs = worldOptions(ed, 'npc');
    const on = riders.length > 0;
    let html = `<button class="dr-sw" role="switch" aria-checked="${on}" data-act="riders-toggle" data-id="${e(w.id)}"${npcs.length || on ? '' : ' disabled'}>`
        + '<span class="dr-sw-name">NPC rides in this vehicle?</span>'
        + `<span class="dr-switch${on ? ' on' : ''}"></span></button>`;
    riders.forEach((r, i) => {
        html += selectField(`rider:${w.id}:${i}`, 'npc', r.npc, npcs,
            { label: i === 0 ? 'NPC' : `Also in it (${SEATS.includes(r.seat) ? r.seat : 'a seat'})`, none: '— pick an NPC —' });
    });
    if (!npcs.length) html += '<div class="dr-hint">Place an NPC in the world builder first.</div>';
    return html;
}

/** Tows (w.def.tow): another of the scenario's cars, a trailer, hitched behind this one: Spawn Car makes both and the
 *  game that owns this one hitches it (server/actors.lua setTow); a recording starts with it on, and saves where it went
 *  (client/director_takes.lua). Placed a few metres behind, it is drawn onto the hitch. */
function towField(ed, w, d) {
    const others = ed.doc.world.filter((x) => x.kind === 'vehicle' && x.id !== w.id && x.def && !x.def.random)
        .map((x) => [x.id, `${x.label || x.id}${x.def.model ? ` (${x.def.model})` : ''}`]);
    if (!others.length && !w.def.tow) return '';
    return selectField(d, 'tow', typeof w.def.tow === 'string' ? w.def.tow : '', others, { label: 'Tows', none: 'nothing',
        hint: 'a trailer, placed just behind: made and hitched with it, and on it when you record' });
}

/** "with Box trailer" for a take that hitched one (its tow: client/director_takes.lua), or ''. */
function towText(ed, k) {
    const tracks = k.tow && k.tow.tracks && typeof k.tow.tracks === 'object' ? Object.keys(k.tow.tracks) : [];
    if (!tracks.length) return '';
    return ' · with ' + tracks.map((wid) => { const x = findWorld(ed.doc, wid); return x ? (x.label || x.id) : `${wid} (gone)`; }).join(', ');
}

function takesGroup(ed, w) {
    const takes = takesOf(w);
    let html = groupHead('Scripted Driving Events');
    takes.forEach((k, i) => {
        const key = `${w.id}#${k.id}`;
        const open = ed.takeOpen === key;
        html += `<div class="dr-item${open ? ' open' : ''}">`
            + `<div class="dr-item-head" data-act="take-open" data-id="${e(w.id)}" data-take="${e(String(k.id))}">`
            + `<span class="dr-task-n${open ? ' on' : ''}">${i + 1}</span>`
            + `<div class="dr-item-main"><b>${e(k.label || 'Driving event ' + (i + 1))}</b><span>${e(takeText(k).split(' · ')[1])}${k.made ? ' · recorded ' + e(dateTime(k.made, '')) : ''}${e(towText(ed, k))}</span></div>`
            + (usedTake(ed, k.id) ? '<div class="dr-pills"><span class="dr-pill ok">Used</span></div>' : '')
            + '</div>'
            + (open ? '<div class="dr-world-edit">'
                + textField(`take:${w.id}:${k.id}`, 'label', k.label, { label: 'Name', max: 40, placeholder: 'Driving event ' + (i + 1) })
                // (In the world builder: played on the car's copy there, its riders in their seats, its line drawn: you
                // stay in the free camera. In the Director: you ride along in a copy of the car.)
                + (ed.inBuilder
                    ? (ed.preview && ed.preview.state === 'playing' && (ed.preview.ids || []).includes(w.id)
                        ? '<div class="dr-btns"><button class="dr-btn danger" data-act="preview-stop">Stop</button>'
                        : `<div class="dr-btns"><button class="dr-btn primary" data-act="take-preview" data-id="${e(w.id)}" data-take="${e(String(k.id))}">Play here</button>`)
                    : `<div class="dr-btns"><button class="dr-btn primary" data-act="take-watch" data-id="${e(w.id)}" data-take="${e(String(k.id))}">Watch it</button>`)
                + `<button class="dr-btn danger" data-act="take-remove" data-id="${e(w.id)}" data-take="${e(String(k.id))}">Remove</button></div>`
                + '</div>' : '')
            + '</div>';
    });
    const placed = w.def.coords && typeof w.def.coords.x === 'number';
    // (How recording goes is said while it is under way: client/director_takes.lua. Only why the button is off is said here.)
    html += `<div class="dr-btns"><button class="dr-btn primary" data-act="take-record" data-id="${e(w.id)}"${placed && w.def.model ? '' : ' disabled'}>Record a Scripted Driving Event</button></div>`
        + (placed ? '' : '<div class="dr-hint">Place the car first: you drive from where it is placed.</div>')
        + (placed ? '<div class="dr-hint">While you record, the scenario\'s other cars with no take stand where they are placed: back into a trailer to hook it. A trailer you hook is saved as it went, and plays that way with the car. Cars with a take drive it beside you, with their trailers.</div>' : '');
    return html;
}

/** Does a card play this take? */
function usedTake(ed, id) {
    return ed.doc.nodes.some((n) => {
        const def = ed.cards.get(n.type);
        return def && def.props.some((f) => f.kind === 'take' && String(n.props[f.key]) === String(id));
    }) || ed.doc.world.some((w) => tasksOf(w).list.some((s) => s.t === 'take' && String(s.take) === String(id)));
}

// ============================================================
// ROUTES, WHAT A GUARD SEES (server/director/routes.lua, vision.lua)
// ============================================================
//
// A route is a place of points walked in turn (w.def = { points: [ { k, at, wait, act, emote, scenario } ], order, pace,
// findWay }):
// an NPC walks it by its Tasks (Walk a Route). What a guard sees is w.def.vision = { on, range, cone, spotS, sneak,
// alert, react }. Each point is placed in the world builder as a task's point is (app.js pointThings).

const ORDERS = [['loop', 'In order'], ['pingpong', 'Back and forth'], ['random', 'At random']];
const ACTS = [['stand', 'Stands'], ['look', 'Looks around'], ['emote', 'An emote'], ['scenario', 'A scenario']];
const ALERTS = [['self', 'Just this guard'], ['group', 'Its group'], ['near', 'Nearby NPCs that react to danger']];
const REACTS = [['attack', 'Attack'], ['look', 'Come to look'], ['card', 'Only the card']];

const routePoints = (w) => (w && Array.isArray(w.def.points) ? w.def.points.filter((p) => p && p.k) : []);
const placedAt = (p) => p && p.at && typeof p.at.x === 'number';

/** What a route point does there, as its row says it. */
function pointText(p) {
    const wait = Number(p.wait) || 0;
    if (wait <= 0) return 'walks straight on';
    const act = p.act === 'look' ? ' · looks around' : p.act === 'emote' ? ` · ${p.emote ? '/e ' + p.emote : 'an emote, not picked'}`
        : p.act === 'scenario' ? ` · ${p.scenario || 'a scenario, not picked'}` : '';
    return `waits ${wait} s${act}`;
}

/** A numbered row that opens (a route's point): `act` names the open action. */
function placeRow(ed, w, p, i, act, name, text, body) {
    const key = `${w.id}~${p.k}`;
    const open = ed.taskOpen === key;
    return `<div class="dr-item${open ? ' open' : ''}">`
        + `<div class="dr-item-head" data-act="${act}" data-id="${e(w.id)}" data-k="${e(p.k)}">`
        + `<span class="dr-task-n${open ? ' on' : ''}">${i + 1}</span>`
        + `<div class="dr-item-main"><b>${e(name)}</b><span>${e(text)}</span></div>`
        + (placedAt(p) ? '' : '<div class="dr-pills"><span class="dr-pill warn">Not placed</span></div>')
        + '</div>'
        + (open ? `<div class="dr-world-edit">${body()}</div>` : '')
        + '</div>';
}

/** Whether a point is placed, and its buttons (Place marker, Select it: pointButtons). */
function placeButtons(ed, w, p, i, count, list) {
    const placed = placedText(p.at);
    return `<div class="dr-row">${labelHtml('Where')}<div class="dr-where${placed ? '' : ' none'}">${e(placed ? 'Placed' : 'Not placed yet')}</div></div>`
        + '<div class="dr-btns">'
        + pointButtons(ed, w, p.k, !!placed)
        + `<button class="dr-btn" data-act="place-move" data-list="${list}" data-id="${e(w.id)}" data-k="${e(p.k)}" data-by="-1"${i === 0 ? ' disabled' : ''}>Move up</button>`
        + `<button class="dr-btn" data-act="place-move" data-list="${list}" data-id="${e(w.id)}" data-k="${e(p.k)}" data-by="1"${i === count - 1 ? ' disabled' : ''}>Move down</button>`
        + `<button class="dr-btn danger" data-act="place-remove" data-list="${list}" data-id="${e(w.id)}" data-k="${e(p.k)}">Remove</button></div>`;
}

/** A route's page: its points, and how they are walked. */
function routeGroups(ed, w) {
    const pts = routePoints(w);
    const order = w.def.order || 'loop';
    const walkers = ed.doc.world.filter((x) => x.kind === 'npc' && routesWalked(x).includes(w.id));
    let html = groupHead('Points')
        + `<div class="dr-hint">${e((ed.inBuilder ? 'Point 1 is where the route was put down. + Point puts the next one in front of the camera: move it like anything placed.'
            : 'Point 1 is where the route was put down. + Point opens the world builder with the next one in front of the camera.')
            + ' Turn a point to set where the NPC faces while it waits there. Remove one and the rest are numbered again.')}</div>`;
    pts.forEach((p, i) => {
        const t = `rpoint:${w.id}:${p.k}`;
        html += placeRow(ed, w, p, i, 'place-open', `Point ${i + 1}`, pointText(p), () => {
            let body = numberField(t, 'wait', p.wait, { label: 'Waits there', hint: 'seconds (empty: walks straight on)', min: 0, max: 600, placeholder: '0' });
            if ((Number(p.wait) || 0) > 0) {
                body += segField(t, 'act', p.act, ACTS, { label: 'While it waits', fallback: 'stand' });
                if (p.act === 'emote') body += textField(t, 'emote', p.emote, { label: 'Emote', max: 40, placeholder: 'smoke', hint: '/e name' });
                if (p.act === 'scenario') body += textField(t, 'scenario', p.scenario, { label: 'Scenario', max: 64, placeholder: 'WORLD_HUMAN_SMOKING' });
            }
            return body + placeButtons(ed, w, p, i, pts.length, 'points');
        });
    });
    if (!pts.length) html += '<div class="dr-none">No points yet</div>';
    if (pts.length < 24) html += `<div class="dr-btns"><button class="dr-btn" data-act="place-add" data-list="points" data-id="${e(w.id)}">+ Point</button></div>`;
    const d = 'def:' + w.id;
    html += groupHead('How it is walked')
        + segField(d, 'order', order === 'once' ? 'loop' : order, ORDERS, { label: 'Order', fallback: 'loop',
            hint: order === 'random' ? 'any point next, never the same one twice' : order === 'pingpong' ? 'to the last, then back the way it came' : '' });
    if (order === 'loop' || order === 'once') {
        html += segField(d, 'order', order, [['loop', 'Back to the first'], ['once', 'Stops there']], { label: 'At the last point', fallback: 'loop' });
    }
    html += segField(d, 'pace', w.def.pace, [['walk', 'Walk'], ['run', 'Run']], { label: 'Pace', fallback: 'walk', inline: true });
    // (At random the lines between points were never drawn: it always finds its own way. server/director/routes.lua)
    if (order !== 'random') {
        html += switchField(d, 'findWay', w.def.findWay, { label: 'Finds its own way', fallback: false,
            hint: w.def.findWay === true ? 'Its own path between points, round anything in the way' : 'The straight line from point to point' });
    }
    html += `<div class="dr-hint">${e(walkers.length ? 'Walked by ' + walkers.map((x) => x.label || x.id).join(', ') + '.' : 'No NPC walks it yet: add Walk a Route to an NPC\'s Tasks.')}</div>`;
    return html;
}

/** The routes an NPC's tasks walk (Walk a Route), by id. */
const routesWalked = (w) => (w && w.def.tasks && Array.isArray(w.def.tasks.list) ? w.def.tasks.list : [])
    .filter((s) => s && s.t === 'walkRoute' && s.route).map((s) => s.route);
const walksRoute = (w) => routesWalked(w).length > 0;

/** A slider's place along its track, as a percentage (its filled part: --p). */
export function sliderPct(el) {
    const lo = Number(el.min), hi = Number(el.max), v = Number(el.value);
    return hi > lo ? Math.round(((v - lo) / (hi - lo)) * 1000) / 10 : 0;
}

/** What a slider says beside it: its value and unit, or an Outfit's "2 / 5" (data-of) and None (data-none, below 0). */
export function sliderText(el) {
    const v = Number(el.value);
    if (el.dataset.none && v < 0) return el.dataset.none;
    if (el.dataset.of) return `${v + 1} / ${el.dataset.of}`;
    return el.value + (el.dataset.unit || '');
}

// ---- An NPC's Outfit (w.def.outfit, client/ped_outfit.lua): what its ped wears, part by part ----
//
// Saved flat: c<part>d / c<part>t a part's style and colour, p<prop>d / p<prop>t a prop's (p<prop>d -1: none). What
// its ped has comes from the game (app.js askPedOpts: ed.pedOpts[model] = { c, p }, each { i, n, t: [colours] }), so
// only those parts are shown. A lore character wears their own look.

const OUTFIT_PARTS = { 0: 'Head', 1: 'Beard or mask', 2: 'Hair', 3: 'Upper body', 4: 'Legs', 5: 'Hands or bag', 6: 'Feet',
    7: 'Neck', 8: 'Undershirt', 9: 'Vest', 10: 'Badge', 11: 'Top' };
const OUTFIT_PROPS = { 0: 'Hat', 1: 'Glasses', 2: 'Earrings', 6: 'Watch', 7: 'Bracelet' };

const outfitOf = (w) => (w.def.outfit && typeof w.def.outfit === 'object' ? w.def.outfit : {});

/** Every part its ped has as the page shows one not set yet (the first style and colour; no prop): written in with the
 *  first change, so a run wears what the page showed. */
function outfitDefaults(ed, w) {
    const opts = ed.pedOpts && ed.pedOpts[w.def.model];
    const out = {};
    if (!opts || opts.failed) return out;
    for (const x of opts.c) { out['c' + x.i + 'd'] = 0; out['c' + x.i + 't'] = 0; }
    for (const x of opts.p) { out['p' + x.i + 'd'] = -1; out['p' + x.i + 't'] = 0; }
    return out;
}

/** A random outfit of what its ped has (Random): a prop worn half the time. null before the ped is read. */
export function outfitRandom(ed, w) {
    const opts = ed.pedOpts && ed.pedOpts[w.def.model];
    if (!opts || opts.failed) return null;
    const r = (n) => Math.floor(Math.random() * Math.max(1, n));
    const out = {};
    for (const x of opts.c) { const d = r(x.n); out['c' + x.i + 'd'] = d; out['c' + x.i + 't'] = r(x.t[d]); }
    for (const x of opts.p) {
        const d = Math.random() < 0.5 ? -1 : r(x.n);
        out['p' + x.i + 'd'] = d;
        out['p' + x.i + 't'] = d >= 0 ? r(x.t[d]) : 0;
    }
    return out;
}

/** One of an Outfit's sliders: a style ("2 / 5", a prop's from None) or a colour. */
function outfitSlider(t, k, value, o) {
    const min = o.none ? -1 : 0, max = o.n - 1;
    const v = typeof value === 'number' ? Math.min(max, Math.max(min, value)) : min;
    const pct = max > min ? Math.round(((v - min) / (max - min)) * 1000) / 10 : 0;
    const text = o.none && v < 0 ? 'None' : `${v + 1} / ${o.n}`;
    return `<div class="dr-look-line"><span class="dr-look-what">${e(o.label)}</span><div class="dr-slide">`
        + `<input class="dr-slider" type="range" min="${min}" max="${max}" step="1" value="${v}" style="--p:${pct}%"`
        + ` data-t="${e(t)}" data-k="${e(k)}" data-f="number" data-of="${o.n}"${o.none ? ' data-none="None"' : ''}`
        + ` aria-label="${e(o.part + ', ' + o.label.toLowerCase())}"><output class="dr-slider-val">${e(text)}</output></div></div>`;
}

/** The Outfit tab: each part its ped has, its style and colour (a colour only when its style has more than one),
 *  then its props; Random, and As the game makes it (the outfit taken off). */
/** The peds a look from the character editor is made on: a player's character's (an NPC's look, w.def.look). */
export const FREEMODE = new Set(['mp_m_freemode_01', 'mp_f_freemode_01']);

/** An NPC's look from the character editor, when it has one. */
export function lookOf(w) {
    const l = w && w.def && w.def.look;
    return l && typeof l === 'object' && FREEMODE.has(l.model) ? l : null;
}

/** A freemode NPC's own look: the character editor on it (app.js npc-look: client/director.lua directorEditLook), and
 *  taking it off. With one, its clothes are part of it, so the Outfit's own parts are not shown. */
function lookGroup(ed, w) {
    const has = lookOf(w);
    return groupHead('Character editor')
        + `<div class="dr-hint">${has ? 'Its face, hair, make-up, tattoos and clothes, made in the character editor: what it wears every time.'
            : 'A freemode ped: give it a face, hair, make-up, tattoos and clothes, as a player makes their character.'}`
        + ' You wear it while the editor is open; Save there puts it on this NPC.</div>'
        + '<div class="dr-btns">'
        + `<button class="dr-btn primary" data-act="npc-look" data-id="${e(w.id)}">${has ? 'Edit its look' : 'Open the character editor'}</button>`
        + (has ? `<button class="dr-btn" data-act="npc-look-off" data-id="${e(w.id)}">Take its look off</button>` : '')
        + '</div>';
}

function outfitGroup(ed, w) {
    if (w.def.lore) return '<div class="dr-none">They wear their lore character\'s look (Director, Lore characters)</div>';
    const model = typeof w.def.model === 'string' ? w.def.model : '';
    if (!model) return '<div class="dr-none">Pick its ped first</div>';
    const free = FREEMODE.has(model) ? lookGroup(ed, w) : '';
    if (lookOf(w)) return free;
    const opts = ed.pedOpts && ed.pedOpts[model];
    if (!opts) {
        if (ed.askPedOpts) ed.askPedOpts(model);
        return free + '<div class="dr-none">Reading what this ped can wear…</div>';
    }
    if (opts.failed) return free + `<div class="dr-none">${e(opts.failed)}</div>`;
    if (!opts.c.length && !opts.p.length) return free + '<div class="dr-none">This ped comes in one look only</div>';
    const o = outfitOf(w);
    const set = Object.keys(o).length > 0;
    const t = 'outfit:' + w.id;
    let html = free + (free ? groupHead('Or only its clothes') : '')
        + `<div class="dr-hint">${set ? 'What it wears every time.' :'As the game makes it, until you change something here.'}`
        + `${ed.inBuilder ? ' Its copy here wears it as you change it.' : ''}</div>`
        + '<div class="dr-btns">'
        + `<button class="dr-btn" data-act="outfit-random" data-id="${e(w.id)}">Random</button>`
        + (set ? `<button class="dr-btn" data-act="outfit-reset" data-id="${e(w.id)}">As the game makes it</button>` : '')
        + '</div>';
    const part = (kind, x, names) => {
        const prop = kind === 'p';
        const kd = kind + x.i + 'd', kt = kind + x.i + 't';
        const d = typeof o[kd] === 'number' ? Math.min(x.n - 1, o[kd]) : (prop ? -1 : 0);
        const colours = d >= 0 ? (x.t[d] || 1) : 1;
        const name = names[x.i] || `${prop ? 'Prop' : 'Part'} ${x.i}`;
        let rows = '';
        if (prop || x.n > 1) rows += outfitSlider(t, kd, d, { label: 'Style', n: x.n, none: prop, part: name });
        if (colours > 1) rows += outfitSlider(t, kt, typeof o[kt] === 'number' ? o[kt] : 0, { label: 'Colour', n: colours, part: name });
        return rows ? `<div class="dr-look-part"><div class="dr-label">${e(name)}</div>${rows}</div>` : '';
    };
    if (opts.c.length) html += groupHead('Clothes') + opts.c.map((x) => part('c', x, OUTFIT_PARTS)).join('');
    if (opts.p.length) html += groupHead('Accessories') + opts.p.map((x) => part('p', x, OUTFIT_PROPS)).join('');
    return html;
}

/** A slider with its value beside it, written as it moves (app.js: its value and its fill follow the thumb). */
function sliderField(t, k, value, o) {
    const v = typeof value === 'number' ? Math.min(o.max, Math.max(o.min, value)) : o.fallback;
    const unit = o.unit || '';
    const pct = Math.round(((v - o.min) / (o.max - o.min)) * 1000) / 10;
    return `<div class="dr-row">${label(o.label, o.hint)}<div class="dr-slide">`
        + `<input class="dr-slider" type="range" min="${o.min}" max="${o.max}" step="${o.step || 1}" value="${v}" style="--p:${pct}%"`
        + ` data-t="${e(t)}" data-k="${e(k)}" data-f="number" data-unit="${e(unit)}" aria-label="${e(o.label)}">`
        + `<output class="dr-slider-val">${e(String(v) + unit)}</output></div></div>`;
}

/** Who a guard's spot alerts, as its page shows it ('all', every guard of the run, is now the NPCs near it). */
const alertOf = (v) => (v.alert === 'self' || v.alert === 'group' ? v.alert : v.alert === 'near' || v.alert === 'all' ? 'near' : 'group');

/** Under who it alerts: who its group is, or how near is nearby. */
function alertHint(w, v) {
    const t = 'vision:' + w.id;
    const a = alertOf(v);
    if (a === 'near') {
        return sliderField(t, 'alertRange', v.alertRange, { label: 'Nearby is within', min: 5, max: 100, step: 5, fallback: 30, unit: ' m' })
            + '<div class="dr-hint">The scenario\'s NPCs that close to this guard, with Reacts to danger on (their General tab).</div>';
    }
    if (a === 'group') {
        const g = typeof w.def.group === 'string' ? w.def.group.trim() : '';
        return `<div class="dr-hint">${e(g ? `Every NPC in the group "${g}", and any copies of this one.`
            : 'It has no group yet: give it one on its General tab (Group). NPCs with the same group are alerted together.')}</div>`;
    }
    return '';
}

/** A guard's Eye sight (server/director/guards.lua, server/vision.lua): its cone, its range, how long it takes to spot
 *  someone, and what a spotted player sets off. Its cone in the world builder follows the sliders as they move. */
function visionGroup(ed, w) {
    const v = w.def.vision && typeof w.def.vision === 'object' ? w.def.vision : {};
    const t = 'vision:' + w.id;
    let html = switchField(t, 'on', v.on, { label: 'Sees players', fallback: false, hint: 'It notices the scenario\'s players in its cone, with nothing in between' });
    if (v.on !== true) return html + '<div class="dr-none">It sees nobody: it fights only when its Spawn card says so, or when it is hurt</div>';
    html += '<div class="dr-hint">Its Spawn card\'s Fights the scenario\'s players stays off: it fights once it spots someone. Select it in the world builder to see its cone change as you set it.</div>';
    return html
        + sliderField(t, 'range', v.range, { label: 'Sees within', min: 3, max: 80, step: 1, fallback: 20, unit: ' m' })
        + sliderField(t, 'cone', v.cone, { label: 'Cone', min: 20, max: 360, step: 5, fallback: 100, unit: '°' })
        + '<div class="dr-pair">'
        + numberField(t, 'spotS', v.spotS, { label: 'Spots you up close in', hint: 'seconds', min: 1, max: 10, placeholder: '2' })
        + numberField(t, 'farS', v.farS, { label: 'At its full distance', hint: 'seconds', min: 1, max: 30, placeholder: '8' })
        + '</div>'
        + '<div class="dr-hint">Seen the whole time, that is how long it takes: a second at least. In between, the further away you are, the longer.</div>'
        + switchField(t, 'sneak', v.sneak, { label: 'Sneaking hides you better', fallback: true, hint: 'Half the distance while you sneak (GTA\'s Ctrl walk)' })
        + selectField(t, 'alert', alertOf(v), ALERTS, { label: 'A spotted player alerts', noEmpty: true })
        + alertHint(w, v)
        + segField(t, 'react', v.react, REACTS, { label: 'Alerted, they', fallback: 'attack' })
        + (v.react === 'look' ? '<div class="dr-hint">Come to look: they go where the player was seen, look round, then go back.</div>'
            : v.react === 'card' ? '<div class="dr-hint">Only the card: nothing by themselves. A Guard Spots You card says what happens.</div>' : '');
}

// (The fields of what a placed thing is, by kind, under their group's head: its group, things-data.js.)

// ---- a random vehicle's models (the world builder's first Vehicles tile: def.random) ----

/** The most models one random vehicle picks from. */
export const MAX_CAR_MODELS = 8;

/** A random vehicle's models as its page has them: { model, chance } each (chance 0-100, whole). */
export function carModels(w) {
    const list = w && w.def && Array.isArray(w.def.models) ? w.def.models : [];
    return list.filter((m) => m && typeof m.model === 'string' && m.model !== '')
        .map((m) => ({ model: m.model, chance: Math.max(0, Math.min(100, Math.round(Number(m.chance) || 0))) }));
}

/** A random vehicle's models: adding one first (picked in the world builder's Vehicles, or by its name), so it stays
 *  where it is as the list grows; then each one's picture and name, its chance (the sliders always make 100 between
 *  them: app.js setChance), its resources' buttons for that model (Whiplash: how that one comes out) and its ×. */
function carModelsGroup(ed, w) {
    const list = carModels(w);
    const tools = (ed.buttons || []).filter((b) => b.kinds.includes('vehicle'));
    let html = '<div class="dr-hint">Each time the scenario makes it, one of these, by its chance. The world builder shows each in turn.</div>';
    if (list.length >= MAX_CAR_MODELS) {
        html += `<div class="dr-hint">${MAX_CAR_MODELS} at most.</div>`;
    } else {
        // Picking one in the world builder's Vehicles (app.js builder.modelPick), or typing its name.
        if (ed.modelPick && ed.modelPick === w.id) {
            html += '<div class="dr-carmodel-pick"><b>Pick a vehicle in Vehicles</b><span>It joins the list instead of being placed.</span>'
                + `<button class="dr-btn" data-act="car-model-pick-end">Done</button></div>`;
        } else if (ed.inBuilder) {
            html += `<button class="dr-add" data-act="car-model-pick" data-id="${e(w.id)}">${ICON.plus}Add a model from Vehicles</button>`;
        }
        html += '<div class="dr-row dr-carmodel-add">'
            + `<input class="dr-field dr-carmodel-input" type="text" maxlength="64" spellcheck="false" placeholder="or type its name: adder"`
            + ` data-id="${e(w.id)}" aria-label="A model, by its name">`
            + `<button class="dr-btn" data-act="car-model-add" data-id="${e(w.id)}">Add</button></div>`;
    }
    if (!list.length) return html + '<div class="dr-carmodels"><div class="dr-none">No models yet: add two or more</div></div>';
    return html + '<div class="dr-carmodels">' + list.map((m, i) => {
        const pct = list.length === 1 ? 100 : m.chance;
        return `<div class="dr-carmodel">`
            + `<div class="dr-carmodel-head">${carArt(m.model)}`
            + `<b class="dr-carmodel-name">${e(m.model)}</b>`
            + `<button class="dr-ibtn" data-act="car-model-remove" data-id="${e(w.id)}" data-i="${i}" aria-label="Take ${e(m.model)} out"`
            + ` title="Take it out">${ICON.close}</button></div>`
            + `<div class="dr-slide"><input class="dr-slider dr-chance" type="range" min="0" max="100" step="1" value="${pct}"`
            + ` style="--p:${pct}%" data-id="${e(w.id)}" data-i="${i}" data-unit="%" aria-label="${e(m.model)}'s chance"${list.length < 2 ? ' disabled' : ''}>`
            + `<output class="dr-slider-val">${pct}%</output></div>`
            + (tools.length ? '<div class="dr-btns">' + tools.map((b) => `<button class="dr-btn dr-btn-tool" data-act="thing-button"`
                + ` data-id="${e(w.id)}" data-button="${e(b.id)}" data-model="${e(m.model)}" title="${e(b.hint || `From ${b.owner}`)}">`
                + `${toolIcon(b.icon)}${e(b.label)}</button>`).join('') + '</div>' : '')
            + '</div>';
    }).join('') + '</div>';
}

// ---- a placed thing's page in tabs (as the /whip panel's sections are) ----
//
// An NPC's page: General (who it is, how it behaves, its group, where it is), Outfit, Eye sight, Tasks. A car's:
// General, Takes (its riders and recorded drives), Tasks. A prop's: General, Tasks. The rest have one page. The tab
// shown is ed.thingTab, kept from one thing to the next (one a thing has not got: its General).

const THING_TABS = {
    npc: [['general', 'General'], ['look', 'Outfit'], ['sight', 'Eye sight'], ['tasks', 'Tasks']],
    vehicle: [['general', 'General'], ['takes', 'Scripted Driving Events'], ['tasks', 'Tasks']],
    prop: [['general', 'General'], ['tasks', 'Tasks']],
};

/** This thing's tabs, or null for a page of one (Tasks only with the server's catalogue). */
function tabsOf(ed, w) {
    const tabs = (THING_TABS[w.kind] || []).filter(([k]) => k !== 'tasks' || ed.tasks);
    return tabs.length > 1 ? tabs : null;
}

/** What a tab's chip says beside its name: how many tasks or takes, Eye sight on, a task that needs work. */
function tabBadge(ed, w, k, mine) {
    if (k === 'tasks') {
        const n = tasksOf(w).list.length;
        const bad = mine.some((p) => /, task \d+ \(/.test(p.message || ''));
        return (n ? `<em>${n}</em>` : '') + (bad ? '<i class="dr-ptab-dot" title="A task needs work"></i>' : '');
    }
    if (k === 'takes') { const n = takesOf(w).length; return n ? `<em>${n}</em>` : ''; }
    if (k === 'sight') return w.def.vision && w.def.vision.on === true ? '<em>On</em>' : '';
    return '';
}

function thingTabs(ed, w, tabs, cur, mine) {
    return '<div class="dr-ptabs" role="tablist">' + tabs.map(([k, text]) => `<button class="dr-ptab${k === cur ? ' on' : ''}" role="tab"`
        + ` aria-selected="${k === cur}" data-act="thing-tab" data-tab="${k}">${e(text)}${tabBadge(ed, w, k, mine)}</button>`).join('') + '</div>';
}

/** A car's KEY SETTINGS (w.def.key = { exists, where, spot }; server/director/nodes_world.lua keyOf): whether it has a
 *  key, and where Spawn Car puts it; then Locked (w.def.locked; with the key inside it w.def.lockedIn, off unless set)
 *  and Only its key opens it. On the ground, at a key spot of its own placed in the world builder. */
const KEY_WHERE = [['world', 'Placed in the world'], ['ignition', 'In the ignition'], ['glovebox', 'In the glovebox'],
    ['trunk', 'In the boot'], ['player', 'Given to the player'], ['card', 'Given by a card']];

function carKeyGroup(ed, w) {
    const k = w.def.key && typeof w.def.key === 'object' ? w.def.key : {};
    const t = 'carkey:' + w.id, d = 'def:' + w.id;
    let html = groupHead('Key settings') + switchField(t, 'exists', k.exists === true, { label: 'Key exists', fallback: false });
    const inside = k.exists === true && (k.where === 'ignition' || k.where === 'glovebox' || k.where === 'trunk');
    if (k.exists === true) {
        html += selectField(t, 'where', k.where, KEY_WHERE, { label: 'Where the key is', none: '— pick where —' });
        if (k.where === 'card') html += '<div class="dr-hint">Spawn Car makes it without its key: a Give Car Key card gives it, when and to whom the card says.</div>';
        if (k.where === 'world') {
            const spot = typeof k.spot === 'string' ? findWorld(ed.doc, k.spot) : null;
            const placed = spot && spot.def && spot.def.coords;
            html += spot
                ? `<div class="dr-row">${label('Key spot', placed ? 'placed' : 'not placed yet')}<div class="dr-where${placed ? '' : ' none'}">${e(spot.label || spot.id)}</div></div>`
                    + `<div class="dr-btns dr-btns-tight"><button class="dr-btn" data-act="build" data-id="${e(spot.id)}">${placed ? 'Show it in the world' : 'Place it in the world'}</button></div>`
                : `<div class="dr-btns dr-btns-tight"><button class="dr-btn primary" data-act="key-spot" data-id="${e(w.id)}">Make its key spot</button></div>`;
        }
    }
    // Locked: with its key inside it, a setting of its own (lockedIn), off unless set; and locked with only its key
    // opening it, nobody gets in: said.
    html += inside
        ? switchField(d, 'lockedIn', w.def.lockedIn, { label: 'Locked', fallback: false })
        : switchField(d, 'locked', w.def.locked, { label: 'Locked', fallback: true });
    html += switchField(d, 'secure', w.def.secure, { label: 'Only its key opens it', fallback: false, hint: 'No lockpicking, no hotwiring' });
    if (inside && w.def.lockedIn === true && w.def.secure === true) html += '<div class="dr-hint">Its key is inside it and only its key opens it: nobody can get in.</div>';
    return html;
}

/** A spot's MARKER (w.def.marker; server/director/spots.lua): how it looks in the world, its size, whether the run's
 *  players see it, and what sets it off. The cards that wait at it go by it (their own Within and Who say so). None:
 *  each card's own Within and Who, as before. */
const MARKER_LOOKS = [['none', 'None'], ['circle', 'Circle'], ['square', 'Square'], ['garage', 'Garage bay']];
const MARKER_ACTIVATE = [['one', 'Any player'], ['all', 'All players'], ['vehicle', 'A vehicle'], ['thing', 'A placed thing']];
const MARKER_SAYS = {
    one: 'Goes on when one of the scenario\'s players stands in it.',
    all: 'Goes on when every one of the scenario\'s players is in it.',
    vehicle: 'Goes on when one of the scenario\'s players drives a car into it.',
    thing: 'Goes on when that NPC or car is in it.',
};

/** The spot a field's placed thing is, when it has a marker (a look whip draws); else null. */
function markedSpot(ed, id) {
    const s = typeof id === 'string' && id ? findWorld(ed.doc, id) : null;
    const m = s && s.kind === 'spot' && s.def && s.def.marker;
    return m && (m.look === 'circle' || m.look === 'square' || m.look === 'garage') ? s : null;
}

/** A field a spot's marker decides instead: said, not asked. */
function bySpotRow(lab, spot) {
    return `<div class="dr-row">${label(lab)}<div class="dr-where">Set by ${e(spot.label || spot.id)}'s marker</div></div>`;
}

function markerGroup(ed, w) {
    const m = w.def.marker && typeof w.def.marker === 'object' ? w.def.marker : {};
    const t = 'marker:' + w.id;
    const look = MARKER_LOOKS.some(([v]) => v === m.look) ? m.look : 'none';
    let html = groupHead('Marker') + segField(t, 'look', m.look, MARKER_LOOKS, { label: 'Looks like', fallback: 'none' });
    if (look === 'none') return html + '<div class="dr-hint">No marker: each card that waits here says how near, and who.</div>';
    // A circle's or a square's symbol in its middle, as a garage bay has: none unless one is picked.
    const symbol = () => glyphField(ed, t, 'icon', m.icon, { label: 'Symbol', noneText: 'None', open: ed.glyphOpen === t + '|icon' });
    if (look === 'circle') {
        html += sliderField(t, 'w', m.w, { label: 'Across', min: 1, max: 30, step: 0.5, fallback: 4, unit: ' m' }) + symbol();
    } else if (look === 'square') {
        html += sliderField(t, 'w', m.w, { label: 'Width', min: 1, max: 30, step: 0.5, fallback: 4, unit: ' m' })
            + sliderField(t, 'l', m.l, { label: 'Length', hint: 'along the way the spot faces', min: 1, max: 30, step: 0.5,
                fallback: typeof m.w === 'number' ? m.w : 4, unit: ' m' })
            + symbol();
    } else {
        html += '<div class="dr-hint">The garages\' own bay, turned with the spot. A car must stand square to it, either way round.</div>'
            // The symbol in its middle: the garage unless another is picked (client/director_spots.lua draws it).
            + glyphField(ed, t, 'icon', m.icon, { label: 'Symbol', fallback: 'garage', open: ed.glyphOpen === t + '|icon' });
    }
    const fallback = look === 'garage' ? 'vehicle' : 'one';
    const act = MARKER_ACTIVATE.some(([v]) => v === m.activate) ? m.activate : fallback;
    html += switchField(t, 'shown', m.shown, { label: 'Shown to the scenario\'s players', fallback: true, hint: 'While a card waits here. Off: it works unseen' })
        + segField(t, 'activate', m.activate, MARKER_ACTIVATE, { label: 'Set off by', fallback });
    if (act === 'thing') {
        const things = worldOptions(ed).filter(([id]) => { const o = findWorld(ed.doc, id); return o && (o.kind === 'npc' || o.kind === 'vehicle'); });
        html += selectField(t, 'thing', m.thing, things, { label: 'Which', none: '— an NPC or a car —' });
    }
    if (act === 'vehicle' || act === 'thing') {
        html += switchField(t, 'still', m.still, { label: 'Stopped in it', fallback: true, hint: 'A car must stand still: parked' });
    }
    return html + `<div class="dr-hint">${e(MARKER_SAYS[act])} Deliver the Car, Car Delivered and Bring Item To take only its shape.</div>`;
}

// (What Spawn Logic's Always present calls a thing of each kind: its spawn, things-data.js.)

/** Other resources' buttons for this kind of thing (client/director_buttons.lua), under their head: each runs that
 *  resource's own code on the thing, and may keep data of its own on it. */
function thingButtons(ed, w) {
    const list = (ed.buttons || []).filter((b) => b.kinds.includes(w.kind) && b.where !== 'bubble');
    if (!list.length) return '';
    return groupHead('Tools') + '<div class="dr-btns">' + list.map((b) => `<button class="dr-btn dr-btn-tool" data-act="thing-button"`
        + ` data-id="${e(w.id)}" data-button="${e(b.id)}" title="${e(b.hint || `From ${b.owner}`)}">`
        + `${toolIcon(b.icon)}${e(b.label)}</button>`).join('') + '</div>';
}

/** A button's icon by its key: whip's interaction icons (js/glyphs.js, as AddAction's), else the furnisher's. */
function toolIcon(key) {
    if (!key) return '';
    const whip = window.WhipGlyphs && window.WhipGlyphs.glyphs;
    return (whip && whip[key]) || GLYPHS[key] || '';
}

/** A placed thing's page (over the World list): who or what it is, how it behaves, where it is; for an NPC, a car
 *  and a prop, in tabs. */
function worldPage(ed, w) {
    const i = worldInfo(ed, w);
    const uses = usesOfWorld(ed.doc, ed.cards, w.id).length;
    // Its name and picture, with nothing beside them to squeeze the name; its pills (Always present, Not placed, Needs
    // work) under them.
    // In the world builder, Change model is the General tab's last row, under its own fields (furnisher.js startRemodel:
    // Place opens on its list, the tile pressed is its model). Not a Vehicle pool's: its models are its page's.
    const remodel = ed.inBuilder && (w.kind === 'npc' || w.kind === 'prop' || (w.kind === 'vehicle' && !w.def.random))
        ? `<div class="dr-btns"><button class="dr-btn" data-act="thing-remodel" data-id="${e(w.id)}" title="Another model for it, picked from Place; everything else it has stays">Change model</button></div>`
        : '';
    // (A Vehicle pool's cars, side by side, in a row of their own over its name.)
    const pool = w.kind === 'vehicle' && w.def.random && carModels(w).length > 0;
    let html = backRow(ed, 'world-back', 'world')
        + (pool ? `<div class="dr-pool-row">${poolArt(w)}</div>` : '')
        + `<div class="dr-page-head">${pool ? '' : worldArt(w)}<div class="dr-item-main"><b>${e(w.label || w.id)}</b></div></div>`
        + (i.hasPills ? `<div class="dr-page-sub">${i.pills}</div>` : '')
        + problemsHtml(i.mine, 'world:' + w.id);
    const tabs = tabsOf(ed, w);
    const cur = tabs && tabs.some(([k]) => k === ed.thingTab) ? ed.thingTab : 'general';
    if (tabs) html += thingTabs(ed, w, tabs, cur, i.mine);
    if (cur === 'look') return html + outfitGroup(ed, w);
    if (cur === 'sight') return html + visionGroup(ed, w);
    if (cur === 'takes') return html + takesGroup(ed, w) + ridersGroup(ed, w);
    if (cur === 'tasks') return html + tasksGroup(ed, w, true);
    html += generalFields(ed, w, i);
    // Change model, last of the General tab's own rows (Tools, below, is other resources').
    html += remodel;
    // (Takes and tasks are tabs of their own: tabsOf. A page with no tabs has neither.)
    html += thingButtons(ed, w);
    // (In the world builder it is placed where it stands, and removed with the selection's Remove.)
    if (ed.inBuilder) return html;
    return html + groupHead('Place')
        + `<div class="dr-row"><div class="dr-where${i.placed ? '' : ' none'}">${e(i.placed || 'Not placed yet')}</div></div>`
        // In the world builder, selected there (or put down, if it is not placed yet; a door is picked).
        + `<div class="dr-btns"><button class="dr-btn primary" data-act="build" data-id="${e(w.id)}" title="The world builder, with this one selected">${i.placed ? 'Show in the world' : 'Place in the world'}</button>`
        + `<button class="dr-btn danger" data-act="remove-world" data-id="${e(w.id)}">Remove${uses ? ` (used by ${uses})` : ''}</button></div>`;
}

/** A placed thing's General tab: its name, Spawn Logic and its kind's own fields. */
function generalFields(ed, w, i) {
    const t = 'world:' + w.id, d = 'def:' + w.id, c = 'cond:' + w.id;
    const cond = w.def.conditions || {};
    // WHAT IT IS AND WHERE come from the world builder (the furnisher): picked from its
    // tabs or by name, moved and turned with its markers. Nothing about placing is typed here.
    const picked =(what, v, none) => `<div class="dr-row">${label(what, 'picked in the world builder')}<div class="dr-where${v ? '' : ' none'}">${e(v || none)}</div></div>`;
    let html = '';
    // (Its name only: its id is the Director's own, which cards keep it by. No head over it but an NPC's Who: a Name
    // head over a Name field says it twice.)
    html += (w.kind === 'npc' ? groupHead('Who') : '')
        + textField(t, 'label', w.label, { label: 'Name', max: 60 })
        // A spot is only a place (for a blip, a waypoint, a drop-off): nothing exists there to make.
        // A car, a door and a container are always the run's (see worldInfo).
        + (i.runOnly ? '' : segField(t, 'layer', w.layer, [['run', 'Only activates via card'], ['standing', 'Always present']],
            { label: 'Spawn Logic', fallback: 'run' })
            + (w.layer === 'standing'
                ? `<div class="dr-hint">This ${thingIs(w.kind, 'spawn') || 'thing'} will exist at all times, regardless of active players.</div>` : ''));
    if (w.kind === 'spot') html += markerGroup(ed, w);
    if (w.kind === 'npc') {
        // (Who it is, a lore character, and its ped are picked in the world builder's NPCs: said in the page's head. Its
        // Group, as a prop's: a guard's Eye sight alerts its group, server/director/guards.lua.)
        html += textField(d, 'group', w.def.group, { label: 'Group', max: 40, placeholder: 'none',
                hint: 'NPCs with the same group: a guard\'s Eye sight can alert them together' })
            + groupHead('Behaviour')
            + segField(d, 'behaviour', w.def.behaviour, BEHAVIOURS, { label: 'Idle', fallback: 'stand' })
            + switchField(c, 'invincible', cond.invincible, { label: 'Cannot be hurt', fallback: false })
            // (One whose tasks walk a route moves, whatever this says: server/director/routes.lua npcDef.)
            + (walksRoute(w) ? '' : switchField(c, 'canMove', cond.canMove, { label: 'Can move', fallback: true }))
            // (Off unless set, as server/npcs.lua makes it: an NPC only reacts once this is switched on.)
            + switchField(c, 'reacts', cond.reacts, { label: 'Reacts to danger', fallback: false })
            + switchField(d, 'fightBack', w.def.fightBack, { label: 'Fights back', fallback: false })
            + '<div class="dr-pair narrow">'
            // A weapon this game has, GTA's or one another resource adds (an NPC carries the gun, never a whip item).
            + (ed.weapons && ed.weapons.length
                ? selectField(d, 'weapon', weaponValue(ed, w.def.weapon), ed.weapons.map((x) => [x.name, weaponText(x)]),
                    { label: 'Weapon', none: '— no weapon —' })
                : textField(d, 'weapon', weaponValue(ed, w.def.weapon), { label: 'Weapon', max: 64, placeholder: 'none, or WEAPON_PISTOL' }))
            + numberField(d, 'armour', w.def.armour, { label: 'Armour', min: 0, max: 100, placeholder: '0' })
            + '</div>';
    } else if (w.kind === 'route') {
        html += routeGroups(ed, w);
    } else if (thingIs(w.kind, 'group')) {
        // (A car's fields have no head of their own: a Vehicle pool's models first, then its plate, then Key settings.)
        if (w.kind !== 'vehicle') html += groupHead(thingIs(w.kind, 'group'));
        if (w.kind === 'groundItem' && typeof w.def.keyOf !== 'string') {
            html += itemField(d, 'item', w.def.item, { label: 'Item' })
                + numberField(d, 'amount', w.def.amount, { label: 'How many', min: 1, max: 1000, placeholder: '1' });
        } else if (w.kind === 'vehicle') {
            html += (w.def.random ? carModelsGroup(ed, w) : '')
                + textField(d, 'plate', w.def.plate, { label: 'Plate', max: 8, placeholder: 'random', hint: 'empty: a new one each time' })
                + towField(ed, w, d)
                // (Each player's own game, while they stand on it: client/director_standon.lua; an NPC on it, its owner's:
                // client/npcs.lua ride.)
                + switchField(d, 'standOn', w.def.standOn, { label: 'Players and NPCs can stand on it while it moves',
                    hint: 'Most cars throw you off once they move (trucks and trailers do not). A very sharp turn can still slide a player off' })
                + carKeyGroup(ed, w);
        } else if (w.kind === 'groundItem' && typeof w.def.keyOf === 'string') {
            // A car's key spot (its Key settings, Placed in the world): the key of that car, made there with it.
            const car = findWorld(ed.doc, w.def.keyOf);
            html += `<div class="dr-hint">The key of <b>${e(car ? car.label || car.id : w.def.keyOf)}</b>: Spawn Car puts it here when it makes the car.</div>`;
        } else if (w.kind === 'door') {
            // Picked off the door itself (the world builder's More > Door, then a click on it). Any door
            // works, saved in the Door Editor or not.
            html += picked('Door', typeof w.def.model === 'number' ? 'model ' + w.def.model : null, 'Not picked yet');
        } else if (w.kind === 'prop' && w.def.weapon) {
            // A Fixed Weapon: a prop that is a gun (the builder's More, Weapons), fired by Fire Weapon. Its gun, and what it
            // is on: where it sits on it is where it was placed beside it in the world builder.
            // (`gun`: a firearm with a world model, client/director.lua weapons(): nothing thrown or melee.)
            const guns = (ed.weapons || []).filter((x) => x.gun);
            const onto = (ed.doc.world || []).filter((o) => o.id !== w.id && (o.kind === 'vehicle' || o.kind === 'npc' || o.kind === 'prop'))
                .map((o) => [o.id, `${o.label || o.id} (${o.kind === 'vehicle' ? 'car' : o.kind === 'npc' ? 'NPC' : 'prop'})`]);
            const at = w.def.attach && typeof w.def.attach.to === 'string' ? w.def.attach.to : '';
            html += (guns.length
                    ? selectField(d, 'weapon', weaponValue(ed, w.def.weapon), guns.map((x) => [x.name, weaponText(x)]), { label: 'Gun', noEmpty: true })
                    : picked('Gun', w.def.weapon, 'none'))
                + selectField('attach:' + w.id, 'to', at, onto, { label: 'Attached to', none: 'nothing: it stays where it is placed',
                    hint: 'a car, an NPC or a prop: it rides on it, sitting where you placed it beside it' })
                + '<div class="dr-hint">Selected in the world builder, a red line shows where it fires. Fire Weapon fires it.</div>';
        } else if (w.kind === 'prop') {
            const still = propStillWhy(w);
            html += picked('Prop', w.def.model, 'none yet')
                + textField(d, 'group', w.def.group, { label: 'Group', max: 40, placeholder: 'none',
                    hint: w.layer === 'standing' ? '' : 'Show Prop can bring a whole group in' })
                + switchField(d, 'collision', w.def.collision, { label: 'Solid', fallback: true, hint: 'Players bump into it' })
                + (still ? `<div class="dr-hint">Static: ${e(still)}.</div>`
                    : switchField(d, 'physics', w.def.physics, { label: 'Physics', fallback: true,
                        hint: w.def.physics === false ? 'Static: it stays exactly where it is placed'
                            : 'It falls, rolls and gets knocked about. The nearest player\'s game moves it, everyone sees it' }))
                + (w.def.light ? '<div class="dr-hint">A lamp: inside an interior it is filed so its light reaches the room.</div>' : '');
        } else if (w.kind === 'container') {
            html += '<div class="dr-pair">'
                + numberField(d, 'slots', w.def.slots, { label: 'Slots', min: 1, max: 100, placeholder: '10' })
                + numberField(d, 'maxWeight', w.def.maxWeight, { label: 'Holds (kg)', min: 1, max: 10000, placeholder: '100' })
                + '</div>'
                + textField(d, 'prop', w.def.prop, { label: 'Prop', max: 64, placeholder: 'none: only a prompt', hint: 'empty for a room with its own safe' });
        }
    }
    return html;
}

// ---- several selected in the world builder (Ctrl+click): one page for all of them ----
//
// ed.multi: their ids, the builder's primary (the last one picked) last; app.js builder.configureMany sets it. Only what
// every one of them has is shown. Each one's page is drawn as it would be on its own, and a field stays when every page
// has it (the same target, key and kind of field). The same value on all: shown. Different: MIXED, and left alone it
// changes nothing. Set, it is written to every one of them: its target is 'many:<kind>' (targetsOf). Their names, lists
// and buttons are each one's own, never here.

/** ed.taskPick / ed.taskCopy.id while the task picker or Copy tasks is for all of them. */
export const MANY = '*many';

/** The things selected together, as the scenario has them now (gone ones left out). */
export function multiThings(ed) {
    return (ed.multi || []).map((id) => findWorld(ed.doc, id)).filter(Boolean);
}

const kindCount = (kind, n) => plural(n, nounOf(kind));

/** Their pictures in a row, how many, and a chip per kind that narrows the selection to that kind (app.js multi-kind). */
function multiHead(ed, things) {
    const counts = new Map();
    for (const w of things) counts.set(w.kind, (counts.get(w.kind) || 0) + 1);
    const SHOWN = 6;
    const art = things.slice(0, SHOWN).map(worldArt).join('')
        + (things.length > SHOWN ? `<span class="dr-multi-more">+${things.length - SHOWN}</span>` : '');
    const what = [...counts].map(([k, n]) => kindCount(k, n)).join(', ');
    const chips = counts.size > 1
        ? '<div class="dr-chips">' + [...counts].map(([k, n]) => `<button class="dr-chip plain" data-act="multi-kind" data-kind="${e(k)}"`
            + ` title="Only the ${e(kindCount(k, n).replace(/^\d+ /, ''))}">${e(kindCount(k, n))}</button>`).join('') + '</div>'
        : '';
    return `<div class="dr-multi-art">${art}</div>`
        + `<div class="dr-page-head"><div class="dr-item-main"><b>${things.length} selected</b><span>${e(what)}</span></div></div>` + chips;
}

/** The tabs every one of them has: General, and Eye sight and Tasks while they are all one kind that has them. */
function multiTabs(ed, things) {
    if (new Set(things.map((w) => w.kind)).size !== 1) return null;
    const tabs = (tabsOf(ed, things[0]) || []).filter(([k]) => k === 'general' || k === 'sight' || k === 'tasks');
    return tabs.length > 1 ? tabs : null;
}

function multiPage(ed) {
    const things = multiThings(ed);
    const prim = things[things.length - 1];
    if (ed.taskPick === MANY && ed.tasks) return taskPicker(ed, prim, things);
    if (ed.taskCopy && ed.taskCopy.id === MANY && ed.tasks) return taskCopier(ed, prim, things);
    let html = multiHead(ed, things);
    const tabs = multiTabs(ed, things);
    const cur = tabs && tabs.some(([k]) => k === ed.thingTab) ? ed.thingTab : 'general';
    if (tabs) {
        html += '<div class="dr-ptabs" role="tablist">' + tabs.map(([k, text]) => `<button class="dr-ptab${k === cur ? ' on' : ''}" role="tab"`
            + ` aria-selected="${k === cur}" data-act="thing-tab" data-tab="${k}">${e(text)}</button>`).join('') + '</div>';
    }
    if (cur === 'tasks') return html + multiTasks(ed, things);
    // (The primary's page first: the one the others are matched against, its order the page's.)
    const order = [prim].concat(things.filter((w) => w !== prim));
    const merged = mergePages(order.map((w) => (cur === 'sight' ? visionGroup(ed, w) : generalFields(ed, w, worldInfo(ed, w)))));
    return html + (merged || '<div class="dr-none">Nothing they all have to set here. Pick one kind above, or one of them alone.</div>');
}

/** Their tasks: each one's list in a line (a click opens that one alone), and what can be done to all of them. */
function multiTasks(ed, things) {
    const max = ed.tasks.max || 40;
    const rows = things.map((w) => {
        const list = tasksOf(w).list;
        const names = list.slice(0, 4).map((s) => { const d = ed.tasks.types.get(s.t); return d ? d.label : s.t; });
        const said = list.length ? `${plural(list.length, 'task')}: ${names.join(' · ')}${list.length > 4 ? ' …' : ''}` : 'No tasks';
        return `<div class="dr-item"><div class="dr-item-head" data-act="multi-one" data-id="${e(w.id)}" title="This one alone">${worldArt(w)}`
            + `<div class="dr-item-main"><b>${e(w.label || w.id)}</b><span>${e(said)}</span></div></div></div>`;
    }).join('');
    const room = things.every((w) => tasksOf(w).list.length < max);
    const any = things.some((w) => tasksOf(w).list.length);
    return '<div class="dr-hint">A task added here goes on the end of each list. Its point is one point they all share.</div>'
        + rows
        + '<div class="dr-btns">'
        + (room ? '<button class="dr-btn primary" data-act="multi-task-add">+ Task for all</button>' : '')
        + '<button class="dr-btn" data-act="multi-task-copy">Copy tasks from…</button>'
        + (any ? '<button class="dr-btn danger" data-act="multi-task-clear">Clear their tasks</button>' : '')
        + '</div>';
}

// ---- the merge: one page out of several ----

/** A field's control as the merge sees it: what it edits (its target's kind and key) and how. */
function controlOf(el) {
    const t = el.dataset.t, i = t.indexOf(':');
    const how = el.classList.contains('dr-seg-key') ? 'seg' : el.classList.contains('dr-sw') ? 'sw'
        : el.tagName === 'SELECT' ? 'select' : el.type === 'range' ? 'range' : el.dataset.f || 'text';
    const kind = i < 0 ? t : t.slice(0, i);
    return { kind, key: el.dataset.k, how, sig: kind + '|' + el.dataset.k + '|' + how };
}

/** A page's fields: sig -> { kind, key, how, els (its controls), unit (its row: what goes when it does), value }. */
function pageFields(root) {
    const out = new Map();
    for (const el of root.querySelectorAll('[data-t][data-k]')) {
        const c = controlOf(el);
        let f = out.get(c.sig);
        if (!f) {
            f = { ...c, els: [], unit: el.classList.contains('dr-sw') ? el : el.closest('.dr-row') || el };
            out.set(c.sig, f);
        }
        f.els.push(el);
    }
    for (const f of out.values()) {
        const el = f.els[0];
        f.value = f.how === 'seg' ? (f.els.find((k) => k.classList.contains('on')) || { dataset: {} }).dataset.v || ''
            : f.how === 'sw' ? el.getAttribute('aria-checked')
            : f.how === 'dhms' ? f.els.map((x) => x.getAttribute('value') || x.getAttribute('placeholder') || '').join('|')
            : f.how === 'select' ? (el.querySelector('option[selected]') || { value: '' }).value
            : el.tagName === 'TEXTAREA' ? el.textContent : el.getAttribute('value') || '';
    }
    return out;
}

/** A field whose value differs between them: shown as no value, "Mixed" (beside its name; a box's own placeholder). */
function markMixed(f) {
    const el = f.els[0];
    const box = f.how === 'text' || f.how === 'number';
    f.unit.classList.add(box ? 'dr-mixed-box' : 'dr-mixed');
    if (f.how === 'seg') {
        for (const k of f.els) k.classList.remove('on');
    } else if (f.how === 'sw') {
        el.setAttribute('aria-checked', 'mixed');
        el.dataset.v = 'true';
        const sw = el.querySelector('.dr-switch');
        if (sw) sw.classList.remove('on');
    } else if (f.how === 'select') {
        for (const o of el.querySelectorAll('option[selected]')) o.removeAttribute('selected');
        el.insertAdjacentHTML('afterbegin', '<option value="__mixed" disabled selected>— Mixed —</option>');
    } else if (f.how === 'range') {
        const out = f.unit.querySelector('.dr-slider-val');
        if (out) out.textContent = 'Mixed';
    } else if (f.how === 'dhms') {
        for (const x of f.els) { x.setAttribute('value', ''); x.setAttribute('placeholder', '–'); }
    } else if (el.tagName === 'TEXTAREA') {
        el.textContent = '';
        el.setAttribute('placeholder', 'Mixed');
    } else {
        el.setAttribute('value', '');
        el.setAttribute('placeholder', 'Mixed');
    }
}

/** Several pages' HTML (the first the one kept) as one: the fields they all have, Mixed where they differ, written to
 *  all ('many:<kind>'); the words every page says alike; no buttons, lists or names. '' when no field is left. */
function mergePages(htmls) {
    const pages = htmls.map((h) => { const tpl = document.createElement('template'); tpl.innerHTML = h; return tpl.content; });
    const maps = pages.map(pageFields);
    const base = pages[0];
    let kept = 0;
    for (const [sig, f] of maps[0]) {
        // (Each one's own name.)
        const own = f.kind === 'world' && f.key === 'label';
        if (own || !maps.every((m) => m.has(sig))) { f.unit.remove(); continue; }
        const values = maps.map((m) => m.get(sig).value);
        for (const el of f.els) el.dataset.t = 'many:' + f.kind;
        if (values.some((v) => v !== values[0])) markMixed(f);
        kept++;
    }
    if (!kept) return '';
    // Words, heads and lines: only those every page has alike.
    const said = (root, sel) => new Set([...root.querySelectorAll(sel)].map((x) => x.textContent));
    for (const sel of ['.dr-hint', '.dr-none', '.dr-group']) {
        const sets = pages.slice(1).map((p) => said(p, sel));
        for (const x of base.querySelectorAll(sel)) if (!sets.every((s) => s.has(x.textContent))) x.remove();
    }
    // One thing's own: its buttons (not a field's own, a time's list), and rows that only say something.
    for (const x of base.querySelectorAll('[data-act]')) if (!x.closest('.dr-dhms')) x.remove();
    for (const x of base.querySelectorAll('.dr-btns, .dr-row, .dr-pair')) if (!x.querySelector('[data-t]')) x.remove();
    // A head with nothing under it before the next.
    const top = [...base.children];
    top.forEach((x, n) => {
        if (x.classList.contains('dr-group') && (n === top.length - 1 || top[n + 1].classList.contains('dr-group'))) x.remove();
    });
    const box = document.createElement('div');
    box.appendChild(base);
    return box.innerHTML;
}

/** Why a prop stays where it is placed in a run whatever its Physics says (server/director/nodes_props.lua physicsOff),
 *  or ''. (A Fixed Weapon has a page of its own, and only it can be attached.) */
function propStillWhy(w) {
    if (w.def.interior) return 'inside an interior, it stays where it is placed';
    if (w.def.collision === false) return 'not solid, it stays where it is placed';
    if (tasksOf(w).list.length) return 'its tasks move it, so it goes only where they take it';
    return '';
}

/** A thing's picture on its row, as the furnisher's Placed list draws one: a car's or an
 *  NPC's picture (a glyph standing in until there is one), a prop's, or its kind's glyph. A Vehicle pool's: its first
 *  car's (its page shows them all: poolArt, POOL_ART of them, then how many more). */
const KIND_GLYPH = { prop: 'box', npc: 'person', vehicle: 'car', spot: 'pin', groundItem: 'box', container: 'chest', door: 'door', route: 'pin' };
const POOL_ART = 4;
function carArt(model) {
    return `<span class="dr-world-art"><img src="${e(vehicleImageUrl(model))}" alt="" data-fit="vehicle" data-model="${e(model)}"`
        + ` onerror="this.parentNode.classList.add('dr-noimg')"><span class="dr-world-glyph">${GLYPHS.car || ''}</span></span>`;
}
/** A Vehicle pool's cars side by side, for the top of its page (a row's picture is its first car's: worldArt). */
function poolArt(w) {
    const list = carModels(w);
    const more = list.length - POOL_ART;
    return `<span class="dr-pool-art" title="${e(list.map((m) => m.model).join(', '))}">`
        + list.slice(0, POOL_ART).map((m) => carArt(m.model)).join('')
        + (more > 0 ? `<span class="dr-pool-more">+${more}</span>` : '') + '</span>';
}
function worldArt(w) {
    const g = `<span class="dr-world-art dr-world-glyph">${GLYPHS[KIND_GLYPH[w.kind] || 'box'] || ''}</span>`;
    if (w.kind === 'vehicle' && w.def && w.def.random) {
        const list = carModels(w);
        return list.length ? carArt(list[0].model) : g;
    }
    const m = w.def && typeof w.def.model === 'string' && w.def.model ? w.def.model : '';
    const url = !m ? null : w.kind === 'vehicle' ? vehicleImageUrl(m) : w.kind === 'npc' ? pedImageUrl(m) : w.kind === 'prop' ? propImageUrl(m) : null;
    if (!url) return g;
    // The thing itself as big as the box allows, an NPC's head and shoulders (utils.js fitPicture, as it loads: app.js).
    const fit = ` data-fit="${e(w.kind)}" data-model="${e(m)}"${w.kind === 'npc' ? ' data-fit-head' : ''}`;
    return `<span class="dr-world-art"><img src="${e(url)}" alt=""${fit} onerror="this.parentNode.classList.add('dr-noimg')">`
        + `<span class="dr-world-glyph">${GLYPHS[KIND_GLYPH[w.kind]] || ''}</span></span>`;
}

function worldTab(ed) {
    // PLACED IN THE WORLD BUILDER: the furnisher, anywhere, with Props, NPCs,
    // Vehicles and More (spots, item spots, containers, doors). This tab is the list of what is placed;
    // a click on one opens its page.
    // (Several selected in the world builder: one page for them all.)
    if (ed.multi && multiThings(ed).length > 1) return multiPage(ed);
    const open = ed.worldOpen && findWorld(ed.doc, ed.worldOpen);
    if (open && ed.taskPick === open.id && ed.tasks) return taskPicker(ed, open);
    if (open && ed.taskCopy && ed.taskCopy.id === open.id && ed.tasks) return taskCopier(ed, open);
    if (open && ed.voicePick && ed.voicePick.id === open.id) return voicePicker(ed, open);
    if (open) return worldPage(ed, open);
    // The world builder saves by itself every five minutes while there is something to save, unless this says not
    // (this player's choice, kept on this PC: app.js autosaveOn).
    const auto = ed.autosaveOn ? ed.autosaveOn() : true;
    return '<div class="dr-btns"><button class="dr-btn primary" data-act="build-open" title="The world builder: props, NPCs, vehicles, spots, containers and doors">Place in the world</button></div>'
        + `<button class="dr-sw" role="switch" aria-checked="${auto}" data-act="autosave">`
        + '<span class="dr-sw-name">Auto-save in the world builder<small>Every 5 minutes, while there is something to save</small></span>'
        + `<span class="dr-switch${auto ? ' on' : ''}"></span></button>`
        + '<div class="dr-hint">Always present things are there whenever the scenario is on (a quest giver, the crates in the warehouse). Things that only activate via card are made by a card while the scenario plays (Spawn NPC, Place Item, Spawn Car, Create Container, Show Prop) and go when it ends; the scenario holds a door with Lock / Unlock Door and gives it back as it was. A spot is just a place: for a blip, a waypoint, a drop-off or an area. A route is points an NPC walks (More, Route).</div>'
        + (ed.doc.world.length ? ed.doc.world.map((w) => worldRow(ed, w)).join('') : '<div class="dr-none">Nothing placed yet: Place in the world</div>');
}

function varsTab(ed) {
    const rows = ed.doc.vars.map((v) => {
        const t = 'var:' + v.id;
        const uses = usesOfVar(ed.doc, ed.cards, v.id).length;
        const def = v.type === 'bool'
            ? switchField(t, 'default', v.default, { label: 'Starts as yes', fallback: false })
            : v.type === 'number'
                ? numberField(t, 'default', v.default, { label: 'Starts as', placeholder: '0' })
                : textField(t, 'default', v.default, { label: 'Starts as', max: 100 });
        return '<div class="dr-item open"><div class="dr-world-edit">'
            + `<div class="dr-row">${label('Name', 'cards name it by this')}<input class="dr-field" type="text" value="${e(v.id)}" data-act-change="rename-var" data-id="${e(v.id)}" spellcheck="false"></div>`
            + segField(t, 'type', v.type, VAR_TYPES, { label: 'Holds', fallback: 'text' })
            + def
            + `<div class="dr-btns"><button class="dr-btn danger" data-act="remove-var" data-id="${e(v.id)}">Remove${uses ? ` (used by ${uses})` : ''}</button></div>`
            + '</div></div>';
    }).join('');
    return '<div class="dr-btns"><button class="dr-btn" data-act="add-var">+ Variable</button></div>'
        + '<div class="dr-hint">A variable starts at its value each time the scenario starts.</div>'
        + (rows || '<div class="dr-none">No variables</div>');
}

/** How a switched-on scenario's runs begin (server/director/main.lua). 'enabled': at once as it is switched on, with
 *  nobody in it until a player talks, presses or comes near (Director.openRun). */
const START_MODES = [
    ['enabled', 'When it\'s switched on'],
    ['interaction', 'Talk to an NPC'],
    ['press', 'Press something'],
    ['area', 'A player comes near'],
    ['item', 'Use an item'],
    ['timer', 'On a timer'],
    ['script', 'From a script'],
    ['admin', 'By hand (an admin starts it)'],
];

/** The Settings tab's "A run starts" fields, by mode. */
function startFields(ed, st) {
    const mode = st.mode || 'admin';
    const placed = ed.doc.world.map((w) => [w.id, w.label || w.id]);
    const where = (label) => selectField('start', 'world', st.world, placed,
        { label, hint: placed.length ? '' : 'place something in the World tab first', none: '— pick a placed thing —' });
    const hint = (text) => `<div class="dr-hint">${e(text)}</div>`;
    if (mode === 'enabled') {
        return hint('Scenario Enabled\'s cards play as soon as it is switched on, with nobody in the scenario yet: what they '
            + 'make is out for everyone. The first player to talk to its NPC (a Dialog Line), press its prompt (Wait for '
            + 'Press, an Interaction Menu) or come near (Player Arrives) joins, and the job starts at Scenario Started '
            + 'By Player (or as they join, without one). Once it is over it starts again, fresh, for the next player.');
    }
    if (mode === 'interaction') {
        const standing = ed.doc.world.filter((w) => w.kind === 'npc' && w.layer === 'standing').map((w) => [w.id, w.label || w.id]);
        return selectField('start', 'world', st.world, standing,
            { label: 'Which NPC', hint: standing.length ? '' : 'needs an NPC set to Always present', none: '— pick an always present NPC —' })
            + textField('start', 'label', st.label, { label: 'Its prompt', max: 40, placeholder: 'Talk' });
    }
    if (mode === 'press') {
        return where('Press what')
            + textField('start', 'label', st.label, { label: 'Its prompt', max: 40, placeholder: 'Use' })
            + hint('An E prompt on that placed thing (a standing prop, or a spot): a laptop, a keypad, a job board.');
    }
    if (mode === 'area') {
        // A spot with a marker says how near (and whether by car): its page.
        const spot = markedSpot(ed, st.world);
        return where('Near what')
            + (spot ? bySpotRow('Within', spot)
                : numberField('start', 'radius', st.radius, { label: 'Within', hint: 'metres', min: 1, max: 500, placeholder: '10' }))
            + hint('A player who walks within the distance starts it. Once a visit: still standing there when it ends, they must leave and come back.');
    }
    if (mode === 'item') {
        return itemField('start', 'item', st.item, { label: 'Which item' })
            + switchField('start', 'consume', st.consume === true, { label: 'Used up when it starts the scenario' })
            + hint('Using it from the inventory starts the scenario. Only an item that does nothing else when used (Check says if it does).');
    }
    if (mode === 'timer') {
        return numberField('start', 'every', st.every, { label: 'Every', hint: 'minutes', min: 1, max: 1440, placeholder: '30' })
            + where('For the players near')
            + numberField('start', 'radius', st.radius, { label: 'Within', hint: 'metres', min: 1, max: 500, placeholder: '10' })
            + hint('The first comes that long after it is switched on. Nobody near when it comes round: it waits until the next time.');
    }
    if (mode === 'script') {
        return hint('Another resource starts it for a player, once this is switched on:')
            + `<pre class="dr-code">exports.whip_core:StartScenarioRun('${e(ed.key || 'key')}', source)</pre>`;
    }
    return hint('Only when someone starts it by hand: Start a run (here, once it is switched on), or /director start '
        + (ed.key || '<key>') + '.');
}

/** Seconds as minutes, for the line beside a long time: "45 min", "1 h 30 min", "2 d 3 h". */
function minutes(sec) {
    const m = Math.round(sec / 60);
    if (m < 60) return `${m} min`;
    if (m >= 1440) return `${Math.floor(m / 1440)} d` + (Math.floor(m % 1440 / 60) ? ` ${Math.floor(m % 1440 / 60)} h` : '');
    return `${Math.floor(m / 60)} h` + (m % 60 ? ` ${m % 60} min` : '');
}

/** The scenario's settings, on its Scenario Enabled card's page: how a run starts first, then its limits, what
 *  scripts are told, its name, and its saved revisions. */
/** VARIANTS (Multi Run Variants: server/director/main.lua pickVariant): which one a new run plays. First free: the first
 *  not being played. Random: any free one. In order: the list set here, in turn (1, 4, 2, 3...), a busy one passed
 *  over. Every one busy: no run, as when Runs at once is full. */
const VARIANT_PICKS = [['sequential', 'First free'], ['random', 'Random'], ['order', 'In order']];
const VARIANT_PICK_SAYS = {
    sequential: 'A new run plays the first variant nobody is playing.',
    random: 'A new run plays any variant nobody is playing, picked at random.',
    order: 'A new run plays the next one in this list, passing over one being played.',
};

function variantsGroup(ed, s, variants) {
    const pick = VARIANT_PICKS.some(([v]) => v === s.variantPick) ? s.variantPick : 'sequential';
    // (Its number is where it is among the variant buttons; the list's order is the rows' order.)
    const numOf = (id) => variants.findIndex((v) => v.id === id) + 1;
    const nameOf = (id) => {
        const i = variants.findIndex((v) => v.id === id);
        return i < 0 ? null : (variants[i].name || `Variant ${i + 1}`);
    };
    let html = groupHead('Variants')
        + segField('settings', 'variantPick', s.variantPick, VARIANT_PICKS, { label: 'A run plays', fallback: 'sequential' })
        + `<div class="dr-hint">${e(VARIANT_PICK_SAYS[pick])}</div>`;
    if (pick !== 'order') return html;
    const order = Array.isArray(s.variantOrder) ? s.variantOrder.filter((id) => nameOf(id)) : [];
    if (!order.length) {
        return html + `<div class="dr-btns dr-btns-tight"><button class="dr-btn primary" data-act="vorder-fill">Start the list: ${variants.map((_, i) => i + 1).join(', ')}</button></div>`;
    }
    html += '<div class="dr-vorder">' + order.map((id, i) => `<div class="dr-vorder-row"><span class="dr-vorder-n">${numOf(id)}</span>`
        + `<span class="dr-vorder-name">${e(nameOf(id))}</span>`
        + `<button class="dr-ibtn" data-act="vorder-move" data-i="${i}" data-by="-1" aria-label="Earlier"${i === 0 ? ' disabled' : ''}>${uiIcon('up')}</button>`
        + `<button class="dr-ibtn" data-act="vorder-move" data-i="${i}" data-by="1" aria-label="Later"${i === order.length - 1 ? ' disabled' : ''}>${uiIcon('down')}</button>`
        + `<button class="dr-ibtn" data-act="vorder-remove" data-i="${i}" aria-label="Take it out of the list">${uiIcon('close')}</button></div>`).join('') + '</div>';
    const left = variants.filter((v) => !order.includes(v.id));
    if (left.length) {
        html += '<div class="dr-btns dr-btns-tight">' + left.map((v) => `<button class="dr-btn ghost" data-act="vorder-add" data-id="${e(v.id)}">+ ${numOf(v.id)} · ${e(nameOf(v.id))}</button>`).join('') + '</div>'
            + '<div class="dr-hint">One left out of the list is never played.</div>';
    }
    return html;
}

function scenarioSettings(ed) {
    const s = ed.doc.settings, st = s.start;
    // (Left empty, a run lasts an hour at most: server/director/runtime.lua maxRunSec.)
    const longest = typeof s.maxRunSec === 'number' ? s.maxRunSec : 3600;
    const variants = variantList(ed.doc);
    const many = variants.length > 1;
    let html = groupHead('How it starts')
        + selectField('start', 'mode', st.mode || 'admin', START_MODES, { label: 'It starts', none: '— pick one —' })
        + startFields(ed, st)
        + (many ? '<div class="dr-hint">The same for every variant: one start, and what is always present.</div>' : '');
    if (many) html += variantsGroup(ed, s, variants);
    html += groupHead('Limits')
        + '<div class="dr-pair">'
        // (With variants: one run per variant at most, and empty is one each.)
        + numberField('settings', 'maxConcurrentRuns', s.maxConcurrentRuns, many
            ? { label: 'Runs at once', hint: 'one per variant', min: 1, max: variants.length, placeholder: String(variants.length) }
            : { label: 'Runs at once', min: 1, max: 10, placeholder: '1' })
        // The run decides how many you can bring: Pick Team's slots, and the most any
        // way of joining puts in. (Nobody joins for standing near the starter: the crew is picked on Pick
        // Team. A timer start is the one made for a group: the players near its placed thing.)
        + numberField('settings', 'teamSize', s.teamSize, { label: 'Team size', hint: 'you included', min: 1, max: 16, placeholder: '16' })
        + '</div>'
        + timeField('settings', 'maxRunSec', s.maxRunSec, { label: 'Longest it lasts', hint: minutes(longest), fallback: 3600 })
        // Each player's wait before another job of it (server/director/main.lua cooldowns), from when one they were in ends.
        + numberField('settings', 'cooldownMin', s.cooldownMin, { label: 'Cooldown', hint: 'minutes, after a job', min: 0, max: 10080, placeholder: '0' })
        // Who waits (main.lua cooldownWho): everyone in the job, or only whoever started it.
        + selectField('settings', 'cooldownWho', s.cooldownWho === 'starter' ? 'starter' : 'everyone',
            [['everyone', 'Everyone in the job'], ['starter', 'Only who started it']], { label: 'Cooldown is for', noEmpty: true })
        + '<div class="dr-hint">How long a player waits before they can do this job again. Put a <b>Scenario Started By Player</b> card where the job really begins (once they accept it): the cooldown counts only from there, so a player who just talks and walks away is not held up.</div>';
    // What other resources are told about it (the Director API): a police script hears a heist start, and where. Only
    // when it starts from a script, or one of them is set already (nothing set is ever hidden).
    const kinds = typeof s.kinds === 'string' ? s.kinds : (Array.isArray(s.kinds) ? s.kinds.join(', ') : '');
    if (st.mode === 'script' || kinds || s.where || s.scriptSwitch === true) {
        const placedThings = ed.doc.world.map((w) => [w.id, w.label || w.id]);
        html += groupHead('For scripts')
            + textField('settings', 'kinds', kinds, { label: 'Kind', hint: 'commas between', max: 160, placeholder: 'heist, crime' })
            + selectField('settings', 'where', s.where, placedThings, { label: 'Where it happens', hint: 'not where it starts', none: '— where it starts —' })
            + switchField('settings', 'scriptSwitch', s.scriptSwitch === true, { label: 'Scripts may switch it on and off' });
    }
    html += groupHead('The scenario')
        + textField('doc', 'name', ed.doc.name, { label: 'Name', max: 80 })
        + textField('doc', 'description', ed.doc.description, { label: 'Description', max: 500, big: true });
    html += groupHead('Saved revisions');
    if (!ed.revisions) {
        html += '<div class="dr-btns"><button class="dr-btn" data-act="history">Show revisions</button></div>';
    } else if (!ed.revisions.length) {
        html += '<div class="dr-none">None</div>';
    } else {
        html += ed.revisions.map((r) => `<div class="dr-rev"><div><b>Revision ${r.rev}</b>`
            + `<span>${e(r.editedBy || 'someone')} · ${e(dateTime(r.createdAt, ''))}${r.note ? ' · ' + e(r.note) : ''}</span></div>`
            + `<button class="dr-btn ghost" data-act="load-rev" data-rev="${r.rev}">Open</button></div>`).join('');
    }
    return html;
}

const OUTCOME = {
    succeeded: ['ok', 'Succeeded'], failed: ['error', 'Failed'], faulted: ['error', 'Went wrong'], aborted: ['', 'Stopped'],
    running: ['', 'Still going when you stopped it'],
};

/** The last test: how it ended, and every card it ran, in order (the trace, from the server). Nothing
 *  before the first: Test is the toolbar's. */
function lastTestHtml(ed) {
    const t = ed.lastTest;
    if (!t) return '';
    const [tone, text] = OUTCOME[t.outcome] || ['', String(t.outcome || 'Over')];
    let html = groupHead('Last test')
        + `<div class="dr-sum ${tone}">${e(text)}${t.reason ? ': ' + e(t.reason) : ''}</div>`;
    if (t.fault) {
        const n = findNode(ed.doc, t.fault);
        const def = n && ed.cards.get(n.type);
        html += `<div class="dr-prob error link" data-act="goto-node" data-id="${e(t.fault)}">It went wrong at <b>${e(def ? def.title : t.fault)}</b> (the card flashing on the grid)</div>`;
    }
    html += '<div class="dr-steps">' + t.steps.map((s) => {
        const n = findNode(ed.doc, s.node);
        const def = n && ed.cards.get(n.type);
        const title = def ? def.title : (n ? n.type : s.node + ' (gone)');
        const pins = s.pins.map((p) => pinLabel(n, def, p)).filter(Boolean);
        // (An outcome that means it could not do its work, in red: the card is red on the grid too.)
        const bad = s.pins.length > 0 && s.pins.every((p) => couldNot(p));
        const went = pins.length ? (bad ? ` <span class="dr-step-bad">→ ${e(pins.join(', '))}</span>` : ' → ' + e(pins.join(', '))) : '';
        return `<div class="dr-step" data-act="goto-node" data-id="${e(s.node)}"><span class="dr-step-at">${s.at.toFixed(1)} s</span>`
            + `<b>${e(title)}</b>${went}${s.note ? ` <i>${e(s.note)}</i>` : ''}</div>`;
    }).join('') + '</div>';
    html += '<div class="dr-btns"><button class="dr-btn ghost" data-act="clear-test">Clear</button></div>';
    return html;
}

/** The Check page (the toolbar's Check, over the tab it was pressed on): what is wrong, the last test, and
 *  switching it on. */
function checkTab(ed) {
    const dirty = ed.history.isDirty(ed.doc);
    const errors = ed.problemList.filter((p) => p.severity === 'error');
    const warns = ed.problemList.filter((p) => p.severity !== 'error');
    let html = backRow(ed, 'page-back') + '<div class="dr-title2">Check and switch on</div>';
    if (ed.checkedAt) {
        html += errors.length || warns.length
            ? `<div class="dr-sum ${errors.length ? 'error' : 'warn'}">${plural(errors.length, 'error')}, ${plural(warns.length, 'warning')}</div>`
            : '<div class="dr-sum ok">No problems</div>';
        html += ed.problemList.map((p, i) => {
            const n = p.node && findNode(ed.doc, p.node);
            const def = n && ed.cards.get(n.type);
            const cards = problemCards(p).filter((id) => findNode(ed.doc, id));
            const fix = p.tab === 'world' && p.world ? 'World tab' : (p.tab === 'settings' ? 'Scenario Enabled' : null);
            const lit = !n && cards.length ? ` <span class="dr-prob-cards">${plural(cards.length, 'card')} lit</span>` : '';
            return `<div class="dr-prob ${p.severity === 'error' ? 'error' : 'warn'}${cards.length ? ' link' : ''}" data-act="goto-prob" data-i="${i}">`
                + (n ? `<b>${e(def ? def.title : n.type)}</b> ` : '') + e(p.message) + lit
                + (fix ? `<button class="dr-btn ghost dr-prob-fix" data-act="prob-fix" data-i="${i}">${e(fix)} →</button>` : '')
                + '</div>';
        }).join('');
        // The other variants' own problems: said by variant, with a button to open it (an error in any stops it switching on).
        const open = ed.doc.variantOpen || 'v1';
        const variants = variantList(ed.doc);
        for (const [i, v] of variants.entries()) {
            if (v.id === open) continue;
            const mine = (ed.problemsAll || []).filter((p) => p.variant === v.id);
            if (!mine.length) continue;
            const errs = mine.filter((p) => p.severity === 'error').length;
            html += `<div class="dr-prob ${errs ? 'error' : 'warn'}"><b>${e(v.name || `Variant ${i + 1}`)}</b> `
                + `${errs ? plural(errs, 'error') : ''}${errs && mine.length > errs ? ', ' : ''}`
                + `${mine.length > errs ? plural(mine.length - errs, 'warning') : ''}`
                + `<button class="dr-btn ghost dr-prob-fix" data-act="variant-open" data-id="${e(v.id)}">Open it →</button></div>`;
        }
    } else {
        html += '<div class="dr-hint">Check reads the scenario the way the server will run it. Errors stop it from being switched on; warnings do not.</div>';
    }
    html += '<div class="dr-btns"><button class="dr-btn" data-act="check">Check again</button></div>';
    html += lastTestHtml(ed);
    html += groupHead('In the world');
    if (ed.on) {
        html += `<div class="dr-sum ok">On, at revision ${ed.onRev}</div>`;
        if (ed.onRev !== ed.baseRev) html += `<div class="dr-hint">Revision ${ed.baseRev} is newer: switch it on to put it live.</div>`;
    } else {
        html += '<div class="dr-sum">Off</div>';
    }
    html += '<div class="dr-btns">'
        + `<button class="dr-btn primary" data-act="activate"${dirty ? ' disabled' : ''}>Switch on revision ${ed.baseRev}</button>`
        + (ed.on ? '<button class="dr-btn" data-act="deactivate">Switch off</button><button class="dr-btn" data-act="start-run">Start a run</button>' : '')
        + '</div>'
        + (dirty ? '<div class="dr-hint">Save first: what is switched on is a saved revision.</div>' : '');
    return html;
}

export function renderTab(ed) {
    // The item picker is over whatever page it was opened from, until it picks or goes back.
    if (ed.picker) return itemPicker(ed);
    switch (ed.tab) {
        case 'cards': return cardsTab(ed);
        case 'card': return cardTab(ed);
        case 'world': return worldTab(ed);
        case 'vars': return varsTab(ed);
        case 'check': return checkTab(ed);
        default: return '';
    }
}

/** The object a field edits. */
export function targetOf(ed, spec) {
    const i = spec.indexOf(':');
    const kind = i < 0 ? spec : spec.slice(0, i);
    const id = i < 0 ? '' : spec.slice(i + 1);
    const doc = ed.doc;
    if (kind === 'doc') return doc;
    if (kind === 'settings') return doc.settings;
    if (kind === 'start') return doc.settings.start;
    if (kind === 'node') { const n = findNode(doc, id); return n ? n.props : null; }
    if (kind === 'world') return findWorld(doc, id);
    if (kind === 'def') { const w = findWorld(doc, id); return w ? w.def : null; }
    if (kind === 'cond') {
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.conditions || typeof w.def.conditions !== 'object') w.def.conditions = {};
        return w.def.conditions;
    }
    if (kind === 'var') return doc.vars.find((v) => v.id === id) || null;
    if (kind === 'carkey') {
        // A car's Key settings (made when first written into): { exists, where, spot }.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.key || typeof w.def.key !== 'object') w.def.key = {};
        return w.def.key;
    }
    if (kind === 'tasks') {
        // A placed thing's task list (made when first written into): its after and fight.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.tasks || typeof w.def.tasks !== 'object') w.def.tasks = { list: [] };
        return w.def.tasks;
    }
    if (kind === 'rider' || kind === 'take') {
        // 'rider:<carId>:<n>': one of a car's riders; 'take:<carId>:<take id>': one of its takes (its name).
        const j = id.lastIndexOf(':');
        const w = j < 0 ? null : findWorld(doc, id.slice(0, j));
        const which = id.slice(j + 1);
        if (!w) return null;
        if (kind === 'rider') return Array.isArray(w.def.riders) ? w.def.riders[Number(which)] || null : null;
        return takesOf(w).find((t) => String(t.id) === which) || null;
    }
    if (kind === 'step' || kind === 'rpoint') {
        // 'step:<worldId>:<key>': one step of its task list; 'rpoint:<routeId>:<key>': one of a route's points.
        const j = id.lastIndexOf(':');
        const w = j < 0 ? null : findWorld(doc, id.slice(0, j));
        const list = !w ? null : kind === 'step' ? (w.def.tasks && w.def.tasks.list) : w.def.points;
        return (Array.isArray(list) && list.find((s) => s && s.k === id.slice(j + 1))) || null;
    }
    if (kind === 'outfit') {
        // An NPC's Outfit, made when first written into with every part its ped has as the page showed it.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.outfit || typeof w.def.outfit !== 'object') w.def.outfit = outfitDefaults(ed, w);
        return w.def.outfit;
    }
    if (kind === 'vision') {
        // What an NPC sees, made when first written into.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.vision || typeof w.def.vision !== 'object') w.def.vision = {};
        return w.def.vision;
    }
    if (kind === 'attach') {
        // A Fixed Weapon's Attached to, made when first written into: { to = the placed thing it rides on }.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.attach || typeof w.def.attach !== 'object') w.def.attach = {};
        return w.def.attach;
    }
    if (kind === 'marker') {
        // A spot's marker, made when first written into.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.marker || typeof w.def.marker !== 'object') w.def.marker = {};
        return w.def.marker;
    }
    if (kind === 'rot') {
        // A prop's tilt, made when first written into.
        const w = findWorld(doc, id);
        if (!w) return null;
        if (!w.def.rot || typeof w.def.rot !== 'object') w.def.rot = {};
        return w.def.rot;
    }
    if (kind === 'loot') {
        // 'loot:<nodeId>:<n>': one of what a container's slots may hold (Create Container's lootEditor).
        const j = id.lastIndexOf(':');
        const n = j < 0 ? null : findNode(doc, id.slice(0, j));
        const list = n && Array.isArray(n.props.loot) ? n.props.loot : null;
        return (list && list[Number(id.slice(j + 1))]) || null;
    }
    if (kind === 'rule') {
        // 'rule:<nodeId>:<propKey>': an answer's rules, made when first written into.
        const j = id.lastIndexOf(':');
        const n = j < 0 ? null : findNode(doc, id.slice(0, j));
        if (!n) return null;
        const k = id.slice(j + 1);
        if (!n.props[k] || typeof n.props[k] !== 'object') n.props[k] = {};
        return n.props[k];
    }
    return null;
}

/** An answer's rules left empty go: no rules is no object at all. */
function tidy(ed, spec) {
    if (!spec.startsWith('rule:')) return;
    const id = spec.slice(5), j = id.lastIndexOf(':');
    const n = findNode(ed.doc, id.slice(0, j));
    const k = id.slice(j + 1);
    if (n && n.props[k] && typeof n.props[k] === 'object' && !Object.keys(n.props[k]).length) delete n.props[k];
}

/** The objects a field edits: one, or for 'many:<kind>' (several selected: multiPage) each selected thing's. */
export function targetsOf(ed, spec) {
    if (!spec.startsWith('many:')) { const o = targetOf(ed, spec); return o ? [o] : []; }
    const kind = spec.slice(5);
    return multiThings(ed).map((w) => targetOf(ed, kind + ':' + w.id)).filter(Boolean);
}

/** Write a field's value into the document. Answers true when something changed. */
export function writeField(ed, el) {
    const objs = targetsOf(ed, el.dataset.t);
    if (!objs.length) return false;
    const k = el.dataset.k;
    const f = el.dataset.f;
    // The value, worked out once (undefined: none, the key goes), for each object it is written into.
    let v;
    if (f === 'number') {
        const n = parseFloat(el.value);
        v = isNaN(n) ? undefined : n;
    } else if (f === 'dhms') {
        // A time field's four boxes (timeField), added up in seconds; all four empty: its default.
        const box = el.closest('.dr-dhms');
        const unit = { d: 86400, h: 3600, m: 60, s: 1 };
        let total = 0, any = false;
        for (const inp of box ? box.querySelectorAll('input[data-part]') : []) {
            const n = parseFloat(inp.value);
            if (!isNaN(n) && n > 0) total += n * unit[inp.dataset.part];
            if (inp.value !== '') any = true;
        }
        v = any ? Math.round(total * 10) / 10 : undefined;   // (to a tenth of a second: timeField)
    } else if (f === 'select' || f === 'text') {
        // (A Mixed list's own line is never a value.)
        if (el.value === '__mixed') return false;
        v = el.value === '' && k !== 'name' ? undefined : el.value;
    } else {
        return false;
    }
    let changed = false;
    for (const obj of objs) {
        const before = JSON.stringify(obj[k]);
        if (v === undefined) delete obj[k]; else obj[k] = v;
        if (JSON.stringify(obj[k]) === before) continue;
        changed = true;
        // (An Outfit's style changed: its colour starts at that style's first.)
        if (el.dataset.t.startsWith('outfit:') && /^[cp]\d+d$/.test(k)) obj[k.slice(0, -1) + 't'] = 0;
    }
    tidy(ed, el.dataset.t);
    return changed;
}

/** A segmented key pressed. */
export function writeSeg(ed, el) {
    const objs = targetsOf(ed, el.dataset.t);
    if (!objs.length) return false;
    let v;
    try { v = JSON.parse(el.dataset.v); } catch (_) { return false; }
    let changed = false;
    for (const obj of objs) {
        if (obj[el.dataset.k] === v) continue;
        obj[el.dataset.k] = v;
        changed = true;
    }
    if (!changed) tidy(ed, el.dataset.t);
    return changed;
}
