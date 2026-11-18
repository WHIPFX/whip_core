// ========================================
// THE EMOTE MENU
//
// Three tabs — emotes, walks, expressions — over one grid of cards, with a search and (on the
// emotes tab) category chips. Each emote and walk card plays its own video; click a card to play
// it. client/emotes.lua owns everything that happens: this page shows what it was sent and posts
// what was clicked. Nothing is marked optimistically; Lua answers with emotesState.
//
// Lua → page:  emotesOpen { tab, data: { categories, emotes, walks, moods }, state }
//              emotesState { state: { emote, walk, mood } }      (the /e, /walk, /mood names)
//              emotesClose
// Page → Lua:  emotePlay { cmd }  emotePlace { cmd }  emoteStop  emoteWalk { cmd }  emoteMood { cmd }
//              emotesClose       ('c' as the cmd resets a walk or mood)
//              emoteVideoError { src, why }   (a preview that would not play, for the F8 console)
//
// The page holds full NUI focus while open, so the search field is safe to type in. Escape closes.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback, escapeHtml, emoteVideoUrl } from './utils.js';
import { createRing } from './pad-ring.js';
import { openPadKeyboard } from './pad-keyboard.js';

const $ = (id) => document.getElementById(id);

let open = false;
// PICK MODE: the menu posing someone else, a hero shot's character (emotesOpen { pick }).
// The emotes tab only and no Place; a card goes to Lua as ever, which hands it to the editor.
let pick = false;

/** Is the menu up? For a screen it opens over (the furnisher, in pick mode): the router walks key scopes lowest
 *  number first, and the furnisher's (29.5, 30) would otherwise keep every key and pad press.
 *  'emotesmenu' on window says when it opens and closes. */
export function emoteMenuUp() { return open; }
const announce = () => window.dispatchEvent(new CustomEvent('emotesmenu', { detail: { open } }));
let tab = 'emotes';
let cat = null;        // a category key, or null for all
let search = '';
let data = { categories: [], emotes: [], walks: [], moods: [] };
let state = { emote: null, walk: null, mood: null };

const PLACEHOLDER = {
    emotes: 'Search emotes…',
    walks: 'Search walks…',
    moods: 'Search expressions…',
};

// The legend in the panel's foot, the creator's: a word or a key,
// then what it does. Static strings only.
const hint = (k, what) => '<span class="em-hint">' + k + ' ' + what + '</span>';
const KEY_ESC = hint('<span class="em-key">Esc</span>', 'Close');
const FOOT = {
    emotes: hint('<b>Click</b>', 'Play') + hint('<b>Place</b>', 'Put it exactly where you aim')
        + hint('<span class="em-key">X</span> or <code>/e c</code>', 'Stop') + KEY_ESC,
    walks: hint('<b>Click</b>', 'Walk that way') + hint('<code>/walk c</code>', 'Your normal walk')
        + hint('', 'Kept on your character') + KEY_ESC,
    moods: hint('<b>Click</b>', 'Wear it') + hint('<code>/mood c</code>', 'None')
        + hint('', 'Kept on your character, seen by everyone') + KEY_ESC,
};
const FOOT_PICK = hint('<b>Click</b>', 'Pose the character') + hint('<b>Stop</b>', 'Stand normally')
    + hint('<span class="em-key">Esc</span>', 'Back to the shot');

// Where an emote has no video (scenarios and props-only emotes are not filmed): whip's own emote glyph
// (js/glyphs.js, "a figure mid-dance, one arm up": the same picture as an emote everywhere else) and the words
// "No preview", so the card is not read as a clip still loading. Read when drawn: glyphs.js is a classic script
// that loads before the modules.
const noVideo = () => (((window.WhipGlyphs && window.WhipGlyphs.glyphs) || {}).emote || '')
    + '<span class="em-card-none-text">No preview</span>';

// ---- filtering ----

function matches(entry) {
    const q = search.trim().toLowerCase();
    if (!q) return true;
    return (entry.label + ' ' + entry.cmd).toLowerCase().indexOf(q) >= 0;
}

function visibleEmotes() {
    const q = search.trim();
    // A search reaches across every category: "no results" while the answer sits in another chip
    // reads as "we don't have one".
    return (data.emotes || []).filter((e) => matches(e) && (q || cat === null || e.category === cat));
}

