// ============================================
// VEHICLE DIAL — the 3D rev dial, bottom right, while in a vehicle
// ============================================
//
// The vehicle HUD is 3D Clanker's dial, and the vehicle stats are its gauges. The dial is theirs, in js/vehicle_hud/ exactly as
// delivered (createVehicleHud in hud.js; its README is the contract). Model or behaviour changes go to them.
//
// THIS FILE IS THE BRIDGE, and it adds no message of its own:
//   - the numbers: client/vehicle_hud.lua's updateVehicleDials (15 Hz, change-gated: the message is the cost, see
//     there) and vehicleDialRange, sent on getting into a vehicle (its rev range, its kind, and whether it has a dial
//     at all);
//   - ITS KIND (3D Clanker's v6): 'air' for helicopters and planes (flight instruments inside the ring:
//     attitude, airspeed and altitude tapes, the landing gear light), 'boat' (v8: the dial reads engine power, 0 to
//     100%, with F / N / R and the anchor light), else 'car'. The dial draws each from the state fields named in its
//     README;
//   - the gauges orbiting it (up its left side; over its top in an aircraft) are the vehicle stats: the same registerVehicleHud definitions and updateVehicleHud
//     snapshots the capsule was drawn from (client/vehicles.lua), mapped here;
//   - WHEN IT SHOWS: in a vehicle (show/hideVehicleHud, the enter/exit edges in client/vehicles.lua), on a vehicle
//     with a dial (not bicycles or trains), and while the HUD is shown: it follows #status-hud's own
//     fade (a panel open, death, the loading light), which it sits outside of because that layer is zoomed and the
//     dial places itself in window pixels;
//   - /vehiclehud (client/vehicles.lua) switches the whole HUD off for a performance test: vehicleHudEnabled. Off,
//     the dial is disposed (its WebGL context and GPU memory freed, the canvas removed); on, it is built again;
//   - IT MAKES ROOM for another resource's UI in its corner (uiAreas: SetScreenArea, client/hud.lua; Josh, 7 Nov 2026: the
//     phone's notifications peeking up push it up, the phone itself pushes it left, next to it). See makeRoom below.
//
// THE DIAL AND three.js ARE IMPORTED THE FIRST TIME A VEHICLE IS ENTERED, so a player on foot pays nothing; the
// numbers that arrive before it loads are kept and handed over when it does.
import { NuiRouter } from './router.js';
import { BOX } from './vehicle_hud/dial.js';
import { statValueText, statEnds } from './stat-display.js';

const statusHud = document.getElementById('status-hud');

let hud = null, canvas = null, loading = null;
let enabled = true, inVehicle = false, hasDial = true, shown = false, hideTimer = 0;
let room = true;                      // makeRoom found the dial a place on screen clear of the areas
const onResize = () => { if (hud) hud.resize(); };

/* What the dial was last told, kept so a dial that loads late (or reloads) starts from the current picture. */
const state = { rpm: 0, maxRpm: 8, redline: null, speed: 0, units: 'mph', gear: 'N', engine: false, lights: 'off', locked: false, damage: false,
    kind: 'car', pitch: 0, roll: 0, altitude: 0, gearState: 'none', power: 0, anchored: false, skin: null };
/* Its config (Config.VehicleHud): the aircraft horizon, 'ball' or 'flat', and whether cars wear their own GTA
   dashboard's look (dashSkins; 3D Clanker's skins: hud.js setConfig `skins`). */
const dialConfig = { attitude: 'ball', skins: true };

/* WHERE IT SITS, BY KIND (close to the right edge for a car, with room for an aircraft's tape): the dial's centre from the screen's right edge, in dial radii (hud.js setConfig
   `right`; 3D Clanker's default is 1.671). Measured on the real dial at 1080p: a car's or a boat's reaches 1.01 radii
   right of its centre, an aircraft's 1.44 (its altitude tape). An aircraft keeps 1.671, its tape ending 0.23 radii
   (31 px at 1080p) from the edge; a car and a boat come in to end the same 0.23 radii from it. js/vehicle-controls.js
   reads it too, to stand on the dial before the dial is up. */
