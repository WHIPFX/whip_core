// ========================================
// EVENT MONITOR — the /whip panel's Monitor section
//
// ONE SCREEN: the live feed, Sentinel and Events together. What an admin asks, in the order they ask it:
//
//   Is anything wrong?   four tiles across the top: traffic a minute (the last ten minutes as bars), problems
//                        (refused and errors, last 10 minutes), the players sending, and Sentinel in words
//   What is happening?   the feed, newest first: the time, how it went, WHAT in words (Store move — the key
//                        whip_core:server:storeMove is in its detail), whose, and why when it was refused.
//                        Everything or Problems. Stat updates (each player's game reporting its stats, most of the
//                        traffic) are hidden until asked for. Runs of the same thing fold into one row (×N)
//   Who, and what?       the rail: the busiest players, the busiest events, Sentinel's strikes and detections;
//                        each opens the feed on itself
//   In depth             All events (the registry: calls, refused, rate limits) and Sentinel's watched keys, in
//                        the feed's place, with the way back
//
// The feed engine (coalescing, the no-yank prepend, one paint per batch) is the one it had. Data still arrives on
// this module's own live-stream router actions (emNewEvents, snNewDetection, …) — the one documented exception to
// sections receiving everything via wpSectionData, because the stream exists whether or not the section is showing.
//
// Rendering rule: data strings (event names, player names, reasons, got/expected) are inserted via textContent,
// never innerHTML — player names pass through here.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { WhipPanel, WP } from './whip-panel.js';
import { uiIcon } from './ui-icons.js';
import { plural, ago, timeOfDay } from './wp/format.js';

// ---- what the stream is ----

// Each player's game reporting its stats, all the time: most of the traffic, and rarely the point.
const STAT_UPDATES = new Set(['reportVitals', 'reportStatLive', 'reportStatBurn']);

// An admin tool's events start with its letters (vmSetStat): said as the tool (Vehicles: set stat).
const TOOL_PREFIX = {
    vm: 'Vehicles', vw: 'Vehicle wizard', gm: 'Garages', gw: 'Garage wizard', sm: 'Shops', sw: 'Shop wizard',
    cm: 'Containers', cw: 'Container wizard', jm: 'Jobs', jw: 'Job wizard', pm: 'Phones', plm: 'Players',
    zm: 'Zones', ze: 'Zone editor', zw: 'Zone wizard', dm: 'Doors', dw: 'Door wizard', em: 'Monitor', sn: 'Sentinel',
};

const RECENT_S = 300;    // "most active": the last five minutes
const WINDOW_S = 600;    // problems and the bars: the last ten minutes
const GROUP_CAP = 200;   // rendered groups; matches are still counted past it
const RAIL_LINES = 4;    // the busiest players and events: four each, so the rail fits a 1080p panel
const OK_CAP = 600;      // the logs kept here: the server's two rings' worth, kept apart as there, so a flood
const PROB_CAP = 500;    // of successes never pushes the problems out

function shortName(ev) {
    const parts = String(ev).split(':');
    return parts[parts.length - 1];
}
function resourceOf(ev) { return String(ev).split(':')[0]; }
function isStat(e) { return STAT_UPDATES.has(shortName(e.event)); }
function isTamper(e) { return typeof e.event === 'string' && e.event.startsWith('sentinel:'); }
function isProblem(e) { return e.status !== 'ok'; }

function humanize(s) {
    const t = String(s).replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[_-]+/g, ' ').trim().toLowerCase();
    return t ? t.charAt(0).toUpperCase() + t.slice(1) : '?';
}

/** An event key in words: whip_core:server:storeMove → Store move; whip_core:vmCatalog → Vehicles: catalog. */
const labelCache = new Map();
function eventLabel(ev) {
    let l = labelCache.get(ev);
    if (l) return l;
    const str = String(ev);
    if (str.startsWith('sentinel:')) {
        l = 'Tampered with ' + str.slice(9);
    } else {
        const parts = str.split(':');
        const name = parts[parts.length - 1];
        const tool = /^([a-z]{2,3})([A-Z].*)$/.exec(name);
        if (tool && TOOL_PREFIX[tool[1]]) l = TOOL_PREFIX[tool[1]] + ': ' + humanize(tool[2]).toLowerCase();
        else if (parts.length > 2 && parts[1] !== 'server' && parts[1] !== 'client') l = humanize(parts[1]) + ': ' + humanize(name).toLowerCase();
        else l = humanize(name);
    }
    labelCache.set(ev, l);
    return l;
}

/** How long ago, by the server's clock, to the second under a minute: the feed is live. */
function since(t) {
    return ago(t, { now: serverNow() * 1000, seconds: true });
}

function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function initials(name) {
    const w = String(name || '?').trim().split(/\s+/);
    return ((w[0] || '?').charAt(0) + (w.length > 1 ? w[w.length - 1].charAt(0) : '')).toUpperCase();
}

function face(name) {
    const a = el('span', 'wp-avatar mon-av');
    a.appendChild(el('span', 'wp-avatar-initials', initials(name)));
    return a;
}

// The shell's magnifier (whip-panel.js SEARCH_ICON), for the two search boxes here.
const SEARCH_ICON = '<svg viewBox="0 0 17 17" width="17" height="17" fill="none" stroke="currentColor"'
    + ' stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="5.5"/><path d="M11.2 11.2L15.5 15.5"/></svg>';

/** A search box in the house look: the label, its magnifier, the input. */
function searchBox(placeholder, value, onInput) {
    const box = el('label', 'wp-search mon-search');
    const icon = el('span', 'wp-search-icon');
    icon.innerHTML = SEARCH_ICON;   // fixed markup, no data
    box.appendChild(icon);
    const input = el('input', 'wp-input');
    input.type = 'text';
    input.placeholder = placeholder;
    input.value = value || '';
    input.addEventListener('input', () => onInput(input.value));
    box.appendChild(input);
    return { box, input };
}

function sigOf(e) {
    // reason is part of the signature ON PURPOSE: coalescing two rejections with different
    // reasons under one row would hide exactly what this tool exists to show. The spam
    // case (identical event+src+status+reason) still collapses.
    return `${e.event}|${e.src}|${e.status}|${e.reason || ''}`;
}

// ---- state (module-level; a fresh snapshot resets only the view subset — see emAdopt) ----

let emOpen = false;              // the Monitor section is the shell's active section
let emView = 'feed';             // the main area: 'feed' | 'events' | 'keys'
let emPaused = false;

let okLog = [];                  // the stream, oldest-first, seq-stamped: successes...
let probLog = [];                // ...and refusals and errors, apart (see PROB_CAP)
let emLastSeq = 0;               // monotonic guard: drop live entries we already hold
let emRegistry = [];
let skew = 0;                    // the server's clock less ours, from the live batches