// ---- rendering ----

function renderTabs() {
    document.querySelectorAll('#emotes .em-tab').forEach((b) => {
        b.classList.toggle('active', b.dataset.tab === tab);
    });
    const s = $('em-search');
    if (s) s.placeholder = PLACEHOLDER[tab];
}

function labelOf(list, cmd) {
    const e = (list || []).find((x) => x.cmd === cmd);
    return e ? e.label : cmd;
}

function renderNow() {
    const el = $('em-now');
    if (!el) return;
    if (!state.emote) {
        el.classList.remove('on');
        el.innerHTML = '';
        return;
    }
    el.classList.add('on');
    el.innerHTML = '<span class="em-now-text"><span class="em-now-label">' + (pick ? 'Character' : 'Playing') + '</span>'
        + '<span class="em-now-name">' + escapeHtml(labelOf(data.emotes, state.emote)) + '</span></span>'
        + '<button class="em-act em-act-primary" type="button" data-em="stop">Stop</button>';
}

function renderChips() {
    const el = $('em-chips');
    if (!el) return;
    if (tab !== 'emotes' || (data.categories || []).length < 2) {
        el.innerHTML = '';
        return;
    }
    const chip = (key, label) => '<button class="em-chip' + (cat === key ? ' active' : '') + '" type="button"'
        + ' data-em="cat" data-cat="' + escapeHtml(key || '') + '">' + escapeHtml(label) + '</button>';
    el.innerHTML = chip(null, 'All') + data.categories.map((c) => chip(c.key, c.label)).join('');
}

/** The kind of card the open tab lists. */
function tabKind() {
    return tab === 'emotes' ? 'emote' : tab === 'walks' ? 'walk' : 'mood';
}

/** Is this the emote playing, or the walk or mood chosen? ('c' is the "normal" card.) */
function isCurrent(kind, cmd) {
    if (kind === 'emote') return state.emote === cmd;
    const chosen = kind === 'walk' ? state.walk : state.mood;
    return cmd === 'c' ? !chosen : chosen === cmd;
}

/** The picture half of a card: its video (loaded when it scrolls into view), or the stand-in. */
function media(video) {
    if (!video) return '<div class="em-card-media em-card-none">' + noVideo() + '</div>';
    return '<div class="em-card-media"><video class="em-card-video" muted loop playsinline preload="none"'
        + ' data-src="' + escapeHtml(emoteVideoUrl(video)) + '"></video></div>';
}

/** An emote or walk card. The whole card is the button; Place (emotes that stay put) sits on top. */
function videoCard(kind, cmd, label, video, placeable) {
    const c = escapeHtml(cmd);
    const word = kind === 'emote' ? '/e ' : '/walk ';
    return '<div class="em-card' + (isCurrent(kind, cmd) ? ' current' : '') + '" data-row="' + c + '"'
        + ' data-em="' + (kind === 'emote' ? 'play' : 'walk') + '" data-cmd="' + c + '">'
        + media(video)
        + (placeable ? '<button class="em-card-place" type="button" data-em="place" data-cmd="' + c + '">Place</button>' : '')
        + '<div class="em-card-text"><div class="em-card-name">' + escapeHtml(label) + '</div>'
        + '<div class="em-card-cmd">' + word + c + '</div></div>'
        + '</div>';
}

/** An expression card: no video to show, so just its name. */
function moodCard(cmd, label) {
    const c = escapeHtml(cmd);
    return '<div class="em-card em-card-small' + (isCurrent('mood', cmd) ? ' current' : '') + '" data-row="' + c + '"'
        + ' data-em="mood" data-cmd="' + c + '">'
        + '<div class="em-card-text"><div class="em-card-name">' + escapeHtml(label) + '</div>'
        + '<div class="em-card-cmd">/mood ' + c + '</div></div>'
        + '</div>';
}

// ---- the grid, drawn a chunk at a time ----
//
// NOT ALL AT ONCE. The full list is some nine hundred emotes, and drawing every one took ~55 ms in a
// desktop browser — longer in the game's — each time the search was cleared or All was picked. The
// first CHUNK cards are drawn and the rest follow as the grid is scrolled (the furnisher's grid does
// the same). Each card is built when it is drawn, so it shows the state of that moment.

