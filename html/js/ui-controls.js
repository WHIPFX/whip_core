/* ========================================
   UI CONTROLS — whip's own list for every <select>, and a stepper for every number box

   CEF's own controls do not belong over a game: a <select> opens the browser's white popup (and over the game it
   does not always open), and a number box draws the browser's grey spin arrows. Every screen of this page gets
   whip's instead, without one of them changing:

   - A SELECT KEEPS ITS PLACE, ITS CLASSES AND ITS CLOSED LOOK (each screen's CSS). Only the list is whip's: a press
     on it (the mouse, or Space, F4, Alt+Down; Enter stays the form's) opens the Director's list under it (director/dropdown.js
     openChoices: a search once there are many, its groups, a tick on the choice, the arrow keys, Enter, Esc), and
     a pick sets the select and sends input and change from it, as the browser's list would. Nothing is wrapped,
     moved or copied, so no screen's layout, styling or lookups change. On a pad the cursor already opens a list of
     its own (pad-cursor.js pickFrom), so a pad's presses are left to it.

   - A NUMBER BOX GETS ONE STEPPER, THE SAME ONE: a minus and a plus, a square each as tall as the field, at its
     right edge while the pointer is on the
     box or the box has the keys, as the browser drew its arrows. One element for the whole page, placed over the
     box it serves; nothing is added to any box. Held, it repeats.

   ONE LISTENER EACH, ON THE DOCUMENT: no observer, no work per control, nothing while no control is in use.

   Opt out with data-native on the control. The give amount opts out by its id: its slider is its stepper.
   ======================================== */

import { openChoices, closeDropdown, dropdownAnchor, choicesOf } from './director/dropdown.js';
import { screenRect, zoomChain } from './pad-cursor.js';
import { uiIcon } from './ui-icons.js';

const SEARCH_AT = 9;   // options from which the list has a search box (as the Director's)
// The give amount steps with its own slider.
const SKIP_NUMBER = '[data-native], #inv-split-value';
const SKIP_SELECT = '[data-native], [multiple], select[size]:not([size="1"]), .dr-dd-wrap > select';
// The capsules whose number box is bare text inside them: the stepper sits at the capsule's edge.
const CHROME = '.wp-field, .ce-field-box';
const HOLD_DELAY = 380;   // ms before a held arrow repeats
const HOLD_EVERY = 60;    // ms between repeats
const TRACK_EVERY = 120;  // ms between checks that the box the stepper serves has not moved or gone

const isPad = () => document.documentElement.dataset.input === 'pad';

// ============================================
// Selects
// ============================================

/** What a select's list hangs from: the field capsule it sits in (the list as wide as the field), else itself. */
const anchorOf = (sel) => sel.closest(CHROME) || sel;

