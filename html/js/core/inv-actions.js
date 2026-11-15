// ========================================
// INVENTORY CORE — ACTIONS
//
// Every gesture a player makes on the inventory, as one call each, with no DOM: move a stack,
// move one, shift-click, split, destroy, use, give, place, and an item's right-click menu. A
// custom inventory UI (docs/nui-inventory.md) calls these and redraws; it never builds a move
// payload, picks a snapshot or guesses where a split lands.
//
// SAME RULES AND PAYLOADS AS WHIP'S OWN INVENTORY (js/inventory.js, whose drag, right-click and
// menu code these were taken from): which action a pair of grids sends, which views a gesture
// snapshots, what changes on screen before the server answers. When one changes, so must the
// other, until whip's own inventory calls these too.
//
// EACH CALL CHANGES THE STATE OPTIMISTICALLY AND SENDS. It answers { ok: true }, or
// { ok: false, reason } where `reason` is the line whip's own inventory shows the player (absent
// for a refusal it shows as a red slot or nothing at all). Redraw after an ok: the state has
// already moved. The server's answer comes later through the renderer interface, as for any move.
//
// AN ADDRESS is { container, slot }: 'player' (the pockets), 'accessory', 'ground', 'container'
// (the stash, boot or glovebox), 'ignition' (slot 1), a panel's key ('panel:<id>', inv.panels[i].key)
// or 'targetPlayer' (an admin looking into someone's pockets).
// ========================================

import { inv, shop, slotConfig, isIgnitionKeyItem, panelByKey, slotTakesItem, slotTakesText } from './inv-state.js';
import { getItemDefs } from './item-defs.js';
import { whenMet } from './item-rules.js';
import { beginOp, extendOp, emit, commitOp, settleUnsentOp } from './inv-ops.js';
import { nuiCallback, decodeTextEntities } from '../utils.js';

const ok = { ok: true };
const no = (reason) => ({ ok: false, reason });

const defOf = (key) => { const d = getItemDefs(); return (d && d[key]) || null; };
const nameOf = (key) => { const d = defOf(key); return d ? d.name : key; };

// ------------------------------------------
// Reading the grids
// ------------------------------------------

/** What is in a slot, or null. */
export function slotAt(container, slot) {
    const key = String(slot);
    switch (container) {
        case 'ground':       return inv.groundItems[key] || null;
        case 'container':    return inv.containerItems[key] || null;
        case 'ignition':     return inv.ignitionSlot || null;
        case 'shop':         return shop.items[key] || null;
        case 'targetPlayer': return (inv.playerInvItems.player && inv.playerInvItems.player[key]) || null;
        default: {
            const panel = panelByKey(container);
            if (panel) return panel.items[key] || null;
            return (inv.state[container] && inv.state[container][key]) || null;
        }
    }
}

const NOT_POCKETS = new Set(['ground', 'container', 'ignition', 'shop', 'basket', 'targetPlayer']);

/** One of the player's own containers ('player', 'accessory', whatever PlayerContainers adds)? */
export function isPocketGrid(container) {
    return !!container && !NOT_POCKETS.has(container) && !panelByKey(container);
}

/** Does this accessory slot take this item? */
export function accessoryTakes(slot, itemKey) {
    return slotTakesItem(slotConfig.accessorySlots.find(c => c.slot === slot), itemKey);
}

/** A slot-keyed store: its view, items, size, weight and per-slot rule. Null for the ground, the
 *  ignition, the shop and the admin view. */
function gridOf(container) {
    if (container === 'container') {
        if (!inv.containerOpen) return null;
        const def = inv.containerDef || {};
        return { container, view: 'container', items: inv.containerItems, slots: def.slots || 0,
                 weight: inv.containerWeight || 0, maxWeight: def.maxWeight || null };
    }
    const panel = panelByKey(container);
    if (panel) {
        return { container, view: 'panels', items: panel.items, slots: panel.slots || 1, panel,
                 weight: panel.currentWeight || 0, maxWeight: panel.maxWeight || null };
    }
    if (isPocketGrid(container)) {
        if (!inv.state[container]) inv.state[container] = {};
        return { container, view: 'state', items: inv.state[container],
                 slots: inv.maxSlots[container] || 0,
                 takes: container === 'accessory' ? accessoryTakes : null };
    }
    return null;
}

/** What a stack weighs, contents included (the server's `w` when it sent one). */
export function stackWeight(d) {
    if (!d) return 0;
    if (typeof d.w === 'number') return d.w;
    const def = defOf(d.item);
    return ((def && def.weight) || 0) * (d.amount || 1);
}

/** How much a grid holds and can hold, in kg: { now, max } (max null when it has no limit). The pockets
 *  and the accessory strip are one weight. */
export function weightOf(container) {
    if (container === 'player' || container === 'accessory') {
        return { now: (inv.weights.player || 0) + (inv.weights.accessory || 0), max: inv.maxWeight.player || null };
    }
    if (container === 'targetPlayer') {
        return { now: inv.playerInvWeights.player || 0, max: inv.playerInvMaxWeight.player || null };
    }
    const g = gridOf(container);
    return g ? { now: g.weight || 0, max: g.maxWeight || null } : { now: 0, max: null };
}

function sameMeta(a, b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
    const ka = Object.keys(a);
    if (ka.length !== Object.keys(b).length) return false;
    for (const k of ka) if (!sameMeta(a[k], b[k])) return false;
    return true;
}

/** Can two stacks combine? Equal metadata, apart from the activity log's `uid`. */
function stacksWith(a, b) {
    const strip = (m) => {
        const out = {};
        if (m && typeof m === 'object') for (const k of Object.keys(m)) if (k !== 'uid') out[k] = m[k];
        return out;
    };
    return sameMeta(strip(a), strip(b));
}

