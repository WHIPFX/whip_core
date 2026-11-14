// The /whip admin panel shell: one panel, every menu-based admin tool inside it as a section. The shell owns the
// chrome (header, tab row, content area), the single key scope, the single zoom and the conversation with Lua
// (tools/whip_panel.lua); sections own only their content. Groups are big words along the header; the open group's
// sections are tabs under them, and a group word opens the section last used in that group.
//
// Section contract: a module in html/js/wp/ calls
//
//     WhipPanel.registerSection({
//         id: 'containers',          // stable key; matches PanelSections in Lua
//         group: 'economy',          // players | vehicles | economy | world | director | system | settings
//         label: 'Containers',
//         order: 30,                 // position within its group
//         render(root),              // build the section skeleton once into root
//         onEnter(),                 // section just became visible (view reset only; the shell tells Lua)
//         onData(kind, payload),     // a wpSectionData message for this id
//         onLeave(),                 // another section took over (view teardown only)
//         onEscape() -> bool,        // true = consumed (closed a dialog/drill-down); false = the shell may close the panel
//         onSuspend(), onResume(),   // optional: around editor/demo/confirm handoffs
//         onFocus(focus),            // optional: opened on one thing ({ vehicleId }, { userId }), via
//                                    //   WhipPanel.switchTo(id, focus), after onEnter
//         actions: { name: fn },     // data-action map for this section's subtree; fn(el, event). One delegated
//                                    //   listener on the shell dispatches, never addEventListener per element.
//     });
//
// Sections render with the WP helpers below and the wp-* classes in whip-panel.css. Data strings render via
// textContent, never innerHTML.

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { createPadCursor } from './pad-cursor.js';
import { PauseMap } from './pause-map.js';

// ---- registry ----

const GROUPS = [
    { id: 'players',  label: 'Players' },
    { id: 'vehicles', label: 'Vehicles' },
    { id: 'economy',  label: 'Economy' },
    { id: 'world',    label: 'World' },
    // The Director's pages (wp/director.js): its own group, being a whole tool of its own.
    { id: 'director', label: 'Director' },
    { id: 'system',   label: 'System' },
    // config.lua's settings (Config) and each satellite's settings page (wp/config.js).
    { id: 'settings', label: 'Settings' },
];

const _sections = new Map();   // id -> def
const _widgets = new Map();    // id -> a WP.tabs / WP.stepper, so the shell actions can find it
let _active = null;            // active section id — SURVIVES close/reopen (EM precedent)
let _open = false;
let _suspended = false;
// WHICH SECTIONS THIS PLAYER MAY OPEN (server/permissions.lua, sent with openWhipPanel): null for a
// full admin (every section), else the ids a permission opens (a Director builder: the Director's).
// A section not allowed is not built at all; the server gates every action behind it regardless.
let _allowed = null;
// A PERMANENT admin (whip.devtools from server.cfg)? False for the Player Manager's temporary dev
// tools: a section marked permanentOnly (the settings pages, whose changes outlive the restart that
// takes temporary tools away) is not built for them. The server refuses them regardless.
let _permanent = true;
const allowedSection = (id) => {
    const s = _sections.get(id);
    if (s && s.permanentOnly && !_permanent) return false;
    // A section that says it is gone for now (a satellite's settings page whose resource stopped).
    if (s && typeof s.hidden === 'function' && s.hidden()) return false;
    return _allowed === null || _allowed.has(id);
};
// Run with the open message before the tabs are built: sections made from what the server sent
// (each satellite's settings page, wp/config.js) exist by then.
const _openHooks = [];
const visibleSections = () => [..._sections.values()].filter((s) => allowedSection(s.id));
/** A group's sections this player may open, in their order. */
const groupMembers = (groupId) => visibleSections()
    .filter((s) => s.group === groupId)
    .sort((a, b) => (a.order || 0) - (b.order || 0));

// ---- skeleton ----

let _panelEl = null, _contentEl = null;
let _resultEl = null, _resultTimer = null, _resultSticky = false;
const _navEls = {}, _rootEls = {}, _badgeEls = {};
// The header's group words and their badges, and each group's row of tabs, by group id.
const _groupEls = {}, _groupBadgeEls = {}, _tabSetEls = {};
const _badgeCounts = {};          // section id -> its badge number (a group word shows its group's sum)
const _groupLast = new Map();     // group id -> the section last open in it (page lifetime, like _active)

const CLOSE_ICON = '<svg viewBox="0 0 14 14" width="14" height="14" fill="none" stroke="currentColor"'
    + ' stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M2 2l10 10M12 2L2 12"/></svg>';
// WP.mark's drawings: an outline circle, transparent inside, and the mark drawn BIGGER than it so it
// breaks out of the ring. The tick's long stroke leaves through the top
// right; the cross's arms leave through all four corners. Stroked in currentColor (.wp-mark-*).
const MARK_RING = '<circle cx="9" cy="10" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6"/>';
const MARK_ICONS = {
    ok: '<svg viewBox="0 0 18 18" aria-hidden="true">' + MARK_RING
        + '<path d="M5.4 9.6 8.6 12.9 16.4 2.6" fill="none" stroke="currentColor" stroke-width="2.3"'
        + ' stroke-linecap="round" stroke-linejoin="round"/></svg>',
    err: '<svg viewBox="0 0 18 18" aria-hidden="true">' + MARK_RING
        + '<path d="M3.6 4.6 14.4 15.4 M14.4 4.6 3.6 15.4" fill="none" stroke="currentColor" stroke-width="2.3"'
        + ' stroke-linecap="round"/></svg>',
    warn: '<svg viewBox="0 0 18 18" aria-hidden="true">' + MARK_RING
        + '<path d="M9 6.4V10.6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>'
        + '<circle cx="9" cy="13.4" r="1.2" fill="currentColor"/></svg>',
    // A fact, not a pass or a fail (an item's weight): an "i" in the ring.
    info: '<svg viewBox="0 0 18 18" aria-hidden="true">' + MARK_RING
        + '<circle cx="9" cy="7.1" r="1.15" fill="currentColor"/>'
        + '<path d="M9 9.6V13.4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    off: '<svg viewBox="0 0 18 18" aria-hidden="true">' + MARK_RING + '</svg>',
};

// A group's caret: points right while shut; the CSS turns it down when the group opens.
const CHEVRON_ICON = '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor"'
    + ' stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3l5 5-5 5"/></svg>';
// The panel's name: whip's logo, the letters alone (the loading screen's trace, whip_loadingscreen/html/index.html),
// filled white by the CSS (.wp-title-logo).
const WHIP_LOGO = '<svg viewBox="58 46 997 235" aria-hidden="true">'
    + '<path d="M62 83 A33 33 0 0 1 128 83 L128 211 L169 211 L169 50 L235 50 L235 211 L276 211 L276 50 L342 50 L342 277 L117 277 A55 55 0 0 1 62 222 Z"/>'
    + '<path d="M369 50 H435 V157 H583 V50 H649 V277 H583 V223 H435 V277 H369 Z"/>'
    + '<rect x="677" y="50" width="66" height="227" rx="33"/>'
    + '<path d="M771 50 H1001 A50 50 0 0 1 1051 100 V173 A50 50 0 0 1 1001 223 H897 A33 33 0 0 1 897 157 H985 V116 H837 V277 H771 Z"/></svg>';
const SEARCH_ICON = '<svg viewBox="0 0 17 17" width="17" height="17" fill="none" stroke="currentColor"'
    + ' stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="5.5"/><path d="M11.2 11.2L15.5 15.5"/></svg>';

