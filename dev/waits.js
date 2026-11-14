// Which whip_core exports can wait (yield the caller)? A static scan of whip_core's Lua.
//
//   node dev/waits.js              the lists, server and client
//   node dev/waits.js --check      do types/server.lua, types/client.lua (---@async), docs.html (WAITS) and
//                                  lib/satellite.lua (WAITS) say the same?
//   node dev/waits.js --write      rewrite the WAITS lists in docs.html and lib/satellite.lua from the scan (the
//                                  stubs' ---@async marks stay by hand: --check names any that differ)
//   node dev/waits.js --why server:export:AddItem      the chain that makes one wait
//
// Run from whip_core. A function waits if its own body calls Wait, Citizen.Await, Await, a MySQL *.await or
// coroutine.yield, or calls a function that waits; a function handed to pcall/xpcall runs in line and counts, one
// handed to CreateThread, SetTimeout or a handler does not (the caller does not wait for it). A wait in one branch
// only (a container not yet in memory) still counts: "can wait". Approximate: a call made through a table of
// functions or a method on an object is not followed, so a new export that waits that way needs its mark by hand,
// and --check says so only for what it can see.
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const checkMode = process.argv.includes('--check');
const writeMode = process.argv.includes('--write');
const whyName = process.argv.indexOf('--why') > 0 ? process.argv[process.argv.indexOf('--why') + 1] : null;

function files(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...files(p));
    else if (e.name.endsWith('.lua')) out.push(p);
  }
  return out;
}

