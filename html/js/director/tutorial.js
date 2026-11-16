// ========================================
// DIRECTOR — the tutorial
//
// A first-time tutorial in three stages, which a button can run again: a coach card over the page,
// with what it is about ringed:
//
//   1 DIRECTOR BASICS    a tour, Next and Back: an example opened only to look at (whip_core:director:example:
//                        nothing is stored), its tabs and its bar, and where scenarios are made (/whip).
//   2 MY FIRST SCENARIO  you build a small job and each step waits until you have done it: a scenario made for
//                        you, a man placed, Talk to an NPC, a Dialog Line wired from Scenario Enabled, Pay,
//                        Succeed, Check, Save, Test, and back. Nothing is covered but the card: the page is yours.
//   3 WHAT'S POSSIBLE    a showcase in the editor: the three examples,
//                        each played the way it goes when all goes right, every kind of card (from the
//                        list this server has), and what else the Director does.
//
// Stages 1 and 3 hold the page: a clear sheet takes the clicks, the Director's keys wait (Esc leaves,
// Enter and the arrows move), and what was open when they began comes back as it was, unsaved changes
// and all (app.js snapshot / restore).
//
// The tour is of the full editor (the Blueprint window's Fullscreen): the first time it is in sight on a PC,
// stage 1 starts by itself; the dock's Tutorial button offers all three again. What has been seen is kept
// on the PC (client/director.lua, a KVP), as bits: SEEN, then one for each stage finished.
// ========================================

import { escapeHtml } from '../utils.js';
import { uiIcon } from '../ui-icons.js';
import { groupCards } from './search.js';

const e = escapeHtml;
const SEEN = 1;
const DONE = { 1: 2, 2: 4, 3: 8 };
const RING_PAD = 6;       // the ring's room round what it is about
const TICK_MS = 300;      // how often a step that waits looks again
const EDGE = 20;          // the card's least distance from the screen's edge and the column

let api = null;           // what app.js lends (initTutorial)
let bits = 0;             // what this PC has seen (client/director.lua's KVP)
let run = null;           // the stage going: { stage, steps, i, blocking, stash, since, base, key, ... }
let els = null;           // { block, ring, card }
let frame = 0, idle = 0, lastTick = 0, lastHtml = '', lastPos = '';

/** app.js's hands: { ed, root(), col(), canvas(), call, drawColumn, shown(), snapshot(), restore(s),
 *  openDemo(name), newScenario(name), playFlow(trace), clearFlow(), saveSeen(bits) }. */
export function initTutorial(a) { api = a; }

/** Is a stage (or the stage list) up? */
export function tutorialRunning() { return run !== null; }

/** The screen opened (directorOpen: `d`, what this PC has seen) or the full editor showed. Stage 1 starts by itself
 *  the first time the page is in sight (`visible`: not in the world, where there is no page to tour). */
export function tutorialOpened(d, visible) {
    if (d && typeof d.tutorial === 'number') bits = d.tutorial;
    if (visible && bits === 0 && !run) startTutorial(1);
}

/** A key while the page is up. Stages 1 and 3 and the stage list take every key (Esc leaves them);
 *  stage 2 takes none. Answers whether it took it. */
export function tutorialKey(ev) {
    if (!run || !run.blocking) return false;
    if (ev.key === 'Escape') { ev.preventDefault(); stop(false); }
    else if (run.stage && (ev.key === 'Enter' || ev.key === 'ArrowRight')) { ev.preventDefault(); next(); }
    else if (run.stage && ev.key === 'ArrowLeft') { ev.preventDefault(); back(); }
    return true;
}

// ============================================================
// Small parts
// ============================================================

const ed = () => api.ed;
const $ = (s) => api.root().querySelector(s);
const cardEl = (id) => (id ? $(`.dr-card[data-id="${CSS.escape(id)}"]`) : null);
const pinEl = (id, side, pin) => (id ? $(`.dr-card[data-id="${CSS.escape(id)}"] .dr-pin.${side}[data-pin="${CSS.escape(pin)}"] i`) : null);
const tabEl = (t) => $(`.dr-tab[data-tab="${t}"]`);
const palRow = (type) => $(`.dr-pal-row[data-type="${CSS.escape(type)}"]`);
// (A card's page is on the right while one is open: app.js drawSide.)
const body = () => $('.dr-side:not([hidden]) .dr-side-body') || $('.dr-col .dr-body');
const nodesOf = (type) => (ed().doc ? ed().doc.nodes.filter((n) => n.type === type) : []);
const filled = (v) => typeof v === 'string' && v.trim() !== '';
/** A wire from a card's pin to a card of a type: the first such card, or null. */
function wiredTo(fromId, fromPin, type) {
    const doc = ed().doc;
    if (!doc || !fromId) return null;
    for (const l of doc.links) {
        if (l.from.node !== fromId || (fromPin && l.from.pin !== fromPin)) continue;
        const n = doc.nodes.find((x) => x.id === l.to.node);
        if (n && n.type === type) return n;
    }
    return null;
}
function safe(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }

