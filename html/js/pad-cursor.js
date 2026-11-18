// ========================================
// PAD CURSOR — a mouse, on a controller, for a screen built for one
//
// Written for the Director (director/pad.js), then shared with the /whip panel: a screen of buttons,
// rows, fields and lists, or of cards dragged about a grid, gets a mouse on a pad. A circle the left
// stick moves (the inventory's: it slows over something it can press), and the pad presses the mouse's
// own buttons where the circle is, so the page's own handlers run and there is one path for both:
//   A        the left button. Held, it drags; a tap is a click, two quick taps a double click.
//   X        a right click (nav 'buttonX').
//   D-pad    jumps the circle to the nearest thing that way it can press. A box the screen says is a
//            question or a menu (modal) keeps it inside; a list that scrolls is scrolled to what it finds.
//   a field  A opens the pad keyboard (pad-keyboard.js); a list (<select>), a menu of its choices
//   RS       scrolls the list under the circle (or pans the screen's grid)    LT / RT  the grid's zoom
// What B, Y, LB and RB mean is the screen's, and so are the hints. The screen's scope takes the sticks
// as numbers with A's hold among them (client/controller.lua, navAnalog `a`).
//
//   const cur = createPadCursor({
//       name?,                // the circle's element also wears .pad-cursor-<name> (one per screen)
//       root, shown,          // () => the screen's element; () => is it up (and not handed away)
//       targets,              // a selector: what the circle can press
//       floats?,              // a selector for the screen's boxes outside root (its menus, its search)
//       modal?,               // () => a box the D-pad stays in, or null
//       start?,               // () => where the circle first appears (the thing picked), else the screen's middle
//       menu?,                // ({ at, items: [{ label, run }] }) => shows a list's choices; default: its own
//       press?,               // (node) => true when A there is the screen's own business (nothing pressed);
//                             //   asked first, before a field opens the keyboard (a slider the screen drags)
//       label?, afterType?,   // (field) => the keyboard's title; (field) => after a field is typed into
//       onGrid?, pan?, zoomAt?,   // a screen with a grid: (node) => on it?; (dx, dy); (x, y, k)
//   });
//   cur.analog(a)   cur.nav(nav) -> true if it was the cursor's   cur.hide()   cur.letGo()
//   cur.on()   cur.over() -> the thing under the circle   cur.at() -> the node under it   cur.typeInto(field)
//   cur.pos() -> { x, y }   cur.moveTo(node) puts the circle on it   cur.refresh() rings what is under it again
//   (after the screen redrew under a still circle)
//
// Drawn by css/pad-cursor.css, only on a pad: .pad-cursor, and .pad-over on what it would press.
// ========================================

import { NuiRouter } from './router.js';
import { openPadKeyboard } from './pad-keyboard.js';
import { escapeHtml } from './utils.js';
import { pref } from './prefs.js';

// the circle at a full push: screen heights a second (the inventory's), times the player's own "Menu cursor speed"
// (Settings → Server: 50-200%, read each frame)
const SPEED = 1.3;
const CURVE = 1.6;      // a light push is slow and exact: speed grows as push ^ this
const SLOW = 0.45;      // over something it can press, it slows to this share
const SCROLL = 1100;    // the right stick over a list: px a second at a full push
const PAN = 1000;       // over a grid: px a second
const ZOOM = 1.4;       // a trigger pulled all the way: the zoom changes by e^this a second
const CLICK_PX = 6;     // a press and release closer than this is a click
const DOUBLE_MS = 400;  // two clicks this close together are a double click

/** The keyboard has A while it is up: its release goes there, so it is not waited for here. Back from
 *  it, an A that is down within this long is the one that pressed Done (held into the screen). */
const AFTER_TYPING_MS = 250;

// THE CEF 103 LESSON (the inventory's padZoom): inside a CSS-zoomed box getBoundingClientRect can come
// back UNZOOMED in FiveM. A 100px probe in the box says which: about 100 × zoom wide means screen pixels,
// about 100 means unzoomed. Measured once per box, for every cursor.
const zoomFix = new WeakMap();