// Strip comments and string contents, keep structure.
function strip(src) {
  let out = '', i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '-' && src[i + 1] === '-') {
      const m = src.slice(i + 2).match(/^\[(=*)\[/);
      if (m) { const close = ']' + m[1] + ']'; const j = src.indexOf(close, i + 2 + m[0].length); i = j < 0 ? n : j + close.length; continue; }
      const j = src.indexOf('\n', i); i = j < 0 ? n : j; continue;
    }
    if (c === '[') {
      const m = src.slice(i).match(/^\[(=*)\[/);
      if (m) { const close = ']' + m[1] + ']'; const j = src.indexOf(close, i + m[0].length); out += '""'; i = j < 0 ? n : j + close.length; continue; }
    }
    if (c === '"' || c === "'" || c === '`') {
      let j = i + 1; let s = '';
      while (j < n && src[j] !== c) { if (src[j] === '\\') { s += src[j + 1]; j += 2; continue; } if (src[j] === '\n') break; s += src[j]; j++; }
      // keep short identifier-like strings (export names) readable
      out += c === '`' ? '0' : JSON.stringify(/^[A-Za-z_][\w]*$/.test(s) ? s : '');
      i = j + 1; continue;
    }
    out += c; i++;
  }
  return out;
}

function tokenize(s) {
  const toks = [];
  const re = /([A-Za-z_][\w]*)|("(?:[^"\\]|\\.)*")|(\.\.\.|\.\.|==|~=|<=|>=|::|[^\s\w])/g;
  let m;
  while ((m = re.exec(s))) toks.push(m[0]);
  return toks;
}

const YIELDS = new Set(['Wait', 'Await']);
const THREADERS = new Set(['CreateThread', 'SetTimeout', 'CreateThreadNow', 'AddEventHandler', 'RegisterNetEvent',
  'RegisterCommand', 'RegisterNUICallback', 'AddStateBagChangeHandler', 'SetInterval', 'onNet', 'on']);
const INLINE = new Set(['pcall', 'xpcall']);

const funcs = new Map();   // key -> { key, file, calls:Set, yields:bool, isExport, exportName }
const exportsOf = { server: new Map(), client: new Map(), shared: new Map() };

function sideOf(f) {
  const rel = path.relative(root, f).replace(/\\/g, '/');
  if (rel.startsWith('server/')) return 'server';
  if (rel.startsWith('client/')) return 'client';
  return 'shared';
}

let anon = 0;
for (const f of files(root)) {
  const rel = path.relative(root, f).replace(/\\/g, '/');
  if (/^(dev|tools|types|html|docs|lib)\//.test(rel)) continue;
  const toks = tokenize(strip(fs.readFileSync(f, 'utf8')));
  const side = sideOf(f);
  // Walk with a stack of blocks; each function block collects calls/yields.
  const stack = [];           // { kind:'fn'|'blk', fn? }
  const fnStack = [];         // current function records (innermost last)
  let skipDo = 0;
  const top = { key: rel + '#top', file: rel, calls: new Set(), yields: false };
  funcs.set(top.key, top);
  const cur = () => fnStack.length ? fnStack[fnStack.length - 1] : top;
  // parenthesis tracking to know the callee of a function literal argument
  const parens = [];          // callee name for each open '('
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t === '(') {
      // callee: previous tokens forming a dotted name
      let j = i - 1, name = '';
      if (j >= 0 && /^[A-Za-z_]/.test(toks[j])) {
        name = toks[j];
        while (j - 2 >= 0 && (toks[j - 1] === '.' || toks[j - 1] === ':') && /^[A-Za-z_]/.test(toks[j - 2])) { name = toks[j - 2] + toks[j - 1] + name; j -= 2; }
      }
      parens.push(name);
      if (name) {
        const last = name.split(/[.:]/).pop();
        const c = cur();
        if (YIELDS.has(last) || name === 'coroutine.yield' || /\.await$/.test(name) || name === 'Citizen.Wait') c.yields = true;
        c.calls.add(name);
        // pcall(Some.fn, ...): Some.fn runs in line, so it is called here
        if (INLINE.has(name) && /^[A-Za-z_]/.test(toks[i + 1] || '') && toks[i + 1] !== 'function') {
          let j = i + 1, ref = toks[j];
          while ((toks[j + 1] === '.' || toks[j + 1] === ':') && /^[A-Za-z_]/.test(toks[j + 2] || '')) { ref += toks[j + 1] + toks[j + 2]; j += 2; }
          if (toks[j + 1] === ',' || toks[j + 1] === ')') c.calls.add(ref);
        }
      }
      continue;
    }
    if (t === ')') { parens.pop(); continue; }
    // A yield handed on by reference: pcall(MySQL[kind].await, ...), pcall(Citizen.Await, p)
    if ((t === 'await' || t === 'Await') && toks[i - 1] === '.') { cur().yields = true; continue; }
    if (t === 'function') {
      // named?   function A.b:c(   |  local function x(   |  x = function(   | exports("X", function(
      let key = null, isExport = false, exportName = null, inline = false, threaded = false;
      if (/^[A-Za-z_]/.test(toks[i + 1] || '')) {
        let j = i + 1, name = toks[j];
        while ((toks[j + 1] === '.' || toks[j + 1] === ':') && /^[A-Za-z_]/.test(toks[j + 2] || '')) { name += '.' + toks[j + 2]; j += 2; }
        key = (toks[i - 1] === 'local' ? rel + '#' : '') + name;
      } else if (toks[i - 1] === '=' && /^[A-Za-z_\]]/.test(toks[i - 2] || '')) {
        let j = i - 2, name = toks[j];
        while (j - 2 >= 0 && (toks[j - 1] === '.') && /^[A-Za-z_]/.test(toks[j - 2])) { name = toks[j - 2] + '.' + name; j -= 2; }
        key = (toks[j - 1] === 'local' ? rel + '#' : '') + name;
        // a field inside a table constructor (onSelect = function): treat as anonymous unless a dotted/global name
        if (toks[j - 1] === '{' || toks[j - 1] === ',') key = null;
      }
      const callee = parens.length ? parens[parens.length - 1] : '';
      if (!key) {
        if (callee === 'exports' && /^"/.test(toks[i - 2] || '')) { isExport = true; exportName = JSON.parse(toks[i - 2]); key = side + ':export:' + exportName; }
        else if (INLINE.has(callee)) inline = true;
        else key = rel + '#anon' + (anon++);
      }
      const rec = inline ? cur() : { key, file: rel, calls: new Set(), yields: false };
      if (!inline) {
        if (funcs.has(key) && !isExport) {
          // same name defined twice (sides, or redefinition): merge
          const prev = funcs.get(key); stack.push({ kind: 'fn', fn: prev }); fnStack.push(prev);
        } else { funcs.set(key, rec); stack.push({ kind: 'fn', fn: rec }); fnStack.push(rec); }
        if (isExport) exportsOf[side].set(exportName, key);
      } else {
        stack.push({ kind: 'blk' });
      }
      continue;
    }
    if (t === 'while' || t === 'for') { stack.push({ kind: 'blk' }); skipDo++; continue; }
    if (t === 'do') { if (skipDo > 0) { skipDo--; } else stack.push({ kind: 'blk' }); continue; }
    if (t === 'if') { stack.push({ kind: 'blk' }); continue; }
    if (t === 'repeat') { stack.push({ kind: 'rep' }); continue; }
    if (t === 'until') { stack.pop(); continue; }
    if (t === 'end') {
      const b = stack.pop();
      if (b && b.kind === 'fn') fnStack.pop();
      continue;
    }
  }
  // exports('Name', Fn)  -- by reference
  for (let i = 0; i + 4 < toks.length; i++) {
    if (toks[i] === 'exports' && toks[i + 1] === '(' && /^"/.test(toks[i + 2]) && toks[i + 3] === ',' && /^[A-Za-z_]/.test(toks[i + 4]) && toks[i + 4] !== 'function') {
      let j = i + 4, name = toks[j];
      while (toks[j + 1] === '.' && /^[A-Za-z_]/.test(toks[j + 2] || '')) { name += '.' + toks[j + 2]; j += 2; }
      const ename = JSON.parse(toks[i + 2]);
      const key = side + ':export:' + ename;
      if (!funcs.has(key)) funcs.set(key, { key, file: rel, calls: new Set([name, rel + '#' + name]), yields: false });
      exportsOf[side].set(ename, key);
    }
  }
}