/** *Words* in a step's text are the page's own words (a button, a tab): bold. */
function fmt(text) { return e(text).replace(/\*([^*]+)\*/g, '<b>$1</b>'); }

function markBits(b) {
    if ((bits & b) === b) return;
    bits |= b;
    api.saveSeen(bits);
}

// ============================================================
// Going through a stage
// ============================================================

export async function startTutorial(stage) {
    if (!api) return;
    if (run) await stop(false);
    build();
    const def = STAGES[stage];
    if (!def) return;
    // Stages 1 and 3 change what is open: what was there comes back after (stage 2 is the builder's own work).
    const blocking = stage !== 2;
    run = { stage, steps: def.steps, i: -1, blocking, stash: blocking && stage ? api.snapshot() : null, since: 0, base: {}, key: null };
    if (stage) markBits(SEEN);
    els.block.classList.toggle('on', blocking);
    lastHtml = '';
    await go(0, 1);
    loop();
}

/** The stage list (the dock's Tutorial button). */
export function tutorialMenu() { return startTutorial(0); }

async function stop(finished) {
    if (!run) return;
    const r = run;
    run = null;
    cancelAnimationFrame(frame);
    clearTimeout(idle);
    if (finished && DONE[r.stage]) markBits(DONE[r.stage]);
    els.block.classList.remove('on', 'dim');
    els.ring.style.display = 'none';
    els.card.style.display = 'none';
    els.card.innerHTML = '';
    lastHtml = '';
    lastPos = '';
    if (r.stash) {
        api.clearFlow();
        api.restore(r.stash);
    }
}

/** To step `i`, moving `dir` past any that are not for now (`when`) or, waiting for something, are
 *  already done (someone ahead of the card). Off the end: the stage is finished. */
async function go(i, dir) {
    if (!run) return;
    const r = run;
    if (r.moving) return;
    r.moving = true;
    try {
        let n = i;
        for (;;) {
            if (n < 0) { n = 0; dir = 1; }
            if (n >= r.steps.length) { r.moving = false; await stop(true); return; }
            const s = r.steps[n];
            r.i = n;
            r.since = Date.now();
            r.base = {};
            r.scrolled = null;
            if (s.when && !safe(() => s.when(r), true)) { n += dir; continue; }
            if (s.prepare) await s.prepare(r);
            if (run !== r) return;
            // (Asked again: what it needs may have failed to come in its prepare, an example say.)
            if (s.when && !safe(() => s.when(r), true)) { n += dir; continue; }
            if (s.done && !s.next && !(s.mine && r.key && !mine(r)) && safe(() => s.done(r), false)) { n += dir; continue; }
            break;
        }
    } finally {
        r.moving = false;
    }
    render();
    position();
}

function next() { if (run) go(run.i + 1, 1); }
function back() { if (run && run.i > 0) go(run.i - 1, -1); }

function loop() {
    cancelAnimationFrame(frame);
    clearTimeout(idle);
    const tick = () => {
        if (!run) return;
        // The page hidden (placing, a test, closed): look again in a while, not every frame.
        if (!api.shown()) { lastPos = ''; idle = setTimeout(tick, 400); return; }
        position();
        const now = Date.now();
        if (now - lastTick >= TICK_MS) {
            lastTick = now;
            look();
        }
        frame = requestAnimationFrame(tick);
    };
    tick();
}

/** A step that waits: done yet? And its words again, when they depend on what happened (Check). */
function look() {
    const r = run;
    if (!r || r.moving || r.i < 0) return;
    const { step: s, away } = current();
    // (Not while another scenario is open: its World and cards are not the ones being built.)
    if (!away && s.done && safe(() => s.done(r), false)) { go(r.i + 1, 1); return; }
    render();
}

// ============================================================
// The card and the ring
// ============================================================

function build() {
    if (els) return;
    const root = api.root();
    const block = document.createElement('div');
    block.className = 'dr-tut-block';
    const ring = document.createElement('div');
    ring.className = 'dr-tut-ring';
    const card = document.createElement('div');
    card.className = 'dr-tut-card';
    root.append(block, ring, card);
    card.addEventListener('click', onClick);
    els = { block, ring, card };
}

/** Stage 2, its scenario not open (another one is): the step waits for it to come back. */
function awayStep(r) {
    return {
        title: 'Back to your scenario',
        text: `Your scenario *${r.name || r.key}* is not open: open it from /whip's Director tab (*Edit in the world*), then the Blueprint window's *Fullscreen*, to carry on.`,
    };
}

function current() {
    const r = run;
    const s = r.steps[r.i];
    if (r.stage === 2 && r.key && s.mine && !mine(r)) return { step: awayStep(r), away: true };
    return { step: s, away: false };
}