const CHUNK = 60;
let cards = [];     // [() => html] for everything the grid holds now
let drawn = 0;

function renderList() {
    const el = $('em-list');
    if (!el) return;
    stopAllVideos();
    const kind = tabKind();
    if (kind === 'emote') {
        cards = visibleEmotes().map((e) => () => videoCard('emote', e.cmd, e.label, e.video, e.placeable && !pick));
    } else if (kind === 'walk') {
        cards = (data.walks || []).filter(matches).map((w) => () => videoCard('walk', w.cmd, w.label, w.video));
        if (!search.trim()) cards.unshift(() => videoCard('walk', 'c', 'Normal'));
    } else {
        cards = (data.moods || []).filter(matches).map((m) => () => moodCard(m.cmd, m.label));
        if (!search.trim()) cards.unshift(() => moodCard('c', 'None'));
    }
    drawn = 0;
    el.innerHTML = cards.length ? '' : '<div class="em-empty">Nothing matches.</div>';
    el.scrollTop = 0;
    drawMore();
}

function drawMore() {
    const el = $('em-list');
    if (!el || drawn >= cards.length) return;
    const next = cards.slice(drawn, drawn + CHUNK);
    drawn += next.length;
    el.insertAdjacentHTML('beforeend', next.map((build) => build()).join(''));
    watchVideos(el);
}

/** Move the highlight to match `state` without redrawing — a redraw would throw away the cards
 *  drawn so far, and the scroll position with them, every time one was clicked. */
function markCurrent() {
    const kind = tabKind();
    document.querySelectorAll('#em-list .em-card[data-row]').forEach((card) => {
        card.classList.toggle('current', isCurrent(kind, card.dataset.row));
    });
}

// ---- the videos: only the cards in view play ----
//
// Nine hundred cards cannot all be playing. A card's video is given its file when it scrolls into
// view (or near it) and has it taken away again when it leaves, so only the dozen or so on screen
// are ever decoding.
//
// A VIDEO THAT WILL NOT PLAY SAYS SO, in the F8 console (emoteVideoError), the first few times —
// a missing file and a format the game's browser refuses look identical on screen.

let observer = null;
const reported = new Set();   // one line per video: an error, its refused play and its timeout are one fault
const REPORT_MAX = 5;

function report(src, why) {
    src = String(src || '');
    if (reported.has(src) || reported.size >= REPORT_MAX) return;
    reported.add(src);
    nuiCallback('emoteVideoError', { src, why: String(why || '') });
}

const SLOW_MS = 3000;
const slow = new WeakMap();   // video -> the timer that reports it if it never gets going

function startVideo(v) {
    if (!v.getAttribute('src')) v.src = v.dataset.src;
    v.muted = true;          // the property, not just the attribute: what autoplay rules look at
    const played = v.play();
    if (played && played.catch) {
        played.catch((err) => {
            // Leaving the view pauses it mid-start; that is not a failure.
            if (err && err.name !== 'AbortError') report(v.dataset.src, 'play refused: ' + err.name);
        });
    }
    // Neither an error nor a picture: say so, with where it got to.
    if (!slow.has(v)) {
        slow.set(v, setTimeout(() => {
            slow.delete(v);
            if (v.getAttribute('src') && v.readyState < 2) {
                report(v.dataset.src, 'no picture after 3s (readyState ' + v.readyState
                    + ', networkState ' + v.networkState + ')');
            }
        }, SLOW_MS));
    }
}

function stopVideo(v) {
    const t = slow.get(v);
    if (t) { clearTimeout(t); slow.delete(v); }
    if (!v.getAttribute('src')) return;
    v.pause();
    v.removeAttribute('src');
    v.load();                // lets go of the file and the decoder
}

function stopAllVideos() {
    if (observer) observer.disconnect();
    document.querySelectorAll('#em-list video[src]').forEach(stopVideo);
}

function watchVideos(el) {
    if (!observer) {
        observer = new IntersectionObserver((entries) => {
            for (const entry of entries) {
                if (entry.isIntersecting) startVideo(entry.target);
                else stopVideo(entry.target);
            }
        }, { root: el, rootMargin: '150px 0px' });
    }
    el.querySelectorAll('video[data-src]:not([data-watched])').forEach((v) => {
        v.dataset.watched = '1';
        observer.observe(v);
    });
}

