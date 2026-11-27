/* ========================================
   THE DEBUG PANEL

   One pane at the top right that every /w debug tool draws into: Player Stats Debug, Vehicle Stats
   Debug, Ground Items Debug. Each is a SECTION; turn two on and the pane holds both, one under the
   other, growing to fit rather than two overlays landing on each other. No section open, no pane.

   The house look (DESIGN.md): solid night glass with the corner glow, the title in the display face.
   It takes no focus and no clicks, like the /w menu.

   THE CORNER IS SHARED. Notifications and a job's objective cards live at the top right too, so the
   pane says how tall it is (--dbg-h, screen pixels, on <html>) and they move down under it (ui.css).

     import { DebugPanel } from './debug-panel.js';
     const sec = DebugPanel.section('player', { title: 'Player stats', order: 1 });
     sec.show(); sec.setMeta('John Framework'); sec.body.innerHTML = '…'; sec.hide();
   ======================================== */

const root = document.createElement('div');
root.id = 'debug-panel';
root.innerHTML = '<div class="dbg-title">Debug</div><div class="dbg-sections"></div>';
document.body.appendChild(root);
const sectionsEl = root.querySelector('.dbg-sections');

const _sections = new Map();   // id -> section

/** The pane is up while any section is; its height goes to --dbg-h for the corner's other tenants. */
function refresh() {
    let any = false;
    for (const s of _sections.values()) if (s.visible) { any = true; break; }
    root.classList.toggle('visible', any);
    if (!any) {
        document.documentElement.style.setProperty('--dbg-h', '0px');
        _lastH = -1;   // so coming back at the same height is measured again
    }
}

/* Measured in SCREEN pixels (the pane has its own zoom), and only when its size changes — a stats
   section redraws several times a second without moving a pixel. The 10px is the gap under it. */
let _lastH = -1;
new ResizeObserver(() => {
    if (!root.classList.contains('visible')) return;
    const h = Math.round(root.getBoundingClientRect().height);
    if (h === _lastH) return;
    _lastH = h;
    document.documentElement.style.setProperty('--dbg-h', (h > 0 ? h + 10 : 0) + 'px');
}).observe(root);

export const DebugPanel = {
    /**
     * A section of the pane, made the first time it is asked for. `order` places it (lower first).
     * @returns {{ el: HTMLElement, body: HTMLElement, visible: boolean, show(): void, hide(): void, setMeta(t: string): void }}
     */
    section(id, opts = {}) {
        let s = _sections.get(id);
        if (s) return s;

        const el = document.createElement('section');
        el.className = 'dbg-section';
        el.dataset.id = id;
        const order = opts.order || 0;
        el.dataset.order = String(order);

        const head = document.createElement('div');
        head.className = 'dbg-head';
        const name = document.createElement('div');
        name.className = 'dbg-name';
        name.textContent = opts.title || id;
        const meta = document.createElement('div');
        meta.className = 'dbg-meta';
        head.append(name, meta);

        const body = document.createElement('div');
        body.className = 'dbg-body';
        el.append(head, body);
        // IN ORDER IN THE DOCUMENT, not by CSS `order`: the hairline between sections is a sibling
        // selector, which reads document order.
        const after = [...sectionsEl.children].find((c) => Number(c.dataset.order) > order);
        sectionsEl.insertBefore(el, after || null);

        s = {
            el, body, visible: false,
            show() {
                if (s.visible) return;
                s.visible = true;
                el.classList.add('visible');
                refresh();
            },
            hide() {
                if (!s.visible) return;
                s.visible = false;
                el.classList.remove('visible');
                body.innerHTML = '';
                meta.textContent = '';
                refresh();
            },
            setMeta(text) {
                const t = text || '';
                if (meta.textContent !== t) meta.textContent = t;
            },
        };
        _sections.set(id, s);
        return s;
    },
};

/* ---- Shared pieces the sections build with (css/debug-panel.css) ---- */

/** A number for a column: fixed places, so it does not change width as it counts. */
export function num(v, dp = 1) {
    return typeof v === 'number' && isFinite(v) ? v.toFixed(dp) : '—';
}