// the feed's view (reset on open, but for showStats, which is the admin's to keep)
let showStats = false;
let onlyProblems = false;
let emFacetEvent = null;         // event-name facet
let emFacetSrc = null;           // { src, name } facet
let emFeedSearch = '';
let emMatchTotal = 0;
let emExpandedRow = null;        // DOM element with the open detail

// sentinel
let snData = null;               // { registry, log, strikes, enabled, autoKick }
let snUnseen = 0;

// the events table
let emEventsSearch = '';
let emEventsSort = { col: 'calls', dir: 'desc' };

// the glance and the rail redraw once a second (tick), not per batch: "the last minute" slides on by itself
let tickTimer = null;

function serverNow() { return Date.now() / 1000 + skew; }

/** Every entry, newest first: the two logs merged by seq. */
function* newestFirst() {
    let i = okLog.length - 1, j = probLog.length - 1;
    while (i >= 0 || j >= 0) {
        if (j < 0 || (i >= 0 && okLog[i].seq > probLog[j].seq)) yield okLog[i--];
        else yield probLog[j--];
    }
}

// ---- skeleton (built once per open) ----

const els = {};
const tiles = {};
let feedListEl = null, feedNewChipEl = null;

function emBuildSkeleton(root) {
    root.innerHTML = '';
    const mon = el('div', 'mon');

    els.tiles = el('div', 'wp-stats mon-tiles');
    mon.appendChild(els.tiles);
    buildTiles();

    const body = el('div', 'mon-body');
    els.main = el('div', 'mon-main');
    els.rail = el('div', 'mon-rail');
    body.appendChild(els.main);
    body.appendChild(els.rail);
    mon.appendChild(body);
    root.appendChild(mon);

    els.views = { feed: buildFeedView(), events: el('div', 'mon-card mon-view'), keys: el('div', 'mon-card mon-view') };
    for (const k of Object.keys(els.views)) els.main.appendChild(els.views[k]);
    buildRail();
}

// ---- the glance ----

function tile(key, label, onClick) {
    const t = el('button', 'wp-stat mon-tile');
    t.type = 'button';
    t.appendChild(el('div', 'wp-stat-label', label));
    const row = el('div', 'mon-tile-row');
    const value = el('div', 'wp-stat-value');
    row.appendChild(value);
    t.appendChild(row);
    const sub = el('div', 'wp-stat-sub');
    t.appendChild(sub);
    t.addEventListener('click', onClick);
    tiles[key] = { root: t, row, value, sub };
    els.tiles.appendChild(t);
    return tiles[key];
}

function buildTiles() {
    const traffic = tile('traffic', 'Traffic', () => { setView('feed'); setProblems(false); });
    traffic.spark = el('div', 'mon-spark');
    traffic.spark.title = 'The last ten minutes, a bar a minute';
    traffic.bars = [];
    for (let i = 0; i < 10; i++) {
        const b = el('span', 'mon-bar');
        const p = el('span', 'mon-bar-prob');
        b.appendChild(p);
        traffic.spark.appendChild(b);
        traffic.bars.push({ b, p });
    }
    traffic.row.appendChild(traffic.spark);
    tile('problems', 'Problems', () => { setView('feed'); setProblems(true); });
    tile('players', 'Players', () => setView('feed'));
    tile('sentinel', 'Sentinel', () => setView('keys'));
}

/** Everything the glance and the rail say, from the logs: one walk, newest first, back ten minutes. */
function computeRecent() {
    const now = serverNow();
    const r = {
        perMin: 0, statPerMin: 0, refused: 0, errors: 0, tamper: 0,
        bars: Array.from({ length: 10 }, () => ({ n: 0, p: 0 })),
        players: new Map(), events: new Map(), sending: new Set(),
    };
    for (const e of newestFirst()) {
        const age = now - e.t;
        if (age > WINDOW_S) break;
        const stat = isStat(e);
        const shown = showStats || !stat;
        if (e.src) r.sending.add(e.src);
        if (age <= 60) { if (shown) r.perMin += 1; else r.statPerMin += 1; }
        if (shown) {
            const bucket = Math.min(9, Math.max(0, Math.floor(age / 60)));
            const bar = r.bars[9 - bucket];
            bar.n += 1;
            if (isProblem(e)) bar.p += 1;
        }
        if (isProblem(e)) {
            if (isTamper(e)) r.tamper += 1;
            else if (e.status === 'error') r.errors += 1;
            else r.refused += 1;
        }
        if (age <= RECENT_S && shown) {
            if (e.src) {
                const p = r.players.get(e.src) || { src: e.src, name: e.name || 'Unknown', n: 0, p: 0 };
                p.n += 1;
                if (isProblem(e)) p.p += 1;
                r.players.set(e.src, p);
            }
            const v = r.events.get(e.event) || { event: e.event, n: 0, p: 0 };
            v.n += 1;
            if (isProblem(e)) v.p += 1;
            r.events.set(e.event, v);
        }
    }
    return r;
}

function setTone(t, tone) {
    t.root.classList.toggle('wp-stat-up', tone === 'up');
    t.root.classList.toggle('wp-stat-down', tone === 'down');
}

function renderTiles(r) {
    const tr = tiles.traffic;
    tr.value.textContent = r.perMin + ' a minute';
    tr.sub.textContent = showStats ? 'in the last minute, stat updates included'
        : r.statPerMin ? 'in the last minute, and ' + r.statPerMin + ' stat updates (hidden)' : 'in the last minute';
    const max = Math.max(1, ...r.bars.map((b) => b.n));
    r.bars.forEach((b, i) => {
        tr.bars[i].b.style.height = Math.max(4, Math.round(b.n / max * 100)) + '%';
        tr.bars[i].b.classList.toggle('mon-bar-empty', b.n === 0);
        tr.bars[i].p.style.height = b.n ? Math.round(b.p / b.n * 100) + '%' : '0';
    });

    const pr = tiles.problems;
    const total = r.refused + r.errors + r.tamper;
    pr.value.textContent = total ? String(total) : 'None';
    const bits = [];
    if (r.refused) bits.push(plural(r.refused, 'refused', 'refused'));
    if (r.errors) bits.push(plural(r.errors, 'error'));
    if (r.tamper) bits.push(plural(r.tamper, 'tamper', 'tampers'));
    pr.sub.textContent = (bits.length ? bits.join(' · ') : 'nothing refused, nothing broke') + ', last 10 minutes';
    setTone(pr, total ? 'down' : 'up');

    const pl = tiles.players;
    pl.value.textContent = String(r.sending.size);
    let top = null;
    for (const p of r.players.values()) if (!top || p.n > top.n) top = p;
    pl.sub.textContent = r.sending.size ? 'sending in the last 10 minutes' + (top ? ' · busiest ' + top.name : '')
        : 'nobody has sent anything in 10 minutes';

    const sn = tiles.sentinel;
    if (!snData) {
        sn.value.textContent = '…';
        sn.sub.textContent = 'waiting for Sentinel';
        setTone(sn, null);
    } else {
        const now = serverNow();
        const recent = (snData.log || []).filter((d) => now - d.t <= WINDOW_S).length;
        const keys = (snData.registry || []).filter((k) => k.armed).length;
        if (!snData.enabled) {
            sn.value.textContent = 'Off';
            sn.sub.textContent = 'nothing is watched for tampering';
            setTone(sn, 'down');
        } else if (recent) {
            sn.value.textContent = plural(recent, 'detection');
            sn.sub.textContent = 'in the last 10 minutes · ' + plural((snData.strikes || []).length, 'player') + ' struck';
            setTone(sn, 'down');
        } else {
            sn.value.textContent = 'Watching';
            sn.sub.textContent = plural(keys, 'key') + ' · ' + (snData.autoKick ? 'kicks at ' + snData.autoKick + ' strikes' : 'logs only, kicks nobody');
            setTone(sn, null);
        }
        sn.root.classList.toggle('mon-tile-alert', snUnseen > 0);
    }
}

