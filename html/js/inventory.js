// Inventory, default renderer: the DOM half only. State lives in core/inv-state.js, the optimistic engine in
// core/inv-ops.js, and every NUI message lands in core/inv-wire.js, which drives this file through the renderer
// interface registered at the bottom (a custom renderer implements the same interface: docs/nui-inventory.md).
// Owns the inv-* element ids (private), the slot factory, drag and drop, tooltips, context menus and the give/split UI.

import { NuiRouter } from './router.js';
import { nuiCallback, setItemImage, decodeTextEntities } from './utils.js';
import { invItemDefs } from './core/item-defs.js';
import { whenMet } from './core/item-rules.js';
import {
    inv, shop, invShopHooks, invHotbarHooks,
    slotConfig, isIgnitionKeyItem, panelByKey,
} from './core/inv-state.js';
import { beginOp, extendOp, emit, commitOp, settleUnsentOp } from './core/inv-ops.js';
import { registerRenderer, getRenderer, defaultSeated, setViewRenderHook } from './core/inventory.js';
import { closeInventory } from './core/inv-wire.js';
import { padGlyph } from './pad-glyphs.js';
import { pref } from './prefs.js';
import { weightText, weightLine } from './weight.js';

// The accessory strip draws from slotConfig.accessorySlots (core/inv-state.js) — the
// server-registered table, NOT a hardcoded list. A satellite calling
// exports.whip_core:RegisterAccessorySlot grows the strip on every client live.

// Built-in placeholder icons, chosen by a def's `icon` name (accessoryPlaceholder below). A registered def may
// instead ship its own `iconSvg` — that is DEVELOPER-AUTHORED markup from a resource that already runs code on this
// client, so rendering it via innerHTML raises nothing the resource could not already do.
const ACCESSORY_ICONS = {
    // A belt pouch: a slot that takes anything (whip's own, shared/inventory_shape.lua).
    accessory: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 8V6.5a3 3 0 0 1 6 0V8"/><rect x="5" y="8" width="14" height="12" rx="2.5"/><path d="M5 12.5h4.5M14.5 12.5H19"/><rect x="9.5" y="11" width="5" height="3.5" rx="1"/></svg>',
    phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2" width="10" height="20" rx="2"/><line x1="12" y1="18" x2="12" y2="18.01"/></svg>',
    vehicle_key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="4"/><line x1="11.3" y1="11.7" x2="20" y2="3"/><line x1="17" y1="3" x2="20" y2="6"/><line x1="15" y1="8" x2="17.5" y2="5.5"/></svg>',
    cash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="3"/><line x1="6" y1="12" x2="6" y2="12.01"/><line x1="18" y1="12" x2="18" y2="12.01"/></svg>',
    // A PLUS — "something goes here".
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><line x1="12" y1="7" x2="12" y2="17"/><line x1="7" y1="12" x2="17" y2="12"/></svg>',
};




// ------------------------------------------
// LIVE SECONDARY-PANEL SWAP (ground <-> glovebox, inventory stays open)
// ------------------------------------------

/**
 * Flash a panel: fully lit on the first frame, settling back to its resting border and shadow.
 *
 * The class is REMOVED again on a timer. Leaving it on would carry into the next ordinary F2 and
 * suppress the normal staggered entrance. setTimeout rather than an animationend listener because
 * there is not a single animationend listener anywhere in this UI today, and adding the first one
 * for this would be a new idiom for no gain.
 */
function flashPanel(el) {
    if (!el) return;
    el.classList.add('inv-panel-swapped');
    setTimeout(() => el.classList.remove('inv-panel-swapped'), 450);
}

export { weightLine };

/**
 * A slot's stack count: thousands separated, and money as money —
 * "$7,920" rather than "7920". The carried grid puts a dim "×" before a count (inventory.css), which
 * money must not get, so it is marked here.
 * @param {{item: string, amount: number}} slotData
 */
function slotAmountEl(slotData) {
    const def = invItemDefs[slotData.item];
    const money = !!def && def.type === 'currency';
    const el = document.createElement('span');
    el.className = money ? 'inv-slot-amount money' : 'inv-slot-amount';
    el.textContent = (money ? '$' : '') + (Number(slotData.amount) || 0).toLocaleString('en-US');
    return el;
}

/**
 * The item's name, for its slot to show: the carried grid always; the
 * small slots only when the item has no picture (inventory.css, .no-art).
 * @param {{item: string}} slotData
 */
function slotNameEl(slotData) {
    const def = invItemDefs[slotData.item];
    const el = document.createElement('span');
    el.className = 'inv-slot-name';
    el.textContent = (def && def.name) || slotData.item;
    return el;
}

// PICTURES, ONCE LOADED. A slot whose picture fell all the way back to
// missing.png says so (.no-art: a glyph and the item's name instead of a "?" picture), and a wide or
// tall picture gets the box its shape needs (.art-wide / .art-tall on the .inv-item). Capture phase,
// because load does not bubble; utils.js's error fallback is what sets missing.png, so this sees it.
document.addEventListener('load', (e) => {
    const img = e.target;
    if (!img || img.tagName !== 'IMG' || !img.classList.contains('inv-item-img')) return;
    const slot = img.closest('.inv-slot');
    if (/(^|\/)missing\.png$/.test(img.getAttribute('src') || '')) {
        if (slot) slot.classList.add('no-art');
        return;
    }
    if (slot) slot.classList.remove('no-art');
    const item = img.parentElement;
    const r = img.naturalHeight ? img.naturalWidth / img.naturalHeight : 1;
    if (item && item.classList.contains('inv-item')) {
        item.classList.toggle('art-wide', r >= 1.6);
        item.classList.toggle('art-tall', r <= 0.62);
    }
}, true);






/**
 * End the drag if the stack it came from is now empty.
 *
 * Right-clicking sprinkles one unit at a time out of a held stack. When the last one lands the
 * source slot is gone, but the cursor was still carrying a ghost of an item that no longer
 * exists — every further click was refused by the server, correctly, but the player had no way
 * to tell from looking. Better to put the drag down at the moment it runs out.
 *
 * Tears down by hand rather than calling cancelDrag(), which ends with a full renderInventory()
 * — the exact rebuild the fix above exists to avoid.
 */
function endDragIfSourceExhausted() {
    if (!dragItem || !dragSourceSlot) return;

    const container = dragSourceSlot.dataset.container;
    const key       = String(dragSourceSlot.dataset.slot);

    let data = null;
    const srcPanel = panelByKey(container);
    if (srcPanel) {
        data = srcPanel.items[key];
    } else if (container === 'container') {
        data = inv.containerItems[key];
    } else if (container === 'ground') {
        data = inv.groundItems[key];
    } else if (container === 'targetPlayer') {
        data = inv.playerInvItems.player && inv.playerInvItems.player[key];
    } else {
        data = inv.state[container] && inv.state[container][key];
    }

    if (data && data.amount > 0) return;   // still holding something

    if (dragGhost) { dragGhost.remove(); dragGhost = null; }
    document.querySelectorAll('#inv-overlay .inv-slot')
        .forEach(s => s.classList.remove('drag-over', 'drag-refuse'));
    dragHoverSlot = null;
    document.removeEventListener('mousemove', onDragMove);
    document.removeEventListener('mouseup', onDragEnd);

    // ORDER MATTERS, AND THE REFRESH MUST BE IN THIS SAME BLOCK.
    //
    // refreshSlotVisuals deliberately SKIPS dragSourceSlot, so while a drag is live the source
    // slot keeps showing its stale item at the dragging fade. Clearing `dragging` on its own
    // therefore snapped that leftover item back to full brightness, it painted, and only the
    // next update removed it — the flash on placing the last unit of a stack.
    //
    // Null the source first so the refresh is allowed to touch that slot, then refresh here,
    // synchronously. The browser cannot paint between these lines, so the item goes straight
    // from faded to gone with nothing in between.
    dragItem.classList.remove('dragging');
    dragItem = null;
    dragSourceSlot = null;
    refreshSlotVisuals();
}



/**
 * What SHOULD be in this slot, whichever grid it belongs to.
 *
 * ONE RESOLVER, USED BY BOTH THE SLOT FACTORY AND THE REFRESH PASS. A grid this does not know
 * reads `undefined` — an empty slot — so every refresh would silently wipe it. Adding a grid means
 * adding it HERE, once.
 *
 * `shop` resolves here for the factory's sake; the refresh pass skips its tiles (shops.js owns that
 * DOM). The basket is a list of lines, not slots.
 */
function slotDataFor(container, slotNum) {
    const key = String(slotNum);
    switch (container) {
        case 'ground':       return inv.groundItems[key] || null;
        case 'container':    return inv.containerItems[key] || null;
        case 'ignition':     return inv.ignitionSlot || null;
        case 'shop':         return shop.items[key] || null;   // the shelf, by its place on it
        case 'targetPlayer': return inv.playerInvItems.player[key] || null;
        // A PANEL, OR A PLAYER-SIDE CONTAINER. There is no `case 'external'` any more: a panel
        // slot's container is its panel KEY ('panel:wallet_3'), which cannot be a switch case
        // because there is one per open panel. panelByKey returns null for every non-panel
        // name, so it doubles as the test.
        default: {
            const panel = panelByKey(container);
            if (panel) return panel.items[key] || null;
            // player, accessory, and anything else PlayerContainers (shared/inventory_shape.lua) adds.
            return (inv.state[container] && inv.state[container][key]) || null;
        }
    }
}

/** A stock slot's price: the price of the ITEM on it now (inv.stockPrices is keyed by item, as prices
 *  are, so a restocked or moved item keeps its price). */
function stockPriceOf(slotNum) {
    const d = inv.containerItems[String(slotNum)];
    return (d && d.item && inv.stockPrices[d.item]) || null;
}

/** The stock view's badge on a shelf slot: its price when for sale, else NOT LISTED. Replaces any it had. */
function drawStockBadge(slotEl, slotNum) {
    slotEl.querySelectorAll('.inv-slot-price, .inv-slot-stock-badge').forEach((el) => el.remove());
    slotEl.classList.remove('stock-for-sale');
    if (!inv.containerItems[String(slotNum)]) return;
    const priceInfo = stockPriceOf(slotNum);
    if (priceInfo && priceInfo.forSale) {
        const priceEl = document.createElement('div');
        priceEl.className = 'inv-slot-price';
        priceEl.textContent = '$' + (priceInfo.price || 0).toLocaleString();
        slotEl.appendChild(priceEl);
        slotEl.classList.add('stock-for-sale');
    } else {
        const badge = document.createElement('div');
        badge.className = 'inv-slot-stock-badge';
        badge.textContent = 'NOT LISTED';
        slotEl.appendChild(badge);
    }
}

function refreshSlotVisuals() {
    const allSlots = document.querySelectorAll('#inv-overlay .inv-slot');
    allSlots.forEach(slotEl => {
        // Don't touch the slot we're dragging from
        if (slotEl === dragSourceSlot) return;

        const container = slotEl.dataset.container;
        const slotNum   = slotEl.dataset.slot;
        if (!container || !slotNum) return;

        // The shelf's tiles are managed by shops.js — don't touch them here
        if (container === 'shop') return;

        const slotData = slotDataFor(container, slotNum);

        // Signature of what this slot should SHOW. Everything below only draws the item image,
        // the amount badge and the has-item class, so item+amount is the whole visual state —
        // metadata is read fresh at tooltip time and is not part of it. A slot whose signature
        // matches what it already renders is left alone (this runs after every optimistic move).
        // The stamp is only written when the rebuild actually happens, so a slot skipped as
        // dragSourceSlot never claims to render something it doesn't.
        const sig = slotData ? (slotData.item + '|' + slotData.amount) : '';
        if (slotEl.dataset.rendered === sig) return;
        slotEl.dataset.rendered = sig;

        // Remove existing item content, name and amount badge (keep slot-number labels and accessory placeholders)
        const oldItem   = slotEl.querySelector('.inv-item');
        const oldAmount = slotEl.querySelector('.inv-slot-amount');
        const oldName   = slotEl.querySelector('.inv-slot-name');
        if (oldItem) oldItem.remove();
        if (oldAmount) oldAmount.remove();
        if (oldName) oldName.remove();
        slotEl.classList.remove('no-art');   // the new picture's load says again, if it has none

        // Toggle accessory placeholder visibility
        const placeholder = slotEl.querySelector('.inv-accessory-placeholder');

        if (slotData) {
            if (placeholder) placeholder.style.display = 'none';

            const itemEl = document.createElement('div');
            itemEl.className = 'inv-item';
            itemEl.dataset.item = slotData.item;
            itemEl.dataset.container = container;
            itemEl.dataset.slot = slotNum;

            const img = document.createElement('img');
            img.className = 'inv-item-img';
            img.alt = '';
            setItemImage(img, slotData);
            itemEl.appendChild(img);
            slotEl.appendChild(itemEl);
            slotEl.appendChild(slotNameEl(slotData));

            if (slotData.amount > 1) slotEl.appendChild(slotAmountEl(slotData));

            slotEl.classList.add('has-item');
        } else {
            if (placeholder) placeholder.style.display = '';
            slotEl.classList.remove('has-item');
        }
        // The stock view's badge follows the item that is on the slot now.
        if (container === 'container' && inv.stockMode) drawStockBadge(slotEl, slotNum);
    });
}


// ------------------------------------------
// RENDER — Builds all slots from data
// ------------------------------------------
function renderInventory() {
    renderPlayerGrid();
    renderAccessoryGrid();
    if (inv.containerOpen) {
        renderContainerGrid();
        renderContainerInfo();
    } else {
        renderGroundGrid();
    }
    if (inv.ignitionOpen) renderIgnitionSlot();
    // Unconditional: renderPanelStack with an empty array is the teardown, so this also clears
    // any panel elements left behind by a close that happened between renders.
    renderPanelStack();
    if (inv.playerInvOpen) {
        renderPlayerInvGrids();
        renderPlayerInvInfo();
    }
    renderPersonalInfo();
    renderWeights();
    tagItemSlots();
    if (invHotbarHooks) invHotbarHooks.syncHotbar();
}

function renderPlayerGrid() {
    const grid = document.getElementById('inv-player-grid');
    if (!grid) return;
    const maxSlots = inv.maxSlots.player || 15;
    grid.innerHTML = '';

    for (let i = 1; i <= maxSlots; i++) {
        const slot = createSlotElement(i, 'player');
        grid.appendChild(slot);
    }
}

/**
 * An empty strip slot's picture, by what the slot does: its own SVG, else the built-in icon its `icon` names, else
 * what it takes (a built-in icon for that item, or the item's own picture, greyed), and for a slot that takes
 * anything the pouch.
 */
function accessoryPlaceholder(cfg) {
    const el = document.createElement('div');
    el.className = 'inv-accessory-placeholder';
    const svg = cfg.iconSvg || ACCESSORY_ICONS[cfg.icon] || ACCESSORY_ICONS[cfg.accepts];
    if (svg) {
        el.innerHTML = svg;
    } else if (cfg.accepts) {
        const img = document.createElement('img');
        img.alt = '';
        setItemImage(img, { item: cfg.accepts });
        el.classList.add('is-picture');
        el.appendChild(img);
    } else {
        el.innerHTML = ACCESSORY_ICONS.accessory;
    }
    return el;
}

function renderAccessoryGrid(forceRebuild) {
    const grid = document.getElementById('inv-accessory-grid');
    if (!grid) return;

    // No slots is no strip (Config.AccessoryStrip off): the column goes, and the grid beside it takes the room.
    const panel = document.getElementById('inv-accessory-panel');
    if (panel) panel.classList.toggle('is-off', slotConfig.accessorySlots.length === 0);

    // DOM already built — update contents in-place without recreating (preserves animations).
    // forceRebuild is the SLOT-DEFS path (a satellite registered/unregistered a slot): the
    // in-place branch only refreshes item contents, so a changed placeholder icon or accepts
    // rule would never repaint — the count matching (5 === 5) hid exactly that. Item-driven
    // calls keep the fast path; registry changes rebuild.
    if (!forceRebuild && grid.children.length === slotConfig.accessorySlots.length) {
        for (let i = 0; i < slotConfig.accessorySlots.length; i++) {
            const cfg = slotConfig.accessorySlots[i];
            const slotEl = grid.children[i];
            const slotData = inv.state.accessory && inv.state.accessory[String(cfg.slot)];

            // Same signature skip as refreshSlotVisuals, and not only for the churn: both
            // functions write these slots, so both must maintain the SAME stamp or one's
            // rebuild would leave the other skipping against a stale one.
            const sig = slotData ? (slotData.item + '|' + slotData.amount) : '';
            if (slotEl.dataset.rendered === sig) continue;
            slotEl.dataset.rendered = sig;

            // Remove old item, name + amount
            const oldItem = slotEl.querySelector('.inv-item');
            const oldAmount = slotEl.querySelector('.inv-slot-amount');
            const oldName = slotEl.querySelector('.inv-slot-name');
            if (oldItem) oldItem.remove();
            if (oldAmount) oldAmount.remove();
            if (oldName) oldName.remove();
            slotEl.classList.remove('no-art');

            const placeholder = slotEl.querySelector('.inv-accessory-placeholder');

            if (slotData) {
                if (placeholder) placeholder.style.display = 'none';

                const itemEl = document.createElement('div');
                itemEl.className = 'inv-item';
                itemEl.dataset.item = slotData.item;
                itemEl.dataset.container = 'accessory';
                itemEl.dataset.slot = cfg.slot;

                const img = document.createElement('img');
                img.className = 'inv-item-img';
                img.alt = '';
                setItemImage(img, slotData);
                itemEl.appendChild(img);
                slotEl.appendChild(itemEl);
                slotEl.appendChild(slotNameEl(slotData));

                if (slotData.amount > 1) slotEl.appendChild(slotAmountEl(slotData));

                slotEl.classList.add('has-item');
            } else {
                if (placeholder) placeholder.style.display = '';
                slotEl.classList.remove('has-item');
            }
        }
        return;
    }

    grid.innerHTML = '';

    for (let i = 0; i < slotConfig.accessorySlots.length; i++) {
        const cfg = slotConfig.accessorySlots[i];
        const slotNum = cfg.slot;

        const slot = document.createElement('div');
        slot.className = 'inv-accessory-slot inv-slot';
        slot.dataset.container = 'accessory';
        slot.dataset.slot = slotNum;
        // Store accepted item type for drag validation
        if (cfg.accepts) slot.dataset.accepts = cfg.accepts;

        // Always add the placeholder (hidden via CSS when has-item)
        const placeholder = accessoryPlaceholder(cfg);
        slot.appendChild(placeholder);

        const slotData = inv.state.accessory && inv.state.accessory[String(slotNum)];

        if (slotData) {
            placeholder.style.display = 'none';

            const itemEl = document.createElement('div');
            itemEl.className = 'inv-item';
            itemEl.dataset.item = slotData.item;
            itemEl.dataset.container = 'accessory';
            itemEl.dataset.slot = slotNum;

            const img = document.createElement('img');
            img.className = 'inv-item-img';
            img.alt = '';
            setItemImage(img, slotData);
            itemEl.appendChild(img);
            slot.appendChild(itemEl);
            slot.appendChild(slotNameEl(slotData));

            if (slotData.amount > 1) slot.appendChild(slotAmountEl(slotData));

            slot.classList.add('has-item');
        }

        grid.appendChild(slot);
    }
}

/**
 * How many columns this grid actually has — ASKED, NOT RESTATED.
 *
 * The row-padding below needs a column count; the number lives in .inv-col-right .inv-slots-grid,
 * so this reads the stylesheet's answer instead of repeating it.
 *
 * TWO SHAPES COME BACK and both are handled. A laid-out grid computes to used track sizes
 * ("112px 112px 112px 112px") — count them. One that is display:none or not yet in the layout
 * computes to the specified list ("repeat(4, minmax(0, 1fr))") — read the repeat count. The
 * fallback only fires if neither matches, and being wrong costs a ragged trailing row, nothing
 * more.
 * @param {HTMLElement} gridEl
 * @returns {number}
 */
