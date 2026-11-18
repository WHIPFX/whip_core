// ========================================
// /whip SECTION — Item Log
//
// WHAT HAPPENED TO ITEMS, ON THE WHOLE SERVER. Two tabs:
//
//   Everything  what happened to items (only rows naming one: no logins, dev mode or inventory opening, which
//               the Player Manager's timeline has), newest first, new rows coming in while it is at the top.
//               On the left, what to narrow it to: one search for a person, an item or an item's id; what
//               happened (came in, went out, traded, dropped and picked up, used, moves); when; how many at
//               least. Every name, item and place in a row is a link — a person to their page in the
//               Player Manager, an item (its picture before its name) to its whole life, a place to a teleport.
//   Economy     what came into the game and what left it — today, this week, the whole log — for
//               every item; for one item (cash first) where it came from, where it went, and who
//               gained the most of it.
//
// An item's whole life opens in the Everything tab's place, with how it came to be and where it was
// last at its head (Back returns to the feed as it was). The Player Manager opens it too: a player's
// own timeline links its items here.
//
// The reads are server/activity_log.lua's (Log.feedRows, Log.economy, Log.itemInfo, Log.itemRows),
// through tools/panel_sections/itemlog.lua and playerManager.lua (alItem).
//
// buildLogRow is exported and shared with playerManager.js — the two timelines must read
// identically, and one renderer is how that stays true.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback, itemImageUrl } from '../utils.js';
import { itemTiles } from './pickers.js';
import { openPlayer } from './playerManager.js';
import { age, ago, dateTime, money } from './format.js';

// ---- shared row rendering ----

const EVENT_TEXT = {
    login:            'logged in',
    logout:           'logged out',
    inv_open:         'opened inventory',
    inv_close:        'closed inventory',
    moved:            'moved',
    organised:        'organised',
    merged:           'merged stack',
    interaction:      'activated',
    gave:             'gave',
    received:         'received',
    threw:            'threw',
    placed:           'placed',
    dropped:          'dropped',
    picked_up:        'picked up',
    used:             'used',
    destroyed:        'destroyed',
    first_seen:       'entered the economy',
    gained:           'gained',
    lost:             'lost',
    bought:           'bought',
    died:             'died',
    vehicle_enter:    'entered vehicle',
    lockpick_door:    'lockpicked',
    lockpick_fail:    'failed a lockpick',
    opened_container: 'opened container',
    bank_system:      'bank',
    bank_admin:       'bank (admin)',
};

function eventText(ev) {
    if (EVENT_TEXT[ev]) return EVENT_TEXT[ev];
    if (ev && ev.startsWith('ctx_')) return ev.slice(4).replace(/_/g, ' ');
    return ev ? ev.replace(/_/g, ' ') : '?';
}

/** A row's time: how long ago for the last day, then the day and time. */
function fmtLogTime(ts) {
    return age(ts) < 86400 ? ago(ts) : dateTime(ts);
}