function render() {
    const r = run;
    if (!r || r.i < 0) return;
    const { step: s, away } = current();
    const def = STAGES[r.stage];
    const text = typeof s.text === 'function' ? safe(() => s.text(r), '') : s.text;
    const waits = !!s.done && !s.next;
    let btns = '';
    if (s.buttons) {
        btns = s.buttons.map((b, i) => `<button class="dr-btn ${i === 0 ? 'primary' : 'ghost'}" data-tut="${b.act}"${b.n ? ` data-n="${b.n}"` : ''}>${e(b.label)}</button>`).join('');
    } else if (r.stage === 0) {
        btns = '<button class="dr-btn ghost" data-tut="stop">Close</button>';
    } else if (r.blocking) {
        btns = (r.i > 0 ? '<button class="dr-btn ghost" data-tut="back">Back</button>' : '')
            + '<button class="dr-btn ghost" data-tut="stop">Skip</button>'
            + `<button class="dr-btn primary" data-tut="next">${e(s.next || (r.i === r.steps.length - 1 ? 'Finish' : 'Next'))}</button>`;
    } else {
        btns = (waits && !away ? '<button class="dr-btn ghost" data-tut="skipstep" title="Go on without it">Skip this step</button>' : '')
            + '<button class="dr-btn ghost" data-tut="stop">Stop</button>'
            + (!waits && !away ? `<button class="dr-btn primary" data-tut="next">${e(s.next || 'Next')}</button>` : '');
    }
    const count = r.stage ? `${def.title} · ${r.i + 1} of ${r.steps.length}` : 'The Director';
    const html = `<div class="dr-tut-box${s.wide ? ' wide' : ''}">`
        + `<div class="dr-tut-kicker">${e(count)}</div>`
        + `<div class="dr-tut-title">${e(s.title)}</div>`
        + (text ? `<div class="dr-tut-text">${fmt(text)}</div>` : '')
        + (s.extra ? safe(() => s.extra(r), '') : '')
        + ((waits || away) ? '<div class="dr-tut-wait"><i></i>Do it, and this moves on</div>' : '')
        + `<div class="dr-tut-btns">${btns}</div></div>`;
    if (html === lastHtml) return;
    lastHtml = html;
    els.card.innerHTML = html;
    els.card.style.display = 'block';
    lastPos = '';
}

/** Where the ring and the card go, each frame (the grid pans, tabs change): beside what the step is
 *  about, never over the column, and round it when there is something to ring. */
function position() {
    const r = run;
    if (!r || r.i < 0 || !els) return;
    const { step: s } = current();
    let target = s.target ? safe(() => s.target(r), null) : null;
    let tr = null;
    if (target && target.isConnected) {
        // Down a scrolled list (the palette, the World rows): brought into view once.
        if (r.scrolled !== target && body() && body().contains(target)) {
            r.scrolled = target;
            target.scrollIntoView({ block: 'nearest' });
        }
        const b = target.getBoundingClientRect();
        if (b.width > 0 && b.height > 0) tr = b;
    }
    const W = window.innerWidth, H = window.innerHeight;
    const col = api.col().getBoundingClientRect();
    const box = els.card.firstElementChild;
    if (!box) return;
    const cb = box.getBoundingClientRect();
    const cw = cb.width, ch = cb.height;
    const left = col.right + EDGE;
    let x, y;
    if (!tr) {
        if (s.at === 'corner') { x = W - cw - EDGE * 1.5; y = H - ch - EDGE * 1.5; }
        else { x = left + (W - left - cw) / 2; y = (H - ch) / 2; }
    } else if (target.closest('.dr-col')) {
        x = left + 4;
        y = tr.top + tr.height / 2 - ch / 2;
    } else if (target.closest('.dr-side')) {
        // Beside the card's page on the right, on its left.
        x = target.closest('.dr-side').getBoundingClientRect().left - cw - EDGE;
        y = tr.top + tr.height / 2 - ch / 2;
    } else if (target.closest('.dr-dock')) {
        x = tr.right - cw;
        y = tr.bottom + 18;
    } else if (!r.blocking) {
        // Building (stage 2): along the bottom, clear of the cards being wired (the top, if that is where it is).
        x = tr.left + tr.width / 2 - cw / 2;
        y = tr.bottom > H - ch - EDGE * 4 ? EDGE * 4 : H - ch - EDGE * 1.5;
    } else {
        x = tr.left + tr.width / 2 - cw / 2;
        y = tr.bottom + 18;
        if (y + ch > H - EDGE) y = tr.top - 18 - ch;
        if (y < EDGE) {
            y = tr.top;
            x = tr.right + 18;
            if (x + cw > W - EDGE) x = tr.left - 18 - cw;
        }
    }
    x = Math.round(Math.max(left, Math.min(x, W - cw - EDGE)));
    y = Math.round(Math.max(EDGE, Math.min(y, H - ch - EDGE)));
    const ring = tr ? [Math.round(tr.left - RING_PAD), Math.round(tr.top - RING_PAD),
        Math.round(tr.width + RING_PAD * 2), Math.round(tr.height + RING_PAD * 2)] : null;
    const key = `${x},${y},${ring ? ring.join(',') : '-'},${r.blocking}`;
    if (key === lastPos) return;
    lastPos = key;
    els.card.style.left = x + 'px';
    els.card.style.top = y + 'px';
    if (ring) {
        els.ring.style.display = 'block';
        els.ring.style.left = ring[0] + 'px';
        els.ring.style.top = ring[1] + 'px';
        els.ring.style.width = ring[2] + 'px';
        els.ring.style.height = ring[3] + 'px';
    } else {
        els.ring.style.display = 'none';
    }
    // Held stages: the page dimmed round the ring (its shadow), or all of it when nothing is ringed
    // (a corner card leaves the grid bright: it is what the step shows).
    els.ring.classList.toggle('spot', r.blocking);
    els.block.classList.toggle('dim', r.blocking && !ring && s.at !== 'corner');
}