/** The first empty slot that takes this item (the server's Stores.freeSlot). */
function predictFreeSlot(grid, itemKey) {
    for (let s = 1; s <= grid.slots; s++) {
        if (!grid.items[String(s)] && (!grid.takes || grid.takes(s, itemKey))) return s;
    }
    return null;
}

/** Where a whole stack lands (Stores.slotAccepting): a stack it can join whole, else the first empty slot. */
function predictSlotAccepting(grid, itemKey, amount, metadata) {
    const def = defOf(itemKey);
    if (!def) return null;
    if (grid.panel && grid.panel.allowed && !grid.panel.allowed[itemKey]) return null;
    if (def.stack && (def.maxStack || 1) > 1) {
        for (let s = 1; s <= grid.slots; s++) {
            const d = grid.items[String(s)];
            if (d && d.item === itemKey && stacksWith(d.metadata, metadata)
                && (d.amount || 1) + amount <= def.maxStack
                && (!grid.takes || grid.takes(s, itemKey))) return s;
        }
    }
    return predictFreeSlot(grid, itemKey);
}

function weightFits(grid, w) {
    return !grid.maxWeight || (grid.weight || 0) + w <= grid.maxWeight + 1e-6;
}

function placeInto(grid, slot, data) {
    const key = String(slot);
    const at = grid.items[key];
    if (at) at.amount = (at.amount || 0) + (data.amount || 0);
    else grid.items[key] = data;
}

/** What Lua needs to address a slot (client/inventory.lua's nuiStoreAddr). */
function slotRef(container, slot) {
    const panel = panelByKey(container);
    return { container, slot, containerId: inv.containerId, panelId: panel ? panel.id : undefined };
}

/** Nearby's piles numbered 1..n again after one is taken from the middle. */
function reindexGround() {
    const keys = Object.keys(inv.groundItems).sort((a, b) => parseInt(a) - parseInt(b));
    const items = keys.map(k => inv.groundItems[k]);
    inv.groundItems = {};
    items.forEach((d, i) => { inv.groundItems[String(i + 1)] = d; });
}

const weightPool = (c) => (c === 'player' || c === 'accessory') ? 'pockets' : c;

/** Would this drop take its destination past what it holds? Only between stores, only where the limit is known. */
function dropTooHeavy(from, to, moving, there) {
    if (from === 'shop' || to === 'shop') return false;
    if (weightPool(from) === weightPool(to)) return false;
    // A pile off the ground comes up as far as the pockets take it (the server takes part of it): too heavy only when
    // not even one would go. One of it weighs its share of the pile, when that is known.
    if (from === 'ground' && (moving.amount || 1) > 1) {
        const n = moving.amount;
        moving = { item: moving.item, amount: 1, w: typeof moving.w === 'number' ? moving.w / n : undefined };
    }
    const back = (there && there.item !== moving.item) ? stackWeight(there) : 0;
    const net = stackWeight(moving) - back;
    if (net <= 0) return false;
    if (weightPool(to) === 'pockets') {
        const max = inv.maxWeight.player;
        if (!max) return false;
        const now = (inv.weights.player || 0) + (inv.weights.accessory || 0);
        return now + net > max + 1e-6;
    }
    const grid = gridOf(to);
    return !!grid && !weightFits(grid, net);
}

/**
 * Would a drop of the stack in `from` onto `to` be refused before it is sent? The red edge whip's own
 * inventory draws while you drag over a slot. True for an empty `from`, the shop, a bag with the ground or
 * another player's inventory, a typed slot that does not take it, an occupied ignition, a read-only panel's
 * edge, a panel that does not take the item, and a drop too heavy for where it is going. The accessory strip
 * trades with everything the pockets do.
 */
export function refused(from, to) {
    const f = from.container, t = to.container;
    const fs = Number(from.slot), ts = Number(to.slot);
    if (!f || !t) return true;
    const moving = slotAt(f, fs);
    if (!moving) return true;
    const there = slotAt(t, ts);
    if (f === 'shop' || t === 'shop') return true;
    if (bagWithoutRoute(f, t)) return true;
    if (t === 'accessory' && !accessoryTakes(ts, moving.item)) return true;
    if (f === 'accessory' && there && !accessoryTakes(fs, there.item)) return true;
    if (t === 'ignition' && (!isIgnitionKeyItem(moving.item) || inv.ignitionSlot)) return true;
    if (f === 'ignition' && there) return true;
    const fp = panelByKey(f), tp = panelByKey(t);
    if (fp !== tp && ((fp && fp.readOnly) || (tp && tp.readOnly))) return true;
    if (tp && tp !== fp && tp.allowed && !tp.allowed[moving.item]) return true;
    if (dropTooHeavy(f, t, moving, there)) return true;
    return false;
}

/** A bag (a resource's panel) and the ground or another player's inventory: the server has no move between them
 *  (pickupGroundItem and dropToGround name pockets only; the admin view's moves are pockets-to-pockets). */
function bagWithoutRoute(a, b) {
    const other = (c) => c === 'ground' || c === 'targetPlayer';
    return (!!panelByKey(a) && other(b)) || (!!panelByKey(b) && other(a));
}

/** Stack onto the same item, swap with a different one, or move into an empty slot. */
function moveBetweenStores(fromStore, fromKey, toStore, toKey) {
    const fromData = fromStore && fromStore[fromKey];
    if (!fromData) return false;
    const toData = toStore[toKey];
    if (toData && toData.item === fromData.item) {
        toData.amount = (toData.amount || 0) + (fromData.amount || 0);
        delete fromStore[fromKey];
    } else if (toData) {
        fromStore[fromKey] = toData;
        toStore[toKey] = fromData;
    } else {
        toStore[toKey] = fromData;
        delete fromStore[fromKey];
    }
    return true;
}

