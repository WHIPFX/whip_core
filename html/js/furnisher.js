// The furnisher: the in-world furniture editor for properties. Player-facing, not a /whip panel section: an ordinary
// player opens it inside their own house, so it has its own overlay, stylesheet and keyboard scope. It shares the
// character creator's shell (a thing in the world with controls floating round it):
//   .fz-scale     one transform-scaled box. Not `zoom`: on CEF (Chromium 103) zoom scales what is painted without
//                 scaling what is clicked (see creator.css).
//   the rail      three cluster cards over a category list.
//   the grid      flex-wrap with an explicit card basis, not CSS grid; chunked so a large catalog does not hitch.
// Specific to this screen:
//   Right mouse   the room turns only while the right button is held. NUI focus is held for the whole session; while
//                 the button is down the cursor is put away and this page goes inert (.fz-looking).
//   The markers   the selected object wears X / Y / Z arrows, or rings after R, dragged with the mouse
//                 (js/furnisher-gizmo.js, an SVG under this shell). A click on the room that is not on a marker
//                 selects what it lands on (Ctrl+click adds to it, a drag selects everything in its box); the shell
//                 takes clicks only on its own controls.
//   The bar       along the top: the property, the Furniture switch that shows the catalog, Move / Rotate, the snap
//                 step, Grid lock (L), Exit and Save.
//   The bubble    beside the selection (#fz-sel): its name, Go to, Remove, and how to move or turn it (placeSel).
//   Typing        the game reads the keyboard too (KeepInput), so the search box tells Lua when it has focus
//                 (focusin/focusout) and client/property_furnish.lua stands its key reader down until it is blurred.
// It draws and does not decide: all state on screen (selection, transform, snap step, object count, cursor) is pushed
// from client/property_furnish.lua as a whole `furnishState` message. It owns only the grid's filter (cluster,
// category, search text), whether the catalog is showing, and where the bubble sits.

import { NuiRouter } from './router.js';
import { nuiCallback, escapeHtml, propImageUrl, vehicleImageUrl, pedImageUrl, fitPicture } from './utils.js';
import { GLYPHS } from './furnisher-data.js';
import { FurnishGizmo } from './furnisher-gizmo.js';
import { PED_CLUSTERS, PED_CATEGORIES, PEDS } from './builder-peds.js';
import { padGlyph } from './pad-glyphs.js';
import { openPadKeyboard, padKeyboardOpen } from './pad-keyboard.js';
import { createRing } from './pad-ring.js';
import { emoteMenuUp } from './emotes.js';
import { directorBuilder } from './director-loader.js';

/* The world builder's More tab: the things that are a place rather than a model. A door is picked by
   clicking one in the world (client/furnish_builder.lua), not put down. `flat`: no row of groups over its list, only
   its categories (Places, then the Weapons' Pistols, SMGs...: the session adds them, furnishOpen). */
const MORE = {
    flat: true,
    clusters: [{ key: 'places', label: 'Places', glyph: 'pin' }],
    categories: [{ key: 'marks', label: 'Places', cluster: 'places', glyph: 'pin' }],
    props: [
        { model: 'spot', kind: 'spot', category: 'marks', name: 'Spot', glyph: 'pin' },
        { model: 'groundItem', kind: 'groundItem', category: 'marks', name: 'Item spot', glyph: 'box' },
        { model: 'container', kind: 'container', category: 'marks', name: 'Container', glyph: 'chest' },
        { model: 'door', kind: 'door', category: 'marks', name: 'Door: click one', glyph: 'door' },
        // A path NPCs walk (its points are placed from its page: + Point).
        { model: 'route', kind: 'route', category: 'marks', name: 'Route', glyph: 'pin' },
    ],
};

let fzOpen = false;
/* THE WORLD BUILDER (the Director's World tab): the same screen opened by
   client/property_furnish.lua's Furnisher.open, with its options here (furnishOpen's `builder`) —
   its tabs (Props, NPCs, Vehicles, More, Placed), its NPC / vehicle / More lists, "By name", and
   Done for Save. Null in a property's room, which has only Catalog and Placed. */
let fzBuilder = null;
/* What each of the builder's tabs places (a More tile names its own kind). A tab here can place a
   model by its name, too. */
const TAB_KIND = { catalog: 'prop', npcs: 'npc', vehicles: 'vehicle' };
/* The search's words, by tab: the builder's say that a model's name can be typed there too. */
const SEARCH_HINT = { catalog: 'Search props…', npcs: 'Search people…', vehicles: 'Search vehicles…', more: 'Search places…',
                      placed: 'Search what is placed…' };
const SEARCH_HINT_BYNAME = { catalog: 'Search props, or type a model\'s name', vehicles: 'Search vehicles, or type a model\'s name' };
/* Said over the by-name offer when nothing in the list matches the text. (A ped by its name: Input ped name.) */
const BYNAME_NONE = { catalog: 'No prop in the catalog is called that.', vehicles: 'No vehicle in the list is called that.' };
/* What the list calls each kind, and the glyph it draws one with when there is no picture. */
const KIND_TEXT = { prop: 'Prop', npc: 'NPC', vehicle: 'Car', spot: 'Spot', groundItem: 'Item', container: 'Container', door: 'Door',
                    point: 'Point', route: 'Route' };
const KIND_GLYPH = { prop: 'box', npc: 'person', vehicle: 'car', spot: 'pin', groundItem: 'box', container: 'chest', door: 'door',
                     point: 'pin', route: 'pin' };
/* model -> the NPCs tab's record, for a placed NPC's name when it has no label of its own. */
const PED_OF = {};
for (const p of PEDS) PED_OF[p.model] = p;
/* Is the right button down — is the player turning the room rather than using the cursor? Pushed
   from Lua, which is the side that reads the button. The page uses it for one thing only: going
   inert, so a pointer being dragged across a marker on its way to swinging the camera cannot edit
   anything. */
let fzLooking = false;
/* Is the catalog showing? Hidden until the card's Furniture switch is pressed:
   the room is what the screen is for. */
let fzCatalogOpen = false;

let fzCatalog = { clusters: [], categories: [], props: [] };
/* model -> the catalog's record for it, so a PLACED object can be drawn with the same picture and
   the same category glyph as the tile it came from. Built once per catalog push rather than walked
   per row: the object list can be a hundred and fifty long. */
let fzProps = {};

/* Which side of the column is showing: the catalog to place FROM, or what is already in the room.
   The one piece of screen state this file owns outright — Lua has no opinion about which list the
   player happens to be looking at. */
let fzTab = 'catalog';
/* [{ index, model }], pushed whole whenever the set of placed objects changes. */
let fzItems = [];
/* Which row is selected, straight from Lua. Nine identical chairs share a name; only this tells
   them apart. */
let fzSelIndex = null;
/* Several selected (Ctrl+click, or a box dragged over the room), straight from Lua: their rows, the primary (fzSelIndex) last;
   null with one or none. */
let fzSelRows = null;
/** Is this row selected (the one, or one of several)? */
const rowPicked = (index) => (fzSelRows ? fzSelRows.includes(index) : fzSelIndex === index);

let fzCluster = null;     // active cluster key, or null before the first catalog arrives
let fzCategory = null;     // null = every category in the active cluster
let fzSearch = '';

/* The last furnishState, whole. The card and the readout are views of this and nothing else. */
let fzState = {};

let fzExitArmed = null;    // timeout id while Exit awaits confirmation

/* Big lists append in slices as the grid scrolls rather than building every node up front. Both
   sides of the column use it: a catalog runs to hundreds of props and a furnished house to a
   hundred and fifty objects, and neither wants that many nodes created on a tab click.
   `gridDraw` is whichever of the two row builders the open tab uses. */
const GRID_CHUNK = 60;
let gridTiles = [];
let gridRendered = 0;
let gridDraw = null;

const $ = (id) => document.getElementById(id);

// ========================================
// CATALOG SHAPE
// ========================================

/** What the open tab (or `tab`) places from, { clusters, categories, props }: the catalog, or one of the world
 *  builder's own lists, which arrive with its options. The Placed tab reads the catalog's shape. */
function source(tab = fzTab) {
    if (tab === 'catalog' || tab === 'placed' || !fzBuilder) return fzCatalog;
    if (tab === 'npcs' && fzBuilder.director) return npcSource();
    const s = fzBuilder.sources && fzBuilder.sources[tab];
    return s || { clusters: [], categories: [], props: [] };
}

/* THE DIRECTOR'S NPCs: the game's peds (builder-peds.js), then the server's lore characters, a group of their own
   (director/app.js builder.lore: each { key, name, model, picture, pictureFrame }). One picked is placed as that
   character: its ped, its name, def.lore (client/furnish_builder.lua pick, app.js newWorldThing). */
const LORE_CLUSTER = { key: 'lore', label: 'Lore characters', glyph: 'star' };
const LORE_CATEGORY = { key: 'lore', label: 'Lore characters', cluster: 'lore', glyph: 'star' };
/* First in every group but the lore characters': a ped typed by its exact name (showPedName). */
const PED_INPUT = { model: '', kind: 'npc', input: true, name: 'Input ped name' };
/* THE DIRECTOR'S VEHICLES: first, a Vehicle pool: one spot, the models a run picks from by their odds on its page
   (client/furnish_builder.lua pick). While its page is adding a model (director/app.js builder.modelPick), a vehicle
   pressed joins its list instead of being placed. */
const CAR_RANDOM = { model: '', kind: 'vehicle', random: true, name: 'Vehicle pool' };
let npcSrc = null, npcSrcLore = null;
// Lore characters' headshots arrive after their list does (lore-faces.js): the tiles, and the selection's picture, are
// made again with them.
window.addEventListener('whip:loreportraits', () => { npcSrc = null; selPic = null; });

function npcSource() {
    const app = director();
    const lore = (app && app.lore && app.lore()) || [];
    if (npcSrc && npcSrcLore === lore) return npcSrc;
    npcSrcLore = lore;
    npcSrc = {
        clusters: PED_CLUSTERS.concat([LORE_CLUSTER]),
        categories: PED_CATEGORIES.concat([LORE_CATEGORY]),
        // (No picture link: the headshot of a look made in the character editor, unframed.)
        props: PEDS.concat(lore.map((c) => ({ model: c.model || '', kind: 'npc', category: 'lore', name: c.name, lore: c.key,
                                              picture: c.picture || c.portrait || '', frame: c.picture ? c.pictureFrame || null : null }))),
    };
    return npcSrc;
}

/** A lore character's picture framed as /whip frames it (wp/lore.js frameStyle): the point kept in view, the zoom. */
function frameCss(f) {
    const n = (v, d) => (f && Number.isFinite(Number(v)) ? Number(v) : d);
    const x = n(f && f.x, 50), y = n(f && f.y, 50), z = n(f && f.z, 1);
    return `object-position:${x}% ${y}%;transform-origin:${x}% ${y}%;transform:scale(${z})`;
}

function clusters() { return source().clusters || []; }
function categories() { return source().categories || []; }

/** The tabs on show: a property's room has the catalog and what is placed; the builder names its own. */
function tabsList() {
    return fzBuilder && Array.isArray(fzBuilder.tabs) && fzBuilder.tabs.length ? fzBuilder.tabs : ['catalog', 'placed'];
}

function tabLabel(tab) {
    if (tab === 'catalog') return fzBuilder ? 'Props' : 'Catalog';
    return { npcs: 'NPCs', vehicles: 'Vehicles', more: 'More', placed: 'Placed' }[tab] || tab;
}

/** The cluster a category belongs to, falling back to the first — see the note in config.lua. */
function clusterOf(cat) {
    const cs = clusters();
    if (cat.cluster && cs.some((c) => c.key === cat.cluster)) return cat.cluster;
    return cs.length ? cs[0].key : null;
}

function categoriesIn(clusterKey) {
    return categories().filter((c) => clusterOf(c) === clusterKey);
}

function glyph(name) {
    return GLYPHS[name] || GLYPHS.none;
}

/** A group card's art: the picture of its `model` (a car, a ped, a prop, as the tab's tiles are drawn), its glyph
 *  standing in while there is none; else its glyph. */
function clusterArt(c) {
    const kind = TAB_KIND[fzTab];
    const url = c.model && { vehicle: vehicleImageUrl, npc: pedImageUrl, prop: propImageUrl }[kind];
    if (!url) return '<span class="fz-cluster-art">' + glyph(c.glyph) + '</span>';
    return '<span class="fz-cluster-pic">' + pictureOr('fz-cluster', url(c.model), c.glyph, fitAttrs(kind, c.model)) + '</span>';
}

/** A prop's display name: whatever the catalog recorded, else the model with its underscores
 *  opened out. Model names are the only name most props will ever have — `v_res_tre_sofa` reads as
 *  "v res tre sofa", which is not beautiful and is honest. */
function propLabel(p) {
    if (p.name) return p.name;
    return String(p.model).replace(/_/g, ' ');
}

function modelLabel(model) {
    return String(model || '').replace(/_/g, ' ');
}

// ========================================
// THE TABS
// ========================================

function renderSubtabs() {
    const bar = $('fz-subtabs');
    if (!bar) return;
    const n = fzItems.length;
    bar.innerHTML = tabsList().map((tab) => '<button class="fz-subtab' + (fzTab === tab ? ' active' : '')
        + '" data-fz="tab" data-tab="' + escapeHtml(tab) + '">' + escapeHtml(tabLabel(tab))
        + (tab === 'placed' && n ? ' <span class="fz-subtab-n">' + n + '</span>' : '') + '</button>').join('');
}

/** Can the open tab place a model by its name (the world builder's tabs that place one)? */
function byNameTab() {
    // (Not the NPCs': a ped by its name is the Input ped name tile's, which says if it is not one.)
    return !!(fzBuilder && fzBuilder.byName && TAB_KIND[fzTab] && fzTab !== 'npcs');
}

/** The search's text as a model's name, when it reads as one (letters, digits and _, as Lua takes
 *  them), on a tab that places by name; else ''. */
function byNameModel() {
    const text = fzSearch.trim();
    return byNameTab() && /^\w{1,64}$/.test(text) ? text : '';
}

/** The world builder's "by name": the search's own text offered as the model to place, with a line
 *  over it when nothing in the list matches. Drawn with the grid, which says whether anything does. */
