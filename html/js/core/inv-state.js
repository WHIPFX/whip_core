// ========================================
// INVENTORY CORE — STATE
//
// Every store the inventory system holds, DOM-free, as properties of two exported objects.
// Property assignment (`inv.containerOpen = true`) works from any importer — unlike the
// exported-let-plus-setter shape this replaced, which needed a setter per rebindable store
// and there are thirty-two of them. The objects are const; their properties are the state.
//
// `inv` is the player-side world: the inventory itself, ground, container, ignition,
// external panel, admin view, stock mode. `shop` is the shop screen's two grids — owned and
// written by shops.js, read by the slot factory and the drag logic.
//
// WHAT DOES NOT LIVE HERE: DOM element references (drag ghosts, context-menu targets — those
// are the renderer's), and item definitions (core/item-defs.js, because utils.js sits below
// even this file).
// ========================================

export const inv = {
    open: false,

    // Developer mode on (tools/core.lua tells the page, 'devModeState'): only then is Destroy offered.
    // The server refuses a destroy without it either way (server/events_inventory.lua).
    devMode: false,
    // Which item options with a `require` the player meets now: ['<item>|<action>'] = true. Client Lua
    // works them out while a screen is open (client/inventory.lua, 'itemOptionGates'); the menu shows
    // such an option only when it is true here. The server asks again before it runs.
    optionGates: {},

    // Server-sent player state
    state:      { player: {} },   // whole player-side inventory, slot-keyed per container
    weights:    { player: 0 },
    maxSlots:   { player: 30 },
    maxWeight:  { player: 80 },
    charName:   '',
    charId:     0,
    accountNum: '',

    // Ground items (nearby world items shown in Ground panel)
    groundItems: {},              // [slotNum string] = { item, amount, metadata, groundId }

    // Container state (right panel when container is open)
    containerOpen:    false,
    containerId:      null,
    containerStoreId: null,       // the store id behind the grid, e.g. 'container:42' or 'vehicle:7:trunk'
    containerDef:     null,       // { name, type, slots, maxWeight }
    containerItems:   {},         // { "1": {item,amount,metadata}, ... }
    containerWeight:  0,
    containerOpenedAt: 0,         // Date.now() when it opened — shift-click sends to the NEWEST store open

    // Ignition state (1-slot panel for vehicle key in driver seat)
    ignitionOpen:      false,
    ignitionSlot:      null,      // {item, amount, metadata} or null
    ignitionVehicleId: null,

    // Stock management mode (shop employee container view)
    stockMode:   false,
    stockShopId: null,
    stockPrices: {},              // { [itemKey]: { price, forSale } } — by item, as prices are

    // ---- OPEN PANELS — the generic N-slot panels other resources open, via OpenPanel.
    // Wallets, duffle bags, crafting benches.
    //
    // AN ARRAY: any number of panels may be open at once (twenty wallets, scrolled).
    //
    // ORDER IS STACK ORDER. New panels append, so the column reads oldest-first and a panel
    // does not jump position when another opens above it.
    //
    // `key` IS THE IMPORTANT FIELD. It goes on every slot element as dataset.container, which
    // is the string the whole drag/drop path already carries from grid to move payload — so
    // making that string per-panel is most of what makes N panels work. It must be unique and
    // stable for the panel's lifetime; panelKeyFor is the only thing that mints one.
    //
    // entry: { key, id, label, slots, items, maxWeight, currentWeight, readOnly, allowed, openedAt }
    //   allowed   { [itemKey]: true } or null for "anything" — only for choosing where a shift-click
    //             goes; the server decides every move
    //   openedAt  Date.now() when it first opened — shift-click sends to the NEWEST store open
    panels: [],

    // Player inventory state (admin viewing another player's inventory)
    playerInvOpen:      false,
    playerInvItems:     { player: {} },
    playerInvCharName:  '',
    playerInvCharId:    0,
    playerInvWeights:   { player: 0 },
    playerInvMaxSlots:  { player: 30 },
    playerInvMaxWeight: { player: 80 },
};

// ============================================
// Panel lookup
// ============================================
//
// THREE FUNCTIONS, AND EVERY PANEL LOOKUP IN THE CODEBASE GOES THROUGH THEM. The slot factory,
// the drag logic, the wire handlers and the renderer all need "which panel is this?" — and the
// lesson slotDataFor's header records is that the same resolver written twice will drift. One
// copy, here, beside the array it reads.

/** The dataset.container string for a panel id. The ONLY place a panel key is minted — it
 *  matches the server's store id grammar ('panel:<id>', see Stores.addViewer) so a storeId
 *  coming off the wire can be compared against a key directly. */
export function panelKeyFor(id) {
    return 'panel:' + String(id);
}

/** The panel a slot belongs to, from its dataset.container. Returns null for every non-panel
 *  container name ('player', 'ground', 'container', ...), which is what lets callers use it as
 *  a test as well as a lookup. */
export function panelByKey(key) {
    if (!key) return null;
    for (const p of inv.panels) {
        if (p.key === key) return p;
    }
    return null;
}

/** The panel a server message is about. Wire payloads name the panel by id, not by key. */
export function panelById(id) {
    return panelByKey(panelKeyFor(id));
}

export const shop = {
    open:   false,
    data:   null,   // { shopId, name, mode, catalog, items, prices, accounts }
    items:  {},     // shelf: { [slot]: { item, amount, price, infinite } }
    basket: {},     // { [slot]: { item, amount, price, metadata } }
};