// ---- the feed ----

function buildFeedView() {
    const v = el('div', 'mon-card mon-view mon-feed');

    const head = el('div', 'mon-card-head');
    els.kind = WP.tabs({
        id: 'mon-kind', inline: true, active: 'all',
        tabs: [{ key: 'all', label: 'Everything' }, { key: 'problems', label: 'Problems' }],
        onChange: (k) => setProblems(k === 'problems'),
    });
    els.kindProblems = el('span', 'mon-tab-count');
    const pTab = els.kind.root.querySelector('[data-arg="problems"]');
    if (pTab) pTab.appendChild(els.kindProblems);
    head.appendChild(els.kind.root);
    head.appendChild(el('span', 'wp-toolbar-spacer'));

    els.statBtn = el('button', 'wp-toggle');
    els.statBtn.type = 'button';
    els.statBtn.title = 'Each player\'s game reporting its stats: most of the traffic';
    els.statBtn.addEventListener('click', () => { showStats = !showStats; paintStatBtn(); refilter(); });
    head.appendChild(els.statBtn);

    els.pause = WP.btn('Pause', null, 'ghost');
    els.pause.classList.add('wp-btn-sm');
    els.pause.addEventListener('click', emTogglePause);
    head.appendChild(els.pause);
    const clear = WP.btn('Clear', null, 'ghost');
    clear.classList.add('wp-btn-sm');
    clear.title = 'Empty the feed for every admin watching (the counts in All events stay)';
    clear.addEventListener('click', () => nuiCallback('emClearLog', {}));
    head.appendChild(clear);
    v.appendChild(head);

    // The search, what narrows the feed, and how much it shows: one line under the head.
    const bar = el('div', 'mon-facets-bar');
    const search = searchBox('Search what, who or why…', '', (val) => { emFeedSearch = val.toLowerCase(); refilter(); });
    els.search = search.input;
    bar.appendChild(search.box);
    els.facets = el('div', 'mon-facets');
    bar.appendChild(els.facets);
    v.appendChild(bar);

    const cols = el('div', 'mon-row mon-cols');
    for (const c of ['Time', '', 'What', 'Who', 'Outcome']) cols.appendChild(el('span', null, c));
    v.appendChild(cols);

    const wrap = el('div', 'mon-list-wrap');
    feedListEl = el('div', 'mon-list');
    feedListEl.addEventListener('scroll', () => { if (feedListEl.scrollTop <= 4) feedCtl.atTopSettled(); });
    wrap.appendChild(feedListEl);
    feedNewChipEl = el('button', 'mon-new-chip');
    feedNewChipEl.style.display = 'none';
    feedNewChipEl.addEventListener('click', () => { feedListEl.scrollTop = 0; });
    wrap.appendChild(feedNewChipEl);
    v.appendChild(wrap);

    paintStatBtn();
    return v;
}

function paintStatBtn() {
    if (!els.statBtn) return;
    els.statBtn.textContent = 'Stat updates · ' + (showStats ? 'shown' : 'hidden');
    els.statBtn.classList.toggle('active', showStats);
}

function setProblems(on) {
    onlyProblems = on;
    if (els.kind) els.kind.set(on ? 'problems' : 'all');
    refilter();
}

// ---- the no-yank prepend controller ----

function makeFeedController(getListEl, getChipEl) {
    return {
        pending: 0,
        // Prepend a row without moving what the user is reading: at the top, new rows
        // appear naturally and the DOM is trimmed; scrolled down, the scroll offset is
        // compensated exactly and the row counts into the "N new" chip instead.
        // A BATCH READS THE LAYOUT ONCE. The live feed arrives as up to 200 entries four times a second,
        // and reading scrollTop/scrollHeight straight after each insert would force a layout per row. Between beginBatch and endBatch rows only go in; endBatch compensates once.
        batch: null,
        beginBatch() {
            const list = getListEl();
            this.batch = list ? { atTop: list.scrollTop <= 4, before: list.scrollHeight, added: 0 } : null;
        },
        endBatch() {
            const b = this.batch;
            this.batch = null;
            const list = getListEl();
            if (!b || !list || b.added === 0) return;
            if (b.atTop) {
                this.trim(list);
            } else {
                list.scrollTop += (list.scrollHeight - b.before);
                this.pending += b.added;
                this.showChip();
            }
        },
        prepend(row) {
            const list = getListEl();
            if (!list) return;
            if (this.batch) {
                list.insertBefore(row, list.firstChild);
                this.batch.added += 1;
                return;
            }
            const atTop = list.scrollTop <= 4;
            const before = list.scrollHeight;
            list.insertBefore(row, list.firstChild);
            if (atTop) {
                this.trim(list);
            } else {
                list.scrollTop += (list.scrollHeight - before);
                this.pending += 1;
                this.showChip();
            }
        },
        // Trimming is DEFERRED while scrolled down — never delete rows someone may be
        // reading. The scroll handler calls atTopSettled() when they come back.
        trim(list) {
            while (list.children.length > GROUP_CAP) list.removeChild(list.lastChild);
        },
        atTopSettled() {
            const list = getListEl();
            if (list) this.trim(list);
            this.pending = 0;
            this.hideChip();
        },
        showChip() {
            const chip = getChipEl();
            if (!chip) return;
            chip.textContent = `${this.pending} new ↑`;
            chip.style.display = 'block';
        },
        hideChip() {
            const chip = getChipEl();
            if (chip) chip.style.display = 'none';
        },
        reset() { this.pending = 0; this.hideChip(); },
    };
}

const feedCtl = makeFeedController(() => feedListEl, () => feedNewChipEl);

// ---- filters ----

function emEntryMatches(e) {
    if (!showStats && isStat(e)) return false;
    if (onlyProblems && !isProblem(e)) return false;
    if (emFacetEvent && e.event !== emFacetEvent) return false;
    if (emFacetSrc && e.src !== emFacetSrc.src) return false;
    if (emFeedSearch) {
        const hay = `${e.event} ${eventLabel(e.event)} ${e.name || ''} ${e.reason || ''}`.toLowerCase();
        if (!hay.includes(emFeedSearch)) return false;
    }
    return true;
}

