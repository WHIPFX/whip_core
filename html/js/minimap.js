// ========================================
// THE MINIMAP — whip's own, in GTA's radar's place (client/minimap.lua feeds it)
//
// The 3D map (pause-map.js's: one copy for the page) in the HUD's map box at the bottom left: top-down on foot, tilted
// in a vehicle, zooming out with speed, turning with the gameplay camera, the player low in the box — 3D Clanker's
// MinimapCamera (js/map3d/map3d.js) moves the view, tuned to the player's own settings (below). Over it, this page's
// own marks: the player's arrow, the blips, the waypoint and north. The GPS line is drawn in the map, on the ground.
//
// WHAT ARRIVES (client/minimap.lua):
//   minimapShow   { on }: client/hud.lua's decision, where it used to show GTA's radar
//   minimapBox    { left, top, width, height } as fractions of the screen, and its look: shape (the mask's), border
//                 ('full' | 'outline' | 'none'), and the dial's speed unit (the settings' speeds are in it)
//   minimapPose   the player and the camera, as often as the frame rate, only when something moved
//   minimapData   every blip { id, x, y, sprite, colour, short, rot?, flash? }, the GPS line and its colour, the waypoint
//   minimapMoves  [[id, x, y, rot], ...]: the blips on moving things, ten times a second
// It also follows the HUD's own fade (#status-hud .visible), as the vehicle dial does: a screen up, or dead, and it
// goes with the rest.
//
// THE PLAYER'S SETTINGS (the pause menu's Settings → Server → Minimap; client/minimap.lua declares them, page = true): the
// frame rate, how much of the map shows on foot, in a vehicle when slow and at top speed (metres across the box, so
// every screen shows the same), the speeds the zoom runs between, the tilt on foot and in a vehicle, and a tilt that
// changes with speed. The camera's own numbers are set from them on every pose (tune).
//
// THE PREVIEW (MinimapPreview, the Minimap tab of that page): a second minimap, bigger, going round from where the
// player stands — on foot, or in a car at a speed the player sets under it — at the settings as they are moved.
//
// A FAR BLIP is pinned to the edge, along the line from the player, as GTA's radar pins one — unless the game made it
// short-range (a shop, a garage): then it shows only inside the box. Every mark stays upright (the player's Upright
// markers), or turns with the map with one the game points pointing its way. One the game made flash, flashes.
//
// DRAWN ON A POSE, never in a loop: a pose that changes the picture asks for a frame, at most the frame rate, and the
// frames stop once the camera has settled (MinimapCamera.settled). Standing still costs nothing.
//
// No WebGL: the box is black, as the pause map is. One version only.
// ========================================

import { NuiRouter } from './router.js';
import { nuiCallback } from './utils.js';
import { whenMap3D, claimMap3D, mayDrawMap3D, blipImage } from './pause-map.js';
import { pref, onPrefs } from './prefs.js';

/** A frame this early is still on time: the browser's own frames wobble by a millisecond or two. */
const FRAME_SLACK_MS = 2;
/** The GPS line, px wide (the preview's grows with it). */
const ROUTE_WIDTH = 4;
/** A far mark pinned with its middle this far inside the map's edge (px): ON the edge, standing out over the border
 *  rather than cut by it (the marks are not clipped to the map: .mm-marks). North the same. */
const EDGE_INSET = 3;
const NORTH_INSET = 4;
/** The 'rounded' mask's corners, as shares of the box's width and height (css/minimap.css, hud_skin.lua MASK_CORNERS):
 *  a far mark follows them round. */
const CORNER_X = 46 / 512;
const CORNER_Y = 46 / 396;
/** Where MinimapCamera puts the player, below the box's middle as a share of its height (3D Clanker's own numbers): in
 *  a vehicle, and on foot. "You in the centre" puts them at 0. */
const PLAYER_AT = 0.28;
const FOOT_PLAYER_AT = 0.12;
/** How far north (m) the north mark is aimed at: far enough to be off the box at every zoom. */
const NORTH_M = 20000;