export const DIAL_RIGHT = { car: 1.242, boat: 1.242, air: 1.671 };
const dialPlace = (kind) => ({ right: DIAL_RIGHT[kind] || DIAL_RIGHT.car });
let rawRpm = 0;                       // GetVehicleCurrentRpm as sent: 0 (engine off), 0.2 idle .. 1.0 limiter
let idleRpm = null;                   // the vehicle's idle in thousands (vehicleDialRange); null: ~11% of the scale
let defs = [];                        // the registered vehicle stats with a gauge (registerVehicleHud)
const gauges = new Map();             // id -> what is on the dial now

// ============================================
// The numbers
// ============================================

/* GTA's rpm is not in rpm: 0.2 at idle, 1.0 at the limiter. It runs in a straight line from the engine's idle (sent
   with its range: measured for most vanilla engines, 0 for an electric, else ~11% of the scale) to its limiter, which
   is THE TOP OF THE SCALE (v11: the needle runs to the last number, then bounces off the limiter). hud.js engages the bounce, the judder and the flash at 99% with the needle there too.
   client/vehicle_hud.lua's revRange chooses the range, by engine.

   THE LIMITER IS 0.99 AND UP, as client/vehicle_hud.lua's RPM_LIMITER says, and the line ends there too, so 0.99 is
   the top whichever way it is reached. A line alone put only an exact 1.0 at the limiter: a reading of 0.995 (the
   limiter bouncing, or the 0.005 rounding) fell out of the zone, reset the dial's limiter clock, and it stuttered. */
const LIMITER_RAW = 0.99, IDLE_AT = 0.113;
function toThousands(raw, max, idle) {
    if (!(raw > 0)) return 0;
    if (raw >= LIMITER_RAW) return max;
    const low = typeof idle === 'number' && idle >= 0 && idle < max ? idle : max * IDLE_AT;
    return low + (Math.max(raw, 0.2) - 0.2) / (LIMITER_RAW - 0.2) * (max - low);
}

/* A boat's dial reads engine power, not revs (3D Clanker's v8): GTA's 0.2 idle .. 1.0 flat out as 0 .. 1, and 0.99 and
   up as full, as the limiter is for the revs (the game hovers just under 1.0 there). Worked out here from the rpm
   already sent, so the message carries nothing more. */
function toPower(raw) {
    if (!(raw > 0)) return 0;
    if (raw >= LIMITER_RAW) return 1;
    return Math.max(0, Math.min(1, (raw - 0.2) / 0.8));
}

function setState(partial) {
    Object.assign(state, partial);
    if (hud) hud.setState(partial);
}

// ============================================
// The gauges: the vehicle stats
// ============================================

/* The dial's own glyphs for the stats whip and whip_power ship; any other stat keeps the SVG path it registered
   its gauge with (the dial draws those too). A car can give a stat another icon (SetVehicleStatIcon, client/vehicles.lua:
   the snapshot's `icons`): whip_fuel's pump with an arrow to the side the filler is on, 'fuel_left' / 'fuel_right'. */
const ICONS = { fuel: 'fuel', boost: 'turbo', nitro: 'nitro' };

/** One stat's gauge for a snapshot value, or null when it is not shown. The rules are the capsule's:
 *  an icon-only stat (engine on/off) is not a gauge; a showWhenPresent stat shows only on a car that carries it (the
 *  snapshot leaves it out otherwise); showAboveZero / hideWhenEmpty hide it at its bottom; below 20% is critical
 *  unless the stat says noCritical. `icon`: this car's own for it, if it has one. */
function gaugeFor(def, v, icon) {
    if (def.iconOnly || typeof v !== 'number') return null;
    const min = typeof def.min === 'number' ? def.min : 0;
    const max = typeof def.max === 'number' && def.max > min ? def.max : 100;
    if ((def.showAboveZero || def.hideWhenEmpty) && v <= min) return null;
    const value = Math.max(0, Math.min(1, (v - min) / (max - min)));
    // The stat's own reading where it has one (its `display`: 14 psi, 92°C), else a percentage; with end markers
    // (fuel's E and F) the gauge shows those and no number.
    return {
        id: def.name, icon: (typeof icon === 'string' && icon) || ICONS[def.name] || def.icon || '',
        order: typeof def.order === 'number' ? def.order : 99,
        value, text: statValueText(def.display, value) || Math.round(value * 100) + '%',
        ends: statEnds(def.display),
        dangerLow: def.noCritical ? null : 0.2,
    };
}