function fullTime(ts) {
    const d = new Date(ts * 1000);
    const p = (n) => String(n).padStart(2, '0');
    return p(d.getDate()) + '/' + p(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

/** How many of an item, the way a person reads it: cash as dollars, the rest as a count. */
function fmtAmount(itemKey, n) {
    const v = Number(n) || 0;
    return itemKey === 'cash' ? money(v) : v.toLocaleString('en-US');
}

/** An item's picture, small, before its name in a row: utils.js's missing-picture fallback (data-item-img), as the
 *  inventory has it. The Item Log's own list of items (alSetup) gives a resource's picture before the inventory's
 *  definitions have reached this page. */
function logIcon(key) {
    const img = WP.el('img', 'wp-log-icon');
    img.alt = '';
    img.dataset.itemImg = '';
    img.dataset.itemKey = key;
    img.src = itemImageUrl(key, items[key] && items[key].img);
    return img;
}

/** One timeline row, shared by both timelines. opts.showWho prefixes the actor; opts.linkWho makes
 *  them a link to their page in the Player Manager (the rows carry userId for it). */
export function buildLogRow(r, opts) {
    const row = WP.el('div', 'wp-feed-row wp-log-row');
    const time = WP.el('span', 'wp-log-time', fmtLogTime(r.ts));
    time.title = fullTime(r.ts);
    row.appendChild(time);

    if (opts && opts.showWho) {
        const who = WP.el('span', 'wp-log-who', r.who || (r.charId ? 'char #' + r.charId : 'the server'));
        if (opts.linkWho && r.userId) {
            who.classList.add('wp-log-link');
            who.dataset.action = 'ilPlayer';
            who.dataset.id = r.userId;
            who.title = 'Open their page in the Player Manager';
        }
        row.appendChild(who);
    }

    row.appendChild(WP.el('span', null, eventText(r.event)));

    if (r.itemKey) {
        const name = r.itemName || r.itemKey;
        const label = r.itemKey === 'cash' && r.amount ? name + ' ' + fmtAmount('cash', r.amount)
            : name + (r.amount && r.amount > 1 ? ' x' + r.amount : '');
        if (r.itemUid) {
            // The clickable pivot: any item with an identity opens its own timeline.
            const tok = WP.el('span', 'wp-log-item');
            tok.appendChild(logIcon(r.itemKey));
            tok.appendChild(document.createTextNode(label));
            tok.dataset.action = 'ilOpen';
            tok.dataset.uid = r.itemUid;
            tok.title = 'Open this item’s timeline (' + r.itemUid + ')';
            row.appendChild(tok);
        } else {
            const plain = WP.el('span', 'wp-log-plain');
            plain.appendChild(logIcon(r.itemKey));
            plain.appendChild(document.createTextNode(label));
            row.appendChild(plain);
        }
    }

    // The HOST item — the duffle a stack went into, the pistol whose mag slot it was.
    // Its own clickable identity: same ilOpen hop as the moved item's token, and the
    // host's timeline contains this row too (the server matches hostUid).
    if (r.hostUid) {
        row.appendChild(WP.el('span', 'wp-log-detail', 'in'));
        const host = WP.el('span', 'wp-log-item');
        if (r.hostKey) host.appendChild(logIcon(r.hostKey));
        host.appendChild(document.createTextNode(r.hostName || r.hostKey || 'item'));
        host.dataset.action = 'ilOpen';
        host.dataset.uid = r.hostUid;
        host.title = 'Open this item’s timeline (' + r.hostUid + ')';
        row.appendChild(host);
    }

    if (r.detail) {
        row.appendChild(WP.el('span', 'wp-log-detail', r.detail));
    }

    // A row with coordinates (threw/placed/dropped) carries a clickable landing spot:
    // confirm, then teleport. Dispatches as 'alTp' through the active section's map —
    // both timeline hosts register it.
    if (typeof r.x === 'number' && typeof r.y === 'number') {
        const spot = WP.el('span', 'wp-log-item wp-log-coords',
            'x: ' + r.x.toFixed(1) + ' y: ' + r.y.toFixed(1) + ' z: ' + (r.z || 0).toFixed(1));
        spot.dataset.action = 'alTp';
        spot.dataset.x = r.x;
        spot.dataset.y = r.y;
        spot.dataset.z = r.z || 0;
        spot.title = 'Teleport to this spot';
        row.appendChild(spot);
    }
    return row;
}

/** The coords click → confirm → teleport flow, shared by both timeline sections. */
export async function confirmTeleport(el) {
    const x = Number(el.dataset.x), y = Number(el.dataset.y), z = Number(el.dataset.z);
    const ok = await WP.confirm({
        title: 'Teleport?',
        body: 'Teleport to x: ' + x.toFixed(1) + '  y: ' + y.toFixed(1) + '  z: ' + z.toFixed(1) + '?',
        confirmLabel: 'Teleport',
    });
    if (ok) nuiCallback('alTeleport', { x: x, y: y, z: z });
}

// ========================================
// STATE
// ========================================

let els = {};
let tab = 'feed';             // 'feed' | 'economy'
let entered = false;          // the section is the one on screen
let items = {};               // key -> { name, img } (alSetup)
let keepDays = 30;
let setupAsked = false;

const GROUPS = [
    { key: '', label: 'Everything' },
    { key: 'came_in', label: 'Came in' },
    { key: 'went_out', label: 'Went out' },
    { key: 'traded', label: 'Traded' },
    { key: 'ground', label: 'Dropped & picked up' },
    { key: 'used', label: 'Used' },
    { key: 'moves', label: 'Moves' },
];
const WHEN = [
    { key: 'hour', label: 'Last hour' },
    { key: 'today', label: 'Today' },
    { key: 'week', label: 'This week' },
    { key: 'all', label: 'Everything kept' },
];
// The Economy's periods: today by the hour, then by the day (whole days, from the admin's midnight).
const ECON_WHEN = [
    { key: 'today', label: 'Today', days: 1 },
    { key: 'week', label: 'Last 7 days', days: 7 },
    { key: 'all', label: 'Everything kept', days: 0 },   // 0: Config.ActivityLogDays
];

/** The item picker's groups: what moved today, in the last 7 days, in the last 30 (a log that keeps
 *  fewer days than that — Config.ActivityLogDays — answers with what it has; the server clamps). */
const MOVED = [
    { key: 'today', label: 'Moved today', days: 1 },
    { key: 'week', label: 'Moved this week', days: 7 },
    { key: 'month', label: 'Moved this month', days: 30 },
];
const movedCache = {};   // key -> { at, list }: read again after a minute

/** Which items moved in a group's period, busiest first ([{ key, n }]), or null when not read. */
function movedIn(m) {
    const hit = movedCache[m.key];
    if (hit && Date.now() - hit.at < 60000) return Promise.resolve(hit.list);
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - (m.days - 1));
    return Promise.resolve(nuiCallback('alItemActivity', { since: Math.floor(d.getTime() / 1000) })).then((res) => {
        if (!res || res.ok !== true) return null;
        // Nothing moved: Lua's empty list can arrive as {} rather than [].
        const rows = Array.isArray(res.items) ? res.items : Object.values(res.items || {});
        const list = rows.map((r) => ({ key: r.itemKey, n: Number(r.n) || 0 }));
        movedCache[m.key] = { at: Date.now(), list };
        return list;
    });
}

/** An Economy period: where it starts, how its graph is cut, and how many pieces it has. */
function econPeriod(when) {
    const w = ECON_WHEN.find((x) => x.key === when) || ECON_WHEN[0];
    const days = w.days || keepDays;
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - (days - 1));
    const since = Math.floor(d.getTime() / 1000);
    const now = Math.floor(Date.now() / 1000);
    const bucket = days === 1 ? 3600 : 86400;
    // Today is all 24 hours, the ones still to come empty, so a bar is the same width at 2am as at 11pm.
    return { since, bucket, count: days === 1 ? 24 : days, nowIndex: Math.min((days === 1 ? 24 : days) - 1, Math.floor((now - since) / bucket)) };
}

// The feed: what it is narrowed to, and what it holds.
const filter = { group: '', when: 'today', itemKey: '', charId: 0, charName: '', minAmount: '' };
let feedRows = [];            // newest first
let feedToken = 0;            // a reply for an older filter is dropped
let feedMore = false;
let feedError = '';
let pollTimer = null;
const POLL_MS = 4000;

// One item's life, when one is open.
let itemUid = null;
let itemRows = [];
let itemInfo = null;

// The Economy tab.
const econ = { when: 'today', itemKey: 'cash', data: null, error: '', token: 0 };

function sinceOf(when) {
    const now = Math.floor(Date.now() / 1000);
    if (when === 'hour') return now - 3600;
    if (when === 'today') { const d = new Date(); d.setHours(0, 0, 0, 0); return Math.floor(d.getTime() / 1000); }
    if (when === 'week') return now - 7 * 86400;
    return now - keepDays * 86400;
}

const itemName = (key) => (items[key] && items[key].name) || key;
const UID_RE = /^[0-9a-f]+-[0-9a-f]+$/i;

function askSetup() {
    if (setupAsked) return;
    setupAsked = true;
    nuiCallback('alSetup', {}).then((res) => {
        if (!res || !res.items) { setupAsked = false; return; }
        items = res.items;
        if (res.keepDays) keepDays = Number(res.keepDays) || 30;
        if (tab === 'economy' && !econ.picking) renderEconomy();
    });
}

// ========================================
// EVERYTHING: the feed
// ========================================

function feedFilter(extra) {
    const f = { since: sinceOf(filter.when) };
    if (filter.group) f.group = filter.group;
    if (filter.itemKey) f.itemKey = filter.itemKey;
    if (filter.charId) f.charId = filter.charId;
    const min = Number(filter.minAmount);
    if (Number.isInteger(min) && min > 1) f.minAmount = min;
    return Object.assign(f, extra || {});
}

function loadFeed() {
    const token = ++feedToken;
    feedRows = [];
    feedError = '';
    feedMore = false;
    renderFeed('Loading…');
    nuiCallback('alFeed', feedFilter()).then((res) => {
        if (token !== feedToken) return;
        if (!res || res.ok !== true) {
            feedError = (res && res.why) || 'The log could not be read';
            renderFeed();
            return;
        }
        feedRows = res.rows || [];
        feedMore = feedRows.length >= 50;
        renderFeed();
    });
}

