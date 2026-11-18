// ========================================
// /whip SECTION — Banks
//
// Everything that can hold a bank account down the left, with one or without: players, businesses (jobs), lore
// characters, and any account nobody holds. A row opens its dashboard: their money, what they are worth, their
// transactions, the full log. An account in it opens its own page, where it is changed and closed; New account makes one.
//
// The server half is server/bank_admin.lua, which says what counts and how it is valued; tools/panel_sections/banks.lua
// carries the asks. An ask answers here, in its promise: the data, or { ok: false, why }.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback } from '../utils.js';
import { avatar } from './pickers.js';
import { ago, date, dateTime, money, plural } from './format.js';
import { inOutChart, buildLogRow, openItemTimeline, confirmTeleport } from './itemlog.js';
import { openPlayer } from './playerManager.js';

const MAX_MONEY = 1000000000000;
const KIND_LABEL = { business: 'BUSINESS', lore: 'LORE', other: 'NO HOLDER' };
const TYPE_LABEL = { personal: 'Personal', savings: 'Savings', shared: 'Shared', business: 'Business' };
const ROLE_LABEL = { owner: 'Owner', manager: 'Manager', withdraw: 'Can withdraw', deposit: 'Can deposit', view: 'Can view' };
const ROLES = ['view', 'deposit', 'withdraw', 'manager'];
const TX_LABEL = { deposit: 'Deposit', withdraw: 'Withdrawal', transfer: 'Transfer', payment: 'Payment' };
const STATE_LABEL = { garaged: 'Garaged', out: 'Out', impounded: 'Impounded' };

let entries = [];
let totals = null;
let filter = 'all';          // 'all' | 'player' | 'business' | 'lore'
let byMoney = false;         // the list by most money, not by name
let search = '';
let sel = null;              // the open row: { kind, id }
let charId = 0;              // a player's page: one of their characters (0: all of them)
let dash = null;             // that page's data
let creating = false;        // the New account form is open
let account = null;          // an account's page: its data ({ account, access, siblings, activity })
let openAccountId = 0;       // ... and which one, while it loads
let log = null;              // the log on screen: { tab, accountId, dir, rows, more }
let els = {};

// Every ask carries a number, and an answer older than the newest for its page is dropped: the admin has moved on.
let dashAsk = 0, accountAsk = 0, logAsk = 0;

const bank = (name, data) => nuiCallback(name, data).then((res) => res || { ok: false, why: 'The server did not answer' });
const refused = (res) => !res || res.ok === false;

// ---- the list ----

function filteredEntries() {
    const needle = search.toLowerCase();
    const out = entries.filter((e) => {
        if (filter !== 'all' && e.kind !== filter) return false;
        if (!needle) return true;
        const hay = [e.name, e.license, e.characterNames, e.numbers, e.ownerName, e.key, e.bankName].join(' ').toLowerCase();
        return hay.indexOf(needle) !== -1;
    });
    const rank = { player: 0, business: 1, lore: 2, other: 3 };
    out.sort((a, b) => {
        if (byMoney && a.bank !== b.bank) return b.bank - a.bank;
        if (rank[a.kind] !== rank[b.kind]) return rank[a.kind] - rank[b.kind];
        if (!!a.online !== !!b.online) return a.online ? -1 : 1;
        return (a.name || '').localeCompare(b.name || '');
    });
    return out;
}

/** A row's second line: their money, then who they are. */
function rowSub(e) {
    const who = e.kind === 'player' ? (e.online && e.currentChar ? '#' + e.source + ' · ' + e.currentChar : (e.characterNames || 'Deleted characters'))
        : e.kind === 'business' ? (e.ownerName ? 'Owner: ' + e.ownerName : 'No owner')
        : e.kind === 'lore' ? (e.bankName || 'Lore character')
        : plural(e.accounts, 'account');
    return e.accounts > 0 ? money(e.bank) + ' · ' + who : who;
}

function renderList() {
    els.list.innerHTML = '';
    const shown = filteredEntries();
    const sum = shown.reduce((n, e) => n + (e.bank || 0), 0);
    els.count.textContent = shown.length + ' listed · ' + money(sum) + ' banked';
    if (!shown.length) {
        els.list.appendChild(WP.empty('Nothing matches'));
        return;
    }
    for (const e of shown) {
        const item = WP.el('div', 'wp-list-item wp-has-icon');
        item.dataset.action = 'bkOpen';
        item.dataset.kind = e.kind;
        item.dataset.id = e.id;
        if (sel && sel.kind === e.kind && sel.id === e.id) item.classList.add('active');
        const face = avatar(e.kind === 'player' ? (e.currentChar || e.name) : e.name, e.kind === 'player' ? !!e.online : undefined, e.faceCharId);
        const dot = face.querySelector('.wp-dot');
        if (dot) dot.title = e.online ? 'Online' : 'Offline';
        item.appendChild(face);
        const top = WP.el('div', 'wp-item-top');
        top.appendChild(WP.el('span', 'wp-item-title', e.name || 'Unknown'));
        if (KIND_LABEL[e.kind]) top.appendChild(WP.el('span', 'wp-pill', KIND_LABEL[e.kind]));
        if (e.retired) top.appendChild(WP.el('span', 'wp-pill', 'RETIRED'));
        if (!e.accounts) top.appendChild(WP.el('span', 'wp-pill wp-pill-warn', 'NO ACCOUNT'));
        item.appendChild(top);
        item.appendChild(WP.el('div', 'wp-item-sub', rowSub(e)));
        els.list.appendChild(item);
    }
}

function setFilter(next) {
    filter = next;
    for (const key of Object.keys(els.filterBtns)) els.filterBtns[key].classList.toggle('wp-btn-primary', key === filter);
    renderList();
}

// ---- opening things ----

function resetPage() {
    dash = null;
    account = null;
    openAccountId = 0;
    creating = false;
    log = null;
}

function openHolder(kind, id, keepChar) {
    sel = { kind, id: String(id) };
    if (!keepChar) charId = 0;
    resetPage();
    renderList();
    renderPane();
    els.pane.scrollTop = 0;
    loadDash();
}

function loadDash() {
    if (!sel) return;
    const ask = ++dashAsk;
    bank('bankDashboard', { kind: sel.kind, id: sel.id, charId }).then((res) => {
        if (ask !== dashAsk || !sel) return;
        if (refused(res)) {
            dash = null;
            renderPane(res ? res.why : null);
            return;
        }
        dash = res;
        if (!log) log = { tab: 'bank', accountId: 0, dir: 'all', rows: [], more: false };
        renderPane();
        if (!openAccountId) loadLog(false);
    });
}

function openAccount(accountId) {
    openAccountId = Number(accountId);
    account = null;
    creating = false;
    log = { tab: 'bank', accountId: 0, dir: 'all', rows: [], more: false };
    renderPane();
    loadAccount(true);
    els.pane.scrollTop = 0;
}

