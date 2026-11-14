// ========================================
// /whip SECTION — Phones
//
// THE HOUSE LOOK, the shape the job, shop and container pages share:
//
//   the list     each number with its owner's face (their portrait, the online light on it), the number, a
//                LOCKED tag when its owner locked its SIM, and who owns it. All / Online / Locked, and one
//                search that matches the number, the name or the character id.
//   its page     the owner's face, large, beside the number as the title, with Online / Offline and Locked;
//                then what it is, row by row — Number (Change: a field under it, Save or Cancel), Owner, SIM,
//                Since, and what it holds (contacts, messages, calls, blocks: pmDetail) — and the owner's other
//                numbers. Destructive far-left, the rest far-right: Delete number, then Give me its SIM card.
//   no number    a word on what the page is for, and Give a character a number (the server's pmAssignNumber,
//                which the old page never offered): find them by name, and they have one.
//   its records  Open phone records: the number's dashboard (phoneRecords.js) takes the whole section, list
//                and all, until Back or Escape brings the number's page back.
//
// The nuiCallbacks: pmEditNumber, pmDeleteNumber, pmSpawnSim — by NUMBER (a character may own several,
// whip_phone's SIM cards); pmAssignNumber and pmDetail
// are tools/panel_sections/phones.lua's too.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback } from '../utils.js';
import { avatar, personSearch } from './pickers.js';
import { PhoneRecords } from './phoneRecords.js';
import { plural, date, phoneNumber } from './format.js';

let entries = [];           // server order preserved
let selected = null;        // the selected NUMBER; null = nothing selected
let search = '';
let filter = 'all';         // all | online | locked
let changing = false;       // the Number row's field is open
let assigning = false;      // Give a character a number is open (nothing selected)
let pendingCharId = null;   // a character just given a number: their new one opens once the list has it
let pendingNumber = null;   // a number just changed to: its page opens once the list has it (a refusal leaves it)
let holds = {};             // number -> { contacts, messages, calls, blocks } | 'loading'
let recordsOpen = false;    // a number's records (the dashboard) cover the section
let els = {};

// ---- helpers ----

function fullName(e) {
    return ((e.firstName || '') + ' ' + (e.lastName || '')).trim() || 'Unknown';
}

function findEntry(number) {
    for (const e of entries) { if (e.phoneNumber === number) return e; }
    return null;
}

/** A face with the online light on it, the light said in words (the Players page's). */
function presence(e, large) {
    const a = avatar(fullName(e), !!e.online, e.charId, large);
    const dot = a.querySelector('.wp-dot');
    if (dot) dot.title = e.online ? 'Online' : 'Offline';
    return a;
}

// ---- the list ----

function filteredEntries() {
    const q = search;
    return entries.filter((e) => {
        if (filter === 'online' && !e.online) return false;
        if (filter === 'locked' && !e.locked) return false;
        if (!q) return true;
        return (e.phoneNumber || '').indexOf(q.replace(/[^0-9]/g, '') || q) !== -1
            || phoneNumber(e.phoneNumber).toLowerCase().indexOf(q) !== -1
            || fullName(e).toLowerCase().indexOf(q) !== -1
            || String(e.charId).indexOf(q) !== -1;
    });
}