function onClick(ev) {
    const b = ev.target.closest('[data-tut]');
    if (!b || !run) return;
    const act = b.dataset.tut;
    if (act === 'next') next();
    else if (act === 'back') back();
    else if (act === 'skipstep') go(run.i + 1, 1);
    else if (act === 'make') {
        // My first scenario's own: made and opened; the step sees it is (mine) and moves on. A refusal is said in the
        // column's foot, and the button is there to press again.
        b.disabled = true;
        api.newScenario('Street job').then((ok) => { if (!ok) b.disabled = false; });
    }
    else if (act === 'stop') stop(false);
    else if (act === 'finish') stop(true);
    else if (act === 'stage') {
        const n = Number(b.dataset.n);
        const finished = run.stage !== 0;
        stop(finished).then(() => startTutorial(n));
    }
}

// ============================================================
// Stage 1 and 3's page: an example to look at
// ============================================================

/** A step about no card: the last one's playback put away. */
async function onPage() {
    api.clearFlow();
}

/** One of the examples, open only to look at. Not there (an old server): the steps that need it go by. */
async function onDemo(r, name) {
    if (ed().demo === name) return;
    api.clearFlow();
    if (!(await api.openDemo(name))) r.noDemo = true;
}

function demoTab(name, tab, select) {
    return async (r) => {
        await onDemo(r, name);
        if (r.noDemo) return;
        api.clearFlow();
        api.canvas().setUses([], false);
        if (select) {
            ed().select([select]);
        } else {
            ed().selected = new Set();
            ed().tab = tab || ed().tab;
            api.canvas().render();
        }
        if (tab) ed().tab = tab;
        api.drawColumn();
    };
}

/** An example shown: the whole of it, played the way a run goes when all goes right, or some of its
 *  cards lit white. */
function showcase(name, o = {}) {
    return async (r) => {
        await onDemo(r, name);
        if (r.noDemo) return;
        api.clearFlow();
        ed().selected = new Set();
        ed().tab = 'cards';
        api.drawColumn();
        api.canvas().frame(o.uses || null);
        api.canvas().setUses(o.uses || [], !!o.uses);
        const at = r.i;
        if (o.flow) setTimeout(() => { if (run === r && r.i === at && ed().demo === name) api.playFlow(happyTrace(ed().doc, ed().cards)); }, 350);
    };
}

/** The way a run goes when all goes right, as a test's trace (for app.js's playback): breadth first from
 *  Scenario Enabled, never into a Fail or a Call Off, to the first Succeed; a run that waits for
 *  something (an item picked up, a car entered) goes on from the first event card that leads to one. */
export function happyTrace(doc, cards) {
    const outs = new Map();
    for (const l of doc.links) {
        if (!outs.has(l.from.node)) outs.set(l.from.node, []);
        outs.get(l.from.node).push(l);
    }
    const typeOf = new Map(doc.nodes.map((n) => [n.id, n.type]));
    const ending = (id) => /^scenario\.(fail|calloff)$/.test(typeOf.get(id) || '');
    const won = (id) => typeOf.get(id) === 'scenario.succeed';
    const pathTo = (prev, id) => {
        const p = [];
        for (let l = prev.get(id); l; l = prev.get(l.from.node)) p.unshift(l);
        return p;
    };
    // To the first success, or (none reached) as far as it goes.
    const walk = (from) => {
        const prev = new Map([[from, null]]);
        const depth = new Map([[from, 0]]);
        const q = [from];
        let far = from;
        while (q.length) {
            const id = q.shift();
            if (won(id)) return { path: pathTo(prev, id), won: true };
            if (depth.get(id) > depth.get(far)) far = id;
            for (const l of outs.get(id) || []) {
                const to = l.to.node;
                if (prev.has(to) || ending(to)) continue;
                prev.set(to, l);
                depth.set(to, depth.get(id) + 1);
                q.push(to);
            }
        }
        return { path: pathTo(prev, far), won: false };
    };
    const start = doc.nodes.find((n) => n.type === 'scenario.started');
    if (!start) return [];
    const trace = [{ node: start.id, kind: 'enter' }];
    const add = (p) => { for (const l of p) trace.push({ node: l.to.node, kind: 'enter', pin: l.to.pin, from: l.from.node, fromPin: l.from.pin }); };
    const first = walk(start.id);
    add(first.path);
    if (!first.won) {
        for (const n of doc.nodes) {
            const def = cards.get(n.type);
            if (n === start || !def || def.category !== 'events') continue;
            const then = walk(n.id);
            if (!then.won) continue;
            trace.push({ node: n.id, kind: 'enter' });
            add(then.path);
            break;
        }
    }
    return trace.map((s, i) => Object.assign(s, { t: i * 100 }));
}

