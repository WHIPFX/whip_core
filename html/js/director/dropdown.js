// ========================================
// DIRECTOR — its dropdowns, whip's own (not the browser's)
//
// CEF's native <select> list is a popup of its own: unstyled, and over the game it does not always open (the
// Camera Creator met the same: cam-editor.js). Every select.dr-field the Director draws (its pages, the world
// builder's Configure panel) stays in the page as the value its code reads and writes (writeField), invisible
// over a box of whip's (enhance): the choice, its picture and a line under it when the option carries them
// (data-pic, data-sub: panels.js selectField), and a chevron. Pressed, the box opens a list of whip's under it
// (openChoices): a search once there are many, its groups (optgroup), a tick on the choice, the arrow keys, Enter
// and Esc. A pick sets the select and sends input and change from it, as the browser's list would: the page's
// own handlers do the rest.
//
// The list is a .dr-float on the body, as the Director's menus are, so the pad's circle takes it as a modal.
// ========================================

import { escapeHtml } from '../utils.js';
import { screenRect } from '../pad-cursor.js';
import { ICON_PATH } from '../ui-icons.js';

const e = escapeHtml;
const SEARCH_AT = 9;   // options from which the list has a search box

const CHEVRON = '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICON_PATH.down + '</svg>';
const TICK = '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICON_PATH.check + '</svg>';

let open = null;   // { el, anchor, close } while a list is up

/** Is a list up? */
export function isDropdownOpen() { return !!open; }

/** Its list down (a redraw, Esc from elsewhere). */
export function closeDropdown() { if (open) open.close(); }

/** The box (or select) the list is up from, or null. */
export function dropdownAnchor() { return open ? open.anchor : null; }

/** A select's choices as the list shows them: [{ group } | { value, label, pic, sub, disabled }]. */
export function choicesOf(sel) {
    const out = [];
    const add = (o) => out.push({ value: o.value, label: o.textContent, pic: o.dataset.pic || '', sub: o.dataset.sub || '',
                                  disabled: o.disabled });
    for (const c of sel.children) {
        if (c.tagName === 'OPTGROUP') {
            out.push({ group: c.label });
            for (const o of c.children) add(o);
        } else if (c.tagName === 'OPTION') add(c);
    }
    return out;
}

/** The box shows the select's choice. */
function paint(box, sel) {
    const o = sel.selectedOptions && sel.selectedOptions[0];
    const empty = !o || o.value === '';
    const pic = o && o.dataset.pic;
    box.classList.toggle('empty', empty);
    box.disabled = sel.disabled;
    box.innerHTML = (pic ? `<span class="dr-dd-pic"><img src="${e(pic)}" alt="" onerror="this.parentNode.classList.add('none')"></span>` : '')
        + `<span class="dr-dd-text"><span class="dr-dd-label">${e(o ? o.textContent : '')}</span>`
        + (o && o.dataset.sub ? `<span class="dr-dd-sub">${e(o.dataset.sub)}</span>` : '') + '</span>'
        + `<span class="dr-dd-chev">${CHEVRON}</span>`;
}

/** Every select.dr-field under `root` not done yet: whip's box over it. */
export function enhance(root) {
    const list = root.matches && root.matches('select.dr-field') ? [root] : [...(root.querySelectorAll ? root.querySelectorAll('select.dr-field') : [])];
    for (const sel of list) {
        if (sel.dataset.dd) continue;
        sel.dataset.dd = '1';
        const wrap = document.createElement('span');
        wrap.className = 'dr-dd-wrap';
        sel.parentNode.insertBefore(wrap, sel);
        wrap.appendChild(sel);
        const box = document.createElement('button');
        box.type = 'button';
        box.className = 'dr-dd';
        box.setAttribute('aria-haspopup', 'listbox');
        if (sel.getAttribute('aria-label')) box.setAttribute('aria-label', sel.getAttribute('aria-label'));
        wrap.appendChild(box);
        paint(box, sel);
        sel.addEventListener('change', () => paint(box, sel));
        box.addEventListener('click', (ev) => {
            ev.preventDefault();
            if (open && open.anchor === box) { open.close(); return; }
            openChoices(box, choicesOf(sel), sel.value, (v) => {
                if (sel.value === v) return;
                sel.value = v;
                paint(box, sel);
                sel.dispatchEvent(new Event('input', { bubbles: true }));
                sel.dispatchEvent(new Event('change', { bubbles: true }));
            }, { search: sel.options.length >= SEARCH_AT, label: sel.getAttribute('aria-label') || '' });
        });
    }
}

/** Keep every select.dr-field drawn from now on boxed (the pages are drawn again often). */
export function watchSelects(target) {
    enhance(target);
    new MutationObserver((muts) => {
        for (const m of muts) {
            for (const n of m.addedNodes) if (n.nodeType === 1) enhance(n);
        }
        // (The box a list hangs from was drawn away: the list goes with it.)
        if (open && !open.anchor.isConnected) open.close();
    }).observe(target, { childList: true, subtree: true });
}

/** A list of `items` ([{ group } | { value, label, pic, sub, disabled }]) under `anchor`; onPick(value). Used by the
 *  boxed selects, by any other box (a time field's units) and by every other screen's selects (ui-controls.js).
 *  o: { search, label, zoom, focus }: zoom, when given, is the list's own instead of the Director's (--dr-zoom), so a
 *  list opened from a screen zoomed otherwise (the /whip panel) is drawn at that screen's size. focus: what has the keys
 *  again once the list is put away (Esc or a pick), when the anchor cannot take them (a field's capsule). */
