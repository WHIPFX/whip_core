// ========================================
// /whip SECTION — Player Manager
//
// The biggest port: list+detail like containers.js, but the detail pane is data-heavy
// (eight collapsible groups) rather than a form. Ported from player-manager.js; the
// static #player-manager-overlay markup and player-manager.css are gone — everything
// builds through WP helpers and the wp-* vocabulary, all data strings via textContent
// (player names are hostile input — the old file needed plmEsc, this one doesn't).
//
// The six old plm-dialogs collapsed into two shapes: unban (a bare confirm) is
// WP.confirm; the four with inputs (kick reason, tempban reason+duration, permaban
// reason, note text) are inline forms that appear on demand inside the pane —
// kick and the character picker under the actions row, tempban/permaban inside Ban
// History, note inside Admin Notes — tracked by one `inlineForm` module state, the
// same shape as the reference's editing pattern.
//
// The nuiCallback names and payloads are UNCHANGED from the standalone tool
// (plmSelectUser, plmKick, plmBan, plmUnban, plmAddNote, plmDeleteNote,
// plmTeleportTo, plmBringPlayer, plmOpenInventory) — their Lua halves moved to
// tools/panel_sections/playerManager.lua. Detail arrives as onData('detail', …),
// the panel framing of the old pmShowDetail router action. plmSetStat is Current Stats'.
// ========================================

import { WhipPanel, WP, VERB_GLYPHS } from '../whip-panel.js';
import { uiIcon } from '../ui-icons.js';
import { nuiCallback } from '../utils.js';
// Current Stats draws each stat as the HUD does (status-hud.js), named as Settings' gauge row names them.
import { hudGauge, hudSkinClass } from '../status-hud.js';
import { statLabel } from './config.js';
// The shared timeline renderer + the jump into an item's own history — one renderer
// so the player and item timelines read identically.
import { openItemTimeline, buildLogRow, confirmTeleport } from './itemlog.js';
import { avatar, vehiclePortrait } from './pickers.js';
// Their cars' cards say what state each is in in the Vehicles page's words, and open it there.
import { vehicleStatus } from './vehicles.js';
import { toMs, ago, dateTime, timeOfDay, money } from './format.js';
import { logoMarkup, logoLight } from '../logo-light.js';

let users = [];
let selectedUserId = null;
let selectedSession = 0;     // which of the selected account's sessions (its server id), 0 when offline
let detail = null;           // the selected user's full detail payload, or null
let filter = 'all';          // 'all' | 'online' | 'banned'
let search = '';
let inlineForm = null;       // null | 'kick' | 'tempban' | 'permaban' | 'note' | 'selectchar'
let els = {};

// ---- formatting helpers (times, dates and money: wp/format.js) ----

function fmtDuration(seconds) {
    if (!seconds || seconds <= 0) return 'Permanent';
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const parts = [];
    if (d > 0) parts.push(d + 'd');
    if (h > 0) parts.push(h + 'h');
    if (m > 0) parts.push(m + 'm');
    return parts.length > 0 ? parts.join(' ') : '<1m';
}

function fmtExpiry(val) {
    if (!val) return 'Permanent';
    const ts = toMs(val);
    if (!ts || isNaN(ts)) return String(val);
    const now = Date.now();
    if (ts <= now) return 'Expired';
    const remaining = Math.floor((ts - now) / 1000);
    return fmtDuration(remaining) + ' remaining (' + dateTime(ts) + ')';
}

// ---- list ----

// A ROW IS A SESSION. One account can have two characters in at once (two clients on one PC share a
// license, so they are one user): the server sends a row for each, with its server id, the character it
// plays and, with the warning on, `sessions`: how many the account has in. An offline account is one row, session 0.
const sessionOf = (u) => (u && u.online && u.source) ? Number(u.source) : 0;

/** The other session of the shown account playing this character, if one is: its server id. */
function otherSessionOf(u, charId) {
    const s = (u && u.otherSessions || []).find((o) => o.charId === charId);
    return s ? s.source : null;
}

function filteredUsers() {
    const needle = search.toLowerCase();
    const out = [];
    for (const u of users) {
        if (filter === 'online' && !u.online) continue;
        if (filter === 'banned' && !u.activeBans) continue;
        if (needle) {
            // characterNames: the server's name for it (devtools.lua).
            const hay = ((u.name || '') + ' ' + (u.license || '') + ' ' + (u.characterNames || '')).toLowerCase();
            if (hay.indexOf(needle) === -1) continue;
        }
        out.push(u);
    }
    // Online first, then by name; one account's sessions together, by server id.
    out.sort((a, b) => {
        if (a.online && !b.online) return -1;
        if (!a.online && b.online) return 1;
        return (a.name || '').localeCompare(b.name || '') || (a.userId - b.userId) || (sessionOf(a) - sessionOf(b));
    });
    return out;
}

/** A face with the online light on it (pickers.js avatar), the light said in words. */
function presence(name, online, charId, large) {
    const a = avatar(name, !!online, charId, large);
    const dot = a.querySelector('.wp-dot');
    if (dot) dot.title = online ? 'Online' : 'Offline';
    return a;
}

function renderList() {
    els.list.innerHTML = '';
    const shown = filteredUsers();
    els.count.textContent = shown.length + ' player' + (shown.length !== 1 ? 's' : '');

    if (shown.length === 0) {
        els.list.appendChild(WP.empty('No players found'));
        return;
    }

    for (const u of shown) {
        const item = WP.el('div', 'wp-list-item wp-has-icon');
        item.dataset.id = u.userId;
        item.dataset.session = sessionOf(u);
        item.dataset.action = 'pmgSelect';
        if (u.userId === selectedUserId && sessionOf(u) === selectedSession) item.classList.add('active');

        // Their face (the character they are playing, else the last one played), the online light on
        // it — the light's meaning in words too, for anyone squinting at a compressed stream.
        item.appendChild(presence(u.currentChar || u.name, u.online, u.faceCharId));

        const top = WP.el('div', 'wp-item-top');
        top.appendChild(WP.el('span', 'wp-item-title', u.name || 'Unknown'));
        // `sessions` comes only with Config.PlayerManagerSessionWarn on (server/devtools.lua).
        if (u.sessions > 1) {
            const pill = WP.el('span', 'wp-pill wp-pill-warn', u.sessions + ' SESSIONS');
            pill.title = 'This account has ' + u.sessions + ' characters in at once';
            top.appendChild(pill);
        }
        if (u.activeBans) top.appendChild(WP.el('span', 'wp-pill wp-pill-err', 'BANNED'));
        item.appendChild(top);

        // Online: its server id and the character it is playing, so an account's two sessions read
        // apart. Offline: its characters and when it was last seen.
        const sub = WP.el('div', 'wp-item-sub');
        if (u.online && u.source) {
            sub.appendChild(WP.el('span', 'wp-info-value-mono', '#' + u.source));
            sub.appendChild(document.createTextNode(' · ' + (u.currentChar || u.characterNames || '')));
        } else {
            sub.appendChild(document.createTextNode(
                (u.characterNames ? u.characterNames + ' · ' : '') + ago(u.lastSeen)));
        }
        item.appendChild(sub);

        els.list.appendChild(item);
    }
}

function setFilter(next) {
    filter = next;
    for (const key of Object.keys(els.filterBtns)) {
        els.filterBtns[key].classList.toggle('wp-btn-primary', key === filter);
    }
    renderList();
}

/** A row's page: the account, and which of its sessions (0: offline, or its first). */
function selectUser(userId, session) {
    selectedUserId = userId;
    selectedSession = session || 0;
    detail = null;
    setInlineForm(null);
    renderList();
    renderDetail();               // shows the loading state until 'detail' arrives
    nuiCallback('plmSelectUser', { userId: userId, session: selectedSession });
}

/** A player's page from anywhere in the panel: the Item Log's names link here. */
export function openPlayer(userId) {
    const id = Number(userId);
    if (!id) return;
    WhipPanel.switchTo('playerManager');
    selectUser(id, 0);
}

function deselect() {
    selectedUserId = null;
    selectedSession = 0;
    detail = null;
    setInlineForm(null);
    renderList();
    renderDetail();
}

// ---- inline forms (the old dialogs, in-pane) ----