const MEDIA_ERRORS = { 1: 'aborted', 2: 'network error (file not served?)', 3: 'could not decode',
                       4: 'format not supported, or file not found' };

function renderFoot() {
    const el = $('em-foot');
    if (el) el.innerHTML = pick ? FOOT_PICK : FOOT[tab];
}

function render() {
    renderTabs();
    renderNow();
    renderChips();
    renderList();
    renderFoot();
}

// ---- open / close ----

function show(d) {
    data = d.data || data;
    state = d.state || state;
    pick = d.pick === true;
    tab = pick ? 'emotes' : (PLACEHOLDER[d.tab] ? d.tab : 'emotes');
    cat = null;
    search = '';
    const s = $('em-search');
    if (s) s.value = '';
    open = true;
    ring.clear();              // a pad's ring starts at the first press, on the emote playing (or the first)
    const root = $('emotes');
    if (root) {
        root.classList.add('em-open');
        root.classList.toggle('em-picking', pick);
    }
    render();
    if (s) s.focus();
    announce();
}

function hide() {
    if (!open) return;
    open = false;
    stopAllVideos();
    const root = $('emotes');
    if (root) root.classList.remove('em-open');
    const s = $('em-search');
    if (s) s.blur();
    announce();
}

/** The page asks; Lua closes (it owns the focus) and tells the page back. hide() is safe twice. */
function requestClose() {
    hide();
    nuiCallback('emotesClose', {});
}

function setTab(next) {
    if (pick || !PLACEHOLDER[next] || next === tab) return;
    tab = next;
    search = '';
    const s = $('em-search');
    if (s) s.value = '';
    render();
}

// ---- delegated actions ----

(function bindEmoteActions() {
    const root = $('emotes');
    if (!root) return;

    const CLICK = new Map([
        ['close', () => requestClose()],
        ['tab',   (el) => setTab(el.dataset.tab)],
        ['cat',   (el) => { cat = el.dataset.cat === '' ? null : el.dataset.cat; renderChips(); renderList(); }],
        ['play',  (el) => nuiCallback('emotePlay', { cmd: el.dataset.cmd })],
        ['place', (el) => nuiCallback('emotePlace', { cmd: el.dataset.cmd })],
        ['stop',  () => nuiCallback('emoteStop', {})],
        ['walk',  (el) => nuiCallback('emoteWalk', { cmd: el.dataset.cmd })],
        ['mood',  (el) => nuiCallback('emoteMood', { cmd: el.dataset.cmd })],
    ]);

    root.addEventListener('click', (e) => {
        if (!open) return;
        // The nearest one wins, so Place on a card is Place, and anywhere else on it is the card.
        const el = e.target.closest('[data-em]');
        if (!el) return;
        if (el.tagName === 'BUTTON') el.blur();
        const fn = CLICK.get(el.dataset.em);
        if (fn) fn(el);
    });

    root.addEventListener('input', (e) => {
        if (!open || e.target.id !== 'em-search') return;
        search = e.target.value || '';
        renderList();
    });

    const list = $('em-list');
    if (list) {
        // Near the bottom, the next chunk of cards goes in.
        list.addEventListener('scroll', () => {
            if (list.scrollTop + list.clientHeight > list.scrollHeight - 400) drawMore();
        }, { passive: true });
        // Media errors do not bubble; caught on the way down instead.
        list.addEventListener('error', (e) => {
            const v = e.target;
            if (!v || v.tagName !== 'VIDEO' || !v.getAttribute('src')) return;
            const code = v.error && v.error.code;
            report(v.dataset.src, MEDIA_ERRORS[code] || ('error ' + code));
        }, true);
    }

    // Enter in the search plays (or picks) the first match — type "dri", Enter.
    root.addEventListener('keydown', (e) => {
        if (!open || e.target.id !== 'em-search' || e.key !== 'Enter') return;
        const first = $('em-list') && $('em-list').querySelector('.em-card[data-em]');
        if (first) first.click();
    });
})();

// ---- on a controller ----
//
// A white ring is the highlight (pad-ring.js): the D-pad or the left stick step it over the tabs, the
// Stop button, the search, the chips and the cards, and A presses what it is on, with the mouse's own
// click. On a card that can be placed, X is its Place. Y types a search on whip's keyboard. LB / RB
// step the tabs. B closes. The foot's mouse words give way to the hint strip on a pad (emotes.css).

