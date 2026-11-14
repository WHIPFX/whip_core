// ========================================
// SETTINGS — GTA's own settings, on the pause menu's page (client/game_settings.lua)
//
// The menu slides away as it does for Server Settings, whose look this page wears (css/prefs-page.css, its rows and
// controls; css/game-settings.css, the rest). A tab per tab GTA has, in GTA's order and words. On the left a row per
// setting: a slider, a list (its choices side by side when there are few, else stepped through with arrows), or
// something to do (Restore Defaults); on the right what the chosen row is set to.
//
// GTA OWNS THE VALUES. Every change goes to client/game_settings.lua, which makes it in GTA's own settings menu, under
// this page, and answers with the tab as GTA now has it; the page only draws what it is told. A change takes a moment
// (GTA's menu is pressed as a player would), so the row being changed says so, and the next change waits for it.
//
// GRAPHICS CHANGES WAIT FOR APPLY, as in GTA: a dot on each one not applied yet, and Apply changes in the head. GTA's
// own questions (keep these display settings?) come up over the page and are answered from it; leaving with changes not
// applied asks first. Key Bindings is GTA's own screen: its tab opens it.
//
// Keyboard, mouse and pad: up / down choose a row, left / right change it, Enter or A does a row that does something,
// Q / E or LB / RB the tabs, R or Y apply, Esc or B back to the menu. pause.js hands keys and the pad over in this mode.
// ========================================

import { nuiCallback, escapeHtml } from './utils.js';
import { padGlyph } from './pad-glyphs.js';
import { NuiRouter } from './router.js';
import { screenRect } from './pad-cursor.js';

/** A list with this few choices, short enough, shows them side by side; any other steps through them. */
const SIDE_BY_SIDE = { most: 4, chars: 34 };

const ARROW = (d) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${d < 0 ? 'M15 5l-7 7 7 7' : 'M9 5l7 7-7 7'}" `
    + 'fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const CHEVRON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" '
    + 'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/** The question asked before leaving with graphics changes not applied: the page's own, not GTA's. */
const LEAVE_QUESTION = {
    title: 'Apply graphics changes?',
    body: 'Some graphics changes are not applied yet. Leaving drops them.',
    buttons: ['Apply', 'Discard', 'Stay'],
    own: true,
};

/** Shown side by side: a list with few, short choices (GTA gave them all). */
function sideBySide(row) {
    const opts = row.options;
    return Array.isArray(opts) && opts.length > 1 && opts.length <= SIDE_BY_SIDE.most
        && opts.join('').length <= SIDE_BY_SIDE.chars;
}

/** A slider's value from where on its track (0-1). */
function sliderAt(row, frac) {
    return Math.max(0, Math.min(row.max, Math.round(Math.max(0, Math.min(1, frac)) * row.max)));
}

/** What a row is set to, in words. */
function valueWords(row) {
    if (row.kind === 'slider') return `${row.value} of ${row.max}`;
    if (row.kind === 'list') return row.text || '';
    return '';
}