/** What Escape and "Show everything" clear: not the stat updates, which are the admin's to keep. */
function emHasActiveFilters() {
    return onlyProblems || emFacetEvent !== null || emFacetSrc !== null || emFeedSearch !== '';
}

function emSetEventFacet(ev) {
    emFacetEvent = ev;
    setView('feed');
    refilter();
}

function emSetSrcFacet(src, name) {
    emFacetSrc = emFacetSrc && emFacetSrc.src === src ? null : { src, name };
    setView('feed');
    refilter();
}

function emClearAllFilters() {
    onlyProblems = false;
    emFacetEvent = null;
    emFacetSrc = null;
    emFeedSearch = '';
    if (els.search) els.search.value = '';
    if (els.kind) els.kind.set('all');
    refilter();
}

function refilter() {
    renderFacets();
    renderFeed();
    tick();
}

function renderFacets() {
    if (!els.facets) return;
    els.facets.innerHTML = '';
    const chip = (label, onRemove) => {
        const c = el('span', 'mon-facet');
        c.appendChild(el('span', null, label));
        const x = el('button', 'mon-facet-x');
        x.innerHTML = uiIcon('close');
        x.type = 'button';
        x.title = 'Take it off';
        x.addEventListener('click', onRemove);
        c.appendChild(x);
        els.facets.appendChild(c);
    };
    if (emFacetEvent) chip(eventLabel(emFacetEvent), () => { emFacetEvent = null; refilter(); });
    if (emFacetSrc) chip(emFacetSrc.name + ' #' + emFacetSrc.src, () => { emFacetSrc = null; refilter(); });
    els.count = el('span', 'mon-count');
    els.facets.appendChild(els.count);
    if (emHasActiveFilters()) {
        const all = WP.btn('Show everything', null, 'ghost');
        all.classList.add('wp-btn-sm');
        all.addEventListener('click', emClearAllFilters);
        els.facets.appendChild(all);
    }
    emUpdateCountLine();
}

function emUpdateCountLine() {
    if (!els.count) return;
    const rendered = feedListEl ? feedListEl.querySelectorAll('.mon-entry').length : 0;
    els.count.textContent = emMatchTotal > 0 && rendered >= GROUP_CAP
        ? `the newest ${GROUP_CAP} of ${emMatchTotal} matching`
        : plural(emMatchTotal, 'entry', 'entries') + (emHasActiveFilters() || !showStats ? ' shown' : '');
}

// ---- rows ----

let emTopGroup = null;   // { sig, group, countEl, timeEl } — live patch target

function emBuildGroups() {
    const groups = [];
    emMatchTotal = 0;
    let current = null;
    for (const e of newestFirst()) {
        if (!emEntryMatches(e)) continue;
        emMatchTotal += 1;
        const sig = sigOf(e);
        if (current && current.sig === sig) {
            current.count += 1;
            current.firstT = e.t;   // walking newest->oldest: this run's earliest so far
        } else {
            if (groups.length >= GROUP_CAP) { current = null; continue; }
            current = { sig, rep: e, count: 1, firstT: e.t, lastT: e.t };
            groups.push(current);
        }
    }
    return groups;
}

function emGroupRow(g) {
    const e = g.rep;
    const tamper = isTamper(e);
    const kind = tamper ? 'tamper' : e.status === 'error' ? 'error' : e.status === 'rejected' ? 'refused' : 'ok';
    const row = el('div', 'mon-row mon-entry mon-' + kind);

    const timeEl = el('span', 'mon-time', timeOfDay(g.lastT));
    row.appendChild(timeEl);
    const mark = WP.mark(kind === 'ok' ? 'ok' : kind === 'refused' ? 'warn' : 'err');
    mark.title = { ok: 'Went through', refused: 'Refused', error: 'Broke on the server', tamper: 'Tampering caught' }[kind];
    row.appendChild(mark);

    const what = el('span', 'mon-what');
    const title = el('span', 'mon-title', eventLabel(e.event));
    title.title = (tamper ? 'Sentinel' : 'Only this') + ': ' + e.event;
    title.addEventListener('click', (ev) => {
        ev.stopPropagation();
        if (tamper) setView('keys');
        else emSetEventFacet(e.event);
    });
    what.appendChild(title);
    const countPill = el('span', 'mon-times', g.count > 1 ? '×' + g.count : '');
    if (g.count <= 1) countPill.style.display = 'none';
    what.appendChild(countPill);
    what.appendChild(el('span', 'mon-res', tamper ? 'sentinel' : resourceOf(e.event)));
    row.appendChild(what);

    const who = el('span', 'mon-who');
    if (e.src !== undefined && e.src !== null && e.src !== 0) {
        who.appendChild(face(e.name));
        who.appendChild(el('span', 'mon-name', e.name || 'Unknown'));
        who.appendChild(el('span', 'mon-id', '#' + e.src));
        who.title = 'Only ' + (e.name || 'Unknown');
        who.addEventListener('click', (ev) => { ev.stopPropagation(); emSetSrcFacet(e.src, e.name || 'Unknown'); });
    } else {
        who.appendChild(el('span', 'mon-dim', 'the server'));
    }
    row.appendChild(who);

    const out = el('span', 'mon-out');
    if (e.reason) out.textContent = e.reason;
    else if (e.ms !== undefined && e.ms !== null) out.textContent = e.ms + ' ms';
    row.appendChild(out);

    // Its detail, on a click: the key, the numbers, and the two ways to narrow the feed to it.
    row.addEventListener('click', () => {
        if (emExpandedRow === row) {
            row.classList.remove('mon-expanded');
            emExpandedRow = null;
            return;
        }
        if (emExpandedRow) emExpandedRow.classList.remove('mon-expanded');
        let detail = row.querySelector('.mon-detail');
        if (!detail) {
            detail = el('div', 'mon-detail');
            const g2 = row._group || g;
            const line = (k, v) => {
                const d = el('div', 'mon-detail-line');
                d.appendChild(el('span', 'mon-detail-k', k));
                d.appendChild(el('span', 'mon-detail-v', v));
                detail.appendChild(d);
            };
            line('Event', e.event);
            line('Outcome', { ok: 'went through', refused: 'refused', error: 'broke on the server', tamper: 'tampering caught' }[kind]
                + (e.reason ? ': ' + e.reason : ''));
            if (e.ms !== undefined && e.ms !== null) line('Handler', e.ms + ' ms');
            line('Who', e.src ? (e.name || 'Unknown') + ' (server id ' + e.src + ')' : 'the server');
            if (g2.count > 1) line('Folded', '×' + g2.count + ', ' + timeOfDay(g2.firstT) + ' → ' + timeOfDay(g2.lastT));
            line('Seq', String(e.seq));
            const acts = el('div', 'mon-detail-acts');
            const only = WP.btn('Only this event', null, 'ghost');
            only.classList.add('wp-btn-sm');
            only.addEventListener('click', (ev) => { ev.stopPropagation(); emSetEventFacet(e.event); });
            acts.appendChild(only);
            if (e.src) {
                const p = WP.btn('Only ' + (e.name || 'Unknown'), null, 'ghost');
                p.classList.add('wp-btn-sm');
                p.addEventListener('click', (ev) => { ev.stopPropagation(); emSetSrcFacet(e.src, e.name || 'Unknown'); });
                acts.appendChild(p);
            }
            detail.appendChild(acts);
            row.appendChild(detail);
        }
        row.classList.add('mon-expanded');
        emExpandedRow = row;
    });

    row._group = g;
    return { row, countPill, timeEl };
}

