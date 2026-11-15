# Your own inventory UI on whip

whip's inventory is split in two. The **core** keeps the state, talks to the server, moves items
optimistically and puts them back when the server says no. The **renderer** draws it. Whip's own
renderer is `html/js/inventory.js`; yours replaces it, from a resource of your own, and the core keeps
running underneath. You write the drawing and the input. You never write a move payload, a sync or a
weight rule: the server checks every move whatever your UI shows.

## Switching it on

```lua
-- whip_core/config.lua
Config.InventoryRenderer = 'my_inventory_ui'
```

Or per server, without touching config.lua: `setr whip_inventory_renderer my_inventory_ui` in
server.cfg (it wins over the config value). Players get it when they next join.

To try a UI without changing either, in game with developer mode on (`/w`):
`/whip_inventory_ui my_inventory_ui`. It draws your own inventory with it at once, until you rejoin.
`/whip_inventory_ui none` goes back to whip's own, and `/whip_inventory_ui` alone loads the current one
again. Before writing any of it, try it in a browser: see **Building it: the preview** below.

Your resource lists `renderer.js` in its `files{}` (and anything it loads: css, fonts, pictures). whip
imports it from `https://cfx-nui-my_inventory_ui/renderer.js` and calls its default export:

```js
// my_inventory_ui/renderer.js
export default function createRenderer({ api, mount, close, addStylesheet, signal }) {
    // api            the core: state, actions, item definitions (everything below)
    // mount          <div id="inv-custom-root">, yours entirely. whip shows it while the inventory is
    //                open and hides it when it closes, and never writes into it
    // close          closes the inventory properly. Your close button calls THIS
    // addStylesheet  addStylesheet('style.css'): a stylesheet from your resource
    // signal         ends when whip takes your UI out (a reload, a switch): for listeners and timers
    //                outside `mount`
    return { render() { /* draw everything from api.inv */ } };
}
```

If the resource is missing, the import fails, or the object you return has no `render`, whip keeps
its own inventory and the F8 console says exactly what was wrong. A method of yours that throws is
printed there too, and the inventory carries on.

**Don't import whip's modules** (`import ... from 'https://cfx-nui-whip_core/js/...'`). It loads, and
gives you a second, empty copy of the state: your UI draws nothing while the real inventory runs
unseen. Everything is in `api`; if something you need is not, that is a gap in whip to report.

Relative imports between your own files work (`import './grid.js'`). Add stylesheets with
`addStylesheet('style.css')` (a path in your resource): whip removes them when your UI is taken out,
so a reload never leaves the old rules behind. whip's theme tokens (`docs/nui-theming.md`) are on the
page too, if you want your UI to follow a theme.

## What is on screen: the state

Read `api.inv` fresh in every render. Updates replace whole sub-objects, so a reference kept from
the last render can be a dead copy.

| Field | What |
| --- | --- |
| `open` | The inventory is open |
| `state` | The player's containers, slot-keyed: `state.player` (the pockets), `state.accessory` (the strip, when it is on). A slot is `{ item, amount, metadata, w? }` (`w`: weight with contents, from the server) |
| `maxSlots`, `maxWeight`, `weights` | Per container: `maxSlots.player`, `maxWeight.player`; `weights.player + weights.accessory` is what the pockets carry |
| `charName`, `charId`, `accountNum` | Who this is |
| `groundItems` | Nearby: piles keyed `'1'..'n'`, each `{ item, amount, metadata, groundId }` |
| `containerOpen`, `containerId`, `containerStoreId`, `containerDef`, `containerItems`, `containerWeight` | A stash, boot or glovebox. `containerDef` is `{ name, type, slots, maxWeight }` |
| `ignitionOpen`, `ignitionSlot`, `ignitionVehicleId` | The ignition, in a driver's seat: one slot |
| `panels` | Every open panel (wallets, bags, benches: `OpenPanel`), oldest first. Each `{ key, id, label, slots, items, maxWeight, currentWeight, readOnly, allowed, openedAt }`. `key` (`'panel:<id>'`) is its container name in an address |
| `playerInvOpen`, `playerInvItems`, `playerInvCharName`, `playerInvCharId`, `playerInvWeights`, `playerInvMaxSlots`, `playerInvMaxWeight` | An admin looking into another player's pockets (`playerInvItems.player`) |
| `stockMode`, `stockShopId`, `stockPrices` | A shop worker's stock view of the container: prices by item, `{ price, forSale }` |
| `devMode` | Developer mode is on (Destroy is offered only then) |
| `optionGates` | Which item options with a `require` the player meets now (`menuFor` reads it) |

