// ========================================
// KEYBOARD WORDS — the pad keyboard's languages and word suggestions
//
// LANGUAGE PACKS. A language is html/keyboard/<code>.json (its name, its three rows of letters, its accents)
// and <code>.txt (its words, most common first). English comes with whip; a server offers more in
// Config.Keyboard.Languages (html/keyboard/README.md says how). The one a player types in: their own choice
// (Settings → Server → Controller → Keyboard language, or the keyboard's language key), else the language GTA is set to when
// the server offers it, else the server's default. client/keyboard.lua tells this page the list.
//
// SUGGESTIONS for the word being typed, up to three: the player's own words first (learned, below), then the
// language's in order. Matched without accents, apostrophes or case, so "cafe" offers "café" and "im" offers
// "I'm"; shown in the case being typed (and capitalised at the start of a sentence). The name of a / command
// offers the commands the keyboard's opener passed (chat's own list).
//
// LEARNED on this PC (localStorage), when a keyboard is Done: each word counted, and a word used twice is
// offered from then on, before the language's own. A name (capitalised, or in capitals, and not a word of the
// language) is kept as typed, for every language. At most MAX_LEARNED a list: the least used go.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { pref } from './prefs.js';

const SUGGEST = 3;           // suggestions at most
const LEARNED_FROM = 2;      // a learned word is offered once used this many times
const MAX_LEARNED = 3000;    // per list: the least used go past this
const MAX_WORD = 32;         // longer is not a word (a pasted link)
const LEARN_KEY = 'whip-pad-keyboard-learned';
const LOAD_AFTER_MS = 2000;  // the language in use is loaded this long after the page hears the list