function renderFeed() {
    if (!feedListEl) return;
    feedListEl.innerHTML = '';
    emExpandedRow = null;
    emTopGroup = null;
    feedCtl.reset();

    const groups = emBuildGroups();
    for (const g of groups) {
        const built = emGroupRow(g);
        feedListEl.appendChild(built.row);
        if (!emTopGroup) emTopGroup = { sig: g.sig, group: g, countEl: built.countPill, timeEl: built.timeEl };
    }

    if (groups.length === 0) {
        let text;
        if (emHasActiveFilters()) text = onlyProblems && !emFacetEvent && !emFacetSrc && !emFeedSearch
            ? 'No problems. Nothing has been refused and nothing broke.' : 'Nothing matches.';
        else text = showStats ? 'Nothing yet: traffic appears here as it happens.'
            : 'Nothing but stat updates yet. Traffic appears here as it happens.';
        feedListEl.appendChild(el('div', 'wp-empty mon-empty', text));
    }

    feedListEl.scrollTop = 0;
    emUpdateCountLine();
}

function emFeedInsert(e) {
    if (!emEntryMatches(e)) return;
    emMatchTotal += 1;

    const sig = sigOf(e);
    if (emTopGroup && emTopGroup.sig === sig) {
        // Same run as the newest rendered group: bump ×N and the time in place — zero
        // layout shift by construction.
        emTopGroup.group.count += 1;
        emTopGroup.group.lastT = e.t;
        emTopGroup.countEl.textContent = '×' + emTopGroup.group.count;
        emTopGroup.countEl.style.display = '';
        emTopGroup.timeEl.textContent = timeOfDay(e.t);
        return;
    }

    const empty = feedListEl.querySelector('.mon-empty');
    if (empty) empty.remove();

    const g = { sig, rep: e, count: 1, firstT: e.t, lastT: e.t };
    const built = emGroupRow(g);
    built.row.classList.add('wp-log-new');
    feedCtl.prepend(built.row);
    emTopGroup = { sig, group: g, countEl: built.countPill, timeEl: built.timeEl };
}

// ONE BATCH, ONE PAINT: the batch is adopted first (logs and registry), then the feed painted
// through one scroll read. The glance and the rail follow on the next tick.
function emNewEvents(list) {
    const adopted = [];
    for (const entry of list) {
        if (emAdoptEntry(entry)) adopted.push(entry);
    }
    if (adopted.length === 0) return;
    // A live batch is seconds old at most: it sets the server's clock against ours.
    const newest = adopted[adopted.length - 1];
    if (typeof newest.t === 'number') skew = newest.t - Date.now() / 1000;
    if (!emOpen) return;

    if (emPaused) return;   // Resume rebuilds the feed in one go
    if (emView === 'feed') {
        feedCtl.beginBatch();
        for (const e of adopted) emFeedInsert(e);
        feedCtl.endBatch();
        emUpdateCountLine();
    } else if (emView === 'events') {
        emRefreshEventsTable();
    }
}

/** Into its log and the registry. True when it was new (not a duplicate or out of order). */
function emAdoptEntry(entry) {
    if (!entry || typeof entry.seq !== 'number') return false;
    if (entry.seq <= emLastSeq) return false;   // duplicate / out-of-order guard
    emLastSeq = entry.seq;

    if (entry.status === 'ok') {
        okLog.push(entry);
        if (okLog.length > OK_CAP) okLog.shift();
    } else {
        probLog.push(entry);
        if (probLog.length > PROB_CAP) probLog.shift();
    }

    // Registry patch — synthesizes a row for names the snapshot never saw ('sentinel:*').
    let reg = null;
    for (const r of emRegistry) {
        if (r.event === entry.event) { reg = r; break; }
    }
    if (!reg) {
        reg = { event: entry.event, resource: '', calls: 0, rejects: 0, lastCall: entry.t, rateLimit: null };
        emRegistry.push(reg);
    }
    reg.calls += 1;
    if (entry.status === 'rejected' || entry.status === 'error') reg.rejects += 1;
    reg.lastCall = entry.t;
    return true;
}

function emCleared() {
    okLog = [];
    probLog = [];
    emTopGroup = null;
    feedCtl.reset();
    if (emOpen && emView === 'feed') renderFeed();
    tick();
}

function emTogglePause() {
    emPaused = !emPaused;
    els.pause.textContent = emPaused ? 'Resume' : 'Pause';
    els.pause.classList.toggle('active', emPaused);
    if (!emPaused) {
        feedCtl.reset();
        if (emView === 'feed') renderFeed();   // catch up in one rebuild
    }
}

// ---- the rail ----

function card(parent, title, sub) {
    const c = el('div', 'mon-card mon-rail-card');
    const head = el('div', 'mon-card-head');
    head.appendChild(el('div', 'mon-card-title', title));
    const s = el('span', 'mon-card-sub', sub || '');
    head.appendChild(s);
    c.appendChild(head);
    const body = el('div', 'mon-rail-body');
    c.appendChild(body);
    const top = el('div');      // what it says first (Sentinel's state)
    const list = el('div');     // its lines
    const note = el('div');     // under them: an empty list's sentence, Sentinel's last detection
    body.appendChild(top);
    body.appendChild(list);
    body.appendChild(note);
    parent.appendChild(c);
    return { root: c, head, sub: s, body, top, list, note };
}

/** Set a box's text only when it changed (the rail redraws every second). */
function say(box, sig, build) {
    if (box._sig === sig) return;
    box._sig = sig;
    box.innerHTML = '';
    build(box);
}

function railLink(c, label, onClick) {
    const b = WP.btn(label, null, 'ghost');
    b.classList.add('wp-btn-sm', 'mon-link');
    b.addEventListener('click', onClick);
    c.head.appendChild(b);
    return b;
}

/** Sentinel first (is anything being tampered with), then who is busiest, then what. */
function buildRail() {
    els.cSentinel = card(els.rail, 'Sentinel', '');
    railLink(els.cSentinel, 'Watched keys', () => setView('keys'));
    els.cPlayers = card(els.rail, 'Most active', 'last 5 minutes');
    els.cEvents = card(els.rail, 'Busiest', 'last 5 minutes');
    els.allEvents = railLink(els.cEvents, 'All events', () => setView('events'));
}