// ============================================================
// Stage 2: whose scenario
// ============================================================

/** A scenario with nothing in it yet (just made): Scenario Enabled alone, nothing placed. */
const fresh = (doc) => !!doc && doc.nodes.length === 1 && doc.nodes[0].type === 'scenario.started' && !doc.world.length;

/** Is the scenario being built open? The first fresh one the builder is in becomes it. */
function mine(r) {
    const d = ed();
    if (d.page !== 'editor' || d.demo || !d.doc) return false;
    if (r.key) return d.key === r.key;
    if (!d.pack && fresh(d.doc)) {
        r.key = d.key;
        r.name = d.doc.name;
        return true;
    }
    return false;
}
/** Room for the next card: the grid moved (never the cards) so that its middle, where a card picked from
 *  the list lands (app.js addAtCentre: 118 left of it, 40 above), is just right of the right-most card
 *  and level with Scenario Enabled. A new card would otherwise land on the last one. */
function roomOnTheRight() {
    const c = api.canvas();
    const cards = [...api.root().querySelectorAll('.dr-card')];
    const s = startOf();
    const startEl = cardEl(s && s.id);
    if (!cards.length || !startEl) return;
    const rect = c.root.getBoundingClientRect();
    const left = Math.max(rect.left, api.col().getBoundingClientRect().right);
    const midX = (left + rect.right) / 2, midY = (rect.top + rect.bottom) / 2;
    const z = c.view.z;
    let right = -Infinity;
    for (const el of cards) right = Math.max(right, el.getBoundingClientRect().right);
    c.view.x -= (right + 80 * z) - (midX - 118 * z);
    c.view.y -= startEl.getBoundingClientRect().top - (midY - 40 * z);
    c.applyView();
}

const npcOf = () => (ed().doc ? ed().doc.world.find((w) => w.kind === 'npc' && w.def && w.def.coords) : null);
const startOf = () => nodesOf('scenario.started')[0];
const lineOf = () => nodesOf('dialog.line')[0];
const payOf = () => { const l = lineOf(); return (l && wiredTo(l.id, 'opt1', 'player.pay')) || nodesOf('player.pay')[0]; };
const errorsNow = () => ed().problemList.some((p) => p.severity === 'error');

// ============================================================
// The stages
// ============================================================

const MENU = [{
    title: 'Tutorial',
    text: 'Three short stages, any of them, any time.',
    extra: () => '<div class="dr-tut-stages">' + [1, 2, 3].map((n) => {
        const st = STAGES[n];
        const done = (bits & DONE[n]) === DONE[n];
        return `<button class="dr-tut-stage" data-tut="stage" data-n="${n}"><span class="dr-tut-n">${done ? uiIcon('check') : n}</span>`
            + `<span><b>${e(st.title)}</b><span>${e(st.blurb)}</span></span></button>`;
    }).join('') + '</div>',
}];

const S1 = [
    { title: 'Welcome to the Director', prepare: onPage,
      text: 'Here you build jobs for players: cards wired together into a *scenario*, the people and things it needs placed in the world, and a *Test* to play it yourself before anyone else does. This tour takes a minute.' },
    { title: 'Where scenarios live', prepare: onPage,
      text: 'Every scenario is in /whip\'s *Director* tab (/w has a *Director* row too). *New scenario* makes one, empty or from an example; *Edit in the world* takes you into the world builder on it. The tab also has each one\'s runs and players, the live runs, and the lore characters.' },
    { title: 'Your own world', prepare: onPage, target: () => $('.dr-dock'),
      text: '*Isolate world* puts you in a world of your own while you build: no other players, no traffic, and your tests are made in it. Closing the Director brings you back. *Tutorial* brings these stages back any time.' },
    { title: 'Inside a scenario', prepare: (r) => showcase('courier')(r), when: (r) => !r.noDemo, target: () => cardEl(startOf() && startOf().id),
      text: 'This is an example, open only to look at. A scenario is a blueprint: it begins at *Scenario Enabled* and follows the wires from card to card. Drag the grid to move round it, the wheel zooms, and *F* fits it all on screen.' },
    { title: 'Cards', prepare: (r) => showcase('courier')(r), when: (r) => !r.noDemo, target: () => cardEl('d1'),
      text: 'A card does one thing: an NPC says a line, a car appears, the player is paid. The dots on its right are what can happen next (here, each answer, and walking away); wire each to the card that follows.' },
    { title: 'The card list', prepare: demoTab('courier', 'cards'), when: (r) => !r.noDemo, target: body,
      text: '*Cards* lists every card there is, by kind: point at one and the line under the list says what it does. Click one to add it in the middle, drag it onto the grid, or right-click the grid to search for one right there.' },
    { title: 'A card\'s settings', prepare: demoTab('courier', 'card', 'd1'), when: (r) => !r.noDemo, target: body,
      text: 'Click a card on the grid and its settings open here: who speaks, what they say and the answers. The arrow at the top goes back to the tab you were on.' },
    { title: 'The world', prepare: demoTab('courier', 'world'), when: (r) => !r.noDemo, target: body,
      text: '*World* holds the people and things the scenario puts in the world, placed with the world builder. *Always present* ones are there while it is on (a quest giver); ones that *only activate via card* are made by a card while the scenario plays, and go when it ends.' },
    { title: 'How it starts', prepare: demoTab('courier', 'card', 'start'), when: (r) => !r.noDemo, target: body,
      text: 'The *Scenario Enabled* card\'s page says how the scenario starts (as soon as it is switched on, talk to an NPC, press something, walk near, use an item, a timer, a script, or by hand), how many can be on the team, how long it may last, and each player\'s cooldown. A *Scenario Started By Player* card is where the job really begins: before it, nothing fails or starts a cooldown. *Variables* keeps numbers and words the scenario needs.' },
    { title: 'What is wrong', prepare: demoTab('courier', 'check'), when: (r) => !r.noDemo, target: body,
      text: 'The *Check* button opens this: anything wrong or missing, each linked to its card, and after a test every step the scenario took. Its number says how many problems are left.' },
    { title: 'Save, Test, Check', prepare: demoTab('courier', 'cards'), when: (r) => !r.noDemo, target: () => $('.dr-bar'),
      text: '*Save* keeps a revision (you can go back to any). *Test* plays it now, you alone, and nothing it gives is kept: *F5* starts it again, *F9* brings you back here with the way it went lit up. The arrows undo and redo (*Ctrl+Z* and *Ctrl+Y*).' },
    { title: 'Back to the world', prepare: onPage,
      text: 'You build in the world: the world builder places the people and things, each one\'s *Configure* sets it up, and its *Blueprint* window holds these cards. The window\'s *Fullscreen* opens this editor, and *‹* at its top (or *Esc*) goes back into the world where you were. When a scenario is ready, *Switch on* in /whip makes it live for players.' },
    { title: 'That\'s the Director', prepare: onPage,
      text: 'Next, build a small job yourself, step by step.',
      buttons: [{ label: 'My first scenario', act: 'stage', n: 2 }, { label: 'Close', act: 'finish' }] },
];