**What shows** is in the state too: the store when `containerOpen`, the ignition when `ignitionOpen`
(in a driver's seat), the admin view when `playerInvOpen`, every entry of `panels`, and Nearby when
`api.actions.groundShowing()` (on foot, with nothing else in its place).

`api.shop` is the shop screen's state, drawn by whip (see Shops). `api.slotConfig` is the accessory
strip's slots (`accessorySlots`: `{ slot, accepts, keys, label, icon, iconSvg }`, where `accepts` is a list of
item keys and `keys` takes any ignition key; `api.slotTakesItem(cfg, item)` answers as the server does) and the ignition keys
(`ignitionKeys`).

**An address** is `{ container, slot }`: `'player'`, `'accessory'`, `'ground'`, `'container'`,
`'ignition'` (slot 1), a panel's `key`, or `'targetPlayer'`. `api.actions.slotAt(container, slot)`
reads any of them.

## Drawing an item

- `api.getItemDefs()[itemKey]` is the item: `{ name, desc, weight, type, stack, maxStack, usable,
  contextOptions, metaFields, img, images, ... }`. Ask for it at render time; it is replaced when
  items are registered.
- `api.setItemImage(imgEl, slot)` puts the item's picture into an `<img>`, the picture its metadata
  picks included, and falls back to whip's missing-picture image. Use it rather than building a URL.
  (`api.itemImageUrl(itemKey)` is the plain picture's URL.)
- `api.actions.describe(address)` is what whip's own tooltip says: `{ name, desc, amount, weight,
  weightEach, stack, lines }`, `lines` being the item's `metaFields` as `[{ label, value }]`.
- `api.actions.weightOf(container)` is `{ now, max }` in kg for the pockets, the container, a panel or
  the admin view.
- Text goes in with `textContent`. Labels written by developers (option labels, meta labels) may
  carry `&#9654;`-style entities: `describe` and `menuFor` decode them already; anything else, with
  `api.decodeTextEntities`. Never decode values players typed.

## Doing things: `api.actions`

Every gesture is one call. Each changes the state at once and sends it to the server, and answers
`{ ok: true }` or `{ ok: false, reason }`. `reason` is the line whip's own inventory shows the player
(an accessory slot that takes only one item, say); it is absent for a refusal whip shows as a red
slot or nothing. **Redraw after an ok**: the state has already changed. If the server then says no,
whip puts the state back, calls your `render`, and tells the player why (`notify`).