/** A speed in the dial's unit (Config.VehicleHud.speedUnit, sent with the box), in m/s. */
const MPS = { mph: 0.44704, kmh: 1 / 3.6 };
let speedUnit = 'mph';

/** The player's settings, read when used: a change applies at the next frame. */
function settings() {
    const num = (k, d) => { const n = Number(pref(k, d)); return Number.isFinite(n) ? n : d; };
    const u = MPS[speedUnit] || MPS.mph;
    const from = Math.max(0, num('mm.speedFrom', 0)) * u;
    return {
        fps: Math.max(1, num('map.fps', 60)),
        footM: Math.max(10, num('mm.viewFoot', 230)),
        slowM: Math.max(10, num('mm.viewSlow', 290)),
        fastM: Math.max(10, num('mm.viewFast', 800)),
        from,
        to: Math.max(from + 1, num('mm.speedTo', 100) * u),
        tiltFoot: num('mm.tiltFoot', 0),
        tiltVehicle: num('mm.tiltVehicle', 38),
        tiltWithSpeed: pref('mm.tiltWithSpeed', false) === true,
        tiltFast: num('mm.tiltFast', 50),
        northUp: pref('mm.northUp', false) === true,
        centre: pref('mm.centre', false) === true,
        markerK: Math.max(0.25, num('mm.markerSize', 100) / 100),
        upright: pref('mm.markersUpright', true) !== false,
    };
}

/** Give the camera a pose, tuned to the player's settings: the views as metres across the box; the zoom running from
 *  `from` to `to` (the camera's own runs from 0 to fastSpeed, so it is given the speed past `from`); the tilts as set,
 *  the vehicle's moving toward the top-speed tilt with speed when the player asked for that; the player low in the box
 *  or in its middle; the map turning with the camera, or north up (a camera always facing north). True if the picture
 *  changed. */
function tune(cam, p, boxW) {
    const s = settings(), o = cam.o, speed = Math.max(0, p.speed || 0);
    o.footPxPerMetre = boxW / s.footM;
    o.slowPxPerMetre = boxW / s.slowM;
    o.fastPxPerMetre = boxW / s.fastM;
    o.fastSpeed = s.to - s.from;
    o.footPitch = 90 - s.tiltFoot;
    const f = Math.min(1, Math.max(0, (speed - s.from) / (s.to - s.from)));
    o.vehiclePitch = 90 - (s.tiltWithSpeed ? s.tiltVehicle + (s.tiltFast - s.tiltVehicle) * f : s.tiltVehicle);
    o.playerAt = s.centre ? 0 : PLAYER_AT;
    o.footPlayerAt = s.centre ? 0 : FOOT_PLAYER_AT;
    return cam.update({ x: p.x, y: p.y, heading: p.heading, camYaw: s.northUp ? 0 : p.camYaw,
        speed: Math.max(0, speed - s.from), inVehicle: !!p.inVehicle, vehicleClass: p.vehicleClass,
        t: performance.now() });   // the page's clock
}

// ---- what the game says is on the map: one copy, for the HUD's minimap and the preview ----

const data = { blips: new Map(), route: null, colour: '#a44cf2', waypoint: null, ver: 0, routeVer: 0 };
const maps = [];                 // the minimaps on the page now
let look = { shape: 'rounded', border: 'none' };
let lastPlayer = null;           // the player's last known place { x, y, heading } (the preview starts there)

// ---- one minimap ----