export class GameSettingsPage {
    /** @param {HTMLElement} root  the pause menu's root; @param {() => void} onBack  back to its menu */
    constructor(root, onBack) {
        this.onBack = onBack;
        this.isOpen = false;
        this.tabs = [];             // GTA's tabs: { id, label, keys }
        this.tabId = null;          // the tab shown (kept for next time: the page opens on it)
        this.tab = null;            // its rows as GTA last answered: { id, label, graphics, rows }
        this.unapplied = false;     // graphics changes waiting for Apply, on either graphics tab
        this.sel = 0;               // the chosen row
        this.loading = false;       // a tab on its way
        this.failed = '';           // GTA's settings did not open: why
        this.note = '';             // a change refused: why
        this.working = null;        // the id of the row being changed, or 'apply'
        this.question = null;       // up over the page: GTA's question, or LEAVE_QUESTION
        this.questionSel = 0;
        this.drag = null;           // a slider being dragged: { row, track, value }
        this.seq = 0;               // each tab asked for: only the newest one's answer is drawn

        const wrap = document.createElement('section');
        wrap.className = 'pm-gs';
        wrap.innerHTML = `
            <header class="pl-head">
                <button class="pm-back pl-back" type="button"><span class="pm-back-arrow">&#8592;</span> Menu</button>
                <div class="pl-title">Settings</div>
                <nav class="pl-tabs gs-tabs"></nav>
                <div class="pl-side gs-side">
                    <span class="gs-status"></span>
                    <button class="pl-reset gs-apply" type="button">Apply changes</button>
                </div>
            </header>
            <div class="pf-body gs-body">
                <div class="pf-listwrap">
                    <div class="pf-scroll"><div class="pf-list"></div></div>
                    <button class="pf-more" type="button" tabindex="-1">More below ${CHEVRON}</button>
                </div>
                <aside class="pf-aside">
                    <div class="pf-help">
                        <div class="pf-help-name"></div>
                        <div class="gs-help-value"></div>
                        <div class="pf-help-text"></div>
                    </div>
                </aside>
            </div>
            <div class="gs-ask">
                <div class="gs-ask-card">
                    <div class="gs-ask-title"></div>
                    <p class="gs-ask-body"></p>
                    <div class="gs-ask-row"></div>
                </div>
            </div>`;
        root.appendChild(wrap);
        this.wrap = wrap;
        this.tabsEl = wrap.querySelector('.gs-tabs');
        this.bodyEl = wrap.querySelector('.gs-body');
        this.listWrap = wrap.querySelector('.pf-listwrap');
        this.scrollEl = wrap.querySelector('.pf-scroll');
        this.listEl = wrap.querySelector('.pf-list');
        this.helpName = wrap.querySelector('.pf-help-name');
        this.helpValue = wrap.querySelector('.gs-help-value');
        this.helpText = wrap.querySelector('.pf-help-text');
        this.statusEl = wrap.querySelector('.gs-status');
        this.applyBtn = wrap.querySelector('.gs-apply');
        this.askEl = wrap.querySelector('.gs-ask');
        this.askTitle = wrap.querySelector('.gs-ask-title');
        this.askBody = wrap.querySelector('.gs-ask-body');
        this.askRow = wrap.querySelector('.gs-ask-row');

        // ---- mouse ----
        wrap.querySelector('.pl-back').addEventListener('click', () => this.back());
        this.tabsEl.addEventListener('click', (e) => {
            const t = e.target.closest('.pl-tab');
            if (t && !this.question) this.setTab(Number(t.dataset.i));
        });
        this.applyBtn.addEventListener('click', () => this.apply());
        // MOUSEMOVE, NOT MOUSEOVER, as on Server Settings: every draw rebuilds the rows, and a fresh mouseover on the
        // new row under a still mouse would take the choice back from the keys and pad.
        this.bodyEl.addEventListener('mousemove', (e) => {
            const r = e.target.closest('.pf-row');
            if (!r || this.question || this.drag) return;
            const i = Number(r.dataset.i);
            if (i !== this.sel) { this.sel = i; this.draw(); }
        });
        this.bodyEl.addEventListener('click', (e) => {
            const r = e.target.closest('.pf-row');
            if (!r || this.question) return;
            this.sel = Number(r.dataset.i);
            const row = this.row();
            if (!row) return;
            const opt = e.target.closest('.pf-opt');
            const arrow = e.target.closest('.gs-arrow, .pf-step');
            if (opt) this.setTo(row, Number(opt.dataset.o));
            else if (arrow) this.step(Number(arrow.dataset.d));
            else if (row.kind === 'button' || row.kind === 'keys') this.press();
            else this.draw();
        });
        // A slider dragged: drawn as it moves, sent once when let go.
        this.bodyEl.addEventListener('pointerdown', (e) => {
            const track = e.target.closest('.pf-track');
            const r = e.target.closest('.pf-row');
            if (!track || !r || this.question) return;
            this.sel = Number(r.dataset.i);
            const row = this.row();
            if (!row || row.kind !== 'slider' || row.locked || this.working) return;
            e.preventDefault();
            this.drag = { row, track, value: row.value };
            track.setPointerCapture?.(e.pointerId);
            this.dragTo(e.clientX);
        });
        this.bodyEl.addEventListener('pointermove', (e) => { if (this.drag) this.dragTo(e.clientX); });
        const endDrag = () => {
            if (!this.drag) return;
            const { row, value } = this.drag;
            this.drag = null;
            if (value !== row.value) this.setTo(row, value); else this.draw();
        };
        this.bodyEl.addEventListener('pointerup', endDrag);
        this.bodyEl.addEventListener('pointercancel', endDrag);
        this.scrollEl.addEventListener('scroll', () => this.syncMore());
        wrap.querySelector('.pf-more').addEventListener('click', () => {
            this.scrollEl.scrollBy({ top: this.scrollEl.clientHeight * 0.8, behavior: 'smooth' });
        });
        this.askRow.addEventListener('click', (e) => {
            const b = e.target.closest('.pl-cbtn');
            if (b) this.answer(Number(b.dataset.c));
        });
        this.askRow.addEventListener('mousemove', (e) => {
            const b = e.target.closest('.pl-cbtn');
            if (b && Number(b.dataset.c) !== this.questionSel) { this.questionSel = Number(b.dataset.c); this.drawQuestion(); }
        });
        addEventListener('resize', () => { if (this.isOpen) this.syncMore(); });

        // GTA asking (or done asking: `refresh`, its answer may have changed the tab).
        NuiRouter.register('gameSettingsQuestion', (d) => {
            if (!this.isOpen) return;
            if (d && d.question) this.ask(d.question);
            else {
                if (this.question && !this.question.own) this.question = null;
                this.draw();
                if (d && d.refresh) this.reload();
            }
        });
    }