/** The zoom a node is drawn at: `k`, the product of its own and its ancestors' CSS zoom (the /whip panel's one zoom),
 *  and `host`, the nearest zoomed box (null when there is none). Also ui-controls.js's, to draw a list at that size. */
export function zoomChain(node) {
    let k = 1, host = null;
    for (let n = node; n && n !== document.documentElement; n = n.parentElement) {
        const z = parseFloat(getComputedStyle(n).zoom);
        if (z > 0 && Math.abs(z - 1) > 0.001) { k *= z; if (!host) host = n; }
    }
    return { k, host };
}

function rectScale(node) {
    const { k, host } = zoomChain(node);
    if (!host || Math.abs(k - 1) < 0.01) return 1;
    if (zoomFix.has(host)) return zoomFix.get(host);
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;left:0;top:0;width:100px;height:1px;visibility:hidden;pointer-events:none';
    host.appendChild(probe);
    const w = probe.getBoundingClientRect().width;
    probe.remove();
    const fix = Math.abs(w - 100 * k) < Math.abs(w - 100) ? 1 : k;
    zoomFix.set(host, fix);
    return fix;
}

// THE PAD OR THE MOUSE, NEVER BOTH (the inventory's padOwnsInput). The circle presses the mouse's own buttons, and
// the game's browser goes on sending the real mouse's events from where it was left, a move whenever the page
// changes under it among them: a card being dragged jumped there, and a box drew out to it. While a pad drives a
// screen with its circle up, the real mouse's events are dropped before the page hears them (the circle's are made
// here: not isTrusted). Which device is in the player's hands is Lua's to say (client/controller.lua,
// html[data-input]): the mouse moved, it is the mouse's again.
const live = new Set();   // the cursors whose circle is up: { shown }
const MOUSE_EVENTS = ['mousedown', 'mouseup', 'mousemove', 'mouseover', 'mouseout', 'click', 'dblclick', 'contextmenu',
    'pointerdown', 'pointerup', 'pointermove', 'pointerover', 'pointerout', 'wheel'];

function padOwnsInput(e) {
    if (!e.isTrusted || document.documentElement.dataset.input !== 'pad') return false;
    for (const c of live) if (c.shown()) return true;
    return false;
}

for (const type of MOUSE_EVENTS) {
    window.addEventListener(type, (e) => {
        if (!padOwnsInput(e)) return;
        e.stopImmediatePropagation();
        if (type === 'mousedown' || type === 'contextmenu') e.preventDefault();
    }, true);
}

/** A node's box in screen pixels, whatever CEF 103 measured it in. Shared: the Settings page's sliders
 *  (settings-page.js) are inside a zoomed box too. */
export function screenRect(node) {
    const r = node.getBoundingClientRect(), k = rectScale(node);
    return { left: r.left * k, right: r.right * k, top: r.top * k, bottom: r.bottom * k,
             width: r.width * k, height: r.height * k };
}

export function createPadCursor(o) {
    const MENU_ROW = '.pad-menu-row';
    const TARGETS = o.targets + ', ' + MENU_ROW;
    const onGrid = (n) => !!(o.onGrid && n && o.onGrid(n));

    const st = {
        on: false, x: 0, y: 0,
        stick: { x: 0, y: 0, rx: 0, ry: 0, lt: 0, rt: 0 }, a: false,
        raf: 0, last: 0,
        over: null,             // the target under the circle
        down: null,             // A held on the page: { x, y, target }
        eaten: false,           // A's press opened the keyboard or a list: its release is nothing
        lastClick: null,        // { t, x, y }: for a double click
        typedAt: -1e9,          // when the keyboard went: an A already down then is its Done, not a press here
        menu: null,             // this cursor's own menu of a list's choices, while it is up
    };

    const gate = { shown: o.shown };   // in `live` while the circle is up: the real mouse is held off

    const el = document.createElement('div');
    el.className = 'pad-cursor' + (o.name ? ' pad-cursor-' + o.name : '');
    el.innerHTML = '<div class="pad-cursor-ring"></div>';
    document.body.appendChild(el);

    // ---- where things are ----

    /** Is this the screen's (inside it, a box of its floating over it, or this cursor's menu)? */
    function ours(node) {
        if (!node || !node.closest) return false;
        const root = o.root();
        return !!((root && root.contains(node)) || (o.floats && node.closest(o.floats))
            || (st.menu && st.menu.contains(node)));
    }

    function hit() {
        const n = document.elementFromPoint(st.x, st.y);
        return ours(n) ? n : null;
    }

    function targetOf(n) {
        const t = n && n.closest(TARGETS);
        return t && ours(t) && !t.disabled ? t : null;
    }

    /** The scrolling list a node is in, if any (a grid is not one: it pans). */
    function scrollerAt(n) {
        for (; n && n !== document.body; n = n.parentElement) {
            if (onGrid(n)) return null;
            const s = getComputedStyle(n);
            if ((s.overflowY === 'auto' || s.overflowY === 'scroll') && n.scrollHeight > n.clientHeight) return n;
        }
        return null;
    }

    // ---- the circle ----

    function show() {
        if (st.on) return;
        st.on = true;
        live.add(gate);
        const s = o.start && o.start();
        if (s && s.getClientRects().length) {
            const b = screenRect(s);
            st.x = (b.left + b.right) / 2;
            st.y = (b.top + b.bottom) / 2;
        } else {
            st.x = innerWidth * 0.6;
            st.y = innerHeight * 0.5;
        }
        el.classList.add('on');
        place();
    }

    function setOver(t) {
        if (st.over === t) return;
        if (st.over) st.over.classList.remove('pad-over');
        st.over = t;
        if (t) t.classList.add('pad-over');
        el.classList.toggle('over', !!t);
        NuiRouter.hintsChanged();   // the strip's words follow what is under the circle
    }

    /** Ring what is under the circle again: a press often redraws, and the ring went with the old element. */
    function reover() {
        if (st.on) setOver(targetOf(hit()));
    }

    function fire(type, target, f = {}) {
        target.dispatchEvent(new MouseEvent(type, {
            bubbles: true, cancelable: true, view: window, clientX: st.x, clientY: st.y,
            button: f.button || 0, buttons: f.buttons || 0,
        }));
    }

    /** The circle moved: draw it, ring what is under it, and tell the page (a drag follows mousemove). */
    function place() {
        el.style.transform = `translate3d(${st.x}px, ${st.y}px, 0)`;
        const n = hit();
        setOver(targetOf(n));
        fire('mousemove', n || document.body, { buttons: st.down ? 1 : 0 });
    }

    // ---- A: the left button ----

    function press() {
        show();
        const n = hit();
        if (!n) return;
        if (o.press && o.press(n)) { st.eaten = true; return; }
        const field = n.closest('input, textarea, select');
        if (field && !field.disabled && !field.readOnly && field.type !== 'checkbox' && field.type !== 'radio') {
            st.eaten = true;
            if (field.tagName === 'SELECT') pickFrom(field); else typeInto(field, true);
            return;
        }
        st.down = { x: st.x, y: st.y, target: n };
        el.classList.add('down');
        fire('mousedown', n, { button: 0, buttons: 1 });
        reover();
    }

    function release() {
        el.classList.remove('down');
        if (st.eaten) { st.eaten = false; return; }
        const d = st.down;
        if (!d) return;
        st.down = null;
        const n = hit() || document.body;
        fire('mouseup', n, { button: 0 });
        if (Math.hypot(st.x - d.x, st.y - d.y) >= CLICK_PX || !d.target.isConnected) { reover(); return; }
        fire('click', d.target, { button: 0 });
        const now = performance.now(), last = st.lastClick;
        if (last && now - last.t < DOUBLE_MS && Math.hypot(st.x - last.x, st.y - last.y) < CLICK_PX * 2) {
            st.lastClick = null;
            if (d.target.isConnected) fire('dblclick', d.target, { button: 0 });
        } else {
            st.lastClick = { t: now, x: st.x, y: st.y };
        }
        reover();
    }

    // ---- X: a right click ----

    function rightClick() {
        show();
        const n = hit();
        if (!n) return;
        fire('mousedown', n, { button: 2, buttons: 2 });
        fire('mouseup', n, { button: 2 });
        fire('contextmenu', n, { button: 2 });
        reover();
    }

    // ---- typing, and lists ----

    function labelOf(field) {
        if (o.label) {
            const t = o.label(field);
            if (t) return t;
        }
        // The words beside it: a <label> around it (the panel's fields), or its own name for itself.
        const lab = field.closest('label');
        const words = lab && [...lab.childNodes].find((c) => c !== field && c.textContent && c.textContent.trim());
        return (words && words.textContent.trim()) || field.getAttribute('aria-label') || field.placeholder || 'Type';
    }

    /** A text field or a number, filled in on the pad keyboard: its own input and change events, as
     *  typing makes, so the page cannot tell the difference. `fromA`: A going down opened it (press), and
     *  its 'select', still to come, is not the keyboard's first key. */
    function typeInto(field, fromA) {
        st.a = false;           // the keyboard takes the pad: A's release goes to it (see AFTER_TYPING_MS)
        st.eaten = false;
        el.classList.remove('down');
        el.classList.add('typing');
        const done = () => {
            st.typedAt = performance.now();
            el.classList.remove('typing');
        };
        openPadKeyboard({
            title: labelOf(field),
            value: field.value,
            placeholder: field.placeholder || '',
            numeric: field.type === 'number',
            maxLength: field.maxLength > 0 ? field.maxLength : 0,
            fromA: fromA === true,
            onDone: (text) => {
                done();
                if (!field.isConnected) return;
                field.value = text;
                field.dispatchEvent(new Event('input', { bubbles: true }));
                if (field.isConnected) field.dispatchEvent(new Event('change', { bubbles: true }));
                if (field.isConnected && o.afterType) o.afterType(field);
            },
            onCancel: done,
        });
    }

    /** A list (<select>): its choices as a menu at the circle, the one picked first marked. The mousedown
     *  first, as a mouse would: a list that fills itself in then (the Director's Under list) does. */
    function pickFrom(select) {
        fire('mousedown', select, { button: 0, buttons: 1 });
        const items = Array.from(select.options).filter((x) => !x.disabled).map((x) => ({
            label: (x.value === select.value ? '● ' : '') + x.textContent,
            run: () => {
                if (!select.isConnected) return;
                select.value = x.value;
                select.dispatchEvent(new Event('change', { bubbles: true }));
            },
        }));
        if (!items.length) return;
        (o.menu || openOwnMenu)({ at: { x: st.x, y: st.y }, items });
    }

    // ---- its own menu, for a screen that has none ----

    function closeOwnMenu() {
        if (!st.menu) return false;
        st.menu.remove();
        st.menu = null;
        document.removeEventListener('mousedown', outsideMenu, true);
        return true;
    }

    function outsideMenu(e) {
        if (st.menu && !st.menu.contains(e.target)) closeOwnMenu();
    }

    function openOwnMenu(m) {
        closeOwnMenu();
        const box = document.createElement('div');
        box.className = 'pad-menu';
        box.innerHTML = m.items.map((it, i) =>
            `<button type="button" class="pad-menu-row" data-i="${i}">${escapeHtml(it.label)}</button>`).join('');
        box.addEventListener('click', (e) => {
            const row = e.target.closest(MENU_ROW);
            if (!row) return;
            const it = m.items[Number(row.dataset.i)];
            closeOwnMenu();
            if (it) it.run();
            reover();
        });
        document.body.appendChild(box);
        // At the circle, kept on the screen.
        const r = box.getBoundingClientRect();
        box.style.left = Math.max(8, Math.min(innerWidth - r.width - 8, m.at.x)) + 'px';
        box.style.top = Math.max(8, Math.min(innerHeight - r.height - 8, m.at.y)) + 'px';
        st.menu = box;
        document.addEventListener('mousedown', outsideMenu, true);
        // The circle onto the choice already made (or the first).
        const rows = [...box.querySelectorAll(MENU_ROW)];
        const on = rows.find((x) => x.textContent.startsWith('● ')) || rows[0];
        if (on) {
            on.scrollIntoView({ block: 'nearest' });
            const b = on.getBoundingClientRect();
            st.x = (b.left + b.right) / 2;
            st.y = (b.top + b.bottom) / 2;
            place();
        }
    }

    // ---- the D-pad: the next thing that way ----

    function jump(dir) {
        // The first press, before the circle is up: it lands on the nearest thing it can press, whichever
        // way that is.
        const fresh = !st.on;
        show();
        const from = st.over ? screenRect(st.over) : { left: st.x, right: st.x, top: st.y, bottom: st.y, width: 0, height: 0 };
        const ax = (from.left + from.right) / 2, ay = (from.top + from.bottom) / 2;
        let best = null, bestScore = Infinity;
        // A menu or a question up: the D-pad stays in it (what is behind it is not what is being asked
        // about, and peeks out at its edges).
        const box = st.menu || (o.modal && o.modal());
        const root = o.root();
        const pool = box ? [...box.querySelectorAll(TARGETS)] : root ? [...root.querySelectorAll(TARGETS)] : [];
        for (const t of pool) {
            if (t === st.over || t.disabled || !t.getClientRects().length) continue;
            const b = screenRect(t);
            if (b.width < 1) continue;
            // Off the screen counts only in a list that scrolls: it is scrolled to below. A card off a
            // grid's edge does not (the grid pans with the right stick).
            const off = b.right < 0 || b.bottom < 0 || b.left > innerWidth || b.top > innerHeight;
            const inList = scrollerAt(t.parentElement);
            if (off && !inList) continue;
            const bx = (b.left + b.right) / 2, by = (b.top + b.bottom) / 2;
            // Only what can be seen there: a grid runs on under a column, and a card behind it is not a
            // place to go. (A list's own rows may be scrolled out of sight: they are scrolled to.)
            if (!inList) {
                const h = document.elementFromPoint(bx, by);
                if (!h || (h !== t && !t.contains(h))) continue;
            }
            if (fresh) {
                const d = Math.hypot(bx - ax, by - ay);
                if (d < bestScore) { bestScore = d; best = { t, x: bx, y: by }; }
                continue;
            }
            let along, across;
            if (dir === 'down' || dir === 'up') {
                if (dir === 'down' ? by <= ay + 1 : by >= ay - 1) continue;
                along = dir === 'down' ? b.top - from.bottom : from.top - b.bottom;
                across = Math.max(0, Math.max(from.left, b.left) - Math.min(from.right, b.right));
            } else {
                if (dir === 'right' ? bx <= ax + 1 : bx >= ax - 1) continue;
                along = dir === 'right' ? b.left - from.right : from.left - b.right;
                across = Math.max(0, Math.max(from.top, b.top) - Math.min(from.bottom, b.bottom));
            }
            const score = Math.max(0, along) + across * 3;
            if (score < bestScore) { bestScore = score; best = { t, x: bx, y: by }; }
        }
        if (!best) return;
        // In a list that scrolls: shown first (it may be below the fold, or cut by the list's edge), and
        // the circle goes where it is then.
        if (scrollerAt(best.t.parentElement)) {
            best.t.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            const b = screenRect(best.t);
            best.x = (b.left + b.right) / 2;
            best.y = (b.top + b.bottom) / 2;
        }
        st.x = Math.min(innerWidth - 1, Math.max(0, best.x));
        st.y = Math.min(innerHeight - 1, Math.max(0, best.y));
        place();
    }

    // ---- the sticks and triggers ----

    function run() {
        if (st.raf) return;
        const s = st.stick;
        if (!(s.x || s.y || s.rx || s.ry || s.lt || s.rt)) return;
        st.last = performance.now();
        st.raf = requestAnimationFrame(frame);
    }

    function frame(now) {
        st.raf = 0;
        if (!o.shown()) return;
        const dt = Math.min(0.05, Math.max(0, (now - st.last) / 1000));
        st.last = now;
        const s = st.stick;
        let moved = false;

        const push = Math.min(1, Math.hypot(s.x, s.y));
        if (push > 0) {
            show();
            const speed = SPEED * (pref('pad.cursorSpeed', 100) / 100) * innerHeight * Math.pow(push, CURVE)
                * (st.over ? SLOW : 1);
            st.x = Math.min(innerWidth - 1, Math.max(0, st.x + s.x / push * speed * dt));
            st.y = Math.min(innerHeight - 1, Math.max(0, st.y - s.y / push * speed * dt));   // stick up is +y
            moved = true;
        }
        if (s.rx || s.ry) {
            const list = st.on ? scrollerAt(document.elementFromPoint(st.x, st.y)) : null;
            if (list) list.scrollTop -= s.ry * SCROLL * dt;                  // stick up: up the list
            else if (o.pan) o.pan(-s.rx * PAN * dt, s.ry * PAN * dt);        // right: see what is to the right
            moved = true;
        }
        if ((s.lt || s.rt) && st.on && o.zoomAt) {
            const n = document.elementFromPoint(st.x, st.y);
            if (onGrid(n)) o.zoomAt(st.x, st.y, Math.exp((s.rt - s.lt) * ZOOM * dt));
        }
        if (moved && st.on) place();
        if (s.x || s.y || s.rx || s.ry || s.lt || s.rt) st.raf = requestAnimationFrame(frame);
    }

    // ---- the cursor's face to its screen ----

    return {
        analog(a) {
            st.stick = { x: +a.x || 0, y: +a.y || 0, rx: +a.rx || 0, ry: +a.ry || 0, lt: +a.lt || 0, rt: +a.rt || 0 };
            const down = a.a === true;
            if (down !== st.a) {
                st.a = down;
                if (down && performance.now() - st.typedAt < AFTER_TYPING_MS) st.eaten = true;   // Done's A, still held
                else if (down) press();
                else release();
            }
            run();
        },
        /** The D-pad and X, and B while its own menu is up (it shuts). Anything else is the screen's. */
        nav(nav) {
            if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') { jump(nav); return true; }
            if (nav === 'buttonX') { rightClick(); return true; }
            if (nav === 'back' && closeOwnMenu()) { reover(); return true; }
            return false;
        },
        /** The screen closed or went away: let go of anything held, hide the circle. */
        hide() {
            if (st.down) release();
            closeOwnMenu();
            st.on = false;
            live.delete(gate);
            st.a = false;
            st.stick = { x: 0, y: 0, rx: 0, ry: 0, lt: 0, rt: 0 };
            if (st.raf) { cancelAnimationFrame(st.raf); st.raf = 0; }
            setOver(null);
            el.classList.remove('on', 'down', 'over');
        },
        /** A held button let go (B on its way to the screen's Esc). */
        letGo() { if (st.down) release(); },
        on: () => st.on,
        over: () => st.over,
        at: () => (st.on ? document.elementFromPoint(st.x, st.y) : null),
        pos: () => ({ x: st.x, y: st.y }),
        /** The circle onto a node (shown first if it is in a list that scrolls). */
        moveTo(node) {
            if (!node || !node.getClientRects().length) return;
            show();
            if (scrollerAt(node.parentElement)) node.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            const b = screenRect(node);
            st.x = Math.min(innerWidth - 1, Math.max(0, (b.left + b.right) / 2));
            st.y = Math.min(innerHeight - 1, Math.max(0, (b.top + b.bottom) / 2));
            place();
        },
        refresh: reover,
        menuOpen: () => !!st.menu,
        typeInto,
    };
}
