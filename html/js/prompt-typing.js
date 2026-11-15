// ========================================
// TYPING INTO A PROMPT — the keyboard's half (client/prompt_typing.lua)
//
// While a value is typed into a 3D prompt on a keyboard, whip's page holds the keys (NUI focus, no cursor; the game
// keeps its input, so the mouse still looks round) and they go into a real text box kept off screen, so pasting
// (Ctrl+V: a song's link), the keyboard's own layout and its accents all work as in any field. Nothing is drawn
// here: the capsule in the world is a DUI that Lua paints. Each change of the text goes to Lua, then Enter (done) or
// Esc (cancel); Backspace on nothing is a cancel too. A number takes digits only, without a leading zero; nothing
// goes past `max`.
//
//   from Lua:  promptTypingOpen { id, numeric, max, text }   promptTypingSet { id, text }   promptTypingClose
//   to Lua:    promptTyping { id, text } / { id, text, done } / { id, cancel }
//
// A key scope at 0.45: over everything but the creator. Open only while typing, when no screen is up (typing ends
// as one opens). No onNav: a pad never types here (the pad's keyboard is Lua's, in the world).
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';

let typing = null;   // { id, numeric, max, text }
let box = null;      // the off-screen text box the keys go into

const len = (t) => [...t].length;

function clean(t) {
    let s = String(t == null ? '' : t);
    if (typing.numeric) s = s.replace(/\D/g, '').replace(/^0+(\d)/, '$1');
    else s = s.replace(/[\r\n\t]+/g, ' ');
    if (typing.max && len(s) > typing.max) s = [...s].slice(0, typing.max).join('');
    return s;
}

function send(extra) {
    if (!typing) return;
    nuiCallback('promptTyping', Object.assign({ id: typing.id, text: typing.text }, extra || {}));
}

/** The box, made once: off screen and see-through, but a real field (it takes a paste, a layout, an accent). */
function field() {
    if (box) return box;
    box = document.createElement('input');
    box.type = 'text';
    box.autocomplete = 'off';
    box.spellcheck = false;
    box.setAttribute('aria-hidden', 'true');
    box.tabIndex = -1;
    box.style.cssText = 'position:fixed;left:-10000px;top:0;width:200px;height:20px;opacity:0;pointer-events:none';
    box.addEventListener('input', () => {
        if (!typing) return;
        const next = clean(box.value);
        if (next !== box.value) box.value = next;
        if (next === typing.text) return;
        typing.text = next;
        send();
    });
    // Anything else taking the page's focus while typing gives it back to the box.
    box.addEventListener('blur', () => { if (typing) setTimeout(() => { if (typing) box.focus(); }, 0); });
    document.body.appendChild(box);
    return box;
}

/** Done or cancel: Lua is told once, with the text as it is. */
function end(extra) {
    if (!typing) return;
    const id = typing.id;
    const text = typing.text;
    typing = null;
    if (box) { box.value = ''; box.blur(); }
    nuiCallback('promptTyping', Object.assign({ id, text }, extra));
}

NuiRouter.register('promptTypingOpen', (d) => {
    if (!d) return;
    typing = { id: d.id, numeric: d.numeric === true, max: Number(d.max) > 0 ? Number(d.max) : 0, text: '' };
    typing.text = clean(d.text || '');
    const f = field();
    f.value = typing.text;
    f.focus();
    f.setSelectionRange(f.value.length, f.value.length);
});

NuiRouter.register('promptTypingSet', (d) => {
    if (!typing || !d || d.id !== typing.id) return;
    typing.text = clean(d.text || '');
    if (box) box.value = typing.text;
});

NuiRouter.register('promptTypingClose', () => {
    typing = null;
    if (box) { box.value = ''; box.blur(); }
});

// Enter, Esc and Backspace on nothing are the typing's; every other key goes on into the box.
NuiRouter.registerKeyScope({
    name: 'prompt-typing',
    priority: 0.45,
    isOpen: () => typing !== null,
    onKey: (e) => {
        if (!typing) return;
        if (e.key === 'Escape') { e.preventDefault(); end({ cancel: true }); }
        else if (e.key === 'Enter') { e.preventDefault(); end({ done: true }); }
        else if (e.key === 'Backspace' && !typing.text) { e.preventDefault(); end({ cancel: true }); }
        else if (document.activeElement !== box) field().focus();
    },
});