function renderList() {
    els.list.innerHTML = '';
    const shown = filteredEntries();
    const total = entries.length;
    els.count.textContent = (search || filter !== 'all')
        ? shown.length + ' of ' + plural(total, 'number')
        : plural(total, 'number');

    if (shown.length === 0) {
        els.list.appendChild(WP.empty(search || filter !== 'all' ? 'No numbers match' : 'No phone numbers yet'));
        return;
    }

    for (const e of shown) {
        const item = WP.el('div', 'wp-list-item wp-has-icon');
        item.dataset.id = e.phoneNumber;
        item.dataset.action = 'pmSelect';
        if (selected === e.phoneNumber) item.classList.add('active');
        item.appendChild(presence(e));

        const top = WP.el('div', 'wp-item-top');
        top.appendChild(WP.el('span', 'wp-item-title wp-info-value-mono', phoneNumber(e.phoneNumber)));
        if (e.locked) top.appendChild(WP.el('span', 'wp-pill', 'LOCKED'));   // a plain state: neutral everywhere
        item.appendChild(top);
        item.appendChild(WP.el('div', 'wp-item-sub', fullName(e) + '  ·  ' + (e.lore ? 'lore character' : '#' + e.charId)
            + (e.online ? '  ·  online' : '')));
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

// ---- a number's page ----

/** What it holds, read once per number (pmDetail), then this page again. */
function loadHolds(number) {
    if (holds[number]) return;
    holds[number] = 'loading';
    nuiCallback('pmDetail', { phoneNumber: number }).then((res) => {
        holds[number] = res && res.ok === true ? res : null;
        if (selected === number) renderDetail();
    });
}

function holdsText(h) {
    if (h === 'loading') return 'reading…';
    if (!h) return 'could not be read';
    const parts = [];
    if (h.contacts !== undefined && h.contacts !== null) parts.push(plural(h.contacts, 'contact'));
    if (h.messages !== undefined && h.messages !== null) parts.push(plural(h.messages, 'message'));
    if (h.calls !== undefined && h.calls !== null) parts.push(plural(h.calls, 'call'));
    // Both ways: the numbers it blocked and those that blocked it (whip_phone's block list, when it has one).
    if (h.blocks !== undefined && h.blocks !== null) parts.push(plural(h.blocks, 'block'));
    return parts.length ? parts.join('  ·  ') : 'nothing to read';
}

function renderIntro(body) {
    els.detailTitle.textContent = 'Phones';
    body.appendChild(WP.el('div', 'wp-hint',
        'Every phone number on the server, with whose it is. Pick one to see what it holds, change it, delete it, '
        + 'or hand yourself its SIM card. A character with no number can be given one here.'));
    if (!assigning) {
        const go = WP.el('div', 'wp-actions-row');
        go.appendChild(WP.btn('Give a character a number', 'pmAssignOpen', 'primary'));
        body.appendChild(go);
        return;
    }
    body.appendChild(WP.el('div', 'wp-section-title', 'Give a character a number'));
    body.appendChild(WP.el('div', 'wp-hint',
        'Find them by name or character id: they get a new number at once, and its page opens. Give me its SIM '
        + 'card there puts a SIM for it in your hands, to pass on. Someone who has a number already is not offered.'));
    const owners = new Set(entries.map((e) => Number(e.charId)));
    const find = personSearch({
        placeholder: 'Type a name or a character id…',
        skip: (charId) => owners.has(charId),
        onPick: (p) => {
            pendingCharId = p.charId;
            assigning = false;
            nuiCallback('pmAssignNumber', { charId: p.charId });
            renderDetail();
        },
    });
    body.appendChild(find.root);
    const row = WP.el('div', 'wp-actions-row');
    row.appendChild(WP.el('span', 'wp-actions-split'));
    row.appendChild(WP.btn('Cancel', 'pmAssignCancel', 'ghost'));
    body.appendChild(row);
    setTimeout(() => find.focus(), 0);
}

function renderDetail() {
    const body = els.detailBody;
    body.innerHTML = '';
    const e = selected !== null && findEntry(selected);
    if (!e) {
        els.detailTitle.style.display = '';
        renderIntro(body);
        return;
    }
    // The face leads the title row on a number's page (the Players page's head).
    els.detailTitle.style.display = 'none';
    loadHolds(e.phoneNumber);

    const head = WP.el('div', 'wp-item-top');
    head.appendChild(presence(e, true));
    head.appendChild(WP.el('span', 'wp-pane-title wp-info-value-mono', phoneNumber(e.phoneNumber)));
    if (e.online) {
        head.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ONLINE'));
        if (e.source) head.appendChild(WP.el('span', 'wp-pill wp-pill-accent', '#' + e.source));
    } else {
        head.appendChild(WP.el('span', 'wp-pill', 'OFFLINE'));
    }
    if (e.locked) head.appendChild(WP.el('span', 'wp-pill', 'LOCKED'));
    body.appendChild(head);
    body.appendChild(WP.el('div', 'wp-item-sub', fullName(e) + (e.lore ? '  ·  a lore character (the Director)' : '\'s  ·  character #' + e.charId)
        + '  ·  since ' + date(e.createdAt, 'not known')));

    body.appendChild(WP.el('div', 'wp-section-title', 'This number'));
    body.appendChild(WP.statusRow({ label: 'Number', status: 'ok', detail: phoneNumber(e.phoneNumber),
        action: changing ? undefined : 'pmChangeOpen', actionLabel: 'Change' }));
    if (changing) {
        // Under the row it changes: the field, then Save and Cancel at its end.
        const form = WP.el('div', 'wp-actions-row');
        els.editNumber = WP.input({ placeholder: '10 digits', enterAction: 'pmEditNumber' });
        els.editNumber.maxLength = 10;
        els.editNumber.value = e.phoneNumber || '';
        form.appendChild(WP.field('New number', els.editNumber));
        form.appendChild(WP.el('span', 'wp-actions-split'));
        form.appendChild(WP.btn('Cancel', 'pmChangeCancel', 'ghost'));
        form.appendChild(WP.btn('Save', 'pmEditNumber', 'primary'));
        body.appendChild(form);
        body.appendChild(WP.el('div', 'wp-hint',
            'Its contacts, messages, calls and blocks move to the new number, and its SIM cards take it the next time '
            + 'their phone is used. The old number is retired: it is never given out again.'));
        setTimeout(() => { if (els.editNumber) { els.editNumber.focus(); els.editNumber.select(); } }, 0);
    }
    // A lore character's number (whip_phone, the Director's lore characters): no character owns it, no SIM carries it.
    body.appendChild(e.lore
        ? WP.statusRow({ label: 'Owner', status: 'ok', detail: 'A lore character: ' + fullName(e) + '. Texts to it are kept, calls ring out.' })
        : WP.statusRow({ label: 'Owner', status: e.online ? 'ok' : 'off',
            detail: fullName(e) + '  ·  #' + e.charId + (e.online ? '  ·  online now' + (e.source ? ' (#' + e.source + ')' : '') : '  ·  offline') }));
    body.appendChild(WP.statusRow({ label: 'SIM', status: e.locked ? 'warn' : 'ok',
        detail: e.locked ? 'Locked by its owner: its SIM card works in no phone until they unlock it'
            : 'Working: its SIM card works in any phone' }));
    body.appendChild(WP.statusRow({ label: 'Since', status: 'ok', detail: date(e.createdAt, 'not known') }));
    const h = holds[e.phoneNumber];
    body.appendChild(WP.statusRow({ label: 'Holds', status: h === 'loading' ? 'todo' : h ? 'ok' : 'warn',
        detail: holdsText(h), action: 'pmRecords', actionLabel: 'Open records' }));

    // A character may own several numbers (whip_phone's SIM cards): theirs, a click away.
    const others = e.charId == null ? [] : entries.filter((o) => o.charId === e.charId && o.phoneNumber !== e.phoneNumber);
    if (others.length) {
        body.appendChild(WP.el('div', 'wp-section-title', fullName(e) + '\'s other numbers'));
        for (const o of others) {
            body.appendChild(WP.statusRow({ label: phoneNumber(o.phoneNumber), status: o.locked ? 'warn' : 'ok',
                detail: o.locked ? 'locked' : 'working', action: 'pmSelect', arg: o.phoneNumber, actionLabel: 'Open' }));
        }
    }

    // Destructive far-left, the rest far-right — Delete never neighbours the others.
    const actions = WP.el('div', 'wp-actions-row');
    actions.appendChild(WP.btn('Delete number', 'pmDelete', 'danger'));
    actions.appendChild(WP.el('span', 'wp-actions-split'));
    actions.appendChild(WP.btn('Give me its SIM card', 'pmSpawnSim'));
    actions.appendChild(WP.btn('Open phone records', 'pmRecords', 'primary'));
    body.appendChild(actions);
}

// ---- its records: the dashboard over the whole section ----

function showRecords(on) {
    recordsOpen = on;
    if (els.split) els.split.style.display = on ? 'none' : '';
    if (els.records) els.records.hidden = !on;
}

function openRecords(number) {
    selected = number;
    changing = false;
    assigning = false;
    showRecords(true);
    PhoneRecords.open(number);
}

function closeRecords() {
    // Back to the page of the number the records ended on (they may have moved to someone else's).
    const n = PhoneRecords.number();
    PhoneRecords.close();
    showRecords(false);
    if (n && findEntry(n)) selected = n;
    renderDetail();
    renderList();
}

function selectEntry(number) {
    if (selected !== number) changing = false;
    selected = number;
    assigning = false;
    renderDetail();
    renderList();
}

function clearSelection() {
    selected = null;
    changing = false;
    renderDetail();
    renderList();
}

// ---- section ----

WhipPanel.registerSection({
    id: 'phones',
    group: 'players',
    label: 'Phones',
    order: 20,

    render(root) {
        els = {};

        els.filterBtns = {
            all: WP.btn('All', 'pmFilter', null, 'all'),
            online: WP.btn('Online', 'pmFilter', null, 'online'),
            locked: WP.btn('Locked', 'pmFilter', null, 'locked'),
        };
        els.filterBtns[filter].classList.add('wp-btn-primary');
        root.appendChild(WP.toolbar({
            left: [els.filterBtns.all, els.filterBtns.online, els.filterBtns.locked],
            search: { inputAction: 'pmSearch', placeholder: 'Search numbers, names, ids…' },
        }));

        const split = WP.el('div', 'wp-split');

        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        const detail = WP.el('div', 'wp-detail');
        els.detailTitle = WP.el('div', 'wp-pane-title', 'Phones');
        detail.appendChild(els.detailTitle);
        els.detailBody = WP.el('div');
        detail.appendChild(els.detailBody);
        split.appendChild(detail);
        root.appendChild(split);
        els.split = split;

        els.records = WP.el('div', 'pr');
        root.appendChild(els.records);
        PhoneRecords.mount(els.records, { onClose: closeRecords, onEntry: findEntry });
        showRecords(recordsOpen && PhoneRecords.isOpen());

        renderList();
        renderDetail();
    },

    onData(kind, payload) {
        // 'all' (section enter snapshot) and 'refresh' (server push after a mutation) carry the same {entries}
        // shape; both keep the page open when its number is still there.
        entries = (payload && payload.entries) || [];
        if (!els.list) return;
        // A number changed or deleted: what it held is read again when it is next opened.
        holds = {};
        if (pendingCharId !== null) {
            const made = entries.find((e) => Number(e.charId) === pendingCharId);
            if (made) { pendingCharId = null; selected = made.phoneNumber; changing = false; }
        }
        // A changed number: its page follows it to the new one (the old one is gone from the list).
        if (pendingNumber !== null && findEntry(pendingNumber)) {
            selected = pendingNumber;
            pendingNumber = null;
            changing = false;
        }
        if (selected !== null && !findEntry(selected)) { selected = null; changing = false; }
        // The records' number deleted or changed meanwhile: back to the list.
        if (recordsOpen && !findEntry(PhoneRecords.number())) { PhoneRecords.close(); showRecords(false); }
        renderList();
        renderDetail();
    },

    onEscape() {
        // Drill-down: the records (their own steps back first), the open field, then the number, then the panel.
        if (recordsOpen) {
            if (!PhoneRecords.escape()) closeRecords();
            return true;
        }
        if (changing) { changing = false; renderDetail(); return true; }
        if (assigning) { assigning = false; renderDetail(); return true; }
        if (selected !== null) { clearSelection(); return true; }
        return false;
    },

    actions: {
        ...PhoneRecords.actions,
        pmRecords: () => { if (selected !== null) openRecords(selected); },
        pmSearch: (el) => { search = el.value.trim().toLowerCase(); renderList(); },
        pmFilter: (el) => setFilter(el.dataset.arg || 'all'),
        pmSelect: (el) => selectEntry(String(el.dataset.id || el.dataset.arg)),
        pmAssignOpen: () => { assigning = true; renderDetail(); },
        pmAssignCancel: () => { assigning = false; renderDetail(); },
        pmChangeOpen: () => { changing = true; renderDetail(); },
        pmChangeCancel: () => { changing = false; renderDetail(); },
        pmEditNumber: () => {
            if (selected === null || !els.editNumber) return;
            const newNumber = els.editNumber.value.replace(/[^0-9]/g, '');
            // Refuse out loud — a silent return leaves Save looking broken.
            if (newNumber.length !== 10) {
                WP.fieldError(els.editNumber, 'Enter a 10-digit number.');
                return;
            }
            if (newNumber === selected) {
                WP.fieldError(els.editNumber, 'That is its number already.');
                return;
            }
            // The page follows the number to its new one when the list comes back with it. A refusal (taken, or
            // retired) sends no list: the field stays open, and the server says why.
            pendingNumber = newNumber;
            nuiCallback('pmEditNumber', { phoneNumber: selected, newNumber: newNumber });
        },
        pmSpawnSim: () => {
            if (selected === null) return;
            nuiCallback('pmSpawnSim', { phoneNumber: selected });
        },
        pmDelete: async () => {
            if (selected === null) return;
            const e = findEntry(selected);
            const h = holds[selected];
            const what = h && h !== 'loading' ? ' Its ' + holdsText(h).replace(/ {2}· {2}/g, ', ') + ' go with it.' : ' Its contacts, messages, calls and blocks go with it.';
            const ok = await WP.confirm({
                title: 'Delete this number?',
                body: phoneNumber(selected) + (e ? ' (' + fullName(e) + '\'s)' : '') + ' will be removed.' + what
                    + ' SIM cards carrying it stop working, and the number is never given out again.',
                confirmLabel: 'Delete number',
                danger: true,
            });
            if (!ok) return;
            nuiCallback('pmDeleteNumber', { phoneNumber: selected });
        },
    },
});