function buildSkeleton() {
    const overlay = document.getElementById('whip-panel-overlay');
    rememberSearches();   // before the old sections go (search memory, below)
    overlay.innerHTML = '';

    _panelEl = WP.el('div', 'wp-panel');
    for (const g of Object.keys(_groupEls)) { delete _groupEls[g]; delete _groupBadgeEls[g]; delete _tabSetEls[g]; }

    // -- header: the title, a big word per group, the close --
    const header = WP.el('div', 'wp-header');
    const title = WP.el('span', 'wp-title wp-title-logo');
    title.setAttribute('role', 'img');
    title.setAttribute('aria-label', 'whip');
    title.innerHTML = WHIP_LOGO;   // a fixed drawing, no data
    header.appendChild(title);
    // The group words and each group's page tabs are tab rows: Left and Right move along them (the
    // panel's keydown, below), and only the open one is a Tab stop.
    const words = WP.el('nav', 'wp-groups');
    words.setAttribute('aria-label', 'Groups');
    words.setAttribute('role', 'tablist');
    // -- the tab row: one set of tabs per group, the open group's shown --
    const tabBar = WP.el('div', 'wp-tabbar');
    for (const group of GROUPS) {
        const members = groupMembers(group.id);
        if (members.length === 0) continue;

        const word = WP.el('button', 'wp-group-word');
        word.type = 'button';
        word.setAttribute('role', 'tab');
        word.tabIndex = -1;
        word.dataset.action = 'wpGroup';
        word.dataset.arg = group.id;
        word.appendChild(WP.el('span', 'wp-group-word-name', group.label));
        const groupBadge = WP.el('span', 'wp-nav-badge');
        groupBadge.hidden = true;
        word.appendChild(groupBadge);
        words.appendChild(word);
        _groupEls[group.id] = word;
        _groupBadgeEls[group.id] = groupBadge;

        const set = WP.el('div', 'wp-tabset');
        set.dataset.group = group.id;
        set.setAttribute('role', 'tablist');
        set.hidden = true;
        // The tabs keep the rail's class, wp-nav-item: LB / RB step through every one of
        // them in order (padSection), crossing into the next group at the end of this one.
        for (const s of members) {
            const item = WP.el('button', 'wp-nav-item');
            item.type = 'button';
            item.setAttribute('role', 'tab');
            item.tabIndex = -1;
            item.dataset.action = 'wpNav';
            item.dataset.arg = s.id;
            item.appendChild(WP.el('span', 'wp-nav-name', s.label));
            const badge = WP.el('span', 'wp-nav-badge');
            badge.style.display = 'none';
            item.appendChild(badge);
            set.appendChild(item);
            _navEls[s.id] = item;
            _badgeEls[s.id] = badge;
        }
        tabBar.appendChild(set);
        _tabSetEls[group.id] = set;
    }
    header.appendChild(words);
    // NOTICES WHILE THE PANEL IS OPEN, at the header's right beside the close: the panel covers the stack
    // and hides the player capsule. The inventory header's row (js/inv-notice.js runs both). Static markup.
    const spacer = WP.el('div', 'wp-header-spacer wp-notice');
    spacer.innerHTML = '<div class="inv-talk-row inv-notice-row" id="wp-notice-row" role="status" aria-live="polite">'
        + '<span class="inv-talk-face"><span class="inv-talk-pic inv-notice-mark"></span></span>'
        + '<span class="inv-talk-text"></span></div>'
        + '<span class="inv-talk-measure" id="wp-notice-measure" aria-hidden="true"></span>';
    header.appendChild(spacer);
    const close = WP.el('button', 'wp-close');
    close.type = 'button';
    close.dataset.action = 'wpClose';
    close.setAttribute('aria-label', 'Close');
    close.innerHTML = CLOSE_ICON;   // a fixed icon, no data
    header.appendChild(close);
    _panelEl.appendChild(header);
    _panelEl.appendChild(tabBar);
    // Badges set while the panel was shut come back with it.
    for (const id of Object.keys(_badgeCounts)) setBadge(id, _badgeCounts[id]);

    // -- content: one persistent root per section, display-toggled so a section's DOM
    // state (scroll, expanded groups, selection) survives switching away and back --
    _contentEl = WP.el('div', 'wp-content');
    for (const s of visibleSections()) {
        const root = WP.el('section', 'wp-section');
        root.dataset.section = s.id;
        _rootEls[s.id] = root;
        _contentEl.appendChild(root);
        try {
            s.render(root);
            dockToolbars(root);
            restoreSearches(s.id);
        } catch (err) {
            root.appendChild(WP.el('div', 'wp-empty', 'Section failed to render: ' + err.message));
            console.error(`[whip-panel] render failed for "${s.id}":`, err);
        }
    }
    _panelEl.appendChild(_contentEl);

    // -- result strip: the panel's own voice (see .wp-result in the CSS for why the
    // toast layer cannot reach an admin while the panel is up). role="status" makes
    // every message a polite screen-reader announcement for free.
    _resultEl = WP.el('div', 'wp-result');
    _resultEl.setAttribute('role', 'status');
    _panelEl.appendChild(_resultEl);
    _resultSticky = false;
    // An error in the strip stays until the admin's next press (WP.result).
    _panelEl.addEventListener('pointerdown', () => {
        if (_resultSticky) { _resultSticky = false; _resultEl.classList.remove('wp-result-show'); }
    }, true);

    overlay.appendChild(_panelEl);

    // ONE delegated listener for the whole panel. Actions resolve shell-first, then the
    // active section's map — a section can never shadow wpClose/wpNav.
    _panelEl.addEventListener('click', (e) => {
        const el = e.target.closest('[data-action]');
        if (!el || !_panelEl.contains(el)) return;
        dispatchAction(el.dataset.action, el, e);
    });
    _panelEl.addEventListener('change', (e) => {
        const el = e.target.closest('[data-change]');
        if (!el) return;
        dispatchAction(el.dataset.change, el, e);
    });
    _panelEl.addEventListener('input', (e) => {
        const el = e.target.closest('[data-input]');
        if (!el) return;
        dispatchAction(el.dataset.input, el, e);
    });
    // Enter submits the form an input belongs to — the same action grammar as clicks.
    // An input declaring data-enter names the action its Enter fires; without this,
    // every inline form (kick reason, hire, phone number) was mouse-forced at exactly
    // the moment the admin's hands were on the keyboard.
    _panelEl.addEventListener('keydown', (e) => {
        // A tab row: Left / Right (Home / End) go to the next tab and open it.
        const tab = e.target.closest && e.target.closest('[role="tab"]');
        if (tab && /^(ArrowLeft|ArrowRight|Home|End)$/.test(e.key)) {
            const row = [...tab.parentElement.querySelectorAll('[role="tab"]')];
            const at = row.indexOf(tab);
            const to = e.key === 'Home' ? 0 : e.key === 'End' ? row.length - 1
                : (at + (e.key === 'ArrowRight' ? 1 : -1) + row.length) % row.length;
            e.preventDefault();
            if (row[to] && row[to] !== tab) { row[to].click(); row[to].focus(); }
            return;
        }
        // A pick box (WP.picks) is a span: Space or Enter ticks it, as a checkbox's would.
        const box = e.target.closest && e.target.closest('.wp-pick-box');
        if (box && (e.key === ' ' || e.key === 'Enter')) {
            e.preventDefault();
            dispatchAction(box.dataset.action, box, e);
            return;
        }
        if (e.key !== 'Enter') return;
        const el = e.target.closest('[data-enter]');
        if (!el) return;
        e.preventDefault();
        dispatchAction(el.dataset.enter, el, e);
    });
}

/**
 * A SECTION'S TOOLBAR LIVES AT THE TOP OF ITS LIST (the search, the filters and the New button).
 * Every section builds WP.toolbar() above its list | detail split; it is moved here, once, for
 * every section: a toolbar directly above a .wp-split goes into that
 * split's list column, and the detail pane gets its full height. whip-panel.css stacks it there
 * (.wp-list-col > .wp-toolbar): the search on its own line, the rest under it.
 *
 * Only a toolbar directly above a split: one above a section's own view tabs or
 * over a single pane (the Event Monitor's) belongs to the whole section and stays where it is. A
 * toolbar a section later swaps for another with replaceWith (Interactions, per tab) is replaced in
 * place, so it stays docked.
 */
function dockToolbars(root) {
    for (const bar of root.querySelectorAll('.wp-toolbar')) {
        const split = bar.nextElementSibling;
        if (!split || !split.classList.contains('wp-split')) continue;
        const col = [...split.children].find((c) => c.classList.contains('wp-list-col'));
        if (col) col.prepend(bar);
    }
}

const SHELL_ACTIONS = {
    wpClose: () => wpRequestClose(),
    wpNav: (el) => switchTo(el.dataset.arg),
    wpGroup: (el) => openGroup(el.dataset.arg),
    wpToggleGroup: (el) => {
        const group = el.closest('.wp-group');
        if (!group) return;
        const open = group.classList.toggle('open');
        el.setAttribute('aria-expanded', open ? 'true' : 'false');
        const key = _active + ':' + (group.dataset.group || '');
        _groupState.set(key, open);
    },
    // The shared widgets' clicks. Shell actions, like wpToggleGroup, so a section using a
    // widget adds nothing to its own action map; the widget is found by its id (data-widget).
    wpTabGo: (el) => {
        const w = _widgets.get(el.dataset.widget);
        if (w && w.go) w.go(el.dataset.arg);
    },
    wpStepGo: (el) => {
        const w = _widgets.get(el.dataset.widget);
        if (w && w.jump) w.jump(el.dataset.arg);
    },
    wpStepNav: (el) => {
        const w = _widgets.get(el.dataset.widget);
        if (w && w.nav) w.nav(el.dataset.arg);
    },
    wpPickToggle: (el, e) => {
        if (e) e.stopPropagation();   // a box inside a list row: the pick, not the row's own click
        const w = _widgets.get(el.dataset.widget);
        if (w && w.toggle) w.toggle(el.dataset.arg);
    },
    wpPickClear: (el) => {
        const w = _widgets.get(el.dataset.widget);
        if (w && w.clear) w.clear();
    },
};

function dispatchAction(name, el, event) {
    if (SHELL_ACTIONS[name]) { SHELL_ACTIONS[name](el, event); return; }
    const s = _active && _sections.get(_active);
    const fn = s && s.actions && s.actions[name];
    if (fn) fn(el, event);
}

// Collapse-state memory, page-lifetime (the emActiveTab precedent — no persistence).
const _groupState = new Map();

// ---- search memory ----
//
// THE SEARCH TEXT SURVIVES THE PANEL CLOSING. Every open rebuilds the skeleton and re-renders every
// section (buildSkeleton), while the section's own filter (a module variable) keeps its text. So the
// shell reads each section's boxes before it rebuilds,
// writes them back after render, and on entering the section fires the box's input action, so the
// section's filter is set from the box and the two always agree. A section that clears its search
// on purpose when its data arrives (Ground Items) clears the box with it, and they still agree.
//
// EVERY SEARCH BOX: a toolbar's, a
// picker's (props, NPCs, items, a person to add), a step's, the Event Monitor's — each box is known by
// its action, id or placeholder, so it finds its text again whether it is built in render or later.
// The text is handed over by firing the box's input event, which reaches its section's input action
// and a picker's own listener alike. A box the section only builds once its data lands is given its
// text then (wpSectionData), once.
const SEARCH_BOXES = '.wp-search input, .wp-section-search, .em-search';
const _searchMemory = new Map();    // section id -> { [box key]: text }, as the panel was last left
const _searchPending = new Map();   // section id -> { [box key]: text } not yet handed to the section

/** A section's search boxes, each with its key: what it is, and which of that kind in the page. */
function keyedSearchBoxes(root) {
    if (!root) return [];
    const seen = {};
    return Array.from(root.querySelectorAll(SEARCH_BOXES)).map((box) => {
        const base = box.dataset.searchKey || box.dataset.input || box.id || box.placeholder || 'search';
        const n = seen[base] = (seen[base] || 0) + 1;
        return { box, key: n > 1 ? base + '#' + n : base };
    });
}

/** Before a rebuild: what is typed in every section's search boxes (and any text still waiting for a
 *  box its section never built, so a second reopen keeps it too). */
function rememberSearches() {
    for (const id of Object.keys(_rootEls)) {
        const mem = Object.assign({}, _searchPending.get(id));
        for (const { box, key } of keyedSearchBoxes(_rootEls[id])) {
            if (box.value) mem[key] = box.value; else delete mem[key];
        }
        if (Object.keys(mem).length) _searchMemory.set(id, mem); else _searchMemory.delete(id);
    }
    _searchPending.clear();
}

/** After a section renders: its text back in its boxes, handed to the section when it is entered. */
function restoreSearches(id) {
    const mem = _searchMemory.get(id);
    if (!mem) return;
    _searchPending.set(id, Object.assign({}, mem));
    for (const { box, key } of keyedSearchBoxes(_rootEls[id])) {
        if (mem[key] != null && !box.value) box.value = mem[key];
    }
}

/** The active section's filters set from its restored text: each remembered box's input fired, once.
 *  On entering (after onEnter, so its actions are the ones reached), and after its data lands. */
function replaySearches(id) {
    const pending = _searchPending.get(id);
    if (!pending || id !== _active) return;
    for (const { box, key } of keyedSearchBoxes(_rootEls[id])) {
        const text = pending[key];
        if (text == null) continue;
        delete pending[key];
        if (box.value && box.value !== text) continue;   // the section set its own text: that wins
        box.value = text;
        box.dispatchEvent(new Event('input', { bubbles: true }));
    }
    if (!Object.keys(pending).length) _searchPending.delete(id);
}

// ---- section switching ----

