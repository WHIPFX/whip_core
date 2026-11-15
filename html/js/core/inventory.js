// ========================================
// INVENTORY CORE — FACADE
//
// The one import a renderer needs. Everything a UI must reach lives behind this file:
// the state objects, the actions, the item definitions, the optimistic-op engine, the event
// stream, and the renderer seat. A custom renderer receives this whole module as `api`
// (js/renderer-loader.js); docs/nui-inventory.md is the contract.
//
// THE RENDERER SEAT. Exactly one renderer draws the inventory at a time. The default
// renderer (js/inventory.js) claims the seat at load; a custom renderer resource
// (Config.InventoryRenderer) claims it instead when configured — same seat, so the wire
// layer never knows or cares which one is drawing. The loader (js/renderer-loader.js) fills a
// custom renderer out to every method the wire calls (RENDERER_METHODS) before seating it, and
// can swap it for another, or back to whip's own, while the page runs.
//
// A SHOP VISIT IS WHIP'S OWN SCREEN unless the custom renderer says `drawsShop: true`: the
// shop (js/shops.js) draws into the default renderer's page, so while one is open the wire
// talks to the default renderer, and the custom one takes over again when it closes.
//
// A REVERT REDRAWS THROUGH THE SEAT. The op engine calls one redraw per view (inv-state's
// INV_VIEWS); those are this file's, and each asks whoever is drawing NOW: whip's own hooks,
// or the seated custom renderer's own (registered on the copy of `api` its loader gave it), or
// its render. So a refused move repaints whip's shop screen over a custom UI too, and the
// hotbar follows a refused move whichever UI is up.
// ========================================

import { inv, shop, setViewRenderHook as setViewRedraw, slotConfig, isIgnitionKeyItem, slotTakesItem } from './inv-state.js';
import * as invState from './inv-state.js';
import { invEvents } from './emitter.js';
import * as ops from './inv-ops.js';
import * as actions from './inv-actions.js';
import { getItemDefs } from './item-defs.js';
import { whenMet } from './item-rules.js';
import { nuiCallback, itemImageUrl, setItemImage, decodeTextEntities } from '../utils.js';

/** Every method the wire calls on the seated renderer (core/inv-wire.js). */
export const RENDERER_METHODS = [
    'showOverlay', 'hideOverlay', 'renderAll', 'refreshSlots', 'renderWeights', 'renderGround',
    'renderContainer', 'renderContainerInfo', 'renderIgnition', 'renderPanelStack', 'renderPlayerInv',
    'renderPlayerInvInfo', 'renderAccessories', 'tagItemSlots', 'setPanels', 'flashPanels',
    'isMidDrag', 'hasPlayerGrid', 'cancelInteractions', 'notify',
];

let activeRenderer = null;
let defaultRenderer = null;   // the first to register: js/inventory.js

/** The views a revert redraws (inv-state's INV_VIEWS). */
const VIEWS = ['state', 'ground', 'container', 'ignition', 'panels', 'playerInv'];
/** whip's own renderer's redraw per view (js/inventory.js sets them through setViewRenderHook below). */
const defaultViewHooks = {};
/** A seated custom renderer's own, from its loader: renderer -> { view: fn }. */
const customViewHooks = new WeakMap();

/**
 * Claim the renderer seat. Last registration wins — the default renderer registers at
 * module load, and a configured custom renderer (loaded later via dynamic import)
 * replaces it.
 * @param {object} renderer  implements the renderer interface (docs/nui-inventory.md)
 * @param {object} [viewHooks]  the custom renderer's own redraw per view (renderer-loader.js)
 */
export function registerRenderer(renderer, viewHooks) {
    if (!defaultRenderer) defaultRenderer = renderer;
    else if (viewHooks) customViewHooks.set(renderer, viewHooks);
    activeRenderer = renderer;
    invEvents.emit('renderer-changed', { renderer });
}

/** Give the seat back to whip's own renderer (renderer-loader.js, when a custom UI is swapped out). */
export function seatDefaultRenderer() {
    if (!defaultRenderer || activeRenderer === defaultRenderer) return;
    activeRenderer = defaultRenderer;
    invEvents.emit('renderer-changed', { renderer: defaultRenderer });
}

/**
 * whip's OWN renderer's redraw for one optimistic view. A custom renderer gets a copy of `api` from
 * its loader whose setViewRenderHook is its own, so the two never overwrite each other's.
 * @param {string} name  a view: state, ground, container, ignition, panels, playerInv
 * @param {function} fn
 */
export function setViewRenderHook(name, fn) {
    if (VIEWS.indexOf(name) !== -1) defaultViewHooks[name] = fn;
}

function redrawView(name) {
    const r = getRenderer();
    if (r === defaultRenderer) {
        if (defaultViewHooks[name]) defaultViewHooks[name]();
    } else if (r) {
        const own = customViewHooks.get(r);
        if (own && own[name]) own[name]();
        else r.renderAll();
    }
    // The hotbar draws the pockets' first slots whichever UI is up.
    if (name === 'state' && invState.invHotbarHooks) invState.invHotbarHooks.syncHotbar();
}
for (const name of VIEWS) setViewRedraw(name, () => redrawView(name));

/** The wire layer's view of the seat: the default renderer while whip's shop screen is up. Null only
 *  before any renderer has loaded. */
export function getRenderer() {
    if (shop.open && activeRenderer !== defaultRenderer && !(activeRenderer && activeRenderer.drawsShop === true)) {
        return defaultRenderer;
    }
    return activeRenderer;
}

/** Is whip's own inventory the one drawing right now? (Its key scope drives the controller only then.) */
export function defaultSeated() {
    return getRenderer() === defaultRenderer;
}

// The third-party surface, re-exported from one place. `inv`/`shop` are LIVE state (read
// freely; change slots through `actions`, or through the ops contract by hand); `actions` is every
// player gesture as one call (core/inv-actions.js); `getItemDefs`/`itemImageUrl`/`setItemImage`/
// `whenMet`/`decodeTextEntities` are what a slot needs to be drawn; `ops` is the optimistic engine;
// `events` is the announcement stream; `slotConfig`/`isIgnitionKeyItem` are the server-registered
// slot registries, and `slotTakesItem` a strip slot's rule; `nuiCallback` is the plain outbound wire. closeInventory is deliberately NOT here:
// inv-wire imports this file for the seat, so the renderer-loader passes it to custom renderers as
// `close` instead (keeps the graph a DAG). A custom renderer gets a COPY of this module from its loader,
// with its own `events` and `setViewRenderHook`, so swapping it out undoes what it subscribed.
export {
    inv, shop, invEvents as events, ops, actions, slotConfig, isIgnitionKeyItem, slotTakesItem,
    nuiCallback, getItemDefs, itemImageUrl, setItemImage, whenMet, decodeTextEntities,
};