/** A line of the rail: a face, words, a bar for its share, its numbers. A button: it narrows the feed. */
function railLine(opts) {
    const b = el('button', 'mon-line');
    b.type = 'button';
    if (opts.lead) b.appendChild(opts.lead);
    const words = el('span', 'mon-line-words');
    const top = el('span', 'mon-line-head');
    b._title = el('span', 'mon-line-title');
    top.appendChild(b._title);
    b._sub = el('span', 'mon-line-sub');
    top.appendChild(b._sub);
    words.appendChild(top);
    const bar = el('span', 'mon-line-bar');
    b._fill = el('span', 'mon-line-fill');
    bar.appendChild(b._fill);
    words.appendChild(bar);
    b.appendChild(words);
    const nums = el('span', 'mon-line-nums');
    b._n = el('span', 'mon-line-n');
    b._p = el('span', 'mon-line-p');
    nums.appendChild(b._n);
    nums.appendChild(b._p);
    b.appendChild(nums);
    b.addEventListener('click', () => { if (b._opts && b._opts.onClick) b._opts.onClick(); });
    updateLine(b, opts);
    return b;
}

function updateLine(b, opts) {
    b._opts = opts;
    b.classList.toggle('active', !!opts.active);
    b._title.textContent = opts.title;
    b._sub.textContent = opts.sub || '';
    b._fill.parentNode.style.display = opts.share === undefined ? 'none' : '';
    if (opts.share !== undefined) b._fill.style.width = Math.max(2, Math.round(opts.share * 100)) + '%';
    b._n.textContent = String(opts.n);
    b._p.textContent = opts.pText || '';
    b._p.style.display = opts.pText ? '' : 'none';
}

/** A rail list built again only when what is in it, or its order, changed; otherwise patched in place. It redraws
 *  every second, and a line rebuilt under the pointer between press and release loses the click. */
function patchLines(box, items) {
    const keys = items.map((i) => i.key).join('|');
    if (box._keys === keys && box._lines) {
        items.forEach((it, i) => updateLine(box._lines[i], it));
        return;
    }
    box.innerHTML = '';
    box._keys = keys;
    box._lines = items.map((it) => {
        const line = railLine(it);
        box.appendChild(line);
        return line;
    });
}

function renderRail(r) {
    // Most active
    const players = [...r.players.values()].sort((a, b) => b.n - a.n || a.src - b.src).slice(0, RAIL_LINES);
    const pmax = players.length ? players[0].n : 1;
    patchLines(els.cPlayers.list, players.map((p) => ({
        key: p.src, lead: face(p.name), title: p.name, sub: '#' + p.src, share: p.n / pmax, n: p.n,
        pText: p.p ? plural(p.p, 'problem') : null,
        active: !!(emFacetSrc && emFacetSrc.src === p.src),
        onClick: () => emSetSrcFacet(p.src, p.name),
    })));
    say(els.cPlayers.note, players.length ? '' : 'none', (box) => {
        if (!players.length) box.appendChild(el('div', 'mon-rail-empty', 'Nobody has sent anything in 5 minutes.'));
    });

    // Busiest
    const events = [...r.events.values()].sort((a, b) => b.n - a.n || (a.event < b.event ? -1 : 1)).slice(0, RAIL_LINES);
    const emax = events.length ? events[0].n : 1;
    patchLines(els.cEvents.list, events.map((v) => ({
        key: v.event, title: eventLabel(v.event), sub: isTamper(v) ? 'sentinel' : resourceOf(v.event), share: v.n / emax,
        n: v.n, pText: v.p ? plural(v.p, 'problem') : null,
        active: emFacetEvent === v.event,
        onClick: () => { if (emFacetEvent === v.event) { emFacetEvent = null; refilter(); } else emSetEventFacet(v.event); },
    })));
    say(els.cEvents.note, (events.length ? '' : 'none') + showStats, (box) => {
        if (!events.length) box.appendChild(el('div', 'mon-rail-empty', showStats ? 'Nothing in 5 minutes.' : 'Nothing but stat updates in 5 minutes.'));
    });
    els.allEvents.textContent = 'All ' + emRegistry.length + ' events';

    // Sentinel: its state in words, who is struck, the last thing it caught
    const c = els.cSentinel;
    c.root.classList.toggle('mon-card-alert', snUnseen > 0);
    if (!snData) {
        say(c.top, 'waiting', (box) => box.appendChild(el('div', 'mon-rail-empty', 'Waiting for Sentinel…')));
        patchLines(c.list, []);
        say(c.note, '', () => {});
        return;
    }
    const watching = (snData.registry || []).filter((k) => k.armed).length;
    say(c.top, [snData.enabled, watching, snData.autoKick].join('|'), (box) => {
        const state = el('div', 'mon-sn-state');
        state.appendChild(WP.mark(snData.enabled ? 'ok' : 'warn'));
        const words = el('div');
        words.appendChild(el('div', 'mon-line-title', snData.enabled
            ? 'Watching ' + plural(watching, 'key') + ' for tampering' : 'Off: nothing is watched'));
        words.appendChild(el('div', 'mon-line-sub', snData.enabled
            ? (snData.autoKick ? 'A player is kicked at ' + snData.autoKick + ' strikes' : 'It logs; it kicks nobody')
            : 'Turn it on in config.lua'));
        state.appendChild(words);
        box.appendChild(state);
    });
    const strikes = (snData.strikes || []).slice().sort((a, b) => b.strikes - a.strikes || a.src - b.src).slice(0, 3);
    patchLines(c.list, strikes.map((s) => ({
        // "2 of 3": the state line above says what 3 is (a player is kicked at 3 strikes).
        key: s.src, lead: face(s.name), title: s.name, sub: '#' + s.src,
        n: snData.autoKick ? s.strikes + ' of ' + snData.autoKick : plural(s.strikes, 'strike'), pText: null,
        active: !!(emFacetSrc && emFacetSrc.src === s.src),
        onClick: () => emSetSrcFacet(s.src, s.name),
    })));
    const log = snData.log || [];
    const last = log[log.length - 1];
    say(c.note, (strikes.length ? 's' : '') + (log.length ? 'l' : '') + (last ? last.t + since(last.t) : ''), (box) => {
        if (!strikes.length) box.appendChild(el('div', 'mon-rail-empty', log.length ? 'Nobody struck now.' : 'No tampering caught. Good.'));
        if (last) {
            const d = el('div', 'mon-sn-last');
            d.appendChild(el('span', 'mon-line-sub', 'Last caught: '));
            d.appendChild(el('span', 'mon-sn-key', last.key));
            d.appendChild(el('span', 'mon-line-sub', ' · ' + (last.name || 'Unknown') + ' · ' + since(last.t)));
            box.appendChild(d);
        }
    });
}

