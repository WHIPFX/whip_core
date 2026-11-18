// ========================================
// THE FURNISHER'S MARKERS — arrows that move the selected object, rings that turn it
//
// The mouse is free, holding the right button turns the camera, and
// the selected piece of furniture wears X / Y / Z markers you click and drag. R (or the card's Move /
// Rotate switch) swaps the three arrows for three rings. While snap is on (G) a drag snaps to its step;
// while it is off, holding Shift during a drag does.
//
// DRAWN HERE, ON AN SVG OVER THE ROOM, NOT BY THE GAME. The game can draw lines, but they are a pixel
// wide and cannot be told they are under the pointer; these are thick, light up when the pointer is
// on them, and are hit-tested with the same numbers they are drawn with. They show through walls,
// as every editor's markers do: they are controls, not furniture.
//
// THE GAME TELLS THIS FILE WHERE THE CAMERA IS (furnishView, from client/property_furnish.lua) every
// frame it or the selected object moves, and only while something is selected:
//   c  camera position [x, y, z]            r  its [pitch, yaw], degrees (it never rolls)
//   k  [kx, ky] how far the screen reaches across and up at one metre ahead (tan of half the FOV)
//   o  the object [x, y, z, rx, ry, rz]     i  its index in the object list
//   b  the last move was refused (outside the property)
//   h  how far its top is above its origin, metres (a prompt it carries counted), when known
//   n  no markers: it cannot be moved (a picked door); only where it is, for the bubble
//   g  several selected (Ctrl+click, or a box): each one's [x, y, z] in order round their middle. `o` is then that
//      middle (the markers move and turn them together) and a shape is drawn through them: a line, a triangle, their
//      outline. `a` is then the primary's [x, y, z], which a grid-locked move puts on the grid
//   w  grid lock (L): the arrows run along the world's X and Y, a move along them lands on the world grid at the snap
//      step, a turn on whole steps; and the grid is drawn on the floor, `f` metres under `o`
// basis / project / rayAt below are the page's half of client/furnish_view.lua and must stay the
// same maths: the Lua half aims clicks, this half draws and drags.
//
// WHERE THE MARKERS ARE, FOR THE BUBBLE: every time they are drawn, the box round them on the screen
// (and round the thing's top) goes to whoever asked (onAnchor), so js/furnisher.js can put what is
// selected beside it rather than over it.
//
// THIS FILE WORKS OUT, LUA DECIDES. A drag becomes a position along an arrow (the closest point on
// the arrow's line to the ray under the pointer) or an angle round a ring (where that ray meets the
// ring's plane), sent once a frame as furnishMove; Lua refuses anything outside the property's space
// and the object — and so the markers, which are drawn where Lua says it is — stays at the edge.
//
// A DRAG ON THE ROOM (not on a marker) draws a box, and lets go to select everything in it (furnishSelectBox; Ctrl
// held: added to what is selected). A press let go where it went down is a click, as before.
//
// THE CENTRE DOT: grabbed, the object follows the pointer over the world, "like
// clicking where you want to place something". Only the game can see the world, so the page sends the
// pointer itself (furnishDragTo, 0-1 across and down, once a frame) and Lua stands the object on what
// the ray through it meets (client/property_furnish.lua, dragSelectedTo).
//
// THE AXES:
//   arrows  X and Y follow the object's own heading (so "along the sofa" is an arrow, in any room at
//           any angle); Z is straight up. Grid-locked, X and Y are the world's.
//   rings   a gimbal on GTA's rotation order 2 (the entity's matrix is Rz · Rx · Ry), so each ring
//           changes exactly one of the three numbers the object is saved with:
//             Z  round straight up                      → rz (its heading)
//             X  round its heading's X                  → rx (tipping forward and back)
//             Y  round its own forward, after the tip   → ry (tipping side to side)
//           Positive is the right-hand turn about each. The heading ring is certain; the other two
//           ASSUME GTA's X and Y turns are right-handed too — unconfirmed until tried in game. If one
//           turns against the mouse, flip its sign in RING_SIGN.
// ========================================

import { nuiCallback } from './utils.js';

const SVG_NS = 'http://www.w3.org/2000/svg';
const svg = document.getElementById('fz-gizmo');
const root = document.getElementById('furnisher');

/** How big the markers are: the arrows' length as a share of the screen's height. */
const SIZE = 0.13;
/** How close the pointer must be to a marker to grab it, in screen pixels. */
const GRAB_PX = 12;
/** A drag can carry an object at most this far from where it started, in metres. Past it the ray
 *  is running almost along the arrow and a pixel of mouse is metres of room. */