const onlyHere = (cfg, verb) => 'Only ' + slotTakesText(cfg, getItemDefs()) + verb;

// ------------------------------------------
// Move a whole stack (a drag)
// ------------------------------------------

/** Drag the stack in `from` onto `to`. */
export function move(from, to) {
    const fromContainer = from.container, toContainer = to.container;
    const fromSlot = Number(from.slot), toSlot = Number(to.slot);
    if (!fromContainer || !toContainer || !fromSlot || !toSlot) return no();
    if (fromContainer === toContainer && fromSlot === toSlot) return no();

    const movingData = slotAt(fromContainer, fromSlot);
    if (movingData && dropTooHeavy(fromContainer, toContainer, movingData, slotAt(toContainer, toSlot))) return no();
    if (fromContainer === 'shop' || toContainer === 'shop') return no();
    if (bagWithoutRoute(fromContainer, toContainer)) return no();
    // The strip's typed slots against anything but the pockets (moveBody checks pockets and strip itself, and says
    // why): what goes in must fit, and on a swap what comes back must fit the slot it left.
    const thereData = slotAt(toContainer, toSlot);
    if (!(isPocketGrid(fromContainer) && isPocketGrid(toContainer)) && movingData
        && ((toContainer === 'accessory' && !accessoryTakes(toSlot, movingData.item))
            || (fromContainer === 'accessory' && thereData && !accessoryTakes(fromSlot, thereData.item)))) return no();

    const opId = beginOp(inv.containerOpen ? ['state', 'ground', 'container'] : ['state', 'ground']);
    try {
        return moveBody(opId, fromContainer, fromSlot, toContainer, toSlot);
    } finally {
        settleUnsentOp(opId);
    }
}