// ---- in depth: every event ----

let emEventsTableRender = null;
let emEventsTableWrap = null;

function emRefreshEventsTable() {
    const pane = els.views && els.views.events;
    if (emEventsTableRender && emEventsTableWrap && pane && pane.contains(emEventsTableWrap)) emEventsTableRender();
    else emRenderEvents();
}

function viewHead(pane, title, sub) {
    const head = el('div', 'mon-card-head');
    const back = WP.backBtn('Live feed', null);
    back.classList.add('wp-btn-sm');
    back.addEventListener('click', () => setView('feed'));
    head.appendChild(back);
    head.appendChild(el('div', 'mon-card-title', title));
    if (sub) head.appendChild(el('span', 'mon-card-sub', sub));
    head.appendChild(el('span', 'wp-toolbar-spacer'));
    pane.appendChild(head);
    return head;
}

function emRenderEvents() {
    const pane = els.views.events;
    pane.innerHTML = '';
    const head = viewHead(pane, 'All events', 'every event whip checks, since the server started');
    const search = searchBox('Search events…', emEventsSearch, (v) => {
        emEventsSearch = v.toLowerCase();
        renderTable();   // only the table: the box keeps its focus
    });
    head.appendChild(search.box);

    const wrap = el('div', 'mon-table-wrap');
    pane.appendChild(wrap);

    const renderTable = () => {
        wrap.innerHTML = '';
        const table = el('table', 'mon-table');
        const thead = el('thead');
        const hr = el('tr');
        const cols = [
            ['event', 'What', false], ['resource', 'Resource', false], ['calls', 'Calls', true],
            ['rejects', 'Refused', true], ['rateLimit', 'Rate limit', false], ['lastCall', 'Last', true],
        ];
        for (const [key, label, sortable] of cols) {
            const th = el('th', (sortable ? 'mon-th-sort' : '') + (key !== 'event' && key !== 'resource' ? ' mon-num' : ''), label);
            if (sortable) {
                if (emEventsSort.col === key) {
                    th.classList.add('mon-th-active');
                    th.textContent = label + (emEventsSort.dir === 'desc' ? ' ↓' : ' ↑');
                }
                th.addEventListener('click', () => {
                    if (emEventsSort.col === key) emEventsSort.dir = emEventsSort.dir === 'desc' ? 'asc' : 'desc';
                    else emEventsSort = { col: key, dir: 'desc' };
                    renderTable();
                });
            }
            hr.appendChild(th);
        }
        thead.appendChild(hr);
        table.appendChild(thead);

        const q = emEventsSearch;
        const rows = emRegistry
            .filter((r) => !q || r.event.toLowerCase().includes(q) || eventLabel(r.event).toLowerCase().includes(q)
                || (r.resource || '').toLowerCase().includes(q))
            .sort((a, b) => {
                const va = a[emEventsSort.col] || 0, vb = b[emEventsSort.col] || 0;
                return emEventsSort.dir === 'desc' ? vb - va : va - vb;
            });

        const tbody = el('tbody');
        for (const r of rows) {
            const tr = el('tr', 'mon-table-row');
            const what = el('td');
            what.appendChild(el('div', 'mon-title', eventLabel(r.event)));
            what.appendChild(el('div', 'mon-key', r.event));
            tr.appendChild(what);
            const res = el('td');
            res.appendChild(el('span', 'mon-res', r.resource || resourceOf(r.event)));
            tr.appendChild(res);
            tr.appendChild(el('td', 'mon-num', String(r.calls || 0)));
            tr.appendChild(el('td', 'mon-num' + ((r.rejects || 0) > 0 ? ' mon-hot' : ''), String(r.rejects || 0)));
            tr.appendChild(el('td', 'mon-num', r.rateLimit ? 'one per ' + r.rateLimit + ' ms' : '—'));
            tr.appendChild(el('td', 'mon-num', r.lastCall ? since(r.lastCall) : 'never'));
            tr.title = 'Show it in the live feed';
            tr.addEventListener('click', () => emSetEventFacet(r.event));
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);
        wrap.appendChild(table);
        if (rows.length === 0) wrap.appendChild(el('div', 'wp-empty mon-empty', 'No event matches.'));
    };

    emEventsTableRender = renderTable;
    emEventsTableWrap = wrap;
    renderTable();
}

// ---- in depth: Sentinel ----

function snRow(entry) {
    const row = el('div', 'mon-row mon-entry mon-tamper mon-sn-row');
    row.appendChild(el('span', 'mon-time', timeOfDay(entry.t)));
    row.appendChild(WP.mark('err'));
    const what = el('span', 'mon-what');
    what.appendChild(el('span', 'mon-title mon-sn-key', entry.key));
    row.appendChild(what);
    const who = el('span', 'mon-who');
    who.appendChild(face(entry.name));
    who.appendChild(el('span', 'mon-name', entry.name || 'Unknown'));
    if (entry.src) who.appendChild(el('span', 'mon-id', '#' + entry.src));
    row.appendChild(who);
    const out = el('span', 'mon-out mon-got-exp');
    out.appendChild(el('span', 'mon-got', String(entry.got)));
    out.appendChild(el('span', 'mon-dim', ' set, the server had '));
    out.appendChild(el('span', 'mon-exp', String(entry.expected)));
    out.appendChild(el('span', 'mon-dim', '  ·  strike ' + (entry.strikes || 0)));
    row.appendChild(out);
    return row;
}