function setInlineForm(name) {
    inlineForm = name || null;

    // Hide everything, clear last-run inputs (the old dialogs re-rendered fresh).
    for (const f of [els.kickForm, els.charForm, els.tempbanForm, els.permaForm, els.noteForm, els.renameForm]) {
        f.style.display = 'none';
    }
    // The verb whose form is open is the chosen card.
    const chosen = { kick: els.btnKick, selectchar: els.btnInventory, tempban: els.btnTempBan, permaban: els.btnPermaBan }[inlineForm];
    for (const b of [els.btnKick, els.btnInventory, els.btnTempBan, els.btnPermaBan]) b.classList.toggle('active', b === chosen);
    els.kickReason.value = '';
    els.tempbanReason.value = '';
    els.tempbanDuration.value = '';
    els.permaReason.value = '';
    els.noteText.value = '';
    els.renameFirst.value = '';
    els.renameLast.value = '';

    if (!inlineForm) return;

    // Kick and the bans open under the button pressed (the Actions group), and say who they are for.
    const who = (detail && detail.name) || 'this player';
    if (inlineForm === 'kick') {
        els.kickGo.textContent = 'Kick ' + who;
        els.kickForm.style.display = '';
        els.actionsGroup.classList.add('open');
    } else if (inlineForm === 'selectchar') {
        renderCharChoices();
        els.charForm.style.display = '';
        els.actionsGroup.classList.add('open');
    } else if (inlineForm === 'tempban') {
        els.tempbanGo.textContent = 'Ban ' + who;
        els.tempbanForm.style.display = '';
        els.actionsGroup.classList.add('open');
    } else if (inlineForm === 'permaban') {
        els.permaWarn.textContent = who + ' can’t join again until someone unbans them in Ban History.';
        els.permaGo.textContent = 'Ban ' + who + ' for good';
        els.permaForm.style.display = '';
        els.actionsGroup.classList.add('open');
    } else if (inlineForm === 'note') {
        els.noteForm.style.display = '';
        els.notesGroup.classList.add('open');
    } else if (inlineForm === 'rename') {
        // The character the Rename button was on, its names to edit.
        const c = ((detail && detail.characters) || []).find((x) => x.charId === renameCharId);
        if (!c) { inlineForm = null; return; }
        els.renameTitle.textContent = 'Rename ' + ((c.firstName || '') + ' ' + (c.lastName || '')).trim() + ' #' + c.charId;
        els.renameFirst.value = c.firstName || '';
        els.renameLast.value = c.lastName || '';
        els.renameForm.style.display = '';
        els.charsGroup.classList.add('open');
        els.renameFirst.focus();
    }
}

/** The character the open Rename form is for (its charId), or null. */
let renameCharId = null;

function renderCharChoices() {
    els.charList.innerHTML = '';
    const chars = detail ? (detail.characters || []) : [];
    for (const c of chars) {
        const isCurrent = detail.online && detail.currentCharId && c.charId === detail.currentCharId;
        const label = (c.firstName || '') + ' ' + (c.lastName || '') + ' #' + c.charId +
            (isCurrent || otherSessionOf(detail, c.charId) ? ' (online)' : '');
        const b = WP.btn(label, 'pmgPickChar');
        b.dataset.id = c.charId;
        els.charList.appendChild(b);
    }
}

// ---- the verbs (the Actions group) ----
//
// A card each: its icon in a small stat disc (the HUD's), the verb, and a line saying what it does to this player.
// The everyday ones on the left; Kick and the bans on the right, apart, their discs red, so Kick is never a slip
// away from Teleport. The verb whose form is open is the chosen card (setInlineForm), its disc lit white.

// Drawn as the glyph atlas's are (html/js/glyphs.js: 24 x 24, a round 2.1 stroke): the car cards' chevron.
const STROKE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">';

// A verb's card is the panel's (WP.verb), the three the atlas has no word for its VERB_GLYPHS.
const verb = WP.verb;

/** A ban still keeping them out: active, and not run out (the list's activeBans counts the same). */
function banHolds(ban) {
    if (!ban || !ban.active) return false;
    return !ban.expiresAt || toMs(ban.expiresAt) > Date.now();
}

// ---- Current Stats ----
//
// Every stat the player has, on their HUD now or not (server/stats.lua Stats.adminRows), as a list: the gauge as their
// HUD draws it (status-hud.js hudGauge, so a restyled HUD restyles these), its name and what it is, and its value in a
// box to type a new one into, with Apply. A value half-typed survives the page coming back from the server (another
// admin's change, a player leaving): statDrafts, kept until the page changes to someone else or it is applied.

const statDrafts = new Map();   // [stat name] = the text typed

/** A stat's value as typed: whole, or to a tenth (hunger drains in fractions). */
function statText(v) {
    const n = Number(v);
    if (!Number.isFinite(n)) return '';
    return String(Math.round(n * 10) / 10);
}

/** What a stat is, in a line under its name. */
function statSub(s) {
    const bits = [];
    const hud = s.hud || {};
    if (s.readOnly) bits.push('Follows developer mode');
    else if (!s.hud) bits.push('No gauge on the HUD');
    else if (!s.active) bits.push('Off in Settings');
    else if (hud.showBelowFull) bits.push('On the HUD below full');
    else if (hud.showAboveZero) bits.push('On the HUD above 0');
    if (s.type === 'vital' && s.max === 200) bits.push('empty on the HUD at 100');
    if (s.owner && s.owner !== 'whip_core') bits.push(s.owner);
    const line = bits.join(' · ');
    return line.charAt(0).toUpperCase() + line.slice(1);
}

function renderStats(u) {
    els.statsWrap.innerHTML = '';
    const rows = Array.isArray(u.stats) ? u.stats : [];
    if (rows.length === 0) {
        els.statsWrap.appendChild(WP.empty('No stats yet: their character is still loading'));
        return;
    }
    const skin = hudSkinClass();
    for (const s of rows) {
        const row = WP.el('div', 'pmg-stat' + (s.active || s.readOnly ? '' : ' pmg-stat-off'));
        row.dataset.stat = s.name;

        const host = WP.el('div', 'sh-copy' + (skin ? ' ' + skin : ''));
        const g = hudGauge(Object.assign({ icon: '' }, s.hud || {}, { name: s.name, type: s.type, max: s.max }));
        host.appendChild(g.el);
        g.set(s.value);
        row.appendChild(host);

        const text = WP.el('div', 'pmg-stat-text');
        text.appendChild(WP.el('span', 'pmg-stat-name', statLabel(s.name)));
        const sub = statSub(s);
        if (sub) text.appendChild(WP.el('span', 'pmg-stat-sub', sub));
        row.appendChild(text);

        // The value in a field with the stat's top after it ("162 / 200"); the developer mark's is read, not typed.
        const typed = statDrafts.get(s.name);
        if (s.readOnly) {
            row.appendChild(WP.el('span', 'pmg-stat-read', statText(s.value) + ' / ' + statText(s.max)));
            row.appendChild(WP.el('span'));
        } else {
            const field = WP.el('label', 'wp-field');
            const input = WP.input({ value: typed !== undefined ? typed : statText(s.value), inputAction: 'pmgStatType', enterAction: 'pmgStatApply' });
            input.inputMode = 'decimal';
            input.dataset.stat = s.name;
            input.setAttribute('aria-label', statLabel(s.name));
            field.appendChild(input);
            field.appendChild(WP.el('span', 'wp-field-hint', '/ ' + statText(s.max)));
            row.appendChild(field);
            const apply = WP.btn('Apply', 'pmgStatApply', typed !== undefined ? 'primary' : null);
            apply.dataset.stat = s.name;
            apply.disabled = typed === undefined;
            row.appendChild(apply);
        }
        els.statsWrap.appendChild(row);
    }
    // What they are in, under the stats (the old Current State's last line).
    const v = u.currentVehicle;
    els.statsWrap.appendChild(WP.el('div', 'pmg-stats-foot', v ? 'In a vehicle, plate ' + String(v.plate || '').trim() : 'On foot'));
}

/** The row of a stat's box or Apply. */
function statRow(name) {
    return els.statsWrap.querySelector('.pmg-stat[data-stat="' + CSS.escape(name) + '"]');
}

/** A typed value's row: Apply lit (the white pill) while it differs from what they have, and any error gone. */
function statTyped(input) {
    const name = input.dataset.stat;
    const row = statRow(name);
    const s = detail && (detail.stats || []).find((x) => x.name === name);
    if (!row || !s) return;
    const changed = input.value.trim() !== statText(s.value);
    if (changed) statDrafts.set(name, input.value); else statDrafts.delete(name);
    const apply = row.querySelector('.wp-btn');
    apply.disabled = !changed;
    apply.classList.toggle('wp-btn-primary', changed);
    statError(row, null);
}

/** Why a typed value was not sent, under its row; null clears it. */
function statError(row, msg) {
    const field = row.querySelector('.wp-field');
    if (field) field.classList.toggle('wp-field-err', !!msg);
    let m = row.nextElementSibling;
    if (!(m && m.classList.contains('pmg-stat-msg'))) m = null;
    if (!msg) { if (m) m.remove(); return; }
    if (!m) {
        m = WP.el('div', 'wp-field-msg pmg-stat-msg');
        row.insertAdjacentElement('afterend', m);
    }
    m.textContent = msg;
}