function loadOlder() {
    if (!feedRows.length) return;
    const token = feedToken;
    nuiCallback('alFeed', feedFilter({ beforeId: feedRows[feedRows.length - 1].id })).then((res) => {
        if (token !== feedToken || !res || res.ok !== true) return;
        const rows = res.rows || [];
        feedRows = feedRows.concat(rows);
        feedMore = rows.length >= 50;
        for (const r of rows) els.feedList.appendChild(buildLogRow(r, { showWho: true, linkWho: true }));
        els.older.style.display = feedMore ? '' : 'none';
    });
}

/** The page is on screen, on the feed, at its newest: then the live poll runs. */
function atTheTop() {
    const overlay = document.getElementById('whip-panel-overlay');
    return entered && tab === 'feed' && !itemUid && overlay && overlay.style.display !== 'none'
        && !overlay.classList.contains('wp-suspended') && els.detail && els.detail.scrollTop < 40;
}

function poll() {
    if (!atTheTop() || feedError) return;
    const token = feedToken;
    const newest = feedRows[0];
    nuiCallback('alFeed', feedFilter(newest ? { afterId: newest.id } : {})).then((res) => {
        if (token !== feedToken || !res || res.ok !== true) return;
        const rows = res.rows || [];
        if (!rows.length) return;
        if (rows.length >= 50) { loadFeed(); return; }   // too much at once: start again from the newest
        feedRows = rows.concat(feedRows);
        const empty = els.feedList.querySelector('.wp-empty');
        if (empty) empty.remove();
        for (let i = rows.length - 1; i >= 0; i--) {
            const el = buildLogRow(rows[i], { showWho: true, linkWho: true });
            el.classList.add('wp-log-new');
            els.feedList.insertBefore(el, els.feedList.firstChild);
        }
        renderFeedHead();
    });
}

function startPoll() {
    if (pollTimer) return;
    pollTimer = setInterval(poll, POLL_MS);
}

function stopPoll() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
}

/** The feed's title says what it shows: "Cash · came in · today". */
function feedTitle() {
    const parts = [];
    if (filter.charId) parts.push(filter.charName || 'Character #' + filter.charId);
    if (filter.itemKey) parts.push(itemName(filter.itemKey));
    const g = GROUPS.find((x) => x.key === filter.group);
    if (filter.group && g) parts.push(g.label.toLowerCase());
    if (!parts.length) parts.push('Everything');
    const w = WHEN.find((x) => x.key === filter.when);
    return parts.join(' · ') + ' · ' + (w ? w.label.toLowerCase() : '');
}

function renderFeedHead() {
    els.title.textContent = feedTitle();
    els.sub.textContent = feedError ? '' : feedRows.length
        ? 'Newest first · ' + feedRows.length + (feedMore ? '+' : '') + ' shown' + (Number(filter.minAmount) > 1 ? ' · ' + filter.minAmount + ' or more at a time' : '')
        : '';
}

function renderFeed(loading) {
    if (itemUid) return;
    els.back.style.display = 'none';
    els.itemHead.style.display = 'none';
    renderFeedHead();
    els.feedList.innerHTML = '';
    if (loading) {
        els.feedList.appendChild(WP.empty(loading));
    } else if (feedError) {
        els.feedList.appendChild(WP.empty(feedError));
    } else if (!feedRows.length) {
        els.feedList.appendChild(WP.empty('Nothing happened that matches. Try a longer time, or fewer filters.'));
    }
    for (const r of feedRows) els.feedList.appendChild(buildLogRow(r, { showWho: true, linkWho: true }));
    els.older.style.display = feedMore ? '' : 'none';
}

// ---- the filters, on the left ----

function renderFilters() {
    const col = els.filters;
    col.innerHTML = '';

    // One search: a person, an item, or an item's id. What it finds is offered; a pick narrows the feed.
    const bar = WP.toolbar({ search: { placeholder: 'A person, an item, or an item id…' } });
    const wrap = bar.querySelector('.wp-search');
    wrap.style.flex = '0 0 auto';   // .wp-search's own flex-basis is a toolbar's width, not a column's height
    els.find = wrap.querySelector('input');
    els.find.classList.add('wp-section-search');
    els.find.dataset.input = 'ilFind';
    els.find.dataset.enter = 'ilFindEnter';
    col.appendChild(wrap);
    els.suggest = WP.el('div', 'wp-list wp-flush');
    els.suggest.style.flex = '0 0 auto';
    col.appendChild(els.suggest);

    // What it is narrowed to now, each with a way out.
    const chips = WP.el('div', 'wp-toggles');
    const chip = (label, action) => {
        const b = WP.el('button', 'wp-toggle active', label + '  ✕');
        b.type = 'button';
        b.dataset.action = action;
        b.title = 'Stop narrowing to this';
        chips.appendChild(b);
    };
    if (filter.charId) chip(filter.charName || 'Character #' + filter.charId, 'ilClearPerson');
    if (filter.itemKey) chip(itemName(filter.itemKey), 'ilClearItem');
    if (chips.children.length) col.appendChild(chips);

    col.appendChild(WP.el('div', 'wp-section-title', 'What happened'));
    col.appendChild(WP.toggles('ilGroup', GROUPS, filter.group));
    col.appendChild(WP.el('div', 'wp-section-title', 'When'));
    col.appendChild(WP.toggles('ilWhen', WHEN, filter.when));
    col.appendChild(WP.el('div', 'wp-section-title', 'How many at least'));
    const min = WP.input({ type: 'number', placeholder: 'any amount', value: filter.minAmount, enterAction: 'ilMin' });
    min.min = 0;
    min.dataset.change = 'ilMin';
    col.appendChild(WP.field('At least', min));
    col.appendChild(WP.el('div', 'wp-hint', 'Catches a big pile of cash, or a lot of one thing, appearing at once. The log keeps '
        + keepDays + ' days.'));
}

let findTimer = null;
let findSeq = 0;
function suggest(q) {
    if (findTimer) clearTimeout(findTimer);
    els.suggest.innerHTML = '';
    q = q.trim();
    if (!q) return;
    const seq = ++findSeq;
    const ql = q.toLowerCase();
    const add = (title, sub, pill, action, data) => {
        const row = WP.listItem({ title, sub, pill, pillClass: 'wp-pill-accent' });
        row.dataset.action = action;
        for (const k of Object.keys(data)) row.dataset[k] = data[k];
        els.suggest.appendChild(row);
    };
    if (UID_RE.test(q)) add('Item ' + q, 'its whole life', 'Item id', 'ilOpen', { uid: q });
    const found = Object.keys(items).filter((k) => k.toLowerCase().includes(ql) || String(items[k].name || '').toLowerCase().includes(ql))
        .sort((a, b) => itemName(a).localeCompare(itemName(b))).slice(0, 5);
    for (const k of found) add(itemName(k), k, 'Item', 'ilPickItem', { key: k });
    if (q.length < 2 && !/^\d+$/.test(q)) return;
    findTimer = setTimeout(() => {
        nuiCallback('wpCharSearch', { q }).then((list) => {
            if (seq !== findSeq || !Array.isArray(list)) return;
            for (const p of list.slice(0, 5)) {
                add(p.name || 'Character #' + p.charId, '#' + p.charId + (p.online ? ' · online now' : ''), 'Person',
                    'ilPickPerson', { char: p.charId, name: p.name || '' });
            }
        });
    }, 250);
}