const S2 = [
    { title: 'My first scenario', next: 'Start',
      text: 'You will build a small job from start to finish: a man on the street says a line, and pays you $100 when you answer. Do each step yourself: this card moves on when it is done.' },
    { title: 'A new scenario',
      text: 'Your job needs a scenario of its own. *Make it* makes an empty one called *Street job* and opens it here. (Any time after, /whip\'s Director tab makes one: *New scenario*.)',
      buttons: [{ label: 'Make it', act: 'make' }, { label: 'Stop', act: 'stop' }],
      done: mine },
    { title: 'The grid', mine: true, next: 'Next', target: () => cardEl(startOf() && startOf().id),
      text: 'Your scenario. It begins at *Scenario Enabled*; whatever you wire to it happens next. Drag the grid to move round, the wheel zooms.' },
    { title: 'Someone to talk to', mine: true, target: () => tabEl('world'),
      text: 'First, the man. Open the *World* tab: what your scenario puts in the world lives there.',
      done: () => ed().tab === 'world' || !!npcOf() },
    { title: 'Place him', mine: true, target: () => $('[data-act="build-open"]'),
      text: 'Press *Place in the world*. In the world builder, press *Place*, open *NPCs* and pick anyone: he is in your hand, so click the ground near you to put him down. Press *Configure* beside him and set *Spawn Logic* to *Always present*, so he stands there whenever the scenario is on, then press *Save* (bottom right). Open *Blueprint* and press its *Fullscreen* to come back here.',
      done: () => !!npcOf() && npcOf().layer === 'standing' },
    { title: 'How it starts', mine: true,
      target: () => {
          const s = startOf();
          if (!(s && ed().tab === 'card' && ed().selected.has(s.id))) return cardEl(s && s.id);
          return (ed().doc.settings.start || {}).mode === 'interaction' ? $('select[data-t="start"][data-k="world"]') : $('select[data-t="start"][data-k="mode"]');
      },
      text: 'Now, how it starts. Click *Scenario Enabled* on the grid; on its page set *It starts* to *Talk to an NPC*, then pick your man under *Which NPC*.',
      done: () => { const st = ed().doc.settings.start || {}; const n = npcOf(); return st.mode === 'interaction' && !!n && st.world === n.id; } },
    { title: 'What he says', mine: true, prepare: roomOnTheRight, target: () => (ed().tab !== 'cards' ? tabEl('cards') : palRow('dialog.line')),
      text: 'Open *Cards* and click *Dialog Line* (under Dialog; typing "dialog" in the search finds it). It lands in the middle of the grid.',
      done: () => !!lineOf() },
    { title: 'Wire it', mine: true, target: () => pinEl(startOf() && startOf().id, 'out', 'out'),
      text: 'Drag from the dot on the right of *Scenario Enabled* to the dot on the left of the *Dialog Line*. The scenario goes along the wires.',
      done: () => { const s = startOf(), l = lineOf(); return !!s && !!l && wiredTo(s.id, 'out', 'dialog.line') !== null; } },
    { title: 'Fill it in', mine: true,
      target: () => { const l = lineOf(); return l && ed().tab === 'card' && ed().selected.has(l.id) ? body() : cardEl(l && l.id); },
      text: 'Click the *Dialog Line* to open its settings. Set *Who speaks* to your man, write *What they say* ("Do me a favour?"), and the first answer under *Answers* ("Sure").',
      done: () => { const l = lineOf(), n = npcOf(); return !!l && !!n && l.props.npc === n.id && filled(l.props.line) && filled(l.props.opt1); } },
    { title: 'Pay', mine: true, prepare: roomOnTheRight, target: () => (ed().tab !== 'cards' ? tabEl('cards') : palRow('player.pay')),
      text: 'Add *Pay* the same way (under Player). It pays $100 unless you change it.',
      done: () => nodesOf('player.pay').length > 0 },
    { title: 'Answering pays', mine: true, target: () => pinEl(lineOf() && lineOf().id, 'out', 'opt1'),
      text: 'Drag from the dot by your *Answer 1* on the Dialog Line to *Pay*: answering it pays you.',
      done: () => { const l = lineOf(); return !!l && wiredTo(l.id, 'opt1', 'player.pay') !== null; } },
    { title: 'The end', mine: true, prepare: roomOnTheRight,
      target: () => (nodesOf('scenario.succeed').length ? pinEl(payOf() && payOf().id, 'out', 'paid') : ed().tab !== 'cards' ? tabEl('cards') : palRow('scenario.succeed')),
      text: 'Add *Succeed* (under Scenario), then drag from the *Paid* dot on *Pay* to it. The scenario ends there, and it went well.',
      done: () => { const p = payOf(); return !!p && wiredTo(p.id, 'paid', 'scenario.succeed') !== null; } },
    { title: 'Check it', mine: true, target: () => $('[data-act="check"]'),
      text: () => (ed().checkedAt > run.since && errorsNow()
          ? 'Check found something to fix: its page lists it, and a click on one takes you to its card. Fix it, then press *Check* again.'
          : 'Press *Check*: it reads the whole scenario for anything wrong or missing.'),
      done: (r) => ed().checkedAt > r.since && !errorsNow() },
    { title: 'Save it', mine: true, target: () => $('[data-act="save"]'),
      text: 'Press *Save* (or Ctrl+S). Each save is a revision you can go back to.',
      done: () => !!ed().history && !ed().history.isDirty(ed().doc) },
    { title: 'A world of your own', mine: true, next: 'Next', target: () => $('.dr-dock-btn[data-act="isolate"]'),
      text: 'If you like: *Isolate world* puts you where nobody else is, so nobody walks into your test (closing the Director brings you back). Press it, or *Next*.',
      done: () => ed().isolated },
    { title: 'Test it', mine: true, target: () => $('[data-act="test"]'),
      prepare: (r) => { r.base.tested = ed().testedAt || 0; },
      text: 'Press *Test*. The editor closes and you play it: walk to your man and *Talk*. (A test pays nothing: it says what it would have paid.) When it ends, or whenever you like, press *F9* to come back here.',
      done: (r) => (ed().testedAt || 0) > r.base.tested },
    { title: 'Playing', prepare: (r) => { r.base.lastTest = ed().lastTest; },
      text: 'Talk to your man, then *F9* to come back.',
      done: (r) => !!ed().lastTest && ed().lastTest !== r.base.lastTest },
    { title: 'How it went', mine: true, next: 'Finish', target: () => cardEl(nodesOf('scenario.succeed')[0] && nodesOf('scenario.succeed')[0].id),
      text: 'What ran is lit on the grid: *green*, it succeeded; *red*, it failed; *yellow*, it stopped part way. A card that could not do its work is *red* either way. *Check* lists every step, and why a card could not. Change anything and Test again. When it is ready, *Switch on* (on Check, or in /whip\'s Director tab): players can start it.' },
];