function renderByName() {
    const row = document.querySelector('#furnisher .fz-byname');
    if (!row) return;
    const model = byNameModel();
    row.classList.toggle('show', model !== '');
    const name = $('fz-byname-model');
    if (name) name.textContent = model;
    const none = $('fz-byname-none');
    if (none) none.textContent = model && gridTiles.length === 0 ? (BYNAME_NONE[fzTab] || '') : '';
}

function searchHint(tab) {
    return (byNameTab() && SEARCH_HINT_BYNAME[tab]) || SEARCH_HINT[tab] || SEARCH_HINT.catalog;
}

/* The list last placed from (Catalog, or the builder's NPCs, Vehicles, More): back from Placed to the
   same one keeps its open group and category, as the furnisher always did. */
let fzSourceTab = 'catalog';

function setTab(tab) {
    if (tab === fzTab) return;
    fzTab = tab;
    // (Another list than the one a new model is picked from: the picking is over.)
    if (remodel && tab !== REMODEL_TAB[remodel.kind]) { remodel = null; renderRemodel(); }

    // THE RAIL GOES WITH THE CATALOG. Its clusters and categories describe what you can place, not
    // what you have placed — leaving them up over the object list would be filters that do nothing.
    const cols = document.querySelector('#furnisher .fz-columns');
    if (cols) cols.classList.toggle('fz-list', fzTab === 'placed');

    // Another list to place from (the builder's NPCs, vehicles, More): its own first group. The same
    // one again (back from Placed) keeps what was open.
    if (fzTab !== 'placed' && fzTab !== fzSourceTab) {
        fzSourceTab = fzTab;
        const cs = clusters();
        if (!cs.some((c) => c.key === fzCluster)) fzCluster = cs.length ? cs[0].key : null;
        fzCategory = null;
    }

    const search = $('fz-search');
    if (search) search.placeholder = searchHint(fzTab);

    renderSubtabs();
    renderRail();
    renderGrid();
}

// ========================================
// THE RAIL
// ========================================

function renderRail() {
    const rail = $('fz-rail');
    if (!rail) return;

    // (A flat list, More's: no row of groups at all, its categories are all there is.)
    let html = '';
    if (!source().flat) {
        html += '<div class="fz-clusters">';
        for (const c of clusters()) {
            html += '<button class="fz-cluster' + (c.key === fzCluster ? ' active' : '')
                  + '" data-fz="cluster" data-cluster="' + escapeHtml(c.key) + '">'
                  + clusterArt(c)
                  + '<span class="fz-cluster-label">' + escapeHtml(c.label || c.key) + '</span>'
                  + '</button>';
        }
        html += '</div>';
    }
    html += '<div class="fz-rail-list">';

    // "All" first, because most of the time you know roughly what you want and not which drawer
    // somebody filed it in.
    html += '<button class="fz-rail-chip' + (fzCategory === null ? ' active' : '')
          + '" data-fz="category" data-cat="">All</button>';
    for (const cat of categoriesIn(fzCluster)) {
        html += '<button class="fz-rail-chip' + (fzCategory === cat.key ? ' active' : '')
              + '" data-fz="category" data-cat="' + escapeHtml(cat.key) + '">'
              + escapeHtml(cat.label || cat.key) + '</button>';
    }
    html += '</div>';

    rail.innerHTML = html;
}

// ========================================
// THE GRID
// ========================================

function visibleProps() {
    const q = fzSearch.trim().toLowerCase();
    // A search reaches across the WHOLE catalog, not just the open drawer. Typing "sofa" and
    // getting nothing because you happened to be looking at Lighting is the kind of empty result
    // that reads as "we do not have one".
    const inCluster = q ? null : categoriesIn(fzCluster).map((c) => c.key);

    const list = (source().props || []).filter((p) => {
        if (q) return (p.model + ' ' + (p.name || '')).toLowerCase().indexOf(q) >= 0;
        if (fzCategory !== null) return p.category === fzCategory;
        return inCluster.indexOf(p.category) >= 0;
    });
    // (Neither while a new model is picked for the selection: it takes a model of the list.)
    if (remodel) return list;
    // The Director's NPCs: Input ped name first, in every group but the lore characters' (who bring their own ped).
    if (fzTab === 'npcs' && fzBuilder && fzBuilder.director && (q || fzCluster !== 'lore')) list.unshift(PED_INPUT);
    // The Director's vehicles: Vehicle pool first (not while a model is being picked for one).
    if (fzTab === 'vehicles' && fzBuilder && fzBuilder.director && !modelPicking()) list.unshift(CAR_RANDOM);
    return list;
}

// ---- CHANGE MODEL: the selection made as a model picked from Place, all else it is kept (director/app.js builder.remodel) ----

/** Which list each kind's new model is picked from. */
const REMODEL_TAB = { npc: 'npcs', vehicle: 'vehicles', prop: 'catalog' };
let remodel = null;   // { id, kind, label, model } while a new model is picked for the selection

/** The bubble's Change model: Place opens on the selection's own list, a bar over it saying so; a tile pressed is its
 *  new model. Not a door (the world's own), a random vehicle (its models are its page's), nor a marker kind. */
function startRemodel() {
    const app = director();
    const d = fzState || {};
    const it = selectedItem(d);
    const kind = (it && it.kind) || 'prop';
    if (!app || !it || !REMODEL_TAB[kind] || it.random) return;
    const id = selectionId(app);
    if (!id) return;
    remodel = { id, kind, label: selectedName(d), model: d.selected.model };
    setCatalogOpen(true);
    if (fzTab !== REMODEL_TAB[kind]) setTab(REMODEL_TAB[kind]);
    renderRemodel();
    renderGrid();
}

/** Picking over: the bar goes, the lists are as they were. */
function endRemodel() {
    if (!remodel) return;
    remodel = null;
    renderRemodel();
    renderGrid();
}

function renderRemodel() {
    const bar = $('fz-remodel');
    if (!bar) return;
    bar.classList.toggle('show', !!remodel);
    // (Not .fz-remodel: that is the bar's own, its tint and padding, which on the root covered the screen.)
    const root = $('furnisher');
    if (root) root.classList.toggle('fz-remodeling', !!remodel);
    if (remodel) $('fz-remodel-text').textContent = 'A new model for ' + remodel.label;
}

// The Configure page's Change model, its General tab's last row (director/panels.js): the selection's, as it is the page's.
window.addEventListener('director-remodel', () => startRemodel());

/** A tile pressed while picking: the selection's new model (a lore character picked from the NPCs: it is them). */
async function remodelTo(el) {
    const r = remodel;
    const app = director();
    if (!r || !app) return;
    const old = (source(REMODEL_TAB[r.kind]).props || []).find((p) => p.model === r.model && !p.lore);
    const res = await app.remodel(r.id, { model: el.dataset.model, lore: el.dataset.lore || undefined, name: el.dataset.name,
                                          was: old ? propLabel(old) : undefined });
    if (res === true) { endRemodel(); return; }
    if (res !== 'cancelled' && typeof window.uiNotify === 'function') window.uiNotify({ text: res, type: 'error', duration: 3500 });
}

/** A random vehicle's page adding a model: { id, label } of that car, or null. */
function modelPicking() {
    const app = director();
    return (app && app.modelPick && app.modelPick()) || null;
}

/** A picture that may not exist yet (a vehicle's, an NPC's): the image, and its glyph standing in
 *  when it fails to load (.fz-noimg on the tile or row, set by the image's own error). */
function pictureOr(cls, url, glyphName, fit) {
    return '<img class="' + cls + '-img" src="' + escapeHtml(url) + '" alt=""' + (fit || '')
         + ' onerror="this.parentNode.classList.add(\'fz-noimg\')">'
         + '<span class="' + cls + '-art ' + cls + '-fallback">' + glyph(glyphName) + '</span>';
}

/** What an img says for fitPicture (utils.js; run as each loads, bind): what it is, so the thing in it is shown
 *  as big as its box allows, and `head` for a ped's head and shoulders only. */
function fitAttrs(kind, model, head) {
    return ' data-fit="' + escapeHtml(kind) + '" data-model="' + escapeHtml(model || '') + '"' + (head ? ' data-fit-head' : '');
}

function tileHtml(p) {
    if (p.input) {
        return '<div class="fz-tile fz-tile-input" data-fz="pedname" data-kind="npc" title="Any ped, by its exact name">'
             + '<span class="fz-tile-art">' + glyph('keyboard') + '</span><span class="fz-tile-name">Input ped name</span></div>';
    }
    if (p.random) {
        return '<div class="fz-tile fz-tile-input" data-fz="tile" data-kind="vehicle" data-random="1"'
             + ' title="One spot, several models: each time a run makes it, one of them, by the chances on its page">'
             + '<span class="fz-tile-art">' + glyph('dice') + '</span><span class="fz-tile-name">Vehicle pool</span></div>';
    }
    const model = escapeHtml(p.model);
    const kind = p.kind || TAB_KIND[fzTab] || 'prop';
    // The image URL is the model name by convention — the same rule the manufacturer logos follow.
    // A prop with no picture yet falls back to its CATEGORY's glyph, which says more than a broken
    // image icon and exactly as much as a generic box would. A vehicle's and an NPC's pictures are
    // asked for whatever they are (whip_media_previews/img/vehicles, img/peds), the glyph standing in.
    let art;
    if (kind === 'vehicle') art = pictureOr('fz-tile', vehicleImageUrl(p.model), 'car', fitAttrs('vehicle', p.model));
    else if (kind === 'npc' && p.lore && p.picture) {
        // A lore character's own picture (/whip, Lore characters), round and framed as /whip frames it.
        art = '<span class="fz-tile-face"><img class="fz-tile-face-img" src="' + escapeHtml(p.picture) + '" alt="" style="'
            + frameCss(p.frame) + '" onerror="this.closest(\'.fz-tile\').classList.add(\'fz-noimg\')"></span>'
            + '<span class="fz-tile-art fz-tile-fallback">' + glyph('star') + '</span>';
    } else if (kind === 'npc') art = pictureOr('fz-tile', pedImageUrl(p.model), categoryGlyph(p.category) || 'person', fitAttrs('npc', p.model));
    else if (p.hasImage) art = '<img class="fz-tile-img" src="' + escapeHtml(p.image || propImageUrl(p.model)) + '" alt=""' + fitAttrs('prop', p.model) + '>';
    else art = '<span class="fz-tile-art">' + glyph(p.glyph || categoryGlyph(p.category)) + '</span>';

    // (A lore character with no ped yet is shown, dimmed: picked, it says where to give them one.)
    return '<div class="fz-tile' + (p.lore && !p.model ? ' fz-tile-off' : '') + '" data-fz="tile"'
         + ' data-model="' + model + '" data-kind="' + escapeHtml(kind) + '" data-name="' + escapeHtml(propLabel(p)) + '"'
         + (p.lore ? ' data-lore="' + escapeHtml(p.lore) + '"' : '')
         + (p.weapon ? ' data-weapon="' + escapeHtml(p.weapon) + '"' : '')
         + ' title="' + (p.lore ? escapeHtml(propLabel(p)) + (p.model ? ' · ' + model : ' · no ped yet') : model) + '">'
         + art
         + '<span class="fz-tile-name">' + escapeHtml(propLabel(p)) + '</span>'
         + '</div>';
}

function categoryGlyph(key) {
    const cat = categories().find((c) => c.key === key);
    return (cat && cat.glyph) || 'box';
}

// ========================================
// THE OBJECT LIST
//
// What is actually in the room, one row each, addressed by the index Lua gave it. Clicking a row
// makes the SAME selection clicking the thing in the room would make — so the markers, Go to and
// Remove all work on it without knowing where the selection came from, and the outline in the room
// marks which of nine identical chairs is meant.
// ========================================

/** The catalog's record for a placed model, or null if it is no longer in the catalog. */
function propOf(model) {
    return fzProps[model] || null;
}

function rowHtml(it) {
    const model = escapeHtml(it.model);
    const p = propOf(it.model);
    const kind = it.kind || 'prop';

    // A PLACED MODEL MAY NOT BE IN THE CATALOG ANY MORE — it can be removed from the config after
    // somebody furnished with it, and the row still has to draw. Falling back to the generic glyph
    // rather than to nothing: the object is really there, whatever the catalog currently thinks.
    // The world builder's NPCs and cars ask for their pictures; its markers draw their kind's glyph.
    let art;
    if (kind === 'vehicle') art = pictureOr('fz-row', vehicleImageUrl(it.model), 'car', fitAttrs('vehicle', it.model));
    else if (kind === 'npc') art = loreFaceHtml(it, 'fz-row') || pictureOr('fz-row', pedImageUrl(it.model), 'person', fitAttrs('npc', it.model, true));
    else if (kind !== 'prop' && kind !== 'container') art = '<span class="fz-row-art">' + glyph(KIND_GLYPH[kind] || 'box') + '</span>';
    else if (p && p.hasImage) art = '<img class="fz-row-img" src="' + escapeHtml(p.image || propImageUrl(it.model)) + '" alt=""' + fitAttrs('prop', it.model) + '>';
    else art = '<span class="fz-row-art">' + glyph(p ? categoryGlyph(p.category) : (KIND_GLYPH[kind] || 'box')) + '</span>';

    const ped = kind === 'npc' ? PED_OF[it.model] : null;
    const name = it.label || (p ? propLabel(p) : ped ? ped.name : modelLabel(it.model));
    return '<div class="fz-row' + (rowPicked(it.index) ? ' selected' : '') + '"'
         + ' data-fz="row" data-index="' + it.index + '" title="' + model + '">'
         // (In a box of its own that cuts what spills: an NPC's picture is scaled up round its head.)
         + '<span class="fz-row-pic">' + art + '</span>'
         + '<span class="fz-row-name">' + escapeHtml(name) + '</span>'
         + (fzBuilder ? '<span class="fz-row-kind">' + escapeHtml(KIND_TEXT[kind] || kind) + '</span>' : '')
         + '<span class="fz-row-num">' + it.index + '</span>'
         + '</div>';
}

function visibleItems() {
    const q = fzSearch.trim().toLowerCase();
    if (!q) return fzItems;
    return fzItems.filter((it) => {
        const p = propOf(it.model);
        return (it.model + ' ' + ((p && p.name) || '') + ' ' + (it.label || '')).toLowerCase().indexOf(q) >= 0;
    });
}