function loadAccount(withLog) {
    const ask = ++accountAsk;
    const id = openAccountId;
    bank('bankAccount', { accountId: id }).then((res) => {
        if (ask !== accountAsk || id !== openAccountId) return;
        if (refused(res)) {
            WP.result(res ? res.why : 'The server did not answer', 'err');
            closeAccount();
            return;
        }
        const first = !account;
        account = res;
        if (first) buildAccountPage(); else fillAccountPage();
        if (withLog) loadLog(false);
    });
}

function closeAccount() {
    openAccountId = 0;
    account = null;
    log = { tab: 'bank', accountId: 0, dir: 'all', rows: [], more: false };
    renderPane();
    els.pane.scrollTop = 0;
    loadDash();
}

function deselect() {
    sel = null;
    charId = 0;
    resetPage();
    renderList();
    renderPane();
}

// ---- the pane ----

/** Draw the page again, keeping which groups were open and how far down it was. */
function renderPane(why) {
    const top = els.pane.scrollTop;
    const open = new Set([...els.body.querySelectorAll('.wp-group.open')].map((g) => g.dataset.group));
    els.body.innerHTML = '';
    if (!sel) { renderOverview(); return; }
    if (openAccountId) {
        if (account) buildAccountPage();
        else els.body.appendChild(WP.empty('Loading…'));
        return;
    }
    if (!dash) {
        els.body.appendChild(WP.empty(why || 'Loading…'));
        return;
    }
    renderDash();
    for (const g of els.body.querySelectorAll('.wp-group')) {
        if (open.has(g.dataset.group)) g.classList.add('open');
    }
    els.pane.scrollTop = top;
}

function renderOverview() {
    const t = totals;
    if (!t) { els.body.appendChild(WP.empty('Loading…')); return; }
    els.body.appendChild(WP.el('div', 'wp-pane-title', 'The whole bank'));
    const stats = WP.el('div', 'wp-stats wp-after');
    stats.appendChild(WP.stat('In the bank', money(t.bank), plural(t.accounts, 'open account')));
    stats.appendChild(WP.stat('Cash on characters', money(t.cash)));
    stats.appendChild(WP.stat('Last 24 hours', money(t.movedAmount), plural(t.movedCount, 'transaction')));
    stats.appendChild(WP.stat('Frozen', String(t.frozen), t.frozen === 1 ? 'account' : 'accounts'));
    els.body.appendChild(stats);
    els.body.appendChild(WP.empty('Pick a player or a business to see their money'));
}

function holderHead() {
    const d = dash;
    const entry = entries.find((e) => e.kind === d.kind && e.id === String(d.id));
    const online = entry && entry.online;
    const row = WP.el('div', 'bk-head');
    const who = WP.el('div', 'pmg-who');
    const face = avatar(d.kind === 'player' && entry ? (entry.currentChar || d.name) : d.name, d.kind === 'player' ? !!online : undefined, entry && entry.faceCharId, true);
    const dot = face.querySelector('.wp-dot');
    if (dot) dot.title = online ? 'Online' : 'Offline';
    who.appendChild(face);
    who.appendChild(WP.el('span', 'wp-pane-title', d.name || 'Unknown'));
    const pills = WP.el('div', 'pmg-pills');
    if (d.kind === 'player') {
        pills.appendChild(WP.el('span', 'wp-pill ' + (online ? 'wp-pill-ok' : ''), online ? 'ONLINE' : 'OFFLINE'));
        if (online && entry.source) pills.appendChild(WP.el('span', 'wp-pill wp-pill-accent', '#' + entry.source));
        if (!online && d.lastSeen) pills.appendChild(WP.el('span', 'wp-pill', 'SEEN ' + ago(d.lastSeen).toUpperCase()));
    } else {
        pills.appendChild(WP.el('span', 'wp-pill', KIND_LABEL[d.kind]));
        if (d.ownerName) pills.appendChild(WP.el('span', 'wp-pill', 'OWNER: ' + d.ownerName));
        if (d.kind === 'business' && !d.ownerCharId) pills.appendChild(WP.el('span', 'wp-pill wp-pill-warn', 'NO OWNER'));
        if (d.retired) pills.appendChild(WP.el('span', 'wp-pill', 'RETIRED'));
    }
    who.appendChild(pills);
    row.appendChild(who);
    if (d.kind === 'player') row.appendChild(WP.btn('Open in Player Manager', 'bkPlayerPage', 'ghost'));
    return row;
}

function makeTable(parent, headers, numeric) {
    const t = WP.el('table', 'wp-table');
    const thead = WP.el('thead');
    const tr = WP.el('tr');
    headers.forEach((h, i) => {
        const th = WP.el('th', numeric && numeric.includes(i) ? 'wp-td-num' : null, h);
        tr.appendChild(th);
    });
    thead.appendChild(tr);
    t.appendChild(thead);
    const tbody = WP.el('tbody');
    t.appendChild(tbody);
    parent.appendChild(t);
    return tbody;
}

const td = (text, cls) => WP.el('td', cls || null, text);

// ---- a holder's dashboard ----

function renderDash() {
    const d = dash;
    const open = (d.accounts || []).filter((a) => !a.closedAt);
    const closed = (d.accounts || []).filter((a) => a.closedAt);
    const w = d.worth || {};
    const act = d.activity || {};

    els.body.appendChild(holderHead());

    if (d.characters && d.characters.length > 1) {
        const list = [{ key: '0', label: 'All characters' }].concat(d.characters.map((c) => ({
            key: String(c.charId), label: c.name + (c.gone ? ' (deleted)' : ''),
        })));
        const row = WP.toggles('bkChar', list, String(d.charId || 0));
        row.classList.add('wp-after');
        els.body.appendChild(row);
    }

    const stats = WP.el('div', 'wp-stats wp-after');
    const parts = ['Bank ' + money(w.bank)];
    if (d.kind === 'player' || w.cash) parts.push('Cash ' + money(w.cash));
    stats.appendChild(WP.stat('Total money', money((w.bank || 0) + (w.cash || 0)), parts.join(' · ')));
    const left = (w.vehicles ? w.vehicles.unpriced : 0) + (w.properties ? w.properties.unpriced : 0) + (w.items ? w.items.unpriced.length : 0);
    stats.appendChild(WP.stat('Net worth (assumed)', money(w.total),
        !w.items ? 'Its accounts: it owns nothing else'
            : left ? plural(left, 'thing') + ' with no price, counted as $0' : 'See below for how'));
    stats.appendChild(WP.stat('Transactions', (act.count || 0).toLocaleString('en-US'),
        (act.days || 30) + ' days: +' + money(act.moneyIn) + ' / −' + money(act.moneyOut)));
    els.body.appendChild(stats);

    renderAccountsList(open, closed, d);
    if (w.items) renderWorth(w);
    // Nothing to chart or list for a holder that has never had an account.
    if (open.length || closed.length) {
        renderChart(act);
        renderLogBlock(open.concat(closed));
    }
}