/** focus: optional, opened on one thing ({ vehicleId }, { userId }): the section's onFocus picks it, once entered. */
function switchTo(id, focus) {
    if (!allowedSection(id)) return;
    if (!_sections.has(id) || id === _active) {
        if (id === _active) return;
        console.error(`[whip-panel] unknown section "${id}"`);
        return;
    }

    if (_active) {
        const prev = _sections.get(_active);
        if (prev.onLeave) prev.onLeave();
        nuiCallback('wpSectionLeave', { id: _active });
        _navEls[_active].classList.remove('active');
        _navEls[_active].setAttribute('aria-selected', 'false');
        _navEls[_active].tabIndex = -1;
        _rootEls[_active].classList.remove('wp-section-active');
    }

    _active = id;
    const s = _sections.get(id);
    _navEls[id].classList.add('active');
    _navEls[id].setAttribute('aria-selected', 'true');
    _navEls[id].tabIndex = 0;
    _rootEls[id].classList.add('wp-section-active');
    showGroup(s.group);
    _groupLast.set(s.group, id);
    keepTabInView(id);
    setBadge(id, null);

    // Restore remembered collapse states for this section's groups.
    for (const group of _rootEls[id].querySelectorAll('.wp-group')) {
        const key = id + ':' + (group.dataset.group || '');
        if (_groupState.has(key)) group.classList.toggle('open', _groupState.get(key));
        const head = group.querySelector('.wp-group-head');
        if (head) head.setAttribute('aria-expanded', group.classList.contains('open') ? 'true' : 'false');
    }

    if (s.onEnter) s.onEnter();
    replaySearches(id);   // after onEnter, so the section is active and its input action is reached
    nuiCallback('wpSectionEnter', { id });   // Lua fires the section's data fetch
    if (focus && typeof focus === 'object' && s.onFocus) {
        try { s.onFocus(focus); } catch (e) { console.error('[whip-panel] onFocus', e); }
    }
}

/** Light a group's word and show its tabs. */
function showGroup(groupId) {
    for (const g of Object.keys(_groupEls)) {
        const on = g === groupId;
        _groupEls[g].classList.toggle('active', on);
        _groupEls[g].setAttribute('aria-selected', on ? 'true' : 'false');
        _groupEls[g].tabIndex = on ? 0 : -1;
        _tabSetEls[g].hidden = !on;
    }
}

/** A long group's tabs scroll sideways (a server with many satellite settings pages); keep the
 *  open one in view. Only when the row overflows, and only the row: nothing else may scroll. */
function keepTabInView(id) {
    const tab = _navEls[id];
    const set = tab && tab.parentElement;
    if (!set || set.scrollWidth <= set.clientWidth) return;
    const left = tab.offsetLeft;   // (.wp-tabset is positioned, so this is from its own edge)
    if (left < set.scrollLeft) set.scrollLeft = left;
    else if (left + tab.offsetWidth > set.scrollLeft + set.clientWidth) {
        set.scrollLeft = left + tab.offsetWidth - set.clientWidth;
    }
}

/** A group word: the section last open in that group, or its first. */
function openGroup(groupId) {
    const last = _groupLast.get(groupId);
    if (last && _sections.has(last) && allowedSection(last)) { switchTo(last); return; }
    const first = groupMembers(groupId)[0];
    if (first) switchTo(first.id);
}

// ---- lifecycle ----

function openWhipPanel(data) {
    _open = true;
    _suspended = false;
    _allowed = data && Array.isArray(data.sections) ? new Set(data.sections) : null;
    _permanent = !(data && data.permanent === false);
    for (const fn of _openHooks) {
        try { fn(data || {}); } catch (e) { console.error('[whip-panel] open hook', e); }
    }
    buildSkeleton();

    const target = (data && data.section && _sections.has(data.section) && allowedSection(data.section)) ? data.section
        : (_active && _sections.has(_active) && allowedSection(_active)) ? _active
        : firstSectionId();
    _active = null;            // force a real enter (leave of a stale id would misfire)
    // Opened on one thing (the object viewer's Open in WHIP Admin Menu): only on the section it asked for.
    if (target) switchTo(target, target === (data && data.section) ? data.focus : null);

    const overlay = document.getElementById('whip-panel-overlay');
    overlay.style.display = 'flex';
    overlay.classList.remove('wp-suspended');
    if (_active) keepTabInView(_active);   // (the row had no size until now)
}

function firstSectionId() {
    for (const group of GROUPS) {
        const members = groupMembers(group.id);
        if (members.length) return members[0].id;
    }
    return null;
}

function closeWhipPanel() {
    // Lua-driven close (the funnel already fired the section leave server-side events;
    // mirror the JS-side leave so section view state resets coherently).
    if (_active) {
        const s = _sections.get(_active);
        if (s && s.onLeave) s.onLeave();
    }
    _open = false;
    _suspended = false;
    setPeek(false);
    padCursor.hide();
    document.getElementById('whip-panel-overlay').style.display = 'none';
    PauseMap.release();   // the 3D map's buffers at the panel's map size go until a map draws again
}

function wpRequestClose() {
    nuiCallback('wpClose', {});   // Lua funnel: section leave -> unfocus -> closeWhipPanel
}

function wpSuspend() {
    _suspended = true;
    setPeek(false);
    padCursor.hide();   // (an editor in the world has the screen now)
    document.getElementById('whip-panel-overlay').classList.add('wp-suspended');
    const s = _active && _sections.get(_active);
    if (s && s.onSuspend) s.onSuspend();
}

function wpResume() {
    _suspended = false;
    document.getElementById('whip-panel-overlay').classList.remove('wp-suspended');
    const s = _active && _sections.get(_active);
    if (s && s.onResume) s.onResume();
}

// ---- peek: the cursor at the very top of the screen fades the panel (.wp-peek) to see the game behind it;
// moving back down brings it back. The gap between the two lines stops it flickering at the edge. The pad's
// cursor fires mousemove too, so it peeks the same way. ----
const PEEK_IN = 3;    // px from the top: fade
const PEEK_OUT = 40;  // px from the top: back

let _peek = false;
function setPeek(on) {
    if (_peek === on) return;
    _peek = on;
    document.getElementById('whip-panel-overlay').classList.toggle('wp-peek', on);
}

document.addEventListener('mousemove', (e) => {
    if (!_open || _suspended) { setPeek(false); return; }
    if (!_peek && e.clientY <= PEEK_IN) setPeek(true);
    else if (_peek && e.clientY > PEEK_OUT) setPeek(false);
}, { passive: true });

function wpSectionData(d) {
    const s = _sections.get(d.section);
    if (!s || !s.onData) return;
    // Guarded like render() below — a section's onData throwing on one broadcast must not
    // kill the shell's data path for every section after it.
    try {
        s.onData(d.kind, d.payload);
        replaySearches(d.section);   // a search box built only now gets its remembered text
    } catch (err) {
        console.error(`[whip-panel] section "${d.section}" onData threw:`, err);
    }
}

// ---- public surface ----

// The verbs the glyph atlas (html/js/glyphs.js) has no word for, drawn as its glyphs are: 24 x 24, a round 2.1 stroke.
// For WP.verb's disc: the Player Manager's and the Vehicles page's.
const STROKE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">';
export const VERB_GLYPHS = {
    // An arrow arriving at you (the dot).
    bring: STROKE + '<circle cx="4.8" cy="12" r="2.1" fill="currentColor" stroke="none"/><path d="M20 12H9.4"/><path d="M13.6 7.8 9.4 12l4.2 4.2"/></svg>',
    // Out of the door.
    kick: STROKE + '<path d="M9.6 4.2H6.4a2.2 2.2 0 0 0-2.2 2.2v11.2a2.2 2.2 0 0 0 2.2 2.2h3.2"/><path d="M9 12h11"/><path d="M15.8 7.8 20 12l-4.2 4.2"/></svg>',
    // No way in.
    ban: STROKE + '<circle cx="12" cy="12" r="8.2"/><path d="M6.2 6.2l11.6 11.6"/></svg>',
    // In through the door (kick's mirror).
    into: STROKE + '<path d="M14.4 4.2h3.2a2.2 2.2 0 0 1 2.2 2.2v11.2a2.2 2.2 0 0 1-2.2 2.2h-3.2"/><path d="M4 12h11"/><path d="M10.8 7.8 15 12l-4.2 4.2"/></svg>',
    key: STROKE + '<circle cx="7.4" cy="12" r="3.6"/><path d="M11 12h9.6"/><path d="M17.4 12v3.2"/><path d="M20.4 12v2.4"/></svg>',
    glovebox: STROKE + '<rect x="3.4" y="6.4" width="17.2" height="11.2" rx="2.2"/><path d="M9.4 10.6h5.2"/></svg>',
    freeze: STROKE + '<path d="M12 3v18"/><path d="M4.2 7.5l15.6 9"/><path d="M4.2 16.5l15.6-9"/><path d="M9.6 4.6 12 7l2.4-2.4"/><path d="M9.6 19.4 12 17l2.4 2.4"/></svg>',
    burst: STROKE + '<path d="M12 2.8l1.9 5 5.2-1.6-2.6 4.7 4.7 2.6-5.2 1 .8 5.3L12 16.2l-4.8 3.6.8-5.3-5.2-1 4.7-2.6-2.6-4.7 5.2 1.6z"/></svg>',
    tyre: STROKE + '<circle cx="12" cy="12" r="8.4"/><circle cx="12" cy="12" r="3.2"/><path d="M12 3.6v5.2M12 15.2v5.2M3.6 12h5.2M15.2 12h5.2"/></svg>',
    fling: STROKE + '<path d="M12 17.5V5"/><path d="M7.5 9.5 12 5l4.5 4.5"/><path d="M5 20.2h14"/></svg>',
    trash: STROKE + '<path d="M4.5 6.5h15"/><path d="M9.5 6.5V4.6h5v1.9"/><path d="M6.4 6.5l1 13.2h9.2l1-13.2"/><path d="M10.4 10.6v5.8M13.6 10.6v5.8"/></svg>',
    wrench: STROKE + '<path d="M15.5 4.2a4.3 4.3 0 0 0-4.6 5.6l-6.6 6.6a1.8 1.8 0 0 0 2.6 2.6l6.6-6.6a4.3 4.3 0 0 0 5.6-4.6l-2.7 2.7-2.6-.6-.6-2.6z"/></svg>',
};

export const WhipPanel = {
    registerSection(def) {
        if (!def || !def.id || !def.group || !def.label || typeof def.render !== 'function') {
            console.error('[whip-panel] bad section registration', def);
            return;
        }
        if (_sections.has(def.id)) {
            console.error(`[whip-panel] duplicate section "${def.id}"`);
            return;
        }
        _sections.set(def.id, def);
    },
    switchTo,
    setBadge,
    hasSection: (id) => _sections.has(id),
    /** May this admin open that section now (a player given one permission opens only its sections)? */
    canOpen: (id) => _sections.has(id) && allowedSection(id),
    /** fn(openMessage) before each open builds the tabs. */
    addOpenHook(fn) { if (typeof fn === 'function') _openHooks.push(fn); },
    isOpen: () => _open,
    isSuspended: () => _suspended,
    activeSection: () => _active,
    requestClose: wpRequestClose,
};

function setBadge(id, n) {
    if (n) _badgeCounts[id] = n; else delete _badgeCounts[id];
    const badge = _badgeEls[id];
    if (badge) {
        if (!n) {
            badge.style.display = 'none';
        } else {
            badge.textContent = String(n);
            badge.style.display = '';
        }
    }
    const s = _sections.get(id);
    if (s) paintGroupBadge(s.group);
}