class Minimap {
    /** @param {HTMLElement} root  its box; @param {string} owner  its name to the shared 3D map (claimMap3D) */
    constructor(root, owner) {
        this.root = root;
        this.owner = owner;
        root.classList.add('mm');
        // The map clipped to the box's shape; the marks over it, NOT clipped, so one pinned to the edge sits on the
        // border rather than being cut by it.
        root.innerHTML = '<div class="mm-clip"><canvas class="mm-canvas"></canvas></div><div class="mm-marks"></div>'
            + '<div class="mm-north">N</div>'
            + '<div class="mm-player"><svg viewBox="0 0 24 24"><path d="M12 2.5L19.5 20.5L12 16.6L4.5 20.5Z"/></svg></div>';
        this.canvas = root.querySelector('.mm-canvas');
        this.ctx = this.canvas.getContext('2d', { alpha: false });
        this.marksEl = root.querySelector('.mm-marks');
        this.northEl = root.querySelector('.mm-north');
        this.playerEl = root.querySelector('.mm-player');
        this.box = { w: 330, h: 179 };
        this.shape = 'rounded';
        this.gl = null;
        this.cam = null;
        this.shown = false;
        this.pending = 0;
        this.nextAt = 0;           // the earliest the next frame is drawn (frame)
        this.heading = 0;          // the player's, for the arrow
        this.routeVer = -1;        // the route the 3D map holds for this one (claimMap3D says when someone else drew)
        this.dataVer = -1;         // the blips its marks were made from
        this.blipEls = new Map();  // id -> element
        this.waypointEl = null;
        this.frames = 0;           // frames drawn, counted (the preview's own rate)
        this.markerK = 1;          // the marks' size as last set (the player's Marker size)
        this.dead = false;
        this.frame = this.frame.bind(this);
        whenMap3D((map, mod) => {
            if (this.dead) return;
            this.gl = map;
            this.cam = new mod.MinimapCamera({ boxH: this.box.h });
            this.kick();
        });
        maps.push(this);
    }

    /** The box's size in px (its place is the caller's). */
    size(w, h) {
        this.box.w = Math.max(1, Math.round(w));
        this.box.h = Math.max(1, Math.round(h));
        if (this.cam) this.cam.o.boxH = this.box.h;   // the player's place in the box is a share of its height
        this.kick();
    }

    setLook(shape, border) {
        this.shape = shape;
        this.root.dataset.shape = shape;
        this.root.dataset.border = border;
    }

    /** A pose: { x, y, heading, camYaw, speed, inVehicle, vehicleClass }. */
    pose(p) {
        this.heading = p.heading || 0;
        if (this.cam && tune(this.cam, p, this.box.w)) this.kick();
    }

    show(on) {
        this.shown = !!on;
        this.root.classList.toggle('on', this.shown);
        if (this.shown) this.kick();
    }

    kick() {
        if (!this.shown || this.pending || this.dead) return;
        this.pending = requestAnimationFrame(this.frame);
    }

    frame(now) {
        this.pending = 0;
        if (!this.shown || !this.cam || this.dead) return;
        // Paced to the frame rate on a running clock, not "this long since the last": 45 on a 60 Hz screen comes out
        // as 45 on average (frames one and two apart) rather than falling to 30.
        if (now < this.nextAt - FRAME_SLACK_MS) { this.pending = requestAnimationFrame(this.frame); return; }
        const s = settings();
        const step = 1000 / s.fps;
        this.nextAt = this.nextAt + step > now ? this.nextAt + step : now + step;
        if (s.markerK !== this.markerK) {
            this.markerK = s.markerK;
            this.root.style.setProperty('--mm-mk', String(s.markerK));
        }
        const v = this.cam.viewAt(now);
        if (!v) return;

        // The 3D map at this minimap's size and view (another map may have had it), drawn, and copied in. Not while
        // the spawn picker holds it (pause-map.js holdMap3D): this frame again once it lets go.
        const gl = this.gl, dpr = window.devicePixelRatio || 1;
        if (!mayDrawMap3D(this.owner, () => this.kick())) return;
        if (claimMap3D(this.owner)) this.routeVer = -1;
        if (gl.W !== this.box.w || gl.H !== this.box.h || gl.dpr !== dpr) gl.resize(this.box.w, this.box.h, dpr);
        if (this.routeVer !== data.routeVer) {
            gl.setRoute(data.route, data.colour, ROUTE_WIDTH * this.box.w / (hud ? hud.box.w : this.box.w));
            gl.setLines([]);   // a panel map's own lines are not the minimap's
            this.routeVer = data.routeVer;
        }
        gl.setView(v);
        gl.render();
        const cw = Math.round(this.box.w * dpr), ch = Math.round(this.box.h * dpr);
        if (this.canvas.width !== cw || this.canvas.height !== ch) { this.canvas.width = cw; this.canvas.height = ch; }
        this.ctx.drawImage(gl.canvas, 0, 0, cw, ch);
        this.frames++;

        this.syncMarks();
        this.placeMarks(v, s.upright);
        if (!this.cam.settled) this.pending = requestAnimationFrame(this.frame);
    }

