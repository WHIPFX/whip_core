import { NuiRouter } from './router.js';
import { capsuleMode } from './capsule.js';

/* ========================================
   STATUS HUD — Data-Driven Arc Ring Gauges
   Stats are registered dynamically from server
   definitions. No hardcoded stat elements.
   ======================================== */

const statusHud = document.getElementById('status-hud');

// THE GAUGES GO IN #statusHudStats, NOT IN THE CAPSULE ITSELF. registerHudStats() clears its
// container with `innerHTML = ''` on every stat-definition push, and the capsule also holds the
// composer's input, its counter, the mode bubble and the notification row (static markup in
// index.html). Its own wrapper means the wipe only reaches the gauges.
const statusHudStats = document.getElementById('statusHudStats');

// Arc geometry — 270° arc on r=18 circle (circumference = 2*PI*18)
const SH_ARC = 84.82;
const SH_CIRC = 113.1;

// Registry of rendered stats: { [name]: { el, arc, config } }
const _hudRegistry = {};

// ============================================
// Color Helpers
// ============================================

/** The colour a gauge gets when its registration names none. */
const DEFAULT_STAT_COLOR = '#ffffff';

/** A usable #rrggbb, whatever arrived. `hud.color` is optional in both Lua registries and passed
 *  through as-is; a throw here would blank every gauge registered after it. */