/** A group word's badge: the sum of its sections' badges (numbers; a non-number counts as 1). */
function paintGroupBadge(groupId) {
    const badge = _groupBadgeEls[groupId];
    if (!badge) return;
    let sum = 0;
    for (const id of Object.keys(_badgeCounts)) {
        const s = _sections.get(id);
        if (!s || s.group !== groupId || !allowedSection(id)) continue;
        const n = Number(_badgeCounts[id]);
        sum += Number.isFinite(n) && n > 0 ? n : 1;
    }
    badge.textContent = String(sum);
    badge.hidden = sum === 0;
}

// ---- WP.place: a place on the map ----

const PLACE_ZOOM = 4.6;       // the small map: a few streets round the place (pause-map.js zoom: 2^zoom px a px0)
const PLACE_BIG_ZOOM = 5.4;   // Open map: closer, and it pans and zooms from there
const PLACE_MAX_ZOOM = 7.5;   // several marks close together: as close as the map goes (pause-map.js maxZoom)
const PLACE_DEEP_ZOOM = 9;    // Open map goes closer than the menu's map: a scenario's things a few metres apart
const PLACE_MIN_ZOOM = 1.4;   // marks all over the map: as far out as the map goes (pause-map.js minZoom)
const K0 = 0.33 / 16;         // px0 a world metre (pause-map.js toPx0's slope)
/** What a place map shows: the one place (GTA's plain blip, sprite 1, white, unless it has its own), or `marks`, each
 *  a blip, one of whip's glyphs (a scenario's NPCs, cars, props), or the thing's own picture over its glyph (pic,
 *  fit, frame: PauseMap.pictureMark). Each keeps its mark, for the card a click opens (openPlace). */
const placeBlips = (o) => (o.marks || [o]).map((m) => ({ x: m.x, y: m.y, name: m.name || '', glyph: m.glyph || null,
    pic: m.pic || null, fit: m.fit || null, frame: m.frame || null,
    sprite: m.sprite || 1, colour: m.colour || '#ffffff', mark: m }));
/** Where to look, and how close, to see every mark in a W x H map: their middle, as close as still fits them all.
 *  One place: on it, at `close`. */
function placeView(o, W, H, close) {
    const ms = o.marks || [o];
    if (!ms.length) return { x: Number(o.x) || 0, y: Number(o.y) || 0, zoom: close };   // no marks yet: on o's own x, y
    if (ms.length < 2) return { x: ms[0].x, y: ms[0].y, zoom: close };
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const m of ms) { x0 = Math.min(x0, m.x); x1 = Math.max(x1, m.x); y0 = Math.min(y0, m.y); y1 = Math.max(y1, m.y); }
    const across = (d) => Math.max(d, 25) * K0;   // at least 25 m across
    const zoom = Math.log2(Math.min((W * 0.7) / across(x1 - x0), (H * 0.7) / across(y1 - y0)));
    return { x: (x0 + x1) / 2, y: (y0 + y1) / 2, zoom: Math.max(PLACE_MIN_ZOOM, Math.min(PLACE_MAX_ZOOM, zoom)) };
}
/** A small map with its size now: the first time, looked at where its marks are (placeView); then drawn again. */
function placeSized(el) {
    if (!el._pmap) return;
    if (!el._placed && el.clientWidth) {
        el._placed = true;
        const v = placeView(el._place, el.clientWidth, el.clientHeight, PLACE_ZOOM);
        el._pmap.centreOn(v.x, v.y, v.zoom);
    } else el._pmap.render();
}
// A small map is made before it is in the page (no size yet): set up when it gets one, let go when it leaves.
const _placeSizes = typeof ResizeObserver === 'function'
    ? new ResizeObserver((entries) => {
        for (const e of entries) {
            if (!e.target.isConnected) { _placeSizes.unobserve(e.target); continue; }
            placeSized(e.target);
        }
    })
    : { observe: (el) => setTimeout(() => placeSized(el), 0) };

/** A picked mark's lines on a map (WP.place's `linesFor`: a car's takes), drawn once they come, unless another has been
 *  picked meanwhile (`still`); none until then. A line running out of view: the map steps back until all of it (and
 *  the mark) is in it, never closer than it was. */
function placeLines(map, opts, mark, still) {
    map.setData({ lines: [] });
    if (!opts.linesFor || !mark) return;
    Promise.resolve(opts.linesFor(mark)).then((lines) => {
        if (!still()) return;
        map.setData({ lines: lines || [] });
        let x0 = mark.x, x1 = mark.x, y0 = mark.y, y1 = mark.y;
        for (const l of lines || []) {
            for (const [x, y] of l.points || []) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
        }
        const W = map.root.clientWidth, H = map.root.clientHeight;
        if (!W || !H) return;
        const corners = [[x0, y0], [x1, y1]].map(([x, y]) => map.screenOf(x, y));
        const inView = corners.every(([sx, sy]) => sx >= 0 && sy >= 0 && sx <= W && sy <= H);
        if (inView) return;
        const zoom = Math.log2(Math.min((W * 0.8) / Math.max(25, x1 - x0) / K0, (H * 0.8) / Math.max(25, y1 - y0) / K0));
        map.centreOn((x0 + x1) / 2, (y0 + y1) / 2, Math.max(map.minZoom, Math.min(map.zoom, zoom)));
    }, () => {});
}

/** Open map: the place big, over the panel and outside its zoom (the map reads the pointer in screen px). One at a
 *  time; Esc and Close put it away, as they do a confirm. Its map is placeArea's, and so is the answer.
 *  A page's own: `hint` under the title, `actions` ([{ label, kind?, onClick(area) }]) beside Close, `closeLabel`,
 *  and `onClose()` once it is put away. */
function openPlace(opts, pick) {
    const overlay = document.getElementById('whip-panel-overlay');
    if (!overlay) return null;
    WP.dismissDialog();
    const returnFocus = document.activeElement;
    const back = WP.el('div', 'wp-place-big');
    const card = WP.el('div', 'wp-place-big-card');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    const head = WP.el('div', 'wp-place-big-head');
    const words = WP.el('div', 'wp-place-big-words');
    words.appendChild(WP.el('span', 'wp-place-big-title', opts.name || 'On the map'));
    if (opts.hint) words.appendChild(WP.el('span', 'wp-hint', opts.hint));
    head.appendChild(words);
    const buttons = WP.el('div', 'wp-place-big-actions');
    let area = null;
    for (const a of opts.actions || []) {
        const b = WP.el('button', 'wp-btn' + (a.kind ? ' wp-btn-' + a.kind : ''), a.label);
        b.type = 'button';
        b.addEventListener('click', () => { if (area) a.onClick(area); });
        buttons.appendChild(b);
    }
    const close = WP.el('button', 'wp-btn', opts.closeLabel || 'Close');
    close.type = 'button';
    buttons.appendChild(close);
    head.appendChild(buttons);
    card.appendChild(head);
    back.appendChild(card);
    overlay.appendChild(back);
    area = placeArea(card, opts, pick);
    const done = () => {
        if (WP._dialogClose === done) WP._dialogClose = null;
        back.remove();
        if (returnFocus && returnFocus.focus && document.contains(returnFocus)) returnFocus.focus();
        if (opts.onClose) opts.onClose();
    };
    WP._dialogClose = done;
    close.addEventListener('click', done);
    back.addEventListener('click', (e) => { if (e.target === back) done(); });
    close.focus();
    return area;
}

/** THE BIG MAP ITSELF, filling the rest of `host` (in the page already, so it can be measured): it pans and zooms
 *  closer than the small one (the wheel, or + and -), and with `opts.card` a click on a mark opens that mark's card
 *  over it (the things on the same spot listed under it); `pick`, a mark, opens with its card up (a click on the small
 *  map's mark). Open map's, and the world builder's Map window's (director/map.js). With `opts.onMove(mark, x, y)`, a
 *  mark is dragged to a new place, and told once it is let go.
 *  Answers { map, update(marks), pick(id), player(pose) }: `update` puts the marks where they are now (a thing moved in
 *  the world), each kept by its `id` (its card staying up); `pick` puts the card of the mark with that id up; `player`
 *  the arrow ({ x, y, heading }, or null). */