// Resolve a call name to function records: exact global key, file-local key, or by last segment for Module.fn.
const byName = new Map();
for (const r of funcs.values()) {
  const short = r.key.includes('#') ? r.key.split('#')[1] : r.key;
  if (!byName.has(short)) byName.set(short, []);
  byName.get(short).push(r);
}
function resolve(fromFile, name) {
  const n = name.replace(/:/g, '.');
  const local = funcs.get(fromFile + '#' + n);
  if (local) return [local];
  const g = funcs.get(n);
  if (g) return [g];
  return [];
}

// fixed point
const why = new Map();
let changed = true;
for (const r of funcs.values()) if (r.yields) why.set(r.key, 'yields itself');
while (changed) {
  changed = false;
  for (const r of funcs.values()) {
    if (why.has(r.key)) continue;
    for (const c of r.calls) {
      for (const t of resolve(r.file, c)) {
        if (why.has(t.key)) { why.set(r.key, 'calls ' + t.key); changed = true; break; }
      }
      if (why.has(r.key)) break;
    }
  }
}

if (whyName) {
  let k = whyName; const seen = new Set();
  while (k && !seen.has(k)) { seen.add(k); console.log(k, '->', why.get(k)); const w = why.get(k); k = w && w.startsWith('calls ') ? w.slice(6) : null; }
  process.exit(0);
}
const out = {};
for (const side of ['server', 'client', 'shared']) {
  const all = [...exportsOf[side].entries()];
  const waiting = all.filter(([, k]) => why.has(k)).map(([n]) => n).sort();
  // A __ name is internal: not stubbed or documented, so only lib/satellite.lua's list holds it (its helpers call
  // these through Whip.call). The __Test* seams (server/testseams.lua) are left out of every list.
  out[side] = {
    total: all.length,
    waits: waiting.filter((n) => !n.startsWith('__')),
    internal: waiting.filter((n) => n.startsWith('__') && !n.startsWith('__Test')),
  };
}

