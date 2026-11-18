// ========================================
// /whip — Players → Phones → a number's RECORDS: the dashboard
//
// Everything one number did, as screens side by side, the way a security desk reads it:
//
//   01 PHONE     the phone itself, as its owner sees it: Messages (the conversations, then one), Recents and
//                Contacts (then a contact's page), with what the desk needs on top: exact times, read times,
//                and who really owns the number at the other end.
//   02 CALLS     every call, newest first: who, which way, how it ended, how long it rang and how long they
//                talked. A row opens to all of it.
//   03 ACTIVITY  how much and when: the totals, the hours of the day (the admin's own clock), the last fortnight.
//   04 PEOPLE    everyone the number deals with, texted, called or saved, and who they really are; on top, its
//                blocks both ways (the numbers it blocked, the numbers that blocked it) and when.
//
// HELD BACK: a text or call that came while its receiver had blocked the sender (whip_phone's block list). The
// receiver never saw it, so their own phone leaves it out; here it stays, marked, as the evidence when someone
// reports being harassed.
//
// PICK A PERSON ANYWHERE (a conversation, a call, a contact, a row in People) and every screen turns to them:
// the phone opens your conversation with them, the calls narrow to theirs, People marks them. "Open their
// phone" moves the whole dashboard to their number.
//
// Read only. Data: pmDossier (server/devtools.lua, pmPhoneDossier) and pmThread for a conversation, a page at a
// time. Times arrive as unix SECONDS. Text a player wrote (texts, contact names) only ever goes in as textContent.
// ========================================

import { WP } from '../whip-panel.js';
import { nuiCallback } from '../utils.js';
import { ICON_PATH } from '../ui-icons.js';
import { avatar } from './pickers.js';
import { plural, ago, phoneNumber } from './format.js';

// ---- fixed icons (no data in them) ----
const ICON = {
    back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' + ICON_PATH.back + '</svg>',
    msgs: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 4c4.7 0 8.5 3 8.5 6.8S16.7 17.6 12 17.6c-.9 0-1.8-.1-2.6-.3L5.6 19.4l1.1-3.3C4.8 14.9 3.5 13 3.5 10.8 3.5 7 7.3 4 12 4z"/></svg>',
    recents: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>',
    contacts: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="8.5" r="4"/><path d="M4 20c.6-4 3.9-6.2 8-6.2s7.4 2.2 8 6.2z"/></svg>',
    call: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7.2 3.2c.6-.3 1.3-.1 1.6.5l1.5 3.1c.3.6.1 1.3-.4 1.7l-1.3 1c.9 2.1 2.6 3.8 4.7 4.7l1-1.3c.4-.5 1.1-.7 1.7-.4l3.1 1.5c.6.3.8 1 .5 1.6l-.9 1.9c-.4.8-1.3 1.3-2.2 1.2C9.9 18.3 4.5 12.9 4.1 6.3C4 5.4 4.5 4.5 5.3 4.1z"/></svg>',
    out: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17L17 7M9 7h8v8"/></svg>',
    in: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M17 7L7 17M15 17H7V9"/></svg>',
    signal: '<svg viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>',
    battery: '<svg viewBox="0 0 26 12" fill="none" stroke="currentColor"><rect x="0.5" y="0.5" width="22" height="11" rx="3"/><rect x="2.5" y="2.5" width="15" height="7" rx="1.5" fill="currentColor" stroke="none"/><path d="M24.5 4v4" stroke-width="2" stroke-linecap="round"/></svg>',
};

function icon(name, cls) {
    const s = WP.el('span', 'pr-ico' + (cls ? ' ' + cls : ''));
    s.innerHTML = ICON[name];   // fixed markup
    return s;
}

// ---- state ----
let els = {};
let hooks = {};              // { onClose(), onEntry(number) -> the list's entry for a number, or null }
let current = null;          // the number on show
let data = null;             // its dossier; null while it loads
let failed = null;           // why it could not be read
let focus = null;            // the person every screen is turned to (their number), or null
let phoneTab = 'messages';   // messages | recents | contacts
let phoneView = null;        // null (the tab's list) | { kind: 'thread' | 'contact', number }
let threads = {};            // their number -> { messages, more, loading, failed }
let callFilter = 'all';      // all | out | in | missed
let callOpen = null;         // the call opened in the log (its id)
let peopleSort = 'most';     // most | recent
let token = 0;               // the newest load: an answer for an older one is dropped

// ---- words and numbers ----

const two = (n) => String(n).padStart(2, '0');
const asDate = (s) => new Date(s * 1000);
const hm = (d) => two(d.getHours()) + ':' + two(d.getMinutes());
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function startOfDay(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); }

/** The day a moment fell on, in words: Today, Yesterday, Tue, 3 Oct, 3 Oct 2025. */
function dayWord(s) {
    const d = asDate(s), now = new Date(), diff = (startOfDay(now) - startOfDay(d)) / 864e5;
    if (diff <= 0) return 'Today';
    if (diff === 1) return 'Yesterday';
    if (diff < 7) return DAYS[d.getDay()];
    return d.getDate() + ' ' + MONTHS[d.getMonth()] + (d.getFullYear() !== now.getFullYear() ? ' ' + d.getFullYear() : '');
}

/** Short, for a list's corner: 14:02 today, else the day. */
function short(s) {
    if (!s) return '';
    const w = dayWord(s);
    return w === 'Today' ? hm(asDate(s)) : w;
}

/** Day and time: "Today 14:02", "Tue 14:02", "3 Oct 14:02". */
function stamp(s) {
    if (!s) return '—';
    return dayWord(s) + ' ' + hm(asDate(s));
}

/** All of it, to the second: "Tue 3 Oct 2026, 14:02:33". */
function full(s) {
    if (!s) return '—';
    const d = asDate(s);
    return DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear() + ', '
        + hm(d) + ':' + two(d.getSeconds());
}

/** A call's length on a clock: 0:42, 12:05, 1:02:05. */
function clock(sec) {
    sec = Math.max(0, Math.round(sec || 0));
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), x = sec % 60;
    return h ? h + ':' + two(m) + ':' + two(x) : m + ':' + two(x);
}