/** The word being typed: letters, with apostrophes inside. */
const TAIL = /[\p{L}\p{M}'’]+$/u;
/** Words in a line, for learning. */
const WORDS = /[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*/gu;

/** What words are matched by: no accents, no apostrophes, no case. */
export function fold(s) {
    return String(s).normalize('NFD').replace(/\p{M}/gu, '').replace(/['’]/g, '').toLowerCase();
}

// ---- which language ----

let server = { list: ['en'], def: 'en', game: null };
// The language key's pick, until the setting it saved comes back from Lua (playerPrefs): then the setting is it.
let picked = null;   // { code, prefWas }

NuiRouter.register('padKeyboardLanguages', (d) => {
    if (!d) return;
    const ok = (c) => typeof c === 'string' && /^[a-z]{2,3}$/.test(c);
    const list = Array.isArray(d.list) ? d.list.filter(ok) : [];
    server = { list: list.length ? list : ['en'], def: ok(d.default) ? d.default : 'en', game: ok(d.game) ? d.game : null };
    // Ready before it is wanted: the language in use, loaded in the background.
    setTimeout(() => { loadPack(currentLanguage()); }, LOAD_AFTER_MS);
});

/** The languages this server offers. */
export function languages() { return server.list.slice(); }

/** The language the keyboard types in now. */
export function currentLanguage() {
    const list = server.list;
    const setting = pref('keyboard.language', 'auto');
    if (picked && setting === picked.prefWas && list.includes(picked.code)) return picked.code;
    picked = null;
    if (setting !== 'auto' && list.includes(setting)) return setting;
    if (server.game && list.includes(server.game)) return server.game;
    if (list.includes(server.def)) return server.def;
    return list[0] || 'en';
}

/** The language key: this one from now on, saved as the player's setting. */
export function setLanguage(code) {
    if (!server.list.includes(code)) return;
    picked = { code, prefWas: pref('keyboard.language', 'auto') };
    Promise.resolve(nuiCallback('prefsSet', { key: 'keyboard.language', value: code })).catch(() => {});
}

/** Are suggestions on (the player's setting)? */
export function predicting() { return pref('keyboard.predict', true) !== false; }

// ---- packs ----

const packs = {};   // [code] = { pack, promise }: pack is null until loaded, or for one that could not be

const urlOf = (code, ext) => new URL(`../keyboard/${code}.${ext}`, import.meta.url).href;

/** A pack's rows if they are three of 11, 11 and 9 single characters, none twice (nor a digit or -). */
function rowsOf(rows) {
    if (!Array.isArray(rows) || rows.length !== 3) return null;
    const want = [11, 11, 9];
    const seen = new Set(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-']);
    for (let r = 0; r < 3; r++) {
        if (!Array.isArray(rows[r]) || rows[r].length !== want[r]) return null;
        for (const k of rows[r]) {
            if (typeof k !== 'string' || [...k].length !== 1 || seen.has(k)) return null;
            seen.add(k);
        }
    }
    return rows.map((row) => row.slice());
}

function accentsFrom(a) {
    const out = {};
    if (!a || typeof a !== 'object') return out;
    for (const [base, forms] of Object.entries(a)) {
        if ([...base].length !== 1 || typeof forms !== 'string') continue;
        const list = [...forms.normalize('NFC')].filter((c) => c !== base).slice(0, 8);
        if (list.length) out[base] = list;
    }
    return out;
}

/** The pack, loading it the first time. Answers it, or null for one that is not there. */
export function loadPack(code) {
    if (typeof code !== 'string' || !/^[a-z]{2,3}$/.test(code)) return Promise.resolve(null);
    if (packs[code]) return packs[code].promise;
    const entry = { pack: null };
    const get = (ext, how) => fetch(urlOf(code, ext)).then((r) => (r.ok ? r[how]() : null)).catch(() => null);
    entry.promise = Promise.all([get('json', 'json'), get('txt', 'text')]).then(([meta, txt]) => {
        if (!meta && !txt) {
            console.warn(`[keyboard] no ${code} language pack in html/keyboard/`);
            return null;
        }
        const rows = meta ? rowsOf(meta.rows) : null;
        if (meta && meta.rows && !rows) console.warn(`[keyboard] ${code}.json: rows must be 11, 11 and 9 single letters, none twice; English's used`);
        const words = [], keys = [], index = new Map();
        for (const line of String(txt || '').split(/\r?\n/)) {
            const w = line.trim();
            if (!w || w[0] === '#' || w.length > MAX_WORD) continue;
            const k = fold(w);
            if (!k) continue;
            if (!index.has(k)) index.set(k, words.length);
            words.push(w.normalize('NFC'));
            keys.push(k);
        }
        return {
            code, name: meta && typeof meta.name === 'string' ? meta.name.slice(0, 40) : code.toUpperCase(),
            rows, accents: accentsFrom(meta && meta.accents), words, keys, index,
        };
    }).catch(() => null).then((p) => { entry.pack = p; return p; });
    packs[code] = entry;
    return entry.promise;
}

/** The pack if it is loaded, else null (loadPack it). */
export function packNow(code) {
    return (packs[code] && packs[code].pack) || null;
}

/** The other forms of a letter in this language (accents), or an empty list. */
export function accentsOf(code, ch) {
    const p = packNow(code);
    return (p && p.accents[ch]) || [];
}

// ---- learned words ----

let learned = null;   // { v: 1, langs: { [code]: { [key]: [word, uses, day] } }, names: {...}, cmds: {...} }

function store() {
    if (learned) return learned;
    try {
        const s = JSON.parse(localStorage.getItem(LEARN_KEY) || 'null');
        if (s && s.v === 1 && s.langs && s.names && s.cmds) learned = s;
    } catch (_) { /* none kept, or not readable: start again */ }
    if (!learned) learned = { v: 1, langs: {}, names: {}, cmds: {} };
    return learned;
}

function save() {
    try { localStorage.setItem(LEARN_KEY, JSON.stringify(learned)); } catch (_) { /* not kept */ }
}

const today = () => Math.floor(Date.now() / 86400000);

function bump(list, key, word, day) {
    const e = list[key];
    if (e) { e[0] = word; e[1] = Math.min(e[1] + 1, 99999); e[2] = day; }
    else list[key] = [word, 1, day];
}

/** Past MAX_LEARNED, the least used (and of those the longest unused) go, down to nine tenths of it. */
function prune(list) {
    const keys = Object.keys(list);
    if (keys.length <= MAX_LEARNED) return;
    keys.sort((a, b) => (list[a][1] - list[b][1]) || (list[a][2] - list[b][2]));
    for (const k of keys.slice(0, keys.length - Math.floor(MAX_LEARNED * 0.9))) delete list[k];
}

/** Count the words of a line that was sent (Done), in this language. */
export function learn(code, text) {
    if (typeof text !== 'string' || !text.trim()) return;
    const s = store();
    const p = packNow(code);
    const mine = s.langs[code] || (s.langs[code] = {});
    const day = today();
    let body = text;
    if (text[0] === '/') {
        const name = text.split(/\s/, 1)[0];
        if (name.length > 1 && name.length <= MAX_WORD) bump(s.cmds, name.toLowerCase(), name, day);
        body = text.slice(name.length);
    }
    for (const m of body.matchAll(WORDS)) {
        const w = m[0].normalize('NFC');
        if ([...w].length < 2 || w.length > MAX_WORD) continue;
        const k = fold(w);
        const known = p && p.index.has(k) ? p.words[p.index.get(k)] : null;
        if (known) bump(mine, k, known, day);                                       // the language's word, as it spells it
        else if (w[0] !== w[0].toLowerCase()) bump(s.names, k, w, day);             // a name, or capitals: as typed
        else bump(mine, k, w, day);                                                 // slang, as typed
    }
    prune(mine); prune(s.names); prune(s.cmds);
    save();
}

/** Forget every learned word (for tests, and a reset). */
export function forgetLearned() {
    learned = { v: 1, langs: {}, names: {}, cmds: {} };
    try { localStorage.removeItem(LEARN_KEY); } catch (_) { /* nothing kept */ }
}

// ---- suggesting ----

const isUpper = (c) => c !== c.toLowerCase();

/** `word` in the case being typed: capitals for capitals, a capital first for a capital first or a new sentence. */
function inCase(word, typed, sentence, asTyped) {
    if ([...typed].length >= 2 && typed === typed.toUpperCase() && isUpper(typed)) return word.toUpperCase();
    if (asTyped) return word;
    if (isUpper(typed[0]) || sentence) return word[0].toUpperCase() + word.slice(1);
    return word;
}

/** Up to three ways to finish the word at the end of `text`: [{ word, from }], the text from `from` on being
 *  what each replaces. `commands`: the names of / commands, for a line that starts with one. */
export function suggest(code, text, commands) {
    text = String(text || '');
    if (Array.isArray(commands) && commands.length && text[0] === '/' && !/\s/.test(text)) {
        const typed = text.toLowerCase();
        const used = store().cmds;
        const uses = (c) => (used[c.toLowerCase()] || [0, 0])[1];
        return commands
            .filter((c) => typeof c === 'string' && c.toLowerCase().startsWith(typed) && c !== text)
            .map((c, i) => ({ c, i }))
            .sort((a, b) => (uses(b.c) - uses(a.c)) || (a.i - b.i))   // most used first, else the opener's order
            .slice(0, SUGGEST).map(({ c }) => ({ word: c, from: 0 }));
    }
    const m = TAIL.exec(text);
    if (!m) return [];
    let typed = m[0], from = m.index;
    while (typed && (typed[0] === "'" || typed[0] === '’')) { typed = typed.slice(1); from++; }
    const key = fold(typed);
    if (!key) return [];
    const before = text.slice(0, from);
    const sentence = before.trim() === '' || /[.!?]\s+$/.test(before);
    const out = [], taken = new Set([typed]);
    const offer = (word, asTyped) => {
        const w = inCase(word, typed, sentence, asTyped);
        if (taken.has(w) || taken.has(w.toLowerCase())) return;
        taken.add(w); taken.add(w.toLowerCase());
        out.push({ word: w, from });
    };

    // The player's own first: most used, then most recent.
    const s = store();
    const mine = [];
    for (const list of [s.names, s.langs[code] || {}]) {
        const asTyped = list === s.names;
        for (const [k, e] of Object.entries(list)) {
            if (e[1] >= LEARNED_FROM && k.startsWith(key)) mine.push({ e, asTyped });
        }
    }
    mine.sort((a, b) => (b.e[1] - a.e[1]) || (b.e[2] - a.e[2]));
    for (const { e, asTyped } of mine) {
        if (out.length >= SUGGEST) break;
        offer(e[0], asTyped);
    }

    // Then the language's, most common first.
    const p = packNow(code);
    if (p) {
        for (let i = 0; i < p.keys.length && out.length < SUGGEST; i++) {
            if (p.keys[i].startsWith(key)) offer(p.words[i], false);
        }
    }
    return out;
}