function clearSuggest() {
    findSeq += 1;
    if (els.find) els.find.value = '';
    if (els.suggest) els.suggest.innerHTML = '';
}

function refilter() {
    renderFilters();
    if (itemUid) closeItem(); else loadFeed();
}

// ========================================
// ONE ITEM'S LIFE
// ========================================

/** Jump here from anywhere in the panel with an item uid. */
export function openItemTimeline(uid) {
    if (!uid) return;
    // Set first: entering the section then knows an item is wanted, not the feed.
    itemUid = uid;
    itemRows = [];
    itemInfo = null;
    WhipPanel.switchTo('itemlog');
    if (els.tabs) { els.tabs.set('feed'); showTab('feed'); }
    clearSuggest();
    renderItem('Loading…');
    nuiCallback('alItem', { uid: uid, beforeId: 0 });
    nuiCallback('alItemInfo', { uid: uid }).then((res) => {
        if (uid !== itemUid || !res) return;
        itemInfo = res;
        renderItemHead();
    });
}

/** Back to the feed — read again, as it may be a while since it was last. */
function closeItem() {
    itemUid = null;
    itemRows = [];
    itemInfo = null;
    loadFeed();
}

function renderItemHead() {
    const head = els.itemHead;
    head.innerHTML = '';
    head.style.display = '';
    const first = itemInfo && itemInfo.first;
    const last = itemInfo && itemInfo.last;
    const key = (first && first.itemKey) || (last && last.itemKey) || (itemRows[0] && itemRows[0].itemKey);
    const top = WP.el('div', 'wp-item-top');
    if (key) {
        const img = document.createElement('img');
        img.width = 56;
        img.height = 56;
        img.dataset.itemImg = '';
        img.dataset.itemKey = key;
        img.src = itemImageUrl(key, items[key] && items[key].img);
        top.appendChild(img);
    }
    const text = WP.el('div');
    text.appendChild(WP.el('div', 'wp-item-title', key ? itemName(key) : 'Item'));
    text.appendChild(WP.el('div', 'wp-item-sub', 'id ' + itemUid + (itemInfo ? '  ·  ' + itemInfo.count + ' row' + (itemInfo.count === 1 ? '' : 's') : '')));
    top.appendChild(text);
    head.appendChild(top);
    const said = (r) => [eventText(r.event), r.detail, r.who ? 'by ' + r.who : '',
        typeof r.x === 'number' ? 'at ' + r.x.toFixed(1) + ', ' + r.y.toFixed(1) + ', ' + (r.z || 0).toFixed(1) : '',
        fmtLogTime(r.ts)].filter(Boolean).join('  ·  ');
    if (first) head.appendChild(WP.statusRow({ label: 'Came to be', status: 'ok', detail: said(first) }));
    if (last && (!first || last.id !== first.id)) head.appendChild(WP.statusRow({ label: 'Last seen', status: 'ok', detail: said(last) }));
    if (itemInfo && !first) head.appendChild(WP.statusRow({ label: 'Came to be', status: 'off', detail: 'before the log began, or longer ago than it keeps' }));
}

function renderItem(loading) {
    els.back.style.display = '';
    els.title.textContent = 'One item’s life';
    els.sub.textContent = 'Newest first · everything that happened to it, and to what was inside it';
    renderItemHead();
    els.feedList.innerHTML = '';
    if (loading) els.feedList.appendChild(WP.empty(loading));
    else if (!itemRows.length) els.feedList.appendChild(WP.empty('No history for ' + itemUid));
    for (const r of itemRows) els.feedList.appendChild(buildLogRow(r, { showWho: true, linkWho: true }));
    els.older.style.display = itemRows.length && itemRows.length % 50 === 0 ? '' : 'none';
}

// ========================================
// ECONOMY
// ========================================

function loadEconomy() {
    const token = ++econ.token;
    const p = econPeriod(econ.when);
    econ.error = '';
    econ.data = null;
    econ.period = p;
    renderEconomy();
    nuiCallback('alEconomy', { since: p.since, itemKey: econ.itemKey, bucket: p.bucket }).then((res) => {
        if (token !== econ.token) return;
        if (!res || res.ok !== true) econ.error = (res && res.why) || 'The log could not be read';
        else econ.data = res;
        // Not over an open picker: rebuilding it would lose its scroll and what is being typed. The
        // figures are drawn from this when the picker closes.
        if (!econ.picking) renderEconomy();
    });
}

// ---- the graphs: plain SVG (WP.svg), sized to the pane they are drawn in ----

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
/** A piece of the period, in words: "14:00" for an hour, "Tue 8" for a day. */
function bucketLabel(p, b) {
    if (p.bucket === 3600) return String(b).padStart(2, '0') + ':00';
    const d = new Date((p.since + b * 86400) * 1000);
    return DAYS[d.getDay()] + ' ' + d.getDate();
}

/** Short numbers for an axis: 12.5k, 3.2M. */
function short(n) {
    const a = Math.abs(n);
    if (a >= 1e6) return (n / 1e6).toFixed(a >= 1e7 ? 0 : 1) + 'M';
    if (a >= 1e4) return Math.round(n / 1e3) + 'k';
    if (a >= 1e3) return (n / 1e3).toFixed(1) + 'k';
    return String(Math.round(n));
}

/** The period's pieces, every one present (a quiet hour is a zero, not a gap): { in, out, net }. */
function econBuckets(d, p) {
    const out = [];
    for (let b = 0; b < p.count; b++) out.push({ b, in: 0, out: 0, gained: 0, bought: 0, lost: 0, destroyed: 0 });
    for (const s of d.series || []) {
        const e = out[s.b];
        if (!e) continue;
        Object.assign(e, { gained: s.gained || 0, bought: s.bought || 0, lost: s.lost || 0, destroyed: s.destroyed || 0 });
        e.in = e.gained + e.bought;
        e.out = e.lost + e.destroyed;
    }
    for (const e of out) e.net = e.in - e.out;
    return out;
}

/** Which labels fit along the bottom: about one in every `step`. */
function labelStep(n) {
    return n <= 8 ? 1 : n <= 16 ? 2 : n <= 24 ? 3 : Math.ceil(n / 8);
}

/** Came in above the line, went out below it, one pair a piece. Hovering a piece says its numbers: `say(e, label)`
 *  for a chart that is not of items (the Banks page's dollars). */