// ========================================
// THE GRID — either list, same machinery
// ========================================

function renderGrid() {
    const grid = $('fz-grid');
    if (!grid) return;

    const placed = fzTab === 'placed';
    gridTiles = placed ? visibleItems() : visibleProps();
    gridDraw = placed ? rowHtml : tileHtml;
    gridRendered = 0;
    grid.scrollTop = 0;
    grid.classList.toggle('fz-grid-rows', placed);
    renderByName();

    if (gridTiles.length === 0) {
        // (The by-name offer says it over itself when it is up: the grid stays quiet.)
        grid.innerHTML = '<div class="fz-empty">' + (byNameModel() ? '' : emptyText(placed)) + '</div>';
        return;
    }

    grid.innerHTML = '';
    appendGridChunk();
}

/** WHICH KIND OF EMPTY, because they need different answers — and telling somebody the catalog is
 *  empty while it holds two hundred props sends them to fix the wrong thing. */
function emptyText(placed) {
    if (placed) {
        return fzItems.length === 0
            ? 'Nothing placed yet. Look where something should go and pick it from '
              + (fzBuilder ? 'a tab' : 'the catalog') + ': it appears there, ready to drag.'
            : 'Nothing placed matches that.';
    }
    if (fzTab === 'npcs' && fzCluster === 'lore' && !fzSearch.trim()) {
        return 'No lore characters yet. Make one in /whip: Director, Lore characters.';
    }
    if (fzTab !== 'catalog') return 'Nothing here matches.';
    return (fzCatalog.props || []).length === 0
        ? 'The prop catalog is empty. A dev can fill it with /prop add while looking at something.'
        : 'Nothing here matches.';
}

function appendGridChunk() {
    if (gridRendered >= gridTiles.length || !gridDraw) return;
    const grid = $('fz-grid');
    const slice = gridTiles.slice(gridRendered, gridRendered + GRID_CHUNK);
    const frag = document.createElement('div');
    frag.innerHTML = slice.map(gridDraw).join('');
    while (frag.firstChild) grid.appendChild(frag.firstChild);
    gridRendered += slice.length;
}

function onGridScroll() {
    const grid = $('fz-grid');
    if (grid.scrollTop + grid.clientHeight > grid.scrollHeight - 300) appendGridChunk();
}

/** Repaint which row is selected without rebuilding the list — the selection moves on every click
 *  in the room and every row click, and rebuilding a hundred and fifty rows for a class change
 *  would also throw away the scroll position the player was reading from. */
function markSelectedRow() {
    const grid = $('fz-grid');
    if (!grid) return;
    grid.querySelectorAll('.fz-row').forEach((el) => {
        el.classList.toggle('selected', rowPicked(Number(el.dataset.index)));
    });
}

// ========================================
// THE BAR AND THE BUBBLE
//
// The bar is along the top and always on screen, because it is where the screen's switches live:
// the Furniture catalog (hidden until asked for), what the markers do (Move / Rotate — R), and, while
// snap is on (G), its step. The bubble is what is selected, beside it in the room: what it is, and
// Remove; Go to too while it is off the screen.
// ========================================

function num(v, dp) {
    return (typeof v === 'number' ? v : 0).toFixed(dp === undefined ? 2 : dp);
}

/** A placed or picked model's name: the catalog's, when it has one. */
function nameOf(model) {
    const p = propOf(model);
    return p ? propLabel(p) : modelLabel(model);
}

/** What the selection is called: the world builder's own name for the thing, else its model's. */
function selectedName(d) {
    const it = typeof d.selectedIndex === 'number' ? fzItems.find((x) => x.index === d.selectedIndex) : null;
    return (it && it.label) || (d.selected ? nameOf(d.selected.model) : '');
}

/** The step, as the chip and the strip say it ("Grid" first while locked to the world grid). */
function stepText(d) {
    return (d.grid === true ? 'Grid ' : 'Snap ') + num(d.move) + ' m · ' + num(d.turn, 0) + '°';
}

function setCatalogOpen(open) {
    fzCatalogOpen = !!open;
    const root = $('furnisher');
    if (root) root.classList.toggle('fz-catalog-open', fzCatalogOpen);
    const btn = $('fz-catalog-btn');
    if (btn) btn.classList.toggle('on', fzCatalogOpen);
    // A field keeping focus while its column is hidden would keep Lua's key reader stood down for
    // a box nobody can see. Blurring fires focusout, which tells Lua.
    if (!fzCatalogOpen) {
        const search = $('fz-search');
        if (search) search.blur();
        endRemodel();
    }
    // The bubble keeps clear of the catalog: where it may go has changed.
    selFrame = null;
    placeSel();
}

function renderCard(d) {
    document.querySelectorAll('#furnisher [data-fz="mode"]').forEach((el) => {
        el.classList.toggle('on', el.dataset.mode === (d.mode || 'move'));
    });
    // The snap chip shows only while snap is on (G), or on a pad (furnisher.css): what it says.
    const on = d.snap === true;
    const root = $('furnisher');
    if (root && root.classList.contains('fz-snap-on') !== on) {
        root.classList.toggle('fz-snap-on', on);
        selFrame = null;   // (the bar's width changed)
    }
    const step = $('fz-steptext');
    if (step) step.textContent = on ? stepText(d) : 'Snap off';
    const grid = $('fz-grid-btn');
    if (grid) grid.classList.toggle('on', d.grid === true);
    // The Director's world builder has no bar: the hint line says what R switches to, and G the step while snap is on.
    const dir = !!(fzBuilder && fzBuilder.director);
    const modeHint = $('fz-mode-hint');
    if (modeHint) modeHint.textContent = (d.mode || 'move') === 'rotate' ? 'Move' : 'Rotate';
    const snapHint = $('fz-snap-hint');
    if (snapHint) snapHint.textContent = dir && on ? stepText(d) : 'Snap';
    renderSel(d);
}

// ---- the bubble ----

/** The selected row of the object list, or null. */
function selectedItem(d) {
    return typeof d.selectedIndex === 'number' ? fzItems.find((x) => x.index === d.selectedIndex) || null : null;
}

/** Several selected: their rows of the object list, the primary last; null with one or none. */
function pickedItems() {
    if (!fzSelRows) return null;
    const list = fzSelRows.map((i) => fzItems.find((x) => x.index === i)).filter(Boolean);
    return list.length > 1 ? list : null;
}

/** What several are, kind by kind: "3 NPCs, 1 car". */
function kindsText(kinds) {
    const counts = new Map();
    for (const k of kinds) counts.set(k, (counts.get(k) || 0) + 1);
    return [...counts].map(([k, n]) => {
        const word = KIND_TEXT[k] || k;
        return n + ' ' + (word === 'NPC' ? word : word.toLowerCase()) + (n === 1 ? '' : 's');
    }).join(', ');
}

/** A placed NPC that is a lore character, with a face: theirs (their picture link framed as /whip frames it, else the
 *  headshot of the look made for them), round as their tile in the NPCs; `cls` the box's ('fz-sel', 'fz-row'). Else ''. */
function loreFaceHtml(it, cls) {
    const app = director();
    const key = it && typeof it.lore === 'string' ? it.lore : '';
    const c = key && app ? (app.lore() || []).find((x) => x.key === key) : null;
    const url = c ? c.picture || c.portrait || '' : '';
    if (!url) return '';
    return '<span class="' + cls + '-face"><img class="' + cls + '-face-img" src="' + escapeHtml(url) + '" alt="" style="'
        + frameCss(c.picture ? c.pictureFrame || null : null) + '" onerror="this.parentNode.parentNode.classList.add(\'fz-noimg\')"></span>'
        + '<span class="' + cls + '-art ' + cls + '-fallback">' + glyph('star') + '</span>';
}

/** The selection's picture: the catalog's (or the car's; the NPC's head, a lore character's face), else its kind's glyph. */
function selPicHtml(it, model, kind) {
    const p = propOf(model);
    if (kind === 'vehicle') return pictureOr('fz-sel', vehicleImageUrl(model), 'car', fitAttrs('vehicle', model));
    if (kind === 'npc') return loreFaceHtml(it, 'fz-sel') || pictureOr('fz-sel', pedImageUrl(model), 'person', fitAttrs('npc', model, true));
    if ((kind === 'prop' || kind === 'container') && p && p.hasImage) {
        return '<img class="fz-sel-img" src="' + escapeHtml(p.image || propImageUrl(model)) + '" alt=""' + fitAttrs('prop', model) + '>';
    }
    const g = kind === 'prop' && p ? categoryGlyph(p.category) : (KIND_GLYPH[kind] || 'box');
    return '<span class="fz-sel-art">' + glyph(g) + '</span>';
}

/** The bubble, for the state: shown while something is selected, what it is and Remove. Measured
 *  again whenever what it says changes (its size is what placeSel works from). */
function renderSel(d) {
    const box = $('fz-sel');
    if (!box) return;
    const on = !!d.selected;
    if (!on) {
        if (box.classList.contains('show')) box.classList.remove('show', 'below', 'docked');
        selKey = null;
        endRemodel();
        hideGroup();
        return;
    }
    const it = selectedItem(d);
    const kind = (it && it.kind) || 'prop';
    // Several selected (Ctrl+click, a box): "5 selected", what they are, and only what works on all of them: Configure, Add
    // task (all NPCs), Add to group (all NPCs and props), Go to and Remove. The rest are one thing's.
    const set = pickedItems();
    const kinds = set ? set.map((x) => x.kind || 'prop') : null;
    // (Another thing selected while a new model was picked for one, or several: the picking is over.)
    if (remodel && (set || !(it && it.id === remodel.id))) endRemodel();
    if (!set) hideGroup();
    // The Director's Duplicate, on the kinds it takes (director/app.js builder.duplicate). Change model is on the thing's
    // Configure page, the last row of its General tab.
    const dir = !!(fzBuilder && fzBuilder.director);
    const acts = dir + '|' + kind + '|' + (kinds ? kinds.join(',') : '');
    if (acts !== selActs) {
        selActs = acts;
        const dup = $('fz-sel-dup');
        if (dup) dup.hidden = !(dir && !set && COPY_KINDS.has(kind));
        const task = $('fz-sel-task');
        if (task) task.hidden = !(dir && (kinds ? kinds.every((k) => k === 'npc') : kind === 'npc'));
        const group = $('fz-sel-group');
        if (group) group.hidden = !(dir && kinds && kinds.every((k) => k === 'npc' || k === 'prop'));
        selSize = null;
    }
    const model = d.selected.model;
    // The picture only when the thing changes: a state push every drag frame must not reload it.
    const picKey = d.selectedIndex + '|' + model + '|' + kind + '|' + ((it && it.lore) || '') + '|' + (set ? set.length : 1);
    if (picKey !== selPic) {
        selPic = picKey;
        const pic = $('fz-sel-art');
        if (pic) {
            pic.className = 'fz-sel-pic';
            pic.innerHTML = selPicHtml(it, model, kind) + (set ? '<span class="fz-sel-count">' + set.length + '</span>' : '');
        }
    }
    // Its name only: the picture says what it is.
    const key = set ? set.length + ' selected' : selectedName(d);
    const sub = set ? kindsText(kinds) : '';
    if (!box.classList.contains('show')) {
        box.classList.add('show', 'unplaced');
        selSide = null;
    }
    if (key + '|' + sub !== selKey) {
        selKey = key + '|' + sub;
        $('fz-sel-name').textContent = key;
        $('fz-sel-sub').textContent = sub;
        selSize = null;
    }
    // Other resources' buttons for this kind of thing (the Director's only, and its own Character editor for a freemode
    // NPC: so the thing itself goes too): drawn again when the list for it moves. (One thing's: none with several.)
    const app = director();
    const tools = app && !set ? app.buttons(kind, { id: it && it.id, model: d.selected && d.selected.model, lore: it && it.lore }) : [];
    const toolKey = kind + '|' + tools.map((b) => b.id + ':' + b.label).join(',');
    if (toolKey !== selTools) {
        selTools = toolKey;
        const el = $('fz-sel-tools');
        if (el) {
            el.innerHTML = tools.map((b) => '<button class="fz-btn fz-btn-sm" type="button" data-fz="tool" data-button="'
                + escapeHtml(b.id) + '" title="' + escapeHtml(b.hint || ('From ' + b.owner)) + '">'
                + toolIcon(b.icon) + escapeHtml(b.label) + '</button>').join('');
            el.classList.toggle('has', tools.length > 0);
        }
        selSize = null;
    }
    placeSel();
}

/** A button's icon by its key: whip's interaction icons (js/glyphs.js, as AddAction's), else the furnisher's own. */
function toolIcon(key) {
    if (!key) return '';
    const whip = window.WhipGlyphs && window.WhipGlyphs.glyphs;
    return (whip && whip[key]) || GLYPHS[key] || '';
}

// (Another resource added or took away a button: the bubble's are drawn again.)
window.addEventListener('director-buttons', () => { selTools = null; if (fzOpen && fzState) renderSel(fzState); });

/* WHERE THE BUBBLE GOES. Over the selected thing's markers, centred on it, its tail pointing down at
   it; under them when the bar is in the way; kept on the screen, clear of the bar, the catalog and
   the hint line. Tucked under the bar's right end, tail-less and with Go to, when the thing is off
   the screen (picked from the Placed list, or behind the camera). The markers' box comes from
   js/furnisher-gizmo.js (onAnchor) every time it draws them, so the bubble follows the thing as the
   camera moves and as it is dragged. It keeps to the side it is on while that side still fits, so it
   does not flap over the thing when the two sides are close. */
let selAnchor = null;   // the markers' box in real pixels { x, y, left, right, top, bottom }, or null
let selSide = null;     // 'above' | 'below' | 'docked', or null before it is first placed
let selSize = null;     // [w, h] in real pixels, measured; null after what it says changed
let selZoom = 1;        // real pixels per CSS pixel, measured with the size
let selFrame = null;    // where it may go { top, barRight, left, right, bottom, avoid }; null after the screen changed
let selKey = null;      // what it says, last drawn
let selPic = null;      // which thing its picture is of
let selTools = null;    // which other resources' buttons it has, last drawn
let selActs = null;     // which of Duplicate and Change model it shows, last drawn