    /** The marks for the blips there are now: an icon already up stays, unless its look changed. */
    syncMarks() {
        if (this.dataVer === data.ver) return;
        this.dataVer = data.ver;
        for (const [id, el] of this.blipEls) {
            const b = data.blips.get(id);
            if (!b || el._sprite !== b.sprite || el._colour !== b.colour) { el.remove(); this.blipEls.delete(id); }
        }
        for (const [id, b] of data.blips) {
            if (this.blipEls.has(id)) continue;
            const el = blipImage(b.sprite, b.colour);
            el._sprite = b.sprite;
            el._colour = b.colour;
            el.style.display = 'none';
            this.marksEl.appendChild(el);
            this.blipEls.set(id, el);
        }
        // The waypoint in the route's colour (GTA's waypoint colour: whip blue with the black HUD), made again if that
        // changed.
        if (this.waypointEl && this.waypointEl._colour !== data.colour) { this.waypointEl.remove(); this.waypointEl = null; }
        if (!this.waypointEl) {
            this.waypointEl = blipImage(8, data.colour);
            this.waypointEl._colour = data.colour;
            this.waypointEl.classList.add('mm-waypoint');
            this.waypointEl.style.display = 'none';
            this.marksEl.appendChild(this.waypointEl);
        }
    }

    /** The box's shape `m` px in from its edge, as a rounded rectangle: its sides, and its corners' radii. A square has
     *  none; a circle is all corner (its four corners share the middle). */
    outline(m) {
        const W = this.box.w, H = this.box.h;
        const r = this.shape === 'circle' ? [W / 2, H / 2] : this.shape === 'square' ? [0, 0] : [W * CORNER_X, H * CORNER_Y];
        return { x0: m, y0: m, x1: W - m, y1: H - m, rx: Math.max(0, r[0] - m), ry: Math.max(0, r[1] - m) };
    }

    /** The centre of the corner (x, y) is in, or null when it is along a side. */
    cornerOf(o, x, y) {
        if (!o.rx || !o.ry) return null;
        const cx = x < o.x0 + o.rx ? o.x0 + o.rx : x > o.x1 - o.rx ? o.x1 - o.rx : null;
        const cy = y < o.y0 + o.ry ? o.y0 + o.ry : y > o.y1 - o.ry ? o.y1 - o.ry : null;
        return cx === null || cy === null ? null : [cx, cy];
    }

    /** Inside the box's shape, `m` px in from its edge. */
    inside(p, m) {
        const o = this.outline(m);
        if (p.sx < o.x0 || p.sx > o.x1 || p.sy < o.y0 || p.sy > o.y1) return false;
        const c = this.cornerOf(o, p.sx, p.sy);
        return !c || ((p.sx - c[0]) / o.rx) ** 2 + ((p.sy - c[1]) / o.ry) ** 2 <= 1;
    }

