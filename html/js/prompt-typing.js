// ========================================
// TYPING INTO A PROMPT — the keyboard's half (client/prompt_typing.lua)
//
// While a value is typed into a 3D prompt on a keyboard, whip's page holds the keys (NUI focus, no cursor; the game
// keeps its input, so the mouse still looks round) and this takes them: nothing is drawn here, the capsule in the
// world is a DUI that Lua paints. Each change of the text goes to Lua, then Enter (done) or Esc (cancel); Backspace
// on nothing is a cancel too. A number takes digits only, without a leading zero; nothing goes past `max`.
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

const len = (t) => [...t].length;

function clean(t) {
    let s = String(t == null ? '' : t);
    if (typing.numeric) s = s.replace(/\D/g, '').replace(/^0+(\d)/, '$1');
    if (typing.max && len(s) > typing.max) s = [...s].slice(0, typing.max).join('');
    return s;
}

function send(extra) {
    if (!typing) return;
    nuiCallback('promptTyping', Object.assign({ id: typing.id, text: typing.text }, extra || {}));
}

function set(t) {
    const next = clean(t);
    if (next === typing.text) return;
    typing.text = next;
    send();
}

NuiRouter.register('promptTypingOpen', (d) => {
    if (!d) return;
    typing = { id: d.id, numeric: d.numeric === true, max: Number(d.max) > 0 ? Number(d.max) : 0, text: '' };
    typing.text = clean(d.text || '');
});

NuiRouter.register('promptTypingSet', (d) => {
    if (typing && d && d.id === typing.id) typing.text = clean(d.text || '');
});

NuiRouter.register('promptTypingClose', () => { typing = null; });

NuiRouter.registerKeyScope({
    name: 'prompt-typing',
    priority: 0.45,
    isOpen: () => typing !== null,
    onKey: (e) => {
        if (!typing) return;
        if (e.key === 'Escape') { e.preventDefault(); const id = typing.id; typing = null; nuiCallback('promptTyping', { id, cancel: true }); }
        else if (e.key === 'Enter') { e.preventDefault(); send({ done: true }); typing = null; }
        else if (e.key === 'Backspace') {
            e.preventDefault();
            if (!typing.text) { const id = typing.id; typing = null; nuiCallback('promptTyping', { id, cancel: true }); return; }
            set([...typing.text].slice(0, -1).join(''));
        }
        else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
            e.preventDefault();
            if (typing.numeric && (e.key === '0' && typing.text === '')) return;
            set(typing.text + e.key);
        }
    },
});