function placeArea(host, opts, pick) {
    const area = WP.el('div', 'wp-place-big-map');   // the map fills it (.pmap is absolute, inset 0)
    const box = WP.el('div');
    area.appendChild(box);
    host.appendChild(area);
    const map = new PauseMap(box);
    map.maxZoom = PLACE_DEEP_ZOOM;
    map.setInteractive(true);
    let blips = placeBlips(opts);
    map.setData({ blips });
    if (opts.onMove) {
        area.classList.add('wp-place-movable');
        map.onBlipDrag = (b, x, y, done) => { if (done) opts.onMove(b.mark, x, y); };
    }
    const v = placeView(opts, box.clientWidth || 1200, box.clientHeight || 700, PLACE_BIG_ZOOM);
    map.centreOn(v.x, v.y, v.zoom);
    let cur = null;   // the mark whose card is up (its lines drawn: placeLines)
    let show = null, shut = null;

    // + and -: the wheel's zoom, for whoever does not know the wheel does it.
    const zooms = WP.el('div', 'wp-place-zoom');
    for (const [label, text, dz] of [['Zoom in', '+', 1], ['Zoom out', '−', -1]]) {
        const b = WP.el('button', 'wp-btn wp-place-zoom-btn', text);
        b.type = 'button';
        b.setAttribute('aria-label', label);
        b.title = label;
        b.addEventListener('click', () => map.glide(map.offsetX, map.zoom + dz, 180));
        zooms.appendChild(b);
    }
    area.appendChild(zooms);

    // A mark's card: the page's words for it (opts.card), with the other marks on the same spot under it.
    if (opts.card) {
        const info = WP.el('div', 'wp-place-info');
        info.hidden = true;
        area.appendChild(info);
        shut = () => { info.hidden = true; info.innerHTML = ''; map.setPicked(null); cur = null; map.setData({ lines: [] }); };
        show = (b, here) => {
            if (cur !== b.mark) {
                cur = b.mark;
                // (Still the one up when its lines come: by its id, as update replaces the mark it keeps.)
                const mark = b.mark;
                placeLines(map, opts, mark, () => cur === mark || (cur != null && mark.id != null && cur.id === mark.id));
            }
            info.innerHTML = '';
            // The box scrolls at the map's height; its inside is zoomed to the panel's size.
            const inner = WP.el('div', 'wp-place-info-in');
            info.appendChild(inner);
            const x = WP.el('button', 'wp-place-info-x', '×');
            x.type = 'button';
            x.setAttribute('aria-label', 'Close this card');
            x.addEventListener('click', shut);
            inner.appendChild(x);
            const body = opts.card(b.mark);
            if (body) inner.appendChild(body);
            const others = here.filter((o) => o !== b);
            if (others.length) {
                const also = WP.el('div', 'wp-place-info-also');
                also.appendChild(WP.el('span', 'wp-place-info-also-title', 'Also here'));
                for (const o of others) {
                    const go = WP.el('button', 'wp-btn wp-btn-sm', o.name || 'Unnamed');
                    go.type = 'button';
                    go.addEventListener('click', () => show(o, here));
                    also.appendChild(go);
                }
                inner.appendChild(also);
            }
            info.hidden = false;
            info.scrollTop = 0;
            map.setPicked(b);
        };
        map.onBlipClick = (b) => show(b, hereOf(b));
        // A click on the map itself (not a drag, not a mark: those stop at the map) puts the card away.
        let down = null;
        area.addEventListener('pointerdown', (e) => { down = { x: e.clientX, y: e.clientY }; }, true);
        area.addEventListener('click', (e) => {
            if (info.hidden || info.contains(e.target) || zooms.contains(e.target)) return;
            if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) <= 6) shut();
        });
        const first = pick && blips.find((b) => b.mark === pick);
        if (first) {
            map.centreOn(first.x, first.y, Math.max(map.zoom, PLACE_BIG_ZOOM));
            show(first, hereOf(first));
        }
    }
    // The marks a click lands on: the one it found, and every other drawn on top of it.
    function hereOf(b) {
        const [bx, by] = map.screenOf(b.x, b.y);
        const r = map.blipSize * (map.markScale || 1) * 0.6;
        return blips.filter((o) => { const [ox, oy] = map.screenOf(o.x, o.y); return Math.hypot(ox - bx, oy - by) <= r; });
    }
    const looks = (b) => [b.mark.id, b.name, b.pic, b.glyph, b.fit, JSON.stringify(b.frame)].join('\u0001');
    return {
        map,
        update(marks) {
            const next = placeBlips({ ...opts, marks });
            // The same marks (by id), only moved or changed inside: moved where they are, nothing drawn again (a
            // picture made again would flash its glyph while it loads).
            const same = next.length === blips.length && next.every((b, i) => b.mark.id != null && looks(b) === looks(blips[i]));
            if (same) {
                next.forEach((b, i) => { blips[i].x = b.x; blips[i].y = b.y; blips[i].mark = b.mark; });
                map.render();
            } else {
                blips = next;
                map.setData({ blips });
            }
            // Its card stays up on the same thing, written again only when what it says changed (not where it is);
            // gone with it, the card goes.
            if (cur && show) {
                const b = cur.id != null ? blips.find((x) => x.mark.id === cur.id) : null;
                if (!b) { shut(); return; }
                const said = (m) => JSON.stringify(m, (k, v) => (k === 'x' || k === 'y' ? undefined : v));
                const changed = said(b.mark) !== said(cur);
                cur = b.mark;
                if (changed) show(b, hereOf(b));
                else map.setPicked(b);
            }
        },
        pick(id) {
            const b = blips.find((x) => x.mark.id === id);
            if (b && show) show(b, hereOf(b));
        },
        /** The arrow: where the camera (or the player) is, { x, y, heading } as the game has them. */
        player(pose) { if (pose) map.setData({ player: pose }); },
    };
}

// ---- WP: the shared component helpers ----
// Sections build DOM through these (textContent only — player names flow through here).