function accountPills(cell, a) {
    if (a.isDefault) cell.appendChild(WP.el('span', 'wp-pill wp-pill-accent', 'MAIN'));
    if (a.frozen) cell.appendChild(WP.el('span', 'wp-pill wp-pill-err', 'FROZEN'));
    if (a.closedAt) cell.appendChild(WP.el('span', 'wp-pill', 'CLOSED'));
    if (a.ownerGone) cell.appendChild(WP.el('span', 'wp-pill wp-pill-warn', 'OWNER DELETED'));
}

function renderAccountsList(open, closed, d) {
    const titleRow = WP.el('div', 'bk-title-row');
    titleRow.appendChild(WP.el('div', 'wp-section-title', 'Accounts'));
    const loreHasOne = d.kind === 'lore' && open.length > 0;
    if (!loreHasOne && !(d.kind === 'player' && !(d.characters || []).some((c) => !c.gone))) {
        titleRow.appendChild(WP.btn(d.kind === 'lore' ? 'Make Its Account' : 'New Account', d.kind === 'lore' ? 'bkMakeLore' : 'bkNew', 'primary wp-btn-sm'));
    }
    els.body.appendChild(titleRow);

    if (creating) els.body.appendChild(buildCreateForm(d));

    const wrap = WP.el('div');
    if (!open.length && !creating) {
        els.body.appendChild(WP.empty(d.kind === 'player' && d.charId ? 'This character has no bank account' : 'No bank account yet'));
    } else if (open.length) {
        const several = d.kind === 'player' && !d.charId && (d.characters || []).length > 1;
        const tbody = makeTable(wrap, several ? ['Account', 'Number', 'Type', 'Held by', 'Balance'] : ['Account', 'Number', 'Type', 'Balance'], [several ? 4 : 3]);
        for (const a of open) tbody.appendChild(accountRow(a, several));
        els.body.appendChild(wrap);
    }

    const shared = d.shared || [];
    if (shared.length) {
        const g = WP.group('shared', 'Other people\'s accounts they can use · ' + shared.length, false);
        const tbody = makeTable(g.body, ['Account', 'Number', 'Whose', 'Their access', 'Balance'], [4]);
        for (const a of shared) {
            const tr = WP.el('tr', 'wp-table-row-click');
            tr.dataset.action = 'bkAccount';
            tr.dataset.id = a.accountId;
            const name = td(a.label || 'Account');
            if (a.frozen) name.appendChild(WP.el('span', 'wp-pill wp-pill-err', 'FROZEN'));
            tr.appendChild(name);
            tr.appendChild(td(a.accountNumber, 'wp-td-mono'));
            tr.appendChild(td(a.jobName || a.ownerName || 'Nobody'));
            tr.appendChild(td(ROLE_LABEL[a.role] || a.role));
            tr.appendChild(td(money(a.balance), 'wp-td-num'));
            tbody.appendChild(tr);
        }
        els.body.appendChild(g.root);
    }

    if (closed.length) {
        const g = WP.group('closed', 'Closed accounts · ' + closed.length, false);
        const tbody = makeTable(g.body, ['Account', 'Number', 'Type', 'Closed'], []);
        for (const a of closed.slice(0, 100)) {
            const tr = WP.el('tr', 'wp-table-row-click');
            tr.dataset.action = 'bkAccount';
            tr.dataset.id = a.accountId;
            tr.appendChild(td(a.label || 'Account'));
            tr.appendChild(td(a.accountNumber, 'wp-td-mono'));
            tr.appendChild(td(TYPE_LABEL[a.type] || a.type));
            tr.appendChild(td(date(a.closedAt)));
            tbody.appendChild(tr);
        }
        if (closed.length > 100) g.body.appendChild(WP.el('div', 'wp-hint', 'The newest 100 of ' + closed.length + '. Every one of their statements is in the log.'));
        els.body.appendChild(g.root);
    }
}

function accountRow(a, several) {
    const tr = WP.el('tr', 'wp-table-row-click');
    tr.dataset.action = 'bkAccount';
    tr.dataset.id = a.accountId;
    const name = td('');
    const inner = WP.el('span', 'bk-account-name');
    inner.appendChild(WP.el('span', null, a.label || 'Account'));
    accountPills(inner, a);
    name.appendChild(inner);
    tr.appendChild(name);
    tr.appendChild(td(a.accountNumber, 'wp-td-mono'));
    tr.appendChild(td(TYPE_LABEL[a.type] || a.type));
    if (several) tr.appendChild(td(a.ownerName || ''));
    tr.appendChild(td(money(a.balance), 'wp-td-num'));
    return tr;
}

// ---- the New account form ----

let form = {};

function buildCreateForm(d) {
    form = {};
    const box = WP.el('div', 'bk-form');
    const row = WP.el('div', 'wp-actions-row');
    if (d.kind === 'player') {
        const living = (d.characters || []).filter((c) => !c.gone);
        form.owner = WP.select(living.map((c) => ({ value: c.charId, label: c.name })));
        if (d.charId && living.some((c) => c.charId === d.charId)) form.owner.value = String(d.charId);
        row.appendChild(WP.field('Held by', form.owner));
    }
    form.label = WP.input({ placeholder: d.kind === 'business' ? (d.name + ' Account') : 'Account name', enterAction: 'bkCreate' });
    form.label.maxLength = 50;
    row.appendChild(WP.field('Name', form.label));
    if (d.kind !== 'business') {
        form.type = WP.select(['personal', 'savings', 'shared'].map((t) => ({ value: t, label: TYPE_LABEL[t] })));
        row.appendChild(WP.field('Type', form.type));
    }
    box.appendChild(row);
    const row2 = WP.el('div', 'wp-actions-row');
    form.opening = WP.input({ placeholder: '0', enterAction: 'bkCreate' });
    form.opening.setAttribute('inputmode', 'numeric');
    row2.appendChild(WP.field('Starts with', form.opening));
    form.reason = WP.input({ placeholder: 'Why it starts with money', enterAction: 'bkCreate' });
    form.reason.maxLength = 120;
    row2.appendChild(WP.field('Reason', form.reason));
    box.appendChild(row2);
    const actions = WP.el('div', 'wp-dialog-actions');
    actions.appendChild(WP.btn('Cancel', 'bkNewCancel', 'ghost'));
    actions.appendChild(WP.btn('Open Account', 'bkCreate', 'primary'));
    box.appendChild(actions);
    return box;
}