// ============================================
// Optimistic views
// ============================================
//
// The stores a drag can optimistically mutate, and how the op engine snapshots and restores
// each. RENDER HOOKS ARE REGISTERED, NOT HARDCODED: the core cannot name renderer functions
// (it would stop being headless), so the active renderer registers a redraw per view at
// startup. ALL SIX views carry a hook — the old shape gave only three of them one and leaned
// on revertInventory's blanket full redraw for the rest, an implicit dependency this registry
// makes explicit.

export const INV_VIEWS = {
    state:     { get: () => inv.state,          set: v => { inv.state = v; },          render: null },
    ground:    { get: () => inv.groundItems,    set: v => { inv.groundItems = v; },    render: null },
    container: { get: () => inv.containerItems, set: v => { inv.containerItems = v; }, render: null },
    ignition:  { get: () => inv.ignitionSlot,   set: v => { inv.ignitionSlot = v; },   render: null },
    // ONE VIEW FOR THE WHOLE STACK, not one per panel. A drag inside a wallet snapshots every
    // open panel, which is a structuredClone of a handful of small objects — cheaper than the
    // register/unregister lifecycle a per-panel view would need, and it keeps beginOp/extendOp
    // call sites naming a literal string exactly as they did when this was `external`.
    panels:    { get: () => inv.panels,         set: v => { inv.panels = v; },         render: null },
    playerInv: { get: () => inv.playerInvItems, set: v => { inv.playerInvItems = v; }, render: null },
};

/**
 * Register the redraw for one optimistic view. The default renderer calls this six times at
 * startup; a custom renderer does the same for its own draw functions.
 * @param {string} name  key of INV_VIEWS
 * @param {function} fn  redraws that view from core state
 */
export function setViewRenderHook(name, fn) {
    if (INV_VIEWS[name]) INV_VIEWS[name].render = fn;
}

// ============================================
// Hook registries (renderer-adjacent bridge)
// ============================================
//
// The against-the-grain call directions (inventory -> shops, inventory -> hotbar), carried
// over from the pre-split shape. Null until registration, and every caller null-guards.
// These are due to become core EVENTS once the emitter lands; do not grow them.

export let invShopHooks = null;     // { openShop, closeShop, renderShopGrid, renderBasketGrid, updateBasketTotal }
export let invHotbarHooks = null;   // { syncHotbar, hideHotbar }

export function invRegisterShopHooks(hooks) { invShopHooks = hooks; }
export function invRegisterHotbarHooks(hooks) { invHotbarHooks = hooks; }

// ============================================
// Registered slot configs (accessory strip + ignition keys)
// ============================================
//
// Server-pushed, stat-system style: whip_core:client:invSlotDefs carries the full current
// registry (seeded from shared/inventory_shape.lua's AccessoryStripSlots and the server's own
// ignition keys, extended by the RegisterAccessorySlot / RegisterIgnitionKey exports), and
// adoption is DESTRUCTIVE and idempotent — the payload IS the truth. The defaults below only
// cover the instant before the first sync lands so the strip never draws empty. An empty strip
// from the server is no strip (Config.AccessoryStrip off): the screen leaves the column out.
//
// These are the NUI'S COPIES of rules the server enforces (the player store kind's
// beforeMove; the ignition gate) — they exist to refuse instantly, not to decide.

export const slotConfig = {
    accessorySlots: [
        { slot: 1, accepts: null, label: 'Phone', icon: 'phone' },
        { slot: 2, accepts: ['cash', 'wallet'], label: 'Money', icon: 'cash' },
        { slot: 3, accepts: null, keys: true, label: 'Key', icon: 'vehicle_key' },
        { slot: 4, accepts: null, keys: true, label: 'Key', icon: 'vehicle_key' },
        { slot: 5, accepts: null, keys: true, label: 'Key', icon: 'vehicle_key' },
    ],
    ignitionKeys: ['vehicle_key', 'hacked_vehicle_key'],
};

export function adoptSlotDefs(payload) {
    if (!payload) return;
    if (Array.isArray(payload.accessorySlots)) slotConfig.accessorySlots = payload.accessorySlots;
    if (Array.isArray(payload.ignitionKeys)) slotConfig.ignitionKeys = payload.ignitionKeys;
}

export function isIgnitionKeyItem(item) {
    return slotConfig.ignitionKeys.indexOf(item) !== -1;
}

/** Does this strip slot take this item? The server's Inventory.slotTakes: `accepts` (a list of items) and `keys`
 *  (any ignition key); a slot with neither takes anything. */
export function slotTakesItem(cfg, item) {
    if (!cfg) return false;
    if (!cfg.accepts && !cfg.keys) return true;
    if (cfg.keys && isIgnitionKeyItem(item)) return true;
    return Array.isArray(cfg.accepts) && cfg.accepts.indexOf(item) !== -1;
}

/** What a strip slot takes, in words for a refusal ("Cash or Wallet"), as the server's Inventory.slotRefusal.
 *  @param defs  the item definitions, for their names */
export function slotTakesText(cfg, defs) {
    const names = (cfg.accepts || []).map((key) => (defs && defs[key] && defs[key].name) || key);
    if (cfg.keys) names.push('keys');
    return names.length ? names.join(' or ') : cfg.label;
}