/** A length in words: 42s, 4m 10s, 1h 12m. */
function lasting(sec) {
    sec = Math.max(0, Math.round(sec || 0));
    if (sec < 60) return sec + 's';
    if (sec < 3600) return Math.floor(sec / 60) + 'm' + (sec % 60 ? ' ' + (sec % 60) + 's' : '');
    return Math.floor(sec / 3600) + 'h ' + two(Math.floor((sec % 3600) / 60)) + 'm';
}

// ---- who is who ----

function savedAs(number) {
    if (!data) return null;
    const c = data.contacts.find((x) => x.number === number);
    return c ? c.name : null;
}

function ownerOf(number) { return (data && data.owners && data.owners[number]) || null; }

/** What to call a number: the name this phone saved it under, else its owner's, else the number. */
function nameOf(number) {
    const o = ownerOf(number);
    return savedAs(number) || (o && o.name) || phoneNumber(number);
}

/** Who really owns it, in words. */
function ownerWords(number) {
    const o = ownerOf(number);
    if (!o) return 'Not a number on this server';
    if (o.retired) return 'A retired number' + (o.renamedTo ? ' (now ' + phoneNumber(o.renamedTo) + ')' : '');
    if (o.lore) return (o.name || 'Lore character') + '  ·  lore character';
    return (o.name || 'Character') + '  ·  #' + o.charId + (o.online ? '  ·  online' + (o.source ? ' (#' + o.source + ')' : '') : '  ·  offline');
}