/** The kinds Duplicate copies (director/app.js COPY_KINDS): not a door (the world's own), nor a point. */
const COPY_KINDS = new Set(['prop', 'npc', 'vehicle', 'spot', 'groundItem', 'container']);

window.addEventListener('resize', () => { selFrame = null; selSize = null; placeSel(); });

function measureSel(box) {
    const r = box.getBoundingClientRect();
    selSize = [r.width, r.height];
    selZoom = box.offsetWidth > 0 ? r.width / box.offsetWidth : 1;
}

function measureFrame() {
    const W = window.innerWidth, H = window.innerHeight;
    const m = 12 * selZoom;
    // (The Director's world builder has no bar: its top is Place and Blueprint, its Blueprint the end of them.)
    const dir = !!(fzBuilder && fzBuilder.director);
    const bar = dir ? $('fz-bp-btn') : document.querySelector('#furnisher .fz-bar');
    const cols = document.querySelector('#furnisher .fz-columns');
    const foot = document.querySelector('#furnisher .fz-footer');
    const b = bar ? bar.getBoundingClientRect() : null;
    const c = fzCatalogOpen && cols ? cols.getBoundingClientRect() : null;
    const f = foot ? foot.getBoundingClientRect() : null;
    // (The Director's page on the right, while it is open: the bubble keeps to its left.)
    const p = cfgOpen ? $('fz-cfg').getBoundingClientRect() : null;
    // What the bubble keeps above where it would be over it: the hint line, and the Director's Exit and Save.
    const avoid = [];
    if (f && f.width > 0) avoid.push({ left: f.left - m, right: f.right + m, top: f.top - m });
    if (dir) {
        const ex = $('fz-exit').getBoundingClientRect(), sv = $('fz-save').getBoundingClientRect();
        if (sv.width > 0) avoid.push({ left: Math.min(ex.left, sv.left) - m, right: Math.max(ex.right, sv.right) + m, top: Math.min(ex.top, sv.top) - m });
    }
    selFrame = {
        top: (b && b.height > 0 ? b.bottom : 0) + m,
        barRight: b && b.width > 0 ? b.right : W,
        left: (c && c.width > 0 ? c.right : 0) + m,
        right: (p && p.width > 0 ? p.left : W) - m,
        bottom: H - m,
        avoid,
    };
}

function placeSel() {
    const box = $('fz-sel');
    if (!box || !box.classList.contains('show')) return;
    const W = window.innerWidth, H = window.innerHeight;
    const a = selAnchor;
    // Tucked away or by the thing, first: Go to is there only tucked away, and it changes the size.
    const onScreen = !!(a && a.x >= 0 && a.x <= W && a.y >= 0 && a.y <= H);
    if (box.classList.contains('docked') === onScreen) {
        box.classList.toggle('docked', !onScreen);
        selSize = null;
    }
    if (!selSize) measureSel(box);
    if (!selFrame) measureFrame();
    const [w, h] = selSize;
    const F = selFrame;
    const gap = 6 * selZoom, tail = 10 * selZoom;

    let x, y, side;
    if (onScreen) {
        x = Math.max(F.left, Math.min(F.right - w, a.x - w / 2));
        // The hint line (and the Director's Exit and Save): the bottom is their top where the bubble would be over them.
        let bottom = F.bottom;
        for (const r of F.avoid) if (x < r.right && x + w > r.left) bottom = Math.min(bottom, r.top);
        const aboveY = a.top - gap - tail - h;
        const belowY = a.bottom + gap + tail;
        const fitsBelow = belowY + h <= bottom;
        // Above whenever there is room for it; once below, a few pixels more than just room, so it does not flicker at
        // the edge.
        const fitsAbove = aboveY >= F.top + (selSide === 'below' ? 8 * selZoom : 0);
        if (fitsAbove) side = 'above';
        else if (fitsBelow) side = 'below';
        else side = (a.top - F.top) >= (bottom - a.bottom) ? 'above' : 'below';
        y = side === 'above' ? aboveY : belowY;
        y = Math.max(F.top, Math.min(bottom - h, y));
        const tx = Math.max(18, Math.min(w / selZoom - 18, (a.x - x) / selZoom));
        box.style.setProperty('--fz-tail-x', tx.toFixed(1) + 'px');
    } else {
        side = 'docked';
        x = Math.max(F.left, Math.min(F.right - w, F.barRight - w));
        y = F.top;
    }
    selSide = side;
    box.style.left = x.toFixed(1) + 'px';
    box.style.top = y.toFixed(1) + 'px';
    box.classList.toggle('below', side === 'below');
    box.classList.remove('unplaced');
}

FurnishGizmo.onAnchor((a) => {
    selAnchor = a;
    placeSel();
});

// ========================================
// THE READOUT
//
// The half that stays bright in fly mode, because it is the half you read while placing.
// ========================================

function renderState(d) {
    const root = $('furnisher');
    if (!root) return;

    d = d || {};
    fzState = d;
    fzLooking = d.looking === true;
    root.classList.toggle('fz-looking', fzLooking);
    // A door pick waiting (the world builder's More > Door): the hint line says to click one.
    root.classList.toggle('fz-picking', d.picking === true);
    // On a pad: the selection riding the dot (the dot fills), and the legend for what is going on.
    root.classList.toggle('fz-carrying', d.carrying === true);
    padLegend();

    const house = $('fz-house');
    if (house) house.textContent = d.house || 'Furnish';

    const count = $('fz-count');
    if (count) {
        // No limit (the world builder): the count alone.
        const capped = typeof d.max === 'number';
        count.textContent = capped ? (d.count + ' / ' + d.max) : String(d.count || 0);
        // The cap is refused rather than truncated on the server, so the warning has to arrive
        // before the refusal does — a player who fills a house and only finds out at Save has lost
        // whatever they placed past the line.
        count.classList.toggle('warn', capped && d.count >= d.max);
    }

    // (The bar's Move / Rotate and its step chip say the markers and the step, the bubble the
    // selection; the count and Unsaved are in the bar too.)

    // THE UNSAVED MARKER. Exiting discards unsaved work — correctly, but it must not do it
    // silently, and a warning you can read before pressing Exit beats a dialog after.
    const dirty = $('fz-dirty');
    if (dirty) dirty.style.display = d.dirty ? '' : 'none';

    saveLabel();
    // An Exit armed by a press that is no longer dangerous is a button lying about itself.
    if (!d.dirty) disarmExit();

    // Repaint the list's marker only when the selection actually changed — touching a hundred and
    // fifty rows on every state push would be the one thing in this file with a cost worth noticing.
    const selIndex = (typeof d.selectedIndex === 'number') ? d.selectedIndex : null;
    const rows = Array.isArray(d.selectedIndexes) && d.selectedIndexes.length > 1 ? d.selectedIndexes.map(Number) : null;
    if (fzSelIndex !== selIndex || String(fzSelRows) !== String(rows)) {
        fzSelIndex = selIndex;
        fzSelRows = rows;
        markSelectedRow();
        // The Director's page on the right follows the selection (or goes, with nothing selected).
        cfgFollow();
        // Opened again on a car after its take was recorded: its Configure, as it was left.
        if (cfgAsk) {
            const it = selectedItem(d);
            if (it && it.id === cfgAsk) { cfgAsk = null; openConfigure(); }
        }
    }
    // A warning for a thing no longer selected is about nothing on screen: it goes.
    if (fzConfirm !== null && fzConfirm !== selIndex) hideConfirm();

    renderCard(d);

    FurnishGizmo.setMode(d.mode);
    FurnishGizmo.setLooking(fzLooking);
    FurnishGizmo.setSnap(d.move, d.turn, d.snap === true);
}

/** Save's words, and "•" while there is something to save. The world builder's: its own name for it (the Director's
 *  Save, which stays open; another's Done), and the scenario's own changes count too (its Configure, its Blueprint:
 *  the Director says when they change, 'director-doc'). */
function saveLabel() {
    const save = $('fz-save');
    if (!save) return;
    const app = fzBuilder && fzBuilder.director ? director() : null;
    const dirty = !!(fzState && fzState.dirty) || !!(app && app.docDirty && app.docDirty());
    const saveText = fzBuilder ? (fzBuilder.done || 'Done') : 'Save';
    save.textContent = dirty ? saveText + ' •' : saveText;
}
window.addEventListener('director-doc', () => { if (fzOpen) saveLabel(); });

/** How a save went: Saved / Could not save, or what the world builder's Director said (`text`). A notice, as any
 *  other: while this is open it shows at the top in the middle (js/inv-notice.js, #fz-notice-row). */
function flash(ok, text) {
    const words = typeof text === 'string' && text ? text : (ok ? 'Saved' : 'Could not save');
    if (typeof window.uiNotify === 'function') window.uiNotify({ text: words, type: ok ? 'success' : 'error', duration: 2500 });
}

// ========================================
// OPEN / CLOSE
// ========================================

function show(d) {
    const root = $('furnisher');
    if (!root) return;
    fzOpen = true;
    typingSaid = false;   // (the game starts not typing: client/property_furnish.lua furnishTyping)
    fzLooking = false;
    fzCategory = null;
    fzSearch = '';
    fzSelIndex = null;
    fzSelRows = null;
    // The world builder (its options), or a property's room (null): the tabs, Done and "By name". Its
    // lists: the NPCs (builder-peds.js), the vehicles this game has (sent with its options) and More.
    fzBuilder = d && d.builder && typeof d.builder === 'object' ? d.builder : null;
    if (fzBuilder) {
        const v = fzBuilder.vehicles && typeof fzBuilder.vehicles === 'object' ? fzBuilder.vehicles : null;
        // More's Weapons: a Fixed Weapon, each GTA firearm this game has (client/director.lua weapons), after the places.
        const wp = fzBuilder.weapons && typeof fzBuilder.weapons === 'object' && Array.isArray(fzBuilder.weapons.props)
            && fzBuilder.weapons.props.length ? fzBuilder.weapons : null;
        npcSrc = null;   // (the Director's NPCs, its lore characters with them, made again for this session: npcSource)
        // Dungeon Mode's (fzBuilder.live, client/director_live.lua): More is its Weapons alone, a place being a
        // scenario's.
        const places = fzBuilder.live ? { categories: [], props: [] } : MORE;
        fzBuilder.sources = {
            npcs: { clusters: PED_CLUSTERS, categories: PED_CATEGORIES, props: PEDS },
            vehicles: { clusters: (v && v.clusters) || [], categories: (v && v.categories) || [], props: (v && v.props) || [] },
            // (One group, flat: the weapons' categories beside Places, under the one row of chips.)
            more: wp ? { flat: true, clusters: MORE.clusters,
                         categories: places.categories.concat((wp.categories || []).map((c) => ({ ...c, cluster: 'places' }))),
                         props: places.props.concat(wp.props) } : MORE,
        };
    }
    root.classList.toggle('fz-builder', !!fzBuilder);
    // Dungeon Mode's: the bubble's Options (the Object Viewer's, for the selection).
    root.classList.toggle('fz-live', !!(fzBuilder && fzBuilder.live));
    // The Director's world builder: Configure and the Blueprint window (both closed as it opens; Configure opens
    // on the thing named `configure` once it is selected).
    root.classList.toggle('fz-director', !!(fzBuilder && fzBuilder.director));
    hideCfg();
    hideBp();
    hideMap();
    cfgAsk = fzBuilder && fzBuilder.director && typeof fzBuilder.configure === 'string' ? fzBuilder.configure : null;
    overSent = false;
    // The session's own buttons beside Exit (a hero shot's "Use this view"): data-fz="extra" calls back with its id.
    const extra = $('fz-extra');
    if (extra) {
        extra.textContent = '';
        for (const a of (fzBuilder && Array.isArray(fzBuilder.actions) ? fzBuilder.actions : [])) {
            if (!a || typeof a.id !== 'string') continue;
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'fz-btn';
            b.dataset.fz = 'extra';
            b.dataset.id = a.id;
            b.textContent = String(a.label || a.id);
            extra.appendChild(b);
        }
    }
    const catBtn = $('fz-catalog-btn');
    if (catBtn) catBtn.textContent = fzBuilder ? 'Place' : 'Furniture';
    // Back to the catalog's own groups (the builder may have left another list's group open).
    const cs = fzCatalog.clusters || [];
    if (!cs.some((c) => c.key === fzCluster)) fzCluster = cs.length ? cs[0].key : null;
    // THE CATALOG'S TAB IS RESET, whatever the last session ended on: opening the catalog is to put
    // something in the room, and the list of what is already there is where you go next, not first.
    // THE CATALOG ITSELF STARTS HIDDEN, behind the bar's Furniture switch.
    fzTab = 'catalog';
    fzSourceTab = 'catalog';
    // Nothing selected yet, and the bar may be wider (a session's own buttons): the bubble starts over.
    selAnchor = null;
    selFrame = null;
    renderSel({});
    setCatalogOpen(false);
    FurnishGizmo.reset();
    disarmExit();

    const search = $('fz-search');
    if (search) {
        search.value = '';
        search.placeholder = searchHint(fzTab);
    }

    const cols = document.querySelector('#furnisher .fz-columns');
    if (cols) cols.classList.remove('fz-list');

    root.classList.add('fz-open');
    root.classList.remove('fz-looking', 'fz-dragging', 'fz-padmenu', 'fz-carrying', 'fz-picking', 'fz-hand', 'fz-hand-new');
    renderSubtabs();
    renderRail();
    renderGrid();

    // A pad starts in the room; Lua is told afresh whether one drives (it forgot as it opened).
    fzPadMenu = false;
    padSent = null;
    ring.clear();
    padReport();
    padLegend();
    startAutosave();
}