| Call | What it does |
| --- | --- |
| `move(from, to)` | A drag: the whole stack onto another slot (stack, swap or move, by the grids' rules) |
| `moveOne(from, to)` | One of the stack onto another slot (whip's right-click while dragging) |
| `quickMove(at)` | Shift-click: pockets to the newest store open (else the ground when Nearby shows); a store, a panel or the ground to the pockets |
| `split(at, amount)` | Split `amount` off into the first free slot (on the ground, a new pile) |
| `destroy(at)` | Developer mode only |
| `use(at)`, `give(at, amount?)`, `place(at)` | Items on your person. Give asks who to; Place closes the inventory and starts placing |
| `menuFor(at)` | The slot's right-click menu as whip shows it: `{ title, options: [{ action, label, group, amount? }] }`, or null. `group` is `'own'`, `'shared'` or `'danger'` |
| `runOption(at, action, { amount })` | Run one of its options (Give and Split take `amount`) |
| `refused(from, to)` | Would that drop be refused before sending? For a red slot while dragging |
| `slotAt`, `describe`, `weightOf`, `stackWeight`, `isPocketGrid`, `accessoryTakes`, `groundShowing` | Reading |

```js
const r = api.actions.move({ container: 'player', slot: 3 }, { container: 'container', slot: 1 });
if (!r.ok && r.reason) toast(r.reason);
redraw();
```

## What whip calls on you

**`render()`** is the one you must have. It draws everything from `api.inv`, and whip calls it whenever
anything changed: the inventory opening, an update from the server, a panel opening, a refused move put
back. Calls that come together arrive as one. Drawing everything every time is right: a hundred slots
at most, and the screen can never disagree with the state.

Everything else is optional. Give one only when you want it:

| Member | Without it | With it |
| --- | --- | --- |
| `showOverlay()` / `hideOverlay()` | whip shows and hides `mount` | Also yours: an animation in or out |
| `notify(text)` | whip's own toast | A refused move's reason, shown your way |
| `flashPanels(names)` | Nothing | A part just appeared (`'container'`, `'ignition'`, `'ground'`: getting in or out of a car) |
| `isMidDrag()` | `false` | Is something being dragged? |
| `cancelInteractions()` | `render()` | Drop any drag, menu or tooltip: a part is about to vanish |
| `destroy()` | whip empties `mount`, removes your stylesheets and your `events` subscriptions, and ends `signal` | Anything else to undo when whip takes your UI out |
| `onKey(e)` | | Keys while the inventory is open. Escape and F2 are whip's: they close it |
| `onNav(nav, mods)` | A controller can only close the inventory | The controller's buttons: `'up'`, `'down'`, `'left'`, `'right'`, `'select'` (A), `'back'` (B), `'buttonX'`, `'buttonY'`, `'tabPrev'` (LB), `'tabNext'` (RB). `mods.held` is how long a direction has been held, in ms; `mods.rb` that RB is held |
| `onAnalog(...)`, `padHints()` | | The stick, and the hint strip: `[[glyph, label], ...]` |
| `drawsShop: true` | whip's shop screen | You draw shops yourself (see Shops) |

Whip's own renderer has a method for each part (`renderGround`, `renderContainer`,
`renderPanelStack`, `refreshSlots`, `setPanels` and the rest: `api.RENDERER_METHODS`). Give any of them
and whip calls yours for that part instead of `render`. A renderer with all of them and no `render`
also works.

**Listeners outside `mount`** (on `document` or `window`, a timer) end with your UI when you pass
`signal`: `document.addEventListener('pointermove', fn, { signal })`. Otherwise an old copy keeps
listening after a reload, and every drag happens twice.

## Events (`api.events.on(name, fn)`, returns an unsubscribe)

| Event | Payload |
| --- | --- |
| `open` | `{ kind }`: `'plain'`, `'container'`, `'panel'`, `'shop'`, `'playerInv'` |
| `close` | `{}` |
| `panel-swap` | `{ toGround }` (got out of a car: true; in: false) |
| `external-open` / `external-close` | `{ id }` / `{ id }` (null: every panel) |
| `op-reverted` | `{ error, opId }` |
| `slot-defs` | `{ accessorySlots, ignitionKeys }` |
| `renderer-changed` | `{ renderer }` |

For sounds or badges. State has already changed when they fire; don't try to stop anything.

## Shops

A shop visit is whip's own shop screen, drawn over your UI, unless your renderer says
`drawsShop: true`. While a shop is open whip calls its own renderer, and yours again once it closes.
Drawing shops yourself means drawing from `api.shop` and sending the shop's own actions (`shopPurchase`
and the rest, `js/shops.js`): a screen of its own, best left to whip until you need it.

## Input

The mouse is yours: whip draws nothing over `mount`. Escape and F2 close the inventory. The hotbar,
the pickup notices and the dim behind the inventory keep working on their own.

## Building it: the preview

whip ships a preview that runs your UI in Chrome (or Edge), with sample items and no game:

```
node whip_core/dev/inventory-preview/preview.js my_inventory_ui
```

It serves whip's real page and your resource the way the game does, so what works there works in game.
Save any file in your resource and the page reloads on the same scene. Errors from your UI print in the
terminal, and F12 opens the browser's DevTools on the page. The toolbar (bottom left, F9 hides it):

- **Scene:** pockets and Nearby, a stash with a wallet open, a car's glovebox and ignition, full
  pockets, someone else's pockets (the admin view), a shop worker's stock, a shop.
- **Open / Close**, **Night**, **Developer mode** (Destroy appears).
- **Refuse next move:** the server says no to the next move, so you see your UI put it back and
  show the reason. **Ping:** how long the server takes to answer.
- **Controller buttons**, sent as the game sends them.
- **What your UI sent**: every action, with its payload.

It is not the server: nothing is saved, and Use, Give and Place only show what would be sent.
`node .../preview.js --help` lists the options (window size, a starting scene, screenshots for scripts).
Node 18 or newer; nothing to install.

## Reloading it in game

After an edit, `ensure my_inventory_ui` in the server console. Every player using it gets the new
files at once: whip closes the inventory if it is open, takes the old UI out, and loads the new one.
`/whip_inventory_ui` alone does the same for you only.

whip loads your `renderer.js` with a new `?v=` each time, so the browser fetches it again. A file your
renderer imports keeps the copy the browser already has, unless you import it with that same `?v=`:

```js
// renderer.js
const v = new URL(import.meta.url).search;              // '?v=…' on a reload, '' the first time
const { drawGrid } = await import('./grid.js' + v);     // instead of import { drawGrid } from './grid.js'
```

Do the same in any of your files that imports another. Without it, the preview still shows every
change (it reloads the whole page); only a reload in game keeps the old imported files until the
player rejoins.

## Server-registered slots

The accessory strip and the ignition's keys are registries, not hard-coded:

```lua
-- from any satellite, inside Whip.register
local ok, err = exports.whip_core:RegisterAccessorySlot({
    slot    = 4,           -- required; 1..Config.ContainerSlots.accessory
    accepts = 'badge',     -- optional item filter: one key or a list (nil = anything)
    keys    = false,       -- optional: true takes any ignition key too
    label   = 'Badge',     -- optional, defaults to 'Accessory'
    icon    = 'phone',     -- optional icon name from whip's set
    iconSvg = '<svg…>',    -- optional inline SVG, wins over icon
})
local ok2, err2 = exports.whip_core:RegisterIgnitionKey('skeleton_key')
```

Your `renderAccessories()` is called when they change (`api.slotConfig` has the new set). The server
enforces both itself; your checks only need to be fast.

## Below `actions`: the op contract

`actions` covers every gesture whip's own inventory has. For something it does not, this is what it
is built on. A gesture snapshots the views it will change, changes them, and sends:

```js
const opId = api.ops.beginOp(['state', 'container']);   // the views you will change
inv.state.player[from] = null;                          // change them
api.ops.emit(opId, 'containerMoveItem', { ... });       // send (stamps payload.opId)
```

- A revert restores only what was snapshotted. One gesture, one op; `emit` refuses a used id.
- `extendOp(opId, views)` adds views to a live op and returns the id to use.
- Nothing changed locally? Still `beginOp([])`, `emit`, then `commitOp(opId)`.
- Unanswered ops are swept after 15 s.
- Leave the other `ops` functions alone (`confirmOldestOp`, `discardAllPendingOps`, `sweepOps`,
  `revertOp`): they are the wire's.

The server actions: `moveItem`, `dropOneItem`, `containerMoveItem`, `containerDropOneItem`,
`playerInvMoveItem`, `playerInvDropOneItem`, `ignitionInsertKey`, `ignitionRemoveKey`,
`externalPanelMove`, `splitItem`, `destroyItem`, `quickMove`, `dropToGround`, `dropOneToGround`,
`pickupGroundItem`, `splitGroundItem`, `destroyGroundItem` (op-tagged), and `useItem`, `giveItem`,
`placeItem`, `customContextAction`, `storeContextAction`, `shopSetPrice`, `shopPriceInput` (plain,
`api.nuiCallback`). Their payloads are `core/inv-actions.js`.

## A minimal renderer, in full

The pockets as buttons: click one to use it, shift-click to send it across. Everything else
(open, close, refused moves, the reason why) is whip's.

```js
export default function createRenderer({ api, mount, close, addStylesheet }) {
    const { inv, actions } = api;
    addStylesheet('style.css');

    function render() {
        mount.replaceChildren();
        for (let s = 1; s <= (inv.maxSlots.player || 0); s++) {
            const at = { container: 'player', slot: s };
            const cell = document.createElement('button');
            const d = actions.slotAt('player', s);
            if (d) {
                const img = document.createElement('img');
                api.setItemImage(img, d);
                cell.append(img, String(d.amount));
                cell.onclick = (e) => {
                    const r = e.shiftKey ? actions.quickMove(at) : actions.use(at);
                    if (r.ok) render();
                };
            }
            mount.appendChild(cell);
        }
        const shut = document.createElement('button');
        shut.textContent = 'Close';
        shut.onclick = close;
        mount.appendChild(shut);
    }

    return { render };
}
```

## Not the contract

Whip's own renderer's element ids (`inv-*`), classes and datasets, and `invShopHooks` /
`invHotbarHooks`. Depend on `api`, the events, the factory's arguments and the interface above.

And the don'ts, each a real bug once:

- **Don't skip an update because your panel is hidden.** Take it into state; draw when it shows.
- **Don't reuse an opId**, and don't change a view you did not snapshot (with raw ops).
- **Don't fake a close by hiding your DOM.** Call `close`.
- **Don't listen on `document` or `window` without `signal`.** After a reload the old copy is still
  listening, and every gesture happens twice.