/** A whole number of dollars typed in a box: the number, 0 for an empty box when `optional`, or null. */
function readMoney(input, optional) {
    const raw = (input.value || '').replace(/[$,\s]/g, '');
    if (raw === '' && optional) return 0;
    if (!/^\d+$/.test(raw)) {
        WP.fieldError(input, 'A whole number of dollars.');
        return null;
    }
    const n = Number(raw);
    if (n > MAX_MONEY) {
        WP.fieldError(input, 'That is more than the bank handles at once.');
        return null;
    }
    if (n === 0 && !optional) {
        WP.fieldError(input, 'Enter how much.');
        return null;
    }
    return n;
}

// ---- what they are worth ----

function worthGroup(key, label, count, value, fill) {
    const g = WP.group('w-' + key, label + (count !== null ? ' · ' + count : ''), false);
    g.root.querySelector('.wp-group-head').appendChild(WP.el('span', 'bk-group-value', money(value)));
    fill(g.body);
    return g.root;
}

function worthLine(label, value) {
    const row = WP.el('div', 'bk-worth-line');
    row.appendChild(WP.el('span', null, label));
    row.appendChild(WP.el('span', 'bk-group-value', money(value)));
    return row;
}

function renderWorth(w) {
    els.body.appendChild(WP.el('div', 'wp-section-title bk-title-gap', 'Net worth (assumed)'));
    els.body.appendChild(worthLine('Bank accounts', w.bank));
    if (w.cash || w.vehicles) els.body.appendChild(worthLine('Cash', w.cash));

    if (w.vehicles) {
        els.body.appendChild(worthGroup('vehicles', 'Vehicles', w.vehicles.list.length, w.vehicles.total, (body) => {
            if (!w.vehicles.list.length) { body.appendChild(WP.empty('No vehicles')); return; }
            const tbody = makeTable(body, ['Plate', 'Model', 'State', 'Worth'], [3]);
            for (const v of w.vehicles.list) {
                const tr = WP.el('tr');
                tr.appendChild(td(v.plate, 'wp-td-mono'));
                tr.appendChild(td(v.name));
                tr.appendChild(td(STATE_LABEL[v.state] || v.state));
                tr.appendChild(td(v.value ? money(v.value) : 'Nobody sells it', v.value ? 'wp-td-num' : 'wp-td-num bk-quiet'));
                tbody.appendChild(tr);
            }
        }));
    }
    if (w.properties) {
        els.body.appendChild(worthGroup('properties', 'Properties', w.properties.list.length, w.properties.total, (body) => {
            if (!w.properties.list.length) { body.appendChild(WP.empty('No properties')); return; }
            const tbody = makeTable(body, ['Property', 'Listed price'], [1]);
            for (const p of w.properties.list) {
                const tr = WP.el('tr');
                tr.appendChild(td(p.name));
                tr.appendChild(td(p.value ? money(p.value) : 'No price set', p.value ? 'wp-td-num' : 'wp-td-num bk-quiet'));
                tbody.appendChild(tr);
            }
        }));
    }
    const items = w.items;
    const itemCount = items.list.length + items.unpriced.length;
    els.body.appendChild(worthGroup('items', dash.kind === 'business' ? 'Shelf stock' : 'Items', itemCount, items.total, (body) => {
        if (!itemCount) { body.appendChild(WP.empty('Nothing held')); return; }
        if (items.list.length) {
            const tbody = makeTable(body, ['Item', 'How many', 'Average price', 'Shops', 'Worth'], [1, 2, 3, 4]);
            for (const it of items.list) {
                const tr = WP.el('tr');
                tr.appendChild(td(it.name));
                tr.appendChild(td(it.amount.toLocaleString('en-US'), 'wp-td-num'));
                tr.appendChild(td(money(it.price), 'wp-td-num'));
                tr.appendChild(td(String(it.shops), 'wp-td-num'));
                tr.appendChild(td(money(it.value), 'wp-td-num'));
                tbody.appendChild(tr);
            }
        }
        if (items.unpriced.length) {
            body.appendChild(WP.el('div', 'wp-hint wp-after', 'No shop sells these, so they count as $0: '
                + items.unpriced.map((it) => it.name + (it.amount > 1 ? ' x' + it.amount.toLocaleString('en-US') : '')).join(', ')));
        }
    }));
    if (w.businesses && w.businesses.list.length) {
        els.body.appendChild(worthGroup('businesses', 'Businesses', w.businesses.list.length, w.businesses.total, (body) => {
            const tbody = makeTable(body, ['Business', 'In its accounts', 'Shelf stock', 'Worth'], [1, 2, 3]);
            for (const b of w.businesses.list) {
                const tr = WP.el('tr', 'wp-table-row-click');
                tr.dataset.action = 'bkOpen';
                tr.dataset.kind = 'business';
                tr.dataset.id = b.jobId;
                tr.appendChild(td(b.name));
                tr.appendChild(td(money(b.bank), 'wp-td-num'));
                tr.appendChild(td(money(b.stock), 'wp-td-num'));
                tr.appendChild(td(money(b.value), 'wp-td-num'));
                tbody.appendChild(tr);
            }
        }));
    }
    const total = worthLine('Total', w.total);
    total.classList.add('bk-worth-total');
    els.body.appendChild(total);
    els.body.appendChild(WP.el('div', 'wp-hint', dash.kind === 'business'
        ? 'An estimate: its accounts, and its shelves at the average price of the shops selling each item.'
        : 'An estimate: vehicles at what the sellers ask, properties at their listed price, and items at the average price of the shops selling them, in pockets, boots and stashes.'));
}

// ---- money in and out ----

function renderChart(act, into) {
    const parent = into || els.body;
    parent.appendChild(WP.el('div', 'wp-section-title bk-title-gap', 'Money in and out, last ' + (act.days || 30) + ' days'));
    if (!(act.series || []).length) {
        parent.appendChild(WP.empty('Nothing moved in that time'));
        return;
    }
    const card = WP.el('div', 'wp-chart-card');
    const host = WP.el('div');
    card.appendChild(host);
    const idle = 'In ' + money(act.moneyIn) + '  ·  Out ' + money(act.moneyOut);
    const readout = WP.el('div', 'wp-chart-readout', idle);
    card.appendChild(readout);
    parent.appendChild(card);
    const days = [];
    for (let b = 0; b < act.days; b++) days.push({ b, in: 0, out: 0 });
    for (const s of act.series) {
        if (days[s.b]) { days[s.b].in = s.in || 0; days[s.b].out = s.out || 0; }
    }
    inOutChart(host, days, { bucket: 86400, since: act.since, count: act.days }, readout, idle,
        (e, label) => label + ':  ' + money(e.in) + ' in  ·  ' + money(e.out) + ' out');
}

// ---- the full log ----