    // ---- open and close ----

    open() {
        this.isOpen = true;
        this.note = '';
        this.failed = '';
        this.question = null;
        this.loading = true;
        this.draw();
        const seq = ++this.seq;
        nuiCallback('gameSettingsOpen', { tab: this.tabId }).then((st) => {
            if (seq !== this.seq || !this.isOpen) return;
            this.loading = false;
            if (!st || st.error) {
                this.failed = (st && st.error) || 'no answer';
                this.draw();
                return;
            }
            this.setState(st);
        });
    }

    close() {
        if (!this.isOpen) return;
        this.isOpen = false;
        this.drag = null;
        this.working = null;
        this.question = null;
        this.wrap.classList.remove('gs-asking');
        nuiCallback('gameSettingsClose', {});
    }

    /** Lua's answer: the tab as GTA has it now (drawn when it is the one shown), whether graphics wait for Apply. */
    setState(st) {
        if (!st) return;
        if (Array.isArray(st.tabs)) this.tabs = st.tabs;
        if (typeof st.unapplied === 'boolean') this.unapplied = st.unapplied;
        if (st.error) this.note = 'Not changed: ' + st.error;
        const t = st.tab;
        if (t && Array.isArray(t.rows) && (this.tabId === null || t.id === this.tabId || !this.tabs.some((x) => x.id === this.tabId))) {
            const rowId = this.row()?.id;
            const sameTab = this.tab && this.tab.id === t.id;
            this.tab = t;
            this.tabId = t.id;
            const r = sameTab ? t.rows.findIndex((x) => x.id === rowId) : -1;
            this.sel = r >= 0 ? r : (sameTab ? Math.min(this.sel, Math.max(0, t.rows.length - 1)) : 0);
        }
        if (this.isOpen) this.draw();
    }

    /** The shown tab read again (GTA answered a question, which may have changed it). */
    reload() {
        const id = this.tabId;
        if (id === null || this.current()?.keys) return;
        const seq = ++this.seq;
        nuiCallback('gameSettingsTab', { tab: id }).then((st) => {
            if (seq === this.seq && this.isOpen) this.setState(st);
        });
    }

    current() { return this.tabs.find((t) => t.id === this.tabId) || null; }

    /** The shown tab's rows; Key Bindings has one, which opens GTA's screen. */
    rows() {
        if (this.current()?.keys) {
            return [{ id: 'keys', kind: 'keys', label: 'Open GTA\'s key bindings' }];
        }
        return this.tab && this.tab.id === this.tabId && !this.loading ? this.tab.rows : [];
    }

    row() { return this.rows()[this.sel] || null; }

    // ---- drawing ----

    draw() {
        // The tabs, LB and RB either side on a pad.
        this.tabsEl.textContent = '';
        const glyph = (g) => {
            const s = document.createElement('span');
            s.className = 'pl-tab-glyph';
            const img = padGlyph(g, 'pl-tab-img');
            if (img) s.appendChild(img);
            return s;
        };
        if (this.tabs.length > 1) this.tabsEl.appendChild(glyph('lb'));
        this.tabs.forEach((t, i) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'pl-tab' + (t.id === this.tabId ? ' on' : '');
            b.dataset.i = i;
            b.textContent = t.label;
            this.tabsEl.appendChild(b);
        });
        if (this.tabs.length > 1) this.tabsEl.appendChild(glyph('rb'));
        this.tabsEl.classList.toggle('hidden', this.tabs.length === 0);