function hide() {
    const root = $('furnisher');
    if (!root) return;
    hidePedName();
    fzOpen = false;
    fzLooking = false;
    fzState = {};
    fzItems = [];
    fzSelIndex = null;
    fzSelRows = null;
    stopAutosave();
    disarmExit();
    hideConfirm();
    hideGroup();
    FurnishGizmo.reset();
    // The field keeps DOM focus across a close otherwise, and Lua would still be standing its key
    // reader down for a screen that has gone. Blurring here fires focusout, which says so.
    const search = $('fz-search');
    if (search) search.blur();
    setCatalogOpen(false);
    renderSel({});
    selAnchor = null;
    // The Director's page and grid go back to it (the grid to its own screen), and its map goes.
    hideCfg();
    hideBp();
    hideMap();
    cfgAsk = null;
    fzBuilder = null;
    fzPadMenu = false;
    padSent = null;
    ring.clear();
    root.classList.remove('fz-open', 'fz-looking', 'fz-dragging', 'fz-builder', 'fz-live', 'fz-padmenu', 'fz-carrying', 'fz-picking',
        'fz-hand', 'fz-hand-new');
    const grid = $('fz-grid');
    if (grid) grid.innerHTML = '';
}

/* THE WORLD BUILDER'S WARNING: which thing it is for, while it is up. A thing a
   card uses goes only after Remove here; Keep, or the selection moving on, puts it away. */
let fzConfirm = null;

function showConfirm(d) {
    const box = $('fz-confirm');
    const text = $('fz-confirm-text');
    if (!box || !text || !d || typeof d.index !== 'number') return;
    const uses = (Array.isArray(d.uses) ? d.uses : []).map(String);
    const who = uses.length <= 1 ? (uses[0] || 'A card')
        : uses.slice(0, -1).join(', ') + ' and ' + uses[uses.length - 1];
    // (Several selected: always asked, the cards that use any of them named.)
    if (typeof d.many === 'number') {
        text.textContent = 'Remove all ' + d.many + '?' + (uses.length ? ' ' + who + (uses.length > 1 ? ' use' : ' uses') + ' some of them.' : '');
    } else {
        text.textContent = who + (uses.length > 1 ? ' use' : ' uses') + ' it. Remove it anyway?';
    }
    hideGroup();
    fzConfirm = d.index;
    box.classList.add('show');
    // (In the bubble: it is taller now.)
    selSize = null;
    placeSel();
}

function hideConfirm() {
    const was = fzConfirm !== null;
    fzConfirm = null;
    const box = $('fz-confirm');
    if (box) box.classList.remove('show');
    if (was) { selSize = null; placeSel(); }
}

/* ADD TO GROUP (several NPCs and props selected): a group's name typed, or one of the scenario's picked from its chips,
   then Add puts all of them in it (director/app.js builder.setGroup, one undo step). */
let groupOpen = false;

function showGroup() {
    const app = director();
    const box = $('fz-group');
    if (!app || !box || !pickedItems()) return;
    hideConfirm();
    groupOpen = true;
    $('fz-group-chips').innerHTML = app.groups().map((g) => '<button class="fz-group-chip" type="button" data-fz="group-pick" data-group="'
        + escapeHtml(g) + '">' + escapeHtml(g) + '</button>').join('');
    const input = $('fz-group-input');
    input.value = '';
    box.classList.add('show');
    if (!isPad()) input.focus();
    selSize = null;
    placeSel();
}

function hideGroup() {
    if (!groupOpen) return;
    groupOpen = false;
    const box = $('fz-group');
    if (box) box.classList.remove('show');
    const input = $('fz-group-input');
    if (input) input.blur();
    selSize = null;
    placeSel();
}

function addToGroup(name) {
    const app = director();
    const ids = selectionIds(app);
    if (!ids) { hideGroup(); return; }
    const why = app.setGroup(ids, typeof name === 'string' ? name : $('fz-group-input').value);
    if (why) {
        if (typeof window.uiNotify === 'function') window.uiNotify({ text: why, type: 'error', duration: 3000 });
        return;
    }
    hideGroup();
}

// The Director's several-selected page narrowing the selection (a kind's chip, one of them alone): those rows, in Lua.
window.addEventListener('director-builder-select', (e) => {
    const ids = e.detail && Array.isArray(e.detail.ids) ? e.detail.ids : [];
    const rows = ids.map((id) => fzItems.find((x) => x.id === id)).filter(Boolean).map((x) => x.index);
    if (fzOpen && rows.length) nuiCallback('furnishSelectRows', { rows });
});

/** The world builder's "by name": the search's text as the model, for this one thing (Lua checks it
 *  with the game). The search is emptied and let go: the thing is in the room, ready to arrange. */
function placeByName() {
    const model = byNameModel();
    if (!model || !fzBuilder) return;
    nuiCallback('furnishPick', { model, byName: true, kind: TAB_KIND[fzTab] || 'prop', replace: heldFresh() });
    const search = $('fz-search');
    if (search) {
        search.value = '';
        search.blur();
    }
    fzSearch = '';
    renderGrid();
}

/** One still in hand and never put down (a fresh pick riding the mouse): the next pick takes its place. */
function heldFresh() {
    const h = FurnishGizmo.carrying();
    return h && h.fresh ? h.index : undefined;
}

/** A tile pressed: picked, and in hand at once (client/property_furnish.lua placeNew's carry). A lore character with
 *  no ped yet says so instead. The Input ped name tile opens its window (showPedName). */
function pickTile(el) {
    // A random vehicle's page adding a model: this one joins its list (and the page is back).
    const picking = modelPicking();
    if (picking && el.dataset.kind === 'vehicle' && el.dataset.model && !el.dataset.random) {
        director().addModel(el.dataset.model);
        renderGrid();
        return;
    }
    if (el.dataset.random) {
        nuiCallback('furnishPick', { kind: 'vehicle', random: true, replace: heldFresh() });
        return;
    }
    if (el.dataset.lore && !el.dataset.model) {
        if (typeof window.uiNotify === 'function') {
            window.uiNotify({ text: `${el.dataset.name || 'That character'} has no ped yet: give them one in /whip (Director, Lore characters)`,
                              type: 'error', duration: 3500 });
        }
        return;
    }
    // Change model: the selection's new model, not a new thing.
    if (remodel) {
        if (el.dataset.kind === remodel.kind && el.dataset.model) remodelTo(el);
        return;
    }
    nuiCallback('furnishPick', { model: el.dataset.model, kind: el.dataset.kind || 'prop', name: el.dataset.name,
                                 lore: el.dataset.lore || undefined, weapon: el.dataset.weapon || undefined, replace: heldFresh() });
}

/** Esc while a pick rides the mouse: a fresh one goes, as if it was never picked (a Place marker's stays put). */
function dropHeld() {
    const c = FurnishGizmo.carrying() ? FurnishGizmo.cancelCarry() : null;
    if (c && c.fresh) nuiCallback('furnishCarryCancel', { i: c.index });
}

// While something rides the mouse the hint line says how to put it down (and, for a fresh pick, Esc).
FurnishGizmo.onCarry((c) => {
    const r = $('furnisher');
    if (!r) return;
    r.classList.toggle('fz-hand', !!c);
    r.classList.toggle('fz-hand-new', !!(c && c.fresh));
});

// ========================================
// THE DIRECTOR, IN THE BUILDER (its world builder only: fzBuilder.director)
//
// Two of the Director's own surfaces, drawn by it (director/app.js `builder`, reached through
// director-loader.js):
//   CONFIGURE   the bubble's button: the selected thing's page — who or what it is, how it behaves — in
//               the panel on the right (#fz-cfg), written into the scenario as it is changed, so nothing
//               sends you back to the Director to set it up. One the scenario has not got yet (placed here
//               just now) is made in it first, as Done would. The panel follows the selection while it
//               is on a thing's page.
//   BLUEPRINT   the bar's switch: the scenario's grid of cards in a window over the room (#fz-bp), dragged
//               by its head and sized by its edges. It works as it does in the Director; a card picked on
//               it opens its settings in the same panel, and what a card names lights green in the world.
//   MAP         the switch beside it: the scenario's things on whip's map in a window of the same kind (#fz-map,
//               director/map.js), where they are now, the camera the arrow; a mark's card has Go to and Configure.
// Lua is told when the pointer is over one of these (furnishOverUi): a right-drag there pans the grid, it
// does not turn the room.
// ========================================

let cfgOpen = false;     // the panel shows a page
let typingSaid = false;  // what the game was last told about the keyboard (furnishTyping), said only when it changes
let cfgPage = '';        // what it shows: 'Configure' (a thing's page) | 'Card'
let cfgAsk = null;       // the thing whose Configure opens once it is selected (the builder opened again after a take)
let bpOpen = false;      // the Blueprint window is up

const director = () => (fzBuilder && fzBuilder.director ? directorBuilder() : null);

/** Configure: the selection's page in the panel. A thing placed here that the scenario has not got yet is
 *  made in it first, and the builder learns its id (client/director.lua). */
function openConfigure() {
    const app = director();
    const ids = pickedItems() ? selectionIds(app) : null;
    if (ids) { if (app.configureMany(ids)) showCfg(); return; }
    const id = selectionId(app);
    if (id && app.configure(id)) showCfg();
}

/** The selection's id in the scenario, made in it first when it has not got it yet (and the builder told), or null. */
function selectionId(app) {
    const d = fzState || {};
    const it = selectedItem(d);
    if (!app || !app.on() || !it || !d.selected) return null;
    let id = it.id;
    if (!app.has(id)) {
        id = app.adopt({ kind: it.kind || 'prop', model: d.selected.model, label: it.label, lore: it.lore, random: it.random,
                         coords: { x: d.selected.x, y: d.selected.y, z: d.selected.z, heading: d.selected.rz } });
        if (!id) return null;
        it.id = id;
        nuiCallback('directorBuilderId', { index: it.index, id });
    }
    return id;
}

/** Several selected: each one's id in the scenario, the primary last (one it has not got yet is left out: everything
 *  placed in the builder is the scenario's from the moment it is put down), or null. */
function selectionIds(app) {
    const set = pickedItems();
    if (!app || !app.on() || !set) return null;
    const ids = set.map((x) => x.id).filter((id) => id && app.has(id));
    return ids.length ? ids : null;
}

/** Add task: an NPC's Configure on its Tasks tab, the list of tasks to pick from up (director/app.js builder.addTask).
 *  Several NPCs: theirs, a task picked goes to each (builder.addTaskMany). */
function openAddTask() {
    const app = director();
    const ids = pickedItems() ? selectionIds(app) : null;
    const id = ids ? null : selectionId(app);
    if (!ids && !id) return;
    const why = ids ? app.addTaskMany(ids) : app.addTask(id);
    if (why) {
        if (typeof window.uiNotify === 'function') window.uiNotify({ text: why, type: 'error', duration: 3500 });
        return;
    }
    showCfg();
}

/** Duplicate: a full copy of the selection in hand on the pointer, to put down (director/app.js builder.duplicate). */
function openDuplicate() {
    const app = director();
    const id = selectionId(app);
    if (!id) return;
    const why = app.duplicate(id);
    if (why && typeof window.uiNotify === 'function') window.uiNotify({ text: why, type: 'error', duration: 3500 });
}

/** Another resource's button in the bubble: pressed on the selection, made in the scenario first when it has not got
 *  it yet (as Configure does). */
function openTool(buttonId) {
    const app = director();
    if (!buttonId) return;
    const id = selectionId(app);
    if (!id) return;
    // A random vehicle of several models: its page, where each model has the button.
    if (app.press(id, buttonId) === 'page' && app.configure(id)) {
        showCfg();
        if (typeof window.uiNotify === 'function') {
            window.uiNotify({ text: 'A vehicle pool: press it on the model to change, under Models', type: 'info', duration: 3500 });
        }
    }
}

// ---- Input ped name: a ped by its exact name (the NPCs' first tile) ----
//
// A small window over the room: the name typed, Spawn (or Enter) asks the game (client/furnish_builder.lua
// furnishPedName), which puts it in hand as any pick is. Not one the game has, or one that would not load or be made:
// the window stays, saying which.

let pedNameOpen = false;
let pedNameBusy = false;

function showPedName() {
    const held = FurnishGizmo.carrying();
    if (held && held.fresh) dropHeld();
    pedNameOpen = true;
    $('fz-pedname').classList.add('show');
    $('furnisher').classList.add('fz-pednaming');   // (the selection's bubble steps out of its way: furnisher.css)
    $('fz-pedname-why').textContent = '';
    const input = $('fz-pedname-input');
    input.value = '';
    if (!isPad()) input.focus();
}

function hidePedName() {
    if (!pedNameOpen) return;
    pedNameOpen = false;
    $('fz-pedname').classList.remove('show', 'busy');
    $('furnisher').classList.remove('fz-pednaming');
    $('fz-pedname-input').blur();
}

async function submitPedName() {
    if (pedNameBusy) return;
    const input = $('fz-pedname-input');
    const why = $('fz-pedname-why');
    const name = input.value.trim();
    if (!/^\w{1,64}$/.test(name)) {
        why.textContent = name ? 'That NPC doesn\'t exist!' : 'Type the ped\'s name first';
        return;
    }
    pedNameBusy = true;
    $('fz-pedname').classList.add('busy');
    why.textContent = '';
    const r = await nuiCallback('furnishPedName', { name });
    pedNameBusy = false;
    $('fz-pedname').classList.remove('busy');
    if (r && r.ok === true) {
        hidePedName();   // (in hand now, riding the mouse)
        return;
    }
    why.textContent = r && r.why === 'missing' ? 'That NPC doesn\'t exist!' : 'That NPC failed to spawn';
    if (!isPad()) { input.focus(); input.select(); }
}

/** The panel up, the Director drawing into it. */
function showCfg() {
    const app = director();
    if (!app) return;
    cfgOpen = true;
    $('fz-cfg').classList.add('show');
    $('furnisher').classList.add('fz-cfg-open');   // (the bar keeps to the middle between the panels: furnisher.css)
    app.page($('fz-cfg'), $('fz-cfg-body'), {
        title: (t) => {
            cfgPage = t;
            $('fz-cfg-title').textContent = t;
        },
        gone: () => hideCfg(true),
        // A vehicle pool's page adding a model (`on`), or done: the Vehicles open to pick it from, the list drawn
        // again (no Vehicle pool tile while picking).
        vehicles: (on) => {
            if (on) {
                setCatalogOpen(true);
                setTab('vehicles');
            }
            renderGrid();
        },
    });
    selFrame = null;
    placeSel();
}