function snRender() {
    const pane = els.views.keys;
    pane.innerHTML = '';
    const head = viewHead(pane, 'Sentinel', 'catches a player\'s game changing what only the server may change');
    const clear = WP.btn('Clear detections', null, 'ghost');
    clear.classList.add('wp-btn-sm');
    clear.addEventListener('click', () => nuiCallback('snClearLog', {}));
    head.appendChild(clear);

    if (!snData) {
        pane.appendChild(el('div', 'wp-empty mon-empty', 'Waiting for Sentinel…'));
        return;
    }
    const scroll = el('div', 'mon-table-wrap');
    pane.appendChild(scroll);

    scroll.appendChild(el('div', 'wp-section-title', 'Watched keys'));
    const table = el('table', 'mon-table');
    const thead = el('thead');
    const hr = el('tr');
    for (const [h, num] of [['Key', false], ['Family', false], ['Owner', false], ['Watching', false], ['Detections', true], ['Last', true]]) {
        hr.appendChild(el('th', num ? 'mon-num' : null, h));
    }
    thead.appendChild(hr);
    table.appendChild(thead);
    const tbody = el('tbody');
    const regs = (snData.registry || []).slice()
        .sort((a, b) => (b.detections || 0) - (a.detections || 0) || a.key.localeCompare(b.key));
    for (const r of regs) {
        const tr = el('tr');
        tr.appendChild(el('td', 'mon-sn-key', r.key));
        tr.appendChild(el('td', null, r.family));
        const owner = el('td');
        owner.appendChild(el('span', 'mon-res', r.owner));
        tr.appendChild(owner);
        const w = el('td', 'mon-watch');
        w.appendChild(WP.mark(r.armed ? 'ok' : 'off'));
        w.appendChild(el('span', 'mon-dim', r.armed ? ' yes' : ' not yet'));
        tr.appendChild(w);
        tr.appendChild(el('td', 'mon-num' + ((r.detections || 0) > 0 ? ' mon-hot' : ''), String(r.detections || 0)));
        tr.appendChild(el('td', 'mon-num', r.lastAt ? since(r.lastAt) : '—'));
        tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    scroll.appendChild(table);

    scroll.appendChild(el('div', 'wp-section-title', 'Detections'));
    const log = snData.log || [];
    const list = el('div', 'mon-sn-list');
    for (let i = log.length - 1; i >= 0; i--) list.appendChild(snRow(log[i]));
    if (log.length === 0) list.appendChild(el('div', 'wp-empty mon-empty', 'No tampering caught. Good.'));
    els.snList = list;
    scroll.appendChild(list);
}

function snAllData(data) {
    snData = data;
    if (emOpen && emView === 'keys') snRender();
    tick();
}

function snNewDetection(entry) {
    if (!snData) snData = { registry: [], log: [], strikes: [], enabled: true, autoKick: false };
    snData.log.push(entry);
    if (snData.log.length > 200) snData.log.shift();

    let reg = null;
    for (const r of snData.registry) {
        if (r.key === entry.key) { reg = r; break; }
    }
    if (reg) { reg.detections = (reg.detections || 0) + 1; reg.lastAt = entry.t; }
    if (entry.src) {
        let s = null;
        for (const x of snData.strikes) {
            if (x.src === entry.src) { s = x; break; }
        }
        if (s) { s.strikes = entry.strikes || (s.strikes + 1); s.name = entry.name || s.name; }
        else snData.strikes.push({ src: entry.src, name: entry.name || 'Unknown', strikes: entry.strikes || 1 });
    }

    if (emOpen && emView === 'keys') {
        snRender();
        return;
    }
    // Not looking at Sentinel: the tile and the card light up, and when the whole section is out of sight, the
    // shell's nav badge counts it too, so a tamper is seen from anywhere in the panel.
    snUnseen += 1;
    if (!emOpen) WhipPanel.setBadge('monitor', snUnseen);
    tick();
}

function snCleared() {
    if (snData) snData.log = [];
    if (emOpen && emView === 'keys') snRender();
    tick();
}

// ---- views ----

function setView(view) {
    emView = view;
    for (const k of Object.keys(els.views || {})) els.views[k].style.display = k === view ? '' : 'none';
    if (view === 'keys') {
        snUnseen = 0;
        snRender();
    } else if (view === 'feed') {
        renderFacets();
        renderFeed();
    } else if (view === 'events') {
        emRenderEvents();
    }
    tick();
}

/** The glance and the rail, when something changed (or once a second, as "the last minute" slides on). */
function tick() {
    if (!emOpen || !els.tiles) return;
    const r = computeRecent();
    renderTiles(r);
    renderRail(r);
    if (els.kindProblems) {
        const n = r.refused + r.errors + r.tamper;
        els.kindProblems.textContent = n ? String(n) : '';
        els.kindProblems.style.display = n ? '' : 'none';
    }
}

// ---- lifecycle (section contract) ----

/** A fresh em snapshot arrived (section enter). View state resets — HISTORY does not,
 *  because the server holds it all: replacing the logs with the snapshot is correct. */
function emAdopt(data) {
    emPaused = false;
    onlyProblems = false;
    emFacetEvent = null;
    emFacetSrc = null;
    emFeedSearch = '';
    emEventsSearch = '';
    emExpandedRow = null;
    feedCtl.reset();

    okLog = [];
    probLog = [];
    for (const e of (data.log || [])) {
        if (!e || typeof e.seq !== 'number') continue;
        if (e.status === 'ok') okLog.push(e); else probLog.push(e);
    }
    if (okLog.length > OK_CAP) okLog = okLog.slice(-OK_CAP);
    if (probLog.length > PROB_CAP) probLog = probLog.slice(-PROB_CAP);
    emRegistry = data.registry || [];
    const lastOk = okLog[okLog.length - 1], lastProb = probLog[probLog.length - 1];
    emLastSeq = Math.max(emLastSeq, (lastOk && lastOk.seq) || 0, (lastProb && lastProb.seq) || 0);

    if (emOpen) {
        if (els.search) els.search.value = '';
        if (els.kind) els.kind.set('all');
        if (els.pause) { els.pause.textContent = 'Pause'; els.pause.classList.remove('active'); }
        setView(emView);   // remembered across visits
    }
}

/** Escape's stages before the panel closes: an open row, a view in depth, the filters. */
function emEscapeStage() {
    if (emExpandedRow) {
        emExpandedRow.classList.remove('mon-expanded');
        emExpandedRow = null;
        return true;
    }
    if (emView !== 'feed') {
        setView('feed');
        return true;
    }
    if (emHasActiveFilters()) {
        emClearAllFilters();
        return true;
    }
    return false;
}

// ---- registrations ----
//
// The live streams keep their own router actions (they arrive whether or not this
// section is showing — state adopts either way, rendering waits for visibility).
// The SNAPSHOT also still arrives on 'openEventMonitor' — the action name predates the
// mount and the Lua side (tools/panel_sections/monitor.lua) kept it to avoid renaming
// a working wire.

NuiRouter.register('openEventMonitor', (d) => emAdopt(d.data));
// The server batches the live feed: a list, oldest first, four times a second — painted once per
// batch (emNewEvents).
NuiRouter.register('emNewEvents', (d) => {
    const list = Array.isArray(d.data) ? d.data : Object.values(d.data || {});
    emNewEvents(list);
});
NuiRouter.register('emCleared', () => emCleared());
NuiRouter.register('snAllData', (d) => snAllData(d.data));
NuiRouter.register('snNewDetection', (d) => snNewDetection(d.data));
NuiRouter.register('snCleared', () => snCleared());

WhipPanel.registerSection({
    id: 'monitor',
    group: 'system',
    label: 'Monitor',
    order: 10,

    render(root) {
        emBuildSkeleton(root);
    },

    onEnter() {
        emOpen = true;
        WhipPanel.setBadge('monitor', null);
        setView(emView);
        // "The last minute" slides on with or without traffic: once a second while the section shows.
        if (tickTimer) clearInterval(tickTimer);
        tickTimer = setInterval(tick, 1000);
    },

    onLeave() {
        emOpen = false;
        if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
    },

    onData() {
        // Data rides this module's own stream actions above; nothing arrives here.
    },

    onEscape() {
        return emEscapeStage();
    },
});