function applyStat(name) {
    const row = statRow(name);
    const s = detail && (detail.stats || []).find((x) => x.name === name);
    if (!row || !s || s.readOnly || !detail.online) return;
    const input = row.querySelector('input');
    const raw = input.value.trim();
    const n = Number(raw);
    if (raw === '' || !Number.isFinite(n)) { statError(row, 'Type a number, like ' + statText(s.max) + '.'); input.focus(); return; }
    if (n < s.min || n > s.max) { statError(row, 'Between ' + statText(s.min) + ' and ' + statText(s.max) + '.'); input.focus(); return; }
    statDrafts.delete(name);
    row.querySelector('.wp-btn').disabled = true;
    nuiCallback('plmSetStat', { targetSource: detail.source, stat: name, value: n });
}

// ---- detail ----

function infoRow(grid, label, value, mono) {
    grid.appendChild(WP.el('div', 'wp-info-label', label));
    const v = WP.el('div', 'wp-info-value' + (mono ? ' wp-info-value-mono' : ''), value);
    if (mono && value && value !== 'N/A') {
        // Click-to-copy, same affordance the old identifier rows had.
        v.dataset.action = 'pmgCopy';
        v.dataset.value = value;
        v.title = 'Click to copy';
        v.style.cursor = 'pointer';
    }
    grid.appendChild(v);
}

// ---- Vehicles ----

// The card's way on: to the car's page.
const GO_GLYPH = STROKE + '<path d="M9.5 6.5 15 12l-5.5 5.5"/></svg>';

/** One of their cars: its picture with its state over it, its name, its plate (and whose, when the account has
 *  several characters), its garage and its fuel. A button that opens it on the Vehicles page, when this admin may
 *  open that page. */