/** The panel down (`gone`: the Director has let it go already). */
function hideCfg(gone) {
    if (!cfgOpen) return;
    cfgOpen = false;
    cfgPage = '';
    if (!gone) { const app = directorBuilder(); if (app) app.unpage(); }
    const p = $('fz-cfg');
    if (p) p.classList.remove('show');
    $('furnisher').classList.remove('fz-cfg-open');
    selFrame = null;
    placeSel();
}

/** The selection moved while the panel is on a thing's page: the new one's page, or the panel goes. */
function cfgFollow() {
    if (!cfgOpen) return;
    const app = director();
    // (Several's page follows it on any of its views: the list of tasks to add for all of them, Copy tasks.)
    if (!(cfgPage === 'Configure' || (app && app.multi()))) return;
    const ids = pickedItems() ? selectionIds(app) : null;
    if (app && ids && ids.length > 1) { app.configureMany(ids); return; }
    const it = selectedItem(fzState || {});
    const id = ids ? ids[0] : it && it.id;
    if (app && id && app.has(id)) app.configure(id);
    else hideCfg();
}

// ---- the windows over the room: the Blueprint and the Map ----

const WIN_MIN_W = 320, WIN_MIN_H = 220;

/** Real pixels per CSS pixel of the scaled shell (--fz-zoom), read off the bar. */
function selZoomOf() {
    const bar = document.querySelector('#furnisher .fz-bar');
    return bar && bar.offsetHeight > 0 ? bar.getBoundingClientRect().height / bar.offsetHeight : 1;
}

/** Kept on the screen, at least its smallest size. */
function winFit(b) {
    const W = window.innerWidth, H = window.innerHeight;
    const w = Math.max(WIN_MIN_W, Math.min(W, b.w)), h = Math.max(WIN_MIN_H, Math.min(H, b.h));
    return { x: Math.max(0, Math.min(W - w, b.x)), y: Math.max(0, Math.min(H - h, b.y)), w, h };
}

/** One of the Director's windows over the room (#fz-bp, #fz-map): its head drags it, its edges and bottom corners size
 *  it, and where it was left is kept under `key` (fractions of the screen, so a new resolution keeps its place); the
 *  first time it opens where `place()` says. `sized()`: its size changed. In real pixels: { x, y, w, h }. */
function floatWindow(id, key, place, sized) {
    const win = { el: $(id), box: null, up: false };
    win.apply = () => {
        if (!win.el || !win.box) return;
        win.el.style.left = win.box.x + 'px';
        win.el.style.top = win.box.y + 'px';
        win.el.style.width = win.box.w + 'px';
        win.el.style.height = win.box.h + 'px';
    };
    win.open = () => {
        const W = window.innerWidth, H = window.innerHeight;
        let b = null;
        try {
            const s = JSON.parse(localStorage.getItem(key) || 'null');
            if (s && s.w > 0 && s.h > 0) b = { x: s.x * W, y: s.y * H, w: s.w * W, h: s.h * H };
        } catch (_) { /* no storage: where it starts */ }
        win.box = winFit(b || place());
        win.apply();
        win.up = true;
    };
    win.save = () => {
        if (!win.box) return;
        const W = window.innerWidth, H = window.innerHeight;
        try {
            localStorage.setItem(key, JSON.stringify({ x: win.box.x / W, y: win.box.y / H, w: win.box.w / W, h: win.box.h / H }));
        } catch (_) { /* no storage: it opens where it starts */ }
    };
    // The pointer held on its head or an edge: the box follows.
    if (win.el) win.el.addEventListener('pointerdown', (e) => {
        const g = e.target.closest('[data-grip]');
        if (!g || e.button !== 0 || !win.box || e.target.closest('[data-fz]')) return;
        e.preventDefault();
        const kind = g.dataset.grip, x0 = e.clientX, y0 = e.clientY, b0 = { ...win.box };
        win.el.classList.toggle('moving', kind === 'move');
        try { g.setPointerCapture(e.pointerId); } catch (_) { /* gone already */ }
        const move = (m) => {
            const dx = m.clientX - x0, dy = m.clientY - y0;
            const b = { ...b0 };
            if (kind === 'move') { b.x += dx; b.y += dy; }
            if (kind === 'r' || kind === 'rb') b.w = b0.w + dx;
            if (kind === 'b' || kind === 'rb' || kind === 'lb') b.h = b0.h + dy;
            if (kind === 'l' || kind === 'lb') {
                b.w = Math.max(WIN_MIN_W, b0.w - dx);
                b.x = b0.x + b0.w - b.w;
            }
            win.box = winFit(b);
            win.apply();
            if (kind !== 'move' && sized) sized();
        };
        const up = () => {
            g.removeEventListener('pointermove', move);
            g.removeEventListener('pointerup', up);
            g.removeEventListener('pointercancel', up);
            win.el.classList.remove('moving');
            win.save();
        };
        g.addEventListener('pointermove', move);
        g.addEventListener('pointerup', up);
        g.addEventListener('pointercancel', up);
    });
    window.addEventListener('resize', () => {
        if (!win.up || !win.box) return;
        win.box = winFit(win.box);
        win.apply();
        if (sized) sized();
    });
    return win;
}

// The Blueprint: low on the right, clear of the Director's page's place and above the hint line's height.
const bpWin = floatWindow('fz-bp', 'whip_fz_blueprint', () => {
    const W = window.innerWidth, H = window.innerHeight, z = selZoomOf();
    const right = W - (34 + 394 + 16) * z;    // (--fz-edge, --fz-cat-w and a gap: the page on the right)
    const w = Math.round(Math.min(W * 0.36, right - W * 0.3)), h = Math.round(H * 0.4);
    return { x: right - w, y: H - h - Math.round(90 * z), w, h };
}, () => { const app = directorBuilder(); if (app) app.resized(); });

function showBp() {
    const app = director();
    if (!app || !app.on() || bpOpen) return;
    bpOpen = true;
    bpWin.open();
    $('fz-bp').classList.add('show');
    $('fz-bp-btn').classList.add('on');
    // A card picked on it: its settings in the panel. It opens on the selected thing's cards.
    const it = selectedItem(fzState || {});
    app.canvas($('fz-bp-body'), { picked: () => { if (!cfgOpen) showCfg(); } }, it && it.id);
}
// The Director asks for the window (a Wait step picking its card on the grid: director/app.js task-card-pick).
window.addEventListener('director-open-blueprint', () => { if (fzOpen) showBp(); });

// ---- auto-save (the Director's world builder: its World tab's switch, on unless turned off) ----
//
// Every five minutes, while there is something to save (the world's changes or the scenario's own), it presses
// Save for you: the same Save, said as "Auto-saved". Never in the middle of a drag or a look round: a little later.

const AUTOSAVE_MS = 5 * 60 * 1000;
const AUTOSAVE_RETRY_MS = 10 * 1000;
let autoTimer = null;

function startAutosave() {
    stopAutosave();
    if (!(fzBuilder && fzBuilder.director && fzBuilder.autosave === true)) return;
    autoTimer = setInterval(autoSaveTick, AUTOSAVE_MS);
}

function stopAutosave() {
    if (autoTimer) clearInterval(autoTimer);
    autoTimer = null;
}

function autoSaveTick() {
    if (!fzOpen) { stopAutosave(); return; }
    const app = director();
    if (!(fzState.dirty || (app && app.docDirty && app.docDirty()))) return;
    const root = $('furnisher');
    if (root && (root.classList.contains('fz-dragging') || root.classList.contains('fz-looking'))) {
        setTimeout(() => { if (autoTimer) autoSaveTick(); }, AUTOSAVE_RETRY_MS);
        return;
    }
    nuiCallback('furnishSave', { auto: true });
}

/** Cards: the card list down the window's left side, the grid beside it (the Director's own column's list, drawn
 *  by it: director/app.js builder.cards). One clicked goes in the middle of the grid, one dragged where it is
 *  dropped. Pressed again, it goes and the grid has the window back. */
let bpPal = false;
function showPal() {
    const app = director();
    if (!app || !bpOpen || bpPal || !app.cards($('fz-bp-pal'), $('fz-bp-pal-body'))) return;
    bpPal = true;
    $('fz-bp').classList.add('pal');
    $('fz-bp-cards').classList.add('on');
    app.resized();
}
function hidePal() {
    if (!bpPal) return;
    bpPal = false;
    const app = directorBuilder();
    if (app) app.uncards();
    $('fz-bp').classList.remove('pal');
    $('fz-bp-cards').classList.remove('on');
    if (app) app.resized();
}

function hideBp() {
    if (!bpOpen) return;
    hidePal();
    bpOpen = false;
    bpWin.up = false;
    const app = directorBuilder();
    if (app) app.uncanvas();
    $('fz-bp').classList.remove('show');
    $('fz-bp-btn').classList.remove('on');
}

// ---- the Map window: the scenario's things on whip's map, where the builder has them now (director/map.js) ----

let mapOpen = false;
// Low on the left, under Place / Blueprint / Map and clear of the Blueprint's place on the right.
const mapWin = floatWindow('fz-map', 'whip_fz_map', () => {
    const W = window.innerWidth, H = window.innerHeight, z = selZoomOf();
    const w = Math.round(Math.min(W * 0.3, 560 * z)), h = Math.round(Math.min(H * 0.42, 420 * z));
    return { x: Math.round(34 * z), y: H - h - Math.round(90 * z), w, h };
}, () => { const app = directorBuilder(); if (app) app.mapResized(); });

function showMap() {
    const app = director();
    if (!app || !app.on() || mapOpen) return;
    mapOpen = true;
    mapWin.open();
    $('fz-map').classList.add('show');
    $('fz-map-btn').classList.add('on');
    // A mark's Configure: its page in the panel on the right, as the bubble's Configure opens it.
    app.map($('fz-map-body'), { configure: (id) => { const a = director(); if (a && a.configure(id) && !cfgOpen) showCfg(); } });
}

function hideMap() {
    if (!mapOpen) return;
    mapOpen = false;
    mapWin.up = false;
    const app = directorBuilder();
    if (app) app.unmap();
    $('fz-map').classList.remove('show');
    $('fz-map-btn').classList.remove('on');
}

// ---- the pointer over a panel, and the keyboard in a field: Lua is told ----

/** Is this a panel of the editor's (or a popover of the Director's, its card search and menus)? A right-drag
 *  there is the panel's (the grid pans), not the room's. */
const OVER_UI = '#furnisher .fz-bar, #furnisher.fz-catalog-open .fz-columns, #fz-sel.show, #fz-cfg.show, #fz-bp.show, #fz-map.show,'
    + ' #fz-pedname.show, .dr-float';
let overSent = false;
document.addEventListener('pointermove', (e) => {
    if (!fzOpen || fzLooking) return;
    const over = !!(e.target && e.target.closest && e.target.closest(OVER_UI));
    if (over === overSent) return;
    overSent = over;
    nuiCallback('furnishOverUi', { on: over });
}, true);

// ========================================
// EXIT — armed, like the creator's Cancel
//
// Exiting throws away everything placed since the last save. Lua says so in a toast afterwards and
// the readout carries an UNSAVED marker before, and neither is a substitute for the button itself
// declining to be a one-click mistake. Armed only WHILE there is something to lose: a two-step
// confirmation on a harmless action is a two-step confirmation people learn to click through.
// ========================================

function attemptExit() {
    if (!fzState.dirty) { nuiCallback('furnishExit', {}); return; }
    if (fzExitArmed) { disarmExit(); nuiCallback('furnishExit', {}); return; }

    setExitLabel(true);
    fzExitArmed = setTimeout(disarmExit, 3000);
}

function disarmExit() {
    if (fzExitArmed) clearTimeout(fzExitArmed);
    fzExitArmed = null;
    setExitLabel(false);
}

/** Exit's words (its key stays beside them), armed or not. */
function setExitLabel(armed) {
    const btn = $('fz-exit');
    if (!btn) return;
    btn.classList.toggle('armed', armed);
    const label = btn.querySelector('.fz-btn-label');
    if (label) label.textContent = armed ? 'Discard?' : 'Exit';
}

// ========================================
// DELEGATED ACTIONS
//
// The documented reference shape (docs/nui-architecture.md): listeners on the #furnisher root,
// parameters as data-*, dispatch through a Map so a lookup cannot be shadowed by Object.prototype
// names. Top-level DOM reads are safe — the module script sits at the end of <body>.
// ========================================