    /** Where the line from `a` toward `b` leaves the box's shape, `m` px in: a far mark pinned there. The straight sides
     *  first; landing in a corner, where the line leaves that corner's curve. */
    toEdge(a, b, m) {
        const o = this.outline(m), dx = b.sx - a.sx, dy = b.sy - a.sy;
        let t = Infinity;
        if (dx > 0) t = Math.min(t, (o.x1 - a.sx) / dx); else if (dx < 0) t = Math.min(t, (o.x0 - a.sx) / dx);
        if (dy > 0) t = Math.min(t, (o.y1 - a.sy) / dy); else if (dy < 0) t = Math.min(t, (o.y0 - a.sy) / dy);
        if (!Number.isFinite(t)) t = 0;
        t = Math.max(0, Math.min(1, t));
        const c = this.cornerOf(o, a.sx + dx * t, a.sy + dy * t);
        if (c) {
            // The line against the corner's ellipse: where it comes out (the larger root).
            const ox = (a.sx - c[0]) / o.rx, oy = (a.sy - c[1]) / o.ry, ux = dx / o.rx, uy = dy / o.ry;
            const A = ux * ux + uy * uy, B = 2 * (ox * ux + oy * uy), C = ox * ox + oy * oy - 1;
            const disc = B * B - 4 * A * C;
            if (A > 0 && disc >= 0) {
                const out = (-B + Math.sqrt(disc)) / (2 * A);
                if (out >= 0) t = Math.min(t, out);
            }
        }
        return [a.sx + dx * t, a.sy + dy * t];
    }

    /** One mark: where it is in the box, pinned to the edge when far (unless `short`), or hidden. `upright` (the
     *  player's Upright markers): never turned, whatever the map or the game does, so no icon is ever sideways or upside
     *  down. Otherwise it turns with the map, and one the game points (`rot`, GTA's sense) points its own way. */
    place(el, me, x, y, short, rot, yaw, upright) {
        const p = this.gl.project(x, y);
        let at;
        if (this.inside(p, 0)) at = [p.sx, p.sy];
        else if (!short) at = this.toEdge(me, p, EDGE_INSET * this.k());
        if (!at) { el.style.display = 'none'; return; }
        el.style.display = '';
        const r = upright ? 0 : rot ? yaw - rot : yaw;
        el.style.transform = 'translate(' + at[0].toFixed(1) + 'px,' + at[1].toFixed(1) + 'px)'
            + (r ? ' rotate(' + r.toFixed(1) + 'deg)' : '');
    }

    /** How much bigger than the HUD's this minimap is (its marks grow with it). */
    k() {
        return hud && hud !== this ? this.box.w / hud.box.w : 1;
    }

    /** @param upright  the player's "Upright markers" */
    placeMarks(v, upright) {
        // The player is the view's own point (the camera follows them), the arrow turned by their heading less the map's.
        const me = this.gl.project(v.x, v.y);
        this.playerEl.style.transform = 'translate(' + me.sx.toFixed(1) + 'px,' + me.sy.toFixed(1) + 'px) rotate(' + (v.yaw - this.heading) + 'deg)';

        const n = this.toEdge(me, this.gl.project(v.x, v.y + NORTH_M), NORTH_INSET * this.k());
        this.northEl.style.transform = 'translate(' + n[0].toFixed(1) + 'px,' + n[1].toFixed(1) + 'px)';

        for (const [id, el] of this.blipEls) {
            const b = data.blips.get(id);
            if (!b) continue;
            el.classList.toggle('mm-flash', !!b.flash);
            this.place(el, me, b.x, b.y, b.short, b.rot, v.yaw, upright);
        }
        if (this.waypointEl) {
            if (data.waypoint) this.place(this.waypointEl, me, data.waypoint.x, data.waypoint.y, false, 0, v.yaw, upright);
            else this.waypointEl.style.display = 'none';
        }
    }

    destroy() {
        this.dead = true;
        if (this.pending) cancelAnimationFrame(this.pending);
        this.pending = 0;
        const i = maps.indexOf(this);
        if (i >= 0) maps.splice(i, 1);
    }
}

// ---- the HUD's minimap ----

const hudRoot = document.createElement('div');
hudRoot.id = 'minimap3d';
document.body.appendChild(hudRoot);
const hud = new Minimap(hudRoot, 'minimap');
const statusHud = document.getElementById('status-hud');

let want = false;          // client/hud.lua wants it up
let boxFr = null;          // the box as fractions of the screen (minimapBox)