export function inOutChart(host, buckets, p, readout, idle, say) {
    const W = Math.max(320, host.clientWidth || 900), H = 200;
    const L = 52, R = 8, T = 10, B = 24;
    const maxIn = Math.max(1, ...buckets.map((e) => e.in));
    const maxOut = Math.max(0, ...buckets.map((e) => e.out));
    const span = maxIn + maxOut || 1;
    const plotH = H - T - B;
    const y0 = T + plotH * (maxIn / span);
    const k = plotH / span;
    const bw = (W - L - R) / buckets.length;
    const root = WP.svg('svg', { class: 'wp-chart', viewBox: '0 0 ' + W + ' ' + H, width: W, height: H });
    root.appendChild(WP.svg('line', { class: 'wp-chart-grid', x1: L, x2: W - R, y1: T, y2: T }));
    if (maxOut > 0) root.appendChild(WP.svg('line', { class: 'wp-chart-grid', x1: L, x2: W - R, y1: H - B, y2: H - B }));
    root.appendChild(WP.svg('text', { x: L - 8, y: T + 4, 'text-anchor': 'end' }, short(maxIn)));
    root.appendChild(WP.svg('text', { x: L - 8, y: y0 + 4, 'text-anchor': 'end' }, '0'));
    if (maxOut > 0) root.appendChild(WP.svg('text', { x: L - 8, y: H - B + 4, 'text-anchor': 'end' }, '−' + short(maxOut)));
    const step = labelStep(buckets.length);
    const gap = Math.min(3, bw * 0.15);
    buckets.forEach((e, i) => {
        const x = L + i * bw;
        if (e.in > 0) root.appendChild(WP.svg('rect', { class: 'wp-chart-in', x: x + gap, y: y0 - e.in * k, width: Math.max(1, bw - gap * 2), height: e.in * k, rx: 2 }));
        if (e.out > 0) root.appendChild(WP.svg('rect', { class: 'wp-chart-out', x: x + gap, y: y0, width: Math.max(1, bw - gap * 2), height: e.out * k, rx: 2 }));
        if (i % step === 0) root.appendChild(WP.svg('text', { x: x + bw / 2, y: H - 6, 'text-anchor': 'middle' }, bucketLabel(p, e.b)));
        if (p.nowIndex !== undefined && i > p.nowIndex) return;   // an hour still to come has nothing to say
        const hit = WP.svg('rect', { class: 'wp-chart-hit', x, y: T, width: bw, height: plotH });
        hit.addEventListener('mouseenter', () => {
            if (say) { readout.textContent = say(e, bucketLabel(p, e.b)); return; }
            readout.textContent = bucketLabel(p, e.b) + ':  ' + fmtAmount(econ.itemKey, e.in) + ' came in (' + fmtAmount(econ.itemKey, e.gained)
                + ' gained, ' + fmtAmount(econ.itemKey, e.bought) + ' bought)  ·  ' + fmtAmount(econ.itemKey, e.out) + ' went out  ·  '
                + (e.net > 0 ? '+' : e.net < 0 ? '−' : '') + fmtAmount(econ.itemKey, Math.abs(e.net));
        });
        hit.addEventListener('mouseleave', () => { readout.textContent = idle; });
        root.appendChild(hit);
    });
    root.appendChild(WP.svg('line', { class: 'wp-chart-zero', x1: L, x2: W - R, y1: y0, y2: y0 }));
    host.appendChild(root);
}

/** How many there were at the end of each piece: today's count, walked back through each piece's
 *  in and out. An estimate — what the log did not see (a wallet's cash, a resource's own stores)
 *  it cannot add back. */
function stockChart(host, all, p, now, readout, idle) {
    // Up to now: the hours still to come today have no count yet.
    const buckets = all.slice(0, (p.nowIndex === undefined ? all.length - 1 : p.nowIndex) + 1);
    const raw = new Array(buckets.length);
    let v = now;
    for (let i = buckets.length - 1; i >= 0; i--) { raw[i] = v; v -= buckets[i].net; }
    // BELOW NONE IS NOT A COUNT. The log saw more come in than there is now: some of it was never
    // logged going out (or the count misses where it is). The line stops at none and says so.
    const short0 = v < 0 || raw.some((n) => n < 0);
    const values = raw.map((n) => Math.max(0, n));
    const start = Math.max(0, v);   // before the first piece
    if (short0) {
        idle += ' Before part of this period the log saw more come in than there is now, so that early part is a guess.';
        readout.textContent = idle;
    }
    const W = Math.max(320, host.clientWidth || 900), H = 160;
    const L = 52, R = 8, T = 12, B = 24;
    const lo = 0, hi = Math.max(1, start, ...values);
    const plotH = H - T - B;
    const y = (n) => T + plotH * (1 - (n - lo) / (hi - lo || 1));
    // The whole period's width, as the graph above has: today's line ends at this hour, under its bar.
    const bw = (W - L - R) / all.length;
    const x = (i) => L + (i + 1) * bw;   // the END of piece i
    const root = WP.svg('svg', { class: 'wp-chart', viewBox: '0 0 ' + W + ' ' + H, width: W, height: H });
    root.appendChild(WP.svg('line', { class: 'wp-chart-grid', x1: L, x2: W - R, y1: y(hi), y2: y(hi) }));
    root.appendChild(WP.svg('line', { class: 'wp-chart-grid', x1: L, x2: W - R, y1: y(lo), y2: y(lo) }));
    root.appendChild(WP.svg('text', { x: L - 8, y: y(hi) + 4, 'text-anchor': 'end' }, short(hi)));
    root.appendChild(WP.svg('text', { x: L - 8, y: y(lo) + 4, 'text-anchor': 'end' }, short(lo)));
    const pts = [[L, y(start)]].concat(values.map((n, i) => [x(i), y(n)]));
    const line = pts.map((pt, i) => (i ? 'L' : 'M') + pt[0].toFixed(1) + ' ' + pt[1].toFixed(1)).join(' ');
    root.appendChild(WP.svg('path', { class: 'wp-chart-area', d: line + ' L' + pts[pts.length - 1][0].toFixed(1) + ' ' + y(lo).toFixed(1) + ' L' + L + ' ' + y(lo).toFixed(1) + ' Z' }));
    root.appendChild(WP.svg('path', { class: 'wp-chart-line', d: line }));
    const step = labelStep(all.length);
    all.forEach((e, i) => {
        if (i % step === 0) root.appendChild(WP.svg('text', { x: L + i * bw + bw / 2, y: H - 6, 'text-anchor': 'middle' }, bucketLabel(p, e.b)));
    });
    buckets.forEach((e, i) => {
        const hit = WP.svg('rect', { class: 'wp-chart-hit', x: L + i * bw, y: T, width: bw, height: plotH });
        hit.addEventListener('mouseenter', () => {
            readout.textContent = 'End of ' + bucketLabel(p, e.b) + ':  about ' + fmtAmount(econ.itemKey, values[i]) + ' in the game';
        });
        hit.addEventListener('mouseleave', () => { readout.textContent = idle; });
        root.appendChild(hit);
    });
    root.appendChild(WP.svg('circle', { class: 'wp-chart-dot', cx: x(values.length - 1), cy: y(values[values.length - 1]), r: 3.5 }));
    host.appendChild(root);
}