// The stubs' ---@async marks, by side. They are kept by hand, so they also hold a wait the scan cannot follow.
const asyncMarks = {};
for (const side of ['server', 'client']) {
  const stub = fs.readFileSync(path.join(root, 'types', side + '.lua'), 'utf8');
  asyncMarks[side] = [...stub.matchAll(/---@async\r?\nfunction whip_core:(\w+)\(/g)].map((m) => m[1]);
}

// --write: the two WAITS lists, one line of JSON each: what the scan finds, plus what a stub marks ---@async that the
// scan cannot follow (GetScenarioStats), while it is still an export on that side; lib/satellite.lua's also holds the
// internal __ exports that wait. Only the lists change, so a second run writes nothing.
if (writeMode) {
  const publicLists = {}, satLists = {};
  for (const side of ['server', 'client']) {
    const names = new Set(out[side].waits);
    for (const n of asyncMarks[side]) if (exportsOf[side].has(n) || exportsOf.shared.has(n)) names.add(n);
    publicLists[side] = [...names].sort();
    satLists[side] = [...names, ...out[side].internal].sort();
  }
  const targets = [
    { file: 'docs.html', lists: publicLists, re: /(var WAITS = )\{[\s\S]*?\}(;)/, what: '`var WAITS = {...};`' },
    { file: 'lib/satellite.lua', lists: satLists, re: /(local WAITS = json\.decode\(\[\[)\{[\s\S]*?\}(\]\]\))/, what: '`local WAITS = json.decode([[{...}]])`' },
  ];
  let failed = false;
  for (const t of targets) {
    const file = path.join(root, t.file);
    const src = fs.readFileSync(file, 'utf8');
    if (!t.re.test(src)) { failed = true; console.log(`${t.file}: no ${t.what} list to write`); continue; }
    const next = src.replace(t.re, (_, open, close) => open + JSON.stringify(t.lists) + close);
    if (next === src) { console.log(`${t.file}: unchanged`); continue; }
    fs.writeFileSync(file, next);
    console.log(`${t.file}: written (${t.lists.server.length} server, ${t.lists.client.length} client)`);
  }
  process.exit(failed ? 1 : 0);
}

if (!checkMode) {
  for (const side of ['server', 'client']) {
    console.log(`${side}: ${out[side].waits.length} of ${out[side].total} exports can wait`);
    console.log('  ' + out[side].waits.join(' '));
  }
  process.exit(0);
}

// --check: the stubs' ---@async marks and the docs' WAITS list against the scan.
let bad = 0;
function compare(what, scanned, marked) {
  const s = new Set(scanned), m = new Set(marked);
  const missing = scanned.filter((n) => !m.has(n));
  const extra = marked.filter((n) => !s.has(n));
  if (missing.length) { bad++; console.log(`${what}: not marked, but can wait: ${missing.join(' ')}`); }
  if (extra.length) { bad++; console.log(`${what}: marked, but the scan finds no wait (check by hand; keep it if it is a call the scan cannot follow): ${extra.join(' ')}`); }
}
for (const side of ['server', 'client']) compare(`types/${side}.lua`, out[side].waits, asyncMarks[side]);
const docs = fs.readFileSync(path.join(root, 'docs.html'), 'utf8');
const listed = docs.match(/var WAITS = (\{[\s\S]*?\});/);
if (!listed) { bad++; console.log('docs.html: no `var WAITS = {...};` list'); }
else {
  const w = JSON.parse(listed[1]);
  for (const side of ['server', 'client']) compare(`docs.html WAITS.${side}`, out[side].waits, w[side] || []);
}
// lib/satellite.lua's own copy: Whip.call gives only these a thread and a promise.
const sat = fs.readFileSync(path.join(root, 'lib', 'satellite.lua'), 'utf8');
const satListed = sat.match(/local WAITS = json\.decode\(\[\[(\{[\s\S]*?\})\]\]\)/);
if (!satListed) { bad++; console.log('lib/satellite.lua: no `local WAITS = json.decode([[{...}]])` list'); }
else {
  const w = JSON.parse(satListed[1]);
  for (const side of ['server', 'client']) {
    compare(`lib/satellite.lua WAITS.${side}`, [...out[side].waits, ...out[side].internal], w[side] || []);
  }
}
console.log(bad ? `${bad} difference(s)` : `OK — ${out.server.waits.length} server and ${out.client.waits.length} client exports that can wait, marked in the stubs, the docs and lib/satellite.lua`);
process.exit(bad ? 1 : 0);