function paintGauges(snapshot) {
    const seen = new Set();
    const icons = (snapshot.icons && typeof snapshot.icons === 'object') ? snapshot.icons : {};
    for (const def of defs) {
        const g = gaugeFor(def, snapshot[def.name], icons[def.name]);
        if (!g) continue;
        seen.add(g.id);
        const was = gauges.get(g.id);
        if (was && was.value === g.value && was.text === g.text && was.icon === g.icon && was.ends === g.ends) continue;   // a snapshot repeats most values
        gauges.set(g.id, g);
        if (hud) hud.setGauge(g);
    }
    for (const id of [...gauges.keys()]) {
        if (!seen.has(id)) { gauges.delete(id); if (hud) hud.removeGauge(id); }
    }
}

// ============================================
// Loading and showing
// ============================================

function load() {
    if (!loading) {
        loading = import('./vehicle_hud/hud.js').then(({ createVehicleHud }) => {
            canvas = document.createElement('canvas');
            canvas.id = 'vehicleDial';
            document.body.appendChild(canvas);
            hud = createVehicleHud(canvas);
            hud.setConfig({ ...dialConfig, ...dialPlace(state.kind) });
            hud.setState({ ...state, rpm: toThousands(rawRpm, state.maxRpm, idleRpm) });
            for (const g of gauges.values()) hud.setGauge(g);
            addEventListener('resize', onResize);
            if (!enabled) unload();     // switched off while it was loading
        }).catch((e) => {
            console.error('[whip] the vehicle dial could not load:', e);
            loading = null;             // a later vehicle tries again
        });
    }
    return loading;
}

/** The dial gone for good (/vehiclehud off): its WebGL context and GPU memory freed, the canvas out of the page.
 *  load() builds a new one from `state` and `gauges` when it is switched back on. */
function unload() {
    if (!hud) return;
    hud.dispose();
    canvas.remove();
    removeEventListener('resize', onResize);
    hud = null; canvas = null; loading = null; shown = false;
}

/** The HUD layer is on screen. (During a load the dial is under the curtain with the rest of the HUD.) */
function hudShown() {
    return !!statusHud && statusHud.classList.contains('visible');
}

function update() {
    const want = enabled && inVehicle && hasDial && hudShown() && room;
    if (want === shown) return;
    shown = want;
    clearTimeout(hideTimer);
    if (want) {
        load().then(() => {
            if (!shown || !hud) return;
            hud.show();
            canvas.classList.add('on');
        });
    } else if (hud) {
        canvas.classList.remove('on');
        // hide() stops rendering at once, so the fade runs first (css/vehicle-dial.css: 0.35 s); switched off, the
        // dial then goes altogether
        hideTimer = setTimeout(() => {
            if (shown || !hud) return;
            if (enabled) hud.hide(); else unload();
        }, 400);
    }
}

if (statusHud) new MutationObserver(update).observe(statusHud, { attributes: true, attributeFilter: ['class'] });

// ============================================
// Making room: other resources' UIs in its corner
// ============================================
//
// An area (SetScreenArea, client/hud.lua) is where another resource's UI will sit once still, as fractions of the screen.
// One that overlaps the dial moves it, by the SHORTER of two ways: up, to stand above it, or left, to stand beside it.
// The phone's notifications peeking up from the bottom edge are short, so the dial goes up over them; the phone itself
// is half the screen tall, so the dial goes left, next to it. A move that would take the dial off the screen is no
// move: with no room either way (the unfolded tablet across the middle) the dial fades until there is.
//
// THE MOVE IS A CSS TRANSFORM, eased (css/vehicle-dial.css), as --dial-dx / --dial-dy on the root: the dial's canvas
// keeps the place hud.js gives it, and js/vehicle-controls.js's buttons, which stand on the dial, take the same move.
// Worked out from where the dial sits by its kind (hud.js place(), DIAL_RIGHT), so it is right before the dial loads.