/** A graph in its card: title, key, the graph, and the line under it that hovering fills in. */
function chartCard(body, title, legend, draw, idle) {
    const card = WP.el('div', 'wp-chart-card');
    const head = WP.el('div', 'wp-chart-head');
    head.appendChild(WP.el('div', 'wp-section-title', title));
    if (legend) {
        const lg = WP.el('div', 'wp-chart-legend');
        for (const [cls, text] of legend) {
            const s = WP.el('span');
            s.appendChild(WP.el('span', 'wp-chart-key ' + cls));
            s.appendChild(document.createTextNode(text));
            lg.appendChild(s);
        }
        head.appendChild(lg);
    }
    card.appendChild(head);
    const host = WP.el('div');
    card.appendChild(host);
    const readout = WP.el('div', 'wp-chart-readout', idle);
    card.appendChild(readout);
    body.appendChild(card);
    draw(host, readout);   // in the page now, so it can be measured
}

function tally(list, name, value, sub, out, action, data) {
    const max = list.reduce((m, x) => Math.max(m, Math.abs(Number(x) || 0)), 0) || 1;
    return (entry) => {
        const v = Math.abs(Number(value(entry)) || 0);
        const el = WP.el(action ? 'button' : 'div', 'wp-tally' + (out ? ' wp-tally-out' : ''));
        if (action) {
            el.type = 'button';
            el.dataset.action = action;
            const d = data(entry);
            for (const k of Object.keys(d)) el.dataset[k] = d[k];
        }
        el.appendChild(WP.el('span', 'wp-tally-name', name(entry)));
        el.appendChild(WP.el('span', 'wp-tally-value', fmtAmount(econ.itemKey, v)));
        if (sub) el.appendChild(WP.el('span', 'wp-tally-sub', sub(entry)));
        const bar = WP.el('span', 'wp-tally-bar');
        const fill = WP.el('span');
        fill.style.width = Math.max(2, Math.round((v / max) * 100)) + '%';
        bar.appendChild(fill);
        el.appendChild(bar);
        return el;
    };
}

const REASON_FALLBACK = { gained: 'no reason given', bought: 'bought in a shop', lost: 'no reason given', destroyed: 'destroyed' };
function reasonName(r) {
    const why = String(r.why || '').trim();
    if (r.event === 'bought') return why ? 'bought ' + why : 'bought in a shop';
    if (r.event === 'destroyed') return why ? 'destroyed · ' + why : 'destroyed';
    return why || REASON_FALLBACK[r.event] || r.event;
}