export const WP = {
    el(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
    },

    /** Two-line list row (the player-manager anatomy). opts: {title, sub, pill, pillClass, id, action}
     *  A real <button>, so every list→detail flow is focusable and keyboard-operable. */
    listItem(opts) {
        const item = WP.el('button', 'wp-list-item');
        item.type = 'button';
        if (opts.id !== undefined) item.dataset.id = opts.id;
        if (opts.action) item.dataset.action = opts.action;
        const top = WP.el('div', 'wp-item-top');
        top.appendChild(WP.el('span', 'wp-item-title', opts.title));
        if (opts.pill !== undefined && opts.pill !== null) {
            top.appendChild(WP.el('span', 'wp-pill ' + (opts.pillClass || ''), String(opts.pill)));
        }
        item.appendChild(top);
        if (opts.sub) item.appendChild(WP.el('div', 'wp-item-sub', opts.sub));
        return item;
    },

    /** Collapsible field group. Returns {root, body}. */
    group(key, label, open) {
        const root = WP.el('div', 'wp-group' + (open ? ' open' : ''));
        root.dataset.group = key;
        const head = WP.el('button', 'wp-group-head');
        head.type = 'button';
        head.dataset.action = 'wpToggleGroup';
        head.setAttribute('aria-expanded', open ? 'true' : 'false');
        const caret = WP.el('span', 'wp-group-caret');
        caret.innerHTML = CHEVRON_ICON;   // a fixed icon, no data
        head.appendChild(caret);
        head.appendChild(WP.el('span', 'wp-group-label', label));
        root.appendChild(head);
        const body = WP.el('div', 'wp-group-body');
        root.appendChild(body);
        return { root, body };
    },

    /** Labeled field capsule around an input/select the caller made. */
    field(label, inputEl, wide) {
        const f = WP.el('label', 'wp-field' + (wide ? ' wp-field-full' : ''));
        f.appendChild(WP.el('span', 'wp-field-label', label));
        f.appendChild(inputEl);
        return f;
    },

    input(opts) {
        const i = WP.el('input', 'wp-input');
        i.type = opts && opts.type || 'text';
        if (opts && opts.placeholder) i.placeholder = opts.placeholder;
        if (opts && opts.value !== undefined) i.value = opts.value;
        if (opts && opts.inputAction) i.dataset.input = opts.inputAction;
        if (opts && opts.enterAction) i.dataset.enter = opts.enterAction;
        if (opts && opts.id) i.id = opts.id;
        return i;
    },

    select(options, opts) {
        const sel = WP.el('select', 'wp-select');
        for (const o of options) {
            const opt = WP.el('option', null, o.label !== undefined ? o.label : String(o.value));
            opt.value = o.value;
            sel.appendChild(opt);
        }
        if (opts && opts.changeAction) sel.dataset.change = opts.changeAction;
        if (opts && opts.id) sel.id = opts.id;
        return sel;
    },

    /** A verb's card (.wp-verb): its icon in a small stat disc, the verb, and a line under it saying what it does, with
     *  ._name and ._sub on the button to say things on. `glyph` is fixed markup: the glyph atlas's
     *  (window.WhipGlyphs) or VERB_GLYPHS. */
    verb(glyph, label, action, danger, arg) {
        const b = WP.el('button', 'wp-verb' + (danger ? ' wp-verb-danger' : ''));
        b.type = 'button';
        b.dataset.action = action;
        if (arg !== undefined) b.dataset.arg = arg;
        const disc = WP.el('span', 'wp-verb-disc');
        disc.innerHTML = glyph || '';   // fixed markup, no data
        b.appendChild(disc);
        const text = WP.el('span', 'wp-verb-text');
        b._name = WP.el('span', 'wp-verb-name', label);
        b._sub = WP.el('span', 'wp-verb-sub', '');
        text.appendChild(b._name);
        text.appendChild(b._sub);
        b.appendChild(text);
        return b;
    },

    btn(label, action, kind, arg) {
        const b = WP.el('button', 'wp-btn' + (kind ? ' wp-btn-' + kind : ''), label);
        if (action) b.dataset.action = action;
        if (arg !== undefined) b.dataset.arg = arg;
        return b;
    },

    /** Per-section toolbar: {left: [els], search: {inputAction, placeholder}, right: [els]}.
     *  Put it directly above the section's .wp-split and the shell moves it to the top of the
     *  list column (dockToolbars): the search on top, then left, then right. */
    toolbar(opts) {
        const bar = WP.el('div', 'wp-toolbar');
        for (const el of (opts.left || [])) bar.appendChild(el);
        bar.appendChild(WP.el('div', 'wp-toolbar-spacer'));
        if (opts.search) {
            // The search box, with a magnifier in it. The box is still the toolbar's .wp-input
            // (sectionSearch, '/' and the pad's Y find it by that), inside a label for the icon.
            const wrap = WP.el('label', 'wp-search');
            const icon = WP.el('span', 'wp-search-icon');
            icon.innerHTML = SEARCH_ICON;   // a fixed icon, no data
            wrap.appendChild(icon);
            const input = WP.input({
                placeholder: opts.search.placeholder || 'Search…',
                inputAction: opts.search.inputAction,
                id: opts.search.id,
            });
            input.setAttribute('aria-label', input.placeholder);
            wrap.appendChild(input);
            bar.appendChild(wrap);
        }
        for (const el of (opts.right || [])) bar.appendChild(el);
        return bar;
    },

    empty(text) {
        return WP.el('div', 'wp-empty', text);
    },

    /** A number tile: its label, the value big, a line under it. `tone` ('good', 'bad'...) adds wp-stat-<tone>.
     *  A row of them goes in a .wp-stats. */
    stat(label, value, sub, tone) {
        const el = WP.el('div', 'wp-stat' + (tone ? ' wp-stat-' + tone : ''));
        el.appendChild(WP.el('div', 'wp-stat-label', label));
        el.appendChild(WP.el('div', 'wp-stat-value', value));
        if (sub) el.appendChild(WP.el('div', 'wp-stat-sub', sub));
        return el;
    },

    /** A row of choices, one of them lit (a period: 7 days, 14 days...). list: [{ key, label }]; a click is
     *  `action` with the key as its arg. */
    toggles(action, list, active) {
        const row = WP.el('div', 'wp-toggles');
        for (const o of list) {
            const b = WP.el('button', 'wp-toggle' + (String(o.key) === String(active) ? ' active' : ''), o.label);
            b.type = 'button';
            b.dataset.action = action;
            b.dataset.arg = String(o.key);
            row.appendChild(b);
        }
        return row;
    },

    /** An SVG element (a chart's bars and labels): attrs set as given, `text` as its text. */
    svg(tag, attrs, text) {
        const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
        for (const k of Object.keys(attrs || {})) el.setAttribute(k, attrs[k]);
        if (text !== undefined) el.textContent = text;
        return el;
    },

    /**
     * Tabs: one row of choices, one of them active. The Event Monitor's tabs, made shared.
     *
     *   const t = WP.tabs({ id: 'pc-space-tabs', tabs: [{ key, label, badge? }], active?,
     *                       inline?, onChange(key, prevKey) });
     *   pane.appendChild(t.root);   t.get()   t.set(key)   (set does not call onChange)
     *
     * `id` must be unique in the panel; the clicks are the shell's wpTabGo, which finds the
     * widget by it. `inline` drops the section-width rail styling, for tabs inside a pane.
     */
    tabs(opts) {
        const root = WP.el('div', 'wp-tabs' + (opts.inline ? ' wp-tabs-inline' : ''));
        root.setAttribute('role', 'tablist');
        const btns = {};
        let active = null;
        for (const t of opts.tabs || []) {
            const b = WP.el('button', 'wp-tab', t.label);
            b.type = 'button';
            b.setAttribute('role', 'tab');
            b.dataset.action = 'wpTabGo';
            b.dataset.widget = opts.id;
            b.dataset.arg = t.key;
            if (t.badge !== undefined && t.badge !== null) b.appendChild(WP.el('span', 'wp-pill', String(t.badge)));
            btns[t.key] = b;
            root.appendChild(b);
        }
        const w = {
            root,
            get: () => active,
            set(key) {
                if (!btns[key]) return;
                active = key;
                for (const k of Object.keys(btns)) {
                    btns[k].classList.toggle('wp-tab-active', k === key);
                    btns[k].setAttribute('aria-selected', k === key ? 'true' : 'false');
                }
            },
            go(key) {
                if (key === active || !btns[key]) return;
                const prev = active;
                w.set(key);
                if (opts.onChange) opts.onChange(key, prev);
            },
        };
        w.set(opts.active || (opts.tabs && opts.tabs[0] && opts.tabs[0].key));
        _widgets.set(opts.id, w);
        return w;
    },

    /**
     * PICK SEVERAL, ACT ONCE: a box on each row of a list and, while any is picked, a bar over the list saying how
     * many, with the action and Clear.
     *
     *   const pk = WP.picks({ id: 'gw-bays', one: 'bay', many: 'bays',
     *                         actions: [{ label: (n) => 'Remove ' + n, action: 'gwBaysRemove', kind: 'danger' }] });
     *   body.appendChild(pk.bar());     // drawn with the list, for what is picked now
     *   row.prepend(pk.box(key));       // each row's box (a span: it may sit inside a list row's button)
     *   pk.keys()   pk.clear()   pk.keep(keysStillThere)
     *
     * The picks live in the widget, by id, so a list drawn again keeps them; keep() drops the ones gone from it.
     * The boxes and Clear are the shell's (wpPickToggle / wpPickClear); the actions are the section's, reading keys().
     */
    picks(opts) {
        const had = _widgets.get(opts.id);
        if (had && had.picks) { had.opts = opts; return had; }
        const picked = new Set();
        const paintBox = (b) => {
            const on = picked.has(b.dataset.arg);
            b.classList.toggle('on', on);
            b.setAttribute('aria-checked', on ? 'true' : 'false');
            b.textContent = on ? '✓' : '';
        };
        const fillBar = (bar) => {
            const n = picked.size;
            bar.hidden = n === 0;
            bar.innerHTML = '';
            if (!n) return;
            const o = w.opts;
            bar.appendChild(WP.el('span', 'wp-info-label', n + ' ' + (n === 1 ? o.one : o.many) + ' picked'));
            bar.appendChild(WP.el('span', 'wp-actions-split'));
            const clear = WP.btn('Clear', 'wpPickClear', 'ghost wp-btn-sm');
            clear.dataset.widget = o.id;
            bar.appendChild(clear);
            for (const a of o.actions || []) bar.appendChild(WP.btn(a.label(n), a.action, a.kind));
        };
        const w = {
            picks: true,
            opts,
            keys: () => [...picked],
            paint() {
                if (!_panelEl) return;
                for (const b of _panelEl.querySelectorAll('.wp-pick-box')) if (b.dataset.widget === w.opts.id) paintBox(b);
                for (const bar of _panelEl.querySelectorAll('.wp-pick-bar')) if (bar.dataset.widget === w.opts.id) fillBar(bar);
            },
            toggle(key) {
                key = String(key);
                if (picked.has(key)) picked.delete(key); else picked.add(key);
                w.paint();
            },
            clear() { picked.clear(); w.paint(); },
            keep(keys) {
                const live = new Set(keys.map(String));
                for (const k of [...picked]) if (!live.has(k)) picked.delete(k);
            },
            box(key) {
                const b = WP.el('span', 'wp-pick-box');
                b.setAttribute('role', 'checkbox');
                b.setAttribute('aria-label', 'Pick');
                b.tabIndex = 0;
                b.dataset.action = 'wpPickToggle';
                b.dataset.widget = w.opts.id;
                b.dataset.arg = String(key);
                paintBox(b);
                return b;
            },
            bar() {
                const bar = WP.el('div', 'wp-pick-bar');
                bar.dataset.widget = w.opts.id;
                fillBar(bar);
                return bar;
            },
        };
        _widgets.set(opts.id, w);
        return w;
    },

    /**
     * A PLACE ON THE MAP, under the row that names it: whip's GTA map (pause-map.js), small, with the place's mark
     * on it, and Open map to see it big over the panel (drag and scroll; Esc or Close puts it away). Places are
     * read on the map, not as coordinates.
     *
     *   row.after(WP.place({ x, y, name: 'Evidence locker', sprite?: 357, colour?: '#60a5fa' }));
     *   WP.place({ name: 'Bank Robbery', marks: [{ x, y, name: 'Bank guard', glyph: GLYPHS.person, pic?, fit? }, ...],
     *              card?: (mark) => element, linesFor?: (mark) => Promise<[{ points: [[x, y], ...], colour }] | null> })
     *
     * With `marks`, every one is on it, the map looking at all of them (as close as still fits them); a mark is a
     * blip (sprite, colour), one of whip's glyphs (an SVG of ours), or its own picture over its glyph (`pic`, a URL;
     * `fit: 'face'` for a ped's whole-body picture; `frame` for a framed portrait). With `card`, a click on a mark
     * opens the map big with the card `card(mark)` makes beside it. With `linesFor` too, a click on the small map
     * picks the mark there and draws its lines (a car's drives); a second click on it, or Open map, opens it big, its
     * card up and its lines drawn there as well. With `onOpen()` (and `openLabel`), the button does the page's own
     * instead (its editor, on WP.openPlace).
     */
    place(opts) {
        const wrap = WP.el('div', 'wp-place');
        const box = WP.el('div', 'wp-place-map');
        box.setAttribute('role', 'img');
        box.setAttribute('aria-label', (opts.name || 'The place') + ' on the map');
        wrap.appendChild(box);
        let picked = null;   // the mark picked on this small map (linesFor): Open map opens on it
        const open = WP.el('button', 'wp-btn wp-btn-sm wp-place-open', opts.openLabel || 'Open map');
        open.type = 'button';
        open.addEventListener('click', () => (opts.onOpen ? opts.onOpen() : openPlace(opts, picked || undefined)));
        wrap.appendChild(open);
        const map = new PauseMap(box);
        map.setData({ blips: placeBlips(opts) });
        // With cards: a click on a mark opens the map big, that mark's card up. With lines to draw, it picks it here
        // first (its lines on this map), and the second click on it opens it big.
        if (opts.card) {
            map.onBlipClick = (b) => {
                if (!opts.linesFor || picked === b.mark) { openPlace(opts, b.mark); return; }
                picked = b.mark;
                map.setPicked(b);
                placeLines(map, opts, b.mark, () => picked === b.mark);
            };
            wrap.classList.add('wp-place-cards');
        }
        box._pmap = map;
        box._place = opts;
        _placeSizes.observe(box);   // looked at and drawn once it has a size (placeSized)
        return wrap;
    },

    /**
     * The big map, in a box of your own (Open map's insides): `host` is in the page already, and the map fills the
     * rest of it. Same `opts` as WP.place; each mark may carry an `id`, to be kept by it as it moves.
     *
     *   const m = WP.placeArea(host, { marks, card, linesFor });   m.update(marks);   m.player({ x, y, heading });
     */
    placeArea(host, opts, pick) { return placeArea(host, opts, pick); },

    /**
     * Open map from a page's own button: the big map over the panel (Esc or Close puts it away), with the page's
     * buttons in its head. Same `opts` as WP.place and WP.placeArea (onMove: marks dragged), and the head's own:
     *
     *   const m = WP.openPlace({ name, hint, marks, card, onMove, actions: [{ label, kind, onClick(m) }],
     *                            closeLabel: 'Done', onClose() }, pickMark);
     *
     * Answers placeArea's { map, update, pick, player }, or null when the panel is not up.
     */
    openPlace(opts, pick) { return openPlace(opts, pick); },

    /**
     * How something stands, as a mark (ticks and crosses, not status lights):
     * an outline circle with the mark bigger than it, breaking out of it —
     *   'ok'   a green tick         'err'  a red cross
     *   'warn' an amber "!"         'info' a blue "i" (a fact, not a pass or a fail)
     *   anything else ('todo', 'off'): the empty circle, dim
     * For a pass/fail. A light that says someone is HERE (online, on duty, inside a zone, the live
     * feed) stays a .wp-dot.
     */
    mark(status) {
        const kind = { ok: 'ok', err: 'err', warn: 'warn', info: 'info' }[status] || 'off';
        const m = WP.el('span', 'wp-mark wp-mark-' + kind);
        m.setAttribute('aria-label', { ok: 'Done', err: 'Problem', warn: 'Needs a look', info: 'About it', off: 'Not set' }[kind]);
        m.innerHTML = MARK_ICONS[kind];   // fixed markup, no data
        return m;
    },

    /**
     * One part of something, and how it stands: a mark (WP.mark), a name, a line of detail, and
     * optionally the button that fixes it. The Configurator's "Interior / Space / Doors /
     * Garage" summary is a column of these.
     *
     *   WP.statusRow({ label: 'Doors', status: 'ok' | 'warn' | 'err' | 'todo' | 'off',
     *                  detail: '2 entrances, 1 garage', action: 'pcEditPart', arg: 'doors',
     *                  actionLabel: 'Edit' })
     *
     * 'todo' is not started yet; 'off' is a part this thing does not use (no garage).
     * `sub: true` indents it under the row before (a unit under its template).
     * `control: [el, ...]` puts the caller's own controls (a select or two) where the button
     * would go, for a row that is changed in place rather than opened.
     * `yesNo: { on, action, arg }` makes it a yes or no you click, like a toggle switch: the mark is a green tick for yes and a
     * red cross for no, and it and the row's name both fire `action` (with `arg`) to flip it.
     */
    statusRow(opts) {
        const yn = opts.yesNo || null;
        const status = yn ? (yn.on ? 'ok' : 'off') : (opts.status || 'todo');
        const row = WP.el('div', 'wp-status-row wp-status-row-' + status + (opts.sub ? ' wp-status-row-sub' : ''));
        if (yn) {
            row.classList.add('wp-status-row-yesno');
            const m = WP.mark(yn.on ? 'ok' : 'err');
            const b = WP.el('button', 'wp-mark-btn');
            b.type = 'button';
            b.dataset.action = yn.action;
            if (yn.arg !== undefined) b.dataset.arg = yn.arg;
            b.setAttribute('role', 'switch');
            b.setAttribute('aria-checked', yn.on ? 'true' : 'false');
            b.setAttribute('aria-label', opts.label + (yn.on ? ': yes' : ': no'));
            b.appendChild(m);
            row.appendChild(b);
            const label = WP.el('span', 'wp-status-label wp-status-label-btn', opts.label);
            label.dataset.action = yn.action;
            if (yn.arg !== undefined) label.dataset.arg = yn.arg;
            row.appendChild(label);
        } else {
            row.appendChild(WP.mark(status));
            row.appendChild(WP.el('span', 'wp-status-label', opts.label));
        }
        row.appendChild(WP.el('span', 'wp-status-detail', opts.detail || ''));
        if (opts.control) {
            const slot = WP.el('span', 'wp-status-controls');
            for (const c of [].concat(opts.control)) slot.appendChild(c);
            row.appendChild(slot);
        } else if (opts.action) {
            const b = WP.btn(opts.actionLabel || 'Edit', opts.action, 'ghost', opts.arg);
            b.classList.add('wp-btn-sm');
            row.appendChild(b);
        } else {
            row.appendChild(WP.el('span'));
        }
        return row;
    },

    /**
     * A step-by-step form: a rail of steps along the top, the current step's content, and
     * Back / Skip / Next along the bottom. The Property Configurator's wizard is one.
     *
     *   const wiz = WP.stepper({
     *       id: 'pc-wizard',                              // unique in the panel
     *       steps: [{ key, label, optional? }],           // optional steps get a Skip button
     *       onGo(key, fromKey, body),                     // fill `body` for this step
     *       canLeave(fromKey, toKey, how),                // true, or a sentence saying why not;
     *                                                     //   may return a Promise. how: 'next' | 'jump'
     *       onFinish(),                                   // Next on the last step
     *       finishLabel: 'Save', nextLabel: 'Next',
     *       railInto: el,                                 // optional: the rail goes in here (a head row,
     *                                                     //   beside the wizard's title) and not on top
     *   });
     *   pane.appendChild(wiz.root);   wiz.start();      // start AFTER wiz is assigned: onGo runs
     *
     * THE RULES, so every wizard behaves the same:
     *   Next asks canLeave; a refusal is SAID, in the footer, and the step is marked in error.
     *   Back never asks — going back loses nothing.
     *   Skip is only offered on an optional step, and does not ask.
     *   The rail goes back to any step, and forward to any step already reached (asking
     *   canLeave first); an unreached step says which one to finish.
     *   wiz.escape() steps back and answers true, or answers false on the first step — call it
     *   from the section's onEscape.
     *
     * Also: wiz.go(key) (no questions asked), wiz.current(), wiz.setStatus(key, 'done' |
     * 'error' | 'skipped' | null), wiz.say(text, 'ok' | 'err'), wiz.body.
     */
    stepper(opts) {
        const steps = opts.steps || [];
        const root = WP.el('div', 'wp-stepper');
        const rail = WP.el('div', 'wp-step-rail');
        const body = WP.el('div', 'wp-step-body');
        const foot = WP.el('div', 'wp-step-foot');
        const msg = WP.el('div', 'wp-step-msg');
        const railBtns = {};

        steps.forEach((s, i) => {
            const b = WP.el('button', 'wp-step');
            b.type = 'button';
            b.dataset.action = 'wpStepGo';
            b.dataset.widget = opts.id;
            b.dataset.arg = s.key;
            b.appendChild(WP.el('span', 'wp-step-num', String(i + 1)));
            b.appendChild(WP.el('span', 'wp-step-label', s.label));
            railBtns[s.key] = b;
            rail.appendChild(b);
        });

        const navBtn = (label, arg, kind) => {
            const b = WP.btn(label, 'wpStepNav', kind, arg);
            b.dataset.widget = opts.id;
            return b;
        };
        const back = navBtn('Back', 'back', 'ghost');
        const skip = navBtn('Skip', 'skip', 'ghost');
        const next = navBtn(opts.nextLabel || 'Next', 'next', 'primary');
        foot.appendChild(back);
        foot.appendChild(msg);
        foot.appendChild(skip);
        foot.appendChild(next);

        if (opts.railInto) opts.railInto.appendChild(rail); else root.appendChild(rail);
        root.appendChild(body);
        root.appendChild(foot);

        const status = {};     // key -> 'done' | 'error' | 'skipped'
        let current = null;
        let reached = -1;      // the furthest step index visited
        let busy = false;

        const idx = (key) => steps.findIndex((s) => s.key === key);

        function paint() {
            const i = idx(current);
            steps.forEach((s, n) => {
                const b = railBtns[s.key];
                b.className = 'wp-step'
                    + (n === i ? ' wp-step-current' : '')
                    + (status[s.key] ? ' wp-step-' + status[s.key] : '')
                    + (n > reached ? ' wp-step-locked' : '');
                b.firstChild.textContent = status[s.key] === 'done' ? '✓'
                    : status[s.key] === 'skipped' ? '–' : String(n + 1);
                if (n === i) b.setAttribute('aria-current', 'step'); else b.removeAttribute('aria-current');
            });
            back.disabled = busy || i <= 0;
            skip.style.display = (i >= 0 && steps[i].optional) ? '' : 'none';
            skip.disabled = busy;
            next.disabled = busy;
            next.textContent = i === steps.length - 1 ? (opts.finishLabel || 'Finish') : (opts.nextLabel || 'Next');
        }

        function say(text, kind) {
            msg.textContent = text || '';
            msg.className = 'wp-step-msg' + (kind ? ' wp-step-msg-' + kind : '');
        }

        function enter(key, from) {
            current = key;
            reached = Math.max(reached, idx(key));
            say('');
            body.innerHTML = '';
            paint();
            if (opts.onGo) opts.onGo(key, from, body);
        }

        // Ask, with the buttons held while the answer is out: a Lua round trip must not be
        // clicked through twice.
        async function ask(from, to, how) {
            if (!opts.canLeave) return true;
            busy = true;
            paint();
            let verdict;
            try {
                verdict = await opts.canLeave(from, to, how);
            } catch (err) {
                console.error('[whip-panel] stepper canLeave threw:', err);
                verdict = 'Something went wrong checking this step';
            }
            busy = false;
            paint();
            if (verdict === true) return true;
            status[from] = 'error';
            say(typeof verdict === 'string' ? verdict : 'This step is not finished yet', 'err');
            paint();
            return false;
        }

        const w = {
            root,
            body,
            current: () => current,
            say,
            start(key) {
                for (const k of Object.keys(status)) delete status[k];
                reached = -1;
                if (steps.length) enter(key || steps[0].key, null);
            },
            go(key) {
                if (idx(key) >= 0) enter(key, current);
            },
            setStatus(key, s) {
                if (s) status[key] = s; else delete status[key];
                paint();
            },
            async nav(how) {
                if (busy || current === null) return;
                const i = idx(current);
                if (how === 'back') {
                    if (i > 0) enter(steps[i - 1].key, current);
                    return;
                }
                const last = i === steps.length - 1;
                if (how === 'skip') {
                    if (!steps[i].optional) return;
                    status[current] = 'skipped';
                } else {
                    if (!(await ask(current, last ? null : steps[i + 1].key, 'next'))) return;
                    status[current] = 'done';
                }
                if (last) {
                    paint();
                    if (opts.onFinish) opts.onFinish();
                    return;
                }
                enter(steps[i + 1].key, current);
            },
            async jump(key) {
                if (busy || current === null) return;
                const to = idx(key), i = idx(current);
                if (to < 0 || to === i) return;
                if (to > reached) {
                    say('Finish "' + steps[i].label + '" first', 'err');
                    return;
                }
                if (to > i) {
                    if (!(await ask(current, key, 'jump'))) return;
                    status[current] = 'done';
                }
                enter(key, current);
            },
            escape() {
                const i = idx(current);
                if (i > 0 && !busy) { enter(steps[i - 1].key, current); return true; }
                return false;
            },
        };
        _widgets.set(opts.id, w);
        return w;
    },

    /**
     * Confirm dialog inside the panel (the plm-dialog pattern, shell-level).
     * Resolves true/false. One at a time — a second call dismisses the first as false.
     *
     * EVERY WAY OUT RESOLVES. The section code sits at `await WP.confirm(...)`, and a
     * promise that is removed from the screen without being settled leaves that code
     * suspended forever — the button never re-enables, the cancel-branch cleanup never
     * runs, and nothing anywhere says why. The active resolver is held where Escape
     * (dismissDialog below) and a replacing confirm() can both reach it, so dismissal IS an
     * answer: false.
     */
    _dialogResolve: null,

    confirm(opts) {
        return new Promise((resolve) => {
            // A second dialog answers the first as cancelled — the JSDoc always said so;
            // now it is true.
            WP.dismissDialog();

            // Focus is borrowed and RETURNED: a keyboard admin who confirms a delete
            // should land back on the element they came from, not at the panel root.
            const returnFocus = document.activeElement;

            const backdrop = WP.el('div', 'wp-dialog-backdrop');
            // `wide`: room for a table; `noCancel`: only the one button (a window that shows, asks nothing).
            const dialog = WP.el('div', 'wp-dialog' + (opts.wide ? ' wp-dialog-wide' : ''));
            dialog.setAttribute('role', 'dialog');
            dialog.setAttribute('aria-modal', 'true');
            dialog.appendChild(WP.el('div', 'wp-dialog-title', opts.title || 'Confirm'));
            if (opts.body) dialog.appendChild(WP.el('div', 'wp-dialog-body', opts.body));
            // `content`: a control of the caller's under the words (a garage's delete asks where its cars go), and
            // `canConfirm`: whether it is answered — the confirm button waits for it, asked on every change.
            if (opts.content) dialog.appendChild(opts.content);
            const actions = WP.el('div', 'wp-dialog-actions');
            const cancel = WP.el('button', 'wp-btn wp-btn-ghost', 'Cancel');
            const ok = WP.el('button', 'wp-btn ' + (opts.danger ? 'wp-btn-danger' : 'wp-btn-primary'),
                opts.confirmLabel || 'Confirm');
            if (typeof opts.canConfirm === 'function') {
                const check = () => { ok.disabled = !opts.canConfirm(); };
                dialog.addEventListener('change', check);
                dialog.addEventListener('input', check);
                check();
            }
            const done = (result) => {
                if (WP._dialogResolve === resolve) WP._dialogResolve = null;
                if (WP._dialogClose === done) WP._dialogClose = null;
                backdrop.remove();
                if (returnFocus && returnFocus.focus && document.contains(returnFocus)) {
                    returnFocus.focus();
                }
                resolve(result);
            };
            WP._dialogResolve = resolve;
            // The dismiss path (Escape, a replacing confirm) goes through the same
            // close as the buttons, so focus-return is never skipped.
            WP._dialogClose = done;
            cancel.addEventListener('click', () => done(false));
            ok.addEventListener('click', () => done(true));
            backdrop.addEventListener('click', (e) => { if (e.target === backdrop) done(false); });
            // Tab stays in the box until it closes: from the last control round to the first, and back.
            dialog.addEventListener('keydown', (e) => {
                if (e.key !== 'Tab') return;
                const stops = [...dialog.querySelectorAll('button, input, select, textarea, [tabindex]')]
                    .filter((x) => !x.disabled && x.tabIndex >= 0 && x.offsetParent !== null);
                if (!stops.length) return;
                const first = stops[0], last = stops[stops.length - 1];
                if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
                else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
            });
            if (!opts.noCancel) actions.appendChild(cancel);
            actions.appendChild(ok);
            dialog.appendChild(actions);
            backdrop.appendChild(dialog);
            _panelEl.appendChild(backdrop);

            // Focus lands on the SAFE answer for destructive asks, the primary otherwise —
            // Enter on a just-opened "Delete?" must never be the deletion.
            (opts.danger ? cancel : ok).focus();
        });
    },

    /** Is a confirm dialog up? (Sections use this in onEscape staging.) */
    dialogOpen() {
        return !!(_panelEl && _panelEl.querySelector('.wp-dialog-backdrop'));
    },

    _dialogClose: null,

    /** Dismiss an open dialog (Escape stage 1). Returns whether one was dismissed.
     *  Dismissal is an ANSWER — the awaiting caller gets false, never silence — and it
     *  rides the dialog's own close, so focus returns to where it was borrowed from. */
    dismissDialog() {
        if (WP._dialogClose) {
            const close = WP._dialogClose;
            WP._dialogClose = null;
            close(false);
            return true;
        }
        const backdrop = _panelEl && _panelEl.querySelector('.wp-dialog-backdrop');
        if (!backdrop) return false;
        backdrop.remove();
        const resolve = WP._dialogResolve;
        WP._dialogResolve = null;
        if (resolve) resolve(false);
        return true;
    },

    /** The panel speaks: show a result in the shell's strip. type: 'ok' | 'err' | undefined.
     *  Lua answers arrive here via the 'wpResult' router action; sections call it directly
     *  for local outcomes. One strip, one timer — a new message replaces the last.
     *  ABOVE A FOOTER, NEVER ON IT: with a wizard's Back / Next or a settings Apply bar showing, the strip sits just
     *  above that bar (moved into it, bottom: 100%). An error stays until the next press; anything else goes in 2.6 s. */
    result(text, type) {
        if (!_resultEl) return;
        const root = _active && _rootEls[_active];
        const foot = root ? [...root.querySelectorAll('.wp-step-foot, .cfg-bar')].find((f) => f.offsetParent !== null) : null;
        const host = foot || _panelEl;
        if (_resultEl.parentElement !== host) host.appendChild(_resultEl);
        _resultEl.textContent = text;
        _resultEl.className = 'wp-result wp-result-show' + (type ? ' wp-result-' + type : '') + (foot ? ' wp-result-over' : '');
        if (_resultTimer) clearTimeout(_resultTimer);
        _resultTimer = null;
        _resultSticky = type === 'err';
        if (!_resultSticky) _resultTimer = setTimeout(() => _resultEl.classList.remove('wp-result-show'), 2600);
    },

    /** Refuse an input OUT LOUD: error-tint its field capsule and say why beneath it.
     *  Clears itself the moment the admin types again. The silent no-op — click,
     *  nothing, no reason — was the panel's worst habit. */
    fieldError(inputEl, msg) {
        const field = inputEl && inputEl.closest ? inputEl.closest('.wp-field') : null;
        const host = field || inputEl;
        if (!host) return;
        if (field) field.classList.add('wp-field-err');
        // One message element per field, reused.
        let msgEl = host._wpMsgEl;
        if (!msgEl || !msgEl.isConnected) {
            msgEl = WP.el('div', 'wp-field-msg');
            host._wpMsgEl = msgEl;
            host.insertAdjacentElement('afterend', msgEl);
        }
        msgEl.textContent = msg;
        if (inputEl && inputEl.addEventListener) {
            inputEl.addEventListener('input', function clear() {
                if (field) field.classList.remove('wp-field-err');
                msgEl.remove();
                inputEl.removeEventListener('input', clear);
            });
        }
        if (inputEl && inputEl.focus) inputEl.focus();
    },

    /**
     * Turn a bare charId number box into a typeahead: type a name (or an id), pick a
     * person, the input ends up holding the charId every existing formData() read
     * expects. Search runs through the ACE-gated 'wpCharSearch' Lua callback, so the
     * panel's own permission model gates the lookup.
     */
    attachCharPicker(inputEl) {
        // The wrap is the dropdown's positioning anchor — but attach time is usually
        // BEFORE the input reaches the DOM (sections build their subtree, then append),
        // and replaceWith on a parentless node is a silent no-op that would strand the
        // input inside an orphaned wrap. So wrapping waits for the first result render,
        // by which point the input is live.
        let wrap = null;
        const ensureWrap = () => {
            if (wrap && wrap.parentNode) return wrap;
            wrap = WP.el('span', 'wp-picker-wrap');
            inputEl.replaceWith(wrap);
            wrap.appendChild(inputEl);
            return wrap;
        };
        // The number box becomes text so names are typeable; numeric ids still are.
        inputEl.type = 'text';
        inputEl.setAttribute('inputmode', 'numeric');
        inputEl.autocomplete = 'off';

        let list = null;
        let timer = null;

        const close = () => { if (list) { list.remove(); list = null; } };

        const renderResults = (results) => {
            close();
            if (!results || !results.length) return;
            ensureWrap();
            list = WP.el('div', 'wp-picker-list');
            for (const r of results) {
                const item = WP.el('button', 'wp-picker-item');
                item.type = 'button';
                item.appendChild(WP.el('span', null, r.name || 'Unknown'));
                item.appendChild(WP.el('span', 'wp-picker-id', '#' + r.charId + (r.online ? ' · online' : '')));
                item.addEventListener('click', () => {
                    inputEl.value = String(r.charId);
                    close();
                    inputEl.focus();
                });
                list.appendChild(item);
            }
            wrap.appendChild(list);
        };

        inputEl.addEventListener('input', () => {
            const q = inputEl.value.trim();
            if (timer) clearTimeout(timer);
            // Pure digits are already an answer; only names need the lookup.
            if (q.length < 2 || /^\d+$/.test(q)) { close(); return; }
            timer = setTimeout(() => {
                nuiCallback('wpCharSearch', { q }).then((results) => {
                    // Stale replies (the admin kept typing) are dropped.
                    if (inputEl.value.trim() === q) renderResults(results);
                });
            }, 250);
        });
        inputEl.addEventListener('blur', () => setTimeout(close, 150));
        return inputEl;
    },
};