let areas = [];                       // [{ left, top, right, bottom }], fractions of the screen
const REACH = { car: 1.01, boat: 1.01, air: 1.44 };   // how far the dial reaches right of its centre, in radii (above)
const ROOM_GAP = 0.12;                // of the dial's radius, between it and an area (16 px at 1080p)

/** The dial's footprint in window pixels where hud.js puts it (no move): its box, cut at the screen's edges, and on
 *  the right only as far as the dial itself reaches. */
function footprint() {
    const W = innerWidth, H = innerHeight;
    const R = Math.max(30, Math.floor(Math.min(0.1257 * H, 0.2 * W)));
    const cx = W - (DIAL_RIGHT[state.kind] || DIAL_RIGHT.car) * R, cy = H - 1.35 * R;
    return {
        R, l: cx - BOX.cx * R, t: cy - BOX.cy * R,
        r: Math.min(W, cx + (REACH[state.kind] || REACH.car) * R), b: Math.min(H, cy + (BOX.h - BOX.cy) * R),
    };
}

function makeRoom() {
    const W = innerWidth, H = innerHeight, f = footprint(), gap = ROOM_GAP * f.R;
    let dx = 0, dy = 0, fits = true;
    for (const a of areas) {
        const l = f.l + dx, t = f.t + dy, r = f.r + dx, b = f.b + dy;
        const al = a.left * W - gap, at = a.top * H - gap, ar = a.right * W + gap, ab = a.bottom * H + gap;
        if (r <= al || l >= ar || b <= at || t >= ab) continue;        // clear of it
        const up = b - at, left = r - al;
        const upOk = t - up >= 0, leftOk = l - left >= 0;
        if (upOk && (!leftOk || up <= left)) dy -= up;
        else if (leftOk) dx -= left;
        else { fits = false; break; }
    }
    if (!fits) { dx = 0; dy = 0; }
    const root = document.documentElement.style;
    root.setProperty('--dial-dx', Math.round(dx) + 'px');
    root.setProperty('--dial-dy', Math.round(dy) + 'px');
    if (fits !== room) { room = fits; update(); }
}

addEventListener('resize', makeRoom);

// [{ left, top, right, bottom }]: every area there is now (an empty list: none)
NuiRouter.register('uiAreas', (d) => {
    areas = (Array.isArray(d && d.areas) ? d.areas : []).filter((a) => a && [a.left, a.top, a.right, a.bottom]
        .every((v) => typeof v === 'number' && v >= 0 && v <= 1));
    makeRoom();
});

// ============================================
// Messages
// ============================================

NuiRouter.register('showVehicleHud', () => { inVehicle = true; update(); });
// GETTING OUT FORGETS WHETHER THAT VEHICLE HAD A DIAL. The next vehicle's show and its range come from two loops
// (client/vehicles.lua's 200 ms edge, client/vehicle_hud.lua's own), in either order, so it waits for the new
// vehicle's vehicleDialRange rather than fading in the old dial (a car's over a bicycle). (vehicle_hud.lua always sends one after a real
// exit: its 50 ms seated loop sees the player out, and the next vehicle counts as new.)
NuiRouter.register('hideVehicleHud', () => { inVehicle = false; hasDial = false; update(); });

// /vehiclehud: the whole HUD off (faded, then disposed) or back on (built again if the player is in a vehicle).
// Nothing else arrives while it is off: client Lua stops the dials and the gauges at the source.
NuiRouter.register('vehicleHudEnabled', (d) => {
    enabled = !(d && d.on === false);
    if (!enabled && !shown) unload();   // on foot, or already hidden: nothing to fade
    update();
});