function renderEconomy() {
    const body = els.econBody;
    if (!body) return;
    body.innerHTML = '';

    // PICKING AN ITEM: a picture list of all items, like the shop and NPC pickers, in the tab's place
    // until one is picked.
    if (econ.picking) {
        const top = WP.el('div', 'wp-actions-row wp-head-row');
        top.appendChild(WP.backBtn('Back', 'ilEconPickClose'));
        top.appendChild(WP.el('div', 'wp-pane-title', 'Pick an item'));
        body.appendChild(top);
        const all = Object.assign({}, items);
        for (const x of (econ.data && econ.data.items) || []) {
            if (!all[x.itemKey]) all[x.itemKey] = { name: x.itemName || x.itemKey };
        }
        if (!all.cash) all.cash = { name: 'Cash' };
        // "moved today", "moved this week", "moved this month" and "all" — the only choices. Each "moved" list is the log's count of every row naming the item.
        const pick = itemTiles({
            id: 'il-econ-items',
            items: all,
            value: econ.itemKey,
            groups: MOVED.map((m) => ({ key: m.key, label: m.label, load: () => movedIn(m) })),
            first: econ.when === 'today' ? 'today' : econ.when === 'week' ? 'week' : 'month',
            onPick: (k) => {
                econ.picking = false;
                econ.itemKey = k;
                els.econBody.scrollTop = 0;
                loadEconomy();
            },
        });
        body.appendChild(pick.root);
        pick.focus();
        return;
    }

    // The item is the page's title, and a button: pressing it opens every item's picture. Beside it,
    // which period.
    const head = WP.el('div', 'wp-actions-row wp-head-row');
    const choose = WP.el('button', 'wp-pick-btn');
    choose.type = 'button';
    choose.dataset.action = 'ilEconPickOpen';
    choose.title = 'Pick another item';
    const chooseImg = document.createElement('img');
    chooseImg.alt = '';
    chooseImg.dataset.itemImg = '';
    chooseImg.dataset.itemKey = econ.itemKey;
    chooseImg.src = itemImageUrl(econ.itemKey, items[econ.itemKey] && items[econ.itemKey].img);
    choose.appendChild(chooseImg);
    const chooseText = WP.el('span', 'wp-pick-btn-text');
    chooseText.appendChild(WP.el('span', 'wp-pick-btn-name', itemName(econ.itemKey)));
    chooseText.appendChild(WP.el('span', 'wp-pick-btn-change', 'Change item'));
    choose.appendChild(chooseText);
    head.appendChild(choose);
    head.appendChild(WP.el('span', 'wp-actions-split'));
    head.appendChild(WP.toggles('ilEconWhen', ECON_WHEN.map((w) => (w.key === 'all' ? { key: w.key, label: 'Last ' + keepDays + ' days' } : w)), econ.when));
    body.appendChild(head);

    if (econ.error) { body.appendChild(WP.empty(econ.error)); return; }
    const d = econ.data;
    if (!d) { body.appendChild(WP.empty('Adding it up…')); return; }

    const it = d.items.find((x) => x.itemKey === econ.itemKey) || { gained: 0, bought: 0, lost: 0, destroyed: 0 };
    const cameIn = (it.gained || 0) + (it.bought || 0);
    const wentOut = (it.lost || 0) + (it.destroyed || 0);
    const net = cameIn - wentOut;
    const name = d.itemName || itemName(econ.itemKey);
    const census = d.census || null;
    const stats = WP.el('div', 'wp-stats');
    if (census) {
        const w = census.where || {};
        const parts = [['pockets', w.pockets], ['stashes', w.stashes], ['cars', w.cars], ['on the ground', w.ground]]
            .filter((x) => x[1]).map((x) => fmtAmount(econ.itemKey, x[1]) + ' ' + x[0]);
        stats.appendChild(WP.stat('In the game now', fmtAmount(econ.itemKey, census.total),
            (parts.length ? parts.join(' · ') : 'none anywhere') + (census.complete ? '' : ' · some places could not be read')));
    }
    stats.appendChild(WP.stat('Came in', fmtAmount(econ.itemKey, cameIn),
        fmtAmount(econ.itemKey, it.gained || 0) + ' gained · ' + fmtAmount(econ.itemKey, it.bought || 0) + ' bought in shops'));
    stats.appendChild(WP.stat('Went out', fmtAmount(econ.itemKey, wentOut),
        fmtAmount(econ.itemKey, it.lost || 0) + ' spent or used · ' + fmtAmount(econ.itemKey, it.destroyed || 0) + ' destroyed'));
    stats.appendChild(WP.stat('Difference', (net > 0 ? '+' : net < 0 ? '−' : '') + fmtAmount(econ.itemKey, Math.abs(net)),
        net > 0 ? 'more in the game than before' : net < 0 ? 'less in the game than before' : 'as much as before',
        net > 0 ? 'up' : net < 0 ? 'down' : null));
    body.appendChild(stats);

    // ---- the graphs ----
    const p = econ.period || econPeriod(econ.when);
    const buckets = econBuckets(d, p);
    const per = p.bucket === 3600 ? 'hour' : 'day';
    const idleInOut = 'Point at a ' + per + ' for its numbers. Busiest: ' + (() => {
        const top = buckets.reduce((m, e) => (e.in > m.in ? e : m), buckets[0] || { in: 0 });
        return top && top.in > 0 ? bucketLabel(p, top.b) + ', ' + fmtAmount(econ.itemKey, top.in) + ' came in' : 'none came in';
    })();
    chartCard(body, 'Came in and went out, per ' + per, [['wp-chart-key-in', 'came in'], ['wp-chart-key-out', 'went out']],
        (host, readout) => inOutChart(host, buckets, p, readout, idleInOut), idleInOut);
    if (census) {
        const idleStock = 'About ' + fmtAmount(econ.itemKey, census.total) + ' now. Worked out from today\'s count and the log, '
            + 'so it leaves out what the log never saw (cash inside wallets, a resource\'s own storage).';
        chartCard(body, 'How many there were', null,
            (host, readout) => stockChart(host, buckets, p, census.total, readout, idleStock), idleStock);
    }

    const reasonsIn = d.reasons.filter((r) => r.event === 'gained' || r.event === 'bought');
    const reasonsOut = d.reasons.filter((r) => r.event === 'lost' || r.event === 'destroyed');
    const cols = WP.el('div', 'wp-cols-2');
    cols.style.alignItems = 'start';
    const colIn = WP.el('div');
    colIn.appendChild(WP.el('div', 'wp-section-title', 'Where it came from'));
    const listIn = WP.el('div', 'wp-tallies');
    const drawIn = tally(reasonsIn.map((r) => r.total), reasonName, (r) => r.total, (r) => r.n + ' time' + (r.n === 1 ? '' : 's'));
    for (const r of reasonsIn) listIn.appendChild(drawIn(r));
    if (!reasonsIn.length) listIn.appendChild(WP.empty('None came in'));
    colIn.appendChild(listIn);
    const colOut = WP.el('div');
    colOut.appendChild(WP.el('div', 'wp-section-title', 'Where it went'));
    const listOut = WP.el('div', 'wp-tallies');
    const drawOut = tally(reasonsOut.map((r) => r.total), reasonName, (r) => r.total, (r) => r.n + ' time' + (r.n === 1 ? '' : 's'), true);
    for (const r of reasonsOut) listOut.appendChild(drawOut(r));
    if (!reasonsOut.length) listOut.appendChild(WP.empty('None went out'));
    colOut.appendChild(listOut);
    cols.appendChild(colIn);
    cols.appendChild(colOut);
    body.appendChild(cols);

    // Who has it now (in their pockets), beside who gained the most of it in the period.
    const people = WP.el('div', 'wp-cols-2');
    people.style.alignItems = 'start';
    const colHave = WP.el('div');
    colHave.appendChild(WP.el('div', 'wp-section-title', 'Who holds the most now'));
    const have = WP.el('div', 'wp-tallies');
    const holders = (census && census.holders) || [];
    const drawHave = tally(holders.map((h) => h.total), (h) => h.who || 'Character #' + h.charId, (h) => h.total,
        () => 'in their pockets · click for their activity', false, 'ilHolder', (h) => ({ char: h.charId, name: h.who || '' }));
    for (const h of holders) have.appendChild(drawHave(h));
    if (!holders.length) have.appendChild(WP.empty('Nobody has any in their pockets'));
    colHave.appendChild(have);
    const colGained = WP.el('div');
    colGained.appendChild(WP.el('div', 'wp-section-title', 'Who gained the most'));
    const gained = WP.el('div', 'wp-tallies');
    const drawWho = tally(d.gainers.map((g) => g.total), (g) => g.who || 'Character #' + g.charId, (g) => g.total,
        (g) => g.n + ' time' + (g.n === 1 ? '' : 's') + ' · click for what they gained', false, 'ilGainer',
        (g) => ({ char: g.charId, name: g.who || '' }));
    for (const g of d.gainers) gained.appendChild(drawWho(g));
    if (!d.gainers.length) gained.appendChild(WP.empty('Nobody gained any'));
    colGained.appendChild(gained);
    people.appendChild(colHave);
    people.appendChild(colGained);
    body.appendChild(people);

    // Every item that moved in or out, the busiest first: pick one for the figures above.
    body.appendChild(WP.el('div', 'wp-section-title', 'Every item'));
    const wrap = WP.el('div', 'wp-table-wrap');
    const table = WP.el('table', 'wp-table');
    const thead = WP.el('tr');
    for (const h of ['Item', 'Came in', 'Went out', 'Difference']) thead.appendChild(WP.el('th', null, h));
    table.appendChild(thead);
    for (const x of d.items) {
        const tr = WP.el('tr', 'wp-table-row-click');
        tr.dataset.action = 'ilEconPick';
        tr.dataset.key = x.itemKey;
        const inN = (x.gained || 0) + (x.bought || 0);
        const outN = (x.lost || 0) + (x.destroyed || 0);
        tr.appendChild(WP.el('td', null, x.itemName || itemName(x.itemKey)));
        tr.appendChild(WP.el('td', 'wp-td-num', fmtAmount(x.itemKey, inN)));
        tr.appendChild(WP.el('td', 'wp-td-num', fmtAmount(x.itemKey, outN)));
        const diff = inN - outN;
        tr.appendChild(WP.el('td', 'wp-td-num', (diff > 0 ? '+' : diff < 0 ? '−' : '') + fmtAmount(x.itemKey, Math.abs(diff))));
        if (x.itemKey === econ.itemKey) tr.classList.add('active');
        table.appendChild(tr);
    }
    wrap.appendChild(table);
    body.appendChild(wrap);
    if (!d.items.length) body.appendChild(WP.empty('Nothing came in or went out'));
}