function moveBody(opId, fromContainer, fromSlot, toContainer, toSlot) {
    const fromKey = String(fromSlot), toKey = String(toSlot);
    const emitMove = (event, extra) => emit(opId, event, Object.assign({
        fromContainer, fromSlot, toContainer, toSlot,
    }, extra || null));

    // ---- the accessory strip with the pockets, or within itself: typed slots both ways ----
    // The strip with anything else is the branch below for the pockets' own move with that thing: each reads and
    // writes inv.state[container] and sends the container's name, and the server takes 'accessory' as a pocket.
    if ((fromContainer === 'accessory' || toContainer === 'accessory')
        && isPocketGrid(fromContainer) && isPocketGrid(toContainer)) {
        if (toContainer === 'accessory' && fromContainer !== 'accessory') {
            const fromData = inv.state[fromContainer] && inv.state[fromContainer][fromKey];
            if (!fromData) return no();
            const cfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
            if (cfg && !slotTakesItem(cfg, fromData.item)) return no(onlyHere(cfg, ' can go here'));
            if (!inv.state.accessory) inv.state.accessory = {};
            if (inv.state.accessory[toKey]) {
                const existing = inv.state.accessory[toKey];
                inv.state.accessory[toKey] = fromData;
                inv.state[fromContainer][fromKey] = existing;
            } else {
                inv.state.accessory[toKey] = fromData;
                delete inv.state[fromContainer][fromKey];
            }
            emitMove('moveItem');
            return ok;
        }
        if (fromContainer === 'accessory' && toContainer !== 'accessory') {
            const fromData = inv.state.accessory && inv.state.accessory[fromKey];
            if (!fromData) return no();
            if (!inv.state[toContainer]) inv.state[toContainer] = {};
            const toData = inv.state[toContainer][toKey];
            if (toData) {
                const cfg = slotConfig.accessorySlots.find(c => c.slot === fromSlot);
                if (cfg && !slotTakesItem(cfg, toData.item)) return no(onlyHere(cfg, ' can go in that slot'));
                inv.state.accessory[fromKey] = toData;
                inv.state[toContainer][toKey] = fromData;
            } else {
                inv.state[toContainer][toKey] = fromData;
                delete inv.state.accessory[fromKey];
            }
            emitMove('moveItem');
            return ok;
        }
        const fromData = inv.state.accessory && inv.state.accessory[fromKey];
        const toData = inv.state.accessory && inv.state.accessory[toKey];
        if (!fromData) return no();
        const toCfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
        const fromCfg = slotConfig.accessorySlots.find(c => c.slot === fromSlot);
        if (toCfg && !slotTakesItem(toCfg, fromData.item)) return no(onlyHere(toCfg, ' can go here'));
        if (toData && fromCfg && !slotTakesItem(fromCfg, toData.item)) return no(onlyHere(fromCfg, ' can go in that slot'));
        if (toData) {
            inv.state.accessory[fromKey] = toData;
            inv.state.accessory[toKey] = fromData;
        } else {
            inv.state.accessory[toKey] = fromData;
            delete inv.state.accessory[fromKey];
        }
        emitMove('moveItem');
        return ok;
    }

    // ---- the ignition: a key in, onto an empty slot; a key out, onto an empty slot ----
    if (inv.ignitionOpen && (fromContainer === 'ignition' || toContainer === 'ignition')) {
        // A bag on the other side (a key in a backpack): its items are the panel's own, and the move names it.
        const keyPanel = panelByKey(fromContainer) || panelByKey(toContainer);
        const ignitionOp = extendOp(opId, ['ignition'].concat(inv.containerOpen ? ['container'] : [],
            keyPanel ? ['panels'] : []));
        const panelId = keyPanel ? keyPanel.id : undefined;
        if (toContainer === 'ignition' && fromContainer !== 'ignition') {
            const fromData = fromContainer === 'container' ? inv.containerItems[fromKey]
                : keyPanel ? (keyPanel.readOnly ? null : keyPanel.items[fromKey])
                : (inv.state[fromContainer] && inv.state[fromContainer][fromKey]);
            if (!(fromData && isIgnitionKeyItem(fromData.item) && !inv.ignitionSlot)) { commitOp(ignitionOp); return no(); }
            inv.ignitionSlot = fromData;
            if (fromContainer === 'container') delete inv.containerItems[fromKey];
            else if (keyPanel) delete keyPanel.items[fromKey];
            else delete inv.state[fromContainer][fromKey];
            emit(ignitionOp, 'ignitionInsertKey', {
                vehicleId: inv.ignitionVehicleId, containerId: inv.containerId, fromContainer, fromSlot, panelId,
            });
            return ok;
        }
        if (fromContainer === 'ignition' && toContainer !== 'ignition') {
            if (!inv.ignitionSlot) return no();
            if (keyPanel && keyPanel.readOnly) { commitOp(ignitionOp); return no(); }
            const store = toContainer === 'container' ? inv.containerItems
                : keyPanel ? keyPanel.items
                : (inv.state[toContainer] = inv.state[toContainer] || {});
            if (store[toKey]) { commitOp(ignitionOp); return no(); }
            store[toKey] = inv.ignitionSlot;
            inv.ignitionSlot = null;
            emit(ignitionOp, 'ignitionRemoveKey', {
                vehicleId: inv.ignitionVehicleId, containerId: inv.containerId, toContainer, toSlot, panelId,
            });
            return ok;
        }
        return no();
    }

    // ---- panels (wallets, bags, benches): any number open; nothing crosses a read-only edge ----
    if (panelByKey(fromContainer) || panelByKey(toContainer)) {
        const fromPanel = panelByKey(fromContainer);
        const toPanel = panelByKey(toContainer);
        if (fromPanel !== toPanel && ((fromPanel && fromPanel.readOnly) || (toPanel && toPanel.readOnly))) return no();

        if (toPanel && !fromPanel) {
            const fromData = fromContainer === 'container' ? inv.containerItems[fromKey]
                : (inv.state[fromContainer] && inv.state[fromContainer][fromKey]);
            if (!fromData) return no();
            const extOp = extendOp(opId, fromContainer === 'container' ? ['panels', 'container'] : ['panels', 'state']);
            if (fromContainer === 'container') delete inv.containerItems[fromKey];
            else delete inv.state[fromContainer][fromKey];
            toPanel.items[toKey] = { item: fromData.item, amount: fromData.amount || 1, metadata: fromData.metadata || null };
            emit(extOp, 'externalPanelMove', {
                panelId: toPanel.id, containerId: inv.containerId, direction: 'toPanel',
                panelSlot: toSlot, invContainer: fromContainer, invSlot: fromSlot,
                item: fromData.item, amount: fromData.amount || 1, metadata: fromData.metadata || null,
            });
            return ok;
        }
        if (fromPanel && toPanel && fromPanel === toPanel) {
            if (fromSlot === toSlot) return no();
            const src = fromPanel.items[fromKey];
            if (!src) return no();
            const dst = fromPanel.items[toKey] || null;
            const extOp = extendOp(opId, ['panels']);
            fromPanel.items[toKey] = src;
            if (dst) fromPanel.items[fromKey] = dst; else delete fromPanel.items[fromKey];
            emit(extOp, 'externalPanelMove', {
                panelId: fromPanel.id, containerId: inv.containerId, direction: 'withinPanel',
                panelSlot: fromSlot, toPanelSlot: toSlot,
                item: src.item, amount: src.amount || 1, metadata: src.metadata || null,
            });
            return ok;
        }
        if (fromPanel && toPanel) {
            const src = fromPanel.items[fromKey];
            if (!src) return no();
            const dst = toPanel.items[toKey] || null;
            const extOp = extendOp(opId, ['panels']);
            toPanel.items[toKey] = src;
            if (dst) fromPanel.items[fromKey] = dst; else delete fromPanel.items[fromKey];
            emit(extOp, 'externalPanelMove', {
                panelId: fromPanel.id, toPanelId: toPanel.id, containerId: inv.containerId, direction: 'panelToPanel',
                panelSlot: fromSlot, toPanelSlot: toSlot,
                item: src.item, amount: src.amount || 1, metadata: src.metadata || null,
            });
            return ok;
        }
        // panel -> pockets or container
        const pd = fromPanel.items[fromKey];
        if (!pd) return no();
        const extOp = extendOp(opId, toContainer === 'container' ? ['panels', 'container'] : ['panels', 'state']);
        const store = toContainer === 'container' ? inv.containerItems
            : (inv.state[toContainer] = inv.state[toContainer] || {});
        const there = store[toKey];
        store[toKey] = (there && there.item === pd.item)
            ? { item: there.item, amount: (there.amount || 1) + (pd.amount || 1), metadata: there.metadata }
            : { item: pd.item, amount: pd.amount || 1, metadata: pd.metadata || null };
        delete fromPanel.items[fromKey];
        emit(extOp, 'externalPanelMove', {
            panelId: fromPanel.id, containerId: inv.containerId, direction: 'fromPanel',
            panelSlot: fromSlot, invContainer: toContainer, invSlot: toSlot,
            item: pd.item, amount: pd.amount || 1, metadata: pd.metadata || null,
        });
        return ok;
    }

    // ---- an admin looking into someone's pockets ----
    if (inv.playerInvOpen && (fromContainer === 'targetPlayer' || toContainer === 'targetPlayer')) {
        const pOp = extendOp(opId, ['playerInv', 'state']);
        const isFrom = fromContainer === 'targetPlayer', isTo = toContainer === 'targetPlayer';
        const target = inv.playerInvItems.player;
        if (isFrom && isTo) moveBetweenStores(target, fromKey, target, toKey);
        else if (isFrom) {
            if (!inv.state[toContainer]) inv.state[toContainer] = {};
            moveBetweenStores(target, fromKey, inv.state[toContainer], toKey);
        } else {
            moveBetweenStores(inv.state[fromContainer], fromKey, target, toKey);
        }
        emit(pOp, 'playerInvMoveItem', { fromType: fromContainer, fromSlot, toType: toContainer, toSlot });
        return ok;
    }

    // ---- the stash, boot or glovebox: sent even for an empty slot (the server's answer decides) ----
    if (inv.containerOpen && (fromContainer === 'container' || toContainer === 'container')) {
        if (fromContainer === 'container' && toContainer === 'container') {
            moveBetweenStores(inv.containerItems, fromKey, inv.containerItems, toKey);
        } else if (fromContainer === 'container') {
            if (!inv.state[toContainer]) inv.state[toContainer] = {};
            moveBetweenStores(inv.containerItems, fromKey, inv.state[toContainer], toKey);
        } else {
            moveBetweenStores(inv.state[fromContainer], fromKey, inv.containerItems, toKey);
        }
        emitMove('containerMoveItem', { containerId: inv.containerId });
        return ok;
    }

    // ---- the ground ----
    if (fromContainer === 'ground' && toContainer === 'ground') return no();
    if (fromContainer === 'ground') {
        const g = inv.groundItems[fromKey];
        if (!(g && g.groundId)) return no();
        if (!inv.state[toContainer]) inv.state[toContainer] = {};
        const toData = inv.state[toContainer][toKey];
        if (toData && toData.item === g.item) toData.amount = (toData.amount || 0) + (g.amount || 0);
        else if (!toData) inv.state[toContainer][toKey] = { item: g.item, amount: g.amount, metadata: g.metadata };
        delete inv.groundItems[fromKey];
        reindexGround();
        emit(opId, 'pickupGroundItem', { groundId: g.groundId, toContainer, toSlot });
        return ok;
    }
    if (toContainer === 'ground') {
        const d = inv.state[fromContainer] && inv.state[fromContainer][fromKey];
        if (!d) return no();
        delete inv.state[fromContainer][fromKey];
        emit(opId, 'dropToGround', { fromContainer, fromSlot, amount: d.amount });
        return ok;
    }

    // ---- pockets to pockets ----
    if (!inv.state[toContainer]) inv.state[toContainer] = {};
    moveBetweenStores(inv.state[fromContainer], fromKey, inv.state[toContainer], toKey);
    if (inv.containerOpen) emitMove('containerMoveItem', { containerId: inv.containerId });
    else emitMove('moveItem');
    return ok;
}