const MAX_MOVE = 20;
/** How far a press goes before it is a box rather than a click, in screen pixels. */
const BOX_PX = 6;
/** The floor grid: at least this far out from the selection each way, in metres, and at most this many lines a side. */
const GRID_REACH = 2;
const GRID_MAX = 30;
/** Points round each ring. */
const RING_STEPS = 64;
/** See the header. 1 = right-handed. */
const RING_SIGN = { x: 1, y: 1, z: 1 };
const AXES = ['x', 'y', 'z'];

let view = null;          // the last furnishView, or null (nothing selected)
let mode = 'move';        // 'move' | 'rotate'
let looking = false;      // right button held: the room is turning, the markers are inert
let snap = { move: 0.25, turn: 15, on: false };   // on: every drag snaps (G); off: only with Shift held
let hot = null;           // the marker under the pointer, or being dragged: 'x' | 'y' | 'z' | 'c' (the dot)
let drag = null;          // the drag in progress (see startDrag)
let box = null;           // a press on the room: { x0, y0, x1, y1, ctrl, on } (on: dragged far enough to be a box)
let pending = null;       // the move waiting for the next frame
let frameId = 0;
let anchorFn = null;      // told where the markers are each time they are drawn (onAnchor)
let carryFn = null;       // told as a carry starts and ends (onCarry: the page's hint line)
/** Where the drags go: the furnisher's callbacks, or the object viewer's Move while it has the markers
 *  (js/ov-panel.js, FurnishGizmo.route). */
const FURNISH_ROUTE = { move: 'furnishMove', dragTo: 'furnishDragTo', end: 'furnishMoveEnd', click: 'furnishClick',
                        box: 'furnishSelectBox' };
let route = FURNISH_ROUTE;