export function openChoices(anchor, items, current, onPick, o = {}) {
    closeDropdown();
    const el = document.createElement('div');
    el.className = 'dr-float dr-dd-float';
    const rows = items.map((it, i) => {
        if (it.group !== undefined) return `<div class="dr-dd-group">${e(it.group)}</div>`;
        const on = String(it.value) === String(current);
        return `<button type="button" class="dr-dd-opt${on ? ' on' : ''}" role="option" aria-selected="${on}" data-i="${i}"${it.disabled ? ' disabled' : ''}>`
            + (it.pic ? `<span class="dr-dd-pic"><img src="${e(it.pic)}" alt="" onerror="this.parentNode.classList.add('none')"></span>` : '')
            + `<span class="dr-dd-text"><span class="dr-dd-label">${e(it.label)}</span>${it.sub ? `<span class="dr-dd-sub">${e(it.sub)}</span>` : ''}</span>`
            + `<span class="dr-dd-tick">${on ? TICK : ''}</span></button>`;
    }).join('');
    el.innerHTML = `<div class="dr-dd-list" role="listbox"${o.label ? ` aria-label="${e(o.label)}"` : ''}>`
        + (o.search ? '<input class="dr-dd-find" type="text" placeholder="Find" spellcheck="false" aria-label="Find">' : '')
        + `<div class="dr-dd-rows">${rows}</div><div class="dr-dd-none">Nothing by that name</div></div>`;
    document.body.appendChild(el);

    const list = el.firstElementChild;
    if (o.zoom > 0) list.style.zoom = String(o.zoom);
    const find = el.querySelector('.dr-dd-find');
    const opts = () => [...el.querySelectorAll('.dr-dd-opt')].filter((b) => !b.hidden && !b.disabled);

    // Under the box (over it when there is no room), at least as wide as it. The list's own zoom is the Director's.
    const r = screenRect(anchor);
    const zoom = parseFloat(getComputedStyle(list).zoom) || 1;
    list.style.minWidth = (r.width / zoom) + 'px';
    const h = screenRect(list).height;
    const below = r.bottom + 4;
    const top = below + h > window.innerHeight - 8 && r.top - 4 - h > 8 ? r.top - 4 - h : below;
    el.style.left = Math.max(8, Math.min(r.left, window.innerWidth - r.width - 8)) + 'px';
    el.style.top = Math.max(8, top) + 'px';
    anchor.classList.add('open');

    const pick = (b) => {
        const it = items[Number(b.dataset.i)];
        close();
        if (o.focus) o.focus.focus();
        if (it) onPick(it.value);
    };
    const filter = () => {
        const q = find.value.trim().toLowerCase();
        let shown = 0;
        for (const b of el.querySelectorAll('.dr-dd-opt')) {
            const it = items[Number(b.dataset.i)];
            b.hidden = !!q && !`${it.label} ${it.sub || ''}`.toLowerCase().includes(q);
            if (!b.hidden) shown++;
        }
        for (const g of el.querySelectorAll('.dr-dd-group')) g.hidden = !!q;
        el.classList.toggle('nothing', shown === 0);
    };
    const move = (step) => {
        const all = opts();
        if (!all.length) return;
        const at = all.indexOf(document.activeElement);
        all[(at + step + all.length) % all.length].focus();
    };

    el.addEventListener('mousedown', (ev) => ev.stopPropagation());
    el.addEventListener('click', (ev) => {
        const b = ev.target.closest('.dr-dd-opt');
        if (b && !b.disabled) pick(b);
    });
    // The list's own keys, before the page's (the router listens on the document, after this).
    el.addEventListener('keydown', (ev) => {
        if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(); (o.focus || anchor).focus(); }
        else if (ev.key === 'ArrowDown') { ev.preventDefault(); ev.stopPropagation(); move(1); }
        else if (ev.key === 'ArrowUp') { ev.preventDefault(); ev.stopPropagation(); move(-1); }
        else if (ev.key === 'Enter') {
            ev.preventDefault();
            ev.stopPropagation();
            const b = document.activeElement && document.activeElement.closest('.dr-dd-opt') ? document.activeElement : opts()[0];
            if (b) pick(b);
        }
    });
    if (find) find.addEventListener('input', filter);
    const outside = (ev) => { if (!el.contains(ev.target) && ev.target !== anchor && !anchor.contains(ev.target)) close(); };
    document.addEventListener('mousedown', outside, true);
    window.addEventListener('wheel', onWheel, true);
    function onWheel(ev) { if (!el.contains(ev.target)) close(); }

    function close() {
        if (!open || open.el !== el) return;
        open = null;
        document.removeEventListener('mousedown', outside, true);
        window.removeEventListener('wheel', onWheel, true);
        anchor.classList.remove('open');
        el.remove();
    }
    open = { el, anchor, close };

    // The choice in sight, and the keys' place: the search, else the choice.
    const cur = el.querySelector('.dr-dd-opt.on');
    if (cur) cur.scrollIntoView({ block: 'nearest' });
    if (find) find.focus();
    else if (cur) cur.focus();
    else if (opts()[0]) opts()[0].focus();
}