// ---- router + key scope ----

NuiRouter.register('openWhipPanel', (d) => openWhipPanel(d));
NuiRouter.register('closeWhipPanel', () => closeWhipPanel());
NuiRouter.register('wpSuspend', () => wpSuspend());
NuiRouter.register('wpResume', () => wpResume());
NuiRouter.register('wpSectionData', (d) => wpSectionData(d));
// Lua's answer channel: action handlers report outcomes into the panel's own strip
// (WhipPanelResult on the Lua side), because the toast layer renders under this overlay.
NuiRouter.register('wpResult', (d) => WP.result(d.text || '', d.kind));

/** The active section's search box, if it has one: its toolbar's, or a box it marks .wp-section-search
 *  (the Item Log's, which sits in its page). */
function sectionSearch() {
    const root = _active && _rootEls[_active];
    if (!root) return null;
    // THE ONE ON SCREEN: a section with views (a wizard over its list, the Item Log's tabs) keeps a
    // hidden view's search in the page. A box inside a hidden view has no offsetParent.
    const boxes = root.querySelectorAll('.wp-toolbar .wp-input, .wp-section-search');
    for (const box of boxes) if (box.offsetParent !== null) return box;
    return null;
}

/** Escape, a stage at a time: a dialog, then the section's drill-down, then the panel. */
function escapeStep() {
    if (WP.dismissDialog()) return;                     // stage 1: dialog
    const s = _active && _sections.get(_active);
    if (s && s.onEscape && s.onEscape()) return;        // stage 2: section drill-down
    wpRequestClose();                                   // stage 3: close the panel
}