function vehicleCard(veh, owner, open) {
    const card = WP.el(open ? 'button' : 'div', 'pmg-car');
    if (open) {
        card.type = 'button';
        card.dataset.action = 'pmgVehicle';
        card.dataset.id = veh.vehicleId;
    }
    card.title = veh.model || '';
    card.appendChild(vehiclePortrait(veh.model));
    const st = vehicleStatus(veh);
    card.appendChild(WP.el('span', 'wp-pill pmg-car-state' + (st.tone ? ' wp-pill-' + st.tone : ''), st.text));

    const body = WP.el('span', 'pmg-car-body');
    const head = WP.el('span', 'pmg-car-head');
    head.appendChild(WP.el('span', 'pmg-car-name', veh.display || veh.model || 'Unknown'));
    if (open) {
        const go = WP.el('span', 'pmg-car-go');
        go.innerHTML = GO_GLYPH;
        head.appendChild(go);
    }
    body.appendChild(head);
    const sub = WP.el('span', 'pmg-car-sub');
    sub.appendChild(WP.el('span', 'pmg-car-plate', String(veh.plate || '').trim() || 'No plate'));
    if (owner) sub.appendChild(document.createTextNode('  ·  ' + owner));
    body.appendChild(sub);

    const glyph = (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
    const facts = WP.el('span', 'pmg-car-facts');
    const fact = (icon, text) => {
        const f = WP.el('span', 'pmg-car-fact');
        if (icon) f.insertAdjacentHTML('beforeend', icon);
        f.appendChild(WP.el('span', 'pmg-car-fact-text', text));
        facts.appendChild(f);
    };
    fact(glyph.garage, veh.garageName || veh.garage || 'No garage');
    const fuel = veh.fuel != null ? Number(veh.fuel) : NaN;
    if (Number.isFinite(fuel)) fact(glyph.fuel, Math.round(fuel) + '%');
    body.appendChild(facts);
    card.appendChild(body);
    return card;
}

function makeTable(parent, headers) {
    const t = WP.el('table', 'wp-table');
    const thead = WP.el('thead');
    const tr = WP.el('tr');
    for (const h of headers) tr.appendChild(WP.el('th', null, h));
    thead.appendChild(tr);
    t.appendChild(thead);
    const tbody = WP.el('tbody');
    t.appendChild(tbody);
    parent.appendChild(t);
    return tbody;
}

function td(text, cls) {
    return WP.el('td', cls || null, text);
}

// ---- activity log ----

let actRows = [];   // the page currently shown, newest first; feeds Older's beforeId

function renderActivity(rows, append) {
    if (!els.actWrap) return;
    if (!append) els.actWrap.innerHTML = '';
    if (!rows.length && !append) {
        els.actWrap.appendChild(WP.empty('No recorded activity'));
        els.actOlder.style.display = 'none';
        return;
    }
    for (const r of rows) els.actWrap.appendChild(buildLogRow(r, { showWho: true }));
    els.actOlder.style.display = rows.length >= 30 ? '' : 'none';
    if (rows.length) actRows = rows;
}

// A NOTE DELETED A MOMENT AGO keeps its row, as "Note deleted" with Undo, and only goes to the server when the
// time is up: { [noteId]: timer }. A pane drawn again meanwhile (a server push) still shows the Undo.
const noteDeletes = new Map();
const NOTE_UNDO_MS = 5000;

function deleteNoteSoon(noteId) {
    if (noteDeletes.has(noteId)) return;
    const userId = selectedUserId;
    noteDeletes.set(noteId, setTimeout(() => {
        noteDeletes.delete(noteId);
        nuiCallback('plmDeleteNote', { noteId, userId });
    }, NOTE_UNDO_MS));
}

// Notes picked, deleted together from the bar over them (each still offers Undo, as one deleted alone).
const notePicks = WP.picks({ id: 'pmg-notes', one: 'note', many: 'notes',
    actions: [{ label: (n) => 'Delete ' + n + (n === 1 ? ' note' : ' notes'), action: 'pmgNotesDelete', kind: 'danger' }] });

function renderNotes(notes) {
    els.notesWrap.innerHTML = '';
    notePicks.keep(notes.filter((n) => !noteDeletes.has(Number(n.noteId))).map((n) => n.noteId));
    if (notes.length === 0) {
        els.notesWrap.appendChild(WP.empty('No notes'));
        return;
    }
    if (notes.length > 1) els.notesWrap.appendChild(notePicks.bar());
    for (const note of notes) {
        const row = WP.el('div', 'wp-feed-row');
        if (noteDeletes.has(Number(note.noteId))) {
            row.appendChild(WP.el('span', 'wp-info-label', 'Note deleted'));
            row.appendChild(WP.el('span', 'wp-actions-split'));
            const undo = WP.btn('Undo', 'pmgNoteUndo', 'sm');
            undo.dataset.id = note.noteId;
            row.appendChild(undo);
        } else {
            if (notes.length > 1) row.appendChild(notePicks.box(note.noteId));
            row.appendChild(WP.el('span', 'wp-info-label', note.createdByName || 'Unknown'));
            row.appendChild(WP.el('span', 'wp-info-value-mono', dateTime(note.createdAt, 'N/A')));
            row.appendChild(WP.el('span', null, note.note || ''));
            row.appendChild(WP.el('span', 'wp-actions-split'));
            const del = WP.btn('', 'pmgNoteDelete', 'ghost wp-btn-sm');
            del.innerHTML = uiIcon('close');
            del.dataset.id = note.noteId;
            del.setAttribute('aria-label', 'Delete this note');
            row.appendChild(del);
        }
        els.notesWrap.appendChild(row);
    }
}

// ---- a picture of their game ----
//
// Opening an online player's page takes a picture of their game (server/devtools.lua pmShot: what they see, whip's
// interface over the game), shown beside their name; Capture Player's Game takes another. The page keeps it for
// SHOT_KEEP_MS: their page opened again in that time (from another tab, or the panel closed and opened again) shows
// it without asking their game, and then it goes. While one is on its way, whip's logo runs its loading light in the
// picture's place (logo-light.js).
//
// Kept by server id, with the account it was taken for: a server id another player gets later never shows theirs.

const SHOT_KEEP_MS = 5 * 60 * 1000;
const SHOT_WAIT_MS = 45000;     // the server gives their game 30 s; the page stops waiting after this
const SHOT_SETTLE_MS = 400;     // a page open this long asks: going down the list does not picture everyone passed
const shots = new Map();        // [server id] = { src, userId, data, at }
const shotAsks = new Map();     // [server id] = { userId, at }: asked, no answer yet
const shotFails = new Map();    // [server id] = { userId, why, at }: why the last ask brought no picture
let shotSettle = null;          // the wait before a page's own ask
let shotShown = null;           // the picture in the preview: it stays there past SHOT_KEEP_MS while the page is open
let shotLight = null;           // the logo's light in the preview (built with it)

/** Ask for a picture of this player's game. `fresh`: even with one kept. */
function askShot(u, fresh) {
    const src = u && u.online ? sessionOf(u) : 0;
    if (!src || shotAsks.has(src)) return;
    const kept = shots.get(src);
    if (!fresh && kept && kept.userId === u.userId) return;
    const ask = { userId: u.userId, at: Date.now() };
    shotAsks.set(src, ask);
    shotFails.delete(src);
    nuiCallback('plmShot', { targetSource: src });
    // No answer at all (the ask was refused before it reached their game): stop waiting.
    setTimeout(() => {
        if (shotAsks.get(src) !== ask) return;
        shotAsks.delete(src);
        shotFails.set(src, { userId: ask.userId, why: 'no picture came back', at: Date.now() });
        if (detail && sessionOf(detail) === src) renderShot();
    }, SHOT_WAIT_MS);
    renderShot();
}

/** A page opened: its kept picture, or an ask once the page has been open a moment. */
function shotForPage() {
    clearTimeout(shotSettle);
    shotSettle = null;
    shotShown = null;
    els.shotImg.removeAttribute('src');
    const u = detail;
    const kept = u && u.online ? shots.get(sessionOf(u)) : null;
    if (u && u.online && !(kept && kept.userId === u.userId)) {
        shotSettle = setTimeout(() => {
            shotSettle = null;
            if (detail && detail.userId === u.userId && sessionOf(detail) === sessionOf(u)) askShot(detail, false);
            renderShot();
        }, SHOT_SETTLE_MS);
    }
    renderShot();
}

/** What came back for an ask (tools/panel_sections/playerManager.lua): the picture, or why not. */
function takeShot(p) {
    const src = Number(p && p.source) || 0;
    const ask = shotAsks.get(src);
    if (!ask) return;   // not asked from here, or given up on
    shotAsks.delete(src);
    const at = Date.now();
    if (typeof p.data === 'string' && p.data.startsWith('data:image/')) {
        const kept = { src, userId: ask.userId, data: p.data, at };
        shots.set(src, kept);
        setTimeout(() => { if (shots.get(src) === kept) shots.delete(src); }, SHOT_KEEP_MS);
    } else {
        shotFails.set(src, { userId: ask.userId, why: p.why || 'the picture failed', at });
    }
    if (detail && sessionOf(detail) === src && detail.userId === ask.userId) {
        renderShot();
        if (p.pos) showPlace(detail, p.pos, at);   // where they stood for it: newer than the page's
    }
}

/** The preview: on its way (the logo's light), the picture, or why there is none. Online pages only. */
function renderShot() {
    const u = detail;
    const src = u && u.online ? sessionOf(u) : 0;
    els.views.style.display = src ? '' : 'none';   // the picture and the map: online pages only
    const mine = (x) => !!x && !!u && x.userId === u.userId;
    let state = 'none';
    let pic = null, fail = null;
    if (src) {
        pic = shots.get(src);
        fail = shotFails.get(src);
        if (mine(shotAsks.get(src)) || (shotSettle && !mine(pic))) state = 'waiting';
        else if (mine(fail) && !(mine(pic) && pic.at > fail.at)) state = 'failed';
        else if (mine(pic)) state = 'pic';
        else if (shotShown && shotShown.src === src && mine(shotShown)) { pic = shotShown; state = 'pic'; }
    }
    els.shotBox.classList.toggle('waiting', state === 'waiting');
    els.shotBox.classList.toggle('has-pic', state === 'pic');
    els.shotBox.classList.toggle('no-pic', state === 'failed' || state === 'none');
    if (state === 'pic' && shotShown !== pic) {
        shotShown = pic;
        els.shotImg.src = pic.data;
    }
    els.shotMsg.textContent = state === 'failed' ? 'No picture: ' + fail.why : 'No picture yet';
    els.shotWhen.textContent = state === 'pic' ? 'Taken at ' + timeOfDay(pic.at)
        : state === 'waiting' ? 'Taking a picture…' : '';
    els.btnShot.disabled = state === 'waiting';
    if (state === 'waiting') shotLight.start(); else shotLight.stop();
}

/** The preview beside their name, with Capture Player's Game under it. */
function buildShot() {
    els.shotCol = WP.el('div', 'pmg-shot-col');
    els.shotBox = WP.el('div', 'pmg-shot');
    els.shotImg = WP.el('img', 'pmg-shot-img');
    els.shotImg.alt = 'Their game';
    els.shotImg.draggable = false;
    els.shotBox.appendChild(els.shotImg);
    const logo = WP.el('div', 'pmg-shot-logo');
    logo.innerHTML = logoMarkup('pmg-shot-clip');   // fixed markup, no data
    els.shotBox.appendChild(logo);
    if (shotLight) shotLight.stop();
    shotLight = logoLight(logo);
    els.shotMsg = WP.el('div', 'pmg-shot-msg');
    els.shotBox.appendChild(els.shotMsg);
    els.shotCol.appendChild(els.shotBox);
    const row = WP.el('div', 'pmg-shot-row');
    els.btnShot = WP.btn('Capture Player\'s Game', 'pmgShot', 'sm');
    row.appendChild(els.btnShot);
    els.shotWhen = WP.el('span', 'pmg-shot-when');
    row.appendChild(els.shotWhen);
    els.shotCol.appendChild(row);
    return els.shotCol;
}

// ---- where they are, on the map beside the picture ----
//
// whip's map (WP.place) with their mark, where their page says they stand, or where they stood when a newer picture
// came back: whichever came last. A move of a few metres keeps the map as it is and only says the new time.

let placeShown = null;          // { userId, src, x, y } on the map now

/** Their place on the map at `at` (ms); none (no position, offline) hides it. */
function showPlace(u, pos, at) {
    const src = u && u.online ? sessionOf(u) : 0;
    const ok = !!src && !!pos && Number.isFinite(pos.x) && Number.isFinite(pos.y);
    els.placeCol.style.display = ok ? '' : 'none';
    if (!ok) {
        els.placeSlot.innerHTML = '';
        placeShown = null;
        return;
    }
    const same = placeShown && placeShown.userId === u.userId && placeShown.src === src
        && Math.hypot(placeShown.x - pos.x, placeShown.y - pos.y) < 3;
    if (!same) {
        els.placeSlot.innerHTML = '';
        els.placeSlot.appendChild(WP.place({ x: pos.x, y: pos.y, name: u.name || 'The player' }));
        placeShown = { userId: u.userId, src, x: pos.x, y: pos.y };
    }
    els.placeWhen.textContent = 'Position at ' + timeOfDay(at);
}

/** The map beside the picture, the same size, with when the position is from under it. */
function buildPlace() {
    els.placeCol = WP.el('div', 'pmg-place-col');
    els.placeSlot = WP.el('div', 'pmg-place');
    els.placeCol.appendChild(els.placeSlot);
    const row = WP.el('div', 'pmg-shot-row');
    els.placeWhen = WP.el('span', 'pmg-shot-when');
    row.appendChild(els.placeWhen);
    els.placeCol.appendChild(row);
    return els.placeCol;
}

function renderDetail() {
    renderShot();
    if (!detail) {
        els.detailBody.style.display = 'none';
        els.detailEmpty.style.display = '';
        els.detailEmpty.textContent = selectedUserId !== null
            ? 'Loading…' : 'Select a player to view details';
        return;
    }
    els.detailEmpty.style.display = 'none';
    els.detailBody.style.display = '';

    const u = detail;

    // -- header: their face, their name (wp-pane-title — the pane's lead voice, like every other
    // section; wp-title belongs to the shell header), and the status pills on a line of their own
    // under it, wrapping: beside the name they squeezed it out and ran under the picture --
    els.headRow.innerHTML = '';
    // Their face: the character they are playing, else the one played last (server/portraits.lua).
    const when = (v) => toMs(v) || 0;
    const chars0 = (u.characters || []).slice().sort((a, b) => when(b.lastPlayed) - when(a.lastPlayed));
    const faceId = (u.online && u.currentCharId) || (chars0[0] && chars0[0].charId);
    const faceChar = (u.characters || []).find((c) => c.charId === faceId);
    els.headRow.appendChild(presence(faceChar ? (faceChar.firstName || '') + ' ' + (faceChar.lastName || '') : u.name, u.online, faceId, true));
    els.headRow.appendChild(WP.el('span', 'wp-pane-title', u.name || 'Unknown'));
    const pills = WP.el('div', 'pmg-pills');
    els.headRow.appendChild(pills);
    if (u.online) {
        pills.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ONLINE'));
        if (u.source) pills.appendChild(WP.el('span', 'wp-pill wp-pill-accent', '#' + u.source));
        // The account's other characters in at the same time (Config.PlayerManagerSessionWarn): each a
        // pill that opens that session.
        for (const s of (u.warnSessions ? u.otherSessions || [] : [])) {
            const pill = WP.el('span', 'wp-pill wp-pill-warn', 'ALSO IN: ' + (s.name || 'a character') + ' #' + s.source);
            pill.title = 'The same account has this character in too. Click to see that session.';
            pill.dataset.action = 'pmgSelect';
            pill.dataset.id = u.userId;
            pill.dataset.session = s.source;
            pill.style.cursor = 'pointer';
            pills.appendChild(pill);
        }
    } else {
        pills.appendChild(WP.el('span', 'wp-pill', 'OFFLINE'));
    }
    // From their ban rows: the page's payload has no count (the list's rows do).
    const banned = (u.bans || []).some(banHolds);
    if (banned) pills.appendChild(WP.el('span', 'wp-pill wp-pill-err', 'BANNED'));
    if (u.devtools === 'permanent') pills.appendChild(WP.el('span', 'wp-pill wp-pill-accent', 'ADMIN'));
    if (u.devtools === 'temporary') {
        const pill = WP.el('span', 'wp-pill wp-pill-warn', 'TEMP ADMIN');
        pill.title = 'Dev tools until the server restarts' + (u.devtoolsBy ? ', given by ' + u.devtoolsBy : '');
        pills.appendChild(pill);
    }

    // -- actions: each card says what it does to them; the online-only ones say Offline, faded --
    const online = !!u.online;
    const say = (b, text) => { b._sub.textContent = text; };
    els.btnTeleport.disabled = !online;
    say(els.btnTeleport, online ? 'Go to them, #' + u.source : 'Offline');
    els.btnBring.disabled = !online;
    say(els.btnBring, online ? 'Pull them to you' : 'Offline');
    const invChars = u.characters || [];
    els.btnInventory.disabled = invChars.length === 0;
    say(els.btnInventory, invChars.length === 0 ? 'No characters'
        : invChars.length === 1 ? ((invChars[0].firstName || '') + ' ' + (invChars[0].lastName || '')).trim()
        : 'Pick one of ' + invChars.length + ' characters');
    els.btnUnban.style.display = banned ? '' : 'none';
    say(els.btnUnban, 'Lift every ban on them');
    // Only a permanent admin sees it (the server says so), and never on another permanent admin.
    els.btnDevtools.style.display = u.canGiveDevtools && u.devtools !== 'permanent' ? '' : 'none';
    els.btnDevtools._name.textContent = u.devtools === 'temporary' ? 'Take Dev Tools' : 'Give Dev Tools';
    say(els.btnDevtools, u.devtools === 'temporary' ? 'Take /whip back now' : 'Until the server restarts');
    els.btnKick.disabled = !online;
    say(els.btnKick, online ? 'Drop them, with a reason' : 'Offline');
    say(els.btnTempBan, 'Out for a set time');
    say(els.btnPermaBan, 'Out until someone unbans them');

    // -- Identifiers --
    els.identGrid.innerHTML = '';
    infoRow(els.identGrid, 'License', u.license || 'N/A', true);
    infoRow(els.identGrid, 'Steam', u.steam || 'N/A', true);
    infoRow(els.identGrid, 'Discord', u.discord || 'N/A', true);
    infoRow(els.identGrid, 'FiveM', u.fivem || 'N/A', true);
    infoRow(els.identGrid, 'Created', dateTime(u.createdAt, 'N/A'));
    infoRow(els.identGrid, 'Last Seen', dateTime(u.lastSeen, 'N/A'));

    // -- Characters --
    els.charsWrap.innerHTML = '';
    const chars = u.characters || [];
    if (chars.length === 0) {
        els.charsWrap.appendChild(WP.empty('No characters'));
    } else {
        const tbody = makeTable(els.charsWrap, ['Name', 'ID', 'DOB', 'Cash', 'Last Played', '']);
        for (const c of chars) {
            const tr = WP.el('tr');
            const nameCell = td('');
            const who = WP.el('span', 'pmg-char');
            who.appendChild(avatar((c.firstName || '') + ' ' + (c.lastName || ''), undefined, c.charId));
            who.appendChild(document.createTextNode((c.firstName || '') + ' ' + (c.lastName || '')));
            nameCell.appendChild(who);
            if (u.online && u.currentCharId && c.charId === u.currentCharId) {
                nameCell.appendChild(document.createTextNode(' '));
                nameCell.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ACTIVE'));
            } else if (otherSessionOf(u, c.charId)) {
                // In on the account's other session at the same time.
                nameCell.appendChild(document.createTextNode(' '));
                nameCell.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ACTIVE #' + otherSessionOf(u, c.charId)));
            }
            tr.appendChild(nameCell);
            tr.appendChild(td('#' + c.charId, 'wp-td-mono'));
            tr.appendChild(td(c.dob || ''));
            tr.appendChild(td(money(c.cash), 'wp-td-num'));
            tr.appendChild(td(c.lastPlayed ? ago(c.lastPlayed) : ''));
            // Rename: the name only; the character ID (and all they own) stays.
            const act = WP.el('td');
            const rb = WP.btn('Rename', 'pmgRename', 'ghost wp-btn-sm');
            rb.dataset.id = c.charId;
            act.appendChild(rb);
            tr.appendChild(act);
            tbody.appendChild(tr);
        }
    }

    // -- Current Stats (online only: stats live in their game session; the whole group hides offline) --
    els.statsGroup.style.display = u.online ? '' : 'none';
    if (u.online) renderStats(u);
    // Where they are: on the map beside the picture (online only).
    showPlace(u, u.online ? u.position : null, Date.now());

    // -- Vehicles: a card each --
    els.vehWrap.innerHTML = '';
    const vehicles = u.vehicles || [];
    if (vehicles.length === 0) {
        els.vehWrap.appendChild(WP.empty('No vehicles'));
    } else {
        // Whose it is only says something when the account has more than one character.
        const chars = u.characters || [];
        const owners = {};
        if (chars.length > 1) for (const c of chars) owners[c.charId] = ((c.firstName || '') + ' ' + (c.lastName || '')).trim();
        const open = WhipPanel.canOpen('vehicles');
        for (const veh of vehicles) els.vehWrap.appendChild(vehicleCard(veh, owners[veh.ownerCharId], open));
    }

    // -- Jobs --
    els.jobsWrap.innerHTML = '';
    const jobs = u.jobs || [];
    if (jobs.length === 0) {
        els.jobsWrap.appendChild(WP.empty('No employment'));
    } else {
        const tbody = makeTable(els.jobsWrap, ['Job', 'Role', 'Level']);
        for (const job of jobs) {
            const tr = WP.el('tr');
            tr.appendChild(td(job.jobName || ''));
            tr.appendChild(td(job.roleName || ''));
            tr.appendChild(td('Lv ' + (job.roleLevel || 0), 'wp-td-num'));
            tbody.appendChild(tr);
        }
    }

    // -- Permissions: every one a resource declared (RegisterPermission), Give or Take for this account --
    els.permsWrap.innerHTML = '';
    const perms = u.permissions || [];
    if (perms.length === 0) {
        els.permsWrap.appendChild(WP.empty('No resource has declared a permission'));
    } else {
        const tbody = makeTable(els.permsWrap, ['Permission', 'From', 'Holds', '']);
        for (const p of perms) {
            const tr = WP.el('tr');
            const nameCell = td(p.label || p.name);
            nameCell.title = (p.description ? p.description + '\n' : '') + p.name;
            tr.appendChild(nameCell);
            tr.appendChild(td(p.owner || ''));
            const held = WP.el('td');
            held.appendChild(WP.el('span', 'wp-pill ' + (p.held ? 'wp-pill-ok' : ''), p.held ? 'YES' : 'NO'));
            tr.appendChild(held);
            const act = WP.el('td');
            const b = WP.btn(p.held ? 'Take' : 'Give', 'pmgPermission', 'sm');
            b.dataset.name = p.name;
            b.dataset.on = p.held ? '0' : '1';
            act.appendChild(b);
            tr.appendChild(act);
            tbody.appendChild(tr);
        }
    }

    // -- Ban History --
    els.bansWrap.innerHTML = '';
    const bans = u.bans || [];
    if (bans.length === 0) {
        els.bansWrap.appendChild(WP.empty('No bans'));
    } else {
        const tbody = makeTable(els.bansWrap, ['Status', 'Date', 'Reason', 'By', 'Expiry', '']);
        for (const ban of bans) {
            const tr = WP.el('tr');
            const statusCell = WP.el('td');
            statusCell.appendChild(WP.el('span',
                'wp-pill ' + (ban.active ? 'wp-pill-err' : ''), ban.active ? 'ACTIVE' : 'EXPIRED'));
            tr.appendChild(statusCell);
            tr.appendChild(td(dateTime(ban.bannedAt, 'N/A')));   // the bans table's column
            const reasonCell = td(ban.reason || 'No reason');
            reasonCell.title = ban.reason || '';
            tr.appendChild(reasonCell);
            tr.appendChild(td(ban.bannedByName || 'System'));
            let expiry;
            if (!ban.active && ban.unbannedByName) {
                expiry = 'Unbanned by ' + ban.unbannedByName + ' on ' + dateTime(ban.unbannedAt, 'N/A');
            } else if (!ban.duration && !ban.expiresAt) {
                expiry = 'Permanent';
            } else if (ban.expiresAt) {
                expiry = fmtExpiry(ban.expiresAt);
            } else {
                expiry = fmtDuration(ban.duration);
            }
            tr.appendChild(td(expiry));
            const actCell = WP.el('td');
            if (ban.active && ban.banId) {
                const b = WP.btn('Unban', 'pmgUnban', 'sm');
                b.dataset.id = ban.banId;
                actCell.appendChild(b);
            }
            tr.appendChild(actCell);
            tbody.appendChild(tr);
        }
    }

    renderNotes(u.notes || []);
}

// ---- click-to-copy (ported; the .plm-copied flash becomes a text swap) ----

// SAYS WHETHER IT COPIED (utils.js's copyToClipboard the same): the async clipboard first; refused, the
// execCommand path, whose answer counts.
function copyFallback(val) {
    const ta = document.createElement('textarea');
    ta.value = val;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy') === true; } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
}

function copyValue(el) {
    const val = el.dataset.value;
    if (!val || val === 'N/A') return;
    const say = (ok) => {
        el.textContent = ok ? 'Copied' : 'Could not copy';
        setTimeout(() => { el.textContent = el.dataset.value; }, ok ? 800 : 1500);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(val).then(() => say(true)).catch(() => say(copyFallback(val)));
    } else {
        say(copyFallback(val));
    }
}

// ---- data adoption ----

function adoptUsers(list) {
    users = list || [];
    renderList();
    // A selection that survived the refresh gets its detail re-fetched (the old
    // plmRefresh behavior — the pane could be showing stale bans/notes otherwise).
    // The same session if it is still in; the server falls back to the account's other one, or to it
    // offline, when it is not.
    if (selectedUserId !== null && detail) {
        for (const u of users) {
            if (u.userId === selectedUserId) {
                nuiCallback('plmSelectUser', { userId: selectedUserId, session: selectedSession });
                break;
            }
        }
    }
}

// ONLY THE USER BEING LOOKED AT, AND A REFRESH IS NOT A NEW PAGE. The server pushes a detail after an
// action on user A even when the admin has moved on to B, so a detail for someone else is dropped. A
// refresh (a player dropping anywhere re-fetches the selected user) must not wipe a half-typed kick
// reason, ban or note: the form closes only when the page changes to a different user.
function showDetail(d) {
    if (!d) return false;
    if (selectedUserId !== null && d.userId !== selectedUserId) return false;
    // Another session of the same account is another page too.
    const sameUser = detail !== null && detail.userId === d.userId && sessionOf(detail) === sessionOf(d);
    detail = d;
    selectedUserId = d.userId;
    selectedSession = sessionOf(d);
    if (!sameUser) {
        setInlineForm(null);   // the old plmShowDetail dropped any open dialog
        statDrafts.clear();
    }
    renderList();
    renderDetail();
    if (!sameUser) shotForPage();
    return true;
}

// ---- form builders (built once; display-toggled by setInlineForm) ----

function buildActionForms(kickParent, charParent) {
    // Kick: reason + confirm (the old kick dialog), living inside the Actions group
    // with the button that opens it. Enter submits — the admin's hands are on the
    // keyboard the moment they finish typing the reason.
    els.kickForm = WP.el('div');
    els.kickForm.style.display = 'none';
    els.kickReason = WP.input({ placeholder: 'Reason for kick…', enterAction: 'pmgKickConfirm' });
    els.kickForm.appendChild(WP.field('Kick reason', els.kickReason, true));
    let row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    els.kickGo = WP.btn('Kick', 'pmgKickConfirm', 'danger');
    row.appendChild(els.kickGo);
    els.kickForm.appendChild(row);
    kickParent.appendChild(els.kickForm);

    // Character picker: which character's inventory (the old selectchar dialog) —
    // under the top verb row, beside Open Inventory itself.
    els.charForm = WP.el('div');
    els.charForm.style.display = 'none';
    els.charForm.appendChild(WP.el('div', 'wp-section-title', 'Open whose inventory?'));
    els.charList = WP.el('div', 'wp-toggles');   // a wrapping row of their characters, one button each
    els.charForm.appendChild(els.charList);
    row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    els.charForm.appendChild(row);
    charParent.appendChild(els.charForm);
}

function buildBanForms(parent) {
    // Temp ban: reason + ONE duration field. Three number boxes (days/hours/min) cost
    // three tab stops for the most common values; "3d 12h 30m" is one field and reads
    // the way admins already say it. A bare number means days.
    els.tempbanForm = WP.el('div');
    els.tempbanForm.style.display = 'none';
    els.tempbanReason = WP.input({ placeholder: 'Reason for ban…' });
    els.tempbanForm.appendChild(WP.field('Ban reason', els.tempbanReason, true));
    els.tempbanDuration = WP.input({
        placeholder: 'e.g. 3d 12h 30m, or just 7 for a week',
        enterAction: 'pmgTempBanConfirm',
    });
    els.tempbanForm.appendChild(WP.field('Duration', els.tempbanDuration, true));
    let row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    els.tempbanGo = WP.btn('Temp Ban', 'pmgTempBanConfirm', 'danger');
    row.appendChild(els.tempbanGo);
    els.tempbanForm.appendChild(row);
    parent.appendChild(els.tempbanForm);

    // Perma ban: warning + reason (the old permaban dialog). setInlineForm names the player in both.
    els.permaForm = WP.el('div');
    els.permaForm.style.display = 'none';
    els.permaWarn = WP.el('div', 'wp-dialog-body');
    els.permaForm.appendChild(els.permaWarn);
    els.permaReason = WP.input({ placeholder: 'Reason for permanent ban…', enterAction: 'pmgPermaBanConfirm' });
    els.permaForm.appendChild(WP.field('Ban reason', els.permaReason, true));
    row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    els.permaGo = WP.btn('Permanent Ban', 'pmgPermaBanConfirm', 'danger');
    row.appendChild(els.permaGo);
    els.permaForm.appendChild(row);
    parent.appendChild(els.permaForm);
}

/** '3d 12h 30m' → {days, hours, minutes}; a bare number is days; null when nothing parses. */
function parseDuration(raw) {
    const s = (raw || '').trim().toLowerCase();
    if (!s) return null;
    if (/^\d+$/.test(s)) return { days: parseInt(s, 10), hours: 0, minutes: 0 };
    const d = /(\d+)\s*d/.exec(s), h = /(\d+)\s*h/.exec(s), m = /(\d+)\s*m/.exec(s);
    if (!d && !h && !m) return null;
    return {
        days: d ? parseInt(d[1], 10) : 0,
        hours: h ? parseInt(h[1], 10) : 0,
        minutes: m ? parseInt(m[1], 10) : 0,
    };
}

function buildRenameForm(parent) {
    // Rename a character (Josh, 1 Nov): first and last name, under their Characters table. The name only: whip knows
    // a character by its ID, which stays, with everything they own.
    els.renameForm = WP.el('div');
    els.renameForm.style.display = 'none';
    els.renameTitle = WP.el('div', 'wp-section-title', 'Rename');
    els.renameForm.appendChild(els.renameTitle);
    els.renameFirst = WP.input({ placeholder: 'First name', enterAction: 'pmgRenameConfirm' });
    els.renameForm.appendChild(WP.field('First name', els.renameFirst, true));
    els.renameLast = WP.input({ placeholder: 'Last name', enterAction: 'pmgRenameConfirm' });
    els.renameForm.appendChild(WP.field('Last name', els.renameLast, true));
    els.renameForm.appendChild(WP.el('div', 'wp-hint',
        'Only the name changes. The character ID stays, and so does everything they own: money, items, cars, property, '
        + 'phone, bank and jobs. A note on the account records it.'));
    const row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    row.appendChild(WP.btn('Save Name', 'pmgRenameConfirm', 'primary'));
    els.renameForm.appendChild(row);
    parent.appendChild(els.renameForm);
}

function buildNoteForm(parent) {
    // Add note (the old note dialog).
    els.noteForm = WP.el('div');
    els.noteForm.style.display = 'none';
    els.noteText = WP.input({ placeholder: 'Type your note…', enterAction: 'pmgNoteConfirm' });
    els.noteForm.appendChild(WP.field('Note', els.noteText, true));
    const row = WP.el('div', 'wp-dialog-actions');
    row.appendChild(WP.btn('Cancel', 'pmgFormCancel', 'ghost'));
    row.appendChild(WP.btn('Save Note', 'pmgNoteConfirm', 'primary'));
    els.noteForm.appendChild(row);
    parent.appendChild(els.noteForm);
}

// ---- section ----

WhipPanel.registerSection({
    id: 'playerManager',
    group: 'players',
    label: 'Player Manager',
    order: 10,

    render(root) {
        els = {};

        // -- toolbar: filter pills + search (the old plm-filter-btn row) --
        els.filterBtns = {
            all: WP.btn('All', 'pmgFilter', null, 'all'),
            online: WP.btn('Online', 'pmgFilter', null, 'online'),
            banned: WP.btn('Banned', 'pmgFilter', null, 'banned'),
        };
        els.filterBtns[filter].classList.add('wp-btn-primary');
        root.appendChild(WP.toolbar({
            left: [els.filterBtns.all, els.filterBtns.online, els.filterBtns.banned],
            search: { inputAction: 'pmgSearch', placeholder: 'Search name, license, character…', id: 'wp-pmg-search' },
        }));
        els.search = root.querySelector('#wp-pmg-search');

        const split = WP.el('div', 'wp-split');

        // -- list column --
        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        // -- detail pane --
        const pane = WP.el('div', 'wp-detail');
        els.detailEmpty = WP.empty('Select a player to view details');
        pane.appendChild(els.detailEmpty);

        els.detailBody = WP.el('div');
        els.detailBody.style.display = 'none';

        // -- The head: their name, and beside it a picture of their game and their place on the map.
        const head = WP.el('div', 'pmg-head');
        const headMain = WP.el('div', 'pmg-head-main');
        head.appendChild(headMain);
        els.headRow = WP.el('div', 'pmg-who');
        headMain.appendChild(els.headRow);
        els.views = WP.el('div', 'pmg-views');   // the picture and the map, side by side
        els.views.appendChild(buildShot());
        els.views.appendChild(buildPlace());
        head.appendChild(els.views);
        els.detailBody.appendChild(head);

        // -- Every verb is in the Actions group, closed: a card each (verb), the everyday ones on the left, the ones
        // that remove a player (kick, bans) on the right. Their forms open under the cards.
        const gActions = WP.group('actions', 'Actions', false);
        els.actionsGroup = gActions.root;   // setInlineForm opens it when a form in it shows
        const glyph = (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
        const verbs = WP.el('div', 'pmg-verbs');
        const reach = WP.el('div', 'pmg-verb-set');
        els.btnTeleport = verb(glyph.pin, 'Teleport To', 'pmgTeleport');
        els.btnBring = verb(VERB_GLYPHS.bring, 'Bring Here', 'pmgBring');
        els.btnInventory = verb(glyph.bag, 'Open Inventory', 'pmgInventory');
        els.btnUnban = verb(glyph.unlock, 'Unban', 'pmgUnbanActive');
        els.btnDevtools = verb(glyph.devtools, 'Give Dev Tools', 'pmgDevtools');
        for (const b of [els.btnTeleport, els.btnBring, els.btnInventory, els.btnUnban, els.btnDevtools]) reach.appendChild(b);
        verbs.appendChild(reach);
        const remove = WP.el('div', 'pmg-verb-set pmg-verb-remove');
        els.btnKick = verb(VERB_GLYPHS.kick, 'Kick', 'pmgKick', true);
        els.btnTempBan = verb(glyph.timer, 'Temp Ban', 'pmgTempBan', true);
        els.btnPermaBan = verb(VERB_GLYPHS.ban, 'Perma Ban', 'pmgPermaBan', true);
        for (const b of [els.btnKick, els.btnTempBan, els.btnPermaBan]) remove.appendChild(b);
        verbs.appendChild(remove);
        gActions.body.appendChild(verbs);

        // The forms: the Open Inventory character picker, then Kick's and the bans'.
        const charFormWrap = WP.el('div');
        gActions.body.appendChild(charFormWrap);
        const kickFormWrap = WP.el('div');
        gActions.body.appendChild(kickFormWrap);
        els.detailBody.appendChild(gActions.root);

        buildActionForms(kickFormWrap, charFormWrap);
        buildBanForms(kickFormWrap);       // under Kick, Temp Ban and Perma Ban: where they were pressed

        // -- the old eight detail sections, as collapsible groups — ALL closed by
        // default, like the Actions group above: the head (pills, picture, map) is the
        // at-a-glance layer, and the admin opens exactly the drawer they came for --
        const gIdent = WP.group('identifiers', 'Identifiers', false);
        els.identGrid = WP.el('div', 'wp-info-grid');
        gIdent.body.appendChild(els.identGrid);
        els.detailBody.appendChild(gIdent.root);

        const gChars = WP.group('characters', 'Characters', false);
        els.charsGroup = gChars.root;
        els.charsWrap = WP.el('div');
        gChars.body.appendChild(els.charsWrap);
        buildRenameForm(gChars.body);
        els.detailBody.appendChild(gChars.root);

        const gStats = WP.group('stats', 'Current Stats', false);
        els.statsGroup = gStats.root;
        els.statsWrap = WP.el('div', 'pmg-stats');
        gStats.body.appendChild(els.statsWrap);
        els.detailBody.appendChild(gStats.root);

        const gVehicles = WP.group('vehicles', 'Vehicles', false);
        els.vehWrap = WP.el('div', 'pmg-cars');
        gVehicles.body.appendChild(els.vehWrap);
        els.detailBody.appendChild(gVehicles.root);

        const gJobs = WP.group('jobs', 'Jobs', false);
        els.jobsWrap = WP.el('div');
        gJobs.body.appendChild(els.jobsWrap);
        els.detailBody.appendChild(gJobs.root);

        // The permissions resources declare (a seller's staff role): given to the account, kept across restarts.
        const gPerms = WP.group('permissions', 'Permissions', false);
        els.permsWrap = WP.el('div');
        gPerms.body.appendChild(els.permsWrap);
        els.detailBody.appendChild(gPerms.root);

        const gBans = WP.group('bans', 'Ban History', false);
        els.bansWrap = WP.el('div');
        gBans.body.appendChild(els.bansWrap);
        els.detailBody.appendChild(gBans.root);

        const gNotes = WP.group('notes', 'Admin Notes', false);
        els.notesGroup = gNotes.root;
        const noteBar = WP.el('div', 'wp-dialog-actions');
        noteBar.appendChild(WP.btn('Add Note', 'pmgNote', 'sm'));
        gNotes.body.appendChild(noteBar);
        buildNoteForm(gNotes.body);
        els.notesWrap = WP.el('div', 'wp-feed');
        gNotes.body.appendChild(els.notesWrap);
        els.detailBody.appendChild(gNotes.root);

        // The activity log: what this user's characters DID — logins, moves, gives,
        // uses, deaths — with every identified item clickable through to its own
        // timeline in the Item Log section. Loaded on select, paged with Older.
        const gActivity = WP.group('activity', 'Activity', false);
        els.actWrap = WP.el('div', 'wp-feed');
        gActivity.body.appendChild(els.actWrap);
        const actRow = WP.el('div', 'wp-actions-row');
        actRow.appendChild(WP.btn('Refresh', 'pmgActRefresh', 'sm'));
        els.actOlder = WP.btn('Older', 'pmgActOlder', 'sm');
        actRow.appendChild(els.actOlder);
        gActivity.body.appendChild(actRow);
        els.detailBody.appendChild(gActivity.root);

        pane.appendChild(els.detailBody);
        split.appendChild(pane);
        root.appendChild(split);

        renderList();
        renderDetail();
    },

    onEnter() {
        // View reset only — matches the old openPlayerManager reset; Lua fetches 'all'.
        selectedUserId = null;
        selectedSession = 0;
        detail = null;
        inlineForm = null;
        search = '';
        els.search.value = '';
        setFilter('all');
        setInlineForm(null);
        renderDetail();
    },

    onLeave() {
        // A page left before its ask went out asks nothing; one already asked still lands (kept for when it opens).
        clearTimeout(shotSettle);
        shotSettle = null;
        if (shotLight) shotLight.stop();
    },

    /** Opened on one player ({ userId }: the object viewer's Open in WHIP Admin Menu): their page. */
    onFocus(f) {
        const id = Number(f && f.userId);
        if (id > 0) selectUser(id, 0);
    },

    onData(kind, payload) {
        if (kind === 'all' || kind === 'refresh') {
            adoptUsers(payload.users);
        } else if (kind === 'detail') {
            if (!showDetail(payload)) return;   // someone else's: the admin has moved on
            // Fetch the fresh page of this user's activity alongside the detail.
            actRows = [];
            if (els.actWrap) {
                els.actWrap.innerHTML = '';
                els.actWrap.appendChild(WP.empty('Loading…'));
            }
            nuiCallback('alPlayer', { userId: payload.userId, beforeId: 0 });
        } else if (kind === 'activity') {
            renderActivity(payload.rows || [], !!payload.more);
        } else if (kind === 'shot') {
            takeShot(payload);
        }
    },

    onEscape() {
        // Stage 1 (an open WP.confirm) is the shell's. Stage 2 here: an open inline
        // form backs out first, then a selection deselects, then the panel may close.
        if (inlineForm) { setInlineForm(null); return true; }
        if (selectedUserId !== null) { deselect(); return true; }
        return false;
    },

    actions: {
        pmgSearch: (el) => { search = el.value; renderList(); },
        pmgFilter: (el) => setFilter(el.dataset.arg),
        pmgSelect: (el) => selectUser(Number(el.dataset.id), Number(el.dataset.session) || 0),
        pmgCopy: (el) => copyValue(el),
        // A car's card: its page on the Vehicles tab.
        pmgVehicle: (el) => WhipPanel.switchTo('vehicles', { vehicleId: Number(el.dataset.id) }),

        // ---- activity log ----
        pmgActRefresh: () => {
            if (!detail) return;
            actRows = [];
            nuiCallback('alPlayer', { userId: detail.userId, beforeId: 0 });
        },
        pmgActOlder: () => {
            if (!detail || !actRows.length) return;
            const oldest = actRows[actRows.length - 1];
            nuiCallback('alPlayer', { userId: detail.userId, beforeId: oldest.id });
        },
        // Item tokens rendered by buildLogRow dispatch here (the active section owns
        // the action map) and hop to the Item Log section.
        ilOpen: (el) => openItemTimeline(el.dataset.uid),
        alTp: (el) => confirmTeleport(el),

        pmgShot: () => {
            if (detail && detail.online) askShot(detail, true);
        },

        // ---- Current Stats ----
        pmgStatType: (el) => statTyped(el),
        pmgStatApply: (el) => applyStat(el.dataset.stat),

        pmgTeleport: () => {
            if (!detail || !detail.online) return;
            nuiCallback('plmTeleportTo', { targetSource: detail.source });
        },
        pmgBring: () => {
            if (!detail || !detail.online) return;
            nuiCallback('plmBringPlayer', { targetSource: detail.source });
        },
        pmgInventory: () => {
            // One character goes straight through; several open the picker (old selectchar).
            // Lua closes the shell before the inventory handoff — nothing to do here.
            if (!detail) return;
            const chars = detail.characters || [];
            if (chars.length === 0) return;
            if (chars.length === 1) {
                nuiCallback('plmOpenInventory', { charId: chars[0].charId });
                return;
            }
            setInlineForm('selectchar');
        },
        pmgPickChar: (el) => {
            setInlineForm(null);
            nuiCallback('plmOpenInventory', { charId: Number(el.dataset.id) });
        },

        pmgKick: () => {
            if (!detail || !detail.online) return;
            setInlineForm('kick');
        },
        pmgKickConfirm: () => {
            if (!detail || !detail.online) return;
            const reason = els.kickReason.value.trim();
            if (!reason) { WP.fieldError(els.kickReason, 'Write why. They see it as they are dropped, and it goes in their notes.'); return; }
            nuiCallback('plmKick', { targetSource: detail.source, reason });
            setInlineForm(null);
        },

        pmgTempBan: () => {
            if (!detail) return;
            setInlineForm('tempban');
        },
        pmgTempBanConfirm: () => {
            if (!detail) return;
            if (!els.tempbanReason.value.trim()) {
                WP.fieldError(els.tempbanReason, 'Write why. They see it as they are dropped, and it is kept in their ban history.');
                return;
            }
            const dur = parseDuration(els.tempbanDuration.value);
            // Old rule preserved: no zero-length bans — but now the refusal is visible
            // instead of a button that silently eats the click.
            if (!dur) {
                WP.fieldError(els.tempbanDuration, 'Enter a duration, like "3d 12h" or "7" for days.');
                return;
            }
            if (dur.days === 0 && dur.hours === 0 && dur.minutes === 0) {
                WP.fieldError(els.tempbanDuration, 'Duration can\'t be zero.');
                return;
            }
            nuiCallback('plmBan', {
                userId: detail.userId, reason: els.tempbanReason.value.trim(),
                days: dur.days, hours: dur.hours, minutes: dur.minutes,
            });
            setInlineForm(null);
        },

        pmgPermaBan: () => {
            if (!detail) return;
            setInlineForm('permaban');
        },
        pmgPermaBanConfirm: () => {
            if (!detail) return;
            const reason = els.permaReason.value.trim();
            if (!reason) { WP.fieldError(els.permaReason, 'Write why. They see it as they are dropped, and it is kept in their ban history.'); return; }
            nuiCallback('plmBan', { userId: detail.userId, reason, permanent: true });
            setInlineForm(null);
        },

        // A permission's Give / Take: for the account, saved; the pane comes back with it changed.
        pmgPermission: async (el) => {
            if (!detail) return;
            const on = el.dataset.on === '1';
            if (!on) {
                const ok = await WP.confirm({
                    title: 'Take this permission?',
                    body: (detail.name || 'This player') + ' loses ' + el.dataset.name + ' on every character, now.',
                    confirmLabel: 'Take it',
                });
                if (!ok) return;
            }
            nuiCallback('plmPermission', { userId: detail.userId, name: el.dataset.name, on });
        },

        // Per-ban Unban button (has a real banId). Bare confirm — the one old dialog
        // with no inputs, so WP.confirm carries it.
        pmgUnban: async (el) => {
            if (!detail) return;
            const banId = Number(el.dataset.id);
            const who = detail.name || 'this player';
            const ok = await WP.confirm({
                title: 'Lift this ban?',
                body: 'This ban on ' + who + ' ends now. Another ban still running keeps them out.',
                confirmLabel: 'Lift it',
            });
            if (!ok) return;
            nuiCallback('plmUnban', { banId: banId, userId: detail.userId });
        },
        // The Unban card (shown while a ban holds, banHolds). banId 0 + the userId means "lift every
        // active ban for this user" server-side (pmUnban).
        pmgUnbanActive: async () => {
            if (!detail) return;
            const who = detail.name || 'this player';
            const ok = await WP.confirm({
                title: 'Unban ' + who + '?',
                body: 'Every ban on ' + who + ' ends now, and they can join again.',
                confirmLabel: 'Unban',
            });
            if (!ok) return;
            nuiCallback('plmUnban', { banId: 0, userId: detail.userId });
        },

        // Dev tools until the server restarts. The pane comes back from the server either way.
        pmgDevtools: async () => {
            if (!detail || !detail.canGiveDevtools) return;
            const userId = detail.userId;
            const give = detail.devtools !== 'temporary';
            const name = detail.name || 'This player';
            const ok = await WP.confirm(give ? {
                title: 'Give dev tools?',
                body: name + ' gets /whip and every dev tool until the server restarts.',
                confirmLabel: 'Give',
            } : {
                title: 'Take dev tools?',
                body: name + ' loses /whip and every dev tool now.',
                confirmLabel: 'Take',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('plmDevtools', { userId: userId, give: give });
        },

        pmgRename: (el) => {
            if (!detail) return;
            renameCharId = Number(el.dataset.id);
            setInlineForm('rename');
        },
        pmgRenameConfirm: () => {
            if (!detail || renameCharId === null) return;
            const first = els.renameFirst.value.trim(), last = els.renameLast.value.trim();
            // The server's rule (Character.cleanNames): letters, spaces and hyphens, two letters at least, 30 at most.
            const letters = (s) => (s.match(/[A-Za-z]/g) || []).length;
            if (letters(first) < 2) { WP.fieldError(els.renameFirst, 'At least two letters.'); return; }
            if (letters(last) < 2) { WP.fieldError(els.renameLast, 'At least two letters.'); return; }
            if (first.length > 30) { WP.fieldError(els.renameFirst, '30 characters at most.'); return; }
            if (last.length > 30) { WP.fieldError(els.renameLast, '30 characters at most.'); return; }
            nuiCallback('plmRenameChar', { charId: renameCharId, firstName: first, lastName: last });
            setInlineForm(null);
        },

        pmgNote: () => {
            if (!detail) return;
            setInlineForm('note');
        },
        pmgNoteConfirm: () => {
            if (!detail) return;
            const note = els.noteText.value.trim();
            if (!note) { WP.fieldError(els.noteText, 'Write the note first.'); return; }
            nuiCallback('plmAddNote', { userId: detail.userId, note: note });
            setInlineForm(null);
        },
        pmgNoteDelete: (el) => {
            deleteNoteSoon(Number(el.dataset.id));
            if (detail) renderNotes(detail.notes || []);
        },
        pmgNotesDelete: () => {
            for (const id of notePicks.keys()) deleteNoteSoon(Number(id));
            notePicks.clear();
            if (detail) renderNotes(detail.notes || []);
        },
        pmgNoteUndo: (el) => {
            const noteId = Number(el.dataset.id);
            clearTimeout(noteDeletes.get(noteId));
            noteDeletes.delete(noteId);
            if (detail) renderNotes(detail.notes || []);
        },
    },
});