function renderLogBlock(accounts, into) {
    const parent = into || els.body;
    parent.appendChild(WP.el('div', 'wp-section-title bk-title-gap', openAccountId ? 'Log' : 'Full log'));
    const bar = WP.el('div', 'bk-log-bar');
    if (!openAccountId && dash && dash.kind === 'player') {
        bar.appendChild(WP.toggles('bkLogTab', [{ key: 'bank', label: 'Bank' }, { key: 'cash', label: 'Cash' }], log.tab));
    }
    if (log.tab === 'bank') {
        bar.appendChild(WP.toggles('bkLogDir', [{ key: 'all', label: 'Everything' }, { key: 'in', label: 'Money in' }, { key: 'out', label: 'Money out' }], log.dir));
        if (accounts && accounts.length > 1) {
            const pick = WP.select([{ value: 0, label: 'All accounts' }].concat(accounts.map((a) => ({
                value: a.accountId, label: (a.label || 'Account') + ' · ' + a.accountNumber + (a.closedAt ? ' (closed)' : ''),
            }))), { changeAction: 'bkLogAccount' });
            pick.value = String(log.accountId || 0);
            bar.appendChild(WP.field('Account', pick));
        }
    }
    parent.appendChild(bar);
    els.logWrap = WP.el('div', log.tab === 'cash' ? 'wp-feed' : null);
    parent.appendChild(els.logWrap);
    els.logOlder = WP.btn('Older', 'bkLogOlder', 'sm');
    els.logOlder.classList.add('wp-after');
    parent.appendChild(els.logOlder);
    drawLog();
}

function drawLog() {
    if (!els.logWrap || !log) return;
    els.logWrap.innerHTML = '';
    els.logOlder.style.display = log.more ? '' : 'none';
    if (!log.rows.length) {
        els.logWrap.appendChild(WP.empty(log.loading ? 'Loading…' : 'Nothing to show'));
        return;
    }
    if (log.tab === 'cash') {
        for (const r of log.rows) els.logWrap.appendChild(buildLogRow(r, { showWho: true }));
        return;
    }
    const several = !openAccountId && dash && (dash.accounts || []).length > 1;
    const tbody = makeTable(els.logWrap, several
        ? ['When', 'Account', 'What', 'Other side', 'By', 'Amount', 'Balance after']
        : ['When', 'What', 'Other side', 'By', 'Amount', 'Balance after'], several ? [5, 6] : [4, 5]);
    for (const r of log.rows) {
        const tr = WP.el('tr');
        const when = td(ago(r.at));
        when.title = dateTime(r.at);
        tr.appendChild(when);
        if (several) {
            const acc = td(r.account || '');
            acc.title = r.number || '';
            tr.appendChild(acc);
        }
        const what = td(r.message || TX_LABEL[r.type] || r.type);
        what.title = TX_LABEL[r.type] || r.type;
        tr.appendChild(what);
        tr.appendChild(otherSide(r));
        tr.appendChild(byCell(r));
        const sign = r.dir === 'in' ? '+' : r.dir === 'out' ? '−' : '';
        tr.appendChild(td(sign + money(r.amount), 'wp-td-num' + (r.dir === 'in' ? ' bk-in' : '')));
        tr.appendChild(td(r.balance !== undefined && r.balance !== null ? money(r.balance) : '', 'wp-td-num bk-quiet'));
        tbody.appendChild(tr);
    }
}

/** Who was on the other end: a link to their page when they have one. */
function otherSide(r) {
    const cell = WP.el('td');
    if (r.dir === 'own') { cell.textContent = 'Their ' + (r.otherLabel || 'other account'); return cell; }
    const name = r.other || r.otherLabel || (r.otherNumber ? r.otherNumber : '');
    if (!name) { cell.textContent = '—'; cell.classList.add('bk-quiet'); return cell; }
    const el = WP.el('span', r.otherJobId || r.otherUserId ? 'wp-log-link' : null, name);
    if (r.otherNumber) el.title = (r.otherLabel ? r.otherLabel + ' · ' : '') + r.otherNumber;
    if (r.otherJobId) { el.dataset.action = 'bkOpen'; el.dataset.kind = 'business'; el.dataset.id = r.otherJobId; }
    else if (r.otherUserId) { el.dataset.action = 'bkOpen'; el.dataset.kind = 'player'; el.dataset.id = r.otherUserId; }
    cell.appendChild(el);
    return cell;
}

function byCell(r) {
    const cell = WP.el('td');
    if (!r.by) { cell.textContent = 'The server'; cell.classList.add('bk-quiet'); return cell; }
    const el = WP.el('span', r.byUserId ? 'wp-log-link' : null, r.by);
    if (r.byUserId) { el.dataset.action = 'bkOpen'; el.dataset.kind = 'player'; el.dataset.id = r.byUserId; }
    cell.appendChild(el);
    return cell;
}

/** Ask for the log as it now stands. `older`: the next page down. */
function loadLog(older) {
    if (!log || !sel) return;
    const ask = ++logAsk;
    const last = older && log.rows.length ? log.rows[log.rows.length - 1] : null;
    if (!older) { log.loading = true; if (!log.rows.length) drawLog(); }
    const answer = (res, more) => {
        if (ask !== logAsk || !log) return;
        log.loading = false;
        if (refused(res)) {
            WP.result(res ? res.why : 'The server did not answer', 'err');
            drawLog();
            return;
        }
        log.rows = older ? log.rows.concat(res.rows || []) : (res.rows || []);
        log.more = more(res);
        drawLog();
    };
    if (log.tab === 'cash') {
        bank('bankCashLog', { id: sel.id, charId, beforeId: last ? last.id : 0 })
            .then((res) => answer(res, (r) => (r.rows || []).length >= (r.page || 30)));
        return;
    }
    const scope = openAccountId ? { kind: 'account', id: String(openAccountId), charId: 0, accountId: 0 }
        : { kind: sel.kind, id: sel.id, charId, accountId: log.accountId || 0 };
    bank('bankLedger', Object.assign(scope, { dir: log.dir, beforeId: last ? last.txId : 0 }))
        .then((res) => answer(res, (r) => !!r.more));
}

function setLog(change) {
    Object.assign(log, change, { rows: [], more: false });
    if (openAccountId) fillAccountLog();
    else renderPane();
    loadLog(false);
}

// ---- an account's own page ----

let acc = {};   // its controls: built once per account, so a push from the server never wipes what is being typed