// ---- on a controller ----
//
// The panel is a mouse's — rows, buttons, fields, lists, in every section — so a pad gets a mouse: the
// shared circle (pad-cursor.js), the Director's. The left stick moves it, A clicks (or types, on the pad
// keyboard; or picks, from a list's choices), the D-pad jumps it to the next thing that way, the right
// stick scrolls the list under it. And the panel's own: B is Escape (a dialog, a drill-down, the panel),
// Y types into the section's search, LB / RB step through the section tabs, on into the next group's at
// the end of one. A dialog keeps the D-pad inside it. No section had to change: the circle presses what a
// mouse would.

const padCursor = createPadCursor({
    name: 'panel',
    root: () => _panelEl,
    shown: () => _open && !_suspended,
    targets: 'button, [data-action], input, select, textarea, .wp-picker-item',
    modal: () => (_panelEl && _panelEl.querySelector('.wp-dialog')) || null,
});

function padSection(step) {
    const items = _panelEl ? [..._panelEl.querySelectorAll('.wp-nav-item')] : [];
    if (!items.length) return;
    const i = items.indexOf(_navEls[_active]);
    const next = items[(i + step + items.length) % items.length];
    if (next) switchTo(next.dataset.arg);
}

function padNav(nav) {
    if (!_open || _suspended) return;
    if (padCursor.nav(nav)) return;
    if (nav === 'back') { padCursor.letGo(); escapeStep(); }
    else if (nav === 'buttonY') { const search = sectionSearch(); if (search) padCursor.typeInto(search); }
    else if (nav === 'tabPrev') padSection(-1);
    else if (nav === 'tabNext') padSection(1);
    // 'select' is A's press, which the cursor has from navAnalog's `a`, with its release.
}

/** The hint strip: what A does where the circle is, and the panel's buttons. */
function padHints() {
    const t = padCursor.on() ? padCursor.over() : null;
    const a = !t ? 'Click'
        : t.matches('select') ? 'Choose'
        : t.matches('input[type="checkbox"]') ? 'Tick'
        : t.matches('input, textarea') && !t.readOnly ? 'Type'
        : 'Press';
    const out = [['ls', 'Move'], ['a', a], ['rs', 'Scroll']];
    if (sectionSearch()) out.push(['y', 'Search']);
    out.push([['lb', 'rb'], 'Sections'], ['b', padCursor.menuOpen() ? 'Close list' : 'Back']);
    return out;
}

// Priority 25: above the creator's swallow-all (0), below the inventory (130) — during
// suspends and inventory handoffs isOpen() goes false, which is what actually yields
// the keys; the number only orders us among concurrently-open scopes.
NuiRouter.registerKeyScope({
    name: 'whip-panel',
    priority: 25,
    isOpen: () => _open && !_suspended,
    onKey: (e) => {
        // '/' jumps to the active section's search — the one accelerator every list
        // section shares. Ignored while typing, so a literal slash still types.
        if (e.key === '/') {
            const tag = document.activeElement && document.activeElement.tagName;
            if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;
            const search = sectionSearch();
            if (search) {
                e.preventDefault();
                search.focus();
                search.select();
            }
            return;
        }

        if (e.key !== 'Escape') return;
        escapeStep();
    },
    onNav: padNav,
    analog: true,
    onAnalog: (a) => padCursor.analog(a),
    padHints,
});