function placeBox() {
    if (!boxFr) return;
    const W = window.innerWidth, H = window.innerHeight;
    hudRoot.style.left = Math.round(boxFr.left * W) + 'px';
    hudRoot.style.top = Math.round(boxFr.top * H) + 'px';
    hudRoot.style.width = Math.max(1, Math.round(boxFr.width * W)) + 'px';
    hudRoot.style.height = Math.max(1, Math.round(boxFr.height * H)) + 'px';
    hud.size(boxFr.width * W, boxFr.height * H);
    if (preview) preview.layout();
}

addEventListener('resize', placeBox);

function syncShown() {
    const on = want && !!statusHud && statusHud.classList.contains('visible');
    if (on !== hud.shown) hud.show(on);
}

if (statusHud) new MutationObserver(syncShown).observe(statusHud, { attributes: true, attributeFilter: ['class'] });

NuiRouter.register('minimapShow', (d) => {
    want = !!(d && d.on);
    syncShown();
});

NuiRouter.register('minimapBox', (d) => {
    if (!d || typeof d.left !== 'number') return;
    boxFr = { left: d.left, top: d.top, width: d.width, height: d.height };
    look = {
        shape: d.shape === 'circle' || d.shape === 'square' ? d.shape : 'rounded',
        border: d.border === 'full' || d.border === 'outline' ? d.border : 'none',
    };
    if (typeof d.speedUnit === 'string' && MPS[d.speedUnit]) speedUnit = d.speedUnit;
    for (const m of maps) m.setLook(look.shape, look.border);
    placeBox();
});

NuiRouter.register('minimapPose', (d) => {
    if (!d || typeof d.x !== 'number') return;
    lastPlayer = { x: d.x, y: d.y, heading: d.heading || 0 };
    hud.pose(d);
});

NuiRouter.register('minimapData', (d) => {
    if (!d) return;
    if ('route' in d) {
        // Its line is built again only when the route (or its colour) is another: a message that changed only a blip
        // leaves it as it is
        const route = Array.isArray(d.route) && d.route.length > 1 ? d.route : null;
        const colour = typeof d.colour === 'string' ? d.colour : data.colour;
        const key = (route ? route.join(',') : '') + '|' + colour;
        if (key !== data.routeKey) {
            data.routeKey = key;
            data.route = route;
            data.colour = colour;
            data.routeVer++;
        }
    }
    if ('waypoint' in d) data.waypoint = d.waypoint && typeof d.waypoint.x === 'number' ? d.waypoint : null;
    // (An empty Lua table may come as {} rather than []: none, all the same.)
    if ('blips' in d) {
        data.blips = new Map((Array.isArray(d.blips) ? d.blips : []).map((b) => [b.id, b]));
        data.ver++;
    }
    for (const m of maps) m.kick();
});

NuiRouter.register('minimapMoves', (d) => {
    if (!d || !Array.isArray(d.m)) return;
    for (const [id, x, y, rot] of d.m) {
        const b = data.blips.get(id);
        if (b) { b.x = x; b.y = y; if (typeof rot === 'number') b.rot = rot; }
    }
    for (const m of maps) m.kick();
});

// The pause menu's own feed says where the player is (the preview starts there when the minimap never showed).
NuiRouter.register('pauseData', (d) => {
    if (d && d.player && typeof d.player.x === 'number') {
        lastPlayer = { x: d.player.x, y: d.player.y, heading: d.player.heading || 0 };
    }
});

// A setting changed: the minimaps up are drawn again with it.
onPrefs(() => { for (const m of maps) m.kick(); });

// ---- the preview (the Settings page's Minimap tab, under Server) ----

/** The circle the preview goes round (m): the map turns as it goes. */
const DRIVE_R = 350;
/** A walk, on foot (m/s). */
const WALK = 1.6;
/** Legion Square, when the game has said nothing of where the player is. */
const PREVIEW_START = { x: 195, y: -934, heading: 0 };

let preview = null;

/** The HUD minimap's shape, width over height: the preview's place on the Settings page is made this shape. */
export function minimapAspect() {
    return hud.box.w / Math.max(1, hud.box.h);
}

/** The preview's car speed control, in the dial's unit (the Settings page shows it beside the preview): the unit's
 *  name, the top of the range and its step. */