(function bindFurnisherActions() {
    const root = $('furnisher');
    if (!root) return;

    const CLICK = new Map([
        ['cluster', (el) => {
            const key = el.dataset.cluster;
            if (key === fzCluster) return;
            fzCluster = key;
            fzCategory = null;
            renderRail();
            renderGrid();
        }],
        ['category', (el) => {
            fzCategory = el.dataset.cat === '' ? null : el.dataset.cat;
            renderRail();
            renderGrid();
        }],
        ['tab',       (el) => setTab(el.dataset.tab)],
        // Picking a prop puts it in the room at once, in the middle of the view, selected with the
        // markers on it — see furnishPick. Clicking a prop IS the instruction to place it.
        ['tile',      (el) => pickTile(el)],
        ['byname',    () => placeByName()],
        // Clicking a row selects that object, exactly as clicking it in the room would. Lua answers
        // with a state push that moves the highlight — nothing is marked optimistically here,
        // because the click can be refused (a row clicked between a delete and the resend).
        // (Ctrl held: into the selection beside what is selected, or out of it.)
        ['row',       (el, e) => nuiCallback('furnishSelectIndex', { index: Number(el.dataset.index), ctrl: !!(e && e.ctrlKey) })],
        ['goto',      () => nuiCallback('furnishGoTo', {})],
        ['catalog',   () => setCatalogOpen(!fzCatalogOpen)],
        ['mode',      (el) => nuiCallback('furnishSetMode', { mode: el.dataset.mode })],
        // The step chip goes round the config's steps, the same as G: both lists move together.
        // The snap chip goes round as G does: the next step, and past the last, off.
        ['step',      () => nuiCallback('furnishSetStep', { cycle: true })],
        ['grid',      () => nuiCallback('furnishToggleGrid', {})],
        ['delete',    () => nuiCallback('furnishDelete', {})],
        // The world builder's warning: Remove (for the one it was about), or Keep.
        ['confirm-remove', () => {
            const index = fzConfirm;
            hideConfirm();
            if (typeof index === 'number') nuiCallback('furnishDelete', { force: true, index });
        }],
        ['confirm-keep', () => hideConfirm()],
        ['save',      () => nuiCallback('furnishSave', {})],
        ['exit',      () => attemptExit()],
        ['extra',     (el) => nuiCallback('furnishAction', { id: el.dataset.id })],
        // The Director's world builder: the selection's page on the right, and the Blueprint window.
        ['configure', () => openConfigure()],
        // An NPC's Tasks, the list to pick one from up.
        ['addtask',   () => openAddTask()],
        // Several NPCs and props: all of them into one group.
        ['group',        () => { if (groupOpen) hideGroup(); else showGroup(); }],
        ['group-pick',   (el) => addToGroup(el.dataset.group)],
        ['group-add',    () => addToGroup()],
        ['group-cancel', () => hideGroup()],
        // A full copy of the selection, in hand to put down; a new model for it, picked from Place.
        ['duplicate', () => openDuplicate()],
        ['remodel',   () => startRemodel()],
        ['remodel-cancel', () => endRemodel()],
        // Another resource's button for this kind of thing (client/director_buttons.lua).
        ['tool',      (el) => openTool(el.dataset.button)],
        // Dungeon Mode's: the selection's Object Viewer options (client/director_live.lua).
        ['options',   () => { if (fzSelIndex !== null) nuiCallback('furnishLiveOptions', { i: fzSelIndex }); }],
        ['cfg-close', () => hideCfg()],
        // Input ped name (the NPCs' first tile): its window, Spawn, and Cancel or its X.
        ['pedname',       () => showPedName()],
        ['pedname-go',    () => submitPedName()],
        ['pedname-close', () => hidePedName()],
        ['blueprint', () => { if (bpOpen) hideBp(); else showBp(); }],
        ['bp-close',  () => hideBp()],
        // The card list, in the Blueprint window itself: pressed again, it goes.
        ['bp-cards',  () => { if (bpPal) hidePal(); else showPal(); }],
        // The full editor: the builder hands the world back and closes, the Director's page takes the screen.
        ['bp-full',   () => { const app = director(); if (app) app.fullscreen(); }],
        // The Map window: the scenario's things on the map.
        ['map',       () => { if (mapOpen) hideMap(); else showMap(); }],
        ['map-close', () => hideMap()],
        // Test: the set here written into the scenario (as Fullscreen does), then the editor's Test.
        ['test',      () => { const app = director(); if (app) app.test(); }],
    ]);

    // Each picture that says what it is (fitAttrs), fitted to its box as it loads: the thing as big as it goes.
    root.addEventListener('load', (e) => {
        if (e.target && e.target.tagName === 'IMG' && e.target.dataset.fit) fitPicture(e.target);
    }, true);

    root.addEventListener('click', (e) => {
        if (!fzOpen) return;
        const el = e.target.closest('[data-fz]');
        if (!el) return;
        // BLURRED THE MOMENT IT IS USED. A button that keeps DOM focus after a click is a button
        // that fires again on the next Space or Enter — and the game is reading the keyboard
        // underneath this page, so those presses are already doing something else. Clicking Save
        // and then jumping the camera must not save twice.
        if (el.tagName === 'BUTTON') el.blur();
        const fn = CLICK.get(el.dataset.fz);
        if (fn) fn(el, e);
    });

    root.addEventListener('input', (e) => {
        if (!fzOpen) return;
        const el = e.target;
        if (el.id === 'fz-search') {
            fzSearch = el.value || '';
            renderGrid();
        }
    });

    // Enter in the search places the model it names, while the by-name offer is up (its button); in Input ped name's
    // box, it spawns that ped.
    root.addEventListener('keydown', (e) => {
        if (!fzOpen || !e.target || e.key !== 'Enter') return;
        if (e.target.id === 'fz-search') placeByName();
        else if (e.target.id === 'fz-pedname-input') submitPedName();
        else if (e.target.id === 'fz-group-input') addToGroup();
    });

    // Right-drag is how the room is turned. Without this, every look would also raise CEF's context
    // menu over the top of it — the same guard the creator puts on its orbit surface.
    root.addEventListener('contextmenu', (e) => e.preventDefault());

    // TELL LUA WHEN A FIELD HAS THE KEYBOARD. focusin/focusout rather than focus/blur because those
    // two do not bubble, and on the document so every field is covered without anything being wired
    // to it: the catalog's search, the Director's page on the right, its card search over the
    // Blueprint window (a popover on the body). See the furnishTyping callback for what it prevents.
    const typingField = (t) => !!t && (t.tagName === 'TEXTAREA' || t.tagName === 'SELECT'
        || (t.tagName === 'INPUT' && !/^(checkbox|radio|button|submit|range|color|file)$/.test(t.type)));
    // SAID ONCE THE FOCUS HAS SETTLED, AND ONLY WHEN IT CHANGES. A field redrawn as it is typed in (the Blueprint
    // window's card search rebuilds its box on every key and focuses the new one) goes out and in again in one moment:
    // said as it happened, "not typing" reached the game in between, and Backspace there left the whole builder.
    let typingCheck = 0;
    const sayTyping = () => {
        typingCheck = 0;
        const on = fzOpen && typingField(document.activeElement);
        if (on === typingSaid) return;
        typingSaid = on;
        nuiCallback('furnishTyping', { on });
    };
    document.addEventListener('focusin', (e) => { if (fzOpen && typingField(e.target)) sayTyping(); });
    document.addEventListener('focusout', () => { if (fzOpen && !typingCheck) typingCheck = setTimeout(sayTyping, 0); });

    const grid = $('fz-grid');
    if (grid) grid.addEventListener('scroll', onGridScroll);
})();

// ========================================
// ON A CONTROLLER
//
// Two halves. IN THE ROOM the pad is the camera's and the selection's: the sticks fly and look (read in
// Lua, FreeCam.setPad), and the presses go to client/property_furnish.lua (furnishPadPress) — A selects
// what the dot in the middle is on, X picks it up to ride the dot, A puts it down, B puts it back, the
// D-pad nudges or turns it, RB is Move / Rotate, the triggers raise and lower it. Y opens THE MENU: the
// catalog, the bar and the bubble under a white ring the D-pad moves (pad-ring.js), A presses what it
// is on, LB and RB the tabs, B back to the room. Picking a thing goes straight back to the room with it
// riding the dot; a field is typed on whip's pad keyboard.
//
// SAVE AND EXIT HAVE BUTTONS OF THEIR OWN, in the room and in the menu alike: ☰ Menu saves (Done, in the world
// builder) and ⧉ View exits, as a click on those buttons does, Exit's "Discard?" included. Lua reads
// the two (client/property_furnish.lua, which holds them from the pause menu while a pad drives) and
// says so here (furnishPadButton). Each control a pad presses directly — the list (Y), Move / Rotate
// (RB), Exit, Save — carries its pad button's picture beside it in the bar (padKeys), so the one-line
// legend is left with the sticks and the rest; the bubble says what the pad does to the selection.
//
// A SCOPE OF ITS OWN, open only while a pad is the device (html[data-input], which Lua settles), so a
// mouse and keyboard keep the editor exactly as it was: the 'furnisher' scope below has no onNav, and
// the pad driver leaves them alone. Lua is told which half has the pad (furnishPad).
// ========================================

let fzPadMenu = false;   // the menu has the pad (the room has it otherwise)
let padSent = null;      // what Lua was last told: 'off', 'room' or 'menu'

const isPad = () => document.documentElement.dataset.input === 'pad';

// THE DIRECTOR'S WORLD BUILDER, ON A PAD: its Blueprint and Configure take the same ring. The page on the right is
// the Director's own (every field, tab, switch, slider and row of it); the Blueprint window's Cards, its card list
// and the cards on its grid (A on one picks it: its settings on the right). A field is typed on the pad keyboard; a
// slider and a list change with ◀ ▶ (padAdjust); LB / RB there are the thing's tabs. (Wiring cards stays the
// mouse's, or the Director's own screen, whose circle can pull a wire.)
const CFG_CONTROLS = ' .fz-cfg-x, #fz-cfg-body button, #fz-cfg-body input, #fz-cfg-body select, #fz-cfg-body textarea,'
    + ' #fz-cfg-body .dr-item-head, #fz-cfg-body [data-act]';
const BP_CONTROLS = ' #fz-bp-btn, .fz-bp-cards, .fz-bp-x, #fz-bp-pal-body .dr-pal-search, #fz-bp-pal-body .dr-chip,'
    + ' #fz-bp-pal-body .dr-pal-row, #fz-bp-body .dr-card,'
    // The Map window: its switch and X, + and -, and a mark's card's buttons (the marks are the mouse's).
    + ' #fz-map-btn, #fz-map .fz-bp-x, #fz-map-body .wp-place-zoom-btn, #fz-map-body .wp-place-info button';
const PAD_SELECTOR = '#fz-catalog-btn, .fz-seg-btn, #fz-stepchip, .fz-sel-head button, #fz-sel-tools button, #fz-confirm button,'
    + ' #fz-pedname-input, #fz-pedname button,'
    + ' .fz-subtab, .fz-cluster, .fz-rail-chip, #fz-search, [data-fz="byname"], .fz-tile, .fz-row,'
    + ' #fz-extra .fz-btn, #fz-exit, #fz-save,' + BP_CONTROLS + ',' + CFG_CONTROLS;
/** Which control the ring is on, kept across a redraw: a switch by what it writes, not by the value its next press
 *  writes (that flips as it is pressed); a card on the grid by its id; the rest by id or all their data. */
function ringKey(el) {
    if (el.id) return '#' + el.id;
    const d = el.dataset;
    if (el.classList.contains('dr-sw') && d.t) return 'sw|' + d.t + '|' + d.k;
    if (el.classList.contains('dr-card')) return 'card|' + d.id;
    return Object.keys(d).sort().map((k) => k + '=' + d[k]).join('|') || el.className;
}
const ring = createRing({ root: () => $('furnisher'), selector: PAD_SELECTOR, keyOf: ringKey });
// The world builder's warning is a question: while it is up its two buttons are all the ring reaches.
const ringEverything = ring.items;
ring.items = () => {
    const all = ringEverything();
    return fzConfirm !== null ? all.filter((el) => el.closest('#fz-confirm')) : all;
};

/** Where the ring starts: the first thing to place (or placed), else the tabs. In the Director's world builder: the
 *  page on the right while it is open, else the selection's Configure, else Place. */
function padFirst() {
    const items = ring.items();
    if (fzBuilder && fzBuilder.director) {
        return items.find((el) => el.closest('#fz-cfg-body')) || items.find((el) => el.matches('[data-fz="configure"]'))
            || items.find((el) => el.matches('#fz-catalog-btn')) || items[0] || null;
    }
    return items.find((el) => el.matches('.fz-tile, .fz-row')) || items.find((el) => el.matches('.fz-subtab'))
        || items[0] || null;
}

/** The emote menu is up over the editor (a hero shot's Pose): it has the keys and the pad, so this page's scopes
 *  stand aside and Lua is told the pad is not the room's. */
const covered = () => emoteMenuUp();

function padReport() {
    const on = fzOpen && isPad() && !covered();
    const now = on ? (fzPadMenu ? 'menu' : 'room') : 'off';
    if (now === padSent) return;
    padSent = now;
    nuiCallback('furnishPad', { on, menu: on && fzPadMenu });
}

/** Nothing near enough that way (the ring keeps to rows and columns): the nearest thing that way at all.
 *  Save and Exit sit alone in the far corner, and this is how the ring gets there. */
function farThatWay(cur, dir) {
    if (!cur) return null;
    const a = cur.getBoundingClientRect();
    const ax = (a.left + a.right) / 2, ay = (a.top + a.bottom) / 2;
    let best = null, bestD = Infinity;
    for (const el of ring.items()) {
        if (el === cur) continue;
        const b = el.getBoundingClientRect();
        const dx = (b.left + b.right) / 2 - ax, dy = (b.top + b.bottom) / 2 - ay;
        const along = dir === 'right' ? dx : dir === 'left' ? -dx : dir === 'down' ? dy : -dy;
        if (along <= 1) continue;
        const d = dx * dx + dy * dy;
        if (d < bestD) { bestD = d; best = el; }
    }
    return best;
}

/** The menu takes the pad (the catalog opens under the ring), or gives it back to the room. */
function setPadMenu(on) {
    fzPadMenu = !!on && fzOpen;
    const root = $('furnisher');
    if (root) root.classList.toggle('fz-padmenu', fzPadMenu);
    // (The Director's world builder has Place for that, a button of its own: the menu leaves it as it is.)
    const dir = !!(fzBuilder && fzBuilder.director);
    if (!dir) setCatalogOpen(fzPadMenu);
    // (There, back on the page or the window it was on; else Configure first, for what was just selected.)
    const at = ring.el();
    if (fzPadMenu && (!at || (dir && !at.closest('#fz-cfg, #fz-bp')))) ring.set(padFirst());
    padReport();
    NuiRouter.syncNavScope(true);   // the left stick: directions in the menu, the camera's in the room
    padLegend();
}

/** The search, typed on whip's pad keyboard: it filters as typing it would. The ring goes to the first
 *  thing found, else to the by-name offer (the world builder's, when the text reads as a model). */
function padType(el) {
    openPadKeyboard({
        title: String(el.placeholder || 'Search').replace(/…$/, ''),
        value: el.value,
        maxLength: 64,
        onDone: (text) => {
            el.value = text;
            fzSearch = text;
            renderGrid();
            const items = ring.items();
            const first = items.find((x) => x.matches('.fz-tile, .fz-row')) || items.find((x) => x.matches('[data-fz="byname"]'));
            if (first) ring.set(first);
            padLegend();
        },
    });
}

/** LB / RB: the tab before or after, the ring on its first thing. */
function padTab(dir) {
    if (!fzCatalogOpen) return;
    const tabs = tabsList();
    setTab(tabs[(tabs.indexOf(fzTab) + dir + tabs.length) % tabs.length]);
    ring.set(ring.items().find((x) => x.matches('.fz-tile, .fz-row')) || ring.items().find((x) => x.matches('.fz-subtab.active')));
}