const ring = createRing({
    root: () => $('emotes'),
    selector: '.em-x, .em-tab, .em-now .em-act, #em-search, .em-chip, .em-card[data-em]',
    keyOf: (el) => (el.id ? '#' + el.id : el.dataset.em + '|' + (el.dataset.tab || el.dataset.cat || el.dataset.cmd || '')),
});

/** Where the ring starts: the emote (walk, expression) on now, else the first card, else the tab. */
function ringStart() {
    return document.querySelector('#em-list .em-card.current') || document.querySelector('#em-list .em-card[data-em]')
        || document.querySelector('#emotes .em-tab.active');
}

const TAB_ORDER = ['emotes', 'walks', 'moods'];
const TAB_WORD = { emotes: 'emotes', walks: 'walks', moods: 'expressions' };

/** Y (or A on the search box): the search typed on whip's keyboard; the ring then goes to the first match. */
function typeSearch() {
    const s = $('em-search');
    if (!s) return;
    openPadKeyboard({
        title: 'Search ' + TAB_WORD[tab], value: search, maxLength: 40,
        onDone: (text) => {
            if (!open) return;
            s.value = text;
            s.dispatchEvent(new Event('input', { bubbles: true }));
            ring.set(document.querySelector('#em-list .em-card[data-em]') || s);
        },
    });
}

function emNav(nav) {
    if (!open) return;
    if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') {
        if (!ring.el()) { ring.set(ringStart()); return; }
        const inList = ring.el().closest('#em-list');
        // Down off the cards drawn so far: the next ones go in first (drawMore), as scrolling does.
        if (!ring.step(nav) && nav === 'down' && inList && drawn < cards.length) {
            drawMore();
            ring.step(nav);
        }
        return;
    }
    if (nav === 'back') { requestClose(); return; }
    if (nav === 'tabPrev' || nav === 'tabNext') {
        const i = TAB_ORDER.indexOf(tab);
        setTab(TAB_ORDER[(i + (nav === 'tabNext' ? 1 : TAB_ORDER.length - 1)) % TAB_ORDER.length]);
        ring.set(ringStart());
        return;
    }
    if (nav === 'buttonY') { typeSearch(); return; }
    const el = ring.el();
    if (nav === 'buttonX') {
        const card = el && el.closest('.em-card');
        const place = card && card.querySelector('.em-card-place');
        if (place) place.click();
        return;
    }
    if (nav === 'select') {
        if (!el) { ring.set(ringStart()); return; }
        if (el.id === 'em-search') typeSearch(); else el.click();
    }
}

/** The hint strip: what A does to what the ring is on. */
function emHints() {
    const el = ring.el();
    const card = el && el.closest('.em-card');
    const a = !el ? 'Choose'
        : card ? ({ emote: 'Play', walk: 'Walk', mood: 'Wear' })[tabKind()]
        : el.id === 'em-search' ? 'Search'
        : el.classList.contains('em-tab') ? 'Open'
        : el.classList.contains('em-chip') ? 'Show'
        : el.dataset.em === 'stop' ? 'Stop'
        : el.dataset.em === 'close' ? 'Close' : 'Press';
    const out = [['dpad', 'Choose'], ['a', a]];
    if (card && card.querySelector('.em-card-place')) out.push(['x', 'Place']);
    out.push(['y', 'Search'], [['lb', 'rb'], 'Tabs'], ['b', 'Close']);
    return out;
}

// ---- router ----

NuiRouter.register('emotesOpen', (d) => show(d));
NuiRouter.register('emotesClose', () => hide());
NuiRouter.register('emotesState', (d) => {
    state = d.state || state;
    if (open) { renderNow(); markCurrent(); }
});

// 115: a free slot between the old dev panels (see router.js). Escape closes; every other key is
// left to the page (the search field). A pad drives it too (emNav above).
NuiRouter.registerKeyScope({
    name: 'emotes',
    priority: 115,
    isOpen: () => open,
    onKey: (e) => {
        if (e.key === 'Escape') {
            e.preventDefault();
            requestClose();
        }
    },
    onNav: emNav,
    padHints: emHints,
});