function buildAccountPage() {
    acc = {};
    els.body.innerHTML = '';
    const a = account.account;

    const back = WP.backBtn('Back to ' + (dash ? dash.name : 'the list'), 'bkAccountBack');
    back.classList.add('wp-log-back');
    els.body.appendChild(back);

    acc.head = WP.el('div');
    els.body.appendChild(acc.head);
    acc.stats = WP.el('div', 'wp-stats wp-after');
    els.body.appendChild(acc.stats);

    if (!a.closedAt) {
        els.body.appendChild(buildChangeGroup(a));
        els.body.appendChild(buildMoneyGroup());
        acc.accessGroup = WP.group('ac-access', 'Who can use it', true);
        acc.accessBody = WP.el('div');
        acc.accessGroup.body.appendChild(acc.accessBody);
        if (!a.jobId) acc.accessGroup.body.appendChild(buildAccessAdd());
        els.body.appendChild(acc.accessGroup.root);
    }

    acc.chart = WP.el('div');
    els.body.appendChild(acc.chart);
    acc.log = WP.el('div');
    els.body.appendChild(acc.log);

    if (!a.closedAt) {
        acc.danger = WP.el('div', 'wp-actions-row wp-apart');
        els.body.appendChild(acc.danger);
    }
    fillAccountPage();
    fillAccountLog();
}

function fillAccountPage() {
    if (!account || !acc.head) return;
    const a = account.account;
    const act = account.activity || {};

    acc.head.innerHTML = '';
    const top = WP.el('div', 'bk-head');
    const who = WP.el('div', 'pmg-who bk-who-plain');
    who.appendChild(WP.el('span', 'wp-pane-title', a.label || 'Account'));
    const pills = WP.el('div', 'pmg-pills');
    accountPills(pills, a);
    pills.appendChild(WP.el('span', 'wp-pill', (TYPE_LABEL[a.type] || a.type).toUpperCase()));
    who.appendChild(pills);
    top.appendChild(who);
    acc.head.appendChild(top);

    acc.stats.innerHTML = '';
    acc.stats.appendChild(WP.stat('Balance', money(a.balance), a.accountNumber));
    const holder = a.jobName || a.loreName || a.ownerName || 'Nobody';
    acc.stats.appendChild(WP.stat('Held by', holder, a.closedAt ? 'Closed ' + date(a.closedAt) : 'Opened ' + date(a.openedAt)));
    acc.stats.appendChild(WP.stat('Transactions', (act.count || 0).toLocaleString('en-US'),
        (act.days || 30) + ' days: +' + money(act.moneyIn) + ' / −' + money(act.moneyOut)));

    if (acc.frozenBtn) {
        acc.frozenBtn.textContent = a.frozen ? 'Unfreeze' : 'Freeze';
        acc.frozenBtn.dataset.arg = a.frozen ? '0' : '1';
    }
    if (acc.mainBtn) acc.mainBtn.style.display = !a.isDefault && a.ownerCharId && !a.jobId && a.type === 'personal' ? '' : 'none';
    if (acc.name && document.activeElement !== acc.name) acc.name.value = a.label || '';
    if (acc.typeSel && document.activeElement !== acc.typeSel) acc.typeSel.value = a.type;

    if (acc.accessBody) fillAccess(a);
    if (acc.danger) {
        acc.danger.innerHTML = '';
        const locked = a.isDefault && a.ownerCharId && !a.ownerGone;
        const del = WP.btn('Delete Account', 'bkDelete', 'danger');
        del.disabled = !!locked;
        acc.danger.appendChild(del);
        if (locked) {
            acc.danger.appendChild(WP.el('span', 'wp-hint', 'This is ' + (a.ownerName || 'their') + '\'s main account. '
                + (account.siblings.length ? 'Make another one their main first.' : 'Open them another one and make it their main first.')));
        }
    }

    acc.chart.innerHTML = '';
    renderChart(act, acc.chart);
}

function fillAccountLog() {
    acc.log.innerHTML = '';
    renderLogBlock(null, acc.log);
}

function buildChangeGroup(a) {
    const g = WP.group('ac-change', 'Change', true);
    const lore = !!a.loreName;
    if (lore) {
        g.body.appendChild(WP.el('div', 'wp-hint', 'Its name is ' + a.loreName + '\'s bank name: change it on the Lore page.'));
    } else {
        const row = WP.el('div', 'wp-actions-row');
        acc.name = WP.input({ value: a.label || '', enterAction: 'bkRename' });
        acc.name.maxLength = 50;
        row.appendChild(WP.field('Name', acc.name));
        row.appendChild(WP.btn('Save Name', 'bkRename'));
        g.body.appendChild(row);
    }
    if (a.jobId) {
        g.body.appendChild(WP.el('div', 'wp-hint', 'A business account. Its owner follows the business: change it on the Jobs page.'));
    } else if (!lore) {
        const row = WP.el('div', 'wp-actions-row');
        if (!a.isDefault) {
            acc.typeSel = WP.select(['personal', 'savings', 'shared'].map((t) => ({ value: t, label: TYPE_LABEL[t] })));
            acc.typeSel.value = a.type;
            row.appendChild(WP.field('Type', acc.typeSel));
            row.appendChild(WP.btn('Save Type', 'bkType'));
            g.body.appendChild(row);
            const ownerRow = WP.el('div', 'wp-actions-row');
            acc.owner = WP.input({ placeholder: 'Type a name or character id', enterAction: 'bkOwner' });
            WP.attachCharPicker(acc.owner);
            ownerRow.appendChild(WP.field('New owner', acc.owner));
            ownerRow.appendChild(WP.btn('Change Owner', 'bkOwner'));
            g.body.appendChild(ownerRow);
        } else {
            g.body.appendChild(WP.el('div', 'wp-hint', 'Their main account: it stays personal, and stays theirs. To change that, make another one their main first.'));
        }
    }
    const flags = WP.el('div', 'wp-actions-row');
    acc.frozenBtn = WP.btn(a.frozen ? 'Unfreeze' : 'Freeze', 'bkFreeze', null, a.frozen ? '0' : '1');
    flags.appendChild(acc.frozenBtn);
    acc.mainBtn = WP.btn('Make Their Main Account', 'bkMain');
    flags.appendChild(acc.mainBtn);
    g.body.appendChild(flags);
    return g.root;
}

function buildMoneyGroup() {
    const g = WP.group('ac-money', 'Money', true);
    const row = WP.el('div', 'wp-actions-row');
    acc.amount = WP.input({ placeholder: '0' });
    acc.amount.setAttribute('inputmode', 'numeric');
    row.appendChild(WP.field('Amount', acc.amount));
    acc.reason = WP.input({ placeholder: 'Goes on the statement' });
    acc.reason.maxLength = 120;
    row.appendChild(WP.field('Reason', acc.reason));
    g.body.appendChild(row);
    const row2 = WP.el('div', 'wp-actions-row');
    row2.appendChild(WP.btn('Add Money', 'bkMoney', 'primary', 'add'));
    row2.appendChild(WP.btn('Take Money', 'bkMoney', 'danger', 'take'));
    row2.appendChild(WP.el('span', 'wp-actions-split'));
    acc.to = WP.input({ placeholder: 'WB-123456', enterAction: 'bkMoneyMove' });
    acc.to.maxLength = 20;
    row2.appendChild(WP.field('To account', acc.to));
    row2.appendChild(WP.btn('Move Money', 'bkMoney', null, 'move'));
    g.body.appendChild(row2);
    return g.root;
}