/** A field of the Director's page (or its card list's search), typed on the pad keyboard: written as typing it would
 *  (its input, then its change). */
function padTypeField(el) {
    const row = el.closest('.dr-row');
    const lab = row && row.querySelector('.dr-label');
    const title = (lab && lab.firstChild && lab.firstChild.textContent.trim()) || el.placeholder || 'Type';
    openPadKeyboard({
        title,
        value: el.value,
        maxLength: Number(el.maxLength) > 0 ? Number(el.maxLength) : 200,
        numeric: el.type === 'number',
        onDone: (text) => {
            el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            // The card list's search: the ring on the first card it found.
            if (el.classList.contains('dr-pal-search')) {
                const first = ring.items().find((x) => x.matches('#fz-bp-pal-body .dr-pal-row'));
                if (first) ring.set(first);
            }
            padLegend();
        },
    });
}

/** ◀ ▶ on a slider or a list of the Director's page: a step along it, written as the mouse would. True when it was
 *  one (the ring stays on it). */
function padAdjust(el, dir) {
    if (!el || !el.closest('#fz-cfg-body')) return false;
    if (el.tagName === 'INPUT' && el.type === 'range') {
        const step = Number(el.step) || 1;
        const v = Math.min(Number(el.max), Math.max(Number(el.min), Number(el.value) + dir * step));
        if (String(v) === el.value) return true;
        el.value = String(v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
    }
    if (el.tagName === 'SELECT') {
        const i = Math.min(el.options.length - 1, Math.max(0, el.selectedIndex + dir));
        if (i === el.selectedIndex) return true;
        el.selectedIndex = i;
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
    }
    return false;
}

/** A on a card of the Blueprint window's grid: picked, as a mouse press on it picks it (its settings on the right). */
function padPickCard(el) {
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, button: 0, clientX: r.left + Math.min(24, r.width / 2), clientY: r.top + Math.min(12, r.height / 2) };
    el.dispatchEvent(new MouseEvent('mousedown', at));
    window.dispatchEvent(new MouseEvent('mouseup', at));
}

/** A in the menu: what the ring is on, pressed. Placing a thing, or going to one, is back to the room. */
function padActivate() {
    const el = ring.el();
    if (!el) { ring.set(padFirst()); return; }
    // The Director's: its fields typed, a slider or a list stepped on (◀ ▶ does the same), a card on the grid picked.
    if (el.closest('#fz-cfg-body, #fz-bp')) {
        if ((el.tagName === 'INPUT' && el.type !== 'range') || el.tagName === 'TEXTAREA') { padTypeField(el); return; }
        if (el.tagName === 'SELECT' || (el.tagName === 'INPUT' && el.type === 'range')) { padAdjust(el, 1); return; }
        if (el.classList.contains('dr-card')) { padPickCard(el); return; }
        el.click();
        return;
    }
    if (el.tagName === 'INPUT') { padType(el); return; }
    const what = el.dataset.fz;
    if (what === 'row') {
        // Selected and gone to in one ask, so the camera frames the one just selected.
        nuiCallback('furnishSelectIndex', { index: Number(el.dataset.index), goTo: true });
        setPadMenu(false);
        return;
    }
    const named = what === 'byname' && byNameModel() !== '';
    el.click();
    if (what === 'tile' || what === 'goto' || named) setPadMenu(false);
}

function padNav(nav) {
    if (!fzOpen) return;
    if (!fzPadMenu) {
        // The room: Y is the menu; the rest is Lua's (LB is whip's talk key: nothing here).
        if (nav === 'buttonY') setPadMenu(true);
        else if (nav !== 'tabPrev') nuiCallback('furnishPadPress', { nav });
        return;
    }
    if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') {
        // (◀ ▶ on a slider or a list of the Director's page change it; ▲ ▼ leave it.)
        if ((nav === 'left' || nav === 'right') && padAdjust(ring.el(), nav === 'right' ? 1 : -1)) { padLegend(); return; }
        if (!ring.el()) ring.set(padFirst());
        else if (!ring.step(nav)) ring.set(farThatWay(ring.el(), nav));
    } else if (nav === 'select') {
        padActivate();
    } else if (nav === 'back' || nav === 'buttonY') {
        if (nav === 'back' && fzConfirm !== null) hideConfirm();   // B on the warning is Keep
        else setPadMenu(false);
    } else if (nav === 'tabPrev' || nav === 'tabNext') {
        if (!padThingTab(nav === 'tabNext' ? 1 : -1)) padTab(nav === 'tabNext' ? 1 : -1);
    }
    padLegend();
}

/** LB / RB on the Director's page (a thing's General, Eye sight, Tasks...): the tab before or after, the ring on it.
 *  True when the ring was there and it has tabs. */
function padThingTab(dir) {
    const at = ring.el();
    if (!at || !at.closest('#fz-cfg-body')) return false;
    const tabs = Array.from(document.querySelectorAll('#fz-cfg-body .dr-ptab'));
    if (tabs.length < 2) return false;
    const i = Math.max(0, tabs.findIndex((t) => t.classList.contains('on')));
    const next = tabs[(i + dir + tabs.length) % tabs.length];
    next.click();
    requestAnimationFrame(() => {
        const again = Array.from(document.querySelectorAll('#fz-cfg-body .dr-ptab')).find((t) => t.dataset.tab === next.dataset.tab);
        if (again) ring.set(again);
        padLegend();
    });
    return true;
}

/** One pad hint as markup: its buttons' pictures, then what they do. */
function padHintHtml(buttons, does) {
    let html = '<span class="fz-hint">';
    for (const name of (Array.isArray(buttons) ? buttons : [buttons])) {
        const img = padGlyph(name, 'fz-pad-glyph');
        if (img) html += img.outerHTML;
    }
    return html + escapeHtml(does) + '</span>';
}

/** The pad's line, bottom left, for what is going on: the sticks and the presses that are not on a
 *  button of their own (Y, RB, ☰ and ⧉ ride on the bar's), the selection's among them (a door is the
 *  world's: it does not move). Drawn only when it says something new. */
function padLegend() {
    const box = $('fz-pad-hints');
    if (!box) return;
    const d = fzState || {};
    let hints;
    const dir = !!(fzBuilder && fzBuilder.director);
    if (fzPadMenu) {
        const el = ring.el();
        const changes = !!el && (el.tagName === 'SELECT' || (el.tagName === 'INPUT' && el.type === 'range'));
        const a = !el ? 'Choose' : changes ? 'Next' : el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' ? 'Type'
            : el.classList.contains('dr-card') ? 'Open' : el.dataset.fz === 'tile' ? 'Place'
            : el.dataset.fz === 'row' ? 'Go to' : 'Press';
        hints = [['dpad', changes ? 'Move / ◀ ▶ change' : 'Move'], ['a', a], [['lb', 'rb'], 'Tab'], ['b', 'Back to the room']];
    } else if (d.carrying) {
        hints = [['ls', 'Fly'], ['rs', 'Look'], ['a', 'Put down'], [['lt', 'rt'], 'Turn'], ['b', 'Cancel']];
    } else if (d.picking) {
        hints = [['ls', 'Fly'], ['rs', 'Look'], ['a', 'Pick the door'], ['b', 'Cancel']];
    } else if (d.selected) {
        const it = selectedItem(d);
        const moves = !(it && it.kind === 'door');
        const rot = d.mode === 'rotate';
        hints = [['ls', 'Fly'], ['rs', 'Look'], ['a', 'Select']];
        if (moves) hints.push(['x', 'Pick up'], ['dpad', rot ? 'Turn' : 'Nudge'], [['lt', 'rt'], 'Lower / raise']);
        hints.push(['b', 'Deselect']);
    } else {
        hints = [['ls', 'Fly'], ['rs', 'Look'], [['lt', 'rt'], 'Down / up'], ['a', 'Select'], ['l3', 'Fast']];
    }
    // The Director's world builder has no bar to carry the pad's buttons beside them: Y (the menu: Place, Blueprint,
    // the selection's Configure), ☰ Save and ⧉ Exit are on this line.
    if (dir && !fzPadMenu) hints.push(['y', d.selected ? 'Menu / Configure' : 'Menu'], ['menu', 'Save'], ['view', 'Exit']);
    const sig = JSON.stringify(hints);
    if (sig === box.dataset.sig) return;
    box.dataset.sig = sig;
    box.innerHTML = hints.map(([b, t]) => padHintHtml(b, t)).join('');
}

/** Each control a pad presses directly gets its pad button's picture beside it — shown only on a pad
 *  (furnisher.css .fz-pad-key): the list (Y), the Move / Rotate switch (RB), Exit (⧉) and Save (☰). A sibling rather than inside: Save's and Exit's words are rewritten as the state
 *  changes ("Save •", "Discard?"). Made once; they are in the page from the start. */
const PAD_KEYS = [['#fz-catalog-btn', 'y'], ['#furnisher .fz-bar > .fz-seg', 'rb'], ['#fz-exit', 'view'], ['#fz-save', 'menu']];
(function padKeys() {
    for (const [sel, glyph] of PAD_KEYS) {
        const btn = document.querySelector(sel);
        if (!btn) continue;
        const key = document.createElement('span');
        key.className = 'fz-pad-key';
        const img = padGlyph(glyph, 'fz-pad-glyph');
        if (img) key.appendChild(img);
        btn.before(key);
    }
})();

// ☰ and ⧉ on a pad, from Lua: the page's own Save and Exit, pressed as a click presses them (Exit arms
// "Discard?" over unsaved work). Not while the pad keyboard is up (its own buttons), nor under the emote menu.
NuiRouter.register('furnishPadButton', (d) => {
    if (!fzOpen || !isPad() || covered() || padKeyboardOpen()) return;
    const btn = $(d && d.button === 'save' ? 'fz-save' : d && d.button === 'exit' ? 'fz-exit' : '');
    if (btn) btn.click();
});

// The device changed (Lua settles it): Lua is told, and a mouse picking up leaves the menu.
new MutationObserver(() => {
    if (!fzOpen) return;
    if (!isPad() && fzPadMenu) {
        fzPadMenu = false;
        $('furnisher').classList.remove('fz-padmenu');
    }
    padReport();
    padLegend();
    // The bubble's hints are the device's, and the keycaps come and go with it: it is measured again.
    selFrame = null;
    renderSel(fzState || {});
}).observe(document.documentElement, { attributes: true, attributeFilter: ['data-input'] });

// The emote menu opening or closing over the editor: Lua hears whether the pad is the room's again.
window.addEventListener('emotesmenu', () => { if (fzOpen) padReport(); });

// Over the furnisher scope (30): walked first, and open only on a pad. In the room the left stick is
// the camera's (analog: not a direction), and in the menu it moves the ring as the D-pad does.
NuiRouter.registerKeyScope({
    name: 'furnisherPad',
    priority: 29.5,
    isOpen: () => fzOpen && isPad() && !covered(),
    onKey: () => {},
    onNav: padNav,
    analog: () => !fzPadMenu,
    onAnalog: () => {},
});

// ========================================
// KEYBOARD
//
// Scope 30 — just above the /whip panel at 25, in the range router.js documents as free. Open for
// the whole session, because NUI focus is held for the whole session.
//
// IT CLAIMS KEYS AND HANDLES NONE, which is a real job rather than a stub: a scope that reports
// open stops the walk, so nothing registered above it (the hotbar's Tab, the inventory, the bank)
// can act on a key while a full-screen editor owns the screen. The character creator's scope at
// priority 0 is the same shape for the same reason.
//
// BACKSPACE IS NOT HANDLED HERE. It was, for one build, and then Lua read it too — two readers
// arming two separate warnings for one press. The key belongs to the RegisterKeyMapping in
// client/property_furnish.lua, which works whether or not this page ever drew; this page owns the
// Exit button and nothing else. See the note there.
//
// NOTHING IS preventDefault'ed. The game is reading the keyboard underneath this page (KeepInput)
// and that is where every control lives — cancelling keys here would stop nothing on the game side
// and would break typing on this one.
// ========================================

NuiRouter.registerKeyScope({
    name: 'furnisher',
    priority: 30,
    // (Not while the emote menu is up over it: its Esc and keys are the menu's. See `covered`.)
    isOpen: () => fzOpen && !covered(),
    // Esc: the Input ped name window closes; else a pick riding the mouse is taken back out (dropHeld).
    onKey: (e) => {
        if (!e || e.key !== 'Escape') return;
        if (pedNameOpen) { hidePedName(); return; }
        dropHeld();
    },
});

// ROUTER REGISTRATION — see router.js's header.
NuiRouter.register('furnishOpen', (d) => show(d));
NuiRouter.register('furnishClose', () => hide());
NuiRouter.register('furnishCatalog', (d) => {
    fzCatalog = d.catalog || { clusters: [], categories: [], props: [] };

    fzProps = {};
    for (const p of (fzCatalog.props || [])) fzProps[p.model] = p;

    // Land on the first cluster, or keep the open one if it survived the push.
    const cs = clusters();
    if (!cs.some((c) => c.key === fzCluster)) fzCluster = cs.length ? cs[0].key : null;

    if (fzOpen) { renderRail(); renderGrid(); }
});
NuiRouter.register('furnishItems', (d) => {
    fzItems = d.items || [];
    if (!fzOpen) return;
    // The count lives on the tab, so it moves whether or not the list is the side being looked at.
    renderSubtabs();
    if (fzTab === 'placed') renderGrid();
    // The bubble names the selection by its row (a new pick's row can arrive after its state).
    renderSel(fzState || {});
});
NuiRouter.register('furnishState', (d) => renderState(d));
// The camera and the selected object, every frame either moves, for the markers.
NuiRouter.register('furnishView', (d) => { if (fzOpen) FurnishGizmo.setView(d); });
// The Director's Place marker: the selection rides the pointer until a left click puts it down.
NuiRouter.register('furnishCarry', (d) => { if (fzOpen && d && typeof d.i === 'number') FurnishGizmo.carry(d.i, d.fresh === true); });
NuiRouter.register('furnishSaved', (d) => { flash(d.ok === true, d.text); if (fzOpen) saveLabel(); });
// The world builder asks before a thing a card uses goes (client/furnish_builder.lua confirmRemove).
NuiRouter.register('furnishConfirmRemove', (d) => { if (fzOpen) showConfirm(d); });