/** Initials in a disc, the phone's own avatar. */
function disc(name, big) {
    const words = String(name || '#').replace(/[^\p{L}\p{N}\s]/gu, '').trim().split(/\s+/);
    const letters = /^\d/.test(name || '') ? '#' : ((words[0] || '#')[0] + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase();
    return WP.el('span', 'pr-disc' + (big ? ' pr-disc-lg' : ''), letters);
}

/** Everyone it deals with: texted, called or saved. */
function people() {
    const map = new Map();
    const get = (n) => {
        if (!map.has(n)) map.set(n, { number: n, texts: 0, sent: 0, recv: 0, unread: 0, calls: 0, callsOut: 0, talk: 0, lastAt: 0, saved: null });
        return map.get(n);
    };
    for (const t of data.threads) {
        const p = get(t.number);
        Object.assign(p, { texts: t.n, sent: t.sent, recv: t.recv, unread: t.unread });
        p.lastAt = Math.max(p.lastAt, t.lastAt || 0);
    }
    for (const c of data.callsBy) {
        const p = get(c.number);
        Object.assign(p, { calls: c.n, callsOut: c.outN, talk: c.talk });
        p.lastAt = Math.max(p.lastAt, c.lastAt || 0);
    }
    for (const c of data.contacts) {
        const p = get(c.number);
        p.saved = c.name;
        p.savedAt = c.savedAt;
    }
    const list = [...map.values()];
    if (peopleSort === 'recent') list.sort((a, b) => b.lastAt - a.lastAt);
    else list.sort((a, b) => (b.texts + b.calls * 3) - (a.texts + a.calls * 3) || b.lastAt - a.lastAt);
    return list;
}

function threadOf(number) { return data && data.threads.find((t) => t.number === number); }
function callsWith(number) { return data ? data.callsBy.find((c) => c.number === number) : null; }

/** Its blocks with one number, either way: when this phone blocked them, when they blocked this phone (0: never). */
function blockWith(number) {
    const mine = data && data.blocks.find((b) => b.number === number);
    const theirs = data && data.blockedBy.find((b) => b.number === number);
    return { mine: mine ? mine.at : 0, theirs: theirs ? theirs.at : 0 };
}

// ---- loading ----

function load(number) {
    const mine = ++token;
    current = number;
    data = null;
    failed = null;
    focus = null;
    phoneTab = 'messages';
    phoneView = null;
    threads = {};
    callFilter = 'all';
    callOpen = null;
    renderAll();
    nuiCallback('pmDossier', { phoneNumber: number, tzOffset: new Date().getTimezoneOffset() }).then((res) => {
        if (mine !== token) return;
        if (!res || res.ok !== true) {
            failed = (res && res.why) || 'The records could not be read.';
        } else {
            data = res;
            for (const k of ['contacts', 'threads', 'calls', 'callsBy', 'blocks', 'blockedBy', 'others', 'days', 'hours']) {
                if (!Array.isArray(data[k])) data[k] = [];
            }
            if (!data.owners || typeof data.owners !== 'object' || Array.isArray(data.owners)) data.owners = {};
            data.totals = data.totals || {};
        }
        renderAll();
    });
}

function loadThread(number, older) {
    const t = threads[number] || (threads[number] = { messages: [], more: false, loading: false, failed: null });
    if (t.loading) return;
    t.loading = true;
    const mine = token;
    const beforeId = older && t.messages.length ? t.messages[0].id : undefined;
    nuiCallback('pmThread', { phoneNumber: current, otherNumber: number, beforeId }).then((res) => {
        if (mine !== token) return;
        t.loading = false;
        if (!res || res.ok !== true) {
            t.failed = (res && res.why) || 'The conversation could not be read.';
        } else {
            const msgs = Array.isArray(res.messages) ? res.messages : [];
            t.messages = older ? msgs.concat(t.messages) : msgs;
            t.more = res.more === true;
            t.failed = null;
        }
        if (phoneView && phoneView.kind === 'thread' && phoneView.number === number) renderPhone(older ? 'keep' : 'bottom');
    });
}

// ---- turning every screen to one person ----

function setFocus(number, via) {
    focus = number || null;
    callOpen = null;
    if (focus && via !== 'phone') {
        if (threadOf(focus)) { phoneTab = 'messages'; openThread(focus, true); }
        else if (savedAs(focus)) { phoneTab = 'contacts'; phoneView = { kind: 'contact', number: focus }; }
        else { phoneTab = 'recents'; phoneView = null; }
    }
    renderPhone(focus && phoneView && phoneView.kind === 'thread' ? 'bottom' : null);
    renderCalls();
    renderPeople();
    if (focus) {
        const row = els.peopleBody && els.peopleBody.querySelector('.pr-person.active');
        if (row && row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
    }
}

function openThread(number, quiet) {
    phoneView = { kind: 'thread', number };
    if (!threads[number] || (!threads[number].messages.length && !threads[number].loading)) loadThread(number, false);
    if (!quiet) setFocus(number, 'phone');
}

// ---- the screens ----

function screen(no, title, extraClass) {
    const s = WP.el('section', 'pr-screen' + (extraClass ? ' ' + extraClass : ''));
    const head = WP.el('div', 'pr-screen-head');
    head.appendChild(WP.el('span', 'pr-screen-no', no));
    head.appendChild(WP.el('span', 'pr-screen-title', title));
    const sub = WP.el('span', 'pr-screen-sub', '');
    head.appendChild(sub);
    head.appendChild(WP.el('span', 'pr-spacer'));
    const tools = WP.el('span', 'pr-screen-tools');
    head.appendChild(tools);
    s.appendChild(head);
    const body = WP.el('div', 'pr-screen-body');
    s.appendChild(body);
    return { root: s, sub, tools, body };
}

function chip(label, action, arg, on) {
    const b = WP.btn(label, action, on ? 'primary' : null, arg);
    b.classList.add('wp-btn-sm', 'pr-chip');
    return b;
}

function waiting(body) {
    body.innerHTML = '';
    body.appendChild(WP.empty(failed ? failed : 'Reading the records…'));
}

function renderAll() {
    renderHead();
    renderPhone('bottom');
    renderCalls();
    renderActivity();
    renderPeople();
}

function renderHead() {
    const h = els.head;
    h.innerHTML = '';
    const back = WP.btn('', 'prClose', 'ghost');
    back.classList.add('pr-back');
    back.appendChild(icon('back'));
    back.appendChild(document.createTextNode('Number'));
    back.title = 'Back to the number\'s page';
    h.appendChild(back);

    const entry = hooks.onEntry ? hooks.onEntry(current) : null;
    const o = data ? data.owner || {} : {};
    const name = (o.name || (entry && ((entry.firstName || '') + ' ' + (entry.lastName || '')).trim())) || 'Unknown';
    const charId = o.charId || (entry && entry.charId);
    const online = data ? !!o.online : !!(entry && entry.online);
    h.appendChild(avatar(name, online, charId));

    const id = WP.el('div', 'pr-id');
    const top = WP.el('div', 'pr-id-top');
    top.appendChild(WP.el('span', 'pr-title', phoneNumber(current)));
    if (online) {
        top.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ONLINE'));
        const src = data ? o.source : entry && entry.source;
        if (src) top.appendChild(WP.el('span', 'wp-pill wp-pill-accent', '#' + src));
    } else {
        top.appendChild(WP.el('span', 'wp-pill', 'OFFLINE'));
    }
    if ((data && o.locked) || (!data && entry && entry.locked)) top.appendChild(WP.el('span', 'wp-pill', 'LOCKED'));
    id.appendChild(top);
    let sub = name + (charId ? '  ·  #' + charId : '');
    if (data && data.createdAt) {
        const d = asDate(data.createdAt);
        sub += '  ·  number since ' + d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear();
    }
    if (data && data.totals.lastAt) sub += '  ·  last used ' + ago(data.totals.lastAt);
    id.appendChild(WP.el('div', 'pr-id-sub', sub));
    h.appendChild(id);

    h.appendChild(WP.el('span', 'pr-spacer'));
    if (data && data.others.length) {
        h.appendChild(WP.el('span', 'pr-also', 'Also theirs'));
        for (const n of data.others) {
            const b = chip(phoneNumber(n.number) + (n.locked ? '  ·  locked' : ''), 'prJump', n.number, false);
            b.title = 'Open this number\'s records';
            h.appendChild(b);
        }
    }
    const again = WP.btn('Refresh', 'prRefresh', 'ghost');
    again.classList.add('wp-btn-sm');
    h.appendChild(again);
}

// ---- 01 the phone ----

function renderPhone(scroll) {
    const s = els.phone;
    const prevScroll = els.phoneApp ? els.phoneApp.scrollTop : 0;
    s.sub.textContent = data ? 'as its owner sees it' : '';
    s.body.innerHTML = '';
    const device = WP.el('div', 'pr-device');
    const os = WP.el('div', 'pr-os');
    device.appendChild(os);

    const bar = WP.el('div', 'pr-sb');
    bar.appendChild(WP.el('span', 'pr-sb-time', hm(new Date())));
    bar.appendChild(WP.el('span', 'pr-spacer'));
    bar.appendChild(WP.el('span', 'pr-sb-net', 'whip'));
    bar.appendChild(icon('signal', 'pr-sb-ico'));
    bar.appendChild(icon('battery', 'pr-sb-bat'));
    os.appendChild(bar);

    const app = WP.el('div', 'pr-app');
    els.phoneApp = app;
    os.appendChild(app);

    if (!data) {
        app.appendChild(WP.el('div', 'pr-os-empty', failed || 'Reading…'));
    } else if (phoneView && phoneView.kind === 'thread') {
        drawThread(app, os, phoneView.number);
    } else if (phoneView && phoneView.kind === 'contact') {
        drawContact(app, phoneView.number);
    } else if (phoneTab === 'recents') {
        drawRecents(app);
    } else if (phoneTab === 'contacts') {
        drawContacts(app);
    } else {
        drawThreads(app);
    }

    if (!(phoneView && phoneView.kind === 'thread')) {
        const tabs = WP.el('div', 'pr-tabbar');
        const tab = (key, label, ico, badge) => {
            const b = WP.el('button', 'pr-tab' + (phoneTab === key ? ' on' : ''));
            b.type = 'button';
            b.dataset.action = 'prTab';
            b.dataset.arg = key;
            b.appendChild(icon(ico));
            b.appendChild(WP.el('span', 'pr-tab-label', label));
            if (badge) b.appendChild(WP.el('span', 'pr-tab-badge', String(badge)));
            tabs.appendChild(b);
        };
        tab('messages', 'Messages', 'msgs', data ? data.totals.unread : 0);
        tab('recents', 'Recents', 'recents');
        tab('contacts', 'Contacts', 'contacts');
        os.appendChild(tabs);
    }

    s.body.appendChild(device);
    if (scroll === 'bottom') app.scrollTop = app.scrollHeight;
    else if (scroll === 'keep') app.scrollTop = app.scrollHeight - (els.phoneKeepFrom || 0);
    else if (scroll === 'top') app.scrollTop = 0;
    else app.scrollTop = prevScroll;
}

function appTitle(app, text, count) {
    const t = WP.el('div', 'pr-app-title');
    t.appendChild(WP.el('span', null, text));
    if (count !== undefined) t.appendChild(WP.el('span', 'pr-app-count', String(count)));
    app.appendChild(t);
}

function drawThreads(app) {
    appTitle(app, 'Messages', data.threads.length || undefined);
    if (!data.threads.length) { app.appendChild(WP.el('div', 'pr-os-empty', 'No messages')); return; }
    for (const t of data.threads) {
        const b = WP.el('button', 'pr-thread' + (focus === t.number ? ' sel' : ''));
        b.type = 'button';
        b.dataset.action = 'prOpenThread';
        b.dataset.arg = t.number;
        if (t.unread) b.appendChild(WP.el('i', 'pr-unread'));
        b.appendChild(disc(nameOf(t.number)));
        const main = WP.el('span', 'pr-t-main');
        const top = WP.el('span', 'pr-t-top');
        top.appendChild(WP.el('span', 'pr-t-name', nameOf(t.number)));
        top.appendChild(WP.el('span', 'pr-t-time', short(t.lastAt)));
        main.appendChild(top);
        main.appendChild(WP.el('span', 'pr-t-prev', t.last ? (t.last.me ? 'You: ' : '') + t.last.text : ''));
        main.appendChild(WP.el('span', 'pr-t-meta', plural(t.n, 'text') + (t.unread ? '  ·  ' + t.unread + ' unread' : '')
            + (t.held ? '  ·  ' + t.held + ' held back' : '')));
        b.appendChild(main);
        app.appendChild(b);
    }
}

function drawThread(app, os, number) {
    const head = WP.el('div', 'pr-chat-h');
    const back = WP.el('button', 'pr-os-back');
    back.type = 'button';
    back.dataset.action = 'prPhoneBack';
    back.setAttribute('aria-label', 'Back');
    back.appendChild(icon('back'));
    head.appendChild(back);
    head.appendChild(disc(nameOf(number)));
    const who = WP.el('span', 'pr-ch-who');
    who.appendChild(WP.el('span', 'pr-ch-name', nameOf(number)));
    const o = ownerOf(number);
    const saved = savedAs(number);
    who.appendChild(WP.el('span', 'pr-ch-sub', phoneNumber(number)
        + (o && o.name && o.name !== saved ? '  ·  ' + o.name : '')
        + (!saved ? '  ·  not saved' : '')));
    head.appendChild(who);
    const card = WP.el('button', 'pr-ch-card');
    card.type = 'button';
    card.dataset.action = 'prOpenContact';
    card.dataset.arg = number;
    card.title = 'Their contact page';
    card.setAttribute('aria-label', 'Their contact page');
    card.appendChild(icon('contacts'));
    head.appendChild(card);
    os.insertBefore(head, app);

    const t = threads[number];
    const list = WP.el('div', 'pr-msgs');
    if (!t || (t.loading && !t.messages.length)) {
        list.appendChild(WP.el('div', 'pr-os-empty', 'Loading…'));
    } else if (t.failed && !t.messages.length) {
        list.appendChild(WP.el('div', 'pr-os-empty', t.failed));
    } else if (!t.messages.length) {
        list.appendChild(WP.el('div', 'pr-os-empty', 'No messages'));
    } else {
        if (t.more) {
            const more = WP.el('button', 'pr-more', t.loading ? 'Loading…' : 'Earlier messages');
            more.type = 'button';
            more.dataset.action = 'prMore';
            more.dataset.arg = number;
            list.appendChild(more);
        }
        let lastDay = '';
        for (const m of t.messages) {
            const day = dayWord(m.at);
            if (day !== lastDay) { list.appendChild(WP.el('div', 'pr-day', day)); lastDay = day; }
            const wrap = WP.el('div', 'pr-bub-wrap ' + (m.me ? 'me' : 'them'));
            wrap.appendChild(WP.el('div', 'pr-bub ' + (m.me ? 'me' : 'them') + (m.held ? ' held' : ''), m.text));
            // What the desk wants beside every text: when, and whether the other side has read it. A held text never
            // reached them, so it has nothing to be read.
            let meta = hm(asDate(m.at));
            if (m.held) meta += '  ·  held back';
            else if (m.me) meta += m.readAt ? '  ·  read ' + stamp(m.readAt) : '  ·  not read yet';
            else meta += m.readAt ? '' : '  ·  unread';
            const line = WP.el('div', 'pr-bub-meta' + (m.held ? ' held' : ''), meta);
            line.title = full(m.at) + (m.readAt ? '\nRead ' + full(m.readAt) : '')
                + (!m.held ? '' : m.me ? '\nHeld back: ' + nameOf(number) + ' had blocked this phone, so it never reached them'
                    : '\nHeld back: this phone had blocked them, so its owner never saw it');
            wrap.appendChild(line);
            list.appendChild(wrap);
        }
    }
    app.classList.add('pr-app-chat');
    app.appendChild(list);

    const foot = WP.el('div', 'pr-composer');
    foot.appendChild(WP.el('span', 'pr-composer-field', 'Read only: nothing is sent from here'));
    os.appendChild(foot);
}

const OUTCOME = {
    answered:    { word: 'Answered', pill: 'ok' },
    missed:      { word: 'Not answered', pill: 'warn' },
    declined:    { word: 'Declined', pill: 'err' },
    unavailable: { word: 'Unavailable', pill: '' },
    ringing:     { word: 'Never closed', pill: '' },
};

const HELD = { word: 'Held back', pill: 'err' };

/** How it ended for the desk. A held call (the callee had blocked the caller) ended however it seemed to the caller,
 * but it did not ring for the callee, or stopped when they blocked it: that is what the desk sees first. */
function outcome(c) { return c.held ? HELD : (OUTCOME[c.status] || { word: c.status || 'Unknown', pill: '' }); }
/** Missed by this phone: it rang here and nobody answered (a held call was blocked here, not missed). */
function missedIn(c) { return !c.out && !c.held && c.status !== 'answered'; }
function talked(c) { return c.status === 'answered' && c.answeredAt && c.endedAt ? c.endedAt - c.answeredAt : 0; }
function rang(c) {
    if (c.answeredAt) return c.answeredAt - c.startedAt;
    if (c.endedAt && c.status !== 'unavailable') return c.endedAt - c.startedAt;
    return null;
}

function drawRecents(app) {
    appTitle(app, 'Recents', data.calls.length || undefined);
    if (!data.hasCalls) { app.appendChild(WP.el('div', 'pr-os-empty', 'This server has no call history yet')); return; }
    if (!data.calls.length) { app.appendChild(WP.el('div', 'pr-os-empty', 'No calls')); return; }
    for (const c of data.calls) {
        const b = WP.el('button', 'pr-rec' + (missedIn(c) ? ' missed' : '') + (focus === c.other ? ' sel' : ''));
        b.type = 'button';
        b.dataset.action = 'prCallFromPhone';
        b.dataset.arg = String(c.id);
        b.appendChild(icon(c.out ? 'out' : 'in', 'pr-rec-dir'));
        const main = WP.el('span', 'pr-t-main');
        main.appendChild(WP.el('span', 'pr-t-name', nameOf(c.other)));
        const how = c.status === 'answered' && !c.held ? (c.out ? 'Outgoing' : 'Incoming') + '  ·  ' + clock(talked(c)) : outcome(c).word;
        main.appendChild(WP.el('span', 'pr-rec-sub', how));
        b.appendChild(main);
        b.appendChild(WP.el('span', 'pr-t-time', short(c.startedAt)));
        app.appendChild(b);
    }
}

function drawContacts(app) {
    appTitle(app, 'Contacts', data.contacts.length || undefined);
    if (!data.contacts.length) { app.appendChild(WP.el('div', 'pr-os-empty', 'No contacts')); return; }
    const sorted = data.contacts.slice().sort((a, b) => String(a.name).localeCompare(String(b.name)));
    let letter = '';
    for (const c of sorted) {
        const l = (String(c.name).trim()[0] || '#').toUpperCase();
        if (l !== letter) { app.appendChild(WP.el('div', 'pr-letter', l)); letter = l; }
        const b = WP.el('button', 'pr-contact' + (focus === c.number ? ' sel' : ''));
        b.type = 'button';
        b.dataset.action = 'prOpenContact';
        b.dataset.arg = c.number;
        b.appendChild(disc(c.name));
        const main = WP.el('span', 'pr-t-main');
        main.appendChild(WP.el('span', 'pr-t-name', c.name));
        const o = ownerOf(c.number);
        main.appendChild(WP.el('span', 'pr-rec-sub', phoneNumber(c.number) + (o && o.name ? '  ·  ' + o.name : o ? '' : '  ·  not on this server')));
        b.appendChild(main);
        app.appendChild(b);
    }
}

function drawContact(app, number) {
    const head = WP.el('div', 'pr-contact-h');
    const back = WP.el('button', 'pr-os-back');
    back.type = 'button';
    back.dataset.action = 'prPhoneBack';
    back.setAttribute('aria-label', 'Back');
    back.appendChild(icon('back'));
    head.appendChild(back);
    app.appendChild(head);

    const saved = savedAs(number);
    const card = WP.el('div', 'pr-card');
    card.appendChild(disc(saved || nameOf(number), true));
    card.appendChild(WP.el('div', 'pr-card-name', saved || nameOf(number)));
    card.appendChild(WP.el('div', 'pr-card-num', phoneNumber(number)));
    const acts = WP.el('div', 'pr-card-acts');
    const act = (label, ico, action, enabled) => {
        const b = WP.el('button', 'pr-card-act');
        b.type = 'button';
        if (enabled) { b.dataset.action = action; b.dataset.arg = number; } else b.disabled = true;
        b.appendChild(icon(ico));
        b.appendChild(WP.el('span', null, label));
        acts.appendChild(b);
    };
    act('Messages', 'msgs', 'prOpenThreadOf', !!threadOf(number));
    act('Calls', 'call', 'prFocus', !!callsWith(number));
    card.appendChild(acts);
    app.appendChild(card);

    const t = threadOf(number);
    const c = callsWith(number);
    const contact = data.contacts.find((x) => x.number === number);
    const info = WP.el('div', 'pr-info');
    const row = (k, v) => {
        const r = WP.el('div', 'pr-info-row');
        r.appendChild(WP.el('span', 'pr-info-k', k));
        r.appendChild(WP.el('span', 'pr-info-v', v));
        info.appendChild(r);
    };
    row('Belongs to', ownerWords(number));
    row('Saved', contact ? stamp(contact.savedAt) : 'Not in their contacts');
    row('Texts', t ? plural(t.n, 'text') + '  ·  ' + t.sent + ' sent, ' + t.recv + ' received' : 'none');
    row('Calls', c ? plural(c.n, 'call') + '  ·  ' + lasting(c.talk) + ' talking' : 'none');
    const last = Math.max(t ? t.lastAt : 0, c ? c.lastAt : 0);
    row('Last contact', last ? stamp(last) + '  (' + ago(last) + ')' : 'never');
    const b = blockWith(number);
    if (b.mine) row('Blocked by this phone', stamp(b.mine) + '  (' + ago(b.mine) + ')');
    if (b.theirs) row('Blocked this phone', stamp(b.theirs) + '  (' + ago(b.theirs) + ')');
    app.appendChild(info);
}

// ---- 02 calls ----

function callPasses(c) {
    if (focus && c.other !== focus) return false;
    if (callFilter === 'out') return c.out;
    if (callFilter === 'in') return !c.out;
    if (callFilter === 'missed') return !c.held && c.status !== 'answered';
    if (callFilter === 'held') return !!c.held;
    return true;
}

function renderCalls() {
    const s = els.calls;
    s.tools.innerHTML = '';
    if (!data) { s.sub.textContent = ''; waiting(s.body); return; }
    const t = data.totals;
    s.sub.textContent = data.hasCalls
        ? plural(t.calls || 0, 'call') + '  ·  ' + (t.callsOut || 0) + ' made  ·  ' + (t.callsIn || 0) + ' received  ·  '
            + (t.missedIn || 0) + ' not answered  ·  ' + (t.callsHeld ? t.callsHeld + ' held back  ·  ' : '')
            + lasting(t.talk) + ' talking'
        : '';
    const filters = [['all', 'All'], ['out', 'Made'], ['in', 'Received'], ['missed', 'Not answered']];
    if (t.callsHeld) filters.push(['held', 'Held back']);   // only on a number a block touched
    for (const [key, label] of filters) {
        s.tools.appendChild(chip(label, 'prCallFilter', key, callFilter === key));
    }

    const body = s.body;
    body.innerHTML = '';
    if (focus) {
        const strip = WP.el('div', 'pr-focus');
        strip.appendChild(WP.el('span', 'pr-focus-label', 'With'));
        strip.appendChild(WP.el('span', 'pr-focus-name', nameOf(focus)));
        strip.appendChild(WP.el('span', 'pr-focus-num', phoneNumber(focus)));
        strip.appendChild(WP.el('span', 'pr-spacer'));
        const all = WP.btn('Everyone', 'prFocus', 'ghost', '');
        all.classList.add('wp-btn-sm');
        strip.appendChild(all);
        body.appendChild(strip);
    }
    if (!data.hasCalls) { body.appendChild(WP.empty('No call history: the phone has not run on this server yet.')); return; }

    const rows = data.calls.filter(callPasses);
    if (!rows.length) { body.appendChild(WP.empty(data.calls.length ? 'No calls like that' : 'No calls')); return; }

    const table = WP.el('div', 'pr-table');
    const head = WP.el('div', 'pr-tr pr-th');
    for (const h of ['When', '', 'Who', 'How it ended', 'Rang', 'Talked']) head.appendChild(WP.el('span', null, h));
    table.appendChild(head);
    for (const c of rows) {
        const r = WP.el('button', 'pr-tr' + (callOpen === c.id ? ' open' : ''));
        r.type = 'button';
        r.dataset.action = 'prCall';
        r.dataset.arg = String(c.id);
        r.appendChild(WP.el('span', 'pr-td-when', stamp(c.startedAt)));
        const dir = icon(c.out ? 'out' : 'in', 'pr-dir' + (missedIn(c) ? ' missed' : ''));
        dir.title = c.out ? 'This phone called them' : 'They called this phone';
        r.appendChild(dir);
        const who = WP.el('span', 'pr-td-who');
        who.appendChild(WP.el('span', 'pr-td-name', nameOf(c.other)));
        who.appendChild(WP.el('span', 'pr-td-num', phoneNumber(c.other)));
        r.appendChild(who);
        const o = outcome(c);
        r.appendChild(WP.el('span', 'pr-td-st', ''));
        r.lastChild.appendChild(WP.el('span', 'wp-pill' + (o.pill ? ' wp-pill-' + o.pill : ''), o.word.toUpperCase()));
        const rg = rang(c);
        r.appendChild(WP.el('span', 'pr-td-num pr-td-r', rg === null ? '—' : lasting(rg)));
        r.appendChild(WP.el('span', 'pr-td-num pr-td-r', c.status === 'answered' ? clock(talked(c)) : '—'));
        table.appendChild(r);
        if (callOpen === c.id) table.appendChild(callDetail(c));
    }
    body.appendChild(table);
    if (data.callsMore) body.appendChild(WP.el('div', 'pr-note', 'The newest ' + data.calls.length + ' of ' + plural(data.totals.calls, 'call') + '.'));
}

function callDetail(c) {
    const d = WP.el('div', 'pr-call');
    const grid = WP.el('div', 'pr-call-grid');
    const row = (k, v) => {
        grid.appendChild(WP.el('span', 'pr-info-k', k));
        grid.appendChild(WP.el('span', 'pr-info-v', v));
    };
    const me = phoneNumber(current) + '  (this phone)';
    const them = nameOf(c.other) + '  ·  ' + phoneNumber(c.other);
    row('Call', '#' + c.id);
    row('From', c.out ? me : them);
    row('To', c.out ? them : me);
    row('Their number', ownerWords(c.other));
    row('Started', full(c.startedAt));
    row('Answered', c.answeredAt ? full(c.answeredAt) + '  (rang ' + lasting(c.answeredAt - c.startedAt) + ')' : 'never');
    row('Ended', c.endedAt ? full(c.endedAt) : 'not recorded');
    if (c.status === 'answered') row('Talked', clock(talked(c)) + '  (' + lasting(talked(c)) + ')');
    row('How it ended', explain(c));
    d.appendChild(grid);
    const acts = WP.el('div', 'wp-actions-row');
    if (focus !== c.other) acts.appendChild(WP.btn('Everything with them', 'prFocus', null, c.other));
    const o = ownerOf(c.other);
    if (o && !o.retired && c.other !== current) acts.appendChild(WP.btn('Open their phone', 'prJump', null, c.other));
    if (acts.children.length) d.appendChild(acts);
    return d;
}

function explain(c) {
    const them = nameOf(c.other);
    if (c.held) {
        // Nothing tells the caller (whip_phone): to them it ended as an unblocked call would have.
        const seemed = (OUTCOME[c.status] || { word: c.status || 'Unknown' }).word;
        return c.out
            ? them + ' had blocked this phone, so it did not ring for them (or stopped when they blocked it). This phone '
                + 'was not told: to it, the call ended "' + seemed + '".'
            : 'This phone had blocked ' + them + ', so it did not ring here (or stopped when the block was made) and is '
                + 'not in its Recents. ' + them + ' was not told: to them, the call ended "' + seemed + '".';
    }
    switch (c.status) {
    case 'answered':
        return c.endedAt ? 'Picked up and talked.' : 'Picked up; no end was recorded (still going, or the server stopped).';
    case 'missed':
        return c.out ? 'No one answered: it rang out, ' + them + ' was busy, or this phone hung up first.'
            : 'This phone did not answer: it rang out, it was busy, or ' + them + ' hung up first.';
    case 'declined':
        return c.out ? them + ' declined it.' : 'This phone declined it.';
    case 'unavailable':
        return c.out ? them + '\'s phone was off or not on them: it never rang.'
            : 'This phone was off or not on its owner: it never rang.';
    case 'ringing':
        return 'Never closed: the server stopped while it rang.';
    default:
        return c.status || 'Unknown';
    }
}

// ---- 03 activity ----

function bars(title, items, labelEvery) {
    const card = WP.el('div', 'pr-chart');
    card.appendChild(WP.el('div', 'pr-chart-title', title));
    const max = Math.max(1, ...items.map((i) => i.msgs + i.calls));
    const row = WP.el('div', 'pr-bars');
    items.forEach((it, i) => {
        const col = WP.el('div', 'pr-bar-col');
        col.title = it.tip;
        const area = WP.el('div', 'pr-bar-area');
        const stack = WP.el('div', 'pr-bar');
        stack.style.height = Math.round(((it.msgs + it.calls) / max) * 100) + '%';
        if (it.calls) {
            const c = WP.el('div', 'pr-bar-calls');
            c.style.height = Math.round((it.calls / (it.msgs + it.calls)) * 100) + '%';
            stack.appendChild(c);
        }
        if (!(it.msgs + it.calls)) stack.classList.add('pr-bar-none');
        area.appendChild(stack);
        col.appendChild(area);
        col.appendChild(WP.el('span', 'pr-bar-label', i % labelEvery === 0 ? it.label : ''));
        row.appendChild(col);
    });
    card.appendChild(row);
    return card;
}

function renderActivity() {
    const s = els.activity;
    if (!data) { s.sub.textContent = ''; waiting(s.body); return; }
    const t = data.totals;
    s.sub.textContent = t.firstAt ? 'first used ' + stamp(t.firstAt) + '  ·  last ' + ago(t.lastAt) : 'never used';
    const body = s.body;
    body.innerHTML = '';

    const stats = WP.el('div', 'wp-stats pr-stats');
    stats.appendChild(WP.stat('Texts', String(t.messages || 0), (t.sent || 0) + ' sent  ·  ' + (t.recv || 0) + ' received'));
    stats.appendChild(WP.stat('Calls', String(t.calls || 0), (t.callsOut || 0) + ' made  ·  ' + (t.callsIn || 0) + ' received'));
    stats.appendChild(WP.stat('Talking', lasting(t.talk), plural(t.answered || 0, 'answered call')));
    stats.appendChild(WP.stat('People', String(t.people || 0), plural(t.contacts || 0, 'contact') + ' saved'));
    body.appendChild(stats);

    const charts = WP.el('div', 'pr-charts');
    const hours = data.hours.length === 24 ? data.hours : Array.from({ length: 24 }, () => ({ msgs: 0, calls: 0 }));
    charts.appendChild(bars('By hour of day', hours.map((h, i) => ({
        msgs: h.msgs || 0, calls: h.calls || 0, label: two(i),
        tip: two(i) + ':00 – ' + two(i) + ':59  ·  ' + plural(h.msgs || 0, 'text') + ', ' + plural(h.calls || 0, 'call'),
    })), 3));
    // The last fourteen days, oldest first, today last (the server counts days on this PC's clock).
    const today = Math.floor((Date.now() / 1000 - new Date().getTimezoneOffset() * 60) / 86400);
    const byDay = {};
    for (const d of data.days) byDay[d.day] = d;
    const days = [];
    for (let i = 13; i >= 0; i--) {
        const dn = today - i;
        const d = byDay[dn] || { msgs: 0, calls: 0 };
        const date = new Date((dn * 86400 + new Date().getTimezoneOffset() * 60) * 1000 + 43200e3);
        days.push({ msgs: d.msgs || 0, calls: d.calls || 0, label: i === 0 ? 'Today' : DAYS[date.getDay()].slice(0, 2),
            tip: (i === 0 ? 'Today' : DAYS[date.getDay()] + ' ' + date.getDate() + ' ' + MONTHS[date.getMonth()])
                + '  ·  ' + plural(d.msgs || 0, 'text') + ', ' + plural(d.calls || 0, 'call') });
    }
    charts.appendChild(bars('Last 14 days', days, 1));
    body.appendChild(charts);
    const key = WP.el('div', 'pr-key');
    key.appendChild(WP.el('i', 'pr-key-msgs'));
    key.appendChild(WP.el('span', null, 'Texts'));
    key.appendChild(WP.el('i', 'pr-key-calls'));
    key.appendChild(WP.el('span', null, 'Calls'));
    key.appendChild(WP.el('span', 'pr-key-note', 'Hours and days on this PC\'s clock'));
    body.appendChild(key);
}

// ---- 04 people ----

/** One person's row: their face, who really owns the number, what this phone saved it as, then `stats`. Picked,
 * it offers Open their phone, unless `go` is false (they have a row lower down that offers it). */
function personRow(body, number, saved, stats, go) {
    const o = ownerOf(number);
    const row = WP.el('button', 'pr-person' + (focus === number ? ' active' : ''));
    row.type = 'button';
    row.dataset.action = 'prFocus';
    row.dataset.arg = focus === number ? '' : number;
    row.appendChild(avatar((o && o.name) || saved || '#', o && !o.retired ? !!o.online : undefined, o && !o.retired ? o.charId : undefined));
    const main = WP.el('span', 'pr-person-main');
    const top = WP.el('span', 'pr-person-top');
    top.appendChild(WP.el('span', 'pr-person-name', (o && o.name) || saved || phoneNumber(number)));
    if (!o) top.appendChild(WP.el('span', 'wp-pill wp-pill-warn', 'NOT ON SERVER'));
    else if (o.retired) top.appendChild(WP.el('span', 'wp-pill', 'RETIRED'));
    else if (o.online) top.appendChild(WP.el('span', 'wp-pill wp-pill-ok', 'ONLINE'));
    main.appendChild(top);
    main.appendChild(WP.el('span', 'pr-person-sub', phoneNumber(number)
        + (saved ? (o && o.name && o.name !== saved ? '  ·  saved as "' + saved + '"' : '') : '  ·  not saved')));
    main.appendChild(WP.el('span', 'pr-person-stats', stats));
    row.appendChild(main);
    body.appendChild(row);
    if (go !== false && focus === number && o && !o.retired && number !== current) {
        const wrap = WP.el('div', 'pr-person-go');
        wrap.appendChild(WP.btn('Open their phone', 'prJump', 'primary', number));
        body.appendChild(wrap);
    }
}

/** A group's label, with how many are in it. */
function groupTitle(body, title, n) {
    const t = WP.el('div', 'pr-group');
    t.appendChild(WP.el('span', null, title));
    t.appendChild(WP.el('span', 'pr-group-n', String(n)));
    body.appendChild(t);
}

function renderPeople() {
    const s = els.people;
    s.tools.innerHTML = '';
    if (!data) { s.sub.textContent = ''; waiting(s.body); return; }
    const list = people();
    s.sub.textContent = String(list.length);
    s.tools.appendChild(chip('Most', 'prPeopleSort', 'most', peopleSort === 'most'));
    s.tools.appendChild(chip('Recent', 'prPeopleSort', 'recent', peopleSort === 'recent'));
    const body = s.body;
    body.innerHTML = '';
    els.peopleBody = body;

    // Its blocks first, both ways, the latest first: who this phone keeps out, and who keeps it out.
    const listed = new Set(list.map((p) => p.number));
    const blocks = (title, rows, words) => {
        if (!rows.length) return;
        groupTitle(body, title, rows.length);
        for (const b of rows) {
            personRow(body, b.number, savedAs(b.number), words + ' ' + stamp(b.at) + '  ·  ' + ago(b.at), !listed.has(b.number));
        }
    };
    blocks('Blocked by this phone', data.blocks, 'blocked');
    blocks('Blocked this phone', data.blockedBy, 'blocked it');
    if (data.blocks.length || data.blockedBy.length) groupTitle(body, 'Everyone', list.length);

    if (!list.length) { body.appendChild(WP.empty('No one: it has texted, called and saved nobody.')); return; }
    for (const p of list) {
        const bits = [];
        if (p.texts) bits.push(plural(p.texts, 'text'));
        if (p.calls) bits.push(plural(p.calls, 'call'));
        if (p.unread) bits.push(p.unread + ' unread');
        bits.push(p.lastAt ? ago(p.lastAt) : 'only saved');
        const b = blockWith(p.number);
        if (b.mine) bits.push('blocked by this phone');
        if (b.theirs) bits.push('blocked this phone');
        personRow(body, p.number, p.saved, bits.join('  ·  '));
    }
}

// ---- the public face ----

export const PhoneRecords = {
    /** Build into `root` (hidden until open). hooks: { onClose(), onEntry(number) }. */
    mount(root, h) {
        hooks = h || {};
        els = {};
        root.innerHTML = '';
        els.root = root;
        els.head = WP.el('div', 'pr-head');
        root.appendChild(els.head);
        const grid = WP.el('div', 'pr-grid');
        els.phone = screen('01', 'Phone', 'pr-s-phone');
        els.calls = screen('02', 'Calls', 'pr-s-calls');
        els.activity = screen('03', 'Activity', 'pr-s-activity');
        els.people = screen('04', 'People', 'pr-s-people');
        for (const s of [els.phone, els.calls, els.activity, els.people]) grid.appendChild(s.root);
        root.appendChild(grid);
        if (current) renderAll();
    },

    open(number) { load(String(number)); },

    isOpen: () => current !== null,

    number: () => current,

    close() {
        current = null;
        data = null;
        token++;
    },

    /** Escape inside the dashboard: the phone's page first, then the person, then false (leave it). */
    escape() {
        if (phoneView) { PhoneRecords.actions.prPhoneBack(); return true; }
        if (callOpen !== null) { callOpen = null; renderCalls(); return true; }
        if (focus) { setFocus(null); return true; }
        return false;
    },

    actions: {
        prClose: () => { if (hooks.onClose) hooks.onClose(); },
        prRefresh: () => { if (current) load(current); },
        prJump: (el) => {
            const n = String(el.dataset.arg || '').replace(/[^0-9]/g, '');
            if (n.length === 10) load(n);
        },
        prTab: (el) => {
            phoneTab = el.dataset.arg || 'messages';
            phoneView = null;
            renderPhone('top');
        },
        prPhoneBack: () => {
            phoneView = null;
            setFocus(null, 'phone');
        },
        prOpenThread: (el) => openThread(String(el.dataset.arg)),
        prOpenThreadOf: (el) => { phoneTab = 'messages'; openThread(String(el.dataset.arg)); },
        prOpenContact: (el) => {
            const n = String(el.dataset.arg);
            phoneTab = 'contacts';
            phoneView = { kind: 'contact', number: n };
            setFocus(n, 'phone');
        },
        prMore: (el) => {
            els.phoneKeepFrom = els.phoneApp ? els.phoneApp.scrollHeight - els.phoneApp.scrollTop : 0;
            loadThread(String(el.dataset.arg), true);
            renderPhone('keep');
        },
        prCallFromPhone: (el) => {
            const c = data && data.calls.find((x) => String(x.id) === el.dataset.arg);
            if (!c) return;
            setFocus(c.other, 'phone');
            callOpen = c.id;
            renderCalls();
        },
        prCall: (el) => {
            const id = Number(el.dataset.arg);
            callOpen = callOpen === id ? null : id;
            renderCalls();
        },
        prCallFilter: (el) => { callFilter = el.dataset.arg || 'all'; callOpen = null; renderCalls(); },
        prFocus: (el) => setFocus(el.dataset.arg ? String(el.dataset.arg) : null),
        prPeopleSort: (el) => { peopleSort = el.dataset.arg === 'recent' ? 'recent' : 'most'; renderPeople(); },
    },
};
