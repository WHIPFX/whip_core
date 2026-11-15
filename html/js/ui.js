import { NuiRouter } from './router.js';
import { nuiCallback, escapeHtml as esc, setItemImage } from './utils.js';
import { inv } from './core/inv-state.js';            // the radial's hotkeys wheel: pocket slots 1-5
import { invItemDefs } from './core/item-defs.js';
import { setCapsuleMode, capsuleMode, capsuleAvailable, onCapsuleFree } from './capsule.js';
import { loadingNow, onLoadingEnd } from './curtain.js';   // §1: notices wait out a load
import { headerNoticeAvailable, showHeaderNotice, setHeaderNoticeFallback } from './inv-notice.js';   // §1: the inventory's and /whip's headers
import { talkNoticeAvailable, talkNotice, setTalkNoticeFallback } from './shop-talk.js';             // §1: the shop screen's talk row
import { withPadGlyphs } from './pad-glyphs.js';
import { openPadKeyboard } from './pad-keyboard.js';   // whip's keyboard (and, loaded here, its Lua way in)

// ========================================
// UI LIBRARY — Runtime Components
// All generic UI utilities rendered here.
// ========================================

(function() {
    'use strict';

    // ---- Shared helpers ----
    //
    // `esc` is utils.js's escapeHtml — SAFE IN AN ATTRIBUTE TOO: every caller here builds attributes
    // with it, and `0` is a value, not nothing.

    /** The input types UI.Input may ask for. Anything else is drawn as text. */
    const INPUT_TYPES = { text: true, number: true, password: true, email: true, tel: true, url: true,
                          date: true, time: true, color: true, range: true };

    /** A min/max attribute: a finite number, or nothing. */
    function numAttr(name, v) {
        const n = Number(v);
        return (v != null && v !== '' && Number.isFinite(n)) ? ' ' + name + '="' + n + '"' : '';
    }

    function sendResult(id, result) {
        nuiCallback('uiResult', { id: id, result: result });
        // THE PAD SCOPE IS TOLD AT ONCE. A dialog has a key scope ('ui-dialog', below), and while one
        // is reported Lua disables every game control for the pad driver; a close by click, Escape or
        // timer must clear it now, not at the 500 ms backstop. Every close path clears its id before
        // calling this.
        NuiRouter.syncNavScope(true);
    }

    // ========================================
    // 1. NOTIFICATIONS
    // ========================================

    const notifContainer = document.getElementById('ui-notifications');
    const capsuleBubble  = document.getElementById('capsuleBubble');
    // The glyph slot inside the bubble's disc. The disc, its white ring and its fill are static
    // markup — only the glyph and the tint are ever written. See renderToCapsule.
    const capsuleIcon    = capsuleBubble ? capsuleBubble.querySelector('.sh-icon') : null;
    const capsuleText    = document.getElementById('capsuleNotifyText');
    const MAX_NOTIFS = 5;

    const NOTIF_ICONS = {
        success: '\u2713',   // checkmark
        error:   '\u2717',   // X
        info:    '\u2139',   // i
        warning: '\u26A0',   // triangle
    };

    /** The semantic token each type paints its disc with. Mirrors the .ui-notif-* rules in ui.css. */
    const NOTIF_COLORS = {
        success: 'var(--ui-success)',
        error:   'var(--ui-error)',
        info:    'var(--ui-info)',
        warning: 'var(--ui-warning)',
    };

    /* ========================================
       TWO SURFACES, AND ONLY ONE OF THEM IS OPTIONAL

       A notification prefers the PLAYER CAPSULE at the bottom left: the text replaces the gauges
       and the mic bubble becomes a coloured status disc. The top-right stack is the fallback.

       THE STACK IS NOT LEGACY. #status-hud \u2014 and so the capsule \u2014 fades out whenever a UI is open
       or the player is dead (WhipRefreshHudVisibility in client/hud.lua), and the inventory's own
       drag-and-drop errors fire from inside exactly that state. Availability is checked at
       ARRIVAL, and anything the capsule cannot take goes to the stack immediately.

       EXCEPT ON A SCREEN THAT SHOWS NOTICES ITSELF, where the player is looking: the /whip panel
       (its header's right; it covers the stack) and the pockets (their header, between the name and
       the weight), js/inv-notice.js; a shop (the shopper's talk row), js/shop-talk.js. Each is the
       shop screen's talk row, its disc the notice's mark. Only with none of them, the stack.

       BURSTS QUEUE THROUGH THE CAPSULE, ONE AT A TIME. The queue
       only ever holds messages waiting behind ANOTHER MESSAGE, which is what stops it stalling:
       the thing that drains it is the current notification's own timer, and that always fires.
       Anything that arrives while the capsule is unavailable for some other reason never enters
       the queue at all.

       EXCEPT A LOAD. While the screen is black for a load the capsule and the top-right stack are
       both under the black (only the logo is over it: curtain.js). So a notice that arrives then
       WAITS in the queue, and the load's end drains it (onLoadingEnd, below) — which always
       happens, because the load's end is the curtain lifting. The staleness rule still applies: a
       notice older than NOTIF_MAX_STALE_MS by the time the picture is back is dropped.
       ======================================== */

    /** Notifications waiting for the capsule. Each carries the time it arrived. */
    const capsuleQueue = [];
    let capsuleShowing = false;
    let capsuleTimer   = null;

    /**
     * How late a queued notification may be before it is dropped instead of shown.
     *
     * A NOTIFICATION NOBODY CAN ACT ON IS WORSE THAN ONE NOBODY SAW: a queued "Only weapons can go
     * here" twelve seconds late describes a drag the player has long finished.
     */
    const NOTIF_MAX_STALE_MS = 8000;

    /** Each type's drawn mark (js/glyphs.js): a tick, a cross, an i, a !, centred in their boxes. */
    const NOTIF_GLYPHS = { success: 'success', error: 'fail', info: 'info', warning: 'warning' };

    /** A type's drawn mark, or nil when js/glyphs.js has not got it (then its character, NOTIF_ICONS). */
    function notifGlyph(type) {
        const g = window.WhipGlyphs && window.WhipGlyphs.glyphs;
        const name = NOTIF_GLYPHS[type] || NOTIF_GLYPHS.info;
        return (g && g[name]) || null;
    }

    /** A notification type's mark as HTML, for the capsule bubble. */
    function notifIcon(type) {
        return notifGlyph(type)
            || '<span class="cap-bubble-glyph">' + (NOTIF_ICONS[type] || NOTIF_ICONS.info) + '</span>';
    }

    /** Render one notification into the top-right stack. The original behaviour, unchanged. */
    function renderToStack(data) {
        const el = document.createElement('div');
        el.className = 'ui-notif ui-notif-' + (data.type || 'info');

        const icon = notifGlyph(data.type) || NOTIF_ICONS[data.type] || NOTIF_ICONS.info;
        el.innerHTML =
            '<span class="ui-notif-icon">' + icon + '</span>' +
            '<span class="ui-notif-text">' + esc(data.text) + '</span>';

        notifContainer.appendChild(el);

        // Trigger entrance animation next frame
        requestAnimationFrame(function() {
            el.classList.add('visible');
        });

        const duration = data.duration || 3000;

        // Remove after duration
        setTimeout(function() {
            el.classList.remove('visible');
            el.classList.add('exiting');
            setTimeout(function() {
                if (el.parentNode) el.parentNode.removeChild(el);
            }, 300);
        }, duration);

        // Limit visible count
        const children = notifContainer.children;
        while (children.length > MAX_NOTIFS) {
            notifContainer.removeChild(children[0]);
        }
    }

    /**
     * Put one notification into the capsule and start its timer.
     *
     * THE BUBBLE IS RE-TINTED, NOT REBUILT. It is the same disc the microphone gauge draws — same
     * markup, same white ring, same black outline — and all that changes is the colour of the
     * core behind the glyph, which is what makes it read as the stat bubble TRANSFORMING rather
     * than a different badge appearing in its place. .sh-fill already carries
     * `transition: background 0.4s ease`, so the tint eases in; replacing the element's innerHTML
     * would build a fresh .sh-fill with no previous value and the colour would cut instead.
     */
    function renderToCapsule(data) {
        const type = data.type || 'info';

        capsuleIcon.innerHTML = notifIcon(type);
        capsuleBubble.style.setProperty('--cap-bubble-color', NOTIF_COLORS[type] || NOTIF_COLORS.info);

        // textContent, not innerHTML: this string can carry an item name a player chose.
        capsuleText.textContent = String(data.text || '');

        setCapsuleMode('notify');
        capsuleShowing = true;

        if (capsuleTimer) clearTimeout(capsuleTimer);
        capsuleTimer = setTimeout(finishCapsule, data.duration || 3000);
    }

    /** The current capsule notification's time is up. */
    function finishCapsule() {
        capsuleTimer = null;
        capsuleShowing = false;

        // ONLY IF IT IS STILL OURS. The composer outranks notifications, so pressing T mid-notice
        // hands the capsule straight to the text field \u2014 and this timer still fires afterwards.
        // Without the check it would yank the capsule back to stats while the player is typing.
        if (capsuleMode() === 'notify') setCapsuleMode('stats');

        pumpCapsule();
    }

    /** Show the next queued notification, dropping anything that has gone stale on the way. */
    function pumpCapsule() {
        if (capsuleShowing) return;
        if (loadingNow()) return;   // held until the load is over (see above)

        while (capsuleQueue.length > 0) {
            const next = capsuleQueue.shift();

            if (Date.now() - next.at > NOTIF_MAX_STALE_MS) continue;

            // The capsule stopped being available while this was waiting \u2014 a UI opened, or the
            // player died. Falling back (the inventory's header, else the stack) rather than holding it
            // is what keeps the queue from stalling behind a state nothing here can see change.
            if (!capsuleAvailable()) { renderElsewhere(next); continue; }

            renderToCapsule(next);
            return;
        }
    }

    // THE END OF A LOAD shows what waited out the black (see above).
    onLoadingEnd(pumpCapsule);

    // THE CAPSULE BACK ON ITS GAUGES — the composer closing — shows what waited for it. A notice
    // the capsule was TAKEN FROM is over at that point: it is not coming back, so its timer must
    // not hold the queue up for whatever was left of its three seconds. (After the notice's own
    // time runs out, finishCapsule has already cleared the flag, and this only pumps.)
    onCapsuleFree(() => {
        if (capsuleShowing) {
            if (capsuleTimer) clearTimeout(capsuleTimer);
            capsuleTimer = null;
            capsuleShowing = false;
        }
        pumpCapsule();
    });

    /** A screen that hides the capsule and shows notices itself is up: /whip, the pockets, a shop. */
    function screenTakesNotices() {
        return headerNoticeAvailable() || talkNoticeAvailable();
    }

    /** Where a notice goes when the capsule cannot take it, where the player is looking: /whip's header
     *  (its top right) or the pockets' (js/inv-notice.js), else the shop screen's talk row
     *  (js/shop-talk.js), else the stack. */
    function renderElsewhere(data) {
        const type = NOTIF_COLORS[data.type] ? data.type : 'info';
        const n = { text: String(data.text || ''), type: type, duration: data.duration,
            glyph: notifIcon(type), color: NOTIF_COLORS[type] };
        if (headerNoticeAvailable()) { showHeaderNotice(n); return; }
        if (talkNoticeAvailable()) { talkNotice(n); return; }
        renderToStack(data);
    }

    // A notice still waiting when its screen closes comes back here.
    setHeaderNoticeFallback((data) => uiNotify(data));
    setTalkNoticeFallback((data) => uiNotify(data));

    function uiNotify(data) {
        // A SCREEN THAT SHOWS NOTICES ITSELF (the capsule is hidden behind it anyway).
        if (screenTakesNotices()) {
            renderElsewhere(data);
            return;
        }

        // Waiting behind another notification, or out a load: queue it, timestamped, and let the
        // running timer (or the load ending) pull it through.
        if (capsuleShowing || loadingNow()) {
            capsuleQueue.push({
                text: data.text, type: data.type, duration: data.duration, at: Date.now(),
            });
            return;
        }

        if (capsuleAvailable()) {
            renderToCapsule(data);
            return;
        }

        renderElsewhere(data);
    }

    // ========================================
    // 2. PROGRESS BAR
    // ========================================

    // ONE BAR IN THE LIBRARY, AND IT IS THE DRAWTEXT BAND. This borrows that element for the length
    // of a call and animates its --dt-p itself, so UI.Progress is blocking, timed and cancelable while
    // a caller can still drive the band by hand.
    //
    // IT TAKES OVER THE BAND while it runs, and client/ui.lua gives it back: text shown during the
    // bar is held and put up when it ends, and the text that was up before comes back after it.

    let _progressRAF     = null;
    let _progressId      = null;
    let _progressLabel   = '';     // what the bar is, for its failure card if it is interrupted (§9 showFailure)

    function uiProgressBar(data) {
        _progressId = data.id;
        _progressLabel = data.label || '';
        const duration = Math.max(1, data.duration || 3000);

        // "X Cancel", not "Hold X" — the handler fires on keydown, so it always was a tap. A control of
        // the band's legend (drawtextMarkup): a keycap, or on a pad the button's picture — control 73 is
        // A there (client/ui.lua), which this said nothing of.
        const cancelKey = document.documentElement.dataset.input === 'pad' ? '{pad:a}' : '[X]';
        const label = data.canCancel
            ? (data.label || '') + '  |  ' + cancelKey + ' Cancel'
            : (data.label || '');

        // Its disc: the item it is done with, its picture in the bubble (UI.Progress's `item`, dtItemPicture); else
        // the caller's icon (UI.Progress's `icon`), else an hourglass (dtDisc).
        const item = data.item && typeof data.item.item === 'string' ? data.item : null;
        renderDrawtext(label, 'bottom', 0, { icon: data.icon, bar: true, item: item });

        const started = performance.now();
        function step(now) {
            const pct = Math.min(100, ((now - started) / duration) * 100);
            setDrawtextProgress(pct);
            if (pct < 100) {
                _progressRAF = requestAnimationFrame(step);
            } else {
                _progressRAF = null;
                clearProgressBar(true);
            }
        }
        _progressRAF = requestAnimationFrame(step);

        // rAF drives the fill AND the completion, rather than a parallel setTimeout, so the bar
        // reaching the end and the promise resolving are the same event. The old version ran a
        // CSS transition against an independent timer, which could disagree by a frame or two on
        // a busy client — visible as a bar that finished slightly before or after it resolved.
        //
        // NO PAGE KEY HOOK FOR X. The bar takes no NUI focus; X is read as a game control by
        // client/ui.lua's control lock. A page keydown hook would only hear keys typed into ANOTHER
        // screen (an "x" in chat would cancel a revive).
    }

    /** The bar ends: done, cancelled, or — with `failWhy` — interrupted (client/ui.lua UI.Interrupt), when it
     *  turns red where it stands and says why instead of going (§9 showFailure). */
    function clearProgressBar(completed, failWhy) {
        if (_progressRAF) { cancelAnimationFrame(_progressRAF); _progressRAF = null; }
        if (failWhy && _progressId != null) showFailure(failWhy, _progressLabel, FAIL_MS);
        else hideDrawtext();
        if (_progressId != null) {
            const id = _progressId;
            _progressId = null;
            sendResult(id, completed);
        }
    }

    // ========================================
    // 3. INPUT DIALOG
    // ========================================

    const inputOverlay = document.getElementById('ui-input-overlay');
    let _inputId = null;
    let _inputFields = [];   // the fields as asked for, for the checks on submit

    function uiInput(data) {
        _inputId = data.id;
        const fields = data.fields || [];
        _inputFields = fields;

        let html = '<div class="ui-modal">';
        html += '<div class="ui-modal-title">' + esc(data.title) + '</div>';
        html += '<div class="ui-modal-body">';

        for (let i = 0; i < fields.length; i++) {
            const f = fields[i];
            const fid = 'ui-input-field-' + i;
            html += '<div class="ui-input-field">';
            html += '<label class="ui-input-label" for="' + fid + '">' + esc(f.label || 'Field ' + (i + 1)) + '</label>';

            if (f.type === 'select') {
                html += '<select class="ui-input-el" id="' + fid + '">';
                const opts = f.options || [];
                for (let j = 0; j < opts.length; j++) {
                    const selected = (f.default != null && String(f.default) === String(opts[j].value)) ? ' selected' : '';
                    html += '<option value="' + esc(String(opts[j].value)) + '"' + selected + '>' + esc(opts[j].label) + '</option>';
                }
                html += '</select>';
            } else if (f.type === 'checkbox') {
                const checked = f.default ? ' checked' : '';
                html += '<div class="ui-input-check-row">';
                html += '<input type="checkbox" class="ui-input-el ui-input-checkbox" id="' + fid + '"' + checked + '>';
                html += '<span class="ui-input-check-text">' + esc(f.placeholder || '') + '</span>';
                html += '</div>';
            } else if (f.type === 'textarea') {
                // `rows` as documented, 1 to 12.
                const rows = Math.min(12, Math.max(1, Math.floor(Number(f.rows)) || 3));
                html += '<textarea class="ui-input-el" id="' + fid + '" placeholder="' + esc(f.placeholder || '') + '" rows="' + rows + '">' + esc(f.default || '') + '</textarea>';
            } else {
                // type, min and max went into the markup raw. They come from whichever resource
                // called UI.Input, so they are held to a list and to numbers respectively.
                const inputType = INPUT_TYPES[f.type] ? f.type : 'text';
                const minAttr = numAttr('min', f.min);
                const maxAttr = numAttr('max', f.max);
                html += '<input type="' + inputType + '" class="ui-input-el" id="' + fid + '" ' +
                    'placeholder="' + esc(f.placeholder || '') + '" ' +
                    'value="' + esc(String(f.default != null ? f.default : '')) + '"' +
                    minAttr + maxAttr + '>';
            }
            // Where a field's problem is said, if Submit finds one.
            html += '<div class="ui-input-problem" id="' + fid + '-problem"></div>';
            html += '</div>';
        }

        html += '</div>'; // body
        html += '<div class="ui-modal-actions">';
        html += '<button class="ui-btn ui-btn-cancel" data-action="_uiInputCancel">Cancel</button>';
        html += '<button class="ui-btn ui-btn-confirm" data-action="_uiInputSubmit">Submit</button>';
        html += '</div>';
        html += '</div>';

        inputOverlay.innerHTML = html;
        inputOverlay.style.display = 'flex';
        _inputPadAt = 0;          // a pad's ring starts on the first field
        inputPadMark();

        // Focus first input
        setTimeout(function() {
            const first = inputOverlay.querySelector('.ui-input-el');
            if (first && first.focus) first.focus();
        }, 50);
    }

    window._uiInputSubmit = function() {
        if (_inputId == null) return;
        const overlay = document.getElementById('ui-input-overlay');
        const els = overlay.querySelectorAll('.ui-input-el');

        // AN ARRAY, so Lua gets `result[1]` as documented (AI build test, 09-24). This was an object
        // keyed i + 1, and an object's keys are strings in JSON — so every answer arrived as
        // result["1"], and every caller (whip's own shop included) had to read both.
        const result = [];

        // WHAT THE DOCS PROMISE, CHECKED: `required`, and min/max (HTML attributes a typed value
        // ignores). A field that fails says why under itself and the dialog stays open.
        let problem = false;
        for (let i = 0; i < els.length; i++) {
            const el = els[i];
            const f = _inputFields[i] || {};
            const problemEl = document.getElementById('ui-input-field-' + i + '-problem');
            let why = '';
            if (el.type !== 'checkbox') {
                const empty = String(el.value).trim() === '';
                if (f.required && empty) {
                    why = 'Required';
                } else if (el.type === 'number' && !empty) {
                    const n = Number(el.value);
                    const min = Number(f.min), max = Number(f.max);
                    if (!Number.isFinite(n)) why = 'Must be a number';
                    else if (f.min != null && f.min !== '' && Number.isFinite(min) && n < min) why = 'At least ' + min;
                    else if (f.max != null && f.max !== '' && Number.isFinite(max) && n > max) why = 'At most ' + max;
                }
            }
            if (problemEl) problemEl.textContent = why;
            el.classList.toggle('ui-input-invalid', why !== '');
            if (why && !problem) { problem = true; if (el.focus) el.focus(); }
        }
        if (problem) return;

        for (let i = 0; i < els.length; i++) {
            const el = els[i];
            if (el.type === 'checkbox') {
                result.push(el.checked);
            } else if (el.type === 'number') {
                result.push(parseFloat(el.value) || 0);
            } else {
                result.push(el.value);
            }
        }

        const id = _inputId;
        _inputId = null;
        inputOverlay.style.display = 'none';
        inputOverlay.innerHTML = '';
        sendResult(id, result);
    };

    window._uiInputCancel = function() {
        if (_inputId == null) return;
        const id = _inputId;
        _inputId = null;
        inputOverlay.style.display = 'none';
        inputOverlay.innerHTML = '';
        sendResult(id, null);
    };

    // ---- the input dialog on a controller (whip's keyboard for what a pad types) ----
    // A white ring is the highlight. Up and down go field to field and on to the buttons, left and right
    // between the buttons (and through a list's choices). A types into a text or number field with whip's
    // keyboard (pad-keyboard.js), then the ring goes on to the next field, or to Submit after the last;
    // A ticks a box, steps a list, presses a button. B cancels. The ring is drawn only on a pad (ui.css).
    let _inputPadAt = 0;

    function inputPadItems() {
        const els = Array.from(inputOverlay.querySelectorAll('.ui-input-el'));
        const btns = Array.from(inputOverlay.querySelectorAll('.ui-modal-actions .ui-btn'));
        return { els, btns, all: els.concat(btns) };
    }

    function inputPadMark() {
        const { all } = inputPadItems();
        if (!all.length) return;
        _inputPadAt = Math.max(0, Math.min(all.length - 1, _inputPadAt));
        all.forEach((el, i) => el.classList.toggle('pad-focus', i === _inputPadAt));
    }

    function stepSelect(sel, d) {
        const n = sel.options.length;
        if (!n) return;
        sel.selectedIndex = (sel.selectedIndex + d + n) % n;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }

    function typeInputField(el) {
        const i = Array.from(inputOverlay.querySelectorAll('.ui-input-el')).indexOf(el);
        const f = _inputFields[i] || {};
        openPadKeyboard({
            title: f.label || 'Type',
            value: el.value,
            numeric: el.type === 'number',
            maxLength: el.maxLength > 0 ? el.maxLength : 0,
            onDone: (text) => {
                if (_inputId == null || !el.isConnected) return;
                el.value = text;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                const { els, btns, all } = inputPadItems();
                _inputPadAt = i + 1 < els.length ? i + 1 : all.indexOf(btns[btns.length - 1]);
                inputPadMark();
            },
        });
    }

    function inputPadNav(nav) {
        const { els, btns, all } = inputPadItems();
        const el = all[_inputPadAt];
        const onBtn = btns.indexOf(el) >= 0;
        if (nav === 'back') { window._uiInputCancel(); return; }
        if (nav === 'up') {
            _inputPadAt = onBtn ? els.length - 1 : _inputPadAt - 1;
        } else if (nav === 'down') {
            if (!onBtn) _inputPadAt = _inputPadAt + 1 < els.length ? _inputPadAt + 1 : all.indexOf(btns[btns.length - 1]);
        } else if (nav === 'left' || nav === 'right') {
            if (onBtn) _inputPadAt = all.indexOf(btns[nav === 'left' ? 0 : btns.length - 1]);
            else if (el && el.tagName === 'SELECT') stepSelect(el, nav === 'right' ? 1 : -1);
            else if (el && el.type === 'checkbox') el.checked = !el.checked;
        } else if (nav === 'select' && el) {
            if (onBtn) { el.click(); return; }
            if (el.type === 'checkbox') el.checked = !el.checked;
            else if (el.tagName === 'SELECT') stepSelect(el, 1);
            else typeInputField(el);
        }
        if (_inputId != null) inputPadMark();
    }

    // ========================================
    // 4. SKILL CHECK — the ring
    // ========================================
    //
    // Part of a ring lights up; push the dot in the middle onto it and hold it there while it fills
    // (holdMs). Then again on a smaller part somewhere else — one round per entry in the difficulty's
    // `rounds` (Config.SkillCheckDifficulty, read by shared/skillcheck.lua and sent here as `level`).
    // TOUCHING THE RING OUTSIDE THE LIT PART IS A MISS, and the check fails.
    //
    // TWO HANDS, ONE DOT — mouse and pad; no keyboard. Neither reaches this page
    // itself: the check takes no NUI focus (there is no cursor, nothing to click), so client/ui.lua
    // reads both through the game while the check is up and posts them here.
    //   mouse     just move it, no button. Each move moves the dot by how far the mouse went
    //             (uiSkillMouse), and the dot stays where it is left.
    //   pad       the right stick IS the dot (uiSkillStick): let go and it is back in the middle.
    // Whichever was used last drives the dot, and the dot wears its glyph: a mouse or an R.
    //
    // THE FILL STARTS SLOW AND ENDS QUICK: the time is holdMs whatever, and only the drawing
    // is eased (skEase). The sound follows the same curve — see skSound below.
    //
    // AFTER A ROUND THE RING WAITS, dimmed, for the dot to come back toward the middle (SK_ARM). The
    // dot is on the ring when a round completes and the next part is somewhere else, so without the
    // wait the frame the new part appeared would already be a miss.

    const skillEl = document.getElementById('ui-skillcheck');
    let _skillId = null;
    let _skill   = null;   // the running check's state, or null

    // The drawing, in the SVG's own units: a unit is a pixel at 1440p, like everything under
    // --ui-scale. A tight ring with a big dot, so the dot has little far to go. Its box is SK_BOX
    // either side of the centre, and .ui-skill-svg in ui.css is drawn at twice that — change the two
    // together.
    const SK_C      = 100;    // the centre
    const SK_OUT    = 72;     // the ring's outer edge
    const SK_IN     = 50;     // its inner edge
    const SK_KNOB   = 24;     // the dot's radius
    const SK_TRAVEL = 37;     // how far the dot's centre goes: at full reach it covers half the band
    const SK_BOX    = 84;     // half the drawing's box: the ring plus room for its glow

    // The feel. Reach is 0 (middle) to 1 (full travel).
    //
    // THE NEXT PART IS LIVE THE MOMENT ONE FILLS: the finished part's glow fades on its own while the
    // next is already lit, and the dot only has to lift off the ring (SK_ARM) before it counts again.
    const SK_RIM        = 0.85;   // this far out and the dot is touching the ring
    const SK_ARM        = 0.7;    // back inside this after a part before the ring counts again
    const SK_FLASH_MS   = 250;    // the LAST part's glow before the check answers
    const SK_MISS_MS    = 450;    // a miss (or the clock running out) shown before the answer
    const SK_LATE       = 0.3;    // the clock turns red with this much of it left
    // THE MOUSE'S SPEED: reach per unit of the game's mouse look (GetDisabledControlNormal 1/2, the
    // same numbers the cameras turn by — client/camera.lua), times Config.SkillCheckMouseSpeed. It
    // also follows the player's own GTA mouse sensitivity.
    const SK_MOUSE_GAIN = 0.8;
    const SK_MOUSE_WAKE = 0.02;   // less than this is a hand resting on the mouse, not taking the dot from the pad

    const SK_MARKUP =
        '<div class="ui-skill-box">' +
            '<svg class="ui-skill-svg" viewBox="' + (SK_C - SK_BOX) + ' ' + (SK_C - SK_BOX) + ' ' +
                (2 * SK_BOX) + ' ' + (2 * SK_BOX) + '">' +
                '<defs><filter id="ui-skill-glow" x="-30%" y="-30%" width="160%" height="160%">' +
                    '<feGaussianBlur stdDeviation="4" result="blur"/>' +
                    '<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>' +
                '</filter></defs>' +
                // The unlit ring: a faint light line on a dark rim, so it reads over a white sky too.
                '<circle class="sk-edge-rim" cx="' + SK_C + '" cy="' + SK_C + '" r="' + SK_IN + '"/>' +
                '<circle class="sk-edge" cx="' + SK_C + '" cy="' + SK_C + '" r="' + SK_IN + '"/>' +
                '<path class="sk-arc"/>' +
                '<path class="sk-fill"/>' +
                // The part just filled, glowing where it was while the next one is already lit.
                '<path class="sk-done-arc"/>' +
                '<path class="sk-miss-mark"/>' +
                // THE OUTER LINE IS THE CLOCK (the difficulty's msPerPart times its parts): full at the start, running
                // back to the top as time goes. pathLength 1, so the dash is simply the time left; turned
                // a quarter so it starts at the top. DRAWN AFTER THE PARTS: it sits on their outer edge,
                // so it has to be on top of them.
                '<circle class="sk-edge-rim" cx="' + SK_C + '" cy="' + SK_C + '" r="' + SK_OUT + '"/>' +
                '<circle class="sk-edge sk-timer" cx="' + SK_C + '" cy="' + SK_C + '" r="' + SK_OUT + '" ' +
                    'pathLength="1" stroke-dasharray="1 1" transform="rotate(-90 ' + SK_C + ' ' + SK_C + ')"/>' +
                '<g class="sk-knob" transform="translate(' + SK_C + ' ' + SK_C + ')">' +
                    '<circle class="sk-knob-disc" r="' + SK_KNOB + '"/>' +
                    '<circle class="sk-knob-tint" r="' + SK_KNOB + '"/>' +
                    '<text class="sk-glyph sk-glyph-pad">R</text>' +
                    '<g class="sk-glyph sk-glyph-mouse">' +
                        '<rect x="-6" y="-9" width="12" height="18" rx="6"/>' +
                        '<line x1="0" y1="-5.5" x2="0" y2="-2"/>' +
                    '</g>' +
                    // Drawn pointing up, and turned to wherever the dot points.
                    '<path class="sk-arrow" d="M-4 -14.5L4 -14.5L0 -19.5Z"/>' +
                '</g>' +
            '</svg>' +
            '<div class="ui-skill-hint">' +
                '<span class="sk-hint-mouse">Move the mouse</span>' +
            '</div>' +
        '</div>';

    /** A point on a circle of radius r at `deg` degrees clockwise from the top, as "x y". */
    function skPoint(r, deg) {
        const a = deg * Math.PI / 180;
        return (SK_C + r * Math.sin(a)).toFixed(2) + ' ' + (SK_C - r * Math.cos(a)).toFixed(2);
    }

    /** The ring's band from `from` to `to` degrees, clockwise, as one closed shape ('' when empty). */
    function skBand(from, to) {
        const span = Math.min(to - from, 359.9);
        if (!(span > 0)) return '';
        const end = from + span;
        const large = span > 180 ? 1 : 0;
        return 'M' + skPoint(SK_OUT, from) +
               'A' + SK_OUT + ' ' + SK_OUT + ' 0 ' + large + ' 1 ' + skPoint(SK_OUT, end) +
               'L' + skPoint(SK_IN, end) +
               'A' + SK_IN + ' ' + SK_IN + ' 0 ' + large + ' 0 ' + skPoint(SK_IN, from) + 'Z';
    }

    /** How far apart two angles are, the short way round (0-180). */
    function skApart(a, b) {
        return Math.abs(((a - b) % 360 + 540) % 360 - 180);
    }

    /** How much of the part is DRAWN when `t` of its time has passed: slow, then quick (a cubic
     *  ease-in). The time itself is never eased — the part still fills in exactly holdMs. */
    function skEase(t) {
        return t * t * t;
    }

    // ---- The sound ----
    //
    // While a part fills, a swoosh of filtered noise rises with the bar (the same skEase curve); when
    // the part fills, a click lands on top of it, higher each part; after the last part, the "you did
    // it" (skSound.success); and on a miss or the clock running out, the failure (skSound.fail).
    //
    // THE CLICKS CLIMB ONE OCTAVE IN ALL, however many parts there are (up to 16): the first part's
    // click is the lowest, the last an octave above it, and the rest spread evenly between.
    //
    // MADE HERE, NOT PLAYED FROM FILES: Web Audio builds all three, so there is nothing to ship or
    // load. SOUND NEVER COSTS THE CHECK — every call is in a try, and a page with no audio just plays
    // the check silently. The context is made on first use and woken if the browser had it asleep.
    const SK_VOLUME = 0.5;
    const SK_CLIMB  = 12;   // semitones from the first part's click to the last's: one octave

    const skSound = (function () {
        let ac = null, out = null, noise = null;

        function ctx() {
            if (!ac) {
                const AC = window.AudioContext || window.webkitAudioContext;
                if (!AC) return null;
                ac = new AC();
                out = ac.createGain();
                out.gain.value = SK_VOLUME;
                out.connect(ac.destination);
                // Half a second of white noise, looped: the swoosh's breath and the click's snap.
                const len = Math.floor(ac.sampleRate * 0.5);
                noise = ac.createBuffer(1, len, ac.sampleRate);
                const ch = noise.getChannelData(0);
                for (let i = 0; i < len; i++) ch[i] = Math.random() * 2 - 1;
            }
            if (ac.state === 'suspended' && ac.resume) ac.resume();
            return ac;
        }

        /** Part `part` (0-based) of `of`'s pitch, as a multiple of the first part's. */
        function pitch(part, of) {
            const semis = of > 1 ? SK_CLIMB * Math.min(part, of - 1) / (of - 1) : 0;
            return Math.pow(2, semis / 12);
        }

        /** The swoosh for part `part` of `of`, from `fromT` of the way through to the end, over `ms`.
         *  Answers a stop() for when the dot leaves before the part fills — or null. */
        function swoosh(part, of, fromT, ms) {
            try {
                const a = ctx();
                if (!a || !(ms > 0)) return null;
                const t0 = a.currentTime, dur = ms / 1000;
                const src = a.createBufferSource();
                src.buffer = noise;
                src.loop = true;
                const band = a.createBiquadFilter();
                band.type = 'bandpass';
                band.Q.value = 0.9;
                const swell = a.createGain();
                const kill = a.createGain();    // only stop() touches this, so it never fights the curves
                const N = 24, f = new Float32Array(N), g = new Float32Array(N);
                const top = 2600 * pitch(part, of);
                for (let i = 0; i < N; i++) {
                    const e = skEase(fromT + (1 - fromT) * i / (N - 1));
                    f[i] = 260 + (top - 260) * e;   // low to high
                    // Nearly level: the band widens as it rises, and that is the swell. (A narrow low
                    // band passes little of the noise — at a gain of 0.04 the swoosh measured 1/30th of
                    // the click.) The first point fades it in, rather than starting on a tick.
                    g[i] = i === 0 ? 0 : 0.3 + 0.1 * e;
                }
                band.frequency.setValueCurveAtTime(f, t0, dur);
                swell.gain.setValueCurveAtTime(g, t0, dur);
                src.connect(band); band.connect(swell); swell.connect(kill); kill.connect(out);
                src.start(t0);
                src.stop(t0 + dur + 0.05);
                return {
                    stop: function () {
                        try {
                            const now = a.currentTime;
                            kill.gain.setTargetAtTime(0, now, 0.012);
                            src.stop(now + 0.08);
                        } catch (_) { /* already over */ }
                    },
                };
            } catch (_) { return null; }
        }

        /** The click that lands when part `part` of `of` fills: a bright blip with a snap on top. */
        function click(part, of) {
            try {
                const a = ctx();
                if (!a) return;
                const t = a.currentTime, p = pitch(part, of);
                const o = a.createOscillator();
                o.type = 'triangle';
                o.frequency.setValueAtTime(1500 * p, t);
                o.frequency.exponentialRampToValueAtTime(1150 * p, t + 0.05);
                const og = a.createGain();
                og.gain.setValueAtTime(0.0001, t);
                og.gain.exponentialRampToValueAtTime(0.8, t + 0.003);
                og.gain.exponentialRampToValueAtTime(0.0001, t + 0.075);
                o.connect(og); og.connect(out);
                o.start(t); o.stop(t + 0.09);

                const n = a.createBufferSource();
                n.buffer = noise;
                const hp = a.createBiquadFilter();
                hp.type = 'highpass';
                hp.frequency.value = 3500;
                const ng = a.createGain();
                ng.gain.setValueAtTime(0.45, t);
                ng.gain.exponentialRampToValueAtTime(0.0001, t + 0.018);
                n.connect(hp); hp.connect(ng); ng.connect(out);
                n.start(t); n.stop(t + 0.025);
            } catch (_) { /* silent */ }
        }

        /** One bell-ish note at `t`: a sine with a quiet octave on top, struck and left to ring. */
        function note(a, freq, t, gain, ringS) {
            const o = a.createOscillator();
            o.type = 'sine';
            o.frequency.value = freq;
            const o2 = a.createOscillator();    // the octave: what makes it a chime, not a beep
            o2.type = 'triangle';
            o2.frequency.value = freq * 2;
            const g = a.createGain();
            g.gain.setValueAtTime(0.0001, t);
            g.gain.exponentialRampToValueAtTime(gain, t + 0.004);
            g.gain.exponentialRampToValueAtTime(0.0001, t + ringS);
            const g2 = a.createGain();
            g2.gain.value = 0.25;
            o.connect(g); o2.connect(g2); g2.connect(g); g.connect(out);
            o.start(t); o2.start(t);
            o.stop(t + ringS + 0.02); o2.stop(t + ringS + 0.02);
        }

        /** "YOU DID IT" after the last part, rising (falling is how a game says no). A warm hit, a
         *  quick run UP a major chord, and the chord ringing out together: the "ta-da". F# major, whose top note is the
         *  first click's pitch, so it belongs with them. */
        function success(delayMs) {
            try {
                const a = ctx();
                if (!a) return;
                const t = a.currentTime + (delayMs || 0) / 1000;

                // The hit underneath: a low sine that rises a touch rather than falls, and a soft knock.
                const o = a.createOscillator();
                o.type = 'sine';
                o.frequency.setValueAtTime(140, t);
                o.frequency.exponentialRampToValueAtTime(175, t + 0.06);
                const og = a.createGain();
                og.gain.setValueAtTime(0.0001, t);
                og.gain.exponentialRampToValueAtTime(0.35, t + 0.005);
                og.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
                o.connect(og); og.connect(out);
                o.start(t); o.stop(t + 0.22);
                const n = a.createBufferSource();
                n.buffer = noise;
                const lp = a.createBiquadFilter();
                lp.type = 'lowpass';
                lp.frequency.value = 1400;
                const ng = a.createGain();
                ng.gain.setValueAtTime(0.2, t);
                ng.gain.exponentialRampToValueAtTime(0.0001, t + 0.03);
                n.connect(lp); lp.connect(ng); ng.connect(out);
                n.start(t); n.stop(t + 0.04);

                // The run up the chord, then all four together, left to ring.
                const chord = [740, 932, 1109, 1480];   // F#5 A#5 C#6 F#6
                for (let i = 0; i < chord.length; i++) note(a, chord[i], t + i * 0.05, 0.18, 0.3);
                const held = t + chord.length * 0.05 + 0.02;
                for (let i = 0; i < chord.length; i++) note(a, chord[i], held, 0.09, 0.7);
            } catch (_) { /* silent */ }
        }

        /** THE FAILURE, for a miss and for the clock running out. Everything the success is not: low,
         *  dull and FALLING — a thud dropping away under two buzzy notes stepping down a tritone
         *  ("bwah-bwahh"). */
        function fail() {
            try {
                const a = ctx();
                if (!a) return;
                const t = a.currentTime;

                const o = a.createOscillator();
                o.type = 'sine';
                o.frequency.setValueAtTime(170, t);
                o.frequency.exponentialRampToValueAtTime(70, t + 0.25);
                const og = a.createGain();
                og.gain.setValueAtTime(0.0001, t);
                og.gain.exponentialRampToValueAtTime(0.45, t + 0.006);
                og.gain.exponentialRampToValueAtTime(0.0001, t + 0.32);
                o.connect(og); og.connect(out);
                o.start(t); o.stop(t + 0.34);

                // The two notes: a sawtooth under a low-pass, so it buzzes without being harsh.
                const notes = [[294, 0.02, 0.13], [208, 0.16, 0.34]];   // D4, then G#3: [Hz, start, length]
                for (let i = 0; i < notes.length; i++) {
                    const f = notes[i][0], s = t + notes[i][1], len = notes[i][2];
                    const b = a.createOscillator();
                    b.type = 'sawtooth';
                    b.frequency.setValueAtTime(f, s);
                    b.frequency.exponentialRampToValueAtTime(f * 0.94, s + len);   // sagging, not held
                    const lp = a.createBiquadFilter();
                    lp.type = 'lowpass';
                    lp.frequency.value = 900;
                    const bg = a.createGain();
                    bg.gain.setValueAtTime(0.0001, s);
                    bg.gain.exponentialRampToValueAtTime(0.16, s + 0.01);
                    bg.gain.setValueAtTime(0.16, s + len * 0.6);
                    bg.gain.exponentialRampToValueAtTime(0.0001, s + len);
                    b.connect(lp); lp.connect(bg); bg.connect(out);
                    b.start(s); b.stop(s + len + 0.02);
                }
            } catch (_) { /* silent */ }
        }

        return { swoosh: swoosh, click: click, success: success, fail: fail };
    })();

    const SK_SUCCESS_AFTER_MS = 110;   // the "you did it", after the last click

    function uiSkillCheck(data) {
        // Lua holds one blocking slot, so a check never arrives over a running one; a loop left over
        // from a page that missed its cancel is stopped rather than left running beside this one.
        if (_skill) { cancelAnimationFrame(_skill.raf); clearTimeout(_skill.timer); _skill = null; }

        const lv = (data && data.level) || {};
        const pieces = Math.max(1, Math.floor(Number(lv.pieces) || 8));
        const rounds = (Array.isArray(lv.rounds) && lv.rounds.length) ? lv.rounds.map(Number) : [4, 2, 1];
        const holdMs = Number(lv.holdMs) > 0 ? Number(lv.holdMs) : 196;
        const limitMs = Number(lv.timeLimitMs) > 0 ? Number(lv.timeLimitMs) : 4000;
        const mouseSpeed = Number(lv.mouseSpeed) > 0 ? Number(lv.mouseSpeed) : 1;

        _skillId = data.id;
        skillEl.innerHTML = SK_MARKUP;
        const box = skillEl.firstElementChild;
        const st = {
            box: box,
            arc: box.querySelector('.sk-arc'),
            fillEl: box.querySelector('.sk-fill'),
            missEl: box.querySelector('.sk-miss-mark'),
            doneEl: box.querySelector('.sk-done-arc'),
            clockEl: box.querySelector('.sk-timer'),
            knob: box.querySelector('.sk-knob'),
            arrow: box.querySelector('.sk-arrow'),
            pieces: pieces, rounds: rounds, holdMs: holdMs,
            round: 0, centre: 0, width: 0, lastDir: -1, fill: 0,
            phase: 'play', armed: false, timer: null, raf: 0, last: performance.now(),
            limitMs: limitMs, deadline: performance.now() + limitMs,   // the clock (the outer line)
            device: '', x: 0, y: 0,                         // the dot, -1..1 each way, y down
            stickX: 0, stickY: 0,                           // pad
            mouseGain: SK_MOUSE_GAIN * mouseSpeed,          // mouse
            swoosh: null,                                   // the sound of the part filling, while it is
            pointer: 180,                                   // where the arrow points: down, as drawn
            left: 1,                                        // how much of the clock is left, 0-1
            // The fill's colour as it starts and as it completes (base.css tokens, so a theme's own):
            // skDraw blends between them as the part fills. null when a token is not a colour this
            // can read — the stylesheet's plain fill colour then stands.
            fromRGB: skRGB(getComputedStyle(document.documentElement).getPropertyValue('--ui-skill-fill')),
            toRGB: skRGB(getComputedStyle(document.documentElement).getPropertyValue('--ui-skill-full')),
            drawnKnob: '', drawnArrow: '', drawnFill: -1, drawnWait: null, drawnClock: '', drawnLate: null,
        };
        st.frame = function (now) { skFrame(st, now); };
        _skill = st;

        skUse(st, document.documentElement.dataset.input === 'pad' ? 'pad' : 'mouse');
        skRound(st);
        skillEl.style.display = 'flex';
        st.raf = requestAnimationFrame(st.frame);
    }

    /** A token's colour as [r, g, b] — #rgb, #rrggbb, rgb() or rgba(), the forms base.css and a theme
     *  write — or null for anything else. */
    function skRGB(text) {
        const s = String(text || '').trim();
        let m = s.match(/^#([0-9a-f]{3})$/i);
        if (m) return m[1].split('').map((h) => parseInt(h + h, 16));
        m = s.match(/^#([0-9a-f]{6})$/i);
        if (m) return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16));
        m = s.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i);
        if (m) return [Number(m[1]), Number(m[2]), Number(m[3])];
        return null;
    }

    /** Light this round's part: its width in pieces, centred on one of the ring's directions, and
     *  never where the last one was. */
    function skRound(st) {
        const size = 360 / st.pieces;
        let dir;
        do { dir = Math.floor(Math.random() * st.pieces); } while (st.pieces > 1 && dir === st.lastDir);
        st.lastDir = dir;
        st.centre = dir * size;
        st.width = Math.min(360, Math.max(0, st.rounds[st.round] || 1) * size);
        st.fill = 0;
        st.armed = false;
        st.phase = 'play';
        st.arc.setAttribute('d', skBand(st.centre - st.width / 2, st.centre + st.width / 2));
    }

    /** Which hand drives the dot now. The dot stays where it is; the new hand picks it up from there. */
    function skUse(st, device) {
        if (st.device === device) return;
        if (st.device) st.box.classList.remove('sk-dev-' + st.device);
        st.box.classList.add('sk-dev-' + device);
        st.device = device;
    }

    /** Move the dot for this frame: the pad's stick puts it where the stick is. (The mouse moves it
     *  in uiSkillMouse, below, and leaves it where it is between moves.) */
    function skMove(st) {
        if (st.device !== 'pad') return;
        let x = st.stickX, y = st.stickY;
        const m = Math.hypot(x, y);
        if (m > 1) { x /= m; y /= m; }      // a square-gated stick reads past 1 on the diagonals
        st.x = x; st.y = y;
    }

    /** The part stopped filling (or never will now): its sound stops with it. */
    function skHush(st) {
        if (st.swoosh) { st.swoosh.stop(); st.swoosh = null; }
    }

    function skFrame(st, now) {
        if (st !== _skill) return;
        const dt = Math.min(50, Math.max(0, now - st.last));   // a stalled frame is not a leap
        st.last = now;
        skMove(st);

        const r = Math.min(1, Math.hypot(st.x, st.y));
        const deg = (Math.atan2(st.x, -st.y) * 180 / Math.PI + 360) % 360;
        if (r > 0.15) st.pointer = deg;

        // THE CLOCK runs while the check is being played, and stops when the last part fills.
        if (st.phase === 'play') {
            st.left = Math.max(0, (st.deadline - now) / st.limitMs);
            if (st.left <= 0) skTimeUp(st);
        }

        let filling = false;
        if (st.phase === 'play') {
            if (!st.armed) {
                if (r < SK_ARM) st.armed = true;
            } else if (r >= SK_RIM) {
                if (skApart(deg, st.centre) <= st.width / 2) {
                    filling = true;
                    // The swoosh starts with the fill — from wherever the fill is, if it drained part way.
                    if (!st.swoosh) st.swoosh = skSound.swoosh(st.round, st.rounds.length, st.fill, (1 - st.fill) * st.holdMs);
                    st.fill = Math.min(1, st.fill + dt / st.holdMs);
                    if (st.fill >= 1) skRoundDone(st);
                } else {
                    skMiss(st, deg);
                }
            } else if (st.fill > 0) {
                // Pulled back before it filled: it drains, twice as fast as it fills.
                st.fill = Math.max(0, st.fill - 2 * dt / st.holdMs);
            }
        }
        if (!filling) skHush(st);

        skDraw(st);
        st.raf = requestAnimationFrame(st.frame);
    }

    /** Write what changed this frame, and nothing else. */
    function skDraw(st) {
        const knob = 'translate(' + (SK_C + st.x * SK_TRAVEL).toFixed(2) + ' ' + (SK_C + st.y * SK_TRAVEL).toFixed(2) + ')';
        if (knob !== st.drawnKnob) { st.knob.setAttribute('transform', knob); st.drawnKnob = knob; }

        const arrow = 'rotate(' + st.pointer.toFixed(1) + ')';
        if (arrow !== st.drawnArrow) { st.arrow.setAttribute('transform', arrow); st.drawnArrow = arrow; }

        if (st.fill !== st.drawnFill) {
            // The part fills clockwise from its start, slow then quick (skEase), and grows more solid
            // as it goes (ui.css).
            const shown = skEase(st.fill);
            const from = st.centre - st.width / 2;
            st.fillEl.setAttribute('d', skBand(from, from + st.width * shown));
            st.box.style.setProperty('--sk-fill', shown.toFixed(3));
            // ...and turns from the fill colour to the full one (white) as it goes.
            if (st.fromRGB && st.toRGB) {
                const c = st.fromRGB.map((v, i) => Math.round(v + (st.toRGB[i] - v) * shown));
                st.box.style.setProperty('--sk-fill-colour', 'rgb(' + c.join(',') + ')');
            }
            st.drawnFill = st.fill;
        }

        const wait = st.phase === 'play' && !st.armed;
        if (wait !== st.drawnWait) { st.box.classList.toggle('sk-wait', wait); st.drawnWait = wait; }

        const clock = st.left.toFixed(3) + ' 1';
        if (clock !== st.drawnClock) { st.clockEl.setAttribute('stroke-dasharray', clock); st.drawnClock = clock; }
        const late = st.left < SK_LATE;
        if (late !== st.drawnLate) { st.box.classList.toggle('sk-late', late); st.drawnLate = late; }
    }

    // The timers act only on THEIR check: a cancel and a new check inside the window
    // must not let the old timer pass or fail the new one.
    function skRoundDone(st) {
        const last = st.round + 1 >= st.rounds.length;
        skHush(st);
        skSound.click(st.round, st.rounds.length);

        if (!last) {
            // THE NEXT PART AT ONCE (see SK_ARM). The one just filled glows where it was and fades on
            // its own (ui.css, .sk-done-arc) — restarted by taking the class off and putting it back.
            st.doneEl.setAttribute('d', skBand(st.centre - st.width / 2, st.centre + st.width / 2));
            st.doneEl.classList.remove('sk-glow');
            st.doneEl.getBoundingClientRect();
            st.doneEl.classList.add('sk-glow');
            st.round++;
            skRound(st);
            return;
        }

        // The last: the whole ring flashes, the "you did it" plays, and then it answers.
        st.phase = 'flash';
        st.box.classList.add('sk-done');
        skSound.success(SK_SUCCESS_AFTER_MS);
        st.timer = setTimeout(function () {
            if (st !== _skill) return;
            finishSkillCheck(true);
        }, SK_FLASH_MS);
    }

    /** The clock ran out: a failure, shown as a miss with nowhere marked. */
    function skTimeUp(st) {
        st.phase = 'miss';
        st.left = 0;
        skHush(st);
        skSound.fail();
        st.box.classList.add('sk-miss');
        st.timer = setTimeout(function () {
            if (st !== _skill) return;
            finishSkillCheck(false);
        }, SK_MISS_MS);
    }

    function skMiss(st, deg) {
        st.phase = 'miss';
        skHush(st);
        skSound.fail();
        st.missEl.setAttribute('d', skBand(deg - 4, deg + 4));   // where the dot touched
        st.box.classList.add('sk-miss');
        st.timer = setTimeout(function () {
            if (st !== _skill) return;
            finishSkillCheck(false);
        }, SK_MISS_MS);
    }

    /** true = passed, false = missed, null = cancelled (Lua reads the last as 'cancelled'). */
    function finishSkillCheck(passed) {
        const st = _skill;
        if (st) { cancelAnimationFrame(st.raf); clearTimeout(st.timer); skHush(st); }
        _skill = null;
        skillEl.style.display = 'none';
        skillEl.innerHTML = '';
        if (_skillId != null) {
            const id = _skillId;
            _skillId = null;
            sendResult(id, passed);
        }
    }

    /** The pad's right stick, from client/ui.lua. A push past the stick's resting wobble hands the dot
     *  to the pad. */
    function uiSkillStick(d) {
        const st = _skill;
        if (!st || !d || d.id !== _skillId) return;
        st.stickX = Number(d.x) || 0;
        st.stickY = Number(d.y) || 0;
        if (st.device !== 'pad' && Math.hypot(st.stickX, st.stickY) > 0.25) skUse(st, 'pad');
    }

    /** How far the mouse moved this frame, from client/ui.lua (the game's mouse look, 1/2). THE MOUSE
     *  NEEDS NO BUTTON: every move moves the dot by how far it went, and the dot stays where it is
     *  left. It stops at the ring's edge and comes straight back off it when the mouse turns round. */
    function uiSkillMouse(d) {
        const st = _skill;
        if (!st || !d || d.id !== _skillId) return;
        const dx = Number(d.x) || 0;
        const dy = Number(d.y) || 0;
        if (st.device !== 'mouse') {
            if (Math.abs(dx) + Math.abs(dy) < SK_MOUSE_WAKE) return;
            skUse(st, 'mouse');
        }
        let x = st.x + dx * st.mouseGain;
        let y = st.y + dy * st.mouseGain;
        const m = Math.hypot(x, y);
        if (m > 1) { x /= m; y /= m; }
        st.x = x;
        st.y = y;
    }

    // ========================================
    // 7. ALERT DIALOG
    // ========================================

    const alertOverlay = document.getElementById('ui-alert-overlay');
    let _alertId = null;

    function uiAlert(data) {
        _alertId = data.id;

        let html = '<div class="ui-modal ui-modal-sm">';
        html += '<div class="ui-modal-title">' + esc(data.title) + '</div>';
        html += '<div class="ui-modal-body"><p class="ui-modal-message">' + esc(data.message) + '</p></div>';
        html += '<div class="ui-modal-actions">';
        html += '<button class="ui-btn ui-btn-confirm" data-action="_uiAlertOk">' + esc(data.btnText || 'OK') + '</button>';
        html += '</div></div>';

        alertOverlay.innerHTML = html;
        alertOverlay.style.display = 'flex';
    }

    // true when the player pressed the button; null when it was closed for them (a cancel),
    // which Lua reads as 'cancelled' rather than "seen".
    function closeAlert(result) {
        if (_alertId == null) return;
        const id = _alertId;
        _alertId = null;
        alertOverlay.style.display = 'none';
        alertOverlay.innerHTML = '';
        sendResult(id, result);
    }

    window._uiAlertOk = function() { closeAlert(true); };

    // ========================================
    // 8. CONFIRM DIALOG
    // ========================================

    let _confirmId = null;

    function uiConfirm(data) {
        _confirmId = data.id;

        let html = '<div class="ui-modal ui-modal-sm">';
        html += '<div class="ui-modal-title">' + esc(data.title) + '</div>';
        html += '<div class="ui-modal-body"><p class="ui-modal-message">' + esc(data.message) + '</p></div>';
        html += '<div class="ui-modal-actions">';
        html += '<button class="ui-btn ui-btn-cancel" data-action="_uiConfirmNo">' + esc(data.cancelText || 'Cancel') + '</button>';
        html += '<button class="ui-btn ui-btn-confirm" data-action="_uiConfirmYes">' + esc(data.confirmText || 'Confirm') + '</button>';
        html += '</div></div>';

        alertOverlay.innerHTML = html;
        alertOverlay.style.display = 'flex';
    }

    window._uiConfirmYes = function() {
        if (_confirmId == null) return;
        const id = _confirmId;
        _confirmId = null;
        alertOverlay.style.display = 'none';
        alertOverlay.innerHTML = '';
        sendResult(id, true);
    };

    window._uiConfirmNo = function() {
        if (_confirmId == null) return;
        const id = _confirmId;
        _confirmId = null;
        alertOverlay.style.display = 'none';
        alertOverlay.innerHTML = '';
        sendResult(id, false);
    };

    // ========================================
    // 9. DRAWTEXT UI — the hint capsule
    // ========================================
    //
    // THE PLAYER CAPSULE'S TWIN (css/ui.css §9 has the look). UI.ShowText and the
    // progress bar draw a second capsule at the bottom centre, on the player capsule's row, built of
    // the same parts — .sh-capsule, and an .sh-stat disc as the bubble is — so it reads as the same
    // object. Its disc shows WHAT is being done, an icon from js/glyphs.js the caller names (place,
    // give, eat: the 3D prompts' own drawing); beside it the controls in the card's layout:
    //
    //     ( icon )  [E] Place Burger              the first control, as the title
    //               [Scroll] Rotate  [C] Cancel   the rest, in a row
    //
    // Callers write their controls as one string — "[E] Place Burger  |  [Scroll] Rotate  |  [C] Cancel",
    // {pad:a} for a button — and each part between the bars is one control. With no icon named, the
    // disc takes the first control's key off the front of the title ("E", or a pad's A in its colour);
    // with no key either, an hourglass for a bar and an "i" for plain words. `tone: 'warn'` turns the
    // ring amber: the thing cannot be done here (aiming at no surface). A bar fills the disc white from
    // the bottom, as a stat gauge does, and fills a track under the title. A bar done with an item (its
    // `item`) shows that item's picture in the disc instead, as the hotbar does, and only the track fills.

    const drawtextEl = document.getElementById('ui-drawtext');

    let _drawtextVisible = false;
    let _drawtextKey = '';   // what the capsule's inside was drawn from: a change redraws the inside only

    /** A pad button's colour, for its ring when the disc shows it (html/img/pad's own colours). */
    const DT_PAD_RING = { a: 'var(--ui-success)', b: 'var(--ui-error)', x: 'var(--ui-accent)', y: 'var(--ui-warning)' };

    /** One control as HTML: escaped first, so only a known button or a short [Key] becomes markup. */
    function dtPart(part) {
        return withPadGlyphs(esc(part), 'ui-padglyph').replace(/\[([^\[\]\s]{1,12})\]/g, '<kbd class="dt-key">$1</kbd>');
    }

    /** What the disc shows: { html, letter, ring, lead } — `lead` being the first control with the
     *  key the disc took off its front. */
    function dtDisc(lead, icon, hasBar) {
        const glyphs = (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
        const has = (name) => !!name && Object.prototype.hasOwnProperty.call(glyphs, name);
        if (has(icon)) return { html: glyphs[icon], lead: lead };
        let m = /^\s*\{pad:([a-z]+)\}\s*/.exec(lead);
        if (m && DT_PAD_RING[m[1]]) {
            return { html: esc(m[1].toUpperCase()), letter: true, ring: DT_PAD_RING[m[1]], lead: lead.slice(m[0].length) };
        }
        m = /^\s*\[([^\[\]\s]{1,3})\]\s*/.exec(lead);
        if (m) return { html: esc(m[1]), letter: true, lead: lead.slice(m[0].length) };
        if (hasBar && has('timer')) return { html: glyphs.timer, lead: lead };
        return { html: 'i', letter: true, lead: lead };
    }

    /** The capsule's inside: the disc, and the controls beside it. `fail`: the failure's cross (the `fail`
     *  glyph, as the error notification has it). `item`: a bar's item, whose picture the disc shows instead of
     *  filling (dtItemPicture puts it in); the glyph is kept for one with no picture. */
    function dtInside(text, icon, tone, hasBar, fail, item) {
        const parts = String(text).split(/\s+\|\s+/);
        const d = fail ? dtDisc(parts[0], 'fail', false) : dtDisc(parts[0], icon, hasBar);
        const ring = tone === 'warn' ? 'var(--ui-warning)' : d.ring;
        const pic = !!item && !fail;
        let html = '<div class="sh-stat dt-disc' + (tone === 'warn' ? ' dt-warn' : '') + (pic ? ' dt-item' : '') + '"'
            + (ring ? ' style="--dt-ring: ' + ring + '"' : '') + '>'
            + '<div class="sh-disc">' + (pic ? '' : '<div class="sh-fill"></div>') + '</div>'
            + (pic ? '<img class="dt-img" alt="" draggable="false">' : '')
            + '<div class="sh-icon' + (d.letter ? ' dt-letter' : '') + '">'
            + (d.letter ? '<span class="cap-bubble-glyph">' + d.html + '</span>' : d.html) + '</div></div>'
            + '<div class="dt-body"><div class="dt-title">' + dtPart(d.lead) + '</div>'
            + (hasBar ? '<div class="dt-bar"><span></span></div>' : '');
        if (parts.length > 1) {
            html += '<div class="dt-row">' + parts.slice(1).map((p) => '<span class="dt-item">' + dtPart(p) + '</span>').join('') + '</div>';
        }
        return html + '</div>';
    }

    /** A bar's item into its disc, by its state as the hotbar draws it (utils.js setItemImage). One with no picture
     *  (missing.png) shows the disc's glyph instead (.dt-no-art). */
    function dtItemPicture(cap, item) {
        const disc = cap.querySelector('.dt-item');
        const img = disc && disc.querySelector('.dt-img');
        if (!img) return;
        img.addEventListener('load', () => {
            disc.classList.toggle('dt-no-art', /(^|\/)missing\.png$/.test(img.getAttribute('src') || ''));
        });
        setItemImage(img, item);
    }

    /**
     * Draw the capsule.
     *
     * Shared by ShowText and by the progress bar, which is the point of there being one bar:
     * both go through here, so there is one element, one entrance animation, and one set of CSS
     * to keep right.
     *
     * @param {string} text
     * @param {string} position 'bottom' | 'top'
     * @param {number} pct      0-100 fill
     * @param {object} opts     { icon, tone, bar, fail, item } — bar: a progress value was given (0 is a value);
     *                          fail: the failure card (showFailure). Anything else drawn ends a failure.
     *                          item: a bar's item { item, metadata }, its picture in the disc (dtItemPicture).
     */
    function renderDrawtext(text, position, pct, opts) {
        opts = opts || {};
        if (!opts.fail && _failTimer) { clearTimeout(_failTimer); _failTimer = null; }
        pct = Math.max(0, Math.min(100, pct || 0));
        const posClass = 'ui-drawtext-' + (position === 'top' ? 'top' : 'bottom');
        let cap = drawtextEl.querySelector('.dt-cap');
        let changed = false;

        if (!_drawtextVisible || !cap) {
            drawtextEl.className = 'ui-drawtext ' + posClass;
            drawtextEl.innerHTML = '<div class="sh-capsule dt-cap"></div>';
            cap = drawtextEl.firstChild;
            drawtextEl.style.display = 'block';
            _drawtextKey = '';
            changed = true;
            requestAnimationFrame(function() {
                drawtextEl.classList.add('visible');
            });
        } else if (!drawtextEl.classList.contains(posClass)) {
            // The position too (ShowText('A', 'bottom') then ShowText('B', 'top')). Set on the element in place — `visible` stays, so no replay.
            drawtextEl.classList.remove('ui-drawtext-bottom', 'ui-drawtext-top');
            drawtextEl.classList.add(posClass);
            changed = true;
        }

        // THE INSIDE ONLY WHEN WHAT IT SAYS CHANGED. The hold-E respawn calls this every frame with
        // a new fill and the same words, and redrawing would restart the disc's fill each time.
        const key = text + '\u0000' + (opts.icon || '') + '\u0000' + (opts.tone || '') + '\u0000' + (opts.bar ? 1 : 0)
            + '\u0000' + (opts.fail ? 1 : 0)
            + '\u0000' + (opts.item ? opts.item.item + JSON.stringify(opts.item.metadata || null) : '');
        if (key !== _drawtextKey) {
            cap.innerHTML = dtInside(text, opts.icon, opts.tone, !!opts.bar, !!opts.fail, opts.item);
            if (opts.item && !opts.fail) dtItemPicture(cap, opts.item);
            _drawtextKey = key;
            changed = true;
        }
        cap.classList.toggle('dt-fail', !!opts.fail);
        cap.style.setProperty('--dt-p', String(pct / 100));
        _drawtextVisible = true;
        // The hotbar (js/hotbar.js) joins this capsule while it is up at the bottom: it is told when the
        // capsule is new, moved, or redrawn inside, since each of those can leave its discs out.
        if (changed) dtAnnounce(true);
    }

    /** Tell the hotbar the capsule is up (or gone): `data-shown` is the state, the event the moment. */
    function dtAnnounce(shown) {
        if (shown) drawtextEl.dataset.shown = '1';
        else delete drawtextEl.dataset.shown;
        drawtextEl.dispatchEvent(new CustomEvent('whip:drawtext', { detail: { shown: shown } }));
    }

    // ---- STOPPED, NOT CANCELLED (client/ui.lua says when) ----
    //
    // A bar or a mode ended by something the player did not choose — they went down, were knocked down, got out
    // — turns the capsule into a failure card for a moment: a red outline, its disc the error notification's red
    // ✗ glowing (css §9 .dt-fail), the why as its title and what stopped under it. A bar's turns red where it
    // stands. Anything else drawn on the band ends it early; a HideText does not (the mode taking its own text
    // down as it ends is what came before the failure, not after it).

    const FAIL_MS = 2600;
    let _failTimer = null;

    function showFailure(why, what, ms) {
        const label = String(what || '').replace(/(\.\.\.|…)\s*$/, '').trim();
        // THE SWAP IS ANIMATED (css §9 dtFail*): the red rises in the disc from where a bar had filled to, so
        // that is read before the card is redrawn; and a card already failing has .dt-fail taken off and put
        // back, so its shake plays again.
        const was = drawtextEl.querySelector('.dt-cap');
        let from = 0;
        if (was && _drawtextVisible) {
            from = parseFloat(was.style.getPropertyValue('--dt-p')) || 0;
            if (was.classList.contains('dt-fail')) { was.classList.remove('dt-fail'); void was.offsetWidth; }
        }
        renderDrawtext(String(why) + (label ? '  |  ' + label : ''), 'bottom', 0, { fail: true });
        const cap = drawtextEl.querySelector('.dt-cap');
        if (cap) cap.style.setProperty('--dt-from', String(Math.max(0, Math.min(1, from))));
        if (_failTimer) clearTimeout(_failTimer);
        _failTimer = setTimeout(() => { _failTimer = null; hideDrawtext(); }, Math.max(500, Number(ms) || FAIL_MS));
    }

    /** Move only the fill. Called per frame by the progress bar, so it must not touch the text. */
    function setDrawtextProgress(pct) {
        const cap = drawtextEl.querySelector('.dt-cap');
        if (!cap) return;
        pct = Math.max(0, Math.min(100, pct));
        cap.style.setProperty('--dt-p', String(pct / 100));   // the disc's fill and the bar's (css §9)
    }

    function hideDrawtext() {
        if (_failTimer) { clearTimeout(_failTimer); _failTimer = null; }
        _drawtextVisible = false;
        _drawtextKey = '';
        drawtextEl.classList.remove('visible');
        dtAnnounce(false);
        setTimeout(function() {
            // Something may have shown the capsule again inside the fade window — a progress bar
            // finishing as a door prompt comes up is enough. Without this guard that late
            // timeout blanks the new content and the element is left displaying nothing.
            if (_drawtextVisible) return;
            drawtextEl.style.display = 'none';
            drawtextEl.innerHTML = '';
        }, 250);
    }

    function uiShowText(data) {
        renderDrawtext(data.text, data.position, data.progress != null ? data.progress : 0,
            { icon: data.icon, tone: data.tone, bar: data.progress != null });
    }

    function uiHideText() {
        if (_failTimer) return;   // a failure card ends on its own (showFailure)
        hideDrawtext();
    }

    function uiInterrupted(data) {
        if (!data || typeof data.why !== 'string' || data.why === '') return;
        showFailure(data.why, typeof data.what === 'string' ? data.what : '', data.ms);
    }

    // ========================================
    // 10. OBJECTIVES — the tracker at the top right
    // ========================================
    //
    // A JOB'S OBJECTIVE, ON A CARD OF ITS OWN, top right, apart from the notifications. The hint capsule
    // (§9) is what the player is doing this moment; this is what the job wants of them, and both show at
    // once. The same capsule, so the same family (css/ui.css §10): the disc holds the objective's flag
    // and drains as the clock runs, the objective is the title, the job's name and the clock under it.
    // One card per job (client/ui.lua's cardId), the newest on top; a changed objective lights the ring
    // for a moment. The page counts the clock down itself; at 0:00 it stops and stays.

    const objectivesEl = document.createElement('div');
    objectivesEl.id = 'ui-objectives';
    document.body.appendChild(objectivesEl);

    const _objCards = new Map();   // cardId → { el, titleEl, nameEl, clockEl, text, endsAt, total, freshTimer }
    let _objTick = null;

    /** "4:59", "1:02:05": the band's clock (client/ui.lua clockText), rounded up. */
    function objClock(ms) {
        const s = Math.max(0, Math.ceil(ms / 1000));
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
        return (h > 0 ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(sec).padStart(2, '0');
    }

    /** One card's clock and its disc, as they stand at `now`. */
    function objPaint(c, now) {
        if (c.endsAt == null) return;
        const left = Math.max(0, c.endsAt - now);
        const text = objClock(left);
        if (c.clockEl.textContent !== text) c.clockEl.textContent = text;
        c.el.style.setProperty('--dt-p', String(c.total > 0 ? left / c.total : 0));
    }

    /** The tick runs while a card's clock does; the notifications stack under the cards (--obj-n). */
    function objSettle() {
        const running = () => Array.from(_objCards.values()).some((c) => c.endsAt != null && c.endsAt > Date.now());
        if (running() && !_objTick) {
            _objTick = setInterval(function() {
                const now = Date.now();
                _objCards.forEach((c) => objPaint(c, now));
                if (!running()) { clearInterval(_objTick); _objTick = null; }
            }, 250);
        } else if (!running() && _objTick) {
            clearInterval(_objTick);
            _objTick = null;
        }
        document.documentElement.style.setProperty('--obj-n', String(_objCards.size));
    }

    /** Lua: put a card up or change it ({ id, text, name, left, total, icon, film } — ms), or take it down
     *  ({ id, hide }). */
    function uiObjective(d) {
        if (!d || typeof d.id !== 'string') return;
        let c = _objCards.get(d.id);
        if (d.hide) {
            if (!c) return;
            _objCards.delete(d.id);
            clearTimeout(c.freshTimer);
            c.el.classList.remove('visible');
            setTimeout(function() { c.el.remove(); }, 400);
            objSettle();
            return;
        }
        if (!c) {
            const el = document.createElement('div');
            el.className = 'sh-capsule ob-card';
            el.innerHTML = '<div class="sh-stat dt-disc"><div class="sh-disc"><div class="sh-fill"></div></div>'
                + '<div class="sh-icon"></div></div>'
                + '<div class="dt-body"><div class="dt-title"></div>'
                + '<div class="dt-row"><span class="ob-name"></span><span class="ob-clock"></span></div></div>';
            objectivesEl.prepend(el);   // the newest on top
            c = { el: el, titleEl: el.querySelector('.dt-title'), nameEl: el.querySelector('.ob-name'),
                  clockEl: el.querySelector('.ob-clock'), iconEl: el.querySelector('.sh-icon'), icon: null,
                  text: null, endsAt: null, total: 0, freshTimer: null };
            _objCards.set(d.id, c);
            requestAnimationFrame(function() { el.classList.add('visible'); });
        }

        // The disc's mark: a glyph by its key (js/glyphs.js), the flag when it names none or one that is not
        // there. Only the table's own markup goes in, never the caller's string.
        const glyphs = (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
        const icon = typeof d.icon === 'string' && Object.prototype.hasOwnProperty.call(glyphs, d.icon)
            ? d.icon : 'objective';
        if (icon !== c.icon) {
            c.icon = icon;
            c.iconEl.innerHTML = glyphs[icon] || '';
        }
        // A card for a recording stays up on a clean screen (css/ui.css, the clean screen's rule).
        c.el.classList.toggle('ob-film', d.film === true);

        // textContent throughout: the words are a job's, and a job's words are a builder's.
        const text = String(d.text || '');
        if (text !== c.text) {
            // A new objective, or a count that moved ("(2 left)"): the ring lights for a moment.
            c.el.classList.remove('fresh');
            void c.el.offsetWidth;
            c.el.classList.add('fresh');
            clearTimeout(c.freshTimer);
            c.freshTimer = setTimeout(function() { c.el.classList.remove('fresh'); }, 1600);
        }
        c.text = text;
        c.titleEl.textContent = text;
        c.nameEl.textContent = d.name ? String(d.name) : '';
        if (typeof d.left === 'number') {
            c.endsAt = Date.now() + Math.max(0, d.left);
            c.total = typeof d.total === 'number' && d.total > 0 ? d.total : d.left;
        } else {
            c.endsAt = null;
            c.total = 0;
            c.clockEl.textContent = '';
            c.el.style.setProperty('--dt-p', '0');
        }
        objPaint(c, Date.now());
        c.el.classList.toggle('no-row', !c.nameEl.textContent && !c.clockEl.textContent);
        objSettle();
    }

    // ========================================
    // 5. RADIAL MENU
    // ========================================
    //
    // REGISTRATION-DRIVEN, not a blocking dialog.
    //
    // The old one took a list of options and returned the chosen one, which meant the caller had
    // to already know what the player could do. Nothing ever did, so it stayed a mockup. Now the
    // Lua side keeps a registry of options with condition functions and sends whichever currently
    // apply; this draws them and reports the choice. No promise and no result id, because the
    // wheel is a mode you toggle rather than a question you answer.
    //
    // THE "SLAB" WHEEL (css/ui.css §5 has the look). One thing is
    // aimed at, or nothing (`_radSel` -1, NEUTRAL), and every device moves the same aim:
    //   mouse  the angle from the screen's centre, anywhere on screen; within RAD.dead of it is
    //          neutral. A click uses, a right-click closes.
    //   pad    either stick, as numbers (the scope's onAnalog): pushed past RAD.padAim it aims. The
    //          left stick let back under RAD.padRest for RAD.padRestMs is neutral again (no input,
    //          neutral); the right stick's aim stays when let go, or the thumb could never
    //          reach A. A uses, B closes, D-pad left / right step round. Up and down do nothing:
    //          D-pad down, held, is what opened it, and may still be down.
    //   keys   arrows step, Enter or Space uses, Escape closes.
    // Using with nothing aimed at does nothing; on the "No actions available" ring it closes.
    //
    // TWO WHEELS ON A PAD. Opened with the pad (Lua sends `hotkeys`), the actions
    // wheel moves left and the hotkeys wheel sits on the right: pocket slots 1-5, always five, each the
    // item's picture with its name under it, an empty one drawn empty. The left stick works the
    // actions, the right stick the hotkeys — ONE AT A TIME (radDuoAnalog): the first stick pushed takes
    // control, and the other only takes it over once the controlling stick is let go; the wheel left
    // behind goes neutral. So only one thing is ever aimed at, and A uses it. The mouse aims the wheel
    // it is over, by the same rule. A page (Seats) has the screen to itself: the hotkeys give way.
    //
    // 25% BIGGER: css/ui.css draws .rad at --ui-scale × 1.25; RAD.big says so here.
    //
    // BUILT AS NODES, NOT AS AN HTML STRING: a label goes in as textContent, so nothing in it can become markup. The one
    // innerHTML is a glyph from js/glyphs.js, our own atlas, looked up by name.

    const radialEl = document.getElementById('ui-radial');
    let _radialOpen      = false;
    let _radialHideTimer = null;

    // Must match --rad-fade in css/ui.css.
    const RADIAL_FADE_MS = 180;

    /** The wheel's geometry in its 560 box (design px, 1440p — css/ui.css §5 says the same), and
     *  how far each device must move to aim. The pad numbers are past Lua's stick dead zone
     *  (client/controller.lua ANALOG_DEADZONE 0.18), so 0.45 and 0.15 are the design's 0.55 and 0.3
     *  of the stick's whole travel. */
    const RAD = {
        C: 280, rIn: 126, rOut: 258, rMid: 194, gap: 1.4, lift: 14, beamIn: 92,
        dead: 70,
        padAim: 0.45, padRest: 0.15, padRestMs: 140,
        big: 1.25,     // the wheel's size on --ui-scale: css/ui.css .rad's zoom
        duoX: 330,     // two wheels: each centre this far either side of the screen's (css .rad-left / .rad-right)
    };

    /** The hotkeys' picture box (design px): the biggest square that stays clear of its slab's edges at
     *  every angle the five slabs sit at. Its centre is halfway between the ring's edges (126..258: 66
     *  each way). A square turned 36 degrees against its slab (the bottom two) reaches 1.4 x its half
     *  along the radius: 44 x 1.4 = 61.5, so 4.5 px clear at worst, more in the other slabs and more
     *  again round a picture's own transparent edge. */
    const RAD_HK_PIC = 88;

    const SVG_NS = 'http://www.w3.org/2000/svg';

    /** The neutral mouse: a mouse, for the disc to sway. Not in js/glyphs.js — it is no action, and
     *  the atlas's every icon turns up in the capsule's loading light. */
    const RAD_MOUSE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"'
        + ' stroke-linecap="round" stroke-linejoin="round">'
        + '<rect x="6.2" y="2.6" width="11.6" height="18.8" rx="5.8"/>'
        + '<path d="M6.2 9.6h11.6"/><path d="M12 2.6v7"/><path d="M12 5.2v1.8" stroke-width="2.6"/></svg>';

    let _radOpts   = [];      // what is on the wheel: [{ id, label, icon, desc, placeholder }]
    let _radSel    = -1;      // the one aimed at, or -1: neutral
    let _radSlabs  = [];
    let _radRoot   = null;    // .rad, and the parts radSelect changes:
    let _radBeam   = null, _radFill = null, _radHero = null, _radName = null, _radDesc = null;
    let _radScale  = 1;       // screen px per design px when it opened (--ui-scale × RAD.big), for the mouse
    let _radRest   = null;    // the left stick's "let go" timer
    let _radByRight = false;  // the aim came from the right stick, which keeps it when let go

    // TWO WHEELS (a pad opened it). The actions wheel keeps the variables above; the hotkeys wheel is
    // `_hk`, its parts as radBuild returns them plus { opts, sel }.
    let _radDuo = false;      // two wheels are up
    let _hk     = null;       // the hotkeys wheel, while they are
    let _radCtl = null;       // the wheel the sticks work: 'act', 'items', or null before either is pushed

    // A SECOND PAGE (Seats). Picking an option whose `keep` is set leaves the
    // wheel up, and Lua answers with uiRadialPage: the ring gives way to the page, the disc and the
    // pill stay. While one is up, _radSel indexes the page's slabs.
    let _radPage     = null;   // { id, data } while a page is up, else null
    let _radWaitPage = false;  // a keep option was picked: its page is on the way, so no second use
    let _radSeatEls  = [];     // the Seats page's slabs, in the data's order
    let _radSeatPos  = [];     // each one's centre from the wheel's centre (design px) and its angle

    function radEmpty() {
        return _radOpts.length === 1 && !!_radOpts[0].placeholder;
    }

    function radPt(r, deg) {
        const t = deg * Math.PI / 180;
        return [RAD.C + r * Math.cos(t), RAD.C + r * Math.sin(t)];
    }

    /** A slab between radii r0..r1 and angles a0..a1 (degrees, clockwise from 3 o'clock). */
    function radSector(r0, r1, a0, a1) {
        const f = (v) => v.toFixed(1);
        const p0 = radPt(r1, a0), p1 = radPt(r1, a1), p2 = radPt(r0, a1), p3 = radPt(r0, a0);
        return 'M' + f(p0[0]) + ' ' + f(p0[1]) + ' A' + r1 + ' ' + r1 + ' 0 0 1 ' + f(p1[0]) + ' ' + f(p1[1])
             + ' L' + f(p2[0]) + ' ' + f(p2[1]) + ' A' + r0 + ' ' + r0 + ' 0 0 0 ' + f(p3[0]) + ' ' + f(p3[1]) + ' Z';
    }

    /** The whole ring between r0..r1 — one option has nothing to share it with. */
    function radRing(r0, r1) {
        const c = RAD.C;
        return 'M' + (c + r1) + ' ' + c + ' A' + r1 + ' ' + r1 + ' 0 1 1 ' + (c - r1) + ' ' + c
             + ' A' + r1 + ' ' + r1 + ' 0 1 1 ' + (c + r1) + ' ' + c + ' Z'
             + ' M' + (c + r0) + ' ' + c + ' A' + r0 + ' ' + r0 + ' 0 1 0 ' + (c - r0) + ' ' + c
             + ' A' + r0 + ' ' + r0 + ' 0 1 0 ' + (c + r0) + ' ' + c + ' Z';
    }

    /** Option i's slab between radii r0..r1, of n. */
    function radSlabPath(i, n, r0, r1) {
        if (n === 1) return radRing(r0, r1);
        const step = 360 / n, th = -90 + i * step;
        return radSector(r0, r1, th - step / 2 + RAD.gap / 2, th + step / 2 - RAD.gap / 2);
    }

    /** An option's icon into `el`: the glyph of that name, else its own short text ('E', '$'), else
     *  the label's first letter. */
    function radIcon(el, icon, label) {
        const glyphs = (window.WhipGlyphs && window.WhipGlyphs.glyphs) || {};
        el.textContent = '';
        if (icon && Object.prototype.hasOwnProperty.call(glyphs, icon)) {
            el.innerHTML = glyphs[icon];
            return;
        }
        const t = document.createElement('span');
        t.className = 'rad-icon-text';
        t.textContent = (icon && icon.length <= 3) ? icon : (String(label || '?').trim().charAt(0).toUpperCase() || '?');
        el.appendChild(t);
    }

    function radDiv(cls, parent) {
        const el = document.createElement('div');
        el.className = cls;
        if (parent) parent.appendChild(el);
        return el;
    }

    function radSvg(parent) {
        const s = document.createElementNS(SVG_NS, 'svg');
        s.setAttribute('width', '560');
        s.setAttribute('height', '560');
        s.setAttribute('viewBox', '0 0 560 560');
        parent.appendChild(s);
        return s;
    }

    function radStopRest() {
        if (_radRest) { clearTimeout(_radRest); _radRest = null; }
    }

    function radNeutral() {
        radStopRest();
        if (_radSel < 0 || !_radRoot) return;
        const els = _radPage ? _radSeatEls : _radSlabs;
        if (els[_radSel]) els[_radSel].classList.remove('on');
        _radSel = -1;
        _radRoot.classList.remove('chosen', 'aim-free', 'aim-you', 'aim-occupied');
        _radFill.classList.remove('full');
        _radName.textContent = _radPage ? 'Choose a seat' : 'Choose an action';
        _radDesc.textContent = '';
    }

    function radSelect(i) {
        const n = _radOpts.length;
        if (!n || !_radRoot || radEmpty()) return;
        i = ((i % n) + n) % n;
        if (i === _radSel) return;
        if (_radSel >= 0 && _radSlabs[_radSel]) _radSlabs[_radSel].classList.remove('on');
        _radSel = i;
        _radSlabs[i].classList.add('on');

        const o = _radOpts[i];
        _radRoot.classList.add('chosen');
        _radBeam.setAttribute('d', radSlabPath(i, n, RAD.beamIn, RAD.rIn - 3));
        radIcon(_radHero, o.icon, o.label);
        _radName.textContent = o.label;
        _radDesc.textContent = o.desc || '';
        radRefill(_radFill);
    }

    /** The disc fills again for each new choice: emptied with no transition, then risen. */
    function radRefill(fill) {
        fill.style.transition = 'none';
        fill.classList.remove('full');
        void fill.offsetHeight;
        fill.style.transition = '';
        fill.classList.add('full');
    }

    /** Which of n slabs covers this angle (degrees, clockwise from 3 o'clock). */
    function radIndexAt(deg, n) {
        const step = 360 / n;
        const rel = (((deg + 90 + step / 2) % 360) + 360) % 360;
        return Math.floor(rel / step);
    }

    /** Aim at whichever slab covers this angle. */
    function radAim(deg) {
        const n = _radOpts.length;
        if (!n) return;
        radSelect(radIndexAt(deg, n));
    }

    /** D-pad left / right and the arrows. Two wheels: the one in control steps — the actions until
     *  a stick has chosen, the hotkeys when there are no actions. */
    function radStep(d) {
        if (!_radialOpen) return;
        if (_radDuo && _hk && (_radCtl === 'items' || radEmpty())) {
            radTake('items');
            hkSelect(_hk.sel < 0 ? (d > 0 ? 0 : _hk.opts.length - 1) : _hk.sel + d);
            return;
        }
        if (radEmpty()) return;
        if (_radDuo) radTake('act');
        _radByRight = false;
        radSelect(_radSel < 0 ? (d > 0 ? 0 : _radOpts.length - 1) : _radSel + d);
    }

    function radUse() {
        if (!_radialOpen || _radWaitPage) return;
        if (_radPage) { radSeatPick(); return; }
        // Two wheels: only one of them has an aim at a time (radTake), so A uses whichever does.
        if (_hk && _hk.sel >= 0) { hkUse(); return; }
        if (radEmpty()) { nuiCallback('radialClose', {}); return; }
        if (_radSel < 0) return;
        window._uiRadialSelect(String(_radOpts[_radSel].id));
    }

    function uiRadialShow(data) {
        const options = data.options || [];
        if (options.length === 0) return;

        if (_radialHideTimer) { clearTimeout(_radialHideTimer); _radialHideTimer = null; }
        radStopRest();

        _radOpts = options;
        _radSel = -1;
        _radSlabs = [];
        _radByRight = false;
        // The first page, fresh: on opening, and on coming back from a second one.
        _radPage = null;
        _radWaitPage = false;
        _radSeatEls = [];
        _radSeatPos = [];
        // Two wheels when the pad opened it, and neither in control until a stick is pushed.
        _radDuo = !!data.hotkeys;
        _radCtl = null;
        _hk = null;
        _radScale = (parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ui-scale'))
            || Math.min(window.innerHeight / 1440, window.innerWidth / 2560)) * RAD.big;   // utils.js's rule

        const act = radBuild(options, false);
        _radRoot = act.root;
        _radSlabs = act.slabs;
        _radBeam = act.beam;
        _radFill = act.fill;
        _radHero = act.hero;
        _radName = act.name;
        _radDesc = act.desc;

        radialEl.textContent = '';
        radialEl.appendChild(act.root);
        if (_radDuo) {
            const opts = radHotkeys();
            _hk = Object.assign(radBuild(opts, true), { opts: opts, sel: -1 });
            act.root.classList.add('rad-left');
            _hk.root.classList.add('rad-right');
            radialEl.appendChild(_hk.root);
        }
        radialEl.style.display = 'flex';

        // Commit the display change before the class flips, or there is no start value to
        // interpolate from and the wheel simply appears. Same idiom as the aim target layer.
        void radialEl.offsetWidth;

        radialEl.classList.add('visible');
        _radialOpen = true;
    }

    /** One wheel: the ring of slabs round the stat disc, and the pill under it. `items` makes it the
     *  hotkeys wheel (radHotkeys' options): each face the slot's number, the item's picture and its
     *  name. Returns the parts the aim changes. */
    function radBuild(options, items) {
        const n = options.length;
        const empty = !items && n === 1 && !!options[0].placeholder;
        const step = 360 / n;

        const root = radDiv('rad' + (empty ? ' empty' : '') + (items ? ' rad-items' : ''));
        // Smaller icons and type as the ring fills, and a label as wide as its slab allows. The
        // hotkeys are only ever five and carry no names (the pill names the aimed one), so their
        // pictures go big: RAD_HK_PIC, see there.
        root.style.setProperty('--rad-icon', items ? RAD_HK_PIC + 'px' : n > 16 ? '24px' : n > 12 ? '28px' : '34px');
        root.style.setProperty('--rad-label-fs', n > 16 ? '10px' : n > 12 ? '11px' : '12px');
        root.style.setProperty('--rad-label-w',
            Math.round(Math.min(150, (2 * Math.PI * RAD.rMid) / n - (n > 12 ? 4 : 18))) + 'px');

        const wheel = radDiv('rad-wheel', root);

        // The beam: under the slabs, from the disc's edge to the chosen one. A gradient id per wheel:
        // two wheels up at once would otherwise share the first one's.
        const gradId = items ? 'radBeamGradHk' : 'radBeamGrad';
        const beamSvg = radSvg(wheel);
        beamSvg.setAttribute('class', 'rad-beam');
        const defs = document.createElementNS(SVG_NS, 'defs');
        const grad = document.createElementNS(SVG_NS, 'radialGradient');
        grad.setAttribute('id', gradId);
        grad.setAttribute('cx', String(RAD.C));
        grad.setAttribute('cy', String(RAD.C));
        grad.setAttribute('r', String(RAD.rIn - 2));
        grad.setAttribute('gradientUnits', 'userSpaceOnUse');
        [['0.7', '#60a5fa', '0.08'], ['1', '#ffffff', '0.42']].forEach((s) => {
            const stop = document.createElementNS(SVG_NS, 'stop');
            stop.setAttribute('offset', s[0]);
            stop.setAttribute('stop-color', s[1]);
            stop.setAttribute('stop-opacity', s[2]);
            grad.appendChild(stop);
        });
        defs.appendChild(grad);
        beamSvg.appendChild(defs);
        const beam = document.createElementNS(SVG_NS, 'path');
        beam.setAttribute('fill', 'url(#' + gradId + ')');
        beamSvg.appendChild(beam);

        const slabs = [];
        for (let i = 0; i < n; i++) {
            const o = options[i];
            const th = -90 + i * step;
            const slab = radDiv('rad-slab' + (empty ? ' empty' : ''), wheel);
            // Lifted straight out from the centre when chosen; one option all the way round stays put.
            const lift = n === 1 ? 0 : RAD.lift;
            const t = th * Math.PI / 180;
            slab.style.setProperty('--lx', (lift * Math.cos(t)).toFixed(1) + 'px');
            slab.style.setProperty('--ly', (lift * Math.sin(t)).toFixed(1) + 'px');

            const path = document.createElementNS(SVG_NS, 'path');
            path.setAttribute('class', 'rad-shape');
            path.setAttribute('d', radSlabPath(i, n, RAD.rIn, RAD.rOut));
            radSvg(slab).appendChild(path);

            if (!empty) {
                // A hotkey's picture alone, halfway between the ring's edges; an action's icon and name
                // on the label line.
                const c = radPt(items ? (RAD.rIn + RAD.rOut) / 2 : RAD.rMid, th);
                const face = radDiv('rad-face', slab);
                face.style.left = c[0].toFixed(1) + 'px';
                face.style.top = c[1].toFixed(1) + 'px';
                if (items) radSlotFace(face, slab, o);
                else {
                    radIcon(radDiv('rad-icon', face), o.icon, o.label);
                    radDiv('rad-label', face).textContent = o.label;
                }
            }
            slabs.push(slab);
        }

        // The centre: the stat disc, its hero, and neutral's hints — the stick cap names the stick
        // that works this wheel when there are two.
        const disc = radDiv('rad-disc', wheel);
        const clip = radDiv('rad-disc-clip', disc);
        radDiv('rad-disc-core', clip);
        const fill = radDiv('rad-disc-fill', clip);
        radDiv('rad-disc-ring', disc);
        const hero = radDiv('rad-hero', disc);
        const stick = radDiv('rad-hint rad-hint-stick', disc);
        radDiv('rad-stick-well', stick);
        radDiv('rad-stick-cap', stick).textContent = items ? 'R' : 'L';
        const mouse = radDiv('rad-hint rad-hint-mouse', disc);
        radDiv('rad-mouse', mouse).innerHTML = RAD_MOUSE;

        // The pill: the name and what it does — or, neutral, how to choose.
        const pill = radDiv('rad-pill', root);
        const name = document.createElement('span');
        name.className = 'rad-pill-name';
        name.textContent = empty ? options[0].label : items ? 'Choose an item' : 'Choose an action';
        pill.appendChild(name);
        const desc = document.createElement('span');
        desc.className = 'rad-pill-desc';
        desc.textContent = empty ? (options[0].desc || '') : '';
        pill.appendChild(desc);
        const push = !_radDuo ? 'Push a stick toward one'
            : items ? 'Push the right stick toward one' : 'Push the left stick toward one';
        [['rad-pill-how rad-pill-how-mouse', 'Point the mouse toward one'],
         ['rad-pill-how rad-pill-how-stick', push]].forEach((h) => {
            const s = document.createElement('span');
            s.className = h[0];
            s.textContent = h[1];
            pill.appendChild(s);
        });

        return { root: root, slabs: slabs, beam: beam, fill: fill, hero: hero, name: name, desc: desc };
    }

    // ---- The hotkeys wheel: two wheels on a pad ----

    /** Pocket slots 1-5 as the hotkeys wheel's options, from the inventory the page holds — where the
     *  hotbar (js/hotbar.js) draws them from, so the two always agree. Always five: a slot with nothing
     *  in it (or an item this page has no definition for, which the hotbar leaves empty too) is one
     *  with no `item`. */
    function radHotkeys() {
        const held = (inv.state && inv.state.player) || {};
        const out = [];
        for (let i = 1; i <= 5; i++) {
            const s = held[String(i)];
            const def = s && invItemDefs[s.item];
            if (!def) {
                out.push({ slot: i, item: null, label: 'Empty', desc: '' });
                continue;
            }
            // The pill's second words: how many are left (or the cash), never the slot's number.
            const amount = Number(s.amount) || 1;
            const count = def.type === 'currency' ? '$' + amount.toLocaleString('en-US')
                : amount > 1 ? amount.toLocaleString('en-US') + ' left' : '';
            out.push({ slot: i, item: s.item, metadata: s.metadata, label: def.name || s.item, desc: count });
        }
        return out;
    }

    /** The item's picture, the one its state picks (setItemImage): utils.js's fallback retries, then
     *  missing.png. One that ends there marks its box .no-art, which draws the inventory's quiet outline
     *  glyph in its place rather than a "?" picture (as js/inventory.js does for a slot). */
    function radItemImg(o) {
        const img = document.createElement('img');
        img.className = 'rad-art';
        img.alt = '';
        img.draggable = false;
        img.addEventListener('load', function() {
            const box = img.parentElement;
            if (box) box.classList.toggle('no-art', /(^|\/)missing\.png$/.test(img.getAttribute('src') || ''));
        });
        setItemImage(img, { item: o.item, metadata: o.metadata });
        return img;
    }

    /** A hotkey slot's face, above its name: the item's picture — or, empty, a dashed box where the
     *  picture would be. No slot number (the pill names the slot): it took the room the name needs. */
    function radSlotFace(face, slab, o) {
        const box = radDiv('rad-icon' + (o.item ? '' : ' rad-none'), face);
        if (o.item) box.appendChild(radItemImg(o));
        else slab.classList.add('rad-slot-empty');
    }

    function hkNeutral() {
        if (!_hk || _hk.sel < 0) return;
        _hk.slabs[_hk.sel].classList.remove('on');
        _hk.sel = -1;
        _hk.root.classList.remove('chosen', 'aim-empty');
        _hk.fill.classList.remove('full');
        _hk.hero.textContent = '';
        _hk.name.textContent = 'Choose an item';
        _hk.desc.textContent = '';
    }

    /** Aim at hotkey i: lifted, the beam, the item as the hero in its own colours, the pill. An empty
     *  slot can be aimed at too (the wheel answers the stick wherever it points), but the disc stays
     *  empty and A does nothing. */
    function hkSelect(i) {
        if (!_hk) return;
        const n = _hk.opts.length;
        i = ((i % n) + n) % n;
        if (i === _hk.sel) return;
        if (_hk.sel >= 0) _hk.slabs[_hk.sel].classList.remove('on');
        _hk.sel = i;
        _hk.slabs[i].classList.add('on');
        const o = _hk.opts[i];
        _hk.root.classList.add('chosen');
        _hk.root.classList.toggle('aim-empty', !o.item);
        _hk.beam.setAttribute('d', radSlabPath(i, n, RAD.beamIn, RAD.rIn - 3));
        _hk.hero.textContent = '';
        _hk.hero.classList.remove('no-art');   // the new picture's load says again, if it has none
        if (o.item) _hk.hero.appendChild(radItemImg(o));
        _hk.name.textContent = o.label;
        _hk.desc.textContent = o.desc;
        // No white fill in the disc for a hotkey: only its slab lights, and the item sits on the dark disc.
    }

    /** A on an aimed hotkey: Lua closes the wheel and uses that slot, as its number key does. */
    function hkUse() {
        const o = _hk.opts[_hk.sel];
        if (!o || !o.item) return;
        nuiCallback('radialUseSlot', { slot: o.slot });
        uiRadialHide();
    }

    /** Hand the aim to one wheel, 'act' or 'items'. The one it leaves goes neutral: only one thing is
     *  ever aimed at. */
    function radTake(side) {
        if (_radCtl === side) return;
        _radCtl = side;
        if (side === 'act') hkNeutral();
        else radNeutral();
    }

    function uiRadialHide() {
        if (!_radialOpen) return;
        _radialOpen = false;
        _radPage = null;
        _radWaitPage = false;
        radStopRest();

        radialEl.classList.remove('visible');

        // Held on screen until the fade finishes, then emptied.
        _radialHideTimer = setTimeout(function() {
            _radialHideTimer = null;
            radialEl.style.display = 'none';
            radialEl.textContent = '';
            _radRoot = null;
            _radSlabs = [];
            _radSeatEls = [];
            _radSeatPos = [];
            _radOpts = [];
            _radSel = -1;
            _hk = null;
            _radCtl = null;
        }, RADIAL_FADE_MS + 40);
    }

    window._uiRadialSelect = function(optionId) {
        if (!_radialOpen) return;
        const o = _radOpts.find((x) => String(x.id) === optionId);
        nuiCallback('radialSelect', { id: optionId });
        // An option with a page of its own keeps the wheel up: Lua answers with the page, or a close.
        if (o && o.keep) { _radWaitPage = true; return; }
        uiRadialHide();
    };

    // ---- The mouse: aim by the angle from the centre, anywhere on screen ----
    radialEl.addEventListener('mousemove', function(e) {
        if (!_radialOpen) return;
        if (_radDuo && !_radPage) { radDuoMouse(e.clientX, e.clientY); return; }
        if (!_radPage && radEmpty()) return;
        const dx = e.clientX - window.innerWidth / 2;
        const dy = e.clientY - window.innerHeight / 2;
        if (Math.hypot(dx, dy) < RAD.dead * _radScale) { radNeutral(); return; }
        _radByRight = false;
        radStopRest();
        // A page's slabs are not a ring: the mouse picks the nearest one to where it points.
        if (_radPage) radSeatPoint(dx / _radScale, dy / _radScale);
        else radAim(Math.atan2(dy, dx) * 180 / Math.PI);
    });
    radialEl.addEventListener('click', function(e) {
        if (e.button === 0) radUse();
    });
    // Right-click: back from a page, else close.
    radialEl.addEventListener('contextmenu', function(e) {
        e.preventDefault();
        if (!_radialOpen) return;
        if (_radPage) radBack();
        else nuiCallback('radialClose', {});
    });

    /** Two wheels: the mouse aims the wheel it is over, by its angle from that wheel's centre, and
     *  takes the aim from the other as a stick does. Off both it changes nothing: Lua leaves the
     *  cursor in the screen's middle, between them, and a stray move there must not aim anything. */
    function radDuoMouse(x, y) {
        if (!_hk) return;
        const off = RAD.duoX * _radScale;
        const cy = window.innerHeight / 2;
        const wheels = [['act', window.innerWidth / 2 - off], ['items', window.innerWidth / 2 + off]];
        for (const [side, cx] of wheels) {
            const dx = x - cx, dy = y - cy;
            const d = Math.hypot(dx, dy) / _radScale;
            if (d > RAD.rOut + RAD.lift) continue;
            if (side === 'act' && radEmpty()) return;
            radTake(side);
            if (d < RAD.dead) {
                if (side === 'act') radNeutral(); else hkNeutral();
                return;
            }
            const deg = Math.atan2(dy, dx) * 180 / Math.PI;
            if (side === 'items') { hkSelect(radIndexAt(deg, _hk.opts.length)); return; }
            _radByRight = false;
            radStopRest();
            radAim(deg);
            return;
        }
    }

    // ---- The pad's sticks (the 'radial' scope's onAnalog, below) ----

    /** A stick's angle (degrees, clockwise from 3 o'clock). Up is +y on the pad and down on the page. */
    function radStickDeg(x, y) {
        return Math.atan2(-y, x) * 180 / Math.PI;
    }

    // TWO WHEELS, ONE STICK IN CONTROL: whichever is pushed first.
    // The first stick pushed past RAD.padAim takes control of its wheel — both on the same frame, the
    // one pushed further. The other stick is ignored until the controlling one is back under
    // RAD.padRest and the other is pushed past RAD.padAim: then control swaps, and the wheel it left
    // goes neutral (radTake). The actions wheel goes neutral when its stick is let go, as the one wheel
    // does; the hotkeys wheel keeps its aim, so the right thumb can come off the stick onto A.
    // "No actions available" takes no control: the left stick does nothing then.
    function radDuoAnalog(a) {
        if (!_hk) return;
        const mag = {
            act: radEmpty() ? 0 : Math.hypot(a.x, a.y),
            items: Math.hypot(a.rx || 0, a.ry || 0),
        };
        if (!_radCtl) {
            if (mag.act > RAD.padAim || mag.items > RAD.padAim) radTake(mag.act >= mag.items ? 'act' : 'items');
        } else {
            const other = _radCtl === 'act' ? 'items' : 'act';
            if (mag[_radCtl] < RAD.padRest && mag[other] > RAD.padAim) radTake(other);
        }

        if (_radCtl === 'items') {
            if (mag.items > RAD.padAim) hkSelect(radIndexAt(radStickDeg(a.rx, a.ry), _hk.opts.length));
            return;
        }
        if (_radCtl !== 'act') return;
        if (mag.act > RAD.padAim) {
            radStopRest();
            radAim(radStickDeg(a.x, a.y));
        } else if (mag.act < RAD.padRest) {
            if (_radSel >= 0 && !_radRest) {
                _radRest = setTimeout(function() { _radRest = null; radNeutral(); }, RAD.padRestMs);
            }
        } else {
            radStopRest();
        }
    }

    function radAnalog(a) {
        if (!_radialOpen) return;
        if (_radDuo && !_radPage) { radDuoAnalog(a); return; }
        if (!_radPage && radEmpty()) return;
        const lm = Math.hypot(a.x, a.y);
        const rm = Math.hypot(a.rx || 0, a.ry || 0);
        const right = rm > lm;
        const m = right ? rm : lm;
        if (m > RAD.padAim) {
            radStopRest();
            _radByRight = right;
            // Up is +y on the pad and down on the page.
            const deg = Math.atan2(-(right ? a.ry : a.y), right ? a.rx : a.x) * 180 / Math.PI;
            if (_radPage) radSeatAngle(deg); else radAim(deg);
        } else if (m < RAD.padRest) {
            if (_radSel >= 0 && !_radByRight && !_radRest) {
                _radRest = setTimeout(function() { _radRest = null; radNeutral(); }, RAD.padRestMs);
            }
        } else {
            radStopRest();
        }
    }

    // ---- The keyboard (the scope's onKey, below; Escape is the listener further down) ----
    function radKey(e) {
        if (_radPage) {
            const dir = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' }[e.key];
            if (dir) { radSeatStep(dir); e.preventDefault(); }
            else if (e.key === 'Enter' || e.key === ' ') { radUse(); e.preventDefault(); }
            else if (e.key === 'Backspace') { radBack(); e.preventDefault(); }
            return;
        }
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { radStep(1); e.preventDefault(); }
        else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { radStep(-1); e.preventDefault(); }
        else if (e.key === 'Enter' || e.key === ' ') { radUse(); e.preventDefault(); }
    }

    // ---- The Seats page, inside the wheel ----
    //
    // The vehicle's seats as slabs laid out like the car round the disc: two to a row, the driver's
    // side on the left, front at the top; one behind another on a bike. client/seats.lua sends
    // { title, inline, seats: [{ seat, label, row, col, state, turret }] }, state 'free' | 'occupied'
    // | 'you'. Aim as on the ring (the mouse at the nearest slab, a stick by its angle, the D-pad and
    // arrows by direction), lifted out with the beam joined to it. Only a free seat can be picked; the
    // pill says what the others are. Back (B, right-click, Backspace) is the first page again.

    /** Design px (the 560 box): a slab, the two columns either side of the centre, the lift. */
    const SEAT = { w: 212, h: 74, hSmall: 56, x: 214, bikeY: 172, lift: 14, beamIn: 92 };
    const SEAT_WORD = { free: 'Free', occupied: 'Occupied', you: 'You' };
    const SEAT_DESC = { free: 'Free · move here', occupied: 'Occupied', you: 'Your seat' };

    function radSeatWord(s) { return (SEAT_WORD[s.state] || '') + (s.turret ? ' · turret' : ''); }
    function radSeatDesc(s) { return (SEAT_DESC[s.state] || '') + (s.turret ? ' · turret' : ''); }

    /** Lay the slabs out and draw them, in place of whatever the page showed before. */
    function radSeatsBuild() {
        const wheel = _radRoot && _radRoot.querySelector('.rad-wheel');
        if (!wheel) return;
        _radSeatEls.forEach((el) => el.remove());
        _radSeatEls = [];
        _radSeatPos = [];
        const d = _radPage.data;
        const seats = d.seats || [];
        if (!seats.length) return;
        const rows = Math.max.apply(null, seats.map((s) => s.row)) + 1;
        const h = rows > 4 ? SEAT.hSmall : SEAT.h;
        // Rows centred on the disc; a car's two rows clear it, a bus's eight fit above the pill.
        const gap = d.inline ? (rows > 1 ? (2 * SEAT.bikeY) / (rows - 1) : 0)
                  : (rows <= 1 ? 0 : rows === 2 ? 128 : Math.min(96, 470 / (rows - 1)));
        seats.forEach((s) => {
            const x = d.inline ? 0 : (s.col === 0 ? -SEAT.x : SEAT.x);
            const y = rows > 1 ? (s.row - (rows - 1) / 2) * gap : 0;
            const len = Math.hypot(x, y) || 1;
            const el = radDiv('rad-seat ' + s.state, wheel);
            el.style.left = (RAD.C + x - SEAT.w / 2).toFixed(1) + 'px';
            el.style.top = (RAD.C + y - h / 2).toFixed(1) + 'px';
            el.style.width = SEAT.w + 'px';
            el.style.height = h + 'px';
            // Lifted straight away from the centre when aimed, as a ring slab is.
            el.style.setProperty('--lx', (SEAT.lift * x / len).toFixed(1) + 'px');
            el.style.setProperty('--ly', (SEAT.lift * y / len).toFixed(1) + 'px');
            radIcon(radDiv('rad-seat-icon', el), 'seat', s.label);
            const text = radDiv('rad-seat-text', el);
            radDiv('rad-seat-name', text).textContent = s.label;
            radDiv('rad-seat-state', text).textContent = radSeatWord(s);
            _radSeatEls.push(el);
            _radSeatPos.push({ x: x, y: y, a: Math.atan2(y, x) * 180 / Math.PI });
        });
    }

    /** The beam from the disc's edge to the aimed slab: a wedge, wider at the slab. */
    function radSeatBeam(p) {
        const len = Math.hypot(p.x, p.y) || 1;
        const ux = p.x / len, uy = p.y / len, nx = -uy, ny = ux;
        const ex = p.x + SEAT.lift * ux, ey = p.y + SEAT.lift * uy;
        const pts = [
            [RAD.C + ux * SEAT.beamIn + nx * 7, RAD.C + uy * SEAT.beamIn + ny * 7],
            [RAD.C + ex + nx * 18, RAD.C + ey + ny * 18],
            [RAD.C + ex - nx * 18, RAD.C + ey - ny * 18],
            [RAD.C + ux * SEAT.beamIn - nx * 7, RAD.C + uy * SEAT.beamIn - ny * 7],
        ];
        return 'M' + pts.map((q) => q[0].toFixed(1) + ' ' + q[1].toFixed(1)).join(' L') + ' Z';
    }

    /** Aim at seat i (the page's own radSelect): lifted, the beam, the pill, the disc. */
    function radSeatSelect(i) {
        if (!_radPage || !_radRoot) return;
        const n = _radSeatEls.length;
        if (!n || i < 0 || i >= n || i === _radSel) return;
        if (_radSel >= 0 && _radSeatEls[_radSel]) _radSeatEls[_radSel].classList.remove('on');
        _radSel = i;
        _radSeatEls[i].classList.add('on');
        const s = _radPage.data.seats[i];
        _radRoot.classList.remove('aim-free', 'aim-you', 'aim-occupied');
        _radRoot.classList.add('chosen', 'aim-' + s.state);
        _radBeam.setAttribute('d', radSeatBeam(_radSeatPos[i]));
        radIcon(_radHero, 'seat', s.label);
        _radName.textContent = s.label;
        _radDesc.textContent = radSeatDesc(s);
        // The disc fills for each new aim, as on the ring (css keeps it empty unless the seat is free).
        _radFill.style.transition = 'none';
        _radFill.classList.remove('full');
        void _radFill.offsetHeight;
        _radFill.style.transition = '';
        _radFill.classList.add('full');
    }

    /** The mouse, in design px from the centre: the nearest slab. */
    function radSeatPoint(dx, dy) {
        let best = -1, bestD = Infinity;
        _radSeatPos.forEach((p, i) => {
            const d = Math.hypot(p.x - dx, p.y - dy);
            if (d < bestD) { bestD = d; best = i; }
        });
        if (best >= 0) radSeatSelect(best);
    }

    /** A stick's angle (degrees, clockwise from 3 o'clock): the slab nearest that way round. */
    function radSeatAngle(deg) {
        let best = -1, bestD = Infinity;
        _radSeatPos.forEach((p, i) => {
            const d = Math.abs((((deg - p.a) % 360) + 540) % 360 - 180);
            if (d < bestD) { bestD = d; best = i; }
        });
        if (best >= 0) radSeatSelect(best);
    }

    /** The D-pad and arrows: the nearest slab that way. From neutral, your own seat first. */
    function radSeatStep(dir) {
        if (!_radPage || !_radSeatPos.length) return;
        _radByRight = false;
        radStopRest();
        if (_radSel < 0) {
            const mine = _radPage.data.seats.findIndex((s) => s.state === 'you');
            radSeatSelect(mine >= 0 ? mine : 0);
            return;
        }
        const at = _radSeatPos[_radSel];
        let best = -1, bestScore = Infinity;
        _radSeatPos.forEach((p, i) => {
            if (i === _radSel) return;
            const dx = p.x - at.x, dy = p.y - at.y;
            const ahead = dir === 'up' ? -dy : dir === 'down' ? dy : dir === 'left' ? -dx : dx;
            if (ahead <= 0.5) return;
            // Straight on counts most; off to the side costs twice as much.
            const side = (dir === 'up' || dir === 'down') ? Math.abs(dx) : Math.abs(dy);
            const score = ahead + side * 2;
            if (score < bestScore) { bestScore = score; best = i; }
        });
        if (best >= 0) radSeatSelect(best);
    }

    /** Use on the page: a free seat moves you (Lua closes the wheel); the others do nothing. */
    function radSeatPick() {
        if (!_radialOpen || !_radPage || _radSel < 0) return;
        const s = _radPage.data.seats[_radSel];
        if (!s || s.state !== 'free') return;
        nuiCallback('radialPagePick', { page: _radPage.id, value: s.seat });
        uiRadialHide();
    }

    /** Back to the first page. Lua sends it as it is now (uiRadialShow). */
    function radBack() {
        if (_radialOpen) nuiCallback('radialBack', {});
    }

    /** Lua: show a page in the ring's place, the disc and the pill kept. Only 'seats' exists. */
    function uiRadialPage(d) {
        if (!_radialOpen || !_radRoot || !d || d.page !== 'seats') return;
        radNeutral();   // the first page's aim (Seats itself) goes with it
        radStopRest();
        _radByRight = false;
        _radWaitPage = false;
        _radSlabs.forEach((el) => el.remove());
        _radSlabs = [];
        _radBeam.setAttribute('d', '');
        // Two wheels: the page has the screen to itself — the hotkeys go, and the page stands in the
        // middle, where the mouse aims a page from. Back draws both again (uiRadialShow).
        if (_hk) {
            hkNeutral();
            _hk.root.classList.add('gone');
            _radRoot.classList.remove('rad-left');
        }
        _radCtl = null;
        _radPage = { id: d.page, data: d.data || { seats: [] } };
        _radRoot.classList.add('paged');
        _radName.textContent = 'Choose a seat';
        _radDesc.textContent = '';
        radSeatsBuild();
    }

    /** Lua: the page's data changed (someone got in or out). States change in place, the aim stays;
     *  a different number of seats is drawn afresh. */
    function uiRadialPageUpdate(d) {
        if (!_radialOpen || !_radPage || !d || d.page !== _radPage.id || !d.data) return;
        const seats = d.data.seats || [];
        if (seats.length !== _radSeatEls.length) {
            const aimed = _radSel >= 0 ? _radPage.data.seats[_radSel].seat : null;
            radNeutral();
            _radPage.data = d.data;
            radSeatsBuild();
            const i = seats.findIndex((s) => s.seat === aimed);
            if (i >= 0) radSeatSelect(i);
            return;
        }
        _radPage.data = d.data;
        seats.forEach((s, i) => {
            const el = _radSeatEls[i];
            el.classList.remove('free', 'occupied', 'you');
            el.classList.add(s.state);
            const word = el.querySelector('.rad-seat-state');
            if (word) word.textContent = radSeatWord(s);
        });
        if (_radSel >= 0) {
            const s = seats[_radSel];
            _radRoot.classList.remove('aim-free', 'aim-you', 'aim-occupied');
            _radRoot.classList.add('aim-' + s.state);
            _radDesc.textContent = radSeatDesc(s);
        }
    }

    // ========================================
    // CANCEL (from Lua side)
    // ========================================

    function uiCancel(data) {
        const id = data.id;
        // Cancel whichever component is active. The radial is absent on purpose — it is not a
        // blocking component and has no result id to cancel against; closing it is
        // radialClose from the Lua side.
        //
        // A CANCEL IS NOT AN ANSWER: the skill check and the alert answer null, which Lua reads as
        // 'cancelled'. A bar and a confirm answer false, which reads the same.
        // `why`: an interruption (UI.Interrupt), shown on the bar before it goes; none, a plain cancel.
        if (_progressId === id) clearProgressBar(false, typeof data.why === 'string' ? data.why : null);
        if (_inputId === id) window._uiInputCancel();
        if (_skillId === id) finishSkillCheck(null);
        if (_alertId === id) closeAlert(null);
        if (_confirmId === id) window._uiConfirmNo();
    }

    // ========================================
    // KEYBOARD — Escape closes active component
    // ========================================

    document.addEventListener('keydown', function(e) {
        if (e.key !== 'Escape') return;

        // Close in priority order: radial, input, confirm/alert.
        //
        // The radial tells Lua rather than closing itself, because Lua owns the open/closed state
        // and the NUI focus that goes with it — closing here alone would leave the cursor freed
        // and the key still thinking the wheel was up.
        //
        // stopIMMEDIATEPropagation, not stopPropagation: the router's key-scope listener is on this
        // same document node, and same-node listeners still run after stopPropagation, so one Escape
        // would also close the panel underneath. This file's listeners register before main.js's.
        if (_radialOpen) { nuiCallback('radialClose', {}); e.stopImmediatePropagation(); return; }
        if (_inputId != null) { window._uiInputCancel(); e.stopImmediatePropagation(); return; }
        if (_confirmId != null) { window._uiConfirmNo(); e.stopImmediatePropagation(); return; }
        if (_alertId != null) { window._uiAlertOk(); e.stopImmediatePropagation(); return; }
    });

    // Enter key submits input dialog
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && _inputId != null) {
            // Don't submit if focus is on textarea
            if (document.activeElement && document.activeElement.tagName === 'TEXTAREA') return;
            window._uiInputSubmit();
        }
    });

    // ========================================
    // CONTROLLER — the dialogs answer a pad too
    // ========================================
    //
    // Input, Alert, Confirm and SkillCheck need a key scope, or the pad driver stays off. One scope for
    // all four, above everything but the creator (a dialog never opens over the creator: ui.lua's
    // FocusScreenUp refuses it). select = OK / yes / submit; back = cancel. The skill check takes only
    // 'back' here: its dot is the RIGHT STICK, which arrives as uiSkillStick, not as nav. (It takes no
    // NUI focus, but stays in this scope: the scope is what runs the pad driver, and with it the B to
    // back out.)
    // Its onKey does nothing on purpose: this file's own listeners handle Escape and Enter, and a key
    // scope that is open consumes the key — so nothing reaches the panel underneath a dialog.
    NuiRouter.registerKeyScope({
        name: 'ui-dialog',
        priority: 1,
        isOpen: () => _inputId != null || _confirmId != null || _alertId != null || _skillId != null,
        onKey: () => {},
        onNav: (nav) => {
            if (_skillId != null) {
                if (nav === 'back') finishSkillCheck(null);
                return;
            }
            if (_inputId != null) {
                inputPadNav(nav);   // the ring: fields typed on whip's keyboard, then Submit
                return;
            }
            if (_confirmId != null) {
                if (nav === 'select') window._uiConfirmYes();
                else if (nav === 'back') window._uiConfirmNo();
                return;
            }
            if (_alertId != null && (nav === 'select' || nav === 'back')) window._uiAlertOk();
        },
        // The hint strip, on a controller (controller.js): what onNav above does, for the dialog up —
        // in the dialog's own words, read off its buttons ("Sell" / "Keep", not "Yes" / "No").
        padHints: () => {
            const said = (overlay, cls, fallback) => {
                const btn = overlay.querySelector(cls);
                return (btn && btn.textContent.trim()) || fallback;
            };
            if (_skillId != null) return [['b', 'Cancel']];
            if (_inputId != null) {
                // A says what it does to the thing ringed (inputPadNav).
                const { btns, all } = inputPadItems();
                const el = all[_inputPadAt];
                const cancel = ['b', said(inputOverlay, '.ui-btn-cancel', 'Cancel')];
                const a = !el ? 'Submit'
                    : btns.indexOf(el) >= 0 ? (el.textContent.trim() || 'OK')
                    : el.tagName === 'SELECT' ? 'Next choice'
                    : el.type === 'checkbox' ? 'Tick' : 'Type';
                return [['dpad', 'Choose'], ['a', a], cancel];
            }
            if (_confirmId != null) {
                return [['a', said(alertOverlay, '.ui-btn-confirm', 'Confirm')],
                        ['b', said(alertOverlay, '.ui-btn-cancel', 'Cancel')]];
            }
            if (_alertId != null) return [['a', said(alertOverlay, '.ui-btn-confirm', 'OK')]];
            return [];
        },
    });

    // THE RADIAL ON A PAD: a held D-pad down opens it, B closes it; the sticks aim, A uses, D-pad
    // left / right step (radAnalog above). Closing asks Lua,
    // which owns the open state, as Escape does. onKey takes the arrows and Enter; Escape is the
    // listener above.
    NuiRouter.registerKeyScope({
        name: 'radial',
        priority: 2,
        isOpen: () => _radialOpen,
        onKey: radKey,
        onNav: (nav) => {
            // A page: B goes back, and all four directions move (D-pad down opened the wheel, but a
            // page is reached with A, so nothing is still held).
            if (_radPage) {
                if (nav === 'back') radBack();
                else if (nav === 'select') radUse();
                else if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') radSeatStep(nav);
                return;
            }
            if (nav === 'back') nuiCallback('radialClose', {});
            else if (nav === 'select') radUse();
            else if (nav === 'left') radStep(-1);
            else if (nav === 'right') radStep(1);
        },
        analog: true,
        onAnalog: radAnalog,
        padHints: () => {
            if (_radPage) return [['ls', 'Aim'], ['a', 'Move here'], ['b', 'Back']];
            if (_radDuo) {
                return radEmpty() ? [['rs', 'Items'], ['a', 'Use'], ['b', 'Close']]
                    : [['ls', 'Actions'], ['rs', 'Items'], ['a', 'Use'], ['b', 'Close']];
            }
            return radEmpty() ? [['b', 'Close']] : [['ls', 'Aim'], ['a', 'Use'], ['b', 'Close']];
        },
    });

    // ========================================
    // Expose to main.js message handler
    // ========================================

    window.uiNotify         = uiNotify;
    window.uiProgressBar    = uiProgressBar;
    window.uiInput          = uiInput;
    window.uiSkillCheck     = uiSkillCheck;
    window.uiSkillStick     = uiSkillStick;
    window.uiSkillMouse     = uiSkillMouse;
    window.uiAlert          = uiAlert;
    window.uiConfirm        = uiConfirm;
    window.uiShowText       = uiShowText;
    window.uiHideText       = uiHideText;
    window.uiInterrupted    = uiInterrupted;
    window.uiRadialShow     = uiRadialShow;
    window.uiRadialHide     = uiRadialHide;
    window.uiRadialPage     = uiRadialPage;
    window.uiRadialPageUpdate = uiRadialPageUpdate;
    window.uiObjective      = uiObjective;
    window.uiCancel         = uiCancel;

})();