export function previewSpeedRange() {
    return speedUnit === 'kmh' ? { unit: 'km/h', max: 320, step: 5 } : { unit: 'mph', max: 200, step: 5 };
}

export class MinimapPreview {
    /** @param {HTMLElement} host  where it goes (settings-page.js lays it over its place in the inspector)
     *  @param {HTMLElement} caption  where it says what it shows: on foot or the car's speed, and its frames a second */
    constructor(host, caption) {
        this.el = document.createElement('div');
        this.el.className = 'mm-preview';
        this.mapEl = document.createElement('div');
        this.mapEl.className = 'mm-preview-map';
        this.el.appendChild(this.mapEl);
        host.appendChild(this.el);
        this.caption = caption;
        this.map = new Minimap(this.mapEl, 'minimap-preview');
        this.map.setLook(look.shape, look.border);
        preview = this;
        this.layout();

        const start = lastPlayer || PREVIEW_START;
        this.pos = { x: start.x, y: start.y, heading: start.heading };
        this.mode = 'car';        // 'foot' | 'car': the player's choice under it (setMode)
        this.speed = 60;          // the car's, in the dial's unit (setSpeed)
        this.last = performance.now();
        this.timer = 0;
        this.rate = 0;            // frames a second, as drawn
        this.rateAt = this.last;
        this.rateFrames = 0;
        this.captionAt = 0;
        this.map.show(true);
        this.tick();
        // The blips, the route and the waypoint where the player is, while it is up (client/minimap.lua).
        nuiCallback('minimapPreview', { on: true });
    }

    /** On foot or in a car. */
    setMode(mode) {
        this.mode = mode === 'foot' ? 'foot' : 'car';
        this.captionAt = 0;
    }

    /** The car's speed, in the dial's unit. */
    setSpeed(v) {
        this.speed = Math.max(0, Number(v) || 0);
        this.captionAt = 0;
    }

    /** Its size: the host's width, the HUD's box's shape. */
    layout() {
        const w = this.mapEl.clientWidth || 600;
        const h = Math.round(w * hud.box.h / hud.box.w);
        this.mapEl.style.height = h + 'px';
        this.mapEl.style.setProperty('--mm-k', String(w / hud.box.w));
        this.map.size(w, h);
    }

    /** One pose, as often as the frame rate: walking, or the car at its speed, round a circle from where the player
     *  stands. */
    tick() {
        const now = performance.now();
        const s = settings();
        const dt = Math.min(0.1, (now - this.last) / 1000);
        this.last = now;
        const inVehicle = this.mode === 'car';
        const u = MPS[speedUnit] || MPS.mph;
        const speed = inVehicle ? this.speed * u : WALK;
        // Round a circle: the heading turns with the distance gone (GTA's heading: anticlockwise from north).
        const p = this.pos;
        p.heading = (p.heading + (speed * dt / DRIVE_R) * 180 / Math.PI) % 360;
        const h = p.heading * Math.PI / 180;
        p.x += -Math.sin(h) * speed * dt;
        p.y += Math.cos(h) * speed * dt;
        this.map.pose({ x: p.x, y: p.y, heading: p.heading, camYaw: p.heading, speed, inVehicle });

        // The caption: what it shows, and the frames it is drawn at.
        if (now - this.rateAt >= 1000) {
            this.rate = Math.round((this.map.frames - this.rateFrames) * 1000 / (now - this.rateAt));
            this.rateFrames = this.map.frames;
            this.rateAt = now;
        }
        if (this.caption && now - this.captionAt >= 250) {
            this.captionAt = now;
            const what = inVehicle ? 'In a car at ' + Math.round(this.speed) + ' ' + previewSpeedRange().unit : 'On foot';
            this.caption.textContent = what + '  ·  ' + this.rate + ' fps';
        }
        this.timer = setTimeout(() => this.tick(), 1000 / s.fps);
    }

    destroy() {
        clearTimeout(this.timer);
        this.map.destroy();
        this.el.remove();
        if (preview === this) preview = null;
        nuiCallback('minimapPreview', { on: false });
    }
}