// ========================================
// THE SECTION
// ========================================

function showTab(key) {
    tab = key;
    econ.picking = false;   // a picker left open is not what the Economy tab comes back to
    els.feedView.style.display = key === 'feed' ? '' : 'none';
    els.econView.style.display = key === 'economy' ? '' : 'none';
    if (key === 'economy') loadEconomy();
}

WhipPanel.registerSection({
    id: 'itemlog',
    group: 'economy',
    label: 'Item Log',
    order: 45,

    render(root) {
        els = {};
        els.tabs = WP.tabs({
            id: 'il-tabs', active: tab,
            tabs: [{ key: 'feed', label: 'Everything' }, { key: 'economy', label: 'Economy' }],
            onChange: (k) => showTab(k),
        });
        root.appendChild(els.tabs.root);

        // ---- Everything: the filters | the feed (or one item's life) ----
        els.feedView = WP.el('div', 'wp-view');
        const split = WP.el('div', 'wp-split');
        els.filters = WP.el('div', 'wp-list-col wp-log-filters');
        split.appendChild(els.filters);
        els.detail = WP.el('div', 'wp-detail');
        els.back = WP.backBtn('Back to everything', 'ilBack');
        els.back.classList.add('wp-log-back');
        els.back.style.display = 'none';
        els.detail.appendChild(els.back);
        const titleRow = WP.el('div', 'wp-item-top');
        els.title = WP.el('div', 'wp-pane-title', 'Everything');
        titleRow.appendChild(els.title);
        els.detail.appendChild(titleRow);
        els.sub = WP.el('div', 'wp-item-sub', '');
        els.detail.appendChild(els.sub);
        els.itemHead = WP.el('div', 'wp-after');
        els.itemHead.style.display = 'none';
        els.detail.appendChild(els.itemHead);
        els.feedList = WP.el('div', 'wp-feed wp-after');
        els.detail.appendChild(els.feedList);
        els.older = WP.btn('Older', 'ilOlder');
        els.older.classList.add('wp-after');
        els.older.style.display = 'none';
        els.detail.appendChild(els.older);
        split.appendChild(els.detail);
        els.feedView.appendChild(split);
        root.appendChild(els.feedView);

        // ---- Economy ----
        els.econView = WP.el('div', 'wp-view');
        els.econBody = WP.el('div', 'wp-detail');
        els.econView.appendChild(els.econBody);
        root.appendChild(els.econView);

        renderFilters();
        if (itemUid) renderItem(); else renderFeed();
        els.feedView.style.display = tab === 'feed' ? '' : 'none';
        els.econView.style.display = tab === 'economy' ? '' : 'none';
    },

    onEnter() {
        entered = true;
        askSetup();
        if (tab === 'economy') loadEconomy();
        else if (!itemUid) loadFeed();
        startPoll();
    },

    onLeave() {
        entered = false;
        econ.picking = false;   // back to the item's figures when the section is opened again
        stopPoll();
    },

    onData(kind, payload) {
        if (kind !== 'timeline') return;
        if (payload.uid !== itemUid) return;   // an item the admin has already moved on from
        if (payload.more) {
            itemRows = itemRows.concat(payload.rows || []);
            for (const r of payload.rows || []) els.feedList.appendChild(buildLogRow(r, { showWho: true, linkWho: true }));
            els.older.style.display = (payload.rows || []).length >= 50 ? '' : 'none';
        } else {
            itemRows = payload.rows || [];
            renderItem();
        }
        if (!itemInfo) renderItemHead();
    },

    onEscape() {
        if (tab === 'economy' && econ.picking) { econ.picking = false; renderEconomy(); return true; }
        if (els.suggest && els.suggest.children.length) { clearSuggest(); return true; }
        if (itemUid) { closeItem(); return true; }
        return false;
    },

    actions: {
        ilFind: (el) => suggest(el.value),
        ilFindEnter: (el) => {
            const q = el.value.trim();
            if (UID_RE.test(q)) { openItemTimeline(q); return; }
            const first = els.suggest.querySelector('.wp-list-item');
            if (first) first.click();
        },
        ilPickItem: (el) => { filter.itemKey = el.dataset.key; clearSuggest(); refilter(); },
        ilPickPerson: (el) => {
            filter.charId = Number(el.dataset.char);
            filter.charName = el.dataset.name || '';
            clearSuggest();
            refilter();
        },
        ilClearPerson: () => { filter.charId = 0; filter.charName = ''; refilter(); },
        ilClearItem: () => { filter.itemKey = ''; refilter(); },
        ilGroup: (el) => { filter.group = el.dataset.arg; refilter(); },
        ilWhen: (el) => { filter.when = el.dataset.arg; refilter(); },
        ilMin: (el) => {
            const v = String(el.value).trim();
            if (v === String(filter.minAmount)) return;
            filter.minAmount = v;
            if (itemUid) closeItem(); else loadFeed();
        },
        ilOlder: () => {
            if (itemUid) {
                if (!itemRows.length) return;
                nuiCallback('alItem', { uid: itemUid, beforeId: itemRows[itemRows.length - 1].id });
            } else {
                loadOlder();
            }
        },
        ilBack: () => closeItem(),
        ilOpen: (el) => openItemTimeline(el.dataset.uid),
        ilPlayer: (el) => openPlayer(el.dataset.id),
        alTp: (el) => confirmTeleport(el),

        ilEconWhen: (el) => { econ.when = el.dataset.arg; loadEconomy(); },
        ilEconPickOpen: () => { econ.picking = true; renderEconomy(); },
        ilEconPickClose: () => { econ.picking = false; renderEconomy(); },
        ilEconPick: (el) => { econ.itemKey = el.dataset.key; loadEconomy(); },
        // Someone who gained a lot: the feed, narrowed to them, that item, what came in, that period.
        ilGainer: (el) => {
            filter.charId = Number(el.dataset.char);
            filter.charName = el.dataset.name || '';
            filter.itemKey = econ.itemKey;
            filter.group = 'came_in';
            filter.when = econ.when === 'today' ? 'today' : econ.when === 'week' ? 'week' : 'all';
            els.tabs.set('feed');
            showTab('feed');
            refilter();
        },
        // Someone holding a lot: everything they did with that item, as far back as the log goes.
        ilHolder: (el) => {
            filter.charId = Number(el.dataset.char);
            filter.charName = el.dataset.name || '';
            filter.itemKey = econ.itemKey;
            filter.group = '';
            filter.when = 'all';
            els.tabs.set('feed');
            showTab('feed');
            refilter();
        },
    },
});