// DELEGATED ACTIONS — the modal buttons (input/alert/confirm) built by the renderers above.
// Same pattern as creator.js's bindCreatorActions; the radial wheel listens on its own layer
// (§5) and needs nothing here.
(function bindUiActions() {
    const root = document.getElementById('ui-layer');
    const CLICK = new Map([
        ['_uiInputCancel', () => window._uiInputCancel()],
        ['_uiInputSubmit', () => window._uiInputSubmit()],
        ['_uiAlertOk',     () => window._uiAlertOk()],
        ['_uiConfirmNo',   () => window._uiConfirmNo()],
        ['_uiConfirmYes',  () => window._uiConfirmYes()],
    ]);
    root.addEventListener('click', (e) => {
        const el = e.target.closest('[data-action]');
        if (!el) return;
        const fn = CLICK.get(el.dataset.action);
        if (fn) fn(el);
    });
})();

// ROUTER REGISTRATION — see router.js's header. IIFE file; the public uiXxx functions live
// on window and are resolved there at dispatch time.
NuiRouter.register('uiNotify', (d) => uiNotify(d));
NuiRouter.register('uiProgressBar', (d) => uiProgressBar(d));
NuiRouter.register('uiInput', (d) => uiInput(d));
NuiRouter.register('uiSkillCheck', (d) => uiSkillCheck(d));
NuiRouter.register('uiSkillStick', (d) => uiSkillStick(d));
NuiRouter.register('uiSkillMouse', (d) => uiSkillMouse(d));
NuiRouter.register('uiAlert', (d) => uiAlert(d));
NuiRouter.register('uiConfirm', (d) => uiConfirm(d));
NuiRouter.register('uiShowText', (d) => uiShowText(d));
NuiRouter.register('uiHideText', () => uiHideText());
NuiRouter.register('uiInterrupted', (d) => uiInterrupted(d));   // a mode stopped by something not chosen (§9)
NuiRouter.register('uiCancel', (d) => uiCancel(d));
// Radial menu — a mode, not a dialog, so show/hide rather than a single blocking call
NuiRouter.register('uiRadialShow', (d) => uiRadialShow(d));
NuiRouter.register('uiRadialHide', () => uiRadialHide());
NuiRouter.register('uiRadialPage', (d) => uiRadialPage(d));             // a second page (Seats)
NuiRouter.register('uiRadialPageUpdate', (d) => uiRadialPageUpdate(d));
NuiRouter.register('uiObjective', (d) => uiObjective(d));                 // a job's objective card (§10)
// A clean screen (client/clean_screen.lua): every layer of the page hidden for a recording, but what the
// one holding it shows itself (the Camera Creator's, css/ui.css). Hidden, not shut: they keep working.
NuiRouter.register('cleanScreen', (d) => document.documentElement.classList.toggle('whip-clean', !!(d && d.on)));
// The mouse turning a camera on Enhanced (client/focus.lua Focus.mouseLook): the page takes no mouse and hides its cursor.
NuiRouter.register('mouseLook', (d) => document.documentElement.classList.toggle('whip-mouse-look', !!(d && d.on)));