function fillAccess(a) {
    acc.accessBody.innerHTML = '';
    const rows = account.access || [];
    if (!rows.length) {
        acc.accessBody.appendChild(WP.empty('Nobody has access'));
        return;
    }
    const tbody = makeTable(acc.accessBody, a.jobId ? ['Character', 'Access'] : ['Character', 'Access', '']);
    for (const r of rows) {
        const tr = WP.el('tr');
        const name = td((r.name || ('#' + r.charId)) + ' ');
        name.appendChild(WP.el('span', 'wp-info-value-mono', '#' + r.charId));
        if (r.gone) name.appendChild(WP.el('span', 'wp-pill wp-pill-warn', 'DELETED'));
        tr.appendChild(name);
        if (r.role === 'owner' || a.jobId) {
            tr.appendChild(td(ROLE_LABEL[r.role] || r.role));
            if (!a.jobId) tr.appendChild(td(''));
        } else {
            const cell = WP.el('td');
            const pick = WP.select(ROLES.map((role) => ({ value: role, label: ROLE_LABEL[role] })), { changeAction: 'bkRole' });
            pick.value = r.role;
            pick.dataset.char = r.charId;
            cell.appendChild(pick);
            tr.appendChild(cell);
            const act = WP.el('td');
            const rm = WP.btn('Remove', 'bkAccessRemove', 'ghost wp-btn-sm');
            rm.dataset.char = r.charId;
            rm.dataset.name = r.name || ('#' + r.charId);
            act.appendChild(rm);
            tr.appendChild(act);
        }
        tbody.appendChild(tr);
    }
}

function buildAccessAdd() {
    const row = WP.el('div', 'wp-actions-row');
    acc.addChar = WP.input({ placeholder: 'Type a name or character id', enterAction: 'bkAccessAdd' });
    WP.attachCharPicker(acc.addChar);
    row.appendChild(WP.field('Give access to', acc.addChar));
    acc.addRole = WP.select(ROLES.map((role) => ({ value: role, label: ROLE_LABEL[role] })));
    row.appendChild(WP.field('Access', acc.addRole));
    row.appendChild(WP.btn('Add', 'bkAccessAdd'));
    return row;
}

// ---- answers to the things done here ----

/** A change came back: say so, and show the page as it is now. */
function done(res, words, then) {
    if (refused(res)) {
        WP.result(res ? res.why : 'The server did not answer', 'err');
        return false;
    }
    WP.result(res.note ? words + ' ' + res.note : words, res.note ? 'warn' : 'ok');
    if (then) then();
    refreshAll();
    return true;
}

function refreshAll() {
    bank('bankDirectory').then((res) => { if (!refused(res)) adopt(res); });
    if (openAccountId) loadAccount(true);
    else if (sel) loadDash();
}

function adopt(data) {
    entries = data.entries || [];
    totals = data.totals || totals;
    renderList();
    if (!sel) renderPane();
}

function change(what, value, words, then) {
    bank('bankChange', { accountId: openAccountId, what, value }).then((res) => done(res, words, then));
}

/** The server says a balance or an account changed. Not over something being typed: that page catches up when it closes. */
function onChanged(ids) {
    bank('bankDirectory').then((res) => { if (!refused(res)) adopt(res); });
    const set = new Set((ids || []).map(Number));
    if (openAccountId) {
        // The log only when it is still on its first page: one paged back stays where it is being read.
        if (set.has(openAccountId)) loadAccount(!!log && log.rows.length <= 50);
        return;
    }
    if (!sel || !dash || creating) return;
    const mine = (dash.accounts || []).concat(dash.shared || []).some((a) => set.has(Number(a.accountId)));
    if (mine) loadDash();
}

// ---- section ----