// ------------------------------------------
// Move one (right-click while dragging)
// ------------------------------------------

/** Put one of the stack in `from` onto `to`, keeping the rest in hand. */
export function moveOne(from, to) {
    const fromContainer = from.container, toContainer = to.container;
    const fromSlot = Number(from.slot), toSlot = Number(to.slot);
    if (!fromContainer || !toContainer || !fromSlot || !toSlot) return no();
    if (fromContainer === toContainer && fromSlot === toSlot) return no();
    if (fromContainer === 'ground') return no();

    const fromKey = String(fromSlot), toKey = String(toSlot);
    const isFromTarget = fromContainer === 'targetPlayer', isToTarget = toContainer === 'targetPlayer';
    const fromData = fromContainer === 'container' ? inv.containerItems[fromKey]
        : isFromTarget ? inv.playerInvItems.player[fromKey]
        : (inv.state[fromContainer] && inv.state[fromContainer][fromKey]);

    const takeOne = (store, key, d) => { d.amount -= 1; if (d.amount <= 0) delete store[key]; };
    const putOne = (store, key, there, d) => {
        if (there) there.amount += 1;
        else store[key] = { item: d.item, amount: 1, metadata: d.metadata };
    };

    if (inv.playerInvOpen && (isFromTarget || isToTarget)) {
        const op = beginOp(['state', 'playerInv']);
        if (fromData && fromData.amount > 0) {
            const toStore = isToTarget ? inv.playerInvItems.player : (inv.state[toContainer] = inv.state[toContainer] || {});
            const there = toStore[toKey];
            if (!there || there.item === fromData.item) {
                const meta = { item: fromData.item, metadata: fromData.metadata };
                takeOne(isFromTarget ? inv.playerInvItems.player : inv.state[fromContainer], fromKey, fromData);
                putOne(toStore, toKey, there, meta);
            }
        }
        emit(op, 'playerInvDropOneItem', { fromType: fromContainer, fromSlot, toType: toContainer, toSlot });
        return ok;
    }

    const fp = panelByKey(fromContainer), tp = panelByKey(toContainer);
    if (fp || tp) {
        if (bagWithoutRoute(fromContainer, toContainer)) return no();
        if ((fp && fp.readOnly && fp !== tp) || (tp && tp.readOnly && fp !== tp)) return no();
        if (!fromData && !(fp && fp.items[fromKey])) return no();
        const op = beginOp(['state', 'container', 'panels']);
        let payload;
        if (fp && tp) {
            payload = fp === tp
                ? { direction: 'withinPanel', panelId: fp.id, panelSlot: fromSlot, toPanelSlot: toSlot }
                : { direction: 'panelToPanel', panelId: fp.id, toPanelId: tp.id, panelSlot: fromSlot, toPanelSlot: toSlot };
        } else if (tp) {
            payload = { direction: 'toPanel', panelId: tp.id, panelSlot: toSlot, invContainer: fromContainer, invSlot: fromSlot };
        } else {
            payload = { direction: 'fromPanel', panelId: fp.id, panelSlot: fromSlot, invContainer: toContainer, invSlot: toSlot };
        }
        payload.containerId = inv.containerId;
        payload.mode = 'one';
        payload.amount = 1;
        emit(op, 'externalPanelMove', payload);
        return ok;
    }

    if (fromContainer === 'ignition' || toContainer === 'ignition') return no('Drag the key to move it');

    if (inv.containerOpen && (fromContainer === 'container' || toContainer === 'container')) {
        const op = beginOp(['state', 'container']);
        if (fromData && fromData.amount > 0) {
            const toStore = toContainer === 'container' ? inv.containerItems : (inv.state[toContainer] = inv.state[toContainer] || {});
            const there = toStore[toKey];
            if (!there || there.item === fromData.item) {
                const meta = { item: fromData.item, metadata: fromData.metadata };
                takeOne(fromContainer === 'container' ? inv.containerItems : inv.state[fromContainer], fromKey, fromData);
                putOne(toStore, toKey, there, meta);
            }
        }
        emit(op, 'containerDropOneItem', { containerId: inv.containerId, fromContainer, fromSlot, toContainer, toSlot });
        return ok;
    }

    if (toContainer === 'ground') {
        const op = beginOp(['state', 'ground']);
        if (fromData && fromData.amount > 0) takeOne(inv.state[fromContainer], fromKey, fromData);
        emit(op, 'dropOneToGround', { fromContainer, fromSlot });
        return ok;
    }

    if (toContainer === 'accessory') {
        const cfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
        if (cfg && fromData && !slotTakesItem(cfg, fromData.item)) return no(onlyHere(cfg, ' can go here'));
    }
    const op = beginOp(['state']);
    const there = inv.state[toContainer] && inv.state[toContainer][toKey];
    if (fromData && fromData.amount > 0 && (!there || there.item === fromData.item)) {
        const meta = { item: fromData.item, metadata: fromData.metadata };
        takeOne(inv.state[fromContainer], fromKey, fromData);
        putOne(inv.state[toContainer] = inv.state[toContainer] || {}, toKey, there, meta);
    }
    emit(op, 'dropOneItem', { fromContainer, fromSlot, toContainer, toSlot });
    return ok;
}