/** "4s", "2m 05s", "1h 12m", "2d 3h": how long ago, or how long left. */
export function dur(seconds) {
    if (typeof seconds !== 'number' || !isFinite(seconds)) return '—';
    const s = Math.max(0, Math.round(seconds));
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60), r = s % 60;
    if (m < 60) return m + 'm ' + String(r).padStart(2, '0') + 's';
    const h = Math.floor(m / 60);
    if (h < 24) return h + 'h ' + String(m % 60).padStart(2, '0') + 'm';
    return Math.floor(h / 24) + 'd ' + (h % 24) + 'h';
}

/** A caption over a group of rows ("Effects · 2"). */
export function caption(text) {
    const c = document.createElement('div');
    c.className = 'dbg-caption';
    c.textContent = text;
    return c;
}

/** The dim line a section shows when it has nothing to say. */
export function empty(text) {
    const e = document.createElement('div');
    e.className = 'dbg-empty';
    e.textContent = text;
    return e;
}

/** A small reading beside a value ("ped 198"). `tone`: '', 'warn', 'up', 'down'. */
export function chip(text, tone) {
    const c = document.createElement('span');
    c.className = 'dbg-chip' + (tone ? ' is-' + tone : '');
    c.textContent = text;
    return c;
}

/**
 * A stat row: the name (and a colour dot), a bar, the value; `extra` nodes sit on a second line.
 * @param {{ name: string, color?: string, pct: number, value: string, dim?: boolean, extra?: Node[] }} r
 */
export function statRow(r) {
    const row = document.createElement('div');
    row.className = 'dbg-stat' + (r.dim ? ' is-dim' : '');
    if (r.color) row.style.setProperty('--dbg-c', r.color);

    const name = document.createElement('div');
    name.className = 'dbg-stat-name';
    name.textContent = r.name;

    const bar = document.createElement('div');
    bar.className = 'dbg-bar';
    const fill = document.createElement('div');
    fill.className = 'dbg-fill';
    fill.style.width = Math.max(0, Math.min(100, r.pct || 0)) + '%';
    bar.appendChild(fill);

    const val = document.createElement('div');
    val.className = 'dbg-stat-val';
    val.textContent = r.value;

    row.append(name, bar, val);
    if (r.extra && r.extra.length) {
        const ex = document.createElement('div');
        ex.className = 'dbg-stat-extra';
        ex.append(...r.extra);
        row.appendChild(ex);
    }
    return row;
}

/** A change: the amount (green up, red down), what moved, why, and how long ago. */
export function changeRow(c) {
    const row = document.createElement('div');
    row.className = 'dbg-change';
    const d = document.createElement('span');
    const up = typeof c.delta === 'number' && c.delta > 0, down = typeof c.delta === 'number' && c.delta < 0;
    d.className = 'dbg-change-d' + (c.cleared ? ' is-cleared' : up ? ' is-up' : down ? ' is-down' : '');
    d.textContent = c.cleared ? 'removed' : (typeof c.delta === 'number' ? (up ? '+' : '') + c.delta.toFixed(c.dp ?? 1) : '');
    const what = document.createElement('span');
    what.className = 'dbg-change-what';
    what.textContent = c.stat || '';
    const src = document.createElement('span');
    src.className = 'dbg-change-src';
    src.textContent = c.source || '';
    const ago = document.createElement('span');
    ago.className = 'dbg-change-ago';
    ago.textContent = num(c.ago, 1) + 's';
    row.append(d, what, src, ago);
    return row;
}

/** A name and its readings on one line, for things that are not an amount (an effect, a data key). */
export function lineRow(name, extras) {
    const row = document.createElement('div');
    row.className = 'dbg-line';
    const n = document.createElement('span');
    n.className = 'dbg-line-name';
    n.textContent = name;
    row.appendChild(n);
    if (extras && extras.length) row.append(...extras);
    return row;
}

/** A key and its value, for facts that are not a stat ("Dropped by", "Lying here"). */
export function kvRow(key, value) {
    const row = document.createElement('div');
    row.className = 'dbg-kv';
    const k = document.createElement('span');
    k.className = 'dbg-kv-k';
    k.textContent = key;
    const v = document.createElement('span');
    v.className = 'dbg-kv-v';
    v.textContent = value;
    row.append(k, v);
    return row;
}