WhipPanel.registerSection({
    id: 'banks',
    group: 'economy',
    label: 'Banks',
    order: 35,

    render(root) {
        els = {};
        els.filterBtns = {
            all: WP.btn('All', 'bkFilter', null, 'all'),
            player: WP.btn('Players', 'bkFilter', null, 'player'),
            business: WP.btn('Businesses', 'bkFilter', null, 'business'),
            lore: WP.btn('Lore', 'bkFilter', null, 'lore'),
        };
        els.filterBtns[filter].classList.add('wp-btn-primary');
        els.sort = WP.btn('Most Money', 'bkSort');
        root.appendChild(WP.toolbar({
            left: [els.filterBtns.all, els.filterBtns.player, els.filterBtns.business, els.filterBtns.lore, els.sort],
            search: { inputAction: 'bkSearch', placeholder: 'Search name, license, account number…', id: 'wp-bk-search' },
        }));
        els.search = root.querySelector('#wp-bk-search');

        const split = WP.el('div', 'wp-split');
        const listCol = WP.el('div', 'wp-list-col');
        els.count = WP.el('div', 'wp-list-count', '');
        listCol.appendChild(els.count);
        els.list = WP.el('div', 'wp-list');
        listCol.appendChild(els.list);
        split.appendChild(listCol);

        els.pane = WP.el('div', 'wp-detail');
        els.body = WP.el('div');
        els.pane.appendChild(els.body);
        split.appendChild(els.pane);
        root.appendChild(split);

        renderList();
        renderPane();
    },

    onEnter() {
        sel = null;
        charId = 0;
        resetPage();
        search = '';
        els.search.value = '';
        setFilter('all');
        renderPane();
    },

    onData(kind, payload) {
        if (kind === 'all') adopt(payload);
        else if (kind === 'changed') onChanged(payload.ids);
    },

    onEscape() {
        if (creating) { creating = false; renderPane(); return true; }
        if (openAccountId) { closeAccount(); return true; }
        if (sel) { deselect(); return true; }
        return false;
    },

    actions: {
        bkSearch: (el) => { search = el.value; renderList(); },
        bkFilter: (el) => setFilter(el.dataset.arg),
        bkSort: () => {
            byMoney = !byMoney;
            els.sort.classList.toggle('wp-btn-primary', byMoney);
            renderList();
        },
        bkOpen: (el) => openHolder(el.dataset.kind, el.dataset.id),
        bkPlayerPage: () => { if (dash && dash.userId) openPlayer(dash.userId); },
        bkChar: (el) => {
            charId = Number(el.dataset.arg) || 0;
            if (log) Object.assign(log, { accountId: 0, rows: [], more: false });
            creating = false;
            dash = null;
            renderPane();
            loadDash();
        },

        // ---- the log ----
        bkLogTab: (el) => setLog({ tab: el.dataset.arg }),
        bkLogDir: (el) => setLog({ dir: el.dataset.arg }),
        bkLogAccount: (el) => setLog({ accountId: Number(el.value) || 0 }),
        bkLogOlder: () => loadLog(true),
        ilOpen: (el) => openItemTimeline(el.dataset.uid),
        alTp: (el) => confirmTeleport(el),

        // ---- a new account ----
        bkNew: () => { creating = true; renderPane(); if (form.label) form.label.focus(); },
        bkNewCancel: () => { creating = false; renderPane(); },
        bkCreate: () => {
            if (!dash) return;
            const opening = readMoney(form.opening, true);
            if (opening === null) return;
            const reason = form.reason.value.trim();
            if (opening > 0 && !reason) { WP.fieldError(form.reason, 'Say why: it goes on the statement.'); return; }
            bank('bankCreate', {
                kind: sel.kind, id: sel.id, charId: form.owner ? Number(form.owner.value) : 0, label: form.label.value.trim(),
                accountType: dash.kind === 'business' ? 'business' : form.type.value, opening, reason,
            }).then((res) => done(res, 'Account opened.', () => { creating = false; }));
        },
        bkMakeLore: () => {
            bank('bankCreate', { kind: sel.kind, id: sel.id, charId: 0, label: '', accountType: 'personal', opening: 0, reason: '' })
                .then((res) => done(res, 'Account opened.'));
        },

        // ---- an account ----
        bkAccount: (el) => openAccount(el.dataset.id),
        bkAccountBack: () => closeAccount(),
        bkRename: () => {
            const name = acc.name.value.trim();
            if (!name) { WP.fieldError(acc.name, 'Give it a name.'); return; }
            change('label', name, 'Renamed.');
        },
        bkType: () => change('type', acc.typeSel.value, 'Type changed.'),
        bkFreeze: (el) => change('frozen', el.dataset.arg, el.dataset.arg === '1' ? 'Frozen: no money moves in or out.' : 'Unfrozen.'),
        bkMain: () => change('main', '', 'This is now their main account.'),
        bkOwner: async () => {
            const value = acc.owner.value.trim();
            if (!/^\d+$/.test(value)) { WP.fieldError(acc.owner, 'Pick a character from the list, or type their id.'); return; }
            const ok = await WP.confirm({
                title: 'Give this account to character #' + value + '?',
                body: 'They own it from now on, money and all. The old owner keeps manager access until you take it away.',
                confirmLabel: 'Change Owner',
            });
            if (ok) change('owner', value, 'Owner changed.', () => { acc.owner.value = ''; });
        },
        bkMoney: (el) => sendMoney(el.dataset.arg),
        bkMoneyMove: () => sendMoney('move'),

        bkRole: (el) => {
            bank('bankAccess', { accountId: openAccountId, charId: Number(el.dataset.char), role: el.value })
                .then((res) => done(res, 'Access changed.'));
        },
        bkAccessRemove: async (el) => {
            const ok = await WP.confirm({
                title: 'Take away ' + el.dataset.name + '\'s access?',
                body: 'They can no longer use this account.',
                confirmLabel: 'Take Away',
                danger: true,
            });
            if (!ok) return;
            bank('bankAccess', { accountId: openAccountId, charId: Number(el.dataset.char), role: 'none' })
                .then((res) => done(res, 'Access taken away.'));
        },
        bkAccessAdd: () => {
            const value = acc.addChar.value.trim();
            if (!/^\d+$/.test(value)) { WP.fieldError(acc.addChar, 'Pick a character from the list, or type their id.'); return; }
            bank('bankAccess', { accountId: openAccountId, charId: Number(value), role: acc.addRole.value })
                .then((res) => done(res, 'Access given.', () => { acc.addChar.value = ''; }));
        },
        bkDelete: () => confirmDelete(),
    },
});

function sendMoney(way) {
    const a = account && account.account;
    if (!a) return;
    const amount = readMoney(acc.amount, false);
    if (amount === null) return;
    const reason = acc.reason.value.trim();
    if (!reason) { WP.fieldError(acc.reason, 'Say why: it goes on the statement.'); return; }
    const to = acc.to.value.trim();
    if (way === 'move' && !to) { WP.fieldError(acc.to, 'Which account does it go to?'); return; }
    bank('bankMoney', { accountId: a.accountId, way, amount, reason, to }).then((res) => {
        const words = way === 'add' ? money(amount) + ' added.' : way === 'take' ? money(amount) + ' taken.' : money(amount) + ' moved to ' + to + '.';
        done(res, words, () => { acc.amount.value = ''; acc.reason.value = ''; acc.to.value = ''; });
    });
}

/** Delete: where its money goes, then the account closes. Its statements stay in the log. */
async function confirmDelete() {
    const a = account && account.account;
    if (!a) return;
    const content = WP.el('div');
    let pick = null, to = null, reason = null;
    if (a.balance > 0) {
        const options = account.siblings.map((s) => ({ value: s.accountNumber, label: 'Move to ' + (s.label || 'Account') + ' · ' + s.accountNumber }));
        options.push({ value: 'other', label: 'Move to another account…' });
        options.push({ value: 'remove', label: 'Take it out of the game' });
        pick = WP.select(options);
        content.appendChild(WP.field('Where its ' + money(a.balance) + ' goes', pick));
        to = WP.input({ placeholder: 'WB-123456' });
        to.maxLength = 20;
        const toField = WP.field('Account number', to);
        content.appendChild(toField);
        const showTo = () => { toField.style.display = pick.value === 'other' ? '' : 'none'; };
        pick.addEventListener('change', showTo);
        showTo();
        reason = WP.input({ placeholder: 'Goes on the statement' });
        reason.maxLength = 120;
        content.appendChild(WP.field('Reason', reason));
    }
    const ok = await WP.confirm({
        title: 'Delete ' + (a.label || 'this account') + '?',
        body: 'It closes and stops working, for good. Its statements stay in the log, because other accounts\' statements name it.',
        confirmLabel: 'Delete Account',
        danger: true,
        content: a.balance > 0 ? content : undefined,
        canConfirm: a.balance > 0 ? () => !!reason.value.trim() && (pick.value !== 'other' || !!to.value.trim()) : undefined,
    });
    if (!ok) return;
    const payload = { accountId: a.accountId, money: 'none', to: '', reason: reason ? reason.value.trim() : '' };
    if (a.balance > 0) {
        if (pick.value === 'remove') payload.money = 'remove';
        else {
            payload.money = 'move';
            payload.to = pick.value === 'other' ? to.value.trim() : pick.value;
        }
    }
    bank('bankClose', payload).then((res) => {
        done(res, 'Account deleted.', () => { openAccountId = 0; account = null; log = { tab: 'bank', accountId: 0, dir: 'all', rows: [], more: false }; });
    });
}