// ------------------------------------------
// Shift-click, split, destroy
// ------------------------------------------

/** The stores on the right a shift-click from the pockets can go to, newest open first. */
function quickTargets() {
    const out = [];
    if (inv.containerOpen) out.push({ grid: gridOf('container'), at: inv.containerOpenedAt || 0 });
    for (const p of inv.panels) if (!p.readOnly) out.push({ grid: gridOf(p.key), at: p.openedAt || 0 });
    out.sort((a, b) => b.at - a.at);
    return out.map(t => t.grid).filter(Boolean);
}

/** Is Nearby the panel a pockets shift-click falls back to? (On foot, nothing else open there.) */
export function groundShowing() {
    return !inv.containerOpen && !inv.playerInvOpen && !shop.open;
}

/**
 * SHIFT + CLICK: a whole stack across. From the pockets to the newest store open that looks able to
 * take it, else onto the ground when Nearby shows; from a store, a panel or the ground into the pockets.
 */
export function quickMove(at) {
    if (shop.open || inv.playerInvOpen) return no();
    const container = at.container, slot = Number(at.slot);
    if (!container || !slot) return no();
    const key = String(slot);

    if (container === 'player') {
        const d = inv.state.player && inv.state.player[key];
        if (!d) return no();
        const targets = quickTargets();
        let target = null, there = null;
        for (const grid of targets) {
            if (!weightFits(grid, stackWeight(d))) continue;
            const s = predictSlotAccepting(grid, d.item, d.amount || 1, d.metadata);
            if (s !== null) { target = grid; there = s; break; }
        }
        if (!target && groundShowing()) {
            const op = beginOp(['state', 'ground']);
            delete inv.state.player[key];
            emit(op, 'dropToGround', { fromContainer: 'player', fromSlot: slot, amount: d.amount });
            return ok;
        }
        if (!target) target = targets[0] || null;
        if (!target) return no('There is nowhere to put that');
        const op = beginOp(['state', target.view]);
        if (there !== null) { delete inv.state.player[key]; placeInto(target, there, d); }
        emit(op, 'quickMove', {
            fromContainer: 'player', fromSlot: slot, toContainer: target.container,
            toPanelId: target.panel ? target.panel.id : undefined, containerId: inv.containerId,
        });
        return ok;
    }

    if (container === 'ground') {
        const g = inv.groundItems[key];
        if (!(g && g.groundId)) return no();
        const pockets = gridOf('player');
        const s = predictSlotAccepting(pockets, g.item, g.amount || 1, g.metadata);
        const op = beginOp(['state', 'ground']);
        if (s !== null) {
            placeInto(pockets, s, { item: g.item, amount: g.amount, metadata: g.metadata });
            delete inv.groundItems[key];
            reindexGround();
        }
        emit(op, 'pickupGroundItem', { groundId: g.groundId, toContainer: 'player', toSlot: s || 1 });
        return ok;
    }

    if (container === 'container' || panelByKey(container)) {
        const src = gridOf(container);
        const d = src && src.items[key];
        if (!d || (src.panel && src.panel.readOnly)) return no();
        const pockets = gridOf('player');
        const s = predictSlotAccepting(pockets, d.item, d.amount || 1, d.metadata);
        const op = beginOp(['state', src.view]);
        if (s !== null) { delete src.items[key]; placeInto(pockets, s, d); }
        emit(op, 'quickMove', {
            fromContainer: container, fromSlot: slot, fromPanelId: src.panel ? src.panel.id : undefined,
            toContainer: 'player', containerId: inv.containerId,
        });
        return ok;
    }
    return no();
}

/** Split `amount` off a stack into the first free slot of the same grid (on the ground, a new pile).
 *  At least one stays behind. */
export function split(at, amount) {
    const container = at.container, slot = Number(at.slot), key = String(slot);
    if (container === 'ground') {
        const g = inv.groundItems[key];
        if (!g || !g.groundId || (g.amount || 1) <= 1) return no();
        const n = Math.max(1, Math.min(Math.floor(amount) || 1, g.amount - 1));
        const op = beginOp(['ground']);
        g.amount -= n;
        inv.groundItems[String(Object.keys(inv.groundItems).length + 1)] = { item: g.item, amount: n, metadata: g.metadata };
        emit(op, 'splitGroundItem', { groundId: g.groundId, splitAmount: n });
        return ok;
    }
    const grid = gridOf(container);
    const d = grid && grid.items[key];
    if (!d || (d.amount || 1) <= 1) return no();
    const n = Math.max(1, Math.min(Math.floor(amount) || 1, d.amount - 1));
    const op = beginOp([grid.view]);
    const free = predictFreeSlot(grid, d.item);
    if (free !== null) {
        d.amount -= n;
        grid.items[String(free)] = { item: d.item, amount: n, metadata: d.metadata ? structuredClone(d.metadata) : d.metadata };
    }
    emit(op, 'splitItem', Object.assign(slotRef(container, slot), { splitAmount: n }));
    return ok;
}

/** Destroy a stack, from any grid with a menu. Developer mode only (the server refuses anyone else). */
export function destroy(at) {
    if (!inv.devMode) return no('Developer mode only');
    const container = at.container, slot = Number(at.slot), key = String(slot);
    if (container === 'ground') {
        const g = inv.groundItems[key];
        if (!g || !g.groundId) return no();
        const op = beginOp(['ground']);
        delete inv.groundItems[key];
        reindexGround();
        emit(op, 'destroyGroundItem', { groundId: g.groundId });
        return ok;
    }
    const grid = gridOf(container);
    if (!grid || !grid.items[key]) return no();
    const op = beginOp([grid.view]);
    delete grid.items[key];
    emit(op, 'destroyItem', slotRef(container, slot));
    return ok;
}

// ------------------------------------------
// Use, give, place: an item on your person
// ------------------------------------------

/** Use the item (its server handler runs; the server answers with the usual push). Pockets only. */
export function use(at) {
    if (!isPocketGrid(at.container) || !slotAt(at.container, at.slot)) return no();
    nuiCallback('useItem', { container: at.container, slot: Number(at.slot) });
    return ok;
}

function onPerson(at) {
    if (!isPocketGrid(at.container)) return null;
    return (inv.state[at.container] && inv.state[at.container][String(at.slot)]) || null;
}

/** Give some or all of a stack: whip asks who to (client Lua), and the server moves it. Pockets only. */
export function give(at, amount) {
    const d = onPerson(at);
    if (!d) return no();
    const n = Math.max(1, Math.min(Math.floor(amount) || d.amount || 1, d.amount || 1));
    nuiCallback('giveItem', { container: at.container, slot: Number(at.slot), itemKey: d.item,
        itemName: nameOf(d.item), itemAmount: n });
    return ok;
}

/** Put the whole stack down in the world (whip closes the inventory and starts placing). Pockets only. */
export function place(at) {
    const d = onPerson(at);
    if (!d) return no();
    nuiCallback('placeItem', { container: at.container, slot: Number(at.slot), itemKey: d.item,
        itemName: nameOf(d.item), itemAmount: d.amount || 1 });
    return ok;
}

// ------------------------------------------
// The right-click menu
// ------------------------------------------

function orderedOptions(list) {
    const rank = (o) => (typeof o.order === 'number' && Number.isFinite(o.order) ? o.order : Infinity);
    return list
        .map((opt, i) => ({ opt, i }))
        .filter(({ opt }) => opt && typeof opt.action === 'string' && opt.action !== '')
        .sort((a, b) => { const ra = rank(a.opt), rb = rank(b.opt); return ra !== rb ? (ra < rb ? -1 : 1) : a.i - b.i; })
        .map(({ opt }) => opt);
}

function optionShown(itemKey, opt, slotData) {
    if (opt.when && !whenMet(opt.when, slotData && slotData.metadata)) return false;
    if (opt.require && inv.optionGates[itemKey + '|' + opt.action] !== true) return false;
    return true;
}

const stockPriceOf = (slot) => {
    const d = inv.containerItems[String(slot)];
    return (d && d.item && inv.stockPrices[d.item]) || null;
};

/**
 * What a slot's menu offers, as whip's own shows it: { title, options: [{ action, label, group, amount? }] }
 * or null when there is nothing to offer. `group` is 'own' (Use, the item's own verbs, a shop
 * employee's pricing), 'shared' (Give, Place, Split) or 'danger' (Destroy). In the pockets an item
 * offers everything; anywhere else, its `anywhere` options, Split and Destroy. Give and Split take an
 * amount (runOption's `amount`); `amount` on them is the stack's size.
 */
export function menuFor(at) {
    const container = at.container, slot = Number(at.slot);
    // No menu on the shop, the ignition, the admin view or a read-only panel: nothing there to act on.
    if (container === 'shop' || container === 'ignition' || container === 'targetPlayer') return null;
    const ro = panelByKey(container);
    if (ro && ro.readOnly) return null;
    const d = slotAt(container, slot);
    if (!d) return null;
    const def = defOf(d.item);
    const amount = d.amount || 1;
    const pockets = isPocketGrid(container);
    const out = [];

    if (pockets && def && def.usable) out.push({ action: 'use', label: 'Use', group: 'own' });
    const elsewhere = !pockets && !!gridOf(container);
    if ((pockets || elsewhere) && def && Array.isArray(def.contextOptions)) {
        for (const opt of orderedOptions(def.contextOptions)) {
            if ((pockets || opt.anywhere === true) && optionShown(d.item, opt, d)) {
                out.push({ action: opt.action, label: decodeTextEntities(opt.label) || '', group: 'own' });
            }
        }
    }
    if (inv.stockMode && container === 'container') {
        const p = stockPriceOf(slot) || { price: 0, forSale: false };
        out.push({ action: 'stock_set_price', label: 'Set Price ($' + (p.price || 0).toLocaleString('en-US') + ' each)', group: 'own' });
        out.push({ action: 'stock_toggle_sale', label: p.forSale ? 'Remove From Sale' : 'Mark For Sale', group: 'own' });
    }
    if (pockets) {
        out.push({ action: 'give', label: 'Give', group: 'shared', amount });
        out.push({ action: 'place', label: 'Place', group: 'shared' });
    }
    if (amount > 1) out.push({ action: 'split', label: 'Split', group: 'shared', amount });
    if (inv.devMode) out.push({ action: 'destroy', label: 'Destroy', group: 'danger' });

    if (!out.length) return null;
    return { title: (def ? def.name : d.item) + (amount > 1 ? ' ×' + amount : ''), options: out };
}

/** Run one of menuFor's options. `opts.amount` for Give and Split (Split defaults to half). */
export function runOption(at, action, opts) {
    const container = at.container, slot = Number(at.slot);
    const amount = opts && opts.amount;
    switch (action) {
        case 'use':     return use(at);
        case 'give':    return give(at, amount);
        case 'place':   return place(at);
        case 'destroy': return destroy(at);
        case 'split': {
            const d = slotAt(container, slot);
            if (!d) return no();
            return split(at, amount !== undefined ? amount : Math.ceil((d.amount || 1) / 2));
        }
        case 'stock_set_price': {
            const d = inv.containerItems[String(slot)];
            nuiCallback('shopPriceInput', { shopId: inv.stockShopId, slot, item: d && d.item ? d.item : '',
                currentPrice: (stockPriceOf(slot) || {}).price || 0 });
            return ok;
        }
        case 'stock_toggle_sale': {
            const here = inv.containerItems[String(slot)];
            if (!here || !here.item) return no();
            const was = stockPriceOf(slot);
            const forSale = !(was && was.forSale);
            if (was) inv.stockPrices[here.item] = { price: was.price || 0, forSale };
            nuiCallback('shopSetPrice', { shopId: inv.stockShopId, slot, item: here.item, forSale, keepPrice: true });
            return ok;
        }
        default:
            if (isPocketGrid(container)) nuiCallback('customContextAction', { action, container, slot });
            else nuiCallback('storeContextAction', Object.assign({ action }, slotRef(container, slot)));
            return ok;
    }
}

// ------------------------------------------
// Describing an item
// ------------------------------------------

const fmtKg = (n) => {
    const v = Math.round((n || 0) * 100) / 100;
    return String(v);
};

/**
 * What whip's own tooltip says about a slot: { name, desc, weight, weightEach, stack, lines } —
 * `weight` the whole stack in kg (contents included), `weightEach` per unit when there are several,
 * `stack` "12 of 50" for a stackable item (null otherwise), `lines` the item's metaFields as
 * [{ label, value }] (labels decoded; values exactly as stored). Null for an empty slot.
 */
export function describe(at) {
    const d = slotAt(at.container, at.slot);
    if (!d) return null;
    const def = defOf(d.item) || { name: d.item, weight: 0 };
    const amount = d.amount || 1;
    const total = typeof d.w === 'number' ? d.w : (def.weight || 0) * amount;
    const stacks = at.container !== 'shop' && !!def.stack && (def.maxStack || 1) > 1 && def.type !== 'currency';
    const meta = d.metadata || null;
    const lines = [];
    if (Array.isArray(def.metaFields)) {
        for (const field of def.metaFields) {
            let value = meta ? meta[field.key] : undefined;
            if (value === undefined || value === null) value = field.value;
            if (value === undefined || value === null || value === '') continue;
            if (field.format === 'uppercase') value = String(value).toUpperCase();
            else if (field.format === 'percent') value = parseFloat(value).toFixed(1) + '%';
            else if (field.format === 'phone') {
                value = String(value).replace(/[^0-9]/g, '');
                if (value.length === 10) value = value.substr(0, 3) + '-' + value.substr(3, 3) + '-' + value.substr(6, 4);
            } else value = String(value);
            lines.push({ label: decodeTextEntities(field.label), value });
        }
    }
    return {
        item: d.item,
        name: def.name || d.item,
        desc: def.desc || '',
        amount,
        weight: Number(fmtKg(total)),
        weightEach: amount > 1 ? Number(fmtKg(total / amount)) : null,
        stack: stacks ? amount.toLocaleString('en-US') + ' of ' + Number(def.maxStack).toLocaleString('en-US') : null,
        lines,
    };
}