/** Every kind of card, from the list this server has (another resource's cards are a kind of their own). */
const KIND_SAYS = {
    events: 'Wait for something to happen: an NPC killed, a car entered, an item picked up.',
    goals: 'A whole objective in one card: go to, bring, collect, steal or deliver a car, survive.',
    dialog: 'Talk: lines with answers, picking the team, haggling, selling to an NPC.',
    world: 'Make and move the world: NPCs, groups, cars, props, items, doors, prompts.',
    player: 'The player: pay, charge, give and take, objectives, blips, skill checks.',
    lore: 'Your story\'s named people acting on the player: send money, and with a phone resource, text and give their contact.',
    flow: 'The plumbing: in order, wait, countdown, if, random, wait for all.',
    scenario: 'Endings and variables: succeed, fail, call off, set and add.',
};
function gallery() {
    const groups = groupCards(ed().cards, '');
    const total = groups.reduce((n, g) => n + g.cards.length, 0);
    return `<div class="dr-tut-gallery-sum">${total} cards in ${groups.length} kinds, on this server now</div><div class="dr-tut-gallery">`
        + groups.map((g) => `<div class="dr-tut-kind kind-${e(g.tint || g.cat)}"><div class="dr-tut-kind-head"><b>${e(g.title)}</b><span>${g.cards.length}</span></div>`
            + `<div class="dr-tut-kind-says">${e(KIND_SAYS[g.cat] || ('Added by ' + (g.cards[0].owner || 'another resource')))}</div>`
            + `<div class="dr-tut-kind-eg">${e(g.cards.slice(0, 4).map((c) => c.title).join(' · '))}</div></div>`).join('')
        + '</div>';
}