// Config.VehicleHud: the speed unit (the dial always gets km/h and converts), the aircraft horizon ('ball' / 'flat'),
// and the cars' own dial looks (dashSkins: false puts every car on the dial as designed)
NuiRouter.register('vehicleHudConfig', (d) => {
    if (d && (d.units === 'kmh' || d.units === 'mph')) setState({ units: d.units });
    if (d && (d.attitude === 'ball' || d.attitude === 'flat') && d.attitude !== dialConfig.attitude) {
        dialConfig.attitude = d.attitude;
        if (hud) hud.setConfig({ attitude: d.attitude });
    }
    if (d && typeof d.skins === 'boolean' && d.skins !== dialConfig.skins) {
        dialConfig.skins = d.skins;
        if (hud) hud.setConfig({ skins: d.skins });
    }
});

// Getting into a vehicle: its rev range (thousands), its redline (thousands; null = the dial's own 87%), its idle
// (thousands; where GTA's 0.2 lands), its kind ('car', 'air', 'boat'), whether it has a dial at all, and its skin
// (its own GTA dashboard's look, a skins3d.js id: client/vehicle_hud.lua from data/dash_skins.lua; false: none).
NuiRouter.register('vehicleDialRange', (d) => {
    if (!d) return;
    hasDial = d.dial !== false;
    const maxRpm = Number(d.maxRpm) || 8;
    idleRpm = typeof d.idle === 'number' ? d.idle : null;
    const kind = d.kind === 'air' || d.kind === 'boat' ? d.kind : 'car';
    setState({ kind, maxRpm, redline: typeof d.redline === 'number' ? d.redline : null, rpm: toThousands(rawRpm, maxRpm, idleRpm),
        skin: typeof d.skin === 'string' ? d.skin : null });
    // Its place for this kind: an aircraft's sits further in (DIAL_RIGHT). Set while it is still hidden on getting in.
    if (hud) hud.setConfig(dialPlace(kind));
    makeRoom();   // the kind moves its footprint (an aircraft's sits further in)
    update();
});

// The dials, fifteen times a second at most. `hud`: the stat snapshot riding in the same message
// (client/vehicles.lua's carry: one message a tick, not two), handed on as the updateVehicleHud it is.
// `eng`: the engine running (the engine light, where the handbrake's P was). An aircraft's instruments (pitch, roll,
// alt in metres, gearState) and a boat's anchor ride in the same message; only the current kind's are passed on. A
// boat's power is its rpm (toPower).
NuiRouter.register('updateVehicleDials', (d) => {
    if (!d) return;
    rawRpm = Number(d.rpm) || 0;
    const p = {
        rpm: toThousands(rawRpm, state.maxRpm, idleRpm), speed: Number(d.speed) || 0, gear: d.gear == null ? 'N' : d.gear,
        engine: d.eng === true, lights: d.lights || 'off', locked: d.locked === true, damage: d.dmg === true,
        // first gear, or the handbrake held in any other (client/vehicle_hud.lua): only then does the needle bounce off
        // the limiter; otherwise only the outline flashes
        launch: d.launch === true,
    };
    if (state.kind === 'air') {
        p.pitch = Number(d.pitch) || 0; p.roll = Number(d.roll) || 0; p.altitude = Number(d.alt) || 0;
        p.gearState = d.gearState || 'none';
    } else if (state.kind === 'boat') {
        // The propeller out of the water under throttle (client/vehicle_hud.lua BoatPropOut): the
        // engine revs free to its top, which GTA's boat rpm (tied to the hull's speed) never shows. The dial eases up
        // to it and back down when it bites again.
        p.power = d.freeRev === true ? 1 : toPower(rawRpm); p.anchored = d.anchored === true;
    }
    setState(p);
    if (d.hud) NuiRouter.dispatch(d.hud);
});

// The vehicle stats with a gauge. A second subscriber: vehicles.js draws the garage cards from the same list.
NuiRouter.register('registerVehicleHud', (d) => {
    defs = Array.isArray(d && d.stats) ? d.stats : [];
    for (const id of [...gauges.keys()]) { gauges.delete(id); if (hud) hud.removeGauge(id); }
});

// A complete snapshot of what the car carries (a stat missing from it is a stat the car has not got).
NuiRouter.register('updateVehicleHud', (d) => { if (d) paintGauges(d); });