/** whip's list for a select, under it. False when the select keeps the browser's (opted out, disabled). */
function openList(sel) {
    if (sel.disabled || sel.matches(SKIP_SELECT) || !sel.options.length) return false;
    const z = zoomChain(sel).k;
    openChoices(anchorOf(sel), choicesOf(sel), sel.value, (v) => {
        if (!sel.isConnected || sel.value === v) return;
        sel.value = v;
        sel.dispatchEvent(new Event('input', { bubbles: true }));
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, {
        search: sel.options.length >= SEARCH_AT,
        label: sel.getAttribute('aria-label') || '',
        focus: sel,   // the keys go back to the select itself, not its capsule
        // The screen's own size where it is zoomed (the /whip panel); the Director's (--dr-zoom) elsewhere.
        zoom: Math.abs(z - 1) > 0.01 ? z : 0,
    });
    return true;
}

/** A press on a select: its list (which takes the keys: the choice, or its search), or the list put away when it is
 *  the one up. */
function pressSelect(ev, sel) {
    if (dropdownAnchor() === anchorOf(sel)) {
        ev.preventDefault();
        closeDropdown();
        return;
    }
    if (openList(sel)) ev.preventDefault();
}

// The mouse. Only a real press (isTrusted): the pad cursor sends a made-up mousedown before opening its own list.
document.addEventListener('mousedown', (ev) => {
    if (ev.button !== 0 || !ev.isTrusted || isPad()) return;
    const sel = ev.target;
    if (sel instanceof HTMLSelectElement) pressSelect(ev, sel);
}, true);

// The keys that open a select's list (the arrows alone still step through it in place, as the browser's do).
document.addEventListener('keydown', (ev) => {
    const sel = ev.target;
    if (!(sel instanceof HTMLSelectElement) || isPad()) return;
    const k = ev.key;
    if (k === ' ' || k === 'F4' || (ev.altKey && (k === 'ArrowDown' || k === 'ArrowUp'))) {
        if (dropdownAnchor() === anchorOf(sel)) return;   // the list has the keys
        if (openList(sel)) {
            ev.preventDefault();
            ev.stopPropagation();
        }
    }
}, true);

// ============================================
// Number boxes
// ============================================

let stepEl = null;     // the one stepper, made on first use
let target = null;     // the box it serves, or null when hidden
let over = false;      // the pointer is on the box or the stepper
let trackTimer = 0;
let holdTimer = 0;
let stepped = false;   // a press moved the value: change is sent when it ends

const eligible = (n) => n instanceof HTMLInputElement && n.type === 'number' && !n.disabled && !n.readOnly
    && !n.matches(SKIP_NUMBER);

/** The decimals a number is written with. */
function decimals(n) {
    const s = String(n);
    const at = s.indexOf('.');
    return at < 0 ? 0 : s.length - at - 1;
}

/** One step up (d = 1) or down (-1), kept to the box's min and max. True when the value changed. */
function stepOnce(input, d) {
    let step = parseFloat(input.getAttribute('step'));
    if (!(step > 0)) step = 1;   // none, 'any' or nonsense: by one
    const min = input.min !== '' && Number.isFinite(parseFloat(input.min)) ? parseFloat(input.min) : null;
    const max = input.max !== '' && Number.isFinite(parseFloat(input.max)) ? parseFloat(input.max) : null;
    const cur = parseFloat(input.value);
    // An empty box starts where the browser's arrows would: at its min, else at 0.
    let next = Number.isFinite(cur) ? cur + d * step : (min !== null ? min : 0);
    if (min !== null && next < min) next = min;
    if (max !== null && next > max) next = max;
    // Kept to the digits the step and the value already have: 0.1 + 0.2 is 0.3, not 0.30000000000000004.
    const places = Math.min(10, Math.max(decimals(step), Number.isFinite(cur) ? decimals(cur) : 0));
    const text = String(Number(next.toFixed(places)));
    if (text === input.value) return false;
    input.value = text;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
}

/** The stepper, made once: two buttons that never take the keys (the box keeps them). */
function makeStepper() {
    stepEl = document.createElement('div');
    stepEl.className = 'ui-step';
    stepEl.innerHTML = '<button type="button" tabindex="-1" data-d="-1" aria-label="Less">' + uiIcon('minus') + '</button>'
        + '<button type="button" tabindex="-1" data-d="1" aria-label="More">' + uiIcon('plus') + '</button>';
    // A press keeps the focus in the box (so Enter still does the box's action, and the stepper stays).
    stepEl.addEventListener('mousedown', (ev) => ev.preventDefault());
    stepEl.addEventListener('pointerdown', (ev) => {
        const b = ev.target.closest('button');
        if (ev.button !== 0 || !b || !target) return;
        ev.preventDefault();
        clearTimeout(holdTimer);
        const input = target;
        const d = Number(b.dataset.d);
        stepped = stepOnce(input, d) || stepped;
        const repeat = () => {
            if (target !== input || !input.isConnected) return stopHold();
            stepped = stepOnce(input, d) || stepped;
            holdTimer = setTimeout(repeat, HOLD_EVERY);
        };
        holdTimer = setTimeout(repeat, HOLD_DELAY);
        window.addEventListener('pointerup', stopHold, { once: true });
        window.addEventListener('pointercancel', stopHold, { once: true });
    });
    stepEl.addEventListener('pointerleave', (ev) => {
        over = !!(target && ev.relatedTarget && target.contains(ev.relatedTarget));
        if (!over && document.activeElement !== target) hide();
    });
    stepEl.addEventListener('pointerenter', () => { over = true; });
    document.body.appendChild(stepEl);
}

/** A held arrow let go: the repeats stop, and the box says it changed (once, as a typed value does on leaving). */
function stopHold() {
    clearTimeout(holdTimer);
    holdTimer = 0;
    window.removeEventListener('pointerup', stopHold);
    window.removeEventListener('pointercancel', stopHold);
    if (stepped && target && target.isConnected) target.dispatchEvent(new Event('change', { bubbles: true }));
    stepped = false;
}

/** Over the box's right edge, inside it; beside it on the right when the box is too narrow to share. The box is the
 *  chrome the number sits in: a field capsule (the /whip panel's, the Camera Creator's) whose input is bare text,
 *  else the input itself. */
function place() {
    if (!target) return;
    if (!target.isConnected) { hide(); return; }
    const r = screenRect(target.closest(CHROME) || target);
    if (r.width < 1 || r.height < 1) { hide(); return; }
    // Two squares as tall as the field less a small margin, at least 18px each so they stay easy to hit.
    const inset = Math.max(3, Math.min(6, Math.round(r.height * 0.13)));
    const h = Math.max(18, Math.round(r.height - inset * 2));
    const w = h * 2;
    const inside = r.width >= w * 2.6;
    const s = stepEl.style;
    s.left = Math.round(inside ? r.right - w - inset : r.right + 4) + 'px';
    s.top = Math.round(r.top + (r.height - h) / 2) + 'px';
    s.width = w + 'px';
    s.height = h + 'px';
    s.fontSize = Math.max(10, Math.round(h * 0.5)) + 'px';
}

function show(input) {
    if (!stepEl) makeStepper();
    if (target !== input) {
        stopHold();
        target = input;
    }
    place();
    if (!target) return;
    stepEl.classList.add('on');
    if (!trackTimer) trackTimer = setInterval(place, TRACK_EVERY);
}

function hide() {
    stopHold();
    target = null;
    over = false;
    if (stepEl) stepEl.classList.remove('on');
    clearInterval(trackTimer);
    trackTimer = 0;
}

document.addEventListener('pointerover', (ev) => {
    if (isPad()) return;
    if (eligible(ev.target)) { over = true; show(ev.target); }
}, true);

document.addEventListener('pointerout', (ev) => {
    if (ev.target !== target) return;
    const to = ev.relatedTarget;
    over = !!(to && stepEl && stepEl.contains(to));
    if (!over && document.activeElement !== target) hide();
}, true);

document.addEventListener('focusin', (ev) => {
    if (!isPad() && eligible(ev.target)) show(ev.target);
}, true);

document.addEventListener('focusout', (ev) => {
    if (ev.target === target && !over) hide();
}, true);

// A scroll or a resize moves the box: the stepper follows at once rather than at the next check.
window.addEventListener('scroll', () => { if (target) place(); }, { capture: true, passive: true });
window.addEventListener('resize', () => { if (target) place(); }, { passive: true });