const S3 = [
    { title: 'What\'s possible', prepare: onPage,
      text: 'The three jobs that ship with whip, every kind of card, and what else the Director does. A couple of minutes: *Next* to go on.' },
    { title: 'Courier', at: 'corner', prepare: showcase('courier', { flow: true }), when: (r) => !r.noDemo,
      text: 'The smallest whole job, played the way it goes when all goes right. The boss talks (*Dialog Lines*) and you pick your team (*Pick Team*); a package appears across town with a mark on the map; bring it back and he pays you.' },
    { title: 'Every other way', at: 'corner', prepare: showcase('courier', { uses: ['late', 'noPlace', 'no', 'missing', 'payFail'] }), when: (r) => !r.noDemo,
      text: 'A good job handles the rest as well: too slow fails it, walking away calls it off, coming back without the package gets a word from the boss. Every outcome is a dot; wire the ones that matter.' },
    { title: 'The Vault', at: 'corner', prepare: showcase('vault', { flow: true }), when: (r) => !r.noDemo,
      text: 'A heist against a forty-minute clock: hack the keypad (a *Skill Check*; a miss sets the guards on you), the vault door opens, drill the safe (*Progress*), take the cash and get out of the building.' },
    { title: 'Steal the Car', at: 'corner', prepare: showcase('steal_car', { flow: true }), when: (r) => !r.noDemo,
      text: 'Guards round a yard: kill them, take the key one of them drops, drive the car to the buyer (the mark follows it) and get paid when you arrive.' },
    { title: 'Every kind of card', wide: true, prepare: (r) => { api.clearFlow(); api.canvas().setUses([], false); }, extra: gallery,
      text: 'Each kind has its colour on the grid. Search *Cards* for any of them.' },
    { title: 'Build the world', prepare: demoTab('steal_car', 'world'), when: (r) => !r.noDemo, target: body,
      text: 'The world builder puts anything anywhere, inside interiors too: props from a catalog of over a thousand, any ped as an NPC, any car, spots, item spots, containers and doors.' },
    { title: 'Seven ways to start', prepare: demoTab('steal_car', 'card', 'start'), when: (r) => !r.noDemo, target: () => $('select[data-t="start"][data-k="mode"]'),
      text: 'Talk to an NPC, press something (a laptop, a keypad), walk near a place, use an item, on a timer, from another resource\'s script, or by an admin\'s hand.' },
    { title: 'Crews', prepare: demoTab('steal_car', 'cards'), when: (r) => !r.noDemo, target: () => cardEl('team'),
      text: '*Pick Team*: whoever starts the job picks who comes along, from the players nearby or by character ID, and each one is asked first. *Team size* (on Scenario Enabled) is how many.' },
    { title: 'Memory', prepare: demoTab('steal_car', 'vars'), when: (r) => !r.noDemo, target: () => tabEl('vars'),
      text: '*Variables* keep numbers, words and yes or no for one run (how many delivered, the price haggled). *Player flags* remember a player from run to run (met the boss already, owes him one).' },
    { title: 'Test, play back, go back', prepare: demoTab('steal_car', 'cards'), when: (r) => !r.noDemo, target: () => $('.dr-bar'),
      text: 'Test plays it with nothing of value given or kept, and lights the way it went. A scenario that is on shows its live runs moving across the grid. Every Save is a revision to go back to (on Scenario Enabled).' },
    { title: 'Tidy blueprints', prepare: (r) => { api.clearFlow(); }, at: 'corner',
      text: 'Select cards and press *C* to box them with a comment. Double-click a wire for a *Reroute* dot to bend it round. *Ctrl+C* and *Ctrl+V* copy cards, even into another scenario.' },
    { title: 'Cards from other resources', prepare: (r) => { api.clearFlow(); },
      text: 'Any resource can add cards of its own (whip_director_cards_example shows how): they appear in *Cards* in their own colour. Scripts can start runs, hear them start and end, and switch scenarios on and off.' },
    { title: 'Your turn', prepare: onPage,
      text: 'That is what the Director can do. Make something of your own: *New scenario* in /whip\'s Director tab. The *Tutorial* button brings any stage back.',
      buttons: [{ label: 'Close', act: 'finish' }] },
];

const STAGES = {
    0: { title: 'Tutorial', steps: MENU },
    1: { title: 'Director basics', blurb: 'A tour of the editor, and where scenarios are made.', steps: S1 },
    2: { title: 'My first scenario', blurb: 'Build a small job yourself, step by step.', steps: S2 },
    3: { title: 'What\'s possible', blurb: 'The shipped jobs, every kind of card, and more.', steps: S3 },
};