        const rows = this.rows();
        if (this.sel >= rows.length) this.sel = Math.max(0, rows.length - 1);
        this.listEl.textContent = '';
        if (this.failed) {
            this.listEl.innerHTML = `<div class="pf-empty gs-failed">GTA's settings did not open: ${escapeHtml(this.failed)}`
                + '<span>Enter or A tries again</span></div>';
        } else if (this.loading) {
            this.listEl.innerHTML = '<div class="pf-empty gs-loading">Reading GTA\'s settings</div>';
        } else if (!rows.length) {
            this.listEl.innerHTML = '<div class="pf-empty">Nothing to set here.</div>';
        }
        rows.forEach((row, i) => this.listEl.appendChild(this.rowEl(row, i)));
        this.listEl.querySelector('.pf-row.on')?.scrollIntoView?.({ block: 'nearest' });

        const graphics = !!this.tab?.graphics && this.tab.id === this.tabId;
        this.applyBtn.classList.toggle('hidden', !(this.unapplied && graphics));
        this.applyBtn.disabled = !!this.working;
        this.statusEl.textContent = this.working === 'apply' ? 'Applying' : (this.working ? 'Changing' : '');
        this.drawHelp();
        this.drawQuestion();
        this.syncMore();
        if (this.isOpen) NuiRouter.hintsChanged();
    }

    rowEl(row, i) {
        const el = document.createElement('div');
        el.className = 'pf-row' + (i === this.sel && !this.question ? ' on' : '') + (row.changed ? ' changed' : '')
            + (row.locked ? ' locked' : '') + (this.working === row.id ? ' gs-working' : '');
        el.dataset.i = i;
        el.dataset.type = row.kind;
        const name = `<div class="pf-name"><span class="pf-label">${escapeHtml(row.label)}</span>`
            + '<span class="pf-dot" aria-label="not applied yet"></span>'
            + (row.locked ? '<span class="pf-locked">Not available</span>' : '') + '</div>';
        let ctl = '';
        if (row.kind === 'slider') {
            const v = this.drag && this.drag.row.id === row.id ? this.drag.value : row.value;
            const pct = Math.max(0, Math.min(1, v / row.max)) * 100;
            ctl = '<button class="pf-step" type="button" data-d="-1" aria-label="less">&#8722;</button>'
                + `<div class="pf-track"><div class="pf-fill" style="width:${pct}%"></div><div class="pf-thumb" style="left:${pct}%"></div></div>`
                + '<button class="pf-step" type="button" data-d="1" aria-label="more">+</button>'
                + `<span class="pf-val pf-num">${v}</span>`;
        } else if (row.kind === 'list' && sideBySide(row)) {
            ctl = '<div class="pf-seg">' + row.options.map((o, k) =>
                `<button class="pf-opt${k === row.value ? ' cur' : ''}" type="button" data-o="${k}">${escapeHtml(o)}</button>`
            ).join('') + '</div>';
        } else if (row.kind === 'list') {
            ctl = `<div class="gs-stepper"><button class="gs-arrow" type="button" data-d="-1" aria-label="previous">${ARROW(-1)}</button>`
                + `<span class="gs-choice">${escapeHtml(row.text || '')}</span>`
                + `<button class="gs-arrow" type="button" data-d="1" aria-label="next">${ARROW(1)}</button></div>`;
        } else if (row.kind === 'button' || row.kind === 'keys') {
            ctl = `<span class="gs-go" aria-hidden="true">${ARROW(1)}</span>`;
        }
        el.innerHTML = name + `<div class="pf-ctl">${ctl}</div>`;
        return el;
    }

    /** The chosen row: its name, what it is set to, and anything to know about changing it. */
    drawHelp() {
        const row = this.row();
        this.helpName.textContent = row ? row.label : '';
        this.helpValue.textContent = row ? valueWords(row) : '';
        let text = '';
        if (this.note) text = this.note;
        else if (!row) text = '';
        else if (row.kind === 'keys') {
            text = 'GTA\'s own key bindings screen, where FiveM\'s and the server\'s keys are too (under FiveM). '
                + 'The pause menu closes while it is open.';
        } else if (row.locked) text = 'GTA does not let this change right now.';
        else if (row.changed) text = 'Changed, not applied yet: Apply changes (R or Y) makes it so.';
        else if (row.kind === 'button') text = 'Enter or A does this.';
        else if (this.tab?.graphics) text = 'Graphics changes wait for Apply changes, as in GTA.';
        else if (row.kind === 'list' && !sideBySide(row)) text = 'Left and right step through the choices.';
        this.helpText.textContent = text;
        this.helpText.classList.toggle('note', !!this.note);
    }

    drawQuestion() {
        const q = this.question;
        this.wrap.classList.toggle('gs-asking', !!q);
        if (!q) return;
        this.askTitle.textContent = q.title || '';
        this.askBody.textContent = q.body || '';
        this.askRow.textContent = '';
        (q.buttons || []).forEach((label, i) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'pl-cbtn' + (i === this.questionSel ? ' on' : '');
            b.dataset.c = i;
            b.textContent = label;
            this.askRow.appendChild(b);
        });
    }

    /** "More below" while the list goes on past the bottom; its top fades once it is scrolled. */
    syncMore() {
        const s = this.scrollEl;
        this.listWrap.classList.toggle('pf-has-more', s.scrollTop + s.clientHeight < s.scrollHeight - 4);
        this.listWrap.classList.toggle('pf-scrolled', s.scrollTop > 4);
    }

    dragTo(clientX) {
        const d = this.drag;
        if (!d) return;
        // In screen pixels, as clientX is: the track is in the zoomed list, which FiveM's Chromium 103 can measure unzoomed.
        const box = screenRect(d.track);
        const v = sliderAt(d.row, box.width > 0 ? (clientX - box.left) / box.width : 0);
        if (v === d.value) return;
        d.value = v;
        const pct = Math.max(0, Math.min(1, v / d.row.max)) * 100;
        const rowEl = d.track.closest('.pf-row');
        rowEl.querySelector('.pf-fill').style.width = pct + '%';
        rowEl.querySelector('.pf-thumb').style.left = pct + '%';
        rowEl.querySelector('.pf-num').textContent = v;
    }

    // ---- doing ----

    /** One change to GTA, the row marked as changing until it answers. One at a time: another waits for it. */
    async change(row, callback, args) {
        if (this.working || !row || row.locked || !this.tab) return;
        this.note = '';
        this.working = row.id;
        this.draw();
        const st = await nuiCallback(callback, { tab: this.tab.id, id: row.id, ...args });
        this.working = null;
        if (!this.isOpen) return;
        if (st && !st.error) this.note = '';
        this.setState(st);
    }

    /** Left / right on the chosen row. */
    step(d) {
        const row = this.row();
        if (!row || (row.kind !== 'slider' && row.kind !== 'list')) return;
        if (row.kind === 'slider' && ((d > 0 && row.value >= row.max) || (d < 0 && row.value <= 0))) return;
        this.change(row, 'gameSettingsStep', { dir: d > 0 ? 1 : -1 });
    }

    /** A slider dragged to a value, or a list's choice clicked. */
    setTo(row, value) {
        if (value === row.value) { this.draw(); return; }
        this.change(row, 'gameSettingsSet', { value });
    }

    /** Enter or A on the chosen row. */
    press() {
        if (this.failed) { this.open(); return; }
        const row = this.row();
        if (!row) return;
        if (row.kind === 'keys') { this.openKeys(); return; }
        if (row.kind === 'button') this.change(row, 'gameSettingsPress', {});
        else if (row.kind === 'list') this.step(1);
    }

    async apply() {
        if (this.working || !this.unapplied) return;
        this.note = '';
        this.working = 'apply';
        this.draw();
        const st = await nuiCallback('gameSettingsApply', { tab: this.tabId });
        this.working = null;
        if (this.isOpen) this.setState(st);
    }

    /** GTA's key bindings: this page and the pause menu shut, and pause.lua opens GTA's screen once GTA's settings
     *  menu under this page has gone. */
    openKeys() {
        this.close();
        nuiCallback('pauseKeyBindings', {});
    }

    setTab(i) {
        const n = this.tabs.length;
        if (!n || this.question) return;
        const t = this.tabs[((i % n) + n) % n];
        if (t.id === this.tabId && !this.loading) return;
        this.tabId = t.id;
        this.sel = 0;
        this.note = '';
        this.scrollEl.scrollTop = 0;
        if (t.keys) { this.loading = false; this.draw(); return; }
        this.loading = true;
        this.draw();
        const seq = ++this.seq;
        nuiCallback('gameSettingsTab', { tab: t.id }).then((st) => {
            if (seq !== this.seq || !this.isOpen) return;
            this.loading = false;
            this.setState(st);
        });
    }

    move(d) {
        const n = this.rows().length;
        if (!n) return;
        this.sel = (this.sel + d + n) % n;
        this.note = '';
        this.draw();
    }

    /** Back to the menu; with graphics changes not applied, asked first. */
    back() {
        if (this.unapplied && !this.question) { this.ask(LEAVE_QUESTION); return; }
        this.onBack();
    }

    ask(q) {
        this.question = q;
        // On the first button: GTA's own questions start on their first (Apply, Keep, OK), as GTA's do.
        this.questionSel = 0;
        this.draw();
    }

    /** A button of the question up: GTA's go to GTA; the page's own leave, apply or stay. */
    answer(i) {
        const q = this.question;
        if (!q) return;
        if (q.own) {
            this.question = null;
            if (i === 0) this.apply();
            else if (i === 1) { this.unapplied = false; this.onBack(); }
            else this.draw();
            return;
        }
        nuiCallback('gameSettingsAnswer', { index: i + 1 });
    }

    // ---- keys and the pad (pause.js hands them over in this mode) ----

    /** A key. Answers false when it was "back" out of the page (pause.js goes to its menu). */
    onKey(e) {
        if (e.type && e.type !== 'keydown') return true;
        const k = e.key.toLowerCase();
        if (k === 'arrowup' || k === 'w') return this.nav('up');
        if (k === 'arrowdown' || k === 's') return this.nav('down');
        if (k === 'arrowleft' || k === 'a') return this.nav('left');
        if (k === 'arrowright' || k === 'd') return this.nav('right');
        if (k === 'enter' || k === ' ') return this.nav('select');
        if (k === 'escape' || k === 'backspace') return this.nav('back');
        if (k === 'q') return this.nav('tabPrev');
        if (k === 'e' || k === 'tab') { e.preventDefault?.(); return this.nav('tabNext'); }
        if (k === 'r') return this.nav('buttonY');
        return true;
    }

    /** A pad (or key) intent. Answers false for "back" out of the page. */
    nav(n) {
        if (this.question) {
            const count = this.question.buttons.length;
            if (n === 'left' || n === 'up') { this.questionSel = (this.questionSel + count - 1) % count; this.drawQuestion(); }
            else if (n === 'right' || n === 'down') { this.questionSel = (this.questionSel + 1) % count; this.drawQuestion(); }
            else if (n === 'select') this.answer(this.questionSel);
            else if (n === 'back') this.answer(count - 1);   // the last button: Cancel, Revert, Not now, Stay
            return true;
        }
        if (n === 'up') this.move(-1);
        else if (n === 'down') this.move(1);
        else if (n === 'left') this.step(-1);
        else if (n === 'right') this.step(1);
        else if (n === 'select') this.press();
        else if (n === 'tabPrev') this.setTab(this.tabs.findIndex((t) => t.id === this.tabId) - 1);
        else if (n === 'tabNext') this.setTab(this.tabs.findIndex((t) => t.id === this.tabId) + 1);
        else if (n === 'buttonY') this.apply();
        else if (n === 'back') {
            if (this.unapplied) { this.ask(LEAVE_QUESTION); return true; }
            return false;
        }
        return true;
    }

    /** The pad's hint strip (controller.js). */
    hints() {
        if (this.question) return [['dpad', 'Choose'], ['a', 'Select'], ['b', 'Back']];
        const row = this.row();
        const h = [['dpad', row && (row.kind === 'slider' || row.kind === 'list') ? 'Choose / change' : 'Choose']];
        if (this.failed) h.push(['a', 'Try again']);
        else if (row && (row.kind === 'button' || row.kind === 'keys')) h.push(['a', 'Select']);
        if (this.tabs.length > 1) h.push(['lb', ''], ['rb', 'Tab']);
        if (this.unapplied && this.tab?.graphics) h.push(['y', 'Apply changes']);
        h.push(['b', 'Back']);
        return h;
    }
}