// ---- vectors: plain [x, y, z] arrays ----
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const unit = (a) => { const l = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
const rad = (d) => (d || 0) * Math.PI / 180;

// ========================================
// THE CAMERA — client/furnish_view.lua's maths, in the browser
// ========================================

/** The camera's forward, right and up from its pitch and yaw (degrees). */
export function basis(pitch, yaw) {
    const p = rad(pitch), y = rad(yaw);
    const cp = Math.cos(p), sp = Math.sin(p), cy = Math.cos(y), sy = Math.sin(y);
    return { f: [-sy * cp, cy * cp, sp], r: [cy, sy, 0], u: [sy * sp, -cy * sp, cp] };
}

function camera() {
    const b = basis(view.r[0], view.r[1]);
    return { C: view.c, f: b.f, r: b.r, u: b.u, kx: view.k[0], ky: view.k[1],
             W: window.innerWidth, H: window.innerHeight };
}

/** Where a point in the room lands on the screen: [x px, y px, depth m], or null behind the camera. */
export function project(cam, P) {
    const d = sub(P, cam.C);
    const depth = dot(d, cam.f);
    if (depth < 0.05) return null;
    const a = dot(d, cam.r) / depth, b = dot(d, cam.u) / depth;
    return [(0.5 + 0.5 * a / cam.kx) * cam.W, (0.5 - 0.5 * b / cam.ky) * cam.H, depth];
}

/** The ray from the camera through a point on the screen: { o, d } with d a unit vector. */
export function rayAt(cam, px, py) {
    const a = (px / cam.W - 0.5) * 2 * cam.kx, b = (0.5 - py / cam.H) * 2 * cam.ky;
    return { o: cam.C, d: unit(add(cam.f, add(mul(cam.r, a), mul(cam.u, b)))) };
}

// ========================================
// THE MARKERS' GEOMETRY
// ========================================

/** The arrows: X and Y along the object's heading (the world's, grid-locked), Z up. */
function moveAxes(o) {
    if (view && view.w) return { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
    const c = Math.cos(rad(o[5])), s = Math.sin(rad(o[5]));
    return { x: [c, s, 0], y: [-s, c, 0], z: [0, 0, 1] };
}

/** The rings' axes (see the header's gimbal). */
function ringAxes(o) {
    const cx = Math.cos(rad(o[3])), sx = Math.sin(rad(o[3]));
    const cz = Math.cos(rad(o[5])), sz = Math.sin(rad(o[5]));
    return { x: [cz, sz, 0], y: [-sz * cx, cz * cx, sx], z: [0, 0, 1] };
}

/** Two unit vectors square to `a` and to each other, turning the right way round it. */
function ringFrame(a) {
    const helper = Math.abs(a[2]) < 0.9 ? [0, 0, 1] : [1, 0, 0];
    const u1 = unit(cross(helper, a));
    return { u1, u2: cross(a, u1) };
}

/** How long the arrows are, in metres, so they are the same size on screen however far away. */
function sizeAt(cam, O) {
    const p = project(cam, O);
    return p ? p[2] * cam.ky * 2 * SIZE : null;
}

/** Everything drawn and grabbed this frame: per axis, the projected shape. */
function layout() {
    if (!view || !view.o) return null;
    const cam = camera();
    const o = view.o;
    const O = [o[0], o[1], o[2]];
    const L = sizeAt(cam, O);
    if (!L) return null;
    const centre = project(cam, O);
    // Its top (a prompt over it counted), for the bubble to keep clear of.
    const top = view.h > 0 ? project(cam, [O[0], O[1], O[2] + view.h]) : null;
    // Several: the shape through them, on the screen (none while one of them is behind the camera).
    let shape = null;
    if (view.g) {
        shape = view.g.map((p) => project(cam, p));
        if (shape.some((p) => !p)) shape = null;
    }
    const out = { cam, O, L, centre, top, shape, axes: {}, fixed: view.n, grid: null };
    // (Nothing to drag on a thing that cannot be moved: only where it is.)
    if (view.n) return out;
    if (view.w) out.grid = gridLines(cam);

    if (mode === 'move') {
        const ax = moveAxes(o);
        for (const k of AXES) {
            const from = project(cam, add(O, mul(ax[k], L * 0.14)));
            const neck = project(cam, add(O, mul(ax[k], L * 0.78)));
            const tip = project(cam, add(O, mul(ax[k], L)));
            const label = project(cam, add(O, mul(ax[k], L * 1.16)));
            // An arrow pointing straight at the camera is a dot: nothing to see, nothing to drag.
            if (!from || !tip || Math.hypot(tip[0] - centre[0], tip[1] - centre[1]) < 14) continue;
            out.axes[k] = { from, neck, tip, label };
        }
    } else {
        const ax = ringAxes(o);
        const toCam = unit(sub(cam.C, O));
        for (const k of AXES) {
            // The world builder's upright things (an NPC, a car, a spot...) turn by heading alone.
            if (view.t === false && k !== 'z') continue;
            const { u1, u2 } = ringFrame(ax[k]);
            const pts = [];
            for (let i = 0; i <= RING_STEPS; i++) {
                const t = (i / RING_STEPS) * Math.PI * 2;
                const p = project(cam, add(O, add(mul(u1, Math.cos(t) * L * 0.8), mul(u2, Math.sin(t) * L * 0.8))));
                if (p) pts.push(p);
            }
            // How squarely the ring faces the camera: 1 face-on, 0 edge-on (a line through the middle).
            if (pts.length > 2) out.axes[k] = { pts, facing: Math.abs(dot(ax[k], toCam)) };
        }
    }
    return out;
}

/** A segment of the room on the screen [x1, y1, x2, y2], cut where it passes behind the camera; null when all of it
 *  is behind. */
const NEAR = 0.1;
function projectSegment(cam, P, Q) {
    const dp = dot(sub(P, cam.C), cam.f), dq = dot(sub(Q, cam.C), cam.f);
    if (dp < NEAR && dq < NEAR) return null;
    if (dp < NEAR) P = add(P, mul(sub(Q, P), (NEAR - dp) / (dq - dp)));
    else if (dq < NEAR) Q = add(Q, mul(sub(P, Q), (NEAR - dq) / (dp - dq)));
    const a = project(cam, P), b = project(cam, Q);
    return a && b ? [a[0], a[1], b[0], b[1]] : null;
}

/** Grid-locked: the world grid at the snap step on the floor under the selection, round the grid point nearest the
 *  primary, as screen segments faded towards their ends [[x1, y1, x2, y2, fade], ...]. */
function gridLines(cam) {
    const s = snap.move > 0 ? snap.move : 0.25;
    const A = view.a || view.o;
    const z = view.o[2] - view.f;
    const n = Math.min(GRID_MAX, Math.max(4, Math.ceil(GRID_REACH / s)));
    const cx = Math.round(A[0] / s) * s, cy = Math.round(A[1] / s) * s;
    const ext = n * s;
    const out = [];
    for (let i = -n; i <= n; i++) {
        const fade = 1 - Math.abs(i) / (n + 1);
        const along = projectSegment(cam, [cx + i * s, cy - ext, z], [cx + i * s, cy + ext, z]);
        if (along) out.push([...along, fade]);
        const across = projectSegment(cam, [cx - ext, cy + i * s, z], [cx + ext, cy + i * s, z]);
        if (across) out.push([...across, fade]);
    }
    return out;
}

// ========================================
// DRAWING
// ========================================

// Made once, moved every frame. Each marker is two strokes: a dark one under a coloured one, so it
// reads on a white wall and a black floor alike.
const parts = {};

function el(name, cls) {
    const e = document.createElementNS(SVG_NS, name);
    if (cls) e.setAttribute('class', cls);
    svg.appendChild(e);
    return e;
}

(function build() {
    if (!svg) return;
    // (First, so the markers are drawn over them.)
    parts.grid = el('g', 'fz-gz-grid');
    parts.gridLines = [];
    parts.shapeUnder = el('polygon', 'fz-gz-shape-under');
    parts.shape = el('polygon', 'fz-gz-shape');
    parts.corners = [];
    for (const k of AXES) {
        parts[k] = {
            ringUnder: el('polyline', 'fz-gz-under'),
            ring: el('polyline', 'fz-gz-ring fz-gz-' + k),
            shaftUnder: el('line', 'fz-gz-under'),
            shaft: el('line', 'fz-gz-shaft fz-gz-' + k),
            head: el('polygon', 'fz-gz-head fz-gz-' + k),
            label: el('text', 'fz-gz-label fz-gz-' + k),
        };
        parts[k].label.textContent = k.toUpperCase();
    }
    parts.dot = el('circle', 'fz-gz-dot');
    parts.box = el('rect', 'fz-gz-box');
    hide(parts.box);
})();

const xy = (p) => p[0].toFixed(1) + ',' + p[1].toFixed(1);

function hide(part) { part.style.display = 'none'; }
function show(part) { part.style.display = ''; }

/** Several selected: the shape through them (two points: a line, which a polygon of two draws), a dot on each. */
function renderShape(shape) {
    const pts = shape || [];
    while (parts.corners.length < pts.length) {
        const c = document.createElementNS(SVG_NS, 'circle');
        c.setAttribute('class', 'fz-gz-corner');
        c.setAttribute('r', '4');
        svg.insertBefore(c, parts.shape.nextSibling);
        parts.corners.push(c);
    }
    parts.corners.forEach((c, i) => {
        if (i >= pts.length) { hide(c); return; }
        c.setAttribute('cx', pts[i][0]);
        c.setAttribute('cy', pts[i][1]);
        show(c);
    });
    if (pts.length < 2) { hide(parts.shape); hide(parts.shapeUnder); return; }
    const line = pts.map(xy).join(' ');
    parts.shapeUnder.setAttribute('points', line);
    parts.shape.setAttribute('points', line);
    show(parts.shapeUnder); show(parts.shape);
}

/** Grid-locked: the floor grid's lines (none otherwise). */
function renderGrid(lines) {
    const ls = lines || [];
    while (parts.gridLines.length < ls.length) {
        const l = document.createElementNS(SVG_NS, 'line');
        parts.grid.appendChild(l);
        parts.gridLines.push(l);
    }
    parts.gridLines.forEach((l, i) => {
        if (i >= ls.length) { hide(l); return; }
        const g = ls[i];
        l.setAttribute('x1', g[0]); l.setAttribute('y1', g[1]);
        l.setAttribute('x2', g[2]); l.setAttribute('y2', g[3]);
        l.style.opacity = g[4].toFixed(2);
        show(l);
    });
}

/** The selection box while a press on the room is dragged out. */
function renderBox() {
    if (!parts.box) return;
    if (!box || !box.on) { hide(parts.box); return; }
    parts.box.setAttribute('x', Math.min(box.x0, box.x1));
    parts.box.setAttribute('y', Math.min(box.y0, box.y1));
    parts.box.setAttribute('width', Math.abs(box.x1 - box.x0));
    parts.box.setAttribute('height', Math.abs(box.y1 - box.y0));
    show(parts.box);
}

/** The box round everything drawn this frame, and the thing's top, in screen pixels, to onAnchor's
 *  listener; null when nothing is drawn. Padded by a label's size, which is drawn round its point. */
function reportAnchor(g) {
    if (!anchorFn) return;
    if (!g) { anchorFn(null); return; }
    let l = g.centre[0], r = l, t = g.centre[1], b = t;
    const take = (p) => {
        if (!p) return;
        if (p[0] < l) l = p[0];
        if (p[0] > r) r = p[0];
        if (p[1] < t) t = p[1];
        if (p[1] > b) b = p[1];
    };
    for (const k of AXES) {
        const a = g.axes[k];
        if (!a) continue;
        if (a.pts) a.pts.forEach(take);
        else { take(a.tip); take(a.label); }
    }
    take(g.top);
    const pad = 12;
    anchorFn({ x: g.centre[0], y: g.centre[1], left: l - pad, right: r + pad, top: t - pad, bottom: b + pad });
}

function render() {
    if (!svg) return;
    const g = layout();
    svg.classList.toggle('fz-gz-on', !!g && !g.fixed);
    svg.style.cursor = drag ? 'grabbing' : (hot ? 'grab' : '');
    reportAnchor(g);
    renderBox();
    if (!g || g.fixed) return;
    renderGrid(g.grid);
    renderShape(g.shape);

    for (const k of AXES) {
        const p = parts[k];
        const a = g.axes[k];
        const cls = (hot === k ? ' hot' : '') + (drag && drag.axis === k && view.b ? ' blocked' : '');
        for (const part of Object.values(p)) hide(part);
        if (!a) continue;

        if (a.pts) {
            const pts = a.pts.map(xy).join(' ');
            p.ringUnder.setAttribute('points', pts);
            p.ring.setAttribute('points', pts);
            p.ring.setAttribute('class', 'fz-gz-ring fz-gz-' + k + cls);
            show(p.ringUnder); show(p.ring);
        } else {
            for (const line of [p.shaftUnder, p.shaft]) {
                line.setAttribute('x1', a.from[0]); line.setAttribute('y1', a.from[1]);
                line.setAttribute('x2', a.neck[0]); line.setAttribute('y2', a.neck[1]);
            }
            p.shaft.setAttribute('class', 'fz-gz-shaft fz-gz-' + k + cls);
            // The head: a triangle on the screen, its point at the tip.
            const dx = a.tip[0] - a.neck[0], dy = a.tip[1] - a.neck[1];
            const len = Math.hypot(dx, dy) || 1;
            const nx = -dy / len * 7, ny = dx / len * 7;
            p.head.setAttribute('points', xy(a.tip) + ' ' + xy([a.neck[0] + nx, a.neck[1] + ny])
                + ' ' + xy([a.neck[0] - nx, a.neck[1] - ny]));
            p.head.setAttribute('class', 'fz-gz-head fz-gz-' + k + cls);
            show(p.shaftUnder); show(p.shaft); show(p.head);
            if (a.label) {
                p.label.setAttribute('x', a.label[0]);
                p.label.setAttribute('y', a.label[1]);
                p.label.setAttribute('class', 'fz-gz-label fz-gz-' + k + cls);
                show(p.label);
            }
        }
    }
    parts.dot.setAttribute('cx', g.centre[0]);
    parts.dot.setAttribute('cy', g.centre[1]);
    parts.dot.setAttribute('r', hot === 'c' ? 6 : 5);
    parts.dot.setAttribute('class', 'fz-gz-dot' + (hot === 'c' ? ' hot' : '') + (drag && drag.axis === 'c' && view.b ? ' blocked' : ''));
}

// ========================================
// GRABBING
// ========================================

/** Distance from a point to a segment, on the screen. */
function segDist(px, py, a, b) {
    const vx = b[0] - a[0], vy = b[1] - a[1];
    const l2 = vx * vx + vy * vy;
    const t = l2 > 0 ? Math.max(0, Math.min(1, ((px - a[0]) * vx + (py - a[1]) * vy) / l2)) : 0;
    return Math.hypot(px - (a[0] + vx * t), py - (a[1] + vy * t));
}

/** Which marker is under the pointer, if any: the nearest within GRAB_PX.
 *
 *  WHERE RINGS CROSS, THE ONE FACING YOU WINS. A ring seen edge-on is a line through the middle,
 *  and it crosses the ring you are looking straight at — seen from above, the two tipping rings lie
 *  right across the heading ring. Its reach is shortened by up to EDGE_PX the more edge-on it is,
 *  so a grab on the crossing turns the ring you can actually see going round. */
const EDGE_PX = 5;
/** The centre dot's reach: it wins over anything else this close, the arrows starting just past it. */
const DOT_PX = 10;
export function markerAt(px, py) {
    const g = layout();
    if (!g || g.fixed) return null;
    if (Math.hypot(px - g.centre[0], py - g.centre[1]) <= DOT_PX) return 'c';
    let best = null, bestD = GRAB_PX;
    for (const k of AXES) {
        const a = g.axes[k];
        if (!a) continue;
        let d = Infinity;
        if (a.pts) {
            for (let i = 1; i < a.pts.length; i++) d = Math.min(d, segDist(px, py, a.pts[i - 1], a.pts[i]));
            d += (1 - a.facing) * EDGE_PX;
        } else {
            d = segDist(px, py, a.from, a.tip);
        }
        if (d < bestD) { best = k; bestD = d; }
    }
    return best;
}

/** How far along an arrow's line (from O, along unit a) is the point closest to a ray. Null when the
 *  ray runs along the line, where every point is as close as any other. */
function closestT(O, a, ray) {
    const w0 = sub(O, ray.o);
    const b = dot(a, ray.d);
    const den = 1 - b * b;
    if (den < 1e-4) return null;
    return (b * dot(ray.d, w0) - dot(a, w0)) / den;
}

/** The angle round a ring the pointer is at, for a turn drag (radians). Where the ray meets the
 *  ring's plane — or, when the ring is seen edge-on, the pointer's angle round the ring's centre
 *  on the screen, which is what a person circling the mouse means either way. */
function angleAt(d, cam, px, py) {
    if (d.method === 'screen') {
        const c = project(cam, d.O);
        if (!c) return null;
        return d.facing * Math.atan2(-(py - c[1]), px - c[0]);
    }
    const ray = rayAt(cam, px, py);
    const den = dot(ray.d, d.a);
    if (Math.abs(den) < 1e-4) return null;
    const s = dot(sub(d.O, ray.o), d.a) / den;
    if (s <= 0) return null;
    const v = sub(add(ray.o, mul(ray.d, s)), d.O);
    return Math.atan2(dot(v, d.u2), dot(v, d.u1));
}

function startDrag(axis, px, py) {
    const cam = camera();
    const o = view.o.slice();
    const O = [o[0], o[1], o[2]];
    if (axis === 'c') {
        // The dot: no maths here, the game finds the world under the pointer (see the header).
        drag = { kind: 'free', axis, index: view.i };
    } else if (mode === 'move') {
        const a = moveAxes(o)[axis];
        const t0 = closestT(O, a, rayAt(cam, px, py));
        if (t0 === null) return false;
        drag = { kind: 'move', axis, a, O, t0, index: view.i, grid: view.w, A: (view.a || O).slice() };
    } else {
        const a = ringAxes(o)[axis];
        const { u1, u2 } = ringFrame(a);
        const ray = rayAt(cam, px, py);
        // Seen nearly edge-on, the plane is a line and the ray meets it anywhere: go by the screen.
        const method = Math.abs(dot(ray.d, a)) > 0.15 ? 'plane' : 'screen';
        const facing = dot(a, sub(cam.C, O)) >= 0 ? 1 : -1;
        const start = axis === 'x' ? o[3] : axis === 'y' ? o[4] : o[5];
        drag = { kind: 'turn', axis, a, O, u1, u2, method, facing, start, total: 0, prev: 0, index: view.i, grid: view.w };
        const first = angleAt(drag, cam, px, py);
        if (first === null) { drag = null; return false; }
        drag.prev = first;
    }
    hot = axis;
    root.classList.add('fz-dragging');
    render();
    return true;
}

function moveDrag(px, py, shift) {
    if (!view || !view.o) return;
    const cam = camera();
    // Snap on (G), or Shift held while it is off.
    const snapping = snap.on || !!shift;
    if (drag.kind === 'free') {
        queue(route.dragTo, { i: drag.index, x: px / cam.W, y: py / cam.H, snap: snapping });
    } else if (drag.kind === 'move') {
        const t = closestT(drag.O, drag.a, rayAt(cam, px, py));
        if (t === null) return;
        let delta = Math.max(-MAX_MOVE, Math.min(MAX_MOVE, t - drag.t0));
        const k = AXES.indexOf(drag.axis);
        if (snapping && snap.move > 0 && drag.grid && k < 2) {
            // Grid-locked along X or Y: the primary lands on the world's grid line, the middle keeping its place from it.
            // (Up is still by the step from where it was: floors are not on the grid.)
            const P = add(drag.O, mul(drag.a, delta));
            const off = drag.A[k] - drag.O[k];
            P[k] = Math.round((P[k] + off) / snap.move) * snap.move - off;
            queue(route.move, { i: drag.index, x: P[0], y: P[1], z: P[2] });
            return;
        }
        if (snapping && snap.move > 0) delta = Math.round(delta / snap.move) * snap.move;
        const P = add(drag.O, mul(drag.a, delta));
        queue(route.move, { i: drag.index, x: P[0], y: P[1], z: P[2] });
    } else {
        const ang = angleAt(drag, cam, px, py);
        if (ang === null) return;
        // Unwrapped, so a drag that goes round past half a turn keeps counting instead of jumping back.
        let step = ang - drag.prev;
        if (step > Math.PI) step -= Math.PI * 2;
        if (step < -Math.PI) step += Math.PI * 2;
        drag.total += step;
        drag.prev = ang;
        let deg = drag.total * 180 / Math.PI * RING_SIGN[drag.axis];
        let value = drag.start + deg;
        // Grid-locked: onto a whole step of the turn; else turned by whole steps from where it was.
        if (snapping && snap.turn > 0) {
            value = drag.grid ? Math.round(value / snap.turn) * snap.turn
                              : drag.start + Math.round(deg / snap.turn) * snap.turn;
        }
        value = ((value % 360) + 360) % 360;
        queue(route.move, { i: drag.index, ['r' + drag.axis]: value });
    }
}

/** One move a frame: the pointer reports faster than the game draws. */
function queue(name, payload) {
    pending = { name, payload };
    if (!frameId) frameId = requestAnimationFrame(flush);
}

function flush() {
    frameId = 0;
    if (pending) { nuiCallback(pending.name, pending.payload); pending = null; }
}

function endDrag() {
    if (!drag) return;
    const carried = drag.carry === true;
    if (frameId) { cancelAnimationFrame(frameId); frameId = 0; }
    flush();
    drag = null;
    root.classList.remove('fz-dragging');
    nuiCallback(route.end, {});
    render();
    if (carried && carryFn) carryFn(null);
}

/** A carry ends by its own left click (or Esc: cancelCarry), never by a button let go: the right one is the camera's. */
function endUnlessCarried() { if (!(drag && drag.carry)) endDrag(); }

// ========================================
// THE POINTER
// ========================================

function roomClick(px, py, ctrl) {
    nuiCallback(route.click, { x: px / window.innerWidth, y: py / window.innerHeight, ctrl });
}

/** A press on the room let go: a click where it went down, or everything in the box it was dragged out to. */
function endBox(px, py) {
    const b = box;
    box = null;
    renderBox();
    if (!b) return;
    if (!b.on) { roomClick(b.x0, b.y0, b.ctrl); return; }
    const W = window.innerWidth, H = window.innerHeight;
    nuiCallback(route.box, { x0: b.x0 / W, y0: b.y0 / H, x1: px / W, y1: py / H, ctrl: b.ctrl });
}

function cancelBox() {
    if (!box) return;
    box = null;
    renderBox();
}

if (svg) {
    svg.addEventListener('pointerdown', (e) => {
        // Only the left button. The right one turns the room, and the game is the one reading it.
        if (e.button !== 0 || looking) return;
        // Carried (FurnishGizmo.carry): the click puts it down where the pointer is.
        if (drag && drag.carry) {
            moveDrag(e.clientX, e.clientY, e.shiftKey);
            endDrag();
            e.preventDefault();
            return;
        }
        // (Ctrl held: always a click on the room, adding to the selection or taking away, even over a marker.)
        const k = e.ctrlKey ? null : markerAt(e.clientX, e.clientY);
        if (k && startDrag(k, e.clientX, e.clientY)) {
            try { svg.setPointerCapture(e.pointerId); } catch (_) { /* gone already */ }
            e.preventDefault();
            return;
        }
        // Not on a marker: a press on the room. Let go where it went down, a click, which selects whatever is under it (or
        // nothing); dragged, a box (where the route has one: the object viewer's has not). Not where only one may be
        // selected (Dungeon Mode) or a click means something else (a door pick), as Lua's multiOk: a press there is a click.
        if (!route.box || root.classList.contains('fz-live') || root.classList.contains('fz-picking')) {
            roomClick(e.clientX, e.clientY, e.ctrlKey);
            return;
        }
        box = { x0: e.clientX, y0: e.clientY, x1: e.clientX, y1: e.clientY, ctrl: e.ctrlKey, on: false };
        try { svg.setPointerCapture(e.pointerId); } catch (_) { /* gone already */ }
    });

    svg.addEventListener('pointermove', (e) => {
        if (looking) return;
        if (box) {
            box.x1 = e.clientX; box.y1 = e.clientY;
            if (!box.on && Math.hypot(box.x1 - box.x0, box.y1 - box.y0) >= BOX_PX) box.on = true;
            if (box.on) renderBox();
            return;
        }
        if (drag) { moveDrag(e.clientX, e.clientY, e.shiftKey); return; }
        const k = markerAt(e.clientX, e.clientY);
        if (k !== hot) { hot = k; render(); }
    });

    svg.addEventListener('pointerup', (e) => { if (box) endBox(e.clientX, e.clientY); else endUnlessCarried(); });
    svg.addEventListener('pointercancel', () => { cancelBox(); endUnlessCarried(); });
    svg.addEventListener('lostpointercapture', () => { cancelBox(); endUnlessCarried(); });
    svg.addEventListener('pointerleave', () => { if (!drag && hot) { hot = null; render(); } });
}

// ========================================
// WHAT furnisher.js TELLS IT
// ========================================

export const FurnishGizmo = {
    /** A furnishView from the game (o = false: nothing selected any more). */
    setView(d) {
        if (!d || !d.o) {
            endDrag();
            view = null;
            hot = null;
            render();
            return;
        }
        // The selection changed under a drag (a click, a row, a removal): that drag is over.
        if (drag && d.i !== drag.index) endDrag();
        // `t`: may it tilt (false: the world builder's upright things; a property's furniture always may).
        view = { c: d.c, r: d.r, k: d.k, o: d.o, i: d.i, b: d.b === true, t: d.t !== false,
                 h: typeof d.h === 'number' ? d.h : 0, n: d.n === true,
                 g: Array.isArray(d.g) && d.g.length > 1 ? d.g : null,
                 w: d.w === true, f: typeof d.f === 'number' ? d.f : 0, a: Array.isArray(d.a) ? d.a : null };
        if (view.n) { endDrag(); hot = null; }
        render();
    },
    /** fn({ x, y, left, right, top, bottom } | null): where the markers are, each time they are drawn. */
    onAnchor(fn) {
        anchorFn = typeof fn === 'function' ? fn : null;
    },
    setMode(m) {
        const next = m === 'rotate' ? 'rotate' : 'move';
        if (next === mode) return;
        endUnlessCarried();
        mode = next;
        hot = null;
        render();
    },
    /** The right button: while it is down the cursor is away and nothing here may be grabbed. (A carried one stays
     *  carried: it follows the pointer again once the room stops turning.) */
    setLooking(on) {
        looking = !!on;
        if (looking) {
            cancelBox();
            if (!(drag && drag.carry)) endDrag();
            if (hot && !drag) { hot = null; render(); }
        }
    },
    /** The selection (row `index`) on the pointer: it follows it over the world, as the centre dot dragged does, until
     *  a left click on the room puts it down (the Director's Place marker: client/property_furnish.lua carry; a fresh
     *  pick: `fresh`, which Esc takes back out). */
    carry(index, fresh) {
        endDrag();
        drag = { kind: 'free', axis: 'c', index, carry: true, fresh: fresh === true };
        hot = 'c';
        root.classList.add('fz-dragging');
        render();
        if (carryFn) carryFn({ index, fresh: fresh === true });
    },
    /** What is on the pointer now: { index, fresh }, or null. */
    carrying: () => (drag && drag.carry ? { index: drag.index, fresh: drag.fresh === true } : null),
    /** fn({ index, fresh } | null) as a carry starts and ends (the page's hint line). */
    onCarry(fn) { carryFn = typeof fn === 'function' ? fn : null; },
    /** Esc: the carry over. A fresh pick's last moves are dropped and the game is not told it was put down (it is about
     *  to go: furnishCarryCancel); a Place marker's carry is just left where it is. Answers { index, fresh }, or null. */
    cancelCarry() {
        if (!(drag && drag.carry)) return null;
        const c = { index: drag.index, fresh: drag.fresh === true };
        if (!c.fresh) { endDrag(); return c; }
        if (frameId) { cancelAnimationFrame(frameId); frameId = 0; }
        pending = null;
        drag = null;
        hot = null;
        root.classList.remove('fz-dragging');
        render();
        if (carryFn) carryFn(null);
        return c;
    },
    /** The step, and whether every drag snaps to it (G) or only one with Shift held. */
    setSnap(move, turn, on) {
        const was = snap.move;
        if (Number(move) > 0) snap.move = Number(move);
        if (Number(turn) > 0) snap.turn = Number(turn);
        snap.on = on === true;
        // (The floor grid is drawn at the step.)
        if (snap.move !== was && view && view.w) render();
    },
    reset() {
        cancelBox();
        endDrag();
        view = null;
        hot = null;
        mode = 'move';
        looking = false;
        render();
    },
    /** Send the drags somewhere else: { move, dragTo, end, click } callback names, or null for the furnisher's own.
     *  The object viewer's Move borrows the markers this way while the furnisher is closed. */
    route(names) {
        cancelBox();
        endDrag();
        // A borrower starts unsnapped (Shift still snaps a drag); the furnisher sets its own again as it opens.
        if (names) snap.on = false;
        // (A borrower has no box unless it names one: a press on the room is a click.)
        route = names ? { ...FURNISH_ROUTE, box: null, ...names } : FURNISH_ROUTE;
    },
};