function statColor(hex) {
    return (typeof hex === 'string' && /^#?[0-9a-fA-F]{6}$/.test(hex))
        ? (hex.charAt(0) === '#' ? hex : '#' + hex)
        : DEFAULT_STAT_COLOR;
}

/** Convert hex color (#rrggbb) to rgba components */
function hexToRgb(hex) {
    hex = statColor(hex).replace('#', '');
    return {
        r: parseInt(hex.substring(0, 2), 16),
        g: parseInt(hex.substring(2, 4), 16),
        b: parseInt(hex.substring(4, 6), 16),
    };
}

/** Set CSS custom properties for a stat's color on its element */
function applyStatColor(el, hex) {
    hex = statColor(hex);
    const c = hexToRgb(hex);
    el.style.setProperty('--stat-color', hex);
    el.style.setProperty('--stat-glow', `rgba(${c.r}, ${c.g}, ${c.b}, 0.45)`);
    el.style.setProperty('--stat-haze', `rgba(${c.r}, ${c.g}, ${c.b}, 0.15)`);
}

// ============================================
// Build Armour Critical Icon (cracked shield)
// ============================================

/** Parse pipe-delimited SVG paths into cracked shield icon markup */
function buildCriticalIconSvg(pathData) {
    const paths = pathData.split('|');
    let svg = `<svg viewBox="0 0 24 24">`;
    // First path = filled shield
    svg += `<path fill="currentColor" d="${paths[0]}"/>`;
    // Remaining paths = crack lines
    const widths = [1.1, 0.8, 0.8, 0.8, 0.7, 0.7, 0.6];
    const opacities = [0.65, 0.55, 0.55, 0.55, 0.5, 0.5, 0.45];
    for (let i = 1; i < paths.length; i++) {
        const w = widths[Math.min(i - 1, widths.length - 1)];
        const o = opacities[Math.min(i - 1, opacities.length - 1)];
        svg += `<path fill="none" stroke="rgba(0,0,0,${o})" stroke-width="${w}" stroke-linecap="round" d="${paths[i]}"/>`;
    }
    svg += `</svg>`;
    return svg;
}

// ============================================
// Build Stat Element — shared by player + vehicle
// ============================================

function buildStatElement(el, config) {
    if (config.hideWhenEmpty) el.classList.add('hide-when-empty');
    if (config.showAboveZero) el.classList.add('show-above-zero');
    // The other way round: a reserve that is usually full, shown only while it is not (oxygen, under water).
    if (config.showBelowFull) el.classList.add('show-below-full');
    // Moves between readings at a steady speed rather than step by step (updateStat says how).
    if (config.glide) el.classList.add('glide');

    /* Collapses the gauge by default, exactly like show-above-zero. Without a class here the
       element has nothing to collapse it — `.sh-stat` reveals itself through its own animation —
       so adding and removing `.visible` did nothing at all and the gauge was permanently on. */
    if (config.showWhenPresent) el.classList.add('show-when-present');
    if (config.iconCritical) el.classList.add('has-critical-icon');

    if (config.iconOnly) {
        el.classList.add('icon-only');
        el.classList.add('inactive'); // start inactive
        // Ring SVG still rendered for sizing (67px container) but hidden via CSS
        el.innerHTML = `
            <svg class="sh-ring" viewBox="0 0 48 48">
                <circle class="sh-track" cx="24" cy="24" r="18"/>
            </svg>
            <div class="sh-icon">
                <svg viewBox="0 0 24 24"><path fill="currentColor" d="${config.icon}"/></svg>
            </div>
        `;
    } else {
        // THE DISC CARRIES THE VALUE, not the arc (the reasoning is on the --sh-disc-* tokens in
        // status-hud.css). .sh-fill rises with the value and the glyph above it flips to ink
        // through mix-blend-mode, the 3D interaction badge's E-pressed inversion run slowly.
        //
        // THE ARC SVG STAYS IN THE MARKUP, hidden by CSS: updateStat still writes to .sh-arc,
        // and bringing the arc back is then a stylesheet edit.
        el.innerHTML = `
            <svg class="sh-ring" viewBox="0 0 48 48">
                <circle class="sh-track" cx="24" cy="24" r="18"/>
                <circle class="sh-arc" cx="24" cy="24" r="18"/>
            </svg>
            <div class="sh-disc"><div class="sh-fill"></div></div>
            <div class="sh-icon sh-icon-normal">
                <svg viewBox="0 0 24 24"><path fill="currentColor" d="${config.icon}"/></svg>
            </div>
            ${config.iconCritical ? `<div class="sh-icon sh-icon-critical">${buildCriticalIconSvg(config.iconCritical)}</div>` : ''}
            ${config.iconRadio ? `<div class="sh-icon sh-icon-radio"><svg viewBox="0 0 24 24"><path fill="currentColor" d="${config.iconRadio}"/></svg></div>` : ''}
        `;
    }
}

// ============================================
// Register Stats — generates DOM elements
// ============================================

function registerHudStats(stats) {
    if (!statusHudStats || !stats) return;

    // Clear existing elements
    statusHudStats.innerHTML = '';
    for (const key in _hudRegistry) delete _hudRegistry[key];

    // Stats arrive pre-sorted by order from server
    stats.forEach((config, index) => {
        const name = config.name;
        const delay = 0.08 + index * 0.06;

        // Create stat container
        const el = document.createElement('div');
        el.className = 'sh-stat';
        el.dataset.stat = name;
        el.style.animationDelay = delay + 's';

        buildStatElement(el, config);
        applyStatColor(el, config.color);
        statusHudStats.appendChild(el);

        _hudRegistry[name] = {
            el: el,
            arc: el.querySelector('.sh-arc'),
            // Looked up ONCE here, like the arc, rather than queried on every update. The Lua
            // side polls at 200ms across five gauges, so a querySelector per stat per tick is
            // 25 lookups a second for a node that never changes.
            fill: el.querySelector('.sh-fill'),
            config: config,
        };
    });

    // A rebuild makes a fresh voice gauge; it must come back lit if the player is mid-sentence.
    applyVoiceTalking();
    // ...and the black skin's row is spaced again for the new count.
    layoutUnderFrame();
}

// ============================================
// Voice gauge — lit while the player transmits
// ============================================

/* Kept HERE rather than on the element, because registerHudStats throws the elements away on
   every rebuild (see the note at the top). Set by stats.lua's SetVoiceTalking (a voice resource's
   push-to-talk); the look is .sh-stat.talking in status-hud.css — and .talking.radio (orange, the
   radio icon) while talking on the radio. */
let _voiceTalking = false;
let _voiceMode = null;

function applyVoiceTalking() {
    const reg = _hudRegistry.voice;
    if (!reg) return;
    reg.el.classList.toggle('talking', _voiceTalking);
    reg.el.classList.toggle('radio', _voiceTalking && _voiceMode === 'radio');
}

function setVoiceTalking(on, mode) {
    _voiceTalking = !!on;
    _voiceMode = mode === 'radio' ? 'radio' : null;
    applyVoiceTalking();
}

// ============================================
// Update a Single Stat
// ============================================

function updateStat(name, percent, registry) {
    registry = registry || _hudRegistry;
    const reg = registry[name];
    if (!reg) return;

    percent = Math.max(0, Math.min(100, percent));
    const el = reg.el;
    const config = reg.config;

    // Icon-only mode (boolean indicators like engine on/off)
    if (config.iconOnly) {
        if (percent > 0) {
            el.classList.add('active');
            el.classList.remove('inactive');
        } else {
            el.classList.remove('active');
            el.classList.add('inactive');
        }
        return;
    }

    // Ring mode — set arc fill.
    // Still written even though the arc is hidden: it costs one style write, and it means
    // switching back to the arc treatment is a CSS change with no JS to remember.
    const arc = reg.arc;
    const fillLen = SH_ARC * (percent / 100);
    arc.style.strokeDasharray = fillLen + ' ' + SH_CIRC;

    // INVERT — the disc fills white IN PROPORTION TO THE VALUE. Full is a white puck with a
    // dark glyph; empty is a dark disc with a white one.
    //
    // White is the affirmative state, as on html/interact3d/badge.html (white when E acts on it).
    //
    // A PLAIN PERCENTAGE: any geometry help a disc needs belongs in the CSS alone (.sh-disc in
    // status-hud.css).
    //
    // GLIDE (a stat's `glide`, e.g. oxygen): a stat the server moves on its tick arrives a step a
    // second, and the fill's own 0.6 s ease would run each step and then stand still. A gliding gauge goes to each reading,
    // in a straight line, over the time readings have been coming apart (averaged, so a late one does not lurch
    // it) — still on the way to one when the next lands, so it moves the whole time. Set BEFORE the level: the
    // transition this level starts takes the time set with it. A first step after a long still (full, then
    // under water) is given the last gap, or a second: the server's tick.
    if (config.glide && percent !== reg.glideAt) {
        const now = performance.now();
        if (reg.glideAt !== undefined) {
            const since = now - reg.glideTime;
            const gap = since > 0 && since < 2500 ? since : (reg.glideGap || 1000);
            reg.glideGap = reg.glideGap ? reg.glideGap * 0.6 + gap * 0.4 : gap;
            el.style.setProperty('--sh-glide', Math.round(Math.max(150, Math.min(2000, reg.glideGap))) + 'ms');
        }
        reg.glideAt = percent;
        reg.glideTime = now;
    }
    if (reg.fill) reg.fill.style.height = percent + '%';
    // The black skin's rim reads the level from this (css/hud-skin.css); the classic look ignores it.
    el.style.setProperty('--sh-p', percent);

    // Empty state (0%)
    if (percent <= 0) {
        el.classList.add('empty');
    } else {
        el.classList.remove('empty');
    }

    // showAboveZero — toggle visibility
    if (config.showAboveZero) {
        if (percent > 0) {
            el.classList.add('visible');
        } else {
            el.classList.remove('visible');
        }
    }
    // showBelowFull — the same, against full
    if (config.showBelowFull) el.classList.toggle('visible', percent < 100);

    // Critical state (<20% and >0%) — skipped if noCritical is set
    if (!config.noCritical && percent > 0 && percent < 20) {
        el.classList.add('critical');
        if (config.heartbeat) {
            el.classList.add('heartbeat');
        }
    } else {
        el.classList.remove('critical');
        if (config.heartbeat) {
            el.classList.remove('heartbeat');
        }
    }
}

// ============================================
// Update All Stats (called from Lua 200ms poll)
// ============================================

/* ============================================
   THE STAT-CHANGE INTERRUPT

   While the capsule is showing the composer or a notification, the gauges are hidden — so the
   player cannot see their health while typing, and typing does not pause the game.

   SO A STAT CAN ASK TO INTERRUPT. `interruptDelta` in a stat's hud config is a number of DISPLAY
   PERCENT (the 0-100 the gauge actually draws, not the raw stat range); move by at least that
   much while hidden and that one gauge slides back in for a moment. Absent means never, which is
   why it is opt-in: hunger ticking down by one must not take the screen, and health dropping
   thirty must.

   COMPARED AGAINST WHAT WAS LAST *SHOWN*, NOT WHAT WAS LAST *SENT*. Two points a tick for five
   ticks is a ten-point drop that a tick-to-tick comparison never sees; measuring from the value
   the player last looked at catches the slow bleed and the single big hit with one rule.
   ============================================ */

/** Display percent for each stat as of the last time the gauges were actually on screen. */
const _lastShown = {};

/** How long an interrupting gauge stays before it leaves again. */
const INTERRUPT_MS = 2500;

const _interruptTimers = {};

function interrupt(name) {
    const reg = _hudRegistry[name];
    if (!reg) return;

    reg.el.classList.add('interrupting');

    // Restarted rather than stacked: a stat that keeps moving should keep the gauge up, not
    // queue a second removal that fires while it is still changing.
    if (_interruptTimers[name]) clearTimeout(_interruptTimers[name]);
    _interruptTimers[name] = setTimeout(() => {
        reg.el.classList.remove('interrupting');
        _interruptTimers[name] = null;
    }, INTERRUPT_MS);
}

/** A stat's value as the percent its gauge draws: health's GTA range 100-200 is 0-100%, everything else a
 *  direct percentage of its max. */
function percentOf(config, value) {
    if (config.type === 'vital' && config.max === 200) return Math.max(0, Math.min(100, ((value - 100) / 100) * 100));
    return Math.max(0, Math.min(100, (value / config.max) * 100));
}

function updateStatusHud(data) {
    // NOT GATED ON THE CAPSULE BEING VISIBLE — same rule, same reason as updateVehicleHud
    // below. Lua's change detector records a sent payload as delivered and never repeats it,
    // so an update discarded here while the HUD was hidden (inventory open, player dead) left
    // the rings showing pre-hide values forever once it came back. Updating a hidden capsule
    // costs a few class and attribute writes and keeps the DOM honest.
    //
    // THE SAME APPLIES TO THE OTHER TWO CAPSULE MODES, and for a second reason on top: the
    // interrupt below can only notice a change if the values keep arriving while the gauges are
    // hidden. Gating this on mode would disable the feature and look like it was working.
    if (!statusHud) return;

    const showing = capsuleMode() === 'stats';

    for (const name in _hudRegistry) {
        let value = data[name];
        if (value === undefined) continue;

        const config = _hudRegistry[name].config;
        const percent = percentOf(config, value);

        updateStat(name, percent);

        if (showing) {
            // On screen: what is drawn is what the player has seen. This is the baseline every
            // later comparison is made against.
            _lastShown[name] = percent;
        } else if (config.interruptDelta > 0) {
            const seen = _lastShown[name];
            if (seen !== undefined && Math.abs(percent - seen) >= config.interruptDelta) {
                interrupt(name);
                // The player has now seen this value, so the next interrupt needs another full
                // delta. Without this the gauge would re-trigger on every tick for as long as
                // the stat stayed away from its old value.
                _lastShown[name] = percent;
            }
        }
    }
    // (The black skin's spacing is fixed — see layoutUnderFrame — so nothing else moves when a gauge
    // comes or goes.)
}

// ============================================
// Show / Hide
// ============================================

function showStatusHud() {
    if (statusHud) statusHud.classList.add('visible');
}

function hideStatusHud() {
    if (statusHud) statusHud.classList.remove('visible');
}

/** The HUD's skin (Config.HudSkin, client/hud.lua): 'black' is css/hud-skin.css, anything else the
 *  classic look. */
function setHudSkin(skin) {
    if (statusHud) statusHud.classList.toggle('skin-black', skin === 'black');
    layoutUnderFrame();
}

// ============================================
// A gauge drawn outside the HUD
// ============================================
//
// A page that shows a player's stats (the Player Manager's Current Stats) draws each one as the HUD does: the same
// element (buildStatElement), its colour, and its level by updateStat. A restyled HUD restyles these too. Put each in a
// .sh-copy, with the HUD's skin class on it (hudSkin): the black skin's rules are written for both. Every gauge shows,
// whatever its rule for when the HUD shows it (oxygen only below full, armour faint at 0).

/** One stat's gauge: { el, set(value) }, value in the stat's own units. `def` is a gauge's definition as
 *  registerHudStats takes it, with the stat's type and max. */
export function hudGauge(def) {
    const config = Object.assign({}, def, { hideWhenEmpty: false, showAboveZero: false, showBelowFull: false, showWhenPresent: false });
    const el = document.createElement('div');
    el.className = 'sh-stat';
    el.dataset.stat = config.name;
    buildStatElement(el, config);
    applyStatColor(el, config.color);
    const registry = { [config.name]: { el, arc: el.querySelector('.sh-arc'), fill: el.querySelector('.sh-fill'), config } };
    return { el, set: (value) => updateStat(config.name, percentOf(config, Number(value) || 0), registry) };
}

/** The HUD's skin class now ('skin-black'), or '' for the classic look: for a .sh-copy. */
export function hudSkinClass() {
    return statusHud && statusHud.classList.contains('skin-black') ? 'skin-black' : '';
}

// ============================================
// The black skin: the gauges lined up under the minimap's frame
// ============================================
//
// client/hud_skin.lua sends the frame's outside edge (hudFrameBox: left, right and bottom, as fractions
// of the screen). The box does not depend on the radar being shown, so on foot (no minimap) the row stays
// where it is in a car.
//
// LAID OUT AS SLOTS, at least ROW_SLOTS of them (voice, health, armour, hunger, thirst), so the first
// gauge always sits in the same place whatever is turned on:
//   * ROW_SLOTS discs fill the frame EDGE TO EDGE, the first under its left edge and the last under its
//     right; more always-shown gauges than that (baseGauges: every one but those that show only
//     sometimes, like oxygen or developer mode) fill it at a smaller gap;
//   * fewer leave the slots on the right empty: a gauge that is turned off (hunger off, no voice
//     resource) is simply not in the row, and the ones after it close up, the same way a sometimes gauge
//     joins on the right at the same gap. Nothing before it moves;
//   * the gap under the frame is the same as the gap between them.
// (A full row is centred rather than left-aligned, so a frame too narrow or too wide for the clamped gap
// still holds it in its middle.)
//
// WORKED OUT FROM THE STYLESHEETS' OWN SIZES, NOT MEASURED: getBoundingClientRect inside a zoomed
// element answers in unzoomed coordinates on the game's browser (CEF 103), and #status-hud is zoomed.
// The numbers below are those in status-hud.css and hud-skin.css: a gauge is --sh-ring-size square, its
// visible disc 1.5px in from that (the rim at 4px, its black edge 2.5px outside it).

let _frameBox = null;
const statusHudWrapper = document.getElementById('statusHudWrapper');
const capsuleEl = document.getElementById('statusHudContainer');
const DISC_INSET = 1.5;
const ROW_SLOTS = 5;
let _lastLayout = '';

function cssPx(el, name) {
    return parseFloat(getComputedStyle(el).getPropertyValue(name)) || 0;
}

/** How many gauges are always in the row: every one but those that show only sometimes. Set by the
 *  registration, not by what is showing, so the layout never changes as a sometimes-gauge comes or goes. */
function baseGauges() {
    let n = 0;
    for (const el of statusHudStats.children) {
        if (!el.classList.contains('show-above-zero') && !el.classList.contains('show-when-present')
            && !el.classList.contains('show-below-full')) n++;
    }
    return Math.max(1, n);
}

function layoutUnderFrame() {
    if (!statusHud || !statusHudWrapper || !capsuleEl || !statusHudStats) return;
    if (!_frameBox || !statusHud.classList.contains('skin-black')) {
        if (_lastLayout !== '') {
            _lastLayout = '';
            statusHudWrapper.style.left = '';
            statusHudWrapper.style.bottom = '';
            statusHud.style.removeProperty('--hb-gap');
        }
        return;
    }
    const zoom = parseFloat(getComputedStyle(statusHud).zoom) || 1;
    const W = window.innerWidth, H = window.innerHeight;
    const ring = cssPx(statusHud, '--sh-ring-size') || 67;
    const padX = cssPx(statusHud, '--sh-capsule-pad-x');
    const padY = cssPx(statusHud, '--sh-capsule-pad-y');
    const border = parseFloat(getComputedStyle(capsuleEl).borderLeftWidth) || 0;
    const disc = ring - 2 * DISC_INSET;
    const base = baseGauges();

    // The gap between discs that `k` of them need to fill the frame's width, in the HUD's own px. Kept
    // sensible on an odd frame.
    const width = (_frameBox.right - _frameBox.left) * W / zoom;
    const fill = (k) => k > 1 ? Math.max(2, Math.min(24, (width - k * disc) / (k - 1))) : 0;

    const slots = Math.max(ROW_SLOTS, base);
    const gap = fill(slots);                                                  // between discs (under the frame: below)
    const rowWidth = slots * disc + (slots - 1) * gap;                        // a full row

    // The first disc where centring a full row under the frame puts it.
    const left = _frameBox.left * W / zoom + (width - rowWidth) / 2 - (border + padX + DISC_INSET);
    // Under the frame: the discs take the middle of the room left below it, as much space over them as under them,
    // and never more over them than between them. The room below the frame is only a little taller than a disc, and
    // the whole gap over them pushed their bottoms off the screen at every aspect ratio (16:10 most).
    const room = H - _frameBox.bottom * H - disc * zoom;                     // screen px, over and under the discs
    const discTop = _frameBox.bottom * H + Math.max(0, Math.min(gap * zoom, room / 2));   // screen px
    const capTop = discTop - (border + padY + DISC_INSET) * zoom;            // screen px
    const capHeight = ring + 2 * padY + 2 * border;                          // HUD px
    const bottom = (H - capTop) / zoom - capHeight;

    const key = left.toFixed(2) + ' ' + bottom.toFixed(2) + ' ' + gap.toFixed(2);
    if (key === _lastLayout) return;
    _lastLayout = key;
    statusHud.style.setProperty('--hb-gap', (gap - 2 * DISC_INSET) + 'px');
    statusHudWrapper.style.left = left + 'px';
    statusHudWrapper.style.bottom = bottom + 'px';
}

window.addEventListener('resize', layoutUnderFrame);

// (The vehicle stats are the gauges orbiting the 3D rev dial, drawn by js/vehicle-dial.js from the
// registerVehicleHud / updateVehicleHud messages.)


// ROUTER REGISTRATION — see router.js's header.
NuiRouter.register('registerHudStats', (d) => registerHudStats(d.stats));
NuiRouter.register('showStatusHud', () => showStatusHud());
NuiRouter.register('hideStatusHud', () => hideStatusHud());
NuiRouter.register('setHudSkin', (d) => setHudSkin(d.skin));
NuiRouter.register('hudFrameBox', (d) => {
    if (typeof d.left === 'number' && typeof d.right === 'number' && typeof d.bottom === 'number') {
        _frameBox = { left: d.left, right: d.right, bottom: d.bottom };
        layoutUnderFrame();
    }
});
NuiRouter.register('updateStatusHud', (d) => updateStatusHud(d));
NuiRouter.register('setVoiceTalking', (d) => setVoiceTalking(d.talking, d.mode));