function sideGridColumns(gridEl) {
    const tracks = gridEl && getComputedStyle(gridEl).gridTemplateColumns;
    if (!tracks || tracks === 'none') return 4;

    const repeated = /^repeat\(\s*(\d+)/.exec(tracks);
    if (repeated) return parseInt(repeated[1], 10) || 4;

    const n = tracks.trim().split(/\s+/).length;
    return n > 0 ? n : 4;
}

function renderGroundGrid() {
    const grid = document.getElementById('inv-ground-grid');
    if (!grid) return;
    grid.innerHTML = '';

    const occupiedCount = Object.keys(inv.groundItems).length;

    // THE GROUND IS NOT SLOT-ADDRESSED, so the empty cells are a landing area, not choosable
    // destinations. events_inventory says it plainly: "dropToGround / dropOneToGround — ground
    // is not slot-addressed; dropping conjures a row". A ground item is a world row with
    // coordinates and no slot number, so whichever cell you aim at, the server creates a row
    // and the list re-renders from the top.
    //
    // Rendering 30 targets advertised a choice that cannot exist. One spare row of five is
    // enough to show you where to drop without implying you can pick the spot.
    const cols = sideGridColumns(grid);
    const totalSlots = Math.max(Math.ceil((occupiedCount + cols) / cols) * cols, cols * 2);

    // NO INLINE grid-template-columns. It was `repeat(5, 106px)` — a fixed 570px including
    // gaps inside a ~545px box, which overflowed and clipped the fifth column against the
    // scroll container's edge. Being inline it also beat the stylesheet, so the CSS fix for
    // that had no effect. The rule in inventory.css uses minmax(0, 1fr) and fits by definition.

    for (let i = 1; i <= totalSlots; i++) {
        const slot = createSlotElement(i, 'ground');
        grid.appendChild(slot);
    }

    // Update ground info text
    const info = document.getElementById('inv-ground-info');
    if (info) info.textContent = occupiedCount + ' item' + (occupiedCount !== 1 ? 's' : '') + ' nearby';
}

function renderContainerGrid() {
    const grid = document.getElementById('inv-container-grid');
    if (!grid) return;
    grid.innerHTML = '';

    const slots = inv.containerDef ? inv.containerDef.slots : 20;
    // NO INLINE grid-template-columns: inline beats the stylesheet. Sizing is CSS's job and ONLY
    // CSS's: .inv-col-right .inv-slots-grid governs every grid in this column, including any panel
    // a satellite opens.
    for (let i = 1; i <= slots; i++) {
        const slot = createSlotElement(i, 'container');
        grid.appendChild(slot);
    }
}

function renderContainerInfo() {
    const nameEl = document.getElementById('inv-container-name');
    const subEl = document.getElementById('inv-container-subname');
    const infoEl = document.getElementById('inv-container-info');
    if (nameEl && inv.containerDef) {
        const fullName = inv.containerDef.name || 'Stash';
        const parts = fullName.split(' \u2014 ');
        nameEl.textContent = parts[0];
        if (subEl) subEl.textContent = parts.length > 1 ? parts[1] : '';
    }
    if (infoEl && inv.containerDef) {
        infoEl.textContent = weightLine(inv.containerWeight || 0, inv.containerDef.maxWeight || 100);
    }
}

function renderIgnitionSlot() {
    const grid = document.getElementById('inv-ignition-grid');
    if (!grid) return;
    grid.innerHTML = '';
    // NO INLINE SIZING, and no fit-content panel either: one track is used of the four the CSS
    // declares, at exactly the size every other slot in this column is, and the panel is as wide
    // as the ones above and below it.
    const slot = createSlotElement(1, 'ignition');
    grid.appendChild(slot);
}


// ------------------------------------------
// EXTERNAL PANEL — Generic N-slot panel
// ------------------------------------------



/**
 * Draw every open panel, one element each, into #inv-panel-stack.
 *
 * RECONCILES BY KEY — IT DOES NOT REBUILD. A `stack.innerHTML = ''` here would be correct
 * exactly once and wrong every other time: this runs on remote deltas (applyStoreDelta) and on
 * weight updates, both of which can land mid-drag, and detaching the tree takes dragSourceSlot
 * with it — the drag then reads datasets off an orphaned node. It is the same rule
 * refreshSlotVisuals follows for the same reason.
 *
 * So: panels that are gone are removed, panels that are new are cloned, and panels that were
 * already on screen keep their elements and have their contents updated in place.
 *
 * PANEL WIDTH IS UNIFORM: panels of different widths under one another read as broken layout, and
 * a 3-slot wallet's ragged short row is just what a grid does. Column count comes from CSS
 * (.inv-col-right .inv-slots-grid) like every other grid.
 */
function renderPanelStack() {
    const stack = document.getElementById('inv-panel-stack');
    const tpl   = document.getElementById('inv-panel-template');
    if (!stack || !tpl) return;

    const wanted = new Set(inv.panels.map(p => p.key));

    // Remove closed panels. Only elements this function created are considered — the static
    // panels (Nearby, container, ignition, shop) share the stack and must not be touched.
    for (const el of Array.from(stack.querySelectorAll('[data-panel-key]'))) {
        if (!wanted.has(el.dataset.panelKey)) el.remove();
    }

    // The panel this render OPENED, if any — brought into view below.
    let opened = null;

    for (const panel of inv.panels) {
        let el = stack.querySelector('[data-panel-key="' + panel.key + '"]');
        if (!el) {
            el = tpl.content.firstElementChild.cloneNode(true);
            el.dataset.panelKey = panel.key;
            stack.appendChild(el);
            opened = el;
        }

        const label = el.querySelector('.inv-external-label');
        if (label) label.textContent = panel.label || 'Panel';

        const weightEl = el.querySelector('.inv-external-weight-info');
        if (weightEl) {
            // Hidden when the panel has no weight limit — a wallet needs no blank line under
            // its slots. (See the note this replaces on setExternalWeight: a placeholder line
            // once lived here chasing a "panels don't line up" report, and the real culprit
            // was a margin, not a missing line.)
            if (panel.maxWeight) {
                weightEl.style.display = '';
                weightEl.textContent = weightLine(panel.currentWeight || 0, panel.maxWeight);
            } else {
                weightEl.style.display = 'none';
                weightEl.textContent = '';
            }
        }

        // The existing class, not a new one — it was toggled on this same element by the
        // setExternalReadOnly seat method this replaced. What it SHOWS is the header's
        // "Read only" badge (.inv-readonly-badge, pure CSS off this class).
        el.classList.toggle('inv-external-readonly', !!panel.readOnly);

        // THE SLOT GRID IS REBUILT, and that is safe where rebuilding the PANEL is not: a drag
        // out of this grid cancels first (cancelInteractions), and a drag out of the player
        // grid never holds a node in here.
        const grid = el.querySelector('.inv-slots-grid');
        if (grid) {
            grid.innerHTML = '';
            const slotCount = panel.slots || 1;
            for (let i = 1; i <= slotCount; i++) {
                // panel.key, not 'external'. This string becomes dataset.container, and it is
                // what tells every downstream drag, drop and move WHICH wallet a slot is in.
                grid.appendChild(createSlotElement(i, panel.key));
            }
        }
    }

    // A PANEL YOU JUST OPENED IS ON SCREEN. New panels append to the bottom of the stack, so one
    // can land below the fold. Scroll just far enough to show it whole (or its top, if it is taller
    // than the column). offsetTop is relative to the stack, which is its positioned parent.
    // Only on an OPEN: re-renders for a weight change or a remote delta create nothing, so they
    // never move the player's scroll.
    if (opened) {
        const top = opened.offsetTop;
        const bottom = top + opened.offsetHeight;
        if (top < stack.scrollTop || bottom > stack.scrollTop + stack.clientHeight) {
            stack.scrollTo({ top: Math.max(0, Math.min(top, bottom - stack.clientHeight)), behavior: 'smooth' });
        }
    }
}





function renderPlayerInvGrids() {
    const playerGrid = document.getElementById('inv-player-inv-grid');
    if (!playerGrid) return;

    playerGrid.innerHTML = '';

    const playerSlots = inv.playerInvMaxSlots.player || 30;
    for (let i = 1; i <= playerSlots; i++) {
        const slot = createSlotElement(i, 'targetPlayer');
        playerGrid.appendChild(slot);
    }
}

function renderPlayerInvInfo() {
    const nameEl = document.getElementById('inv-player-inv-name');
    const infoEl = document.getElementById('inv-player-inv-info');
    if (nameEl) nameEl.textContent = inv.playerInvCharName || 'Player';
    if (infoEl) {
        const totalWeight = (inv.playerInvWeights.player || 0);
        const totalMax = (inv.playerInvMaxWeight.player || 80);
        infoEl.textContent = weightLine(totalWeight, totalMax);
    }
}



// Re-number ground items sequentially after removing one from the middle
// e.g. {"1": ..., "3": ...} → {"1": ..., "2": ...}
function reindexGroundItems() {
    const items = [];
    const keys = Object.keys(inv.groundItems).sort((a, b) => parseInt(a) - parseInt(b));
    for (const k of keys) {
        items.push(inv.groundItems[k]);
    }
    inv.groundItems = {};
    for (let i = 0; i < items.length; i++) {
        inv.groundItems[String(i + 1)] = items[i];
    }
}

export function createSlotElement(slotNum, container) {
    const slot = document.createElement('div');
    slot.className = 'inv-slot';
    slot.dataset.container = container;
    slot.dataset.slot = slotNum;

    // Slot number label (first 5 in player grid)
    if (container === 'player' && slotNum <= 5) {
        const numEl = document.createElement('span');
        numEl.className = 'inv-slot-number';
        numEl.textContent = slotNum;
        slot.appendChild(numEl);
    }

    // Check if slot has an item — each container type reads from its own store (slotDataFor).
    const slotData = slotDataFor(container, slotNum);

    // THE SAME STAMP refreshSlotVisuals keeps (item|amount): a slot built here already shows this,
    // so the refresh that follows every open and every drag reply can skip it. Without it every
    // freshly built slot read as unrendered, and each open rebuilt the grid two or three times.
    slot.dataset.rendered = slotData ? (slotData.item + '|' + slotData.amount) : '';

    // Store ground item DB id on the slot for pickup identification
    if (container === 'ground' && slotData && slotData.groundId) {
        slot.dataset.groundId = slotData.groundId;
    }

    if (slotData) {
        const def = invItemDefs[slotData.item];
        const itemEl = document.createElement('div');
        itemEl.className = 'inv-item';
        itemEl.dataset.item = slotData.item;
        itemEl.dataset.container = container;
        itemEl.dataset.slot = slotNum;

        // Item image — setItemImage picks the picture the item's state asks for (def.images), else
        // its own, from whip_core or the resource that registered it. Falls back through whip_core
        // to missing.png via the global capture-phase listener in utils.js.
        const img = document.createElement('img');
        img.className = 'inv-item-img';
        img.alt = '';
        setItemImage(img, slotData);

        itemEl.appendChild(img);
        slot.appendChild(itemEl);
        slot.appendChild(slotNameEl(slotData));

        // Amount badge
        if (slotData.amount > 1) slot.appendChild(slotAmountEl(slotData));

        slot.classList.add('has-item');

        // (A shop's goods are not built here: shops.js draws them as cards.)

        // Stock mode: show price + forSale badge on container slots
        if (container === 'container' && inv.stockMode) drawStockBadge(slot, slotNum);

        // (The basket is a list of lines, drawn by shops.js — not slots.)
    }

    return slot;
}

function renderPersonalInfo() {
    const nameEl = document.getElementById('inv-name');
    const charIdEl = document.getElementById('inv-charid');
    const acctEl = document.getElementById('inv-account');
    if (nameEl) nameEl.textContent = inv.charName || 'Unknown';
    if (charIdEl) charIdEl.textContent = inv.charId || '?';
    if (acctEl) acctEl.textContent = inv.accountNum || '—';
}

function renderWeights() {
    // The panel is headed with WHO you are, not the word "Player". renderWeights already runs
    // on open and on every state update, so the name follows a character switch for free.
    const playerTitle = document.getElementById('inv-player-title');
    if (playerTitle) playerTitle.textContent = inv.charName || 'Player';

    const playerSub = document.getElementById('inv-player-weight');
    if (playerSub) {
        // Accessory weight counts towards player total
        const playerW = (inv.weights.player || 0) + (inv.weights.accessory || 0);
        const max = inv.maxWeight.player || 80;
        playerSub.textContent = weightLine(playerW, max);

        // THE GAUGE: the bar, amber from 85%, red when full (inventory.css .inv-weight).
        const f = max > 0 ? playerW / max : 0;
        const fill = document.getElementById('inv-player-weight-fill');
        if (fill) fill.style.transform = 'scaleX(' + Math.min(1, Math.max(0, f)).toFixed(3) + ')';
        const box = document.getElementById('inv-player-weight-box');
        if (box) {
            const full = f >= 1 - 1e-6;
            box.classList.toggle('full', full);
            box.classList.toggle('near', !full && f >= 0.85);
        }
    }
}

// ------------------------------------------
// HELPERS — mark slots that contain items
// ------------------------------------------
function tagItemSlots() {
    document.querySelectorAll('#inv-overlay .inv-slot').forEach(slot => {
        if (slot.querySelector('[data-item]')) {
            slot.classList.add('has-item');
        } else {
            slot.classList.remove('has-item');
        }
    });
}

// ------------------------------------------
// DRAG & DROP — server-validated
// ------------------------------------------
let dragItem = null;
let dragGhost = null;
let dragSourceSlot = null;
// The slot the drag is lit over, so a move clears THAT one rather than touching every slot on
// every mousemove. The drag's end and cancel still sweep them all once, which also catches a slot
// re-rendered under the cursor.
let dragHoverSlot = null;

// ------------------------------------------
// SLOT LISTENERS — one delegated set on the overlay root.
//
// The overlay root is static in index.html, so the five listeners live THERE, once, bound at
// load, and resolve which slot was hit from the event target. A slot that appears in a grid
// rebuild is covered the moment it is appended; nothing re-binds anything.
//
// mouseenter/mouseleave do not bubble, so their delegated forms are mouseover/mouseout
// with a relatedTarget check: a move between two children of the SAME slot fires both
// events, and must neither re-show nor hide the tooltip.
// ------------------------------------------
(function bindInvSlotListeners() {
    const overlay = document.getElementById('inv-overlay');

    const slotFrom = (node) =>
        node instanceof Element ? node.closest('.inv-slot') : null;

    // Left-click starts drag if slot has item. SHIFT + left-click sends it across instead
    // (quickMove): pockets -> whatever is open on the right, and the right -> pockets.
    overlay.addEventListener('mousedown', (e) => {
        if (e.button !== 0) return;
        const slot = slotFrom(e.target);
        if (!slot) return;
        const item = slot.querySelector('[data-item]');
        if (!item) return;
        // A card's count is a field: it takes the click, and the focus (no preventDefault).
        if (e.target.closest('.inv-qty-input')) return;
        e.preventDefault();
        hideContextMenu();
        // A SHOP'S TILE IS NOT PICKED UP: a click puts one in the basket. The pad's A
        // is this same mousedown, so it adds one too. The card stays up: it is the item's price
        // and description, still true after the click. HELD, it keeps adding (shops.js holdStart): the
        // mouse's until the button is let go, the pad's (its mousedown is ours: not isTrusted) until A is.
        if (slot.dataset.container === 'shop') {
            // (A card's own minus and plus answer their click in shops.js.)
            if (!e.target.closest('.inv-shop-card-ctl')) shelfAdd(slot, 1, e.isTrusted ? 'mouse' : 'pad');
            return;
        }
        hideTooltip();
        if (e.shiftKey) {
            quickMove(slot);
            return;
        }
        startDrag(item, slot, e.clientX, e.clientY);
    });

    // Right-click — context menu OR drop-one-item during drag
    overlay.addEventListener('contextmenu', (e) => {
        const slot = slotFrom(e.target);
        if (!slot) return;
        e.preventDefault();

            // If dragging a stack, right-click drops 1 item into hovered slot
            if (dragItem && dragSourceSlot) {
                // Queued rather than called inline BECAUSE OF THE EARLY RETURNS below — this
                // handler exits from about six different branches depending on which stores are
                // involved, and each one decrements the source itself. A timeout of 0 runs after
                // whichever branch ran, so there is one check instead of six.
                setTimeout(endDragIfSourceExhausted, 0);

                const fromContainer = dragSourceSlot.dataset.container;
                const fromSlot      = parseInt(dragSourceSlot.dataset.slot);
                const toContainer   = slot.dataset.container;
                const toSlot        = parseInt(slot.dataset.slot);

                if (fromContainer && toContainer && fromSlot && toSlot
                    && !(fromContainer === toContainer && fromSlot === toSlot)) {

                    // Can't right-click drop from ground items
                    if (fromContainer === 'ground') return;

                    const fromKey  = String(fromSlot);

                    // Get source data from the correct store
                    const isFromTarget = (fromContainer === 'targetPlayer');
                    const isToTarget   = (toContainer === 'targetPlayer');
                    const fromData = fromContainer === 'container'
                        ? inv.containerItems[fromKey]
                        : isFromTarget
                        ? (inv.playerInvItems.player[fromKey])
                        : (inv.state[fromContainer] && inv.state[fromContainer][fromKey]);

                    // Player-inventory-involved drop-one
                    if (inv.playerInvOpen && (isFromTarget || isToTarget)) {
                        const dropOp = beginOp(['state', 'playerInv']);

                        if (fromData && fromData.amount > 0) {
                            const toKey = String(toSlot);

                            // Resolve stores
                            const fromStoreName = fromContainer === 'targetPlayer' ? 'player'
                        : null;
                            const toStoreName = toContainer === 'targetPlayer' ? 'player'
                        : null;

                            const toData = isToTarget
                                ? (inv.playerInvItems[toStoreName][toKey])
                                : (inv.state[toContainer] && inv.state[toContainer][toKey]);

                            if (!toData || toData.item === fromData.item) {
                                const itemKey  = fromData.item;
                                const metadata = fromData.metadata;

                                // Decrement source
                                fromData.amount -= 1;
                                if (fromData.amount <= 0) {
                                    if (isFromTarget) {
                                        delete inv.playerInvItems[fromStoreName][fromKey];
                                    } else {
                                        delete inv.state[fromContainer][fromKey];
                                    }
                                }

                                // Increment target
                                if (isToTarget) {
                                    if (toData) {
                                        toData.amount += 1;
                                    } else {
                                        inv.playerInvItems[toStoreName][toKey] = { item: itemKey, amount: 1, metadata: metadata };
                                    }
                                } else {
                                    if (!inv.state[toContainer]) inv.state[toContainer] = {};
                                    if (toData) {
                                        toData.amount += 1;
                                    } else {
                                        inv.state[toContainer][toKey] = { item: itemKey, amount: 1, metadata: metadata };
                                    }
                                }

                                refreshSlotVisuals();
                                renderPlayerInvGrids();
                                renderPlayerInvInfo();
                            }
                        }

                        emit(dropOp, 'playerInvDropOneItem', {
                            fromType: fromContainer,
                            fromSlot: fromSlot,
                            toType: toContainer,
                            toSlot: toSlot,
                        });
                        return;
                    }

                    // PANEL-INVOLVED DROP-ONE: a panel's key ('panel:<id>') is not a pocket name, so
                    // one unit goes through the panel's own move, like a full drag does, and the
                    // screen follows the server's answer rather than a guess.
                    const dropFromPanel = panelByKey(fromContainer);
                    const dropToPanel   = panelByKey(toContainer);
                    if (dropFromPanel || dropToPanel) {
                        // No route (bagWithoutRoute): a bag with the ground or another player, through the pockets.
                        if (bagWithoutRoute(fromContainer, toContainer)) return;
                        if ((dropFromPanel && dropFromPanel.readOnly && dropFromPanel !== dropToPanel)
                            || (dropToPanel && dropToPanel.readOnly && dropFromPanel !== dropToPanel)) return;
                        if (!fromData && !(dropFromPanel && dropFromPanel.items[fromKey])) return;
                        const dropOp = beginOp(['state', 'container', 'panels']);
                        let payload;
                        if (dropFromPanel && dropToPanel) {
                            payload = dropFromPanel === dropToPanel
                                ? { direction: 'withinPanel', panelId: dropFromPanel.id, panelSlot: fromSlot, toPanelSlot: toSlot }
                                : { direction: 'panelToPanel', panelId: dropFromPanel.id, toPanelId: dropToPanel.id,
                                    panelSlot: fromSlot, toPanelSlot: toSlot };
                        } else if (dropToPanel) {
                            payload = { direction: 'toPanel', panelId: dropToPanel.id, panelSlot: toSlot,
                                        invContainer: fromContainer, invSlot: fromSlot };
                        } else {
                            payload = { direction: 'fromPanel', panelId: dropFromPanel.id, panelSlot: fromSlot,
                                        invContainer: toContainer, invSlot: toSlot };
                        }
                        payload.containerId = inv.containerId;
                        payload.mode = 'one';
                        payload.amount = 1;
                        emit(dropOp, 'externalPanelMove', payload);
                        return;
                    }
                    // The ignition takes a key by drag; one unit of a key is the key.
                    if (fromContainer === 'ignition' || toContainer === 'ignition') {
                        uiNotify({ text: 'Drag the key to move it', type: 'error', duration: 3000 });
                        return;
                    }

                    // Container-involved drop-one
                    if (inv.containerOpen && (fromContainer === 'container' || toContainer === 'container')) {
                        const dropOp = beginOp(['state', 'container']);

                        if (fromData && fromData.amount > 0) {
                            const toKey = String(toSlot);
                            const toData = toContainer === 'container'
                                ? inv.containerItems[toKey]
                                : (inv.state[toContainer] && inv.state[toContainer][toKey]);

                            if (!toData || toData.item === fromData.item) {
                                const itemKey  = fromData.item;
                                const metadata = fromData.metadata;

                                // Decrement source
                                fromData.amount -= 1;
                                if (fromData.amount <= 0) {
                                    if (fromContainer === 'container') {
                                        delete inv.containerItems[fromKey];
                                    } else {
                                        delete inv.state[fromContainer][fromKey];
                                    }
                                }

                                // Increment target
                                if (toContainer === 'container') {
                                    if (toData) {
                                        toData.amount += 1;
                                    } else {
                                        inv.containerItems[toKey] = { item: itemKey, amount: 1, metadata: metadata };
                                    }
                                } else {
                                    if (!inv.state[toContainer]) inv.state[toContainer] = {};
                                    if (toData) {
                                        toData.amount += 1;
                                    } else {
                                        inv.state[toContainer][toKey] = { item: itemKey, amount: 1, metadata: metadata };
                                    }
                                }

                                refreshSlotVisuals();
                            }
                        }

                        emit(dropOp, 'containerDropOneItem', {
                            containerId: inv.containerId,
                            fromContainer: fromContainer,
                            fromSlot: fromSlot,
                            toContainer: toContainer,
                            toSlot: toSlot,
                        });
                        return;
                    }

                    if (toContainer === 'ground') {
                        // Drop one item to the ground.
                        // The op is opened OUTSIDE the mutation guard, exactly like the playerInv
                        // and container branches above: emit() below runs unconditionally, and a
                        // `const` declared inside the if is out of scope there — which threw a
                        // ReferenceError after the optimistic decrement had already painted, and
                        // left the opened op orphaned in the pending queue for confirmOldestOp
                        // to mis-pop on the next authoritative update.
                        const dropOp = beginOp(['state', 'ground']);

                        if (fromData && fromData.amount > 0) {
                            fromData.amount -= 1;
                            if (fromData.amount <= 0) {
                                delete inv.state[fromContainer][fromKey];
                            }
                            refreshSlotVisuals();
                        }

                        // Op-tagged, so a refusal reverts precisely and the snapshot does not sit
                        // in the queue. The Lua side echoes the id like storeMove does.
                        emit(dropOp, 'dropOneToGround', {
                            fromContainer: fromContainer,
                            fromSlot: fromSlot,
                        });
                    } else {
                        // Check accessory slot restriction before drop-one
                        if (toContainer === 'accessory') {
                            const slotCfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
                            if (slotCfg && slotCfg.accepts && fromData && fromData.item !== slotCfg.accepts) {
                                const def = invItemDefs[slotCfg.accepts];
                                uiNotify({ text: 'Only ' + (def ? def.name : slotCfg.label) + ' can go here', type: 'error', duration: 3000 });
                                return;
                            }
                        }

                        // Normal inventory drop-one.
                        // This branch had NO beginOp at all — its emit() read `dropOp` from
                        // scopes that had already returned, so the gesture threw every time and
                        // the server was never told about the optimistic decrement below.
                        const dropOp = beginOp(['state']);

                        const toKey  = String(toSlot);
                        const toData = inv.state[toContainer] && inv.state[toContainer][toKey];

                        if (fromData && fromData.amount > 0) {
                            if (!toData || toData.item === fromData.item) {
                                const itemKey  = fromData.item;
                                const metadata = fromData.metadata;

                                fromData.amount -= 1;
                                if (fromData.amount <= 0) {
                                    delete inv.state[fromContainer][fromKey];
                                }

                                if (!inv.state[toContainer]) inv.state[toContainer] = {};
                                if (toData) {
                                    toData.amount += 1;
                                } else {
                                    inv.state[toContainer][toKey] = { item: itemKey, amount: 1, metadata: metadata };
                                }

                                refreshSlotVisuals();
                            }
                        }

                        emit(dropOp, 'dropOneItem', {
                            fromContainer: fromContainer,
                            fromSlot: fromSlot,
                            toContainer: toContainer,
                            toSlot: toSlot,
                        });
                    }
                }
                return;
            }

            // A shop's tile has no right-click. Holding it adds
            // faster, and its count can be typed into (shops.js).
            const ctxContainer = slot.dataset.container;
            if (ctxContainer === 'shop') return;

            // No context menu for the admin view of another player or the ignition slot, and none
            // on a read-only panel — there is nothing there to act on. Everything else gets one;
            // what is ON it depends on the grid (showContextMenu).
            if (ctxContainer === 'targetPlayer' || ctxContainer === 'ignition') return;
            const ctxPanel = panelByKey(ctxContainer);
            if (ctxPanel && ctxPanel.readOnly) return;

            const item = slot.querySelector('[data-item]');
            if (!item) return;
            hideTooltip();
            showContextMenu(e.clientX, e.clientY, item, slot);
    });

    // Hover — tooltip. Delegated mouseenter: ignore moves that started inside the same slot.
    overlay.addEventListener('mouseover', (e) => {
        if (!inv.open || dragItem) return;
        const slot = slotFrom(e.target);
        if (!slot || slotFrom(e.relatedTarget) === slot) return;
        const item = slot.querySelector('[data-item]');
        if (!item) return;
        showTooltipForItem(item);
    });

    overlay.addEventListener('mousemove', (e) => {
        if (dragItem) return;
        const slot = slotFrom(e.target);
        if (!slot) return;
        const item = slot.querySelector('[data-item]');
        if (!item) return;
        positionTooltip(e.clientX, e.clientY);
    });

    // Delegated mouseleave: ignore moves that end inside the same slot.
    overlay.addEventListener('mouseout', (e) => {
        const slot = slotFrom(e.target);
        if (!slot || slotFrom(e.relatedTarget) === slot) return;
        hideTooltip();
    });
})();

function startDrag(item, slot, x, y) {
    dragItem = item;
    dragSourceSlot = slot;
    item.classList.add('dragging');

    // The ghost: a box at the cursor, with a copy of the item inside it drawn at the screen's scale
    // (css/inventory.css .inv-drag-ghost-item).
    const copy = item.cloneNode(true);
    copy.classList.remove('dragging');
    copy.classList.add('inv-drag-ghost-item');
    copy.style.width = item.offsetWidth + 'px';
    copy.style.height = item.offsetHeight + 'px';
    dragGhost = document.createElement('div');
    dragGhost.className = 'inv-drag-ghost';
    dragGhost.appendChild(copy);
    dragGhost.style.left = x + 'px';
    dragGhost.style.top = y + 'px';
    document.body.appendChild(dragGhost);

    document.addEventListener('mousemove', onDragMove);
    document.addEventListener('mouseup', onDragEnd);
}

function onDragMove(e) {
    if (!dragGhost) return;
    dragGhost.style.left = e.clientX + 'px';
    dragGhost.style.top = e.clientY + 'px';

    const found = getSlotUnderCursor(e.clientX, e.clientY);
    const target = (found && found !== dragSourceSlot) ? found : null;
    if (target === dragHoverSlot) return;   // still over the same slot: nothing to redraw

    if (dragHoverSlot) dragHoverSlot.classList.remove('drag-over', 'drag-refuse');
    dragHoverSlot = target;
    if (target) {
        target.classList.add(dropRefused(dragSourceSlot, target) ? 'drag-refuse' : 'drag-over');
    }
}

/**
 * Will this drop be refused? Asked while the cursor is over a slot, so the slot can say "not
 * here" (a red edge) before the player lets go.
 *
 * THE PILL USED TO LIGHT ON EVERY SQUARE, including the ones a drop was always going to bounce
 * off — a phone into a slot typed for something else, anything across a read-only panel's edge, a second key into
 * an occupied ignition. The screen promised the move and then took it back.
 *
 * ONLY WHAT THIS SCREEN CAN KNOW: the same client-side rules onDragEnd applies, plus a panel's
 * allowed-items list. A slot that passes here can still be refused by the server (weight, a
 * panel's own onValidate), and that refusal comes back with its reason as it always has.
 * @returns {boolean}
 */
function dropRefused(fromEl, toEl) {
    const from = fromEl.dataset.container;
    const to   = toEl.dataset.container;
    const fromSlot = parseInt(fromEl.dataset.slot);
    const toSlot   = parseInt(toEl.dataset.slot);
    if (!from || !to) return false;

    const moving = slotDataFor(from, fromSlot);
    if (!moving) return false;
    const there = slotDataFor(to, toSlot);

    // A shop's tile is never dragged (a click adds it to the basket), and nothing is dropped on one.
    if (from === 'shop' || to === 'shop') return true;

    // A bag (a resource's panel) has no move with the ground or another player's inventory: through the pockets.
    // (The strip trades with everything the pockets do: the ignition, a stash or boot, the ground, a bag.)
    if (bagWithoutRoute(from, to)) return true;

    // Typed accessory slots, both ways round: what goes in must fit, and on a swap what comes
    // back must fit the slot the dragged item left.
    if (to === 'accessory' && !accessoryTakes(toSlot, moving.item)) return true;
    if (from === 'accessory' && there && !accessoryTakes(fromSlot, there.item)) return true;

    // The ignition takes a key, into an empty slot; a key comes out onto an empty slot only.
    if (to === 'ignition' && (!isIgnitionKeyItem(moving.item) || inv.ignitionSlot)) return true;
    if (from === 'ignition' && there) return true;

    // Panels: nothing crosses a read-only panel's edge, and a panel with a list takes only what
    // is on it (the wallet takes cash and cards).
    const fromPanel = panelByKey(from);
    const toPanel   = panelByKey(to);
    if (fromPanel !== toPanel
        && ((fromPanel && fromPanel.readOnly) || (toPanel && toPanel.readOnly))) return true;
    if (toPanel && toPanel !== fromPanel && toPanel.allowed && !toPanel.allowed[moving.item]) return true;

    // WEIGHT, WHERE THIS SCREEN KNOWS THE LIMIT: no white pill for a drop the server would take
    // back. quickMove asks the same.
    if (dropTooHeavy(from, to, moving, there)) return true;

    return false;
}

/** The pockets and the accessory strip are one weight: the strip counts towards the player's total. */
function weightPool(container) {
    return (container === 'player' || container === 'accessory') ? 'pockets' : container;
}

/**
 * Would this drop take its destination past what it can hold? Only between different stores, and
 * only where the limit is known here: the pockets, a stash or boot, a resource's panel (gridOf). A
 * swap sends the other stack back out, so only the difference has to fit. The server still decides.
 */
function dropTooHeavy(from, to, moving, there) {
    if (from === 'shop' || to === 'shop') return false;   // never a drop (dropRefused)
    if (weightPool(from) === weightPool(to)) return false;
    // A pile off the ground comes up as far as the pockets take it (pickupGroundItem takes part of it): too heavy only
    // when not even one would go.
    if (from === 'ground') moving = oneOfPile(moving);
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
 * The optimistic move every plain drag performs, between two slot-keyed stores: stack onto a
 * matching item, swap with a different one, or move into an empty slot. This exact triad was
 * written out seven times across onDragEnd's branches (player↔player, the three container
 * directions, the three admin-view directions) and they drifted only in whitespace.
 *
 * NOT used by the branches that genuinely differ: accessory (swap-only + slot restrictions),
 * external panel (stacks but never swaps), ignition (single slot), ground (server-keyed).
 *
 * @returns {boolean} whether anything moved (false = source slot was empty)
 */
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

/** The op the current drag opened, so onDragEnd can settle it however the drag ends. */
let dragGestureOp = null;

/**
 * The drag's end. A thin wrapper so the gesture's op is settled on EVERY way out: dragEndBody has a
 * dozen branches that refuse locally and return without sending, and an op left open would make the
 * inventory ignore the server until the 15 s sweep.
 */
function onDragEnd(e) {
    dragGestureOp = null;
    try {
        dragEndBody(e);
    } finally {
        settleUnsentOp(dragGestureOp);
        dragGestureOp = null;
    }
}

function dragEndBody(e) {
    // Ignore right-click release — only end drag on left-click (button 0)
    if (e.button !== 0) return;

    document.removeEventListener('mousemove', onDragMove);
    document.removeEventListener('mouseup', onDragEnd);

    const target = getSlotUnderCursor(e.clientX, e.clientY);

    if (target && target !== dragSourceSlot) {
        const fromContainer = dragSourceSlot.dataset.container;
        const fromSlot      = parseInt(dragSourceSlot.dataset.slot);
        const toContainer   = target.dataset.container;
        const toSlot        = parseInt(target.dataset.slot);

        if (fromContainer && toContainer && fromSlot && toSlot) {
            // TOO HEAVY TO GO THERE: the slot showed the red edge during the drag, so
            // letting go does nothing — as over a read-only panel, below — rather than moving the item
            // and having the server take it back.
            const movingData = slotDataFor(fromContainer, fromSlot);
            if (movingData && dropTooHeavy(fromContainer, toContainer, movingData, slotDataFor(toContainer, toSlot))) {
                cancelDrag();
                return;
            }

            // THE SHOP IS NOT A DRAG. Its tiles add to the basket on a click, and the
            // basket is a list with its own buttons — the server's three shop actions, never a
            // store move. Nothing can be dropped on a shop tile.
            if (fromContainer === 'shop' || toContainer === 'shop') {
                cancelDrag();
                return;
            }

            // NO ROUTE, and the slot showed the red edge (dropRefused): a bag with the ground or another player.
            if (bagWithoutRoute(fromContainer, toContainer)) {
                cancelDrag();
                return;
            }

            // THE STRIP'S TYPED SLOTS against anything but the pockets (the accessory branch below checks
            // pockets and strip itself, and says why): what goes in must fit, and on a swap what comes back
            // must fit the slot it left.
            const pocketPair = isPocketGrid(fromContainer) && isPocketGrid(toContainer);
            const thereData = slotDataFor(toContainer, toSlot);
            if (!pocketPair && movingData
                && ((toContainer === 'accessory' && !accessoryTakes(toSlot, movingData.item))
                    || (fromContainer === 'accessory' && thereData && !accessoryTakes(fromSlot, thereData.item)))) {
                cancelDrag();
                return;
            }

            // THE GESTURE'S OP ID, held in a local and passed to every emit — the engine no
            // longer keeps a "current op" global to lean on (see core/inv-ops.js on why that
            // died).
            const opId = beginOp(inv.containerOpen ? ['state', 'ground', 'container'] : ['state', 'ground']);
            dragGestureOp = opId;   // settled by onDragEnd if nothing sends it

            const fromKey = String(fromSlot);
            const toKey   = String(toSlot);

            // Ten of the emits below send exactly this 4-tuple (plus at most a containerId);
            // one builder instead of ten hand-rolled payload literals.
            const emitMove = (event, extra) => emit(opId, event, Object.assign({
                fromContainer: fromContainer,
                fromSlot:      fromSlot,
                toContainer:   toContainer,
                toSlot:        toSlot,
            }, extra || null));

            // ---- ACCESSORY DRAG LOGIC: the strip with the pockets, or within itself ----
            //
            // The strip with anything else (the ignition, a stash or boot, the ground, a bag, the admin view) is
            // the branch for the pockets' own move with that thing: each reads and writes inv.state[container]
            // and sends the container's name, and the server takes 'accessory' as a pocket.
            if ((fromContainer === 'accessory' || toContainer === 'accessory') && pocketPair) {
                if (toContainer === 'accessory' && fromContainer !== 'accessory') {
                    // Player/Accessory → Accessory slot
                    const fromData = inv.state[fromContainer] && inv.state[fromContainer][fromKey];
                    if (fromData) {
                        // Check slot restriction
                        const slotCfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
                        if (slotCfg && slotCfg.accepts && fromData.item !== slotCfg.accepts) {
                            const def = invItemDefs[slotCfg.accepts];
                            const slotName = def ? def.name : slotCfg.label;
                            uiNotify({ text: 'Only ' + slotName + ' can go here', type: 'error', duration: 3000 });
                        } else if (inv.state.accessory[toKey]) {
                            // Slot occupied — swap
                            const existingAccessory = inv.state.accessory[toKey];
                            inv.state.accessory[toKey] = fromData;
                            inv.state[fromContainer][fromKey] = existingAccessory;
                            emitMove('moveItem');
                        } else {
                            // Empty slot — move in
                            if (!inv.state.accessory) inv.state.accessory = {};
                            inv.state.accessory[toKey] = fromData;
                            delete inv.state[fromContainer][fromKey];
                            emitMove('moveItem');
                        }
                    }
                } else if (fromContainer === 'accessory' && toContainer !== 'accessory') {
                    // Accessory → Player/Accessory
                    const fromData = inv.state.accessory && inv.state.accessory[fromKey];
                    if (fromData) {
                        if (!inv.state[toContainer]) inv.state[toContainer] = {};
                        const toData = inv.state[toContainer][toKey];
                        if (toData) {
                            // Check if the item being swapped back can go into the accessory slot
                            const slotCfg = slotConfig.accessorySlots.find(c => c.slot === fromSlot);
                            if (slotCfg && slotCfg.accepts && toData.item !== slotCfg.accepts) {
                                const def = invItemDefs[slotCfg.accepts];
                                const slotName = def ? def.name : slotCfg.label;
                                uiNotify({ text: 'Only ' + slotName + ' can go in that slot', type: 'error', duration: 3000 });
                            } else {
                                // Swap
                                inv.state.accessory[fromKey] = toData;
                                inv.state[toContainer][toKey] = fromData;
                                emitMove('moveItem');
                            }
                        } else {
                            // Empty target — move out
                            inv.state[toContainer][toKey] = fromData;
                            delete inv.state.accessory[fromKey];
                            emitMove('moveItem');
                        }
                    }
                } else {
                    // Accessory → Accessory (swap within)
                    const fromData = inv.state.accessory && inv.state.accessory[fromKey];
                    const toData = inv.state.accessory && inv.state.accessory[toKey];
                    if (fromData) {
                        // Check restriction on target slot
                        const toCfg = slotConfig.accessorySlots.find(c => c.slot === toSlot);
                        const fromCfg = slotConfig.accessorySlots.find(c => c.slot === fromSlot);
                        const toAcceptsFrom = !toCfg.accepts || fromData.item === toCfg.accepts;
                        const fromAcceptsTo = !toData || !fromCfg.accepts || toData.item === fromCfg.accepts;

                        if (!toAcceptsFrom) {
                            const def = invItemDefs[toCfg.accepts];
                            uiNotify({ text: 'Only ' + (def ? def.name : toCfg.label) + ' can go here', type: 'error', duration: 3000 });
                        } else if (!fromAcceptsTo) {
                            const def = invItemDefs[fromCfg.accepts];
                            uiNotify({ text: 'Only ' + (def ? def.name : fromCfg.label) + ' can go in that slot', type: 'error', duration: 3000 });
                        }

                        if (toAcceptsFrom && fromAcceptsTo) {
                            if (toData) {
                                inv.state.accessory[fromKey] = toData;
                                inv.state.accessory[toKey] = fromData;
                            } else {
                                inv.state.accessory[toKey] = fromData;
                                delete inv.state.accessory[fromKey];
                            }
                            emitMove('moveItem');
                        }
                    }
                }
            }
            // ---- IGNITION DRAG LOGIC (must be checked before container) ----
            else if (inv.ignitionOpen && (fromContainer === 'ignition' || toContainer === 'ignition')) {
                // Captured because the branches below can reject the drag locally, without
                // ever contacting the server — in which case the op is finished, not pending.
                // A bag on the other side (a key in a backpack): its items are the panel's own, and the move names it.
                const keyPanel = panelByKey(fromContainer) || panelByKey(toContainer);
                const ignitionOp = extendOp(opId, ['ignition'].concat(inv.containerOpen ? ['container'] : [],
                    keyPanel ? ['panels'] : []));

                if (toContainer === 'ignition' && fromContainer !== 'ignition') {
                    // Player/Accessory/Container/bag → Ignition (insert key)
                    let fromData;
                    if (fromContainer === 'container') {
                        fromData = inv.containerItems[fromKey];
                    } else if (keyPanel) {
                        fromData = keyPanel.readOnly ? null : keyPanel.items[fromKey];
                    } else {
                        fromData = inv.state[fromContainer] && inv.state[fromContainer][fromKey];
                    }
                    if (fromData && isIgnitionKeyItem(fromData.item) && !inv.ignitionSlot) {
                        inv.ignitionSlot = fromData;
                        if (fromContainer === 'container') {
                            delete inv.containerItems[fromKey];
                        } else if (keyPanel) {
                            delete keyPanel.items[fromKey];
                            renderPanelStack();
                        } else {
                            delete inv.state[fromContainer][fromKey];
                        }
                        emit(ignitionOp, 'ignitionInsertKey', {
                            vehicleId: inv.ignitionVehicleId,
                            containerId: inv.containerId,
                            fromContainer: fromContainer,
                            fromSlot: fromSlot,
                            panelId: keyPanel ? keyPanel.id : undefined,
                        });
                    } else {
                        // Reject — not a key, or ignition occupied
                        commitOp(ignitionOp);
                    }
                } else if (fromContainer === 'ignition' && toContainer !== 'ignition') {
                    // Ignition → Player/Accessory/Container/bag (remove key)
                    if (inv.ignitionSlot && keyPanel) {
                        if (!keyPanel.readOnly && !keyPanel.items[toKey]) {
                            keyPanel.items[toKey] = inv.ignitionSlot;
                            inv.ignitionSlot = null;
                            renderPanelStack();
                            emit(ignitionOp, 'ignitionRemoveKey', {
                                vehicleId: inv.ignitionVehicleId,
                                containerId: inv.containerId,
                                toContainer: toContainer,
                                toSlot: toSlot,
                                panelId: keyPanel.id,
                            });
                        } else {
                            commitOp(ignitionOp);
                        }
                    } else if (inv.ignitionSlot) {
                        if (toContainer === 'container') {
                            const existing = inv.containerItems[toKey];
                            if (!existing) {
                                inv.containerItems[toKey] = inv.ignitionSlot;
                                inv.ignitionSlot = null;
                                emit(ignitionOp, 'ignitionRemoveKey', {
                                    vehicleId: inv.ignitionVehicleId,
                                    containerId: inv.containerId,
                                    toContainer: toContainer,
                                    toSlot: toSlot,
                                });
                            } else {
                                commitOp(ignitionOp);
                            }
                        } else {
                            if (!inv.state[toContainer]) inv.state[toContainer] = {};
                            const existing = inv.state[toContainer][toKey];
                            if (!existing) {
                                inv.state[toContainer][toKey] = inv.ignitionSlot;
                                inv.ignitionSlot = null;
                                emit(ignitionOp, 'ignitionRemoveKey', {
                                    vehicleId: inv.ignitionVehicleId,
                                    containerId: inv.containerId,
                                    toContainer: toContainer,
                                    toSlot: toSlot,
                                });
                            } else {
                                commitOp(ignitionOp);
                            }
                        }
                    }
                }
                // Re-render affected grids
                renderIgnitionSlot();
            }
            // ---- PANEL DRAG LOGIC (optimistic) ----
            //
            // WHICH panel, not WHETHER a panel (any number may be open). The two lookups resolve
            // the slot's container key to the panel it belongs to, and null for anything that is
            // not a panel — so they are the test as well.
            else if (panelByKey(fromContainer) || panelByKey(toContainer)) {
                const fromPanel = panelByKey(fromContainer);
                const toPanel   = panelByKey(toContainer);

                // ReadOnly guard: block moves that cross a read-only panel's boundary, allow a
                // rearrange inside it. Checked per panel now — a read-only bench must not stop
                // you rearranging the wallet open beside it.
                const crossing = (fromPanel !== toPanel);
                if (crossing && ((fromPanel && fromPanel.readOnly) || (toPanel && toPanel.readOnly))) {
                    cancelDrag();
                    return;
                }

                if (toPanel && !fromPanel) {
                    // Player/Accessory/Container → panel
                    const fromData = fromContainer === 'container'
                        ? inv.containerItems[fromKey]
                        : (inv.state[fromContainer] && inv.state[fromContainer][fromKey]);
                    if (fromData) {
                        const extOp = extendOp(opId, fromContainer === "container" ? ["panels", "container"] : ["panels", "state"]);
                        if (fromContainer === 'container') {
                            delete inv.containerItems[fromKey];
                        } else {
                            delete inv.state[fromContainer][fromKey];
                        }
                        toPanel.items[toKey] = { item: fromData.item, amount: fromData.amount || 1, metadata: fromData.metadata || null };
                        refreshSlotVisuals();
                        renderPanelStack();
                        emit(extOp, 'externalPanelMove', {
                            panelId: toPanel.id,
                            containerId: inv.containerId,
                            direction: 'toPanel',
                            panelSlot: toSlot,
                            invContainer: fromContainer,
                            invSlot: fromSlot,
                            item: fromData.item,
                            amount: fromData.amount || 1,
                            metadata: fromData.metadata || null,
                        });
                    }
                } else if (fromPanel && toPanel && fromPanel === toPanel) {
                    // Rearrange inside ONE panel. `fromPanel === toPanel` compares the entry
                    // objects, so two panels that happen to share a slot number cannot collide.
                    if (fromSlot === toSlot) { /* no-op */ }
                    else {
                        const srcData = fromPanel.items[fromKey];
                        if (srcData) {
                            const dstData = fromPanel.items[toKey] || null;
                            const extOp = extendOp(opId, ["panels"]);
                            fromPanel.items[toKey] = srcData;
                            if (dstData) {
                                fromPanel.items[fromKey] = dstData;
                            } else {
                                delete fromPanel.items[fromKey];
                            }
                            renderPanelStack();
                            emit(extOp, 'externalPanelMove', {
                                panelId: fromPanel.id,
                                containerId: inv.containerId,
                                direction: 'withinPanel',
                                panelSlot: fromSlot,
                                toPanelSlot: toSlot,
                                item: srcData.item,
                                amount: srcData.amount || 1,
                                metadata: srcData.metadata || null,
                            });
                        }
                    }
                } else if (fromPanel && toPanel) {
                    // ONE PANEL STRAIGHT INTO ANOTHER — wallet A to wallet B. A case that could
                    // not exist before, because there was never a second panel to drag into.
                    //
                    // The server needs nothing new for it: storeMove already takes two arbitrary
                    // addresses and both sides here are ordinary 'panel' addresses. Only the NUI
                    // callback lacked a direction for the pairing, so `panelToPanel` was added
                    // alongside the other three in client/inventory.lua.
                    const srcData = fromPanel.items[fromKey];
                    if (srcData) {
                        const dstData = toPanel.items[toKey] || null;
                        const extOp = extendOp(opId, ["panels"]);
                        toPanel.items[toKey] = srcData;
                        if (dstData) {
                            fromPanel.items[fromKey] = dstData;
                        } else {
                            delete fromPanel.items[fromKey];
                        }
                        renderPanelStack();
                        emit(extOp, 'externalPanelMove', {
                            panelId: fromPanel.id,
                            toPanelId: toPanel.id,
                            containerId: inv.containerId,
                            direction: 'panelToPanel',
                            panelSlot: fromSlot,
                            toPanelSlot: toSlot,
                            item: srcData.item,
                            amount: srcData.amount || 1,
                            metadata: srcData.metadata || null,
                        });
                    }
                } else if (fromPanel && !toPanel) {
                    // Panel → Player/Accessory/Container
                    const panelData = fromPanel.items[fromKey];
                    if (panelData) {
                        const extOp = extendOp(opId, toContainer === "container" ? ["panels", "container"] : ["panels", "state"]);
                        if (toContainer === 'container') {
                            const existingC = inv.containerItems[toKey];
                            if (existingC && existingC.item === panelData.item) {
                                inv.containerItems[toKey] = { item: existingC.item, amount: (existingC.amount || 1) + (panelData.amount || 1), metadata: existingC.metadata };
                            } else {
                                inv.containerItems[toKey] = { item: panelData.item, amount: panelData.amount || 1, metadata: panelData.metadata || null };
                            }
                        } else {
                            if (!inv.state[toContainer]) inv.state[toContainer] = {};
                            const existingP = inv.state[toContainer][toKey];
                            if (existingP && existingP.item === panelData.item) {
                                inv.state[toContainer][toKey] = { item: existingP.item, amount: (existingP.amount || 1) + (panelData.amount || 1), metadata: existingP.metadata };
                            } else {
                                inv.state[toContainer][toKey] = { item: panelData.item, amount: panelData.amount || 1, metadata: panelData.metadata || null };
                            }
                        }
                        delete fromPanel.items[fromKey];
                        refreshSlotVisuals();
                        renderPanelStack();
                        emit(extOp, 'externalPanelMove', {
                            panelId: fromPanel.id,
                            containerId: inv.containerId,
                            direction: 'fromPanel',
                            panelSlot: fromSlot,
                            invContainer: toContainer,
                            invSlot: toSlot,
                            item: panelData.item,
                            amount: panelData.amount || 1,
                            metadata: panelData.metadata || null,
                        });
                    }
                }
            }
            // ---- PLAYER INVENTORY DRAG LOGIC (admin viewing another player) ----
            else if (inv.playerInvOpen && (fromContainer === 'targetPlayer'
                || toContainer === 'targetPlayer')) {
                // Both sides are in play: a drag between the admin's inventory and the
                // target's touches inv.state and inv.playerInvItems, and either can be the
                // source. Snapshotting both is cheaper than working out which.
                const pOp = extendOp(opId, ["playerInv", "state"]);

                const isFromTarget = (fromContainer === 'targetPlayer');
                const isToTarget   = (toContainer === 'targetPlayer');

                // Resolve source data store
                const fromStore = fromContainer === 'targetPlayer' ? 'player'
            : null;
                const toStore = toContainer === 'targetPlayer' ? 'player'
            : null;

                if (isFromTarget && isToTarget) {
                    // Target → Target (move within target player's inventory)
                    moveBetweenStores(inv.playerInvItems[fromStore], fromKey,
                                      inv.playerInvItems[toStore], toKey);
                } else if (isFromTarget && !isToTarget) {
                    // Target → Admin inventory
                    if (!inv.state[toContainer]) inv.state[toContainer] = {};
                    moveBetweenStores(inv.playerInvItems[fromStore], fromKey,
                                      inv.state[toContainer], toKey);
                } else if (!isFromTarget && isToTarget) {
                    // Admin inventory → Target
                    if (!inv.playerInvItems[toStore]) inv.playerInvItems[toStore] = {};
                    moveBetweenStores(inv.state[fromContainer], fromKey,
                                      inv.playerInvItems[toStore], toKey);
                }

                // Send to server
                emit(pOp, 'playerInvMoveItem', {
                    fromType: fromContainer,
                    fromSlot: fromSlot,
                    toType: toContainer,
                    toSlot: toSlot,
                });

                // Re-render target grids
                renderPlayerInvGrids();
                renderPlayerInvInfo();
            }
            // ---- CONTAINER-AWARE DRAG LOGIC ----
            else if (inv.containerOpen && (fromContainer === 'container' || toContainer === 'container')) {
                // Any drag involving the container panel
                // The emit is deliberately OUTSIDE the moved check (as it always was): an
                // empty-slot drag still asks the server, whose answer is authoritative.
                if (fromContainer === 'container' && toContainer === 'container') {
                    // Container → Container (move within)
                    moveBetweenStores(inv.containerItems, fromKey, inv.containerItems, toKey);
                } else if (fromContainer === 'container') {
                    // Container → Player/Accessory
                    if (!inv.state[toContainer]) inv.state[toContainer] = {};
                    moveBetweenStores(inv.containerItems, fromKey, inv.state[toContainer], toKey);
                } else {
                    // Player/Accessory → Container
                    moveBetweenStores(inv.state[fromContainer], fromKey, inv.containerItems, toKey);
                }

                emitMove('containerMoveItem', { containerId: inv.containerId });
            }
            // ---- GROUND DRAG LOGIC (unchanged) ----
            else if (fromContainer === 'ground' && toContainer === 'ground') {
                // Ground to ground — no-op
            } else if (fromContainer === 'ground') {
                // PICKUP: Ground → Player/Accessory
                const groundData = inv.groundItems[fromKey];
                if (groundData && groundData.groundId) {
                    // Optimistic: add to inventory, remove from ground
                    if (!inv.state[toContainer]) inv.state[toContainer] = {};
                    const toData = inv.state[toContainer][toKey];
                    if (toData && toData.item === groundData.item) {
                        toData.amount = (toData.amount || 0) + (groundData.amount || 0);
                    } else if (!toData) {
                        inv.state[toContainer][toKey] = {
                            item: groundData.item,
                            amount: groundData.amount,
                            metadata: groundData.metadata,
                        };
                    }
                    delete inv.groundItems[fromKey];
                    reindexGroundItems();

                    // Op-tagged now — see the dropOneToGround note in the right-click handler.
                    emit(opId, 'pickupGroundItem', {
                        groundId: groundData.groundId,
                        toContainer: toContainer,
                        toSlot: toSlot,
                    });
                }
            } else if (toContainer === 'ground') {
                // DROP: Player/Accessory → Ground
                const fromData = inv.state[fromContainer] && inv.state[fromContainer][fromKey];
                if (fromData) {
                    // Optimistic: remove from inventory
                    delete inv.state[fromContainer][fromKey];

                    // Op-tagged now — see the dropOneToGround note in the right-click handler.
                    emit(opId, 'dropToGround', {
                        fromContainer: fromContainer,
                        fromSlot: fromSlot,
                        amount: fromData.amount,
                    });
                }
            } else {
                // Normal inventory move (player to player)
                if (!inv.state[toContainer]) inv.state[toContainer] = {};
                moveBetweenStores(inv.state[fromContainer], fromKey, inv.state[toContainer], toKey);

                // If container is open, use container move event (for player↔accessory while container open)
                if (inv.containerOpen) {
                    emitMove('containerMoveItem', { containerId: inv.containerId });
                } else {
                    emitMove('moveItem');
                }
            }
        } else {
            console.warn('[whip_core:inv] Drag: missing container/slot data', { fromContainer, fromSlot, toContainer, toSlot });
        }
    }

    // Cleanup drag state
    if (dragItem) dragItem.classList.remove('dragging');
    const allSlots = document.querySelectorAll('#inv-overlay .inv-slot');
    allSlots.forEach(s => s.classList.remove('drag-over', 'drag-refuse'));
    dragHoverSlot = null;
    if (dragGhost) { dragGhost.remove(); dragGhost = null; }
    dragItem = null;
    dragSourceSlot = null;

    // Render from optimistic state (instant) — server response will confirm or revert
    renderInventory();
    if (invHotbarHooks) invHotbarHooks.syncHotbar();
}

function cancelDrag() {
    document.removeEventListener('mousemove', onDragMove);
    document.removeEventListener('mouseup', onDragEnd);
    if (dragItem) dragItem.classList.remove('dragging');
    if (dragGhost) { dragGhost.remove(); dragGhost = null; }
    const allSlots = document.querySelectorAll('#inv-overlay .inv-slot');
    allSlots.forEach(s => s.classList.remove('drag-over', 'drag-refuse'));
    dragHoverSlot = null;
    dragItem = null;
    dragSourceSlot = null;

    // Re-render to catch deferred updates
    renderInventory();
    if (invHotbarHooks) invHotbarHooks.syncHotbar();
}

/** The slot a controller is pointing the drag at (the D-pad's highlight), set only while the pad's
 *  own mousemove / mouseup is being handled (padAimAt below). It is the answer for that event: a
 *  slot's measured position and the screen's points need not agree under the inventory's CSS zoom
 *  in FiveM's Chromium 103, so the pad names the slot instead of pointing at where it thinks it is. */
let padAim = null;

function getSlotUnderCursor(x, y) {
    if (padAim) return padAim;
    // elementFromPoint handles zoom/transforms natively;
    // drag ghost has pointer-events:none so it's seen through, and the pad's sheet is looked under (hitAt)
    const el = hitAt(x, y);
    if (!el) return null;
    return el.closest('#inv-overlay .inv-slot');
}

// ------------------------------------------
// ANY-GRID GESTURES — destroy, split and shift-click
//
// The three things that work on a slot whichever grid it is in: the pockets, a stash, a boot, a
// glovebox, a wallet or bag, a resource's panel, the ground. Each is OPTIMISTIC exactly like a
// drag: the screen changes the moment it is clicked, under an op (core/inv-ops.js), and the server
// confirms it or refuses with a reason — and a refusal puts the screen back.
//
// WHERE THINGS LAND IS THE SERVER'S CALL. A split's new half goes to the first free slot and a
// shift-clicked stack to the first slot that takes it (Stores.freeSlot / Stores.slotAccepting).
// predictFreeSlot / predictSlotAccepting below are the same rules, so the screen draws what the
// server is about to do; when they disagree (somebody else filled that slot a moment ago) the
// server's reply redraws the truth.
// ------------------------------------------

/** Grids that are not the player's own pockets. Anything else that is not a panel IS one of the
 *  player's containers ('player', 'accessory', and whatever PlayerContainers adds). */
const NOT_POCKETS = new Set(['ground', 'container', 'ignition', 'shop', 'basket', 'targetPlayer']);

function isPocketGrid(container) {
    return !!container && !NOT_POCKETS.has(container) && !panelByKey(container);
}

/** The accessory strip's typed slots — this screen's copy of the player kind's allowsAt. */
function accessoryTakes(slot, itemKey) {
    const cfg = slotConfig.accessorySlots.find(c => c.slot === slot);
    return !!cfg && (!cfg.accepts || cfg.accepts === itemKey);
}

/** A bag (a resource's panel) and the ground or another player's inventory: the server has no move between them
 *  (pickupGroundItem and dropToGround name pockets only; the admin view's moves are pockets-to-pockets). */
function bagWithoutRoute(a, b) {
    const other = (c) => c === 'ground' || c === 'targetPlayer';
    return (!!panelByKey(a) && other(b)) || (!!panelByKey(b) && other(a));
}

/**
 * One slot-keyed grid, described the same way whichever it is: which optimistic view owns it, its
 * items, its size and weight, and its per-slot rule if it has one. Null for the grids that are not
 * slot-keyed stores — the ground, the ignition, the shop screens, the admin view.
 */
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

/** Deep equality for metadata. Lua sends an empty table as [] as often as {}; both have no keys. */
function sameMeta(a, b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
    const ka = Object.keys(a);
    if (ka.length !== Object.keys(b).length) return false;
    for (const k of ka) {
        if (!sameMeta(a[k], b[k])) return false;
    }
    return true;
}

/** Can two stacks combine? Stores.stacksWith's rule: equal metadata, apart from the activity
 *  log's `uid` (bookkeeping about an item, not part of what it is). */
function stacksWith(a, b) {
    const strip = (m) => {
        const out = {};
        if (m && typeof m === 'object') {
            for (const k of Object.keys(m)) if (k !== 'uid') out[k] = m[k];
        }
        return out;
    };
    return sameMeta(strip(a), strip(b));
}

/** The first empty slot that takes this item — Stores.freeSlot. */
function predictFreeSlot(grid, itemKey) {
    for (let s = 1; s <= grid.slots; s++) {
        if (!grid.items[String(s)] && (!grid.takes || grid.takes(s, itemKey))) return s;
    }
    return null;
}

/** Where a whole stack would land — Stores.slotAccepting: onto a stack of the same thing it can
 *  join whole, otherwise the first empty slot that takes it. Null when there is none. */
function predictSlotAccepting(grid, itemKey, amount, metadata) {
    const def = invItemDefs[itemKey];
    if (!def) return null;
    // A panel's allowed items (the wallet takes cash and cards) — the kind's `allows`.
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

/** What a stack weighs, contents included: the server's `w` when it sent one (a full wallet
 *  weighs its cash), otherwise weight x amount. */
function stackWeight(d) {
    if (typeof d.w === 'number') return d.w;
    const def = invItemDefs[d.item];
    return ((def && def.weight) || 0) * (d.amount || 1);
}

/** One of a pile, for "would even one fit": its share of the pile's weight when that is known. */
function oneOfPile(d) {
    const n = d.amount || 1;
    if (n <= 1) return d;
    return { item: d.item, amount: 1, w: typeof d.w === 'number' ? d.w / n : undefined };
}

function weightFits(grid, w) {
    return !grid.maxWeight || (grid.weight || 0) + w <= grid.maxWeight + 1e-6;
}

/** Put a stack into a slot the predictions above chose: onto the same item (the only occupied slot
 *  they ever answer), or into the empty one. */
function placeInto(grid, slot, data) {
    const key = String(slot);
    const at = grid.items[key];
    if (at) at.amount = (at.amount || 0) + (data.amount || 0);
    else grid.items[key] = data;
}

/** What Lua needs to address a slot of this grid — client/inventory.lua's nuiStoreAddr. A panel
 *  slot's grid is its panel key, so its id rides along. */
function slotRef(container, slot) {
    const panel = panelByKey(container);
    return { container, slot, containerId: inv.containerId, panelId: panel ? panel.id : undefined };
}

/** Destroy the stack in a slot, from any grid with a context menu. */
function destroyAt(container, slot) {
    const key = String(slot);
    if (container === 'ground') {
        const g = inv.groundItems[key];
        if (!g || !g.groundId) return;
        const opId = beginOp(['ground']);
        delete inv.groundItems[key];
        reindexGroundItems();
        renderInventory();
        emit(opId, 'destroyGroundItem', { groundId: g.groundId });
        return;
    }
    const grid = gridOf(container);
    if (!grid || !grid.items[key]) return;
    const opId = beginOp([grid.view]);
    delete grid.items[key];
    renderInventory();
    emit(opId, 'destroyItem', slotRef(container, slot));
}

/** Split `amount` off a stack into the first free slot of the same grid — on the ground, into a new
 *  pile in the same spot. At least one always stays behind, as on the server. */
function splitAt(container, slot, amount) {
    const key = String(slot);
    if (container === 'ground') {
        const g = inv.groundItems[key];
        if (!g || !g.groundId || (g.amount || 1) <= 1) return;
        const n = Math.max(1, Math.min(amount, g.amount - 1));
        const opId = beginOp(['ground']);
        g.amount -= n;
        // The new pile has no groundId until the server makes it; the ground broadcast that follows
        // redraws Nearby with the real one.
        inv.groundItems[String(Object.keys(inv.groundItems).length + 1)] =
            { item: g.item, amount: n, metadata: g.metadata };
        renderInventory();
        emit(opId, 'splitGroundItem', { groundId: g.groundId, splitAmount: n });
        return;
    }
    const grid = gridOf(container);
    const d = grid && grid.items[key];
    if (!d || (d.amount || 1) <= 1) return;
    const n = Math.max(1, Math.min(amount, d.amount - 1));
    const opId = beginOp([grid.view]);
    // No free slot on this screen: sent anyway, unchanged, and the server answers. It may know of a
    // slot this screen has not been told about yet — and if not, its refusal carries the reason.
    const free = predictFreeSlot(grid, d.item);
    if (free !== null) {
        d.amount -= n;
        grid.items[String(free)] = { item: d.item, amount: n,
            metadata: d.metadata ? structuredClone(d.metadata) : d.metadata };
    }
    renderInventory();
    emit(opId, 'splitItem', Object.assign(slotRef(container, slot), { splitAmount: n }));
}

/** The stores on the right a shift-click from the pockets can go to, NEWEST OPEN FIRST: the stash,
 *  boot or glovebox, and every panel that is not read-only. The ground is not in the list — it is
 *  the fallback, and only when Nearby is showing. */
function quickTargets() {
    const out = [];
    if (inv.containerOpen) out.push({ grid: gridOf('container'), at: inv.containerOpenedAt || 0 });
    for (const p of inv.panels) {
        if (!p.readOnly) out.push({ grid: gridOf(p.key), at: p.openedAt || 0 });
    }
    out.sort((a, b) => b.at - a.at);
    return out.map(t => t.grid).filter(Boolean);
}

/** Nearby is the panel at the top of the right-hand column: on foot, nothing else open there. */
function groundShowing() {
    return !inv.containerOpen && !inv.playerInvOpen && !shop.open;
}

/**
 * SHIFT + CLICK: send a whole stack across — from the pockets to what is open on the right, and from
 * anything on the right into the pockets.
 *
 * FROM THE POCKETS it goes to the NEWEST store open on the right that looks able to take it — the
 * boot you just opened, the wallet you just opened (quickTargets). Only when none can, and Nearby
 * is showing, does it go on the ground. "Looks able" is this screen's knowledge: room, weight, a
 * panel's allowed items. If every store looks full it still goes to the newest, unchanged on
 * screen, so the server can say why.
 *
 * INTO THE POCKETS it goes to the pockets grid, never the accessory strip — the line a drag from
 * the right already draws.
 *
 * Nothing happens in the shop, the admin view, the accessory strip or the ignition: the grids a drag
 * cannot cross either.
 */
function quickMove(slotEl) {
    if (dragItem || shop.open || inv.playerInvOpen) return;
    const container = slotEl.dataset.container;
    const slot = parseInt(slotEl.dataset.slot);
    if (!container || !slot) return;

    if (container === 'player') quickMoveOut(slot);
    else if (container === 'ground') quickPickup(slot);
    else if (container === 'container' || panelByKey(container)) quickMoveIn(container, slot);
}

function quickMoveOut(slot) {
    const key = String(slot);
    const d = inv.state.player && inv.state.player[key];
    if (!d) return;

    const targets = quickTargets();
    let target = null;
    let at = null;
    for (const grid of targets) {
        if (!weightFits(grid, stackWeight(d))) continue;
        const s = predictSlotAccepting(grid, d.item, d.amount || 1, d.metadata);
        if (s !== null) { target = grid; at = s; break; }
    }

    if (!target && groundShowing()) {
        // At your feet — the same drop a drag onto Nearby makes.
        const opId = beginOp(['state', 'ground']);
        delete inv.state.player[key];
        renderInventory();
        emit(opId, 'dropToGround', { fromContainer: 'player', fromSlot: slot, amount: d.amount });
        return;
    }
    if (!target) target = targets[0] || null;
    if (!target) {
        uiNotify({ text: 'There is nowhere to put that', type: 'error', duration: 3000 });
        return;
    }

    const opId = beginOp(['state', target.view]);
    if (at !== null) {
        delete inv.state.player[key];
        placeInto(target, at, d);
    }
    renderInventory();
    emit(opId, 'quickMove', {
        fromContainer: 'player',
        fromSlot:      slot,
        toContainer:   target.container,
        toPanelId:     target.panel ? target.panel.id : undefined,
        containerId:   inv.containerId,
    });
}

function quickMoveIn(container, slot) {
    const src = gridOf(container);
    const key = String(slot);
    const d = src && src.items[key];
    if (!d || (src.panel && src.panel.readOnly)) return;

    const pockets = gridOf('player');
    const at = predictSlotAccepting(pockets, d.item, d.amount || 1, d.metadata);
    const opId = beginOp(['state', src.view]);
    // Pockets full on this screen: sent unchanged, and the server says so (or finds the room).
    if (at !== null) {
        delete src.items[key];
        placeInto(pockets, at, d);
    }
    renderInventory();
    emit(opId, 'quickMove', {
        fromContainer: container,
        fromSlot:      slot,
        fromPanelId:   src.panel ? src.panel.id : undefined,
        toContainer:   'player',
        containerId:   inv.containerId,
    });
}

function quickPickup(slot) {
    const key = String(slot);
    const g = inv.groundItems[key];
    if (!g || !g.groundId) return;

    const pockets = gridOf('player');
    const at = predictSlotAccepting(pockets, g.item, g.amount || 1, g.metadata);
    const opId = beginOp(['state', 'ground']);
    if (at !== null) {
        placeInto(pockets, at, { item: g.item, amount: g.amount, metadata: g.metadata });
        delete inv.groundItems[key];
        reindexGroundItems();
    }
    renderInventory();
    // The pickup honours this slot and falls back to anywhere it fits (pickupGroundItem), so a
    // stale guess still lands.
    emit(opId, 'pickupGroundItem', { groundId: g.groundId, toContainer: 'player', toSlot: at || 1 });
}

// ------------------------------------------
// CONTEXT MENU
// ------------------------------------------
let ctxTarget = null;
let ctxSlotEl = null;
// Where the menu was opened — kept so it can be re-clamped when Split or the Destroy confirm
// swaps in and the menu changes size.
let ctxX = 0;
let ctxY = 0;

/**
 * Keep the menu on screen. It opens below and to the right of the cursor, so a slot near the
 * right or bottom edge — the Nearby column at 1080p — pushed it off the screen. It flips to the
 * cursor's other side, and failing that is pinned inside the edge.
 *
 * MEASURED AFTER IT IS SHOWN: its size is the zoomed .inv-pop's, which only exists once laid
 * out. The positioned box itself carries no zoom, so left/top are plain screen pixels.
 */
function clampMenu(menu, x, y) {
    const r = menu.getBoundingClientRect();
    const pad = 8;
    let left = x;
    let top = y;
    if (left + r.width > window.innerWidth - pad) left = Math.max(pad, x - r.width);
    if (top + r.height > window.innerHeight - pad) top = Math.max(pad, window.innerHeight - r.height - pad);
    menu.style.left = left + 'px';
    menu.style.top = top + 'px';
}

/**
 * An item's contextOptions in the order they go on its menu: those with an `order` first, lowest
 * first, then the rest as they are listed. A tie keeps the listed order. An entry with no action is
 * left out.
 */
function orderedOptions(list) {
    const rank = (o) => (typeof o.order === 'number' && Number.isFinite(o.order) ? o.order : Infinity);
    return list
        .map((opt, i) => ({ opt, i }))
        .filter(({ opt }) => opt && typeof opt.action === 'string' && opt.action !== '')
        .sort((a, b) => {
            const ra = rank(a.opt), rb = rank(b.opt);
            if (ra !== rb) return ra < rb ? -1 : 1;
            return a.i - b.i;
        })
        .map(({ opt }) => opt);
}

/**
 * Is this option on the menu for this item now? Its `when` against the item's metadata (core/item-rules.js),
 * and its `require` as client Lua last answered it (inv.optionGates). The server asks both again.
 */
function optionShown(itemKey, opt, slotData) {
    if (opt.when && !whenMet(opt.when, slotData && slotData.metadata)) return false;
    if (opt.require && inv.optionGates[itemKey + '|' + opt.action] !== true) return false;
    return true;
}

function showContextMenu(x, y, item, slotEl) {
    ctxTarget = item;
    ctxSlotEl = slotEl;
    ctxX = x;
    ctxY = y;
    const menu = document.getElementById('inv-context-menu');
    menu.style.left = x + 'px';
    menu.style.top = y + 'px';

    // Reset: show normal options, hide the split and confirm panels
    document.getElementById('inv-ctx-options').style.display = '';
    document.getElementById('inv-split-panel').style.display = 'none';
    document.getElementById('inv-confirm-panel').style.display = 'none';

    const container = slotEl.dataset.container;

    // YOUR POCKETS GET THE WHOLE MENU; EVERYTHING ELSE GETS THE BASIC TWO.
    //
    // In the pockets (and the accessory strip) an item offers everything it can do — Use, Give,
    // Place, its own options. Anywhere else you can reach — a stash, a boot, a glovebox, a wallet
    // or bag, a resource's panel, the ground — it offers Split and Destroy, and nothing that needs
    // the item on your person. The stack size is read from the slot's own store.
    const pockets = isPocketGrid(container);

    const itemKey = item.dataset.item;
    const def = invItemDefs[itemKey];
    const useOpt = menu.querySelector('[data-action="use"]');
    if (useOpt) {
        useOpt.style.display = (pockets && def && def.usable) ? 'flex' : 'none';
    }

    // Give and Place need the item on your person. Destroy is everywhere this menu opens (the
    // basket has its own menu, and the grids with none are refused in the contextmenu listener),
    // for a developer with developer mode on only (inv.devMode; the server refuses anyone else).
    const giveOpt = menu.querySelector('[data-action="give"]');
    if (giveOpt) giveOpt.style.display = pockets ? 'flex' : 'none';
    const placeOpt = menu.querySelector('[data-action="place"]');
    if (placeOpt) placeOpt.style.display = pockets ? 'flex' : 'none';
    const destroyOpt = menu.querySelector('[data-action="destroy"]');
    if (destroyOpt) destroyOpt.style.display = inv.devMode ? 'flex' : 'none';

    // Show/hide "Split" option — only for stacks > 1. slotDataFor, so the stack is read from the
    // grid it is actually in.
    const slot = parseInt(slotEl.dataset.slot);
    const slotData = slotDataFor(container, slot);
    const amount = slotData ? (slotData.amount || 1) : 1;
    const splitOpt = menu.querySelector('[data-action="split"]');
    if (splitOpt) {
        splitOpt.style.display = amount > 1 ? 'flex' : 'none';
    }

    // THE SUBJECT: what this menu acts on, and how many. A column of verbs with no noun asked the
    // player to remember which slot they had right-clicked.
    document.getElementById('inv-ctx-title').textContent =
        (def ? def.name : itemKey) + (amount > 1 ? ' ×' + amount : '');

    // Build custom context options from item definition.
    //
    // PLAYER-SIDE CONTAINERS, same gate as Use/Give/Place above. The server's
    // customContextAction event validates container against PlayerContainers, so a
    // custom option clicked on a stash/shop/external item was refused anyway — but it was
    // DRAWN, and every click landed in the Event Monitor as a security rejection against a
    // player who just pressed a button the UI showed them.
    //
    // AN OPTION MARKED `anywhere` is the exception: it is offered in every store grid too (a boot, a
    // glovebox, a stash, a bag, a panel; not the ground, the ignition or a shop), and goes to the server
    // as that slot's address (storeContextAction).
    //
    // No icon span: the API accepts `icon` in contextOptions and ignores it. Labels stay
    // textContent, entity-decoded (satellite-supplied strings, same rule as tooltip meta).
    //
    // THE ITEM'S OWN VERBS LEAD, in the order it asks for (orderedOptions), under Use; Give, Place and
    // Split, which every item has, come after them.
    const customContainer = document.getElementById('inv-ctx-custom');
    customContainer.innerHTML = '';
    const elsewhere = !pockets && !!gridOf(container);
    if ((pockets || elsewhere) && def && def.contextOptions && Array.isArray(def.contextOptions)) {
        orderedOptions(def.contextOptions)
            .filter(opt => (pockets || opt.anywhere === true) && optionShown(itemKey, opt, slotData)).forEach(opt => {
            const el = document.createElement('div');
            el.className = 'inv-context-option';
            el.dataset.action = opt.action;
            el.textContent = decodeTextEntities(opt.label) || '';
            customContainer.appendChild(el);
        });
    }

    // Stock management options (container slots only, when in stock mode)
    if (inv.stockMode && container === 'container') {
        const priceInfo = stockPriceOf(slot) || { price: 0, forSale: false };

        // A price is the ITEM's: set here, it is the price on every slot holding it.
        const setPriceEl = document.createElement('div');
        setPriceEl.className = 'inv-context-option';
        setPriceEl.dataset.action = 'stock_set_price';
        setPriceEl.textContent = `Set Price ($${(priceInfo.price || 0).toLocaleString('en-US')} each)`;
        customContainer.appendChild(setPriceEl);

        const toggleEl = document.createElement('div');
        toggleEl.className = 'inv-context-option';
        toggleEl.dataset.action = 'stock_toggle_sale';
        toggleEl.textContent = priceInfo.forSale ? 'Remove From Sale' : 'Mark For Sale';
        customContainer.appendChild(toggleEl);
    }

    // The hairlines only between rows: under the item's own verbs when the shared ones follow, and
    // above Destroy when something sits above it to be set apart from. A single stash item offers
    // Destroy alone, and a rule over one row is a rule over nothing.
    const shows = (o) => !!o && o.style.display !== 'none';
    const ownVerbs = shows(useOpt) || customContainer.children.length > 0;
    const sharedVerbs = [giveOpt, placeOpt, splitOpt].some(shows);
    const keepVerbs = ownVerbs || sharedVerbs;
    const canDestroy = shows(destroyOpt);
    document.getElementById('inv-ctx-divider-own').style.display = ownVerbs && sharedVerbs ? '' : 'none';
    document.getElementById('inv-ctx-divider').style.display = keepVerbs && canDestroy ? '' : 'none';

    // NOTHING TO OFFER (a single item in a stash, with developer mode off): no menu at all, rather than
    // a title over nothing.
    if (!keepVerbs && !canDestroy) {
        ctxTarget = null;
        ctxSlotEl = null;
        return;
    }

    menu.classList.add('visible');
    clampMenu(menu, x, y);
}

// ONE delegated listener for every option, bound once — options are rebuilt per open, and
// the old per-open `.onclick` loop re-walked and re-bound the whole menu each time. The
// static element carries the handler; whatever the rebuild puts inside it just works.
// Give, Split and Destroy keep the menu open: each swaps its own panel in.
document.getElementById('inv-context-menu').addEventListener('click', (e) => {
    const opt = e.target.closest('.inv-context-option');
    if (!opt) return;
    const action = opt.dataset.action;
    handleContextAction(action);
    if (action !== 'give' && action !== 'split' && action !== 'destroy') hideContextMenu();
});

/**
 * DESTROY ASKS FIRST. The confirm replaces the options in place — the way Split's panel does — and names
 * exactly what goes, so the answer is about THIS item and not "whatever I clicked".
 */
function showDestroyConfirm(container, slot) {
    const d = slotDataFor(container, slot);
    if (!d) { hideContextMenu(); return; }
    const def = invItemDefs[d.item];
    const amount = d.amount || 1;
    document.getElementById('inv-confirm-text').textContent =
        'Destroy ' + (def ? def.name : d.item) + (amount > 1 ? ' ×' + amount : '') + '?';

    document.getElementById('inv-ctx-options').style.display = 'none';
    document.getElementById('inv-confirm-panel').style.display = '';
    document.getElementById('inv-confirm-yes').onclick = () => {
        destroyAt(container, slot);
        hideContextMenu();
    };
    document.getElementById('inv-confirm-no').onclick = () => hideContextMenu();

    clampMenu(document.getElementById('inv-context-menu'), ctxX, ctxY);
}

function handleContextAction(action) {
    if (!ctxTarget || !ctxSlotEl) return;

    const container = ctxSlotEl.dataset.container;
    const slot = parseInt(ctxSlotEl.dataset.slot);

    if (action === 'use') {
        nuiCallback('useItem', { container: container, slot: slot });
    } else if (action === 'destroy') {
        showDestroyConfirm(container, slot);
    } else if (action === 'give') {
        const itemKey = ctxTarget.dataset.item;
        const def = invItemDefs[itemKey];
        const slotData = inv.state[container] && inv.state[container][String(slot)];
        const amount = slotData ? slotData.amount : 1;

        nuiCallback('giveItem', {
            container: container,
            slot: slot,
            itemKey: itemKey,
            itemName: def ? def.name : itemKey,
            itemAmount: amount,
        });
        hideContextMenu();
    } else if (action === 'place') {
        // Same payload shape as give: the Lua side closes the inventory and enters
        // placing mode (client/placing.lua). Whole stack — split first for less.
        const itemKey = ctxTarget.dataset.item;
        const def = invItemDefs[itemKey];
        const slotData = inv.state[container] && inv.state[container][String(slot)];
        const amount = slotData ? slotData.amount : 1;

        nuiCallback('placeItem', {
            container: container,
            slot: slot,
            itemKey: itemKey,
            itemName: def ? def.name : itemKey,
            itemAmount: amount,
        });
    } else if (action === 'split') {
        const itemKey = ctxTarget.dataset.item;
        const def = invItemDefs[itemKey];
        const slotData = slotDataFor(container, slot);
        const amount = slotData ? (slotData.amount || 1) : 1;

        if (amount > 1) {
            showSplitPanel('split', container, slot, itemKey, def, amount);
        }
    } else if (action === 'stock_set_price') {
        // Stock management: use NUI callback to trigger Lua UI.Input dialog. Only the price changes: the server
        // keeps the item's for-sale as it has it (keepSale).
        // item: what the menu was opened on — the server refuses if the shelf slot holds something else by the time
        // the typed price lands.
        const priced = inv.containerItems[String(slot)];
        nuiCallback('shopPriceInput', {
            shopId: inv.stockShopId,
            slot: slot,
            item: priced && priced.item ? priced.item : '',
            currentPrice: (stockPriceOf(slot) || {}).price || 0,
        });
    } else if (action === 'stock_toggle_sale') {
        // Stock management: toggle forSale. The price is the ITEM's, so every slot holding the same
        // item shows the change at once (the server prices the item: Shops.setSlotPrice). ONLY the for-sale
        // goes: the server keeps the item's price as it has it (keepPrice).
        const here = inv.containerItems[String(slot)];
        if (!here || !here.item) return;
        const was = stockPriceOf(slot);
        const newForSale = !(was && was.forSale);
        // Shown at once only for an item with a price here: one never priced is refused by the server ("Set a
        // price first"), and showing it listed at $0 would say otherwise.
        if (was) inv.stockPrices[here.item] = { price: was.price || 0, forSale: newForSale };
        nuiCallback('shopSetPrice', {
            shopId: inv.stockShopId,
            slot: slot,
            item: here.item,
            forSale: newForSale,
            keepPrice: true,
        });
        renderContainerGrid();
    } else if (isPocketGrid(container)) {
        // Custom context action from external resource
        nuiCallback('customContextAction', {
            action: action,
            container: container,
            slot: slot,
        });
    } else {
        // An `anywhere` option on a slot that is not in the pockets (showContextMenu).
        nuiCallback('storeContextAction', Object.assign({ action }, slotRef(container, slot)));
    }
}

// ---- the amount panel: Give, Split, and the shop's amounts ----
// ONE BIG NUMBER (Josh, 25 Oct 2026): "60/120" as big as the panel holds, the max dimmed, the slider the
// panel's width, no header (the button says what it does). On a pad an arrow above and below the amount
// says D-pad up / down step it, and held they go faster (splitStep). The arrows are built here, round the
// box index.html has.
const splitBox = document.getElementById('inv-split-value');
const splitPick = document.createElement('span');
splitPick.className = 'inv-split-pick';
splitBox.replaceWith(splitPick);
const splitArrow = (dir) => {
    const a = document.createElement('span');
    a.className = 'inv-split-arrow ' + dir;
    a.innerHTML = '<svg viewBox="0 0 24 14"><path d="' + (dir === 'up' ? 'M3 11.5 12 3l9 8.5' : 'M3 2.5 12 11l9-8.5') + '"/></svg>';
    return a;
};
splitPick.append(splitArrow('up'), splitBox, splitArrow('down'));

/** The box as wide as its digits (tabular: one ch each), and an arrow dimmed at its end. After every change. */
function splitBoxFit() {
    splitBox.style.width = Math.max(1, String(splitBox.value).length) + 'ch';
    const v = +splitBox.value;
    splitPick.querySelector('.up').classList.toggle('end', v >= +splitBox.max);
    splitPick.querySelector('.down').classList.toggle('end', v <= +splitBox.min);
}

/** A new max on the panel: "/max" beside the box, and the number sized once for its widest ("max/max",
 *  measured): 72px, smaller when that would not fit, never under 40. Called once the panel is on screen. */
function splitAmountShow(max) {
    const label = document.getElementById('inv-split-max');
    label.innerHTML = '<span class="inv-split-slash">/</span>' + Number(max);
    const row = splitPick.parentElement;
    const probe = document.createElement('span');
    probe.className = 'inv-split-probe';
    probe.textContent = max + '/' + max;
    row.appendChild(probe);
    const need = probe.offsetWidth * 1.04;
    probe.remove();
    row.style.fontSize = Math.max(40, Math.min(72, Math.floor(72 * row.clientWidth / (need || 1)))) + 'px';
    splitBoxFit();
}

/** D-pad up / down on the amount: one at a time, and held (Lua says how long: controller.lua) faster, the
 *  repeat by ones, then by tens, then by fifties, landing on round numbers. Its arrow lights for the press. */
function splitStep(nav, held) {
    const slider = document.getElementById('inv-split-slider');
    const v = +slider.value, dir = nav === 'up' ? 1 : -1;
    const step = held >= 2600 ? 50 : held >= 1200 ? 10 : 1;
    const next = step === 1 ? v + dir : (dir > 0 ? Math.floor(v / step) + 1 : Math.ceil(v / step) - 1) * step;
    slider.value = String(Math.min(+slider.max, Math.max(+slider.min, next)));
    if (slider.oninput) slider.oninput();       // the number box follows, as dragging it does
    const arrow = splitPick.querySelector('.' + nav);
    arrow.classList.add('on');
    clearTimeout(arrow.offTimer);
    arrow.offTimer = setTimeout(() => arrow.classList.remove('on'), 160);
}

// Reusable split panel for both 'give' and 'split' actions
function showSplitPanel(mode, container, slot, itemKey, def, maxAmount) {
    document.getElementById('inv-ctx-options').style.display = 'none';
    const panel = document.getElementById('inv-split-panel');
    panel.style.display = '';

    const slider   = document.getElementById('inv-split-slider');
    const input    = splitBox;
    const confirmBtn = document.getElementById('inv-split-give');

    confirmBtn.textContent = mode === 'give' ? 'Give' : 'Split';

    const defaultVal = Math.ceil(maxAmount / 2);
    slider.min = 1;
    slider.max = maxAmount;
    slider.value = defaultVal;
    input.min = 1;
    input.max = maxAmount;
    input.value = defaultVal;
    splitAmountShow(maxAmount);

    // Sync slider → input
    slider.oninput = () => {
        input.value = slider.value;
        splitBoxFit();
    };

    // Sync input → slider
    input.oninput = () => {
        let v = parseInt(input.value);
        if (isNaN(v) || v < 1) v = 1;
        if (v > maxAmount) v = maxAmount;
        slider.value = v;
        splitBoxFit();
    };

    // Confirm button
    confirmBtn.onclick = () => {
        let v = parseInt(input.value);
        if (isNaN(v) || v < 1) v = 1;
        if (v > maxAmount) v = maxAmount;

        if (mode === 'give') {
            nuiCallback('giveItem', {
                container: container,
                slot: slot,
                itemKey: itemKey,
                itemName: def ? def.name : itemKey,
                itemAmount: v,
            });
        } else {
            splitAt(container, slot, v);
        }
        hideContextMenu();
    };

    // Cancel button
    document.getElementById('inv-split-cancel').onclick = () => {
        hideContextMenu();
    };

    // The panel is wider than the option list it replaced; keep it on screen.
    clampMenu(document.getElementById('inv-context-menu'), ctxX, ctxY);
}

/**
 * The amount panel on its own, without the item menu's rows: the shop's "Add how many" and a basket
 * line's "Set quantity". The split panel's slider and box, renamed for the job.
 *
 * THE SERVER DOES THE ARITHMETIC, as it does for every shop action: the panel only says what was
 * asked for, and the shopScreenUpdate the server pushes back draws what actually happened. `max`
 * is the slider's reach only — the server holds the real one (stock, stack, basket lines).
 */
function showAmountPanel(x, y, anchorEl, itemEl, title, confirmText, start, max, onConfirm) {
    max = Math.max(1, Math.floor(max) || 1);
    start = Math.min(max, Math.max(1, Math.floor(start) || 1));

    ctxTarget = itemEl;
    ctxSlotEl = anchorEl;
    ctxX = x;
    ctxY = y;
    const menu = document.getElementById('inv-context-menu');
    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
    document.getElementById('inv-ctx-options').style.display = 'none';
    document.getElementById('inv-confirm-panel').style.display = 'none';

    const panel = document.getElementById('inv-split-panel');
    panel.style.display = '';
    const slider = document.getElementById('inv-split-slider');
    const input = splitBox;
    const confirmBtn = document.getElementById('inv-split-give');

    // (`title` is not shown: the panel has no header now, its button says what it does)
    confirmBtn.textContent = confirmText;
    slider.min = 1;
    slider.max = max;
    slider.value = start;
    input.min = 1;
    input.max = max;
    input.value = start;

    const read = () => {
        let v = parseInt(input.value, 10);
        if (isNaN(v) || v < 1) v = 1;
        if (v > max) v = max;
        return v;
    };
    slider.oninput = function() { input.value = slider.value; splitBoxFit(); };
    input.oninput = function() { slider.value = read(); splitBoxFit(); };
    confirmBtn.onclick = function() {
        onConfirm(read());
        hideContextMenu();
    };
    document.getElementById('inv-split-cancel').onclick = function() {
        hideContextMenu();
    };

    menu.classList.add('visible');
    splitAmountShow(max);   // measured: once the panel is on screen
    clampMenu(menu, x, y);
}

/** How many of a shelf entry are left to take: its stock, or (an infinite shelf) a hundred. */
function shelfReach(entry) {
    return (entry.stock !== undefined && entry.stock !== null) ? entry.stock : 100;
}

/** One of a shop tile's item into the basket — the tile's click, and the pad's A. `by` ('mouse' | 'pad')
 *  is a press that keeps adding while it is held. */
function shelfAdd(slotEl, n, by) {
    const entry = slotDataFor('shop', slotEl.dataset.slot);
    if (!entry || shelfReach(entry) <= 0 || !invShopHooks) return;
    invShopHooks.add(entry.item, n, by);
}

/**
 * A basket line's right-click (shops.js): set it to an exact number. As far as the line holds now
 * plus what is left on the shelf; an infinite shelf, a hundred (or the line's own count, if more).
 * Taking a line out is its remove button.
 * @param {{slot: number, item: string, amount: number}} line
 */
export function showBasketQuantity(x, y, line, rowEl) {
    let left = 0;
    let infinite = false;
    for (const key in shop.items) {
        const e = shop.items[key];
        if (e.item !== line.item) continue;
        if (e.stock === undefined || e.stock === null) infinite = true;
        else left += e.stock;
    }
    const have = Number(line.amount) || 1;
    const max = infinite ? Math.max(have, 100) : have + left;
    showAmountPanel(x, y, rowEl, null, 'Set Quantity', 'Set', have, max,
        (n) => { if (invShopHooks) invShopHooks.setLine(line.slot, n); });
}

function hideContextMenu() {
    const menu = document.getElementById('inv-context-menu');
    menu.classList.remove('visible');
    // Reset the split and confirm panel state
    document.getElementById('inv-ctx-options').style.display = '';
    document.getElementById('inv-split-panel').style.display = 'none';
    document.getElementById('inv-confirm-panel').style.display = 'none';
    ctxTarget = null;
    ctxSlotEl = null;
}

// Close context menu when clicking anywhere else
document.addEventListener('mousedown', (e) => {
    const menu = document.getElementById('inv-context-menu');
    if (!menu.contains(e.target)) {
        hideContextMenu();
    }
});

// ------------------------------------------
// TOOLTIP
// ------------------------------------------
function showTooltipForItem(item) {
    const key = item.dataset.item;
    const def = invItemDefs[key];
    if (!def) return;

    document.getElementById('inv-tooltip-name').textContent = def.name;

    // Look up slot metadata
    const container = item.dataset.container;
    const slot = item.dataset.slot;
    let slotData = null;
    if (container === 'ground') {
        slotData = inv.groundItems[String(slot)];
    } else if (container === 'container') {
        slotData = inv.containerItems[String(slot)];
    } else if (container === 'ignition') {
        slotData = inv.ignitionSlot;
    } else if (panelByKey(container)) {
        slotData = panelByKey(container).items[String(slot)];
    } else if (inv.state[container]) {
        slotData = inv.state[container][String(slot)];
    }

    // Total stack weight, CONTENTS INCLUDED.
    //
    // `w` comes from the server, because reading what is inside an item needs that item's panel
    // `read` hook and those only exist server-side. Computing def.weight * amount here reported
    // the weight of an EMPTY wallet however much cash was folded into it — so the tooltip
    // disagreed with the capacity check that actually decided whether you could carry the
    // thing. The fallback keeps older payloads rendering.
    const amount = (slotData && slotData.amount) ? slotData.amount : 1;
    const totalWeight = (slotData && typeof slotData.w === 'number')
        ? slotData.w
        : def.weight * amount;
    // A stack says what one weighs as well as all of them: the figure a player needs
    // to decide how many to move.
    document.getElementById('inv-tooltip-weight').textContent = amount > 1
        ? weightText(totalWeight / amount) + ' each · ' + weightText(totalWeight)
        : weightText(totalWeight);

    // How full the stack is, for anything that stacks (not money: "of 999,999" says nothing).
    const stackRow = document.getElementById('inv-tooltip-stack-row');
    if (stackRow) {
        // (Not on a shop's shelf: a tile there is the item for sale, not a stack anyone holds.)
        const stacks = container !== 'shop' && !!def.stack && (def.maxStack || 1) > 1 && def.type !== 'currency';
        stackRow.style.display = stacks ? '' : 'none';
        if (stacks) {
            document.getElementById('inv-tooltip-stack').textContent =
                amount.toLocaleString('en-US') + ' of ' + Number(def.maxStack).toLocaleString('en-US');
        }
    }

    const meta = slotData && slotData.metadata ? slotData.metadata : null;
    const metaEl = document.getElementById('inv-tooltip-meta');
    metaEl.innerHTML = '';

    // Description
    document.getElementById('inv-tooltip-desc').textContent = def.desc || '';

    // The item's own rows, from its metaFields: each reads the slot's metadata, and a field with a fixed
    // `value` shows that when the slot has none (a weapon's ammo type, the same for every copy).
    if (def.metaFields && Array.isArray(def.metaFields)) {
        def.metaFields.forEach(field => {
            let value = meta ? meta[field.key] : undefined;
            if (value === undefined || value === null) value = field.value;
            if (value === undefined || value === null || value === '') return;

            // Format the value
            if (field.format === 'uppercase') {
                value = String(value).toUpperCase();
            } else if (field.format === 'percent') {
                value = parseFloat(value).toFixed(1) + '%';
            } else if (field.format === 'phone') {
                value = String(value).replace(/[^0-9]/g, '');
                if (value.length === 10) value = value.substr(0,3) + '-' + value.substr(3,3) + '-' + value.substr(6,4);
            } else {
                value = String(value);
            }

            // textContent, NEVER innerHTML: field.label comes from satellite metaFields defs
            // and value is per-slot metadata that travels between players (ground drops,
            // stashes, admin views) — either one carrying markup would run in the browser of
            // every player who hovers the item. Every sibling field in this tooltip already
            // renders through textContent; this row was the one that didn't.
            //
            // The LABEL gets entity decoding (developer-authored, same '&#9654;' contract as
            // context-option icons); the VALUE stays literal — player-typed text displays
            // exactly as typed.
            const row = document.createElement('div');
            row.className = 'inv-tooltip-meta-row';
            const labelEl = document.createElement('span');
            labelEl.textContent = decodeTextEntities(field.label);
            const valueEl = document.createElement('span');
            valueEl.textContent = value;
            row.appendChild(labelEl);
            row.appendChild(valueEl);
            metaEl.appendChild(row);
        });
    }

    document.getElementById('inv-tooltip').classList.add('visible');
}

function positionTooltip(x, y) {
    const tip = document.getElementById('inv-tooltip');
    const offsetX = 16;
    const offsetY = -16;
    let left = x + offsetX;
    let top = y + offsetY;

    const rect = tip.getBoundingClientRect();
    if (left + rect.width > window.innerWidth) {
        left = x - rect.width - offsetX;
    }
    if (top < 0) {
        top = y + 16;
    }
    // The bottom edge too — the tooltip draws at the inventory's scale now (see .inv-pop), so
    // over the last row at 1080p it is tall enough to run off the screen.
    if (top + rect.height > window.innerHeight - 8) {
        top = Math.max(8, window.innerHeight - rect.height - 8);
    }

    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
}

function hideTooltip() {
    document.getElementById('inv-tooltip').classList.remove('visible');
}


// ========================================
// CONTROLLER — a pad works the inventory
//
// What it does:
//   - the selected slot's outline lights (.pad-focus, css/inventory.css);
//   - A picks the item up and it rides the highlight; A again places it there — a move, a stack or
//     a swap, whatever a drag there would do. B puts it back;
//   - X opens the item's menu (Use, Give, Split, Destroy...), the D-pad walks it and A chooses;
//   - RB held + A is a shift-click: the fast transfer across;
//   - the D-pad walks the slots one at a time; the LEFT STICK drives a free circle, Destiny 2's menu
//     cursor: it goes anywhere on the screen and only slows over an item — never pulled onto a grid
//     (slowing over every slot makes it run along the gaps). The D-pad puts the circle away; the stick brings
//     it back where the highlight is.
//   - carrying with the D-pad, the item sits in the highlighted slot lifted a little up and left,
//     covering what is there; with the circle, it rides the circle as it rides a mouse;
//   - the item's card: with the D-pad at the slot's bottom right, with the circle following it as it
//     follows a mouse; on a pad it ends with the buttons ("X Actions", "A Select"), and the item menu
//     with its own.
//   Beside those, what a mouse already does: carrying, X drops one (a right-click mid-drag), and the
//   right stick scrolls a long list (the panel under the circle or the highlight).
//
// THE PAD DOES WHAT THE MOUSE DOES, THROUGH THE MOUSE'S OWN CODE. A is the mousedown of a click,
// RB + A the same with Shift, X the right-click, and A while carrying the mouseup that ends a drag —
// each a MouseEvent dispatched at the highlighted slot. Every rule a drag follows (stacks, swaps,
// typed accessory slots, panels, the shop and basket, the ground, the server's refusals) is then the
// one rule, never a second copy beside it to drift.
//
// WHERE THE CIRCLE IS, THE SCREEN SAYS: what is under it is a real hit test at its point. A slot's
// measured position is used only to place things (the circle's start, the carried item, the menu),
// corrected by padZoom for FiveM's Chromium 103, whose CSS zoom can measure in other pixels. The D-pad
// names its slot to the drag outright (padAim), so a move never depends on that correction.
// ========================================

/** What the pad can land on: every slot (a shop's cards are slots too), the shop's buttons — its
 *  category chips and sort, the basket lines' minus / plus / remove, Cash / Bank and Buy, Edit
 *  Shelf's (`.inv-pad-btn`, each with an id so the highlight survives a redraw) — the bank account
 *  picker, and Edit Shelf's tab pickers (A steps a picker to its next choice: padActivate). */
const PAD_TARGETS = '#inv-overlay .inv-slot, #inv-overlay .inv-pad-btn, #inv-basket-account, #inv-overlay .inv-edit-pick';
const PAD_CURSOR_SPEED = 1.3;    // the circle at a full push: screen heights a second
const PAD_CURSOR_CURVE = 1.6;    // a light push is slow and exact: speed grows as push ^ this
const PAD_CURSOR_SLOW  = 0.45;   // over an item (or a menu row, a button) it slows to this share
const PAD_SCROLL       = 1100;   // the right stick at a full push scrolls a list this many px a second

const pad = {
    focus: null,        // the highlighted target as a key (padKeyOf): it outlives a grid's rebuild
    cursor: false,      // the circle is up (the stick moved it; the D-pad puts it away)
    cx: 0, cy: 0,       // where the circle is, in screen pixels
    over: null,         // the target (or menu row) under the circle, or null
    stick: { x: 0, y: 0, ry: 0 },
    raf: 0, last: 0,    // the circle's frame loop, only while something moves
    zoom: 0,            // padZoom, measured once per open (0: not yet)
    menuEl: null,       // the item menu's row the pad is on
    carryEl: null,      // the carried item drawn over the highlighted slot (padCarryDraw), D-pad only
    carryHost: null,    // the slot it is over
    carrying: false,    // the drag under way was picked up by the pad (a mouse drag is left alone)
};

const padCursorEl = document.createElement('div');
padCursorEl.id = 'inv-pad-cursor';
padCursorEl.innerHTML = '<div class="inv-pad-ring"></div>';
document.body.appendChild(padCursorEl);

// THE PAD OR THE MOUSE, NEVER BOTH. A pad takes the cursor away (client/focus.lua), but the mouse stays
// where it was left, and the browser kept hovering whatever moved under it and sending its moves: a hover
// wash on a slot the pad was not on, the drop pill flicking between the pad's slot and the mouse's, the
// card shown for the wrong one. While a pad drives the inventory, a clear sheet over the screen takes the
// mouse's hover (css #inv-pad-shield), and the mouse's events are dropped before anything here hears them.
// The pad's own are made by this page (padMouse, padAimAt), never trusted, so they pass. Moving the mouse
// turns the device back to the keyboard (client/controller.lua), and the sheet goes with data-input.
const padShield = document.createElement('div');
padShield.id = 'inv-pad-shield';
document.body.appendChild(padShield);

function padOwnsInput(e) {
    return e.isTrusted && padShield.classList.contains('on') && document.documentElement.dataset.input === 'pad';
}

for (const type of ['mousedown', 'mouseup', 'mousemove', 'mouseover', 'mouseout', 'click', 'dblclick', 'contextmenu']) {
    window.addEventListener(type, (e) => {
        if (!padOwnsInput(e)) return;
        e.stopImmediatePropagation();
        if (type === 'mousedown' || type === 'contextmenu') e.preventDefault();
    }, true);
}

/** What is at a screen point, under the sheet: the circle's hit tests and a drag's target. */
function hitAt(x, y) {
    for (const n of document.elementsFromPoint(x, y)) if (n !== padShield) return n;
    return null;
}

/** A row of button pictures and words, for the card's and the item menu's pad help. A hint's button
 *  may be a list, for a button held under another: [['rb', 'a'], 'Quick move']. */
function padHintRow(hints) {
    const row = document.createElement('div');
    row.className = 'inv-pad-hints';
    for (const [button, label] of hints) {
        const item = document.createElement('span');
        item.className = 'inv-pad-hint';
        for (const name of (Array.isArray(button) ? button : [button])) {
            const img = padGlyph(name, 'inv-pad-hint-glyph');
            if (img) item.appendChild(img);
        }
        item.appendChild(document.createTextNode(label));
        row.appendChild(item);
    }
    return row;
}

// The item card's pad help, at its foot (shown on a pad only: css/inventory.css). RB + A shows only
// where a quick move does something (padTooltip).
const padCardHints = padHintRow([['x', 'Actions'], ['a', 'Select'], [['rb', 'a'], 'Quick move']]);
const padCardQuick = padCardHints.lastChild;
document.querySelector('#inv-tooltip .inv-pop').appendChild(padCardHints);
// A shop's tile does something else with the same buttons (padTooltip shows one row or the other): A
// adds one, and held keeps adding, faster.
const padCardHintsShop = padHintRow([['a', 'Add'], ['a', 'Hold: add faster']]);
padCardHintsShop.style.display = 'none';
document.querySelector('#inv-tooltip .inv-pop').appendChild(padCardHintsShop);
// The item menu's: drawn for what it shows (padMenuHintsDraw).
let padMenuHintsEl = padHintRow([]);
document.querySelector('#inv-context-menu .inv-pop').appendChild(padMenuHintsEl);

function padKeyOf(el) {
    return el.classList.contains('inv-slot')
        ? 'slot\u0000' + el.dataset.container + '\u0000' + el.dataset.slot
        : '#' + el.id;
}

/** The highlighted element now — looked up by its key, as a grid rebuild replaces the slot's element. */
function padFocusEl() {
    const k = pad.focus;
    if (!k) return null;
    if (k[0] === '#') return document.getElementById(k.slice(1));
    const parts = k.split('\u0000');
    return document.querySelector('#inv-overlay .inv-slot[data-container="' + CSS.escape(parts[1])
        + '"][data-slot="' + CSS.escape(parts[2]) + '"]');
}

/** How a measured position inside the inventory becomes a screen point: 1 where they agree, the
 *  inventory's zoom where FiveM's Chromium 103 measures in unzoomed pixels. Once per open.
 *
 *  MEASURED ON A PROBE OF KNOWN SIZE (hit-testing a big slot can pass in both cases): a 100px box
 *  inside the zoomed container is measured: about 100 × zoom wide where measurements are on
 *  the screen, about 100 where they are unzoomed. */
function padZoom() {
    if (pad.zoom) return pad.zoom;
    const host = document.querySelector('#inv-overlay .inv-container');
    if (!host || !host.getClientRects().length) return 1;
    let k = 1;
    for (let n = host; n; n = n.parentElement) {
        const z = parseFloat(getComputedStyle(n).zoom);
        if (z > 0) k *= z;
    }
    if (Math.abs(k - 1) < 0.01) { pad.zoom = 1; return 1; }
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;left:0;top:0;width:100px;height:1px;visibility:hidden;pointer-events:none';
    host.appendChild(probe);
    const w = probe.getBoundingClientRect().width;
    probe.remove();
    pad.zoom = Math.abs(w - 100 * k) < Math.abs(w - 100) ? 1 : k;
    return pad.zoom;
}

/** An element's middle and edges as screen points. The item menu is outside the zoom. */
function padPoint(el) {
    const r = el.getBoundingClientRect();
    const z = el.closest('#inv-overlay') ? padZoom() : 1;
    return { x: (r.left + r.right) / 2 * z, y: (r.top + r.bottom) / 2 * z,
             left: r.left * z, right: r.right * z, top: r.top * z, bottom: r.bottom * z };
}

/** Everything the pad can land on that is on the screen now (a hidden panel's slots are not). */
function padTargets() {
    const out = [];
    for (const el of document.querySelectorAll(PAD_TARGETS)) {
        if (el.getClientRects().length) out.push(el);
    }
    return out;
}

/** The gap between two spans, 0 when they overlap. */
function padGap(a1, a2, b1, b2) {
    return Math.max(0, Math.max(a1, b1) - Math.min(a2, b2));
}

/** How good `b` is as the next stop from `a` going `dir`: the distance that way, then (three times
 *  over) how far it sits off the line — so the same row or column wins, and across a gap the
 *  nearest panel's facing slot does. Infinity: not that way at all. */
function padScore(dir, a, b) {
    const acx = (a.left + a.right) / 2, acy = (a.top + a.bottom) / 2;
    const bcx = (b.left + b.right) / 2, bcy = (b.top + b.bottom) / 2;
    let along, off;
    if (dir === 'right') {
        if (bcx <= acx + 1) return Infinity;
        along = Math.max(0, b.left - a.right); off = padGap(a.top, a.bottom, b.top, b.bottom);
    } else if (dir === 'left') {
        if (bcx >= acx - 1) return Infinity;
        along = Math.max(0, a.left - b.right); off = padGap(a.top, a.bottom, b.top, b.bottom);
    } else if (dir === 'down') {
        if (bcy <= acy + 1) return Infinity;
        along = Math.max(0, b.top - a.bottom); off = padGap(a.left, a.right, b.left, b.right);
    } else {
        if (bcy >= acy - 1) return Infinity;
        along = Math.max(0, a.top - b.bottom); off = padGap(a.left, a.right, b.left, b.right);
    }
    return along + off * 3 + Math.hypot(bcx - acx, bcy - acy) * 0.01;
}

/** Where the highlight starts: the first pocket slot — in a shop, the first thing on the shelf. */
function padHome() {
    if (shop.open) {
        return document.querySelector('#inv-shop-grid .inv-slot[data-container="shop"]') || padTargets()[0] || null;
    }
    return document.querySelector('#inv-player-grid .inv-slot') || padTargets()[0] || null;
}

/** Light `el` (null: nothing) and say what it holds. `opts.scroll`: bring it into its list's view.
 *  `opts.at`: the circle's point (the carried item and the card follow it there). */
function padSetFocus(el, opts) {
    opts = opts || {};
    const prev = padFocusEl();
    if (prev && prev !== el) prev.classList.remove('pad-focus');
    pad.focus = el ? padKeyOf(el) : null;
    if (!el) { if (!dragItem) hideTooltip(); padCarryDraw(); return; }
    el.classList.add('pad-focus');
    if (opts.scroll) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    if (dragItem) {
        if (!opts.at) {
            const p = padPoint(el);
            padAimAt(el, p.x, p.y, 'mousemove');   // the drop target's pill and refuse edge, as a drag shows them
        }
        padCarryDraw();
        return;
    }
    padTooltip(el, opts.at);
}

/** The item's card, as hovering shows it: with the circle at its point, as a mouse's; with the D-pad at
 *  the slot's bottom right, off the item's picture. */
function padTooltip(el, at) {
    const item = el.classList.contains('inv-slot') && el.querySelector('[data-item]');
    if (!item || padMenuKind()) { hideTooltip(); return; }
    showTooltipForItem(item);
    const onShelf = el.dataset.container === 'shop';
    padCardHints.style.display = onShelf ? 'none' : '';
    padCardHintsShop.style.display = onShelf ? '' : 'none';
    padCardQuick.classList.toggle('off', !padQuickMoves(el.dataset.container));
    if (at) { positionTooltip(at.x, at.y); return; }
    const p = padPoint(el);
    positionTooltip(p.right - 24, p.bottom + 8);   // its top left just inside the slot's bottom-right corner
}

/** Does RB + A (a shift-click, quickMove) do anything from this grid? The pockets send across, the
 *  right-hand stores and the ground into the pockets; never in a shop or the admin view, nor from the
 *  accessory strip, the ignition or a read-only panel — quickMove's own rules. */
function padQuickMoves(container) {
    if (shop.open || inv.playerInvOpen) return false;
    if (container === 'player' || container === 'ground' || container === 'container') return true;
    const panel = panelByKey(container);
    return !!panel && !panel.readOnly;
}

/** Carrying with the D-pad: the item sits on the highlighted slot, lifted a little up and to the left,
 *  on a tile of its own that covers what is in the slot. The free copy the mouse drags (the ghost) waits
 *  hidden, and comes back when the circle is up (it rides the circle).
 *
 *  THE TILE IS IN .inv-wrapper, LAID OVER THE SLOT, NOT INSIDE IT. Every grid is in a scroll box, and the
 *  lifted tile hung out of its slot over that box's edge on the top row and the left column, where the
 *  box cut it off. The wrapper is inside the zoom like the slot, so the tile is drawn at the slot's size;
 *  padCarryPlace puts it there. */
function padCarryDraw() {
    if (!dragItem) pad.carrying = false;
    const slotCarry = !!dragItem && pad.carrying && !pad.cursor;
    document.body.classList.toggle('inv-pad-carry', slotCarry);
    const focus = slotCarry ? padFocusEl() : null;
    const host = focus && focus.classList.contains('inv-slot') ? focus : null;
    if (pad.carryHost && pad.carryHost !== host) pad.carryHost.classList.remove('pad-carry-host');
    pad.carryHost = host;
    if (!host) {
        if (pad.carryEl) { pad.carryEl.remove(); pad.carryEl = null; }
        return;
    }
    host.classList.add('pad-carry-host');
    if (!pad.carryEl) {
        const el = document.createElement('div');
        el.className = 'inv-pad-carried';
        const art = dragItem.querySelector('img');
        if (art) {
            const img = document.createElement('img');
            img.src = art.currentSrc || art.src;
            img.alt = '';
            img.draggable = false;
            el.appendChild(img);
        }
        // The slot's own count, as the slot draws it (money stays money).
        const count = dragSourceSlot && dragSourceSlot.querySelector('.inv-slot-amount');
        if (count && count.textContent) el.appendChild(count.cloneNode(true));
        pad.carryEl = el;
    }
    const wrap = document.querySelector('#inv-overlay .inv-wrapper');
    if (pad.carryEl.parentElement !== wrap) wrap.appendChild(pad.carryEl);
    padCarryPlace(host);
}

/** The carried tile over its slot, in the wrapper's own pixels. Both are measured, and the wrapper's
 *  measured width over its layout width turns a measured distance into those pixels, whichever FiveM's
 *  browser measures in (padZoom: Chromium 103 measures inside the zoom unzoomed). Hidden while the right
 *  stick has scrolled its slot out of its list. */
function padCarryPlace(host) {
    const el = pad.carryEl;
    const wrap = el && el.parentElement;
    if (!wrap || !host.isConnected) return;
    const w = wrap.getBoundingClientRect();
    const r = host.getBoundingClientRect();
    const k = wrap.offsetWidth ? w.width / wrap.offsetWidth : 1;
    el.style.left = (r.left - w.left) / k + 'px';
    el.style.top = (r.top - w.top) / k + 'px';
    el.style.width = r.width / k + 'px';
    el.style.height = r.height / k + 'px';
    el.classList.toggle('wide', !!host.closest('.inv-col-center'));
    const list = host.closest('#inv-panel-stack') || host.closest('.inv-col-center .inv-slots-grid');
    const s = list && list.getBoundingClientRect();
    el.style.visibility = !s || (r.top >= s.top - 1 && r.bottom <= s.bottom + 1) ? '' : 'hidden';
}

// A list scrolled under a carried tile (the right stick, or a step bringing a slot into view): the tile
// follows its slot. Scrolls do not bubble; the overlay hears them on the way down.
document.getElementById('inv-overlay').addEventListener('scroll', () => {
    if (pad.carryEl && pad.carryHost) padCarryPlace(pad.carryHost);
}, true);

/** One D-pad step from the highlight to the best target that way (padScore). */
function padStep(dir) {
    const from = padFocusEl();
    if (!from || !from.getClientRects().length) { padSetFocus(padHome(), { scroll: true }); return; }
    const a = from.getBoundingClientRect();
    let best = null, bestScore = Infinity;
    for (const el of padTargets()) {
        if (el === from) continue;
        const s = padScore(dir, a, el.getBoundingClientRect());
        if (s < bestScore) { bestScore = s; best = el; }
    }
    if (best) padSetFocus(best, { scroll: true });
}

/** A mouse event at `el`, as a click there makes it (the slot listeners take it from here). */
function padMouse(el, type, p, extra) {
    el.dispatchEvent(new MouseEvent(type, Object.assign({
        bubbles: true, cancelable: true, view: window,
        button: type === 'contextmenu' ? 2 : 0, clientX: p.x, clientY: p.y,
    }, extra || null)));
}

/** The drag's own mousemove (the carried item rides along) or mouseup (it lands) at a screen point,
 *  pointed at `slot` (padAim) when the pad knows which slot it means. */
function padAimAt(slot, x, y, type) {
    padAim = slot;
    try {
        document.dispatchEvent(new MouseEvent(type, {
            bubbles: true, cancelable: true, view: window, button: 0, clientX: x, clientY: y,
        }));
    } finally {
        padAim = null;
    }
}

/** A while carrying: put it down on `el` — or back where it came from, if that is where it is. */
function padPlace(el, at) {
    if (!el.classList.contains('inv-slot')) return;
    if (dragSourceSlot && padKeyOf(el) === padKeyOf(dragSourceSlot)) { cancelDrag(); padSoon(); return; }
    padAimAt(el, at.x, at.y, 'mouseup');
    padSoon();
}

/** After a move has redrawn the grids: the highlight on its slot again, the carried item (or none), and
 *  the card. */
function padSoon() {
    setTimeout(() => {
        if (!inv.open) return;
        padCarryDraw();
        const el = padFocusEl();
        if (!el) return;
        el.classList.add('pad-focus');
        if (!dragItem) padTooltip(el, pad.cursor ? { x: pad.cx, y: pad.cy } : null);
    }, 0);
}

/** A on one of the shop's buttons (a tab, minus / plus / remove, Cash / Bank, Buy) presses it; on the
 *  bank account picker it steps to the next account. */
function padActivate(el) {
    if (el.tagName === 'SELECT') {
        if (!el.options.length) return;
        el.selectedIndex = (el.selectedIndex + 1) % el.options.length;
        el.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (!el.disabled) {
        el.click();
    }
}

// ---- the item menu ----

/** Which part of the item menu is up: its rows, Split's amount, Destroy's question — or none. */
function padMenuKind() {
    const menu = document.getElementById('inv-context-menu');
    if (!menu || !menu.classList.contains('visible')) return null;
    if (document.getElementById('inv-split-panel').style.display !== 'none') return 'split';
    if (document.getElementById('inv-confirm-panel').style.display !== 'none') return 'confirm';
    return 'options';
}

function padMenuRows() {
    return Array.from(document.querySelectorAll('#inv-ctx-options .inv-context-option'))
        .filter((o) => o.getClientRects().length);
}

function padMenuFocus(row) {
    if (pad.menuEl && pad.menuEl !== row) pad.menuEl.classList.remove('pad-focus');
    pad.menuEl = row || null;
    if (row) row.classList.add('pad-focus');
}

/** The item menu's pad help, at its foot, for what it shows now (on a pad only: css/inventory.css). */
function padMenuHintsDraw() {
    const kind = padMenuKind();
    const hints = kind === 'split'
        ? [['dpad', 'Amount'], ['a', document.getElementById('inv-split-give').textContent || 'OK'], ['b', 'Cancel']]
        : kind === 'confirm' ? [['y', 'Destroy'], ['b', 'Cancel']]
        : [['a', 'Select'], ['b', 'Back']];
    const row = padHintRow(hints);
    padMenuHintsEl.replaceWith(row);
    padMenuHintsEl = row;
}

function padMenuNav(kind, nav, mods) {
    padMenuNavBody(kind, nav, mods || {});
    if (padMenuKind()) padMenuHintsDraw();
    else { padMenuFocus(null); padSoon(); }
}

function padMenuNavBody(kind, nav, mods) {
    if (kind === 'split') {
        if (nav === 'up' || nav === 'down') {
            splitStep(nav, mods.held || 0);             // the arrows: held, faster
        } else if (nav === 'left' || nav === 'right') {
            const slider = document.getElementById('inv-split-slider');
            const by = nav === 'right' ? 1 : -1;
            slider.value = String(Math.min(+slider.max, Math.max(+slider.min, +slider.value + by)));
            if (slider.oninput) slider.oninput();       // the number box follows, as dragging it does
        } else if (nav === 'select') {
            document.getElementById('inv-split-give').click();
        } else if (nav === 'back') {
            document.getElementById('inv-split-cancel').click();
        }
        return;
    }
    // Destroy's question takes Y, not A: A is the button that opened it, so a mashed A would destroy
    // the stack. A here does nothing; Y is a deliberate second button.
    if (kind === 'confirm') {
        if (nav === 'buttonY') document.getElementById('inv-confirm-yes').click();
        else if (nav === 'back') document.getElementById('inv-confirm-no').click();
        return;
    }
    const rows = padMenuRows();
    let i = rows.indexOf(pad.menuEl);
    if (nav === 'up' || nav === 'down') {
        if (!rows.length) return;
        // Stops at the ends, no wrap: Up from the first row wrapped onto Destroy, the last.
        i = i < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, i + (nav === 'down' ? 1 : -1)));
        padMenuFocus(rows[i]);
    } else if (nav === 'select') {
        if (i >= 0) rows[i].click();     // the menu's own click: an option, or Split / Destroy's panel in its place
    } else if (nav === 'back' || nav === 'buttonX') {
        hideContextMenu();
    }
}

// ---- the circle ----

function padShowCursor() {
    if (pad.cursor) return;
    const el = padFocusEl();
    const p = el && el.getClientRects().length ? padPoint(el) : { x: innerWidth / 2, y: innerHeight / 2 };
    pad.cx = p.x;
    pad.cy = p.y;
    pad.cursor = true;
    padCursorEl.classList.add('on');
    padCarryDraw();   // carrying: the item leaves the slot and rides the circle
}

function padHideCursor() {
    if (!pad.cursor) return;
    pad.cursor = false;
    pad.over = null;
    padCursorEl.classList.remove('on', 'over');
    padCarryDraw();
}

/** Does the circle slow here: over an item, a menu row or a button — never over an empty slot or a
 *  gap, so it crosses a grid at one speed. */
function padSlowsOver(el) {
    if (!el) return false;
    return el.classList.contains('inv-slot') ? !!el.querySelector('[data-item]') : true;
}

/** What is under the circle becomes the highlight (or, with the menu up, its row). */
function padHover() {
    const hit = hitAt(pad.cx, pad.cy);
    if (padMenuKind() === 'options') {
        const row = hit && hit.closest('.inv-context-option');
        pad.over = row && padMenuRows().indexOf(row) >= 0 ? row : null;
        if (pad.over) padMenuFocus(pad.over);
        return;
    }
    const target = hit && hit.closest(PAD_TARGETS);
    pad.over = target || null;
    if (!target) { if (pad.focus) padSetFocus(null); return; }
    if (padKeyOf(target) !== pad.focus) padSetFocus(target, { at: { x: pad.cx, y: pad.cy } });
}

/** Scroll the list under the circle (or the highlight's) by `dy` pixels. */
function padScrollBy(dy) {
    let n = pad.cursor ? hitAt(pad.cx, pad.cy) : padFocusEl();
    for (; n && n !== document.body; n = n.parentElement) {
        const s = getComputedStyle(n);
        if ((s.overflowY === 'auto' || s.overflowY === 'scroll') && n.scrollHeight > n.clientHeight) {
            n.scrollTop += dy;
            return;
        }
    }
}

function padRun() {
    if (pad.raf) return;
    pad.last = performance.now();
    pad.raf = requestAnimationFrame(padFrame);
}

/** One frame of the circle. It runs only while a stick is pushed: let go, the circle stays exactly
 *  where it is (no settling onto a slot). */
function padFrame(now) {
    pad.raf = 0;
    if (!inv.open) return;
    const dt = Math.min(0.05, Math.max(0, (now - pad.last) / 1000));
    pad.last = now;
    const { x, y, ry } = pad.stick;
    const push = Math.min(1, Math.hypot(x, y));
    let moved = false;

    if (push > 0) {
        padShowCursor();
        // times the player's own "Menu cursor speed" (Settings → Server, prefs.js), read each frame
        const speed = PAD_CURSOR_SPEED * (pref('pad.cursorSpeed', 100) / 100) * innerHeight * Math.pow(push, PAD_CURSOR_CURVE)
            * (padSlowsOver(pad.over) ? PAD_CURSOR_SLOW : 1);
        pad.cx = Math.min(innerWidth - 1, Math.max(0, pad.cx + x / push * speed * dt));
        pad.cy = Math.min(innerHeight - 1, Math.max(0, pad.cy - y / push * speed * dt));   // stick up is +y
        moved = true;
    }
    if (ry) {
        padScrollBy(-ry * PAD_SCROLL * dt);   // stick up: up the list
        moved = true;
    }

    if (moved && pad.cursor) {
        padHover();
        padCursorEl.style.transform = 'translate3d(' + pad.cx + 'px,' + pad.cy + 'px,0)';
        padCursorEl.classList.toggle('over', padSlowsOver(pad.over));
        if (dragItem) {
            const slot = pad.over && pad.over.classList.contains('inv-slot') ? pad.over : null;
            padAimAt(slot, pad.cx, pad.cy, 'mousemove');
        } else if (pad.over && document.getElementById('inv-tooltip').classList.contains('visible')) {
            positionTooltip(pad.cx, pad.cy);   // the card follows the circle, as it follows a mouse
        }
    }
    if (moved) padRun();
}

function padAnalog(a) {
    // Whether A is down: a held A on a shop tile or basket button keeps adding until it is let go.
    if (invShopHooks && invShopHooks.padA) invShopHooks.padA(a.a === true);
    pad.stick = { x: +a.x || 0, y: +a.y || 0, ry: +a.ry || 0 };
    if (inv.open && (pad.stick.x || pad.stick.y || pad.stick.ry)) padRun();
}

// ---- the presses ----

function padNav(nav, mods) {
    if (!inv.open) return;
    const menu = padMenuKind();
    if (menu) { padMenuNav(menu, nav, mods); return; }

    if (nav === 'up' || nav === 'down' || nav === 'left' || nav === 'right') {
        padHideCursor();
        padStep(nav);
        return;
    }

    const el = padFocusEl();
    const at = el && (pad.cursor ? { x: pad.cx, y: pad.cy } : padPoint(el));
    if (nav === 'select') {
        if (!el) return;
        if (dragItem) { padPlace(el, at); return; }
        if (!el.classList.contains('inv-slot')) {
            padActivate(el);
            // A basket line's minus or plus keeps going while A stays down (shops.js).
            if (shop.open && invShopHooks && invShopHooks.padPressed) invShopHooks.padPressed(el);
            return;
        }
        if (!el.querySelector('[data-item]')) return;
        // A picks it up (the click that starts a drag); RB + A is the shift-click, sent across.
        padMouse(el, 'mousedown', at, { shiftKey: mods && mods.rb === true });
        pad.carrying = !!dragItem;
        if (dragItem) padCarryDraw(); else padSoon();
        return;
    }
    if (nav === 'buttonX') {
        if (!el || !el.classList.contains('inv-slot')) return;
        // A shop's tile has nothing on X: A held adds faster.
        if (el.dataset.container === 'shop') return;
        // The right-click: carrying, it drops one there; otherwise the item's menu, on its first row.
        const p = pad.cursor || dragItem ? at : { x: padPoint(el).right - 6, y: at.y };
        padMouse(el, 'contextmenu', p);
        if (dragItem) { padSoon(); return; }
        hideTooltip();
        if (padMenuKind() === 'options') padMenuFocus(padMenuRows()[0]);
        if (padMenuKind()) padMenuHintsDraw();
        return;
    }
    if (nav === 'back') {
        if (dragItem) { cancelDrag(); padSoon(); } else closeInventory();
    }
}

/* ---- the legend at the foot of the right column, on a pad ----
   Every button the inventory reads, in index.html's #inv-legend. A, X and B do something else while an
   item is carried, so their words follow (as the strip's hints did); RB + A does nothing then and keeps
   its place empty; an item menu says its own buttons at its foot, so the capsule dims under it. */
const legendEl = document.getElementById('inv-legend');
const legendWords = {};
for (const w of legendEl.querySelectorAll('[data-word]')) legendWords[w.dataset.word] = w;
const legendQuick = legendEl.querySelector('[data-when="free"]');
const LEGEND_WORDS = {
    free:     { a: 'Select', x: 'Actions',     b: 'Close' },
    carrying: { a: 'Place',  x: 'Place one',   b: 'Put back' },
    // A shop's tile adds to the basket, and held adds faster; X does nothing there, so its place is
    // taken by "Hold A".
    shop:     { a: 'Add',    x: 'Actions',     b: 'Close' },
};
const legendX = legendEl.querySelector('[data-when="noshop"]');
const legendHold = legendEl.querySelector('[data-when="shop"]');

function padLegendDraw() {
    const shopping = shop.open && !dragItem;
    const words = LEGEND_WORDS[dragItem ? 'carrying' : (shop.open ? 'shop' : 'free')];
    // Only a real change is written: a text write is a childList change, which the slot observer
    // below would answer by putting the highlight back.
    for (const k of Object.keys(words)) {
        const el = legendWords[k];
        if (el && el.textContent !== words[k]) el.textContent = words[k];
    }
    if (legendQuick) legendQuick.classList.toggle('off', !!dragItem || shop.open);
    if (legendX) legendX.classList.toggle('off', shopping);
    if (legendHold) legendHold.classList.toggle('off', !shopping);
    legendEl.classList.toggle('inv-legend-muted', !!padMenuKind());
}

/** The strip at the bottom (controller.js) says nothing in the inventory now: the legend above holds
 *  every button. It is asked after every press and twice a second, which is the beat the legend's
 *  words are kept on. */
function padHints() {
    padLegendDraw();
    return [];
}

/** A fresh start each open: the highlight on the first pocket slot, no circle, the zoom measured anew. */
function padReset(open) {
    if (pad.raf) cancelAnimationFrame(pad.raf);
    pad.raf = 0;
    padHideCursor();
    const el = padFocusEl();
    if (el) el.classList.remove('pad-focus');
    padMenuFocus(null);
    pad.stick = { x: 0, y: 0, ry: 0 };
    pad.zoom = 0;
    padShield.classList.toggle('on', !!open);   // the mouse's hover and events, held off while a pad drives
    // A shop opens with the shelf where the pockets were: the highlight starts on its first tile.
    pad.focus = open ? (shop.open ? 'slot\u0000shop\u00001' : 'slot\u0000player\u00001') : null;
    padCarryDraw();   // nothing carried in a closed (or fresh) inventory
    padLegendDraw();  // and the legend's words back to an empty hand
    const home = open && padFocusEl();
    if (home) home.classList.add('pad-focus');
}

// A grid redraw makes new slot elements: the highlight goes back on its slot's new one, and a carried
// item into it. (Putting the carried item in is itself a change here; it is already in place then.)
new MutationObserver(() => {
    if (!pad.focus) return;
    const el = padFocusEl();
    if (el) el.classList.add('pad-focus');
    if (pad.carryEl || (dragItem && pad.carrying && !pad.cursor)) padCarryDraw();
}).observe(document.getElementById('inv-overlay'), { childList: true, subtree: true });

// The inbound message protocol registers in core/inv-wire.js now; the key scope stays with
// the renderer because Escape/F2 are INPUT, and input belongs to whoever owns the DOM.
//
// A CUSTOM RENDERER IS SEATED (Config.InventoryRenderer): Escape and F2 still close, and every other
// key, the controller's presses and stick, and the hint strip go to ITS onKey / onNav / onAnalog /
// padHints, when it has them (docs/nui-inventory.md). Ours drive this file's grid, which is not on
// screen then.
const custom = () => (defaultSeated() ? null : getRenderer());
NuiRouter.registerKeyScope({
    name: 'inventory', priority: 130,
    isOpen: () => inv.open,
    onKey: (e) => {
        if (e.key === 'Escape' || e.key === 'F2') { closeInventory(); return; }
        const r = custom();
        if (r && typeof r.onKey === 'function') r.onKey(e);
    },

    // The controller (above). The stick comes as numbers (router.js activeNavAnalog) and drives the
    // circle; the D-pad still comes as up / down / left / right.
    onNav: (nav, mods) => {
        const r = custom();
        if (!r) return padNav(nav, mods);
        if (typeof r.onNav === 'function') r.onNav(nav, mods);
    },
    analog: true,
    onAnalog: (...a) => {
        const r = custom();
        if (!r) return padAnalog(...a);
        if (typeof r.onAnalog === 'function') r.onAnalog(...a);
    },
    padHints: () => {
        const r = custom();
        if (!r) return padHints();
        return typeof r.padHints === 'function' ? r.padHints() : null;
    },
});

// ========================================
// OPTIMISTIC-VIEW RENDER HOOKS
// The op engine redraws through these when it reverts — all six views, registered rather
// than hardcoded, because the core cannot name renderer functions (see setViewRenderHook).
// 'state' points at the full orchestrator: a state revert can shift weights and whichever
// right-hand panel is up, and renderInventory is the function that knows that. The hotbar is
// the core's to follow (core/inventory.js redrawView), whichever renderer is drawing.
// ========================================
setViewRenderHook('state',     () => renderInventory());
setViewRenderHook('ground',    () => renderGroundGrid());
setViewRenderHook('container', () => { renderContainerGrid(); renderContainerInfo(); });
setViewRenderHook('ignition',  () => renderIgnitionSlot());
setViewRenderHook('panels',    () => renderPanelStack());
setViewRenderHook('playerInv', () => { renderPlayerInvGrids(); renderPlayerInvInfo(); });


// ========================================
// THE RENDERER SEAT
//
// This object IS the renderer interface — the complete set of operations the wire layer
// (core/inv-wire.js) can ask of whatever is drawing the inventory. A custom renderer
// resource implements this same shape and registers it in this seat; the wire never knows
// the difference. Method-by-method documentation: docs/nui-inventory.md.
// ========================================
// The STATIC panels — the ones that are single by nature and live in index.html. `external`
// was removed with the element it named: resource panels are cloned from a template and keyed
// by panel id now, so there is no one id to map (see renderPanelStack).
const PANEL_IDS = {
    ground:    'inv-ground-panel',
    container: 'inv-container-panel',
    ignition:  'inv-ignition-panel',
    playerInv: 'inv-player-inv-panel',
};

/* Developer mode on or off (tools/core.lua, on every change and when dev tools are taken back): Destroy is
   offered only while it is on. Off with the menu open shuts the menu, Destroy's confirm included. */
NuiRouter.register('devModeState', (d) => {
    inv.devMode = !!(d && d.on === true);
    const menu = document.getElementById('inv-context-menu');
    if (!inv.devMode && menu && menu.classList.contains('visible')) hideContextMenu();
});

/* Which options with a `require` the player meets now (client/inventory.lua, while a screen is open,
   and again whenever the answer changes): the menu shows only those. */
NuiRouter.register('itemOptionGates', (d) => {
    inv.optionGates = (d && d.gates && typeof d.gates === 'object') ? d.gates : {};
});

/* The dim behind the inventory — see #inv-wash in css/inventory.css. Lua sends it on when an
   inventory screen opens without the character preview, carrying INVENTORY_WASH as the colour,
   and off when it closes. Not tied to showOverlay: whether the dim is the page's job or the
   game's depends on Config.MenuPedEnabled, which only Lua knows. */
NuiRouter.register('inventoryWash', (d) => {
    const wash = document.getElementById('inv-wash');
    if (!wash) return;
    if (d && d.show) {
        if (d.color) wash.style.background = d.color;
        wash.classList.add('on');
    } else {
        wash.classList.remove('on');
    }
});

registerRenderer({
    // ---- overlay lifecycle ----
    showOverlay() {
        const overlay = document.getElementById('inv-overlay');
        overlay.classList.add('open');
        // Commit the display change before opacity, or the fade is skipped (see the CSS's
        // two-classes note on #inv-overlay).
        void overlay.offsetWidth;
        overlay.classList.add('visible');
        padReset(true);    // the controller's highlight starts on the first pocket slot
    },
    hideOverlay() {
        const overlay = document.getElementById('inv-overlay');
        padReset(false);
        overlay.classList.remove('visible');
        setTimeout(() => {
            if (!inv.open) {
                overlay.classList.remove('open');
                hideTooltip();
            }
        }, 250);
    },

    // ---- full and partial redraws ----
    renderAll:           () => renderInventory(),
    refreshSlots:        () => refreshSlotVisuals(),
    renderWeights:       () => renderWeights(),
    renderGround:        () => renderGroundGrid(),
    renderContainer:     () => renderContainerGrid(),
    renderContainerInfo: () => renderContainerInfo(),
    renderIgnition:      () => renderIgnitionSlot(),
    renderAccessories:   () => renderAccessoryGrid(true),   // defs changed — full rebuild
    // ONE METHOD FOR THE WHOLE STACK. It replaces renderExternal, and with it the three
    // seat methods that pushed one panel's chrome (setExternalLabel / setExternalWeight /
    // setExternalReadOnly). Those existed because the wire held panel state the renderer
    // could not see; the panel entries carry label, weight and readOnly now, so the stack
    // draws its own chrome and there is nothing left to push.
    renderPanelStack:    () => renderPanelStack(),
    renderPlayerInv:     () => { renderPlayerInvGrids(); renderPlayerInvInfo(); },
    renderPlayerInvInfo: () => renderPlayerInvInfo(),
    tagItemSlots:        () => tagItemSlots(),

    // ---- panel chrome ----
    setPanels(visible) {
        for (const name in visible) {
            const el = document.getElementById(PANEL_IDS[name]);
            if (el) el.style.display = visible[name] ? '' : 'none';
        }
    },
    flashPanels(names) {
        for (const name of names) flashPanel(document.getElementById(PANEL_IDS[name]));
    },
    // Each panel's chrome (label, weight, read-only) is drawn by renderPanelStack from its own
    // entry: twenty wallets cannot share one element id.

    // ---- interaction state the wire must ask about ----
    isMidDrag:     () => !!dragItem,
    hasPlayerGrid: () => !!document.querySelector('#inv-player-grid .inv-slot'),
    cancelInteractions() {
        cancelDrag();
        hideContextMenu();
        hideTooltip();
    },

    // ---- player feedback ----
    notify: (text) => uiNotify({ text, type: 'error', duration: 4000 }),
});