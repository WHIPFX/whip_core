-- ============================================
-- Inventory & Ground Item Events — server/events_inventory.lua
-- Depends on globals from inventory_sync.lua (Inventory.syncAndSave) and devtools_base.lua (DevTools.refresh)
-- Depends on globals from player_lifecycle.lua:
--   GroundSync, PlayersNearPoint
-- ============================================

--- The highest pocket slot any pocket declares (Config.ContainerSlots): the bound for the events
--- here that take `(container, slot)` rather than an address. The handlers check the slot exists.
local POCKET_SLOT_MAX = 1
for _, n in pairs(Config.ContainerSlots or {}) do
    if type(n) == 'number' and n > POCKET_SLOT_MAX then POCKET_SLOT_MAX = math.floor(n) end
end

-- ============================================
-- storeMove — the one move event
-- ============================================
--
-- One client-facing move event: which pair of stores a move connects is a parameter. Outside it,
-- each for a reason:
--   splitItem, quickMove             no destination SLOT — the server picks it (both still go
--                                    through the same committed move; see playerMove)
--   dropToGround / dropOneToGround   ground is not slot-addressed; dropping conjures a row
--
-- Both endpoints arrive as 'addr' parameters, so SecureEvent has already resolved AND authorized
-- them: a client naming a container it has not opened, a vehicle it does not hold, or another
-- player's inventory never reaches the handler.

--- The `onReject` for every event that carries the NUI's operation id (storeMove, the two drops,
--- the pickup): a refusal SecureEvent makes before the handler still answers the op, or the NUI
--- would keep the optimistic move on screen (see refuseEvent in secure.lua).
---
--- A function per event because the id sits at a different position in each. The arguments are
--- RAW, so the id is checked before it is echoed, and it only goes back to the client that sent it.
---@param position number  which argument is the opId
---@return function
local function revertOpAt(position)
    return function(src, reason, args)
        local n = tonumber(args[position])
        local opId = n and math.tointeger(n)
        if opId and opId > 0 then
            TriggerClientEvent('whip_core:client:inventoryRevert', src, reason, opId)
        end
    end
end

--- A HANDLER's refusal of a drop, pickup, throw or placement: recorded (the Event Monitor,
--- whip_test), then answered. `reason` nil answers the client without a toast (the drop-one of an
--- empty slot); `logReason` is what is recorded then.
---@param eventName string
---@param source number
---@param reason string|nil   shown to the player
---@param opId number|nil
---@param logReason string|nil  recorded instead, when the player is shown nothing
local function refuseOp(eventName, source, reason, opId, logReason)
    RecordEventRejection(eventName, source, reason or logReason or 'refused')
    TriggerClientEvent('whip_core:client:inventoryRevert', source, reason, opId)
end

--- A PLAYER moving an item between two authorised addresses: the committed move, the reply their
--- screen is waiting for, a refusal they can read, and the timeline rows.
---
--- storeMove's whole body; splitItem and quickMove are the same move with the destination slot
--- picked for the player.
---@param eventName string  the event the refusal is recorded under
---@param source number
---@param player table
---@param from table  { store, slot }
---@param to table    { store, slot }
---@param amount number  0 = the whole slot
---@param mode string  'move' | 'one' | 'split'
---@param opId number  the NUI's optimistic op, 0 when it is not tracking one
local function playerMove(eventName, source, player, from, to, amount, mode, opId)
    local function reject(reason)
        -- Recorded as well as sent: SecureEvent only logs the refusals it makes itself.
        RecordEventRejection(eventName, source, reason)
        TriggerClientEvent('whip_core:client:inventoryRevert', source, reason, opId)

        -- Tell them what is actually there: the client restores the snapshot it took before the
        -- drag, which may hold slots another viewer has since moved. The current contents of the
        -- two slots the move named correct those two, on the ordinary delta path. (Other slots a
        -- viewer changed meanwhile show the snapshot until their next delta.)
        if from and from.store then Stores.publishSlotsTo(source, from.store, { from.slot }) end
        if to and to.store and not (to.store.id == from.store.id and to.slot == from.slot) then
            Stores.publishSlotsTo(source, to.store, { to.slot })
        end
    end

    if not player.inventory then
        reject('Not loaded')
        return
    end
    local locked = DbHealth.refusal()   -- items are locked while the database is down (db_health.lua)
    if locked then
        reject(locked)
        return
    end

    -- Ask both ends before touching anything. A panel's owning resource may veto the move,
    -- or perform it itself ('handled'), and either answer must cost nothing to honour.
    local fromData = from.store.kind.get(from.store.handle, from.slot)
    -- 'one' moves ONE, whatever amount the client sent, and the hooks are told 1. Never more than
    -- the stack, as commitMove's own detail.
    local detail = {
        item     = fromData and fromData.item,
        amount   = (mode == 'one' and fromData) and 1
                   or ((amount > 0 and fromData) and math.min(amount, fromData.amount))
                   or (fromData and fromData.amount),
        metadata = fromData and fromData.metadata,
        source   = source,
        -- The NUI is waiting for exactly one inventoryUpdate for this move (its op queue confirms
        -- the oldest pending drag on each). `replied` is set by whichever sends it first; everything
        -- after is marked unsolicited. (0 = not tracking.)
        awaitsReply = opId > 0,
        replied     = false,
    }
    -- Stamp the instance's uid BEFORE the move runs, so the id is inside the very write saveAll
    -- commits.
    --
    -- Not an infinite shop's shelf: its `get` builds a fresh row on every read, so a stamp would go
    -- nowhere (and leave a first_seen debt, Log's _firstSeenOwed). The goods are stamped where they
    -- land.
    if fromData and fromData.item and from.store.kind.id ~= 'shop' then
        Log.ensureUid(fromData)
    end

    -- The destination's occupant, read BEFORE the move: a full move onto an occupied slot is a
    -- SWAP, and the occupant gets its own row. Same-item occupants merge instead (a row further down).
    local toData = to.store.kind.get(to.store.handle, to.slot)
    if toData and toData.item then
        Log.ensureUid(toData)
    end
    local toSnapshot = toData and toData.item and {
        item = toData.item, amount = toData.amount, metadata = toData.metadata,
    } or nil

    -- The move itself is Stores.commitMove (as the StoreMove export). What is left here is specific
    -- to a PLAYER dragging: the uid stamping above, the client sync, the rejection replies and the
    -- timeline rows below.
    --
    -- onCommitted keeps the order: the client sync runs BETWEEN the persist and the post-move hooks
    -- (a key inserted into an ignition must not start an engine off a write that then failed).
    local ok, err, verdict = Stores.commitMove(from, to, {
        mode        = mode,
        amount      = amount,
        detail      = detail,
        onCommitted = function()
            -- A reply only while nothing has answered this drag yet (the panel fold can't have
            -- run: afterMove comes after this).
            if StoreMoveSyncClients(source, player, detail.awaitsReply, from, to) then detail.replied = true end
        end,
    })

    if not ok then
        reject(err or 'Move failed')
        return
    end

    -- Every accepted drag is answered: a move that touched no player container (stash to stash,
    -- trunk to glovebox, a panel another resource handled) sends no inventoryUpdate, so it is
    -- acknowledged by id.
    if detail.awaitsReply and not detail.replied then
        TriggerClientEvent('whip_core:client:moveAck', source, opId)
    end

    -- A kind performed the move itself. Do NOT log and do NOT sync: the client's optimistic
    -- state already matches what the hook made true, and pushing a sync here would fight
    -- whatever the hook chose to render.
    if verdict == 'handled' then return end

    -- The move stood — put it on both timelines, written the way an admin reads it:
    -- store LABELS and slot numbers, not kind ids. A basket→player move IS a purchase
    -- (the basket kind charged for it), so a shop good's first rows read
    -- "first_seen · moved · Shop Name (slot N) → Player Inventory (slot M)".
    if detail.item then
        local fromLbl = Log.storeLabel(from.store)
        local toLbl   = Log.storeLabel(to.store)
        local sameStore = from.store.id == to.store.id

        -- A panel store is a VIEW of a real item (duffle bag, wallet, a pistol's mag
        -- slot) — resolve that HOST item and put it on the row as a second clickable
        -- identity, so "moved Cash into Duffle Bag" links to BOTH timelines. The host's
        -- own timeline picks these rows up too (itemRows matches hostUid), which is how
        -- a duffle's history shows everything that ever went in or out of it.
        local hostKey, hostUid
        local hostStore = (to.store.kind.id == 'panel' and to.store)
            or (from.store.kind.id == 'panel' and from.store)
        if hostStore and hostStore.handle and hostStore.handle.session then
            local host = Panels.resolveHost(source, hostStore.handle.session)
            if host and host.item then
                Log.ensureUid(host)   -- live inventory slot — the stamp persists
                hostKey, hostUid = host.item, host.metadata.uid
            end
        end

        if sameStore then
            -- Rearranging inside one store is housekeeping, and reads as such.
            Log.item(player.charId, 'organised',
                { item = detail.item, amount = detail.amount, metadata = fromData and fromData.metadata },
                { detail = ('%s · slot %d → slot %d'):format(fromLbl, from.slot, to.slot),
                  hostKey = hostKey, hostUid = hostUid })
        else
            Log.item(player.charId, 'moved',
                { item = detail.item, amount = detail.amount, metadata = fromData and fromData.metadata },
                { detail = ('%s (slot %d) → %s (slot %d)'):format(fromLbl, from.slot, toLbl, to.slot),
                  hostKey = hostKey, hostUid = hostUid })
        end

        if toSnapshot then
            if toSnapshot.item ~= detail.item then
                -- The swap's other half: the occupant travelled the opposite way.
                Log.item(player.charId, sameStore and 'organised' or 'moved', toSnapshot,
                    { detail = sameStore
                        and ('%s · slot %d → slot %d · swapped'):format(fromLbl, to.slot, from.slot)
                        or ('%s (slot %d) → %s (slot %d) · swapped'):format(toLbl, to.slot, fromLbl, from.slot),
                      hostKey = hostKey, hostUid = hostUid })
            elseif toSnapshot.metadata and fromData and fromData.metadata
                and toSnapshot.metadata.uid and fromData.metadata.uid
                and toSnapshot.metadata.uid ~= fromData.metadata.uid then
                -- Same item, distinct instances: could be a merge (stacks combined) or a
                -- metadata-mismatch swap; either way the occupant's timeline should not
                -- just stop dead — this row says where it went.
                Log.item(player.charId, 'merged', toSnapshot,
                    { detail = 'with ' .. fromData.metadata.uid,
                      hostKey = hostKey, hostUid = hostUid })
            end
        end
    end
end

SecureEvent('whip_core:server:storeMove', {
    rateLimit = 100,
    burst     = 5,   -- drag-and-drop arrives in bursts, then settles
    onReject  = revertOpAt(5),
    params = {
        {'from',   'addr'},
        {'to',     'addr'},
        -- 0 means "the whole slot". Split and one-at-a-time carry their own amounts.
        {'amount', 'int', 0, 999999, 0},
        {'mode',   'enum', { 'move', 'one', 'split' }, 'move'},
        -- Correlation id for the client's optimistic update, echoed back on rejection so the NUI
        -- rolls back the move that actually failed. 0 means "the caller is not tracking ops".
        {'opId',   'int', 0, 2147483647, 0},
    },
}, function(source, player, from, to, amount, mode, opId)
    playerMove('whip_core:server:storeMove', source, player, from, to, amount, mode, opId)
end)

--- Shift-click: move a whole stack to wherever it fits in another store.
---
--- The destination is a WHOLE STORE (an address with no slot) and the server picks the slot —
--- Stores.slotAccepting, a stack of the same thing it can join or else the first empty slot. The
--- NUI predicts the same slot so the item moves the instant it is clicked, and this answers
--- exactly like a drag does: the move lands, or it is refused with the reason and the screen
--- puts the item back.
---
--- One destination, never a second guess: the client names the store it moved the item to on
--- screen; if that store cannot take it, the answer is no. Trying somewhere else here would leave
--- the item drawn in a store it never reached.
---
--- Swaps cannot happen: slotAccepting never answers with a slot holding something else.
SecureEvent('whip_core:server:quickMove', {
    rateLimit = 100,
    burst     = 5,   -- shift-clicking down a column is a burst, like dragging
    onReject  = revertOpAt(3),
    params = {
        {'from', 'addr'},
        {'to',   'addr', { slotOptional = true }},
        {'opId', 'int', 0, 2147483647, 0},
    },
}, function(source, player, from, to, opId)
    local EVENT = 'whip_core:server:quickMove'
    local function refuse(reason)
        RecordEventRejection(EVENT, source, reason)
        TriggerClientEvent('whip_core:client:inventoryRevert', source, reason, opId)
    end

    if not player.inventory then return refuse('Not loaded') end
    if Stores.sameStore(from.store, to.store) then return refuse('It is already there') end

    local d = from.store.kind.get(from.store.handle, from.slot)
    if not d or not d.item then return refuse('No item in that slot') end

    local slot = Stores.slotAccepting(to.store, d.item, d.amount, d.metadata)
    if not slot then
        -- Two reasons slotAccepting says no, and the player should hear which. The wording is the
        -- movers' own, so a shift-click and a drag refused for the same thing say the same thing.
        local kind = to.store.kind
        if kind.allows then
            local okIn, inWhy = kind.allows(to.store.handle, d.item, d.metadata)
            if not okIn then return refuse(inWhy or 'That item does not go there') end
        end
        return refuse(kind.id == 'player' and 'No room in your pockets' or 'No room there')
    end

    -- serverPicked: the NUI only PREDICTED this slot, so the mover gets the whole store back rather
    -- than a delta that would leave a mispredicted slot drawn (see StoreMoveSyncClients).
    playerMove(EVENT, source, player, from, { store = to.store, slot = slot, serverPicked = true }, 0, 'move', opId)
end)

--- Push whichever views the move touched back to the client: presentation, per kind. The player
--- inventory gets a full resync, a panel one slot at a time, a stash or a boot the slots that
--- changed (a delta, like every other viewer). Where the SERVER chose a slot (shift-click, split:
--- `serverPicked`), the mover gets the whole store: the NUI only predicted that slot.
---@param source number
---@param player table
---@param reply boolean|nil  the mover's inventory push answers their drag (storeMove only)
---@param ... table  the {store, slot, serverPicked?} addresses that changed
function StoreMoveSyncClients(source, player, reply, ...)
    local pushedPlayer, pushedUnits = false, {}

    -- Stores where a slot was the server's choice, and so the mover gets the whole store.
    local wholeFor = {}
    for i = 1, select('#', ...) do
        local addr = select(i, ...)
        if addr.serverPicked then wholeFor[addr.store.id] = true end
    end

    -- Everyone ELSE looking at these stores, collected as we go and told at the end.
    --
    -- Gathered per STORE ID rather than per unit, because a delta names slots and slots only
    -- mean something within one instance — a vehicle's trunk and its glovebox share a unit but
    -- are two different grids on screen.
    local touched = {}

    for i = 1, select('#', ...) do
        local addr   = select(i, ...)
        local store  = addr.store
        local kindId = store.kind.id

        local t = touched[store.id]
        if not t then
            t = { store = store, slots = {} }
            touched[store.id] = t
        end
        t.slots[#t.slots + 1] = addr.slot

        if kindId == 'player' then
            -- One resync covers every player container, so both ends of a
            -- player->accessory move must not each trigger their own.
            if not pushedPlayer then
                pushedPlayer = true
                Inventory.syncToClient(source, player, reply)
            end

        elseif kindId == 'rawInventory' then
            -- The admin inventory-inspect path. This store belongs to a DIFFERENT character,
            -- so it must never be confused with the mover's own inventory — the admin sees it
            -- through a side panel, and the target, if connected, needs their real inventory
            -- refreshed underneath them.
            if not pushedUnits[store.unit] then
                pushedUnits[store.unit] = true
                local session = Inventory.playerInvSession(source)
                if session then
                    TriggerClientEvent('whip_core:client:playerInvUpdate', source, {
                        targetInv     = Inventory.serialize(session.targetCache),
                        targetWeights = Inventory.buildWeights(session.targetCache),
                    })
                    if session.isOnline then
                        local targetPlayer = Players[session.targetSource]
                        if targetPlayer then
                            Inventory.syncToClient(session.targetSource, targetPlayer)
                        end
                    end
                end
            end

        elseif kindId == 'panel' then
            -- Panels update per SLOT, not wholesale — which is why this takes addresses
            -- rather than bare stores.
            local session = store.handle.session
            -- session.id rides along on both: a player can hold several panels open now, and
            -- neither message identifies its grid without it.
            TriggerClientEvent('whip_core:client:updateExternalPanelSlot', source,
                addr.slot, session.items[addr.slot], session.id)
            if session.config.maxWeight and not pushedUnits[store.unit] then
                pushedUnits[store.unit] = true
                TriggerClientEvent('whip_core:client:panelWeightInfo', source, {
                    panelId       = session.id,
                    maxWeight     = session.config.maxWeight,
                    currentWeight = Stores.weightOf(store),
                })
            end

        elseif wholeFor[store.id] and not pushedUnits[store.unit] then
            -- The whole store, only where the server picked a slot (see above); otherwise the
            -- mover's delta goes out with everyone else's at the end.
            pushedUnits[store.unit] = true

            if kindId == 'container' then
                TriggerClientEvent('whip_core:client:containerUpdate', source, {
                    inventory       = Containers.serializeInventory(store.handle.containerId),
                    containerWeight = Stores.weightOf(store),
                })
            elseif kindId == 'vehicle' then
                -- Say which compartment this is for (trunk, glovebox or ignition), or the client
                -- paints it into whatever vehicle panel is open. vehicleId + storageType also key
                -- the client's remembered copy of this storage (vehicleStorageKey, client/vehicles.lua).
                TriggerClientEvent('whip_core:client:vehicleStorageUpdate', source, {
                    vehicleId       = store.handle.vehicleId,
                    storageType     = store.handle.storageType,
                    inventory       = Vehicles.serializeStorage(store.handle.vehicleId, store.handle.storageType),
                    containerWeight = Stores.weightOf(store),
                })
            end
        end
    end

    -- ---- The shop screens ----
    --
    -- A player never moves into a shelf or a basket here (the shop screen has its own actions,
    -- server/shops.lua), but an employee restocking a stocked shop's shelf (a container) does:
    -- every customer at that shop sees the new stock.
    if Shops and Shops.refreshContainer then
        for _, t in pairs(touched) do
            if t.store.kind.id == 'container' then Shops.refreshContainer(t.store.handle.containerId) end
        end
    end

    -- Now everyone else inside these stores, after the loop: a swap names the same store twice, and
    -- a viewer gets ONE message listing both slots. The mover gets a stash or boot's delta here too
    -- (unless it went back whole above). Player containers and the admin inspect view are skipped
    -- (one viewer each; their own push above).
    for _, t in pairs(touched) do
        local kindId = t.store.kind.id
        -- Not the ignition: it is never on screen as a grid, and has its own channel (afterMove).
        local toMover = (kindId == 'container' or (kindId == 'vehicle' and t.store.handle.storageType ~= 'key'))
            and not wholeFor[t.store.id]
        if kindId ~= 'player' and kindId ~= 'rawInventory' then
            -- One build for everyone, the mover included.
            Stores.publishSlots(t.store, t.slots, source, toMover and source or nil)
        end
    end

    -- Whether the mover was sent an inventoryUpdate — the reply the NUI's op queue counts. The
    -- storeMove handler records it so a panel fold later in the same move does not send a second.
    return pushedPlayer
end

-- ============================================
-- Inventory Events (client → server)
-- ============================================

--- Client requests inventory data when opening F2
---
--- Burst 3 on the UI bookkeeping events (this, inventoryClosed, openContainer, closePlayerInventory,
--- closePanelSession, openShop, openShopStock): screens open themselves too (a seat reconcile asks
--- for a glovebox, a panel reopens as an overlay), and a dropped close is unrecoverable (the client
--- clears its state before sending). Three covers a close-then-open pair plus one automatic request;
--- the window, and so the sustained ceiling, is unchanged.
SecureEvent('whip_core:server:openInventory', {
    rateLimit = 500,
    burst     = 3,
    params = {
        -- The client saying it already holds the item definitions, so they can be left out of the
        -- payload. Defaults to false, which is the safe direction: an old or confused client that
        -- says nothing gets sent them, exactly as before.
        {'haveDefs', 'bool', false},
    },
}, function(source, player, haveDefs)
    if not player.inventory then
        return
    end

    -- Recorded so every OTHER opener — stash, boot, shop, satellite panel — can skip the
    -- definitions too without each growing a parameter of its own. See Inventory.buildPayload.
    player._haveItemDefs = haveDefs

    -- Block opening inventory while another player is viewing it
    if player._inventoryLocked then
        return false, 'Your inventory is currently locked'   -- shown to the player and recorded
    end

    Log.paced(player.charId, 'inv_open')

    -- Gather nearby ground items for the Ground panel
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local nearbyRaw = GroundItems.getNearby(coords.x, coords.y, coords.z, Config.GroundItemPickupRange)

    -- Map nearby items to slot numbers (1-based) for the NUI grid
    local groundSlots = {}
    for i, gItem in ipairs(nearbyRaw) do
        groundSlots[tostring(i)] = {
            item     = gItem.item,
            amount   = gItem.amount,
            metadata = gItem.metadata,
            groundId = gItem.id,
            -- Where it lies: the client shows only the piles it can see (client/ground.lua
            -- GroundSlotsInSight), and may not have been sent this one yet.
            x = gItem.x, y = gItem.y, z = gItem.z,
        }
    end

    local payload = Inventory.buildPayload(player, haveDefs)
    payload.groundItems = groundSlots
    TriggerClientEvent('whip_core:client:openInventory', source, payload)
end)

--- The close half of the activity log's inv_open. Purely informational — every
--- session the close might affect (containers, panels, shops) already announces its
--- own close through its own event; this exists only so a timeline shows how long an
--- inventory sat open.
SecureEvent('whip_core:server:inventoryClosed', {
    whileDead = true,   -- dying closes the inventory (dead players are refused by default; see secure.lua)
    rateLimit = 500,
    -- Burst 3; see the note on openInventory above.
    burst     = 3,
}, function(_, player)
    Log.paced(player.charId, 'inv_close')
end)

--- An item that is not usable does its defaultAction instead (a weapon's Equip, a magazine's Load):
--- the hotbar key, a double-click and the menu's Use all come here. The option's when and require
--- are asked first, as a click on it in the menu is. Answers what customContextAction would: nothing,
--- or false and why.
---@return boolean|nil ok
---@return string|nil why
local function runDefaultAction(source, player, container, slot)
    local slotData = Inventory.getSlot(player.inventory, container, slot)
    if not slotData then return end
    local def = Config.Items[slotData.item]
    if not (def and def.defaultAction) then return end
    local opt = Inventory.optionFor(slotData.item, def.defaultAction)
    if opt then
        local allowed, why = Inventory.optionAllowed(source, player, opt, slotData)
        if not allowed then return false, why end
    end
    -- Declared, but nothing does it: its resource is stopped or never registered it. Said, as a
    -- use with no handler is ("can't be used right now"), rather than a press that does nothing.
    if Inventory.ContextActions[def.defaultAction] == nil then
        return false, ("%s can't be used right now"):format(def.name or slotData.item)
    end
    Log.item(player.charId, 'used', slotData, { amount = 1, detail = def.defaultAction })
    -- Through the one dispatcher, which hands a satellite the sheet.
    local _, _, refused = Inventory.runContextAction(def.defaultAction, source, player, slotData, container, slot)
    if refused then return false, refused end
end

--- Client requests item use (hotbar key 1-5)
SecureEvent('whip_core:server:useItem', {
    rateLimit = 500,
    params = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
    },
}, function(source, player, container, slot)
    if not player.inventory then return end

    -- Read the slot BEFORE the use — a consumable's last unit leaves the slot inside
    -- useItem, and the log wants to name what was used, not find an empty square.
    local usedSlot = Inventory.getSlot(player.inventory, container, slot)

    local ok, err, logged = Inventory.useItem(source, player, container, slot)

    if ok then
        -- `logged`: a declared timed use took the item through StoreTake, which wrote the row.
        if usedSlot and not logged then Log.item(player.charId, 'used', usedSlot, { amount = 1 }) end
        -- The inventory only: a use that changes stats (eating, bandaging) goes through Stats.set,
        -- which queues the character row for the one-second flush in player.lua.
        Inventory.syncAndSave(source, player)
    elseif err == 'Item not usable' then
        -- Fallback: its defaultAction (e.g. weapons, magazines)
        return runDefaultAction(source, player, container, slot)
    -- A refusal is answered `false, 'why'`: shown to the player and recorded in the Event Monitor.
    elseif err == 'On cooldown' then
        return false, 'Item on cooldown'
    elseif err == '' then
        return false   -- refused without a word to say (a cancelled bar)
    elseif err ~= 'Empty slot' then
        return false, err or 'Cannot use item'
    end
end)

--- Context menu: use item from inventory UI
SecureEvent('whip_core:server:useItemFromMenu', {
    rateLimit = 500,
    params = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
    },
}, function(source, player, container, slot)
    if not player.inventory then
        return
    end

    -- Same pre-read as the hotbar path: name the item before the use empties the slot.
    local usedSlot = Inventory.getSlot(player.inventory, container, slot)

    local ok, err, logged = Inventory.useItem(source, player, container, slot)

    if ok then
        if usedSlot and not logged then Log.item(player.charId, 'used', usedSlot, { amount = 1 }) end
        Inventory.syncAndSave(source, player)   -- inventory only; see the hotbar path above
    elseif err == 'Item not usable' then
        -- Same defaultAction fallback as the hotbar path above (the shipped menu hides Use unless
        -- def.usable, but the two use events agree).
        return runDefaultAction(source, player, container, slot)
    elseif err == '' then
        return false   -- refused silently (a cancelled bar), as on the hotbar path
    elseif err and err ~= 'Empty slot' then
        return false, err   -- shown and recorded, as on the hotbar path
    end
end)

--- Context menu: custom context action (from external resources)
SecureEvent('whip_core:server:customContextAction', {
    rateLimit = 500,
    params = {
        {'action', 'string', 32},
        {'container', 'enum', PlayerContainers},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
    },
}, function(source, player, action, container, slot)
    if not player.inventory then return end

    local slotData = Inventory.getSlot(player.inventory, container, slot)
    if not slotData then return end

    -- The ownership check: an action key must match the item's defaultAction or one of its options,
    -- its own or added (AddItemOption). Handlers keep their own guards too.
    local def = Config.Items[slotData.item]
    if not def then return end
    local opt = Inventory.optionFor(slotData.item, action)
    if not opt and def.defaultAction ~= action then return end

    -- Its when (the item) and require (the player), asked again: the page only hid what failed.
    if opt then
        local allowed, why = Inventory.optionAllowed(source, player, opt, slotData)
        if not allowed then return false, why end
    end

    -- Declared, but nothing does it: its resource is stopped or never registered it. Said, rather
    -- than a click that does nothing.
    if Inventory.ContextActions[action] == nil then
        return false, ("%s isn't available right now"):format(opt and opt.label or (def.name or slotData.item))
    end

    Log.item(player.charId, 'ctx_' .. action, slotData)
    -- The dispatcher reports a throw itself, and hands a satellite the sheet. A handler's
    -- `false, 'why'` comes back as `refused`, answered here so the player sees it.
    local _, _, refused = Inventory.runContextAction(action, source, player, slotData, container, slot)
    if refused then return false, refused end
end)

--- Context menu: an option marked `anywhere`, on an item that is not on the player: in a boot, a glovebox, a
--- stash, a bag or wallet, a resource's panel. `at` is resolved and authorised by the 'addr' param (the player
--- has that store open). The option must say `anywhere`: the rest are written for the pockets.
SecureEvent('whip_core:server:storeContextAction', {
    rateLimit = 500,
    params = {
        {'action', 'string', 32},
        {'at', 'addr'},
    },
}, function(source, player, action, at)
    if not player.inventory then return end

    local slotData = at.store.kind.get(at.store.handle, at.slot)
    if not slotData or not slotData.item then return end

    local opt = Inventory.optionFor(slotData.item, action)
    if not opt or opt.anywhere ~= true then return end

    local allowed, why = Inventory.optionAllowed(source, player, opt, slotData)
    if not allowed then return false, why end

    if Inventory.ContextActions[action] == nil then
        return false, ("%s isn't available right now"):format(opt.label)
    end

    Log.item(player.charId, 'ctx_' .. action, slotData)
    local _, _, refused = Inventory.runContextActionAt(action, source, player, slotData, Stores.addressOf(at.store, at.slot) --[[@as table]])
    if refused then return false, refused end
end)

--- Context menu: destroy the stack at an address — in the pockets, or in anything the player has
--- open: a stash, a boot, a glovebox, a wallet or bag, a resource's panel.
---
--- Through Stores.commitDestroy, so the store has its say (a read-only panel refuses, a panel's
--- onValidate is asked) and hears about it after (a wallet's contents are folded back).
---
--- Answered like a drag: the NUI removes the item the instant Destroy is clicked; this sends the
--- reply that op is waiting for, or refuses with the reason and the screen puts it back.
---
--- DEVELOPERS ONLY: whip.devtools with developer mode on. The menu offers Destroy only
--- then (js/inventory.js, inv.devMode); anyone else is refused here, and the screen puts the item back.
SecureEvent('whip_core:server:destroyItem', {
    rateLimit = 200,
    burst     = 3,
    ace       = 'whip.devtools',   -- with developer mode on (DevTools.aceRefusal)
    onReject  = revertOpAt(2),
    params = {
        {'at',   'addr'},
        {'opId', 'int', 0, 2147483647, 0},
    },
}, function(source, player, at, opId)
    local EVENT = 'whip_core:server:destroyItem'
    if not player.inventory then return refuseOp(EVENT, source, 'Not loaded', opId) end
    local locked = DbHealth.refusal()   -- items are locked while the database is down (db_health.lua)
    if locked then return refuseOp(EVENT, source, locked, opId) end

    -- Stamped before it goes, so the row that closes this item's timeline names the instance.
    local live = at.store.kind.get(at.store.handle, at.slot)
    if live and live.item then Log.ensureUid(live) end

    local isPockets = at.store.kind.id == 'player'
    -- The same reply bookkeeping storeMove keeps: a wallet's fold may answer the op itself.
    local detail = {
        item        = live and live.item,
        amount      = live and live.amount,
        metadata    = live and live.metadata,
        source      = source,
        awaitsReply = opId > 0,
        replied     = false,
    }
    local ok, err, removed, verdict = Stores.commitDestroy(at, {
        detail      = detail,
        onCommitted = function()
            -- The push announces whip_core:item:removed itself (Inventory.announceChanges).
            if isPockets then Inventory.noteChangeReason(source, 'destroyed by the player', nil) end
            if StoreMoveSyncClients(source, player, detail.awaitsReply, at) then detail.replied = true end
        end,
    })
    if not ok then
        refuseOp(EVENT, source, err or 'Could not destroy that', opId)
        -- What is really there, as storeMove's refusal does: in a shared stash the snapshot the
        -- screen reverts to may be older than somebody else's move.
        Stores.publishSlotsTo(source, at.store, { at.slot })
        return
    end
    if detail.awaitsReply and not detail.replied then
        TriggerClientEvent('whip_core:client:moveAck', source, opId)
    end
    if verdict == 'handled' or not removed then return end

    -- The row that closes the item's timeline. Outside the pockets it says where it was.
    Log.item(player.charId, 'destroyed', removed,
        (not isPockets) and { detail = 'from ' .. Log.storeLabel(at.store) } or nil)
end)

--- Split a stack into a second slot the framework chooses (Stores.freeSlot, the rule the NUI predicts
--- with). Its own event: a split has ONE address and no destination.
---
--- A move within one store (playerMove, mode 'split'), so the store has its say like a drag (a
--- panel's onValidate, a read-only panel, a wallet's fold), and it is answered like a drag.
SecureEvent('whip_core:server:splitItem', {
    rateLimit = 200,
    burst     = 5,   -- drag-and-drop: allow a short burst, then the interval applies
    onReject  = revertOpAt(3),
    params = {
        {'from', 'addr'},
        {'splitAmount', 'int', 1, 999999},
        {'opId', 'int', 0, 2147483647, 0},
    },
}, function(source, player, from, splitAmount, opId)
    local EVENT = 'whip_core:server:splitItem'
    local d = from.store.kind.get(from.store.handle, from.slot)
    if not d or not d.item then return refuseOp(EVENT, source, 'No item in that slot', opId) end
    if (d.amount or 0) <= 1 then return refuseOp(EVENT, source, 'Nothing to split', opId) end
    -- A non-stackable never shares a slot, and one that does would copy its metadata (a wallet's or
    -- a bag's contents) into both halves.
    local sdef = Config.Items[d.item]
    if not (sdef and sdef.stack) then return refuseOp(EVENT, source, 'That does not stack', opId) end
    -- A split always leaves at least one behind, as Stores.split always has.
    if splitAmount >= d.amount then splitAmount = d.amount - 1 end

    local free = Stores.freeSlot(from.store, d.item, d.metadata)
    if not free then return refuseOp(EVENT, source, 'No empty slot to split into', opId) end

    playerMove(EVENT, source, player, from, { store = from.store, slot = free }, splitAmount, 'split', opId)
end)

-- ============================================
-- Give mode's prop: the item in the hand, for everyone
-- ============================================
-- The item a player offers is a HELD PROP (server/held_props.lua), the server's like an emote's
-- bottle: made when give mode starts (giveHold), handed over in the give (giveItem below, on the
-- server's clock), dropped when give mode ends (the client's heldPropsDrop 'give').

local GIVE_BONE   = 57005               -- SKEL_R_Hand, where give mode holds it
local GIVE_BONE_L = 18905               -- SKEL_L_Hand: in a vehicle's left-hand seat, GTA throws out of the window left-handed
local GIVE_OFFSET = { 0.05, 0.0, 0.0 }
local GIVE_ROT    = { 0.0, 0.0, 0.0 }
-- The hand-off, as both clients play it (client/inventory.lua playGiveAnim): half a second to turn,
-- then the clip, whose middle is a second in. The receiver holds it for the second after that.
local HANDOFF_MS  = 1500
local RECEIVE_MS  = 1000

local giveHeld = {}   -- [source] = { item, model, at }: what give mode put in their hand, and when

---@param hand string|nil  'left' or 'right' (the default)
---@param item string|nil  its hold set in /whip → Items → Edit hand position (server/item_holds.lua), when it has one
local function giveProp(model, hand, item)
    local hold = item and ItemHolds.get(item, hand or 'right')
    return { model = model, bone = hand == 'left' and GIVE_BONE_L or GIVE_BONE,
             offset = hold and hold.offset or GIVE_OFFSET, rot = hold and hold.rot or GIVE_ROT }
end

--- Is `model` this item's own prop, or the stand-in for items without one? The client picks between
--- the two (it alone can tell whether the item's prop exists in its game files: Inventory.itemPropModel).
local function isItemProp(itemKey, model)
    local hash = GetHashKey(model)
    local def = Config.Items[itemKey]
    if def and def.prop and GetHashKey(def.prop) == hash then return true end
    return Config.DefaultGroundProp ~= nil and GetHashKey(Config.DefaultGroundProp) == hash
end

--- Give mode started: the item in that pocket slot goes in the player's hand, seen by everyone. In the hand
--- GTA throws with (`hand`, the client's: a vehicle's left-hand seat throws left-handed out of its window); asked
--- again with the other when they change seats.
SecureEvent('whip_core:server:giveHold', {
    rateLimit = 250,
    burst     = 3,
    params    = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id'},
        {'model', 'key', 80},
        {'hand', 'enum', { 'right', 'left' }, 'right'},
    },
}, function(source, player, container, slot, model, hand)
    if slot > (Config.ContainerSlots[container] or 0) then return false, 'Give failed — invalid slot' end
    local slotData = player.inventory and Inventory.getSlot(player.inventory, container, slot)
    if not slotData then return false, 'Give failed — item no longer in slot' end
    if not isItemProp(slotData.item, model) then return false, 'That prop cannot be held' end
    giveHeld[source] = { item = slotData.item, model = model, at = GetGameTimer() }
    HeldProps.give(source, { giveProp(model, hand, slotData.item) }, 'give')
end)

AddEventHandler('playerDropped', function()
    giveHeld[source] = nil
end)

--- Client requests give item to another player (give mode → E key)
SecureEvent('whip_core:server:giveItem', {
    rateLimit = 200,
    params = {
        -- 'id', not clamped ints: both are addresses, rejected rather than redirected.
        {'targetServerId', 'id'},
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id'},
        -- 'amount': refused if not a whole number of 1 or more; the slot caps it.
        {'giveAmount', 'amount'},
    },
}, function(source, player, targetServerId, container, slot, giveAmount)
    -- Every refusal below is `return false, 'why'`: shown to the player and recorded.
    local locked = DbHealth.refusal()   -- items are locked while the database is down (db_health.lua)
    if locked then return false, locked end

    -- The top of the slot range depends on which pocket, so it is checked here rather than in the
    -- schema.
    if slot > (Config.ContainerSlots[container] or 0) then
        return false, 'Give failed — invalid slot'
    end

    -- 1. Validate giver
    local giver = player
    if not giver.inventory then
        return false, 'Give failed — not loaded'
    end

    -- 2. Validate target
    if targetServerId == source then
        return false, 'Give failed — invalid target'
    end
    local target = Players[targetServerId]
    if not target or not target.inventory then
        return false, 'Give failed — target not loaded'
    end

    -- 3. Distance check (server authority, 4m buffer for movement)
    local giverPed  = GetPlayerPed(source)
    local targetPed = GetPlayerPed(targetServerId)
    if not giverPed or giverPed == 0 or not targetPed or targetPed == 0 then
        return false, 'Give failed — could not verify distance'
    end
    local giverCoords  = GetEntityCoords(giverPed)
    local targetCoords = GetEntityCoords(targetPed)
    local dist = #(giverCoords - targetCoords)
    if dist > 4.0 then
        return false, 'Give failed — too far away'
    end

    -- 4. Validate slot data
    local slotData = Inventory.getSlot(giver.inventory, container, slot)
    if not slotData then
        return false, 'Give failed — item no longer in slot'
    end

    local itemKey    = slotData.item
    local slotAmount = slotData.amount
    local metadata   = slotData.metadata

    -- Stamp the instance id before the move, so it crosses to the receiver inside
    -- the committed write and one timeline spans both owners.
    Log.ensureUid(slotData)
    metadata = slotData.metadata   -- ensureUid creates the table when there was none

    -- Clamp give amount to what's actually in the slot
    local amount = giveAmount
    if amount > slotAmount then amount = slotAmount end

    -- 5. Check target has space + weight — for THIS instance (its metadata: a loaded magazine, a full
    -- wallet), as canFitItem's own docstring asks.
    local canFit, capacity = Inventory.canFitItem(target.inventory, itemKey, amount, metadata)
    if not canFit then
        local def = Config.Items[itemKey]
        local defName = def and def.name or itemKey
        return false, "Give failed — the player's inventory is full (can hold "
            .. capacity .. ' more ' .. defName .. ')'
    end

    -- 6. Hand it over: one move between two real stores, checked at both ends before either changes.
    -- Weight is checked against the RECEIVER's containers.
    local fromStore = Stores.player(source, container)
    local toStore   = Stores.player(targetServerId, 'player')
    if not fromStore or not toStore then
        return false, 'Give failed — could not reach an inventory'
    end

    -- Which slot it lands in is the store's answer: the receiver's containers in order, so a full
    -- main inventory still finds room in an accessory. A container with the weight room, not only a
    -- free slot (slotAccepting does not weigh).
    local weight = Inventory.effectiveWeight(itemKey, amount, metadata)
    local destSlot, destStore
    for _, c in ipairs(PlayerContainers) do
        local candidate = Stores.player(targetServerId, c)
        if candidate and Inventory.canAcceptWeight(target.inventory, c, weight) then
            local s = Stores.slotAccepting(candidate, itemKey, amount, metadata)
            if s then
                destSlot, destStore = s, candidate
                break
            end
        end
    end

    if not destSlot then
        return false, 'Give failed — the player has no room for that'
    end

    -- Through commitMove, like every other move: the beforeMove hooks (a store kind or panel may
    -- refuse the item leaving), self-containment, persistence and the afterMove side effects.
    local ok, err = Stores.commitMove(
        { store = fromStore, slot = slot },
        { store = destStore, slot = destSlot },
        { mode = 'move', amount = amount, source = source })
    if not ok then
        return false, 'Give failed — ' .. (err or 'unknown error')
    end

    -- 8. Sync both inventories (immediate — items crossed players)
    Inventory.syncAndSave(source, giver)
    Inventory.syncAndSave(targetServerId, target)

    -- 9. Notify both players
    local def = Config.Items[itemKey]
    local defName = def and def.name or itemKey
    -- No names in the toasts (the name rule); the item log below keeps who.
    ShowSuccess(source,
        'Gave ' .. defName .. ' x' .. amount .. ' to player')
    ShowSuccess(targetServerId,
        'Received ' .. defName .. ' x' .. amount .. ' from player')

    -- 10. Play handoff animation on both clients (pass itemKey for prop handoff)
    TriggerClientEvent('whip_core:client:playGiveAnim', source, targetServerId, true, itemKey)
    TriggerClientEvent('whip_core:client:playGiveAnim', targetServerId, source, false, itemKey)

    -- ...and the item crosses hand to hand where everyone sees it, on the server's clock: out of the
    -- giver's at the clip's middle, into the receiver's for a second. The model is the one give mode
    -- held (giveHold), or the item's own. The giver's hand is left alone if they started give mode
    -- again since, and the receiver's when it holds anything (taking theirs would not give it back).
    -- The receiver's is tagged 'take', so their own give mode's cleanup can't take it early.
    local heldNow = giveHeld[source]
    giveHeld[source] = nil
    local handModel = (heldNow and heldNow.item == itemKey and heldNow.model)
        or (def and def.prop) or Config.DefaultGroundProp
    local handOffAt = GetGameTimer()
    local function startedSince(src)
        local h = giveHeld[src]
        return h ~= nil and h.at >= handOffAt
    end
    SetTimeout(HANDOFF_MS, function()
        if not startedSince(source) then HeldProps.drop(source, 'give') end
        if handModel and Players[targetServerId] and HeldProps.tagOf(targetServerId) == nil then
            HeldProps.give(targetServerId, { giveProp(handModel, 'right', itemKey) }, 'take')
            SetTimeout(RECEIVE_MS, function() HeldProps.drop(targetServerId, 'take') end)
        end
    end)

    -- 11. Fire event for other scripts (whip_core:item:given).
    WhipEmit('whip_core:item:given',
        { source = source, target = targetServerId, item = itemKey, amount = amount })

    -- Both timelines see the handoff, and the item's own timeline shows the change
    -- of hands as two rows sharing one uid.
    local handed = { item = itemKey, amount = amount, metadata = metadata }
    Log.item(giver.charId, 'gave', handed, { detail = 'to ' .. target.fullName })
    Log.item(target.charId, 'received', handed, { detail = 'from ' .. giver.fullName })
end)

-- ============================================
-- Ground Item Events (client → server)
-- ============================================

--- A drop, throw or place whose ground row failed: the taken stack goes back where it came from, or
--- anywhere in that store it fits.
---
--- When it fits nowhere (the slot filled, or the weight changed, while the ground INSERT waited): at
--- the player's feet, and if even that fails it is logged lost with a CRITICAL line.
---@param source number
---@param player WhipPlayer
---@param fromStore table
---@param slot number
---@param removed table  { item, amount, metadata } — what Stores.take gave back
---@param what string    'drop' | 'throw' | 'place', for the log
local function putBackTaken(source, player, fromStore, slot, removed, what)
    -- Owed again once it is back: the flush may have written the pocket without the item during the
    -- ground INSERT's wait.
    local function backIn(at)
        if not Stores.place(fromStore, at, removed.item, removed.amount, removed.metadata) then return false end
        Stores.markDirty(fromStore)
        return true
    end
    if backIn(slot) then return end
    local spare = Stores.slotAccepting(fromStore, removed.item, removed.amount, removed.metadata)
    if spare and backIn(spare) then return end
    if Inventory.dropAtFeet(source, player, removed.item, removed.amount, removed.metadata) then
        -- And said where it went: the timeline read 'took' and then nothing.
        Log.item(player.charId, 'dropped', removed,
            { detail = what .. ' failed — put at their feet instead' })
        return
    end
    print(('[whip_core:ground] CRITICAL: %s x%s (%s by %s) could not go on the ground OR back into the inventory — lost')
        :format(tostring(removed.item), tostring(removed.amount), what, tostring(player.charId)))
    Log.lost(player.charId, removed.item, removed.amount, what .. ' failed and could not be put back')
end

--- Saves the pockets first and refuses while they can't be saved: the ground is written on the spot,
--- so a stuck pocket save would mean the item on the ground AND in the pocket after a restart.
--- Yields, so call it before reading any slot.
---@return boolean ok, string|nil why
local function pocketsSaved(source, player)
    local locked = DbHealth.refusal()   -- items are locked while the database is down (db_health.lua)
    if locked then return false, locked end
    local store = Stores.player(source, 'player')
    -- Pockets held still while a bank write that fills them is out (Stores.freeze, the ATM): settling
    -- now would write its notes to disk before the debit.
    if store and Stores.isFrozen(store.unit) then return false, 'Paying — wait a moment' end
    if not store or not Stores.settle(store.unit) then
        return false, 'Saving is not working right now. Try again in a moment.'
    end
    -- The wait can outlast the session (a logout waits only 2 s for handlers in flight).
    if player.closing or Players[source] ~= player then return false, 'Not loaded' end
    if Stores.isFrozen(store.unit) then return false, 'Paying — wait a moment' end   -- frozen in the wait
    return true
end

--- Where a drop lands: the spot the player's game found (client/ground.lua findDropSpot: only a client
--- can see walls), taken when it is within the Ground panel's reach of the player, at a random
--- resting angle. Nil when it is not.
---@return number|nil x, number|nil y, number|nil z, number|nil heading
local function dropSpot(source, x, y, z)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    local p = GetEntityCoords(ped)
    local reach = Config.GroundItemPickupRange or 2.0
    if (x - p.x) ^ 2 + (y - p.y) ^ 2 > reach * reach or math.abs(z - p.z) > 3.0 then return nil end
    return x, y, z, math.random() * 360.0
end

--- Player drags item from inventory to Ground panel (drop at feet)
SecureEvent('whip_core:server:dropToGround', {
    rateLimit = 200,
    onReject  = revertOpAt(4),   -- see revertOpAt at the top of this file
    params = {
        {'fromContainer', 'enum', PlayerContainers, 'player'},
        -- 'id', not 'int': a slot is an address, rejected rather than clamped (as in the drop-one
        -- and pickup events below).
        {'fromSlot', 'id', 1, POCKET_SLOT_MAX},
        {'amount', 'int', 1, 999999},
        -- The NUI's optimistic-operation id, echoed back on every refusal so the client
        -- reverts exactly the drop that failed — the same contract storeMove carries.
        {'opId', 'int', 0, 2000000000, 0},
        -- Where it lands, found by the player's game (dropSpot).
        {'x', 'number', -10000, 10000},
        {'y', 'number', -10000, 10000},
        {'z', 'number', -1000, 2000},
    },
}, function(source, player, fromContainer, fromSlot, amount, opId, x, y, z)
    local EVENT = 'whip_core:server:dropToGround'
    if not player.inventory then
        refuseOp(EVENT, source, 'Not loaded', opId)
        return
    end
    local saved, why = pocketsSaved(source, player)
    if not saved then
        refuseOp(EVENT, source, why, opId)
        return
    end

    local slotData = Inventory.getSlot(player.inventory, fromContainer, fromSlot)
    if not slotData then
        refuseOp(EVENT, source, 'No item in slot', opId)
        return
    end

    local itemKey  = slotData.item
    local metadata = slotData.metadata
    local slotAmount = slotData.amount

    -- Default to full stack if amount not specified or exceeds slot
    if not amount or amount <= 0 or amount > slotAmount then
        amount = slotAmount
    end

    local dropX, dropY, dropZ, heading = dropSpot(source, x, y, z)
    if not dropX then
        refuseOp(EVENT, source, 'Nowhere to place!', opId)
        return
    end

    -- Take it off the player through the store (take() knows emptying a slot from reducing a stack).
    -- Ground is deliberately NOT a store kind: a ground item is a database row with a world position,
    -- so this half is a take and the other half is a create.
    local fromStore = Stores.player(source, fromContainer)
    if not fromStore then
        refuseOp(EVENT, source, 'Could not reach your inventory', opId)
        return
    end

    local took, takeErr, removed = Stores.take(fromStore, fromSlot, amount)
    if not took or not removed then
        refuseOp(EVENT, source, takeErr or 'Could not drop that', opId)
        return
    end
    -- Owed at once, before the ground INSERT below yields (take() only changes memory). markDirty
    -- does no I/O.
    Stores.markDirty(fromStore)

    -- Stamp the instance on the taken stack — the same metadata table the ground row
    -- stores and the next pickup carries back into a pocket, so the timeline survives
    -- the trip through the floor.
    Log.ensureUid(removed)
    metadata = removed.metadata

    -- Create ground item
    local groundItem = GroundItems.create(itemKey, amount, metadata, dropX, dropY, dropZ, heading, player.charId)
    if not groundItem then
        -- Put it back where it came from, or anywhere it fits if that slot is no longer free.
        putBackTaken(source, player, fromStore, fromSlot, removed, 'drop')
        refuseOp(EVENT, source, 'Failed to create ground item', opId)
        return
    end

    DevTools.refresh('gim')
    -- Flush, not save: the ground row is already on disk (create needs its id back), so a deferred
    -- inventory write would leave a crash window with the item on the ground AND in the pocket. The
    -- reply to the drag, when there is one, and a push of what they hold when the write failed.
    if not Inventory.syncAndFlush(source, player, opId > 0) then
        Inventory.syncToClient(source, player, opId > 0)
    end

    local def = Config.Items[itemKey]
    local defName = def and def.name or itemKey
    ShowSuccess(source,
        'Dropped ' .. defName .. ' x' .. amount)

    Log.item(player.charId, 'dropped', groundItem,
        { x = groundItem.x, y = groundItem.y, z = groundItem.z })
end)

--- Player drags one item from held stack to Ground panel during drag (right-click drop-one)
SecureEvent('whip_core:server:dropOneToGround', {
    rateLimit = 200,
    onReject  = revertOpAt(3),   -- see revertOpAt at the top of this file
    params = {
        {'fromContainer', 'enum', PlayerContainers, 'player'},
        {'fromSlot', 'id', 1, POCKET_SLOT_MAX},
        {'opId', 'int', 0, 2000000000, 0},   -- see dropToGround above
        {'x', 'number', -10000, 10000},      -- where it lands (dropSpot)
        {'y', 'number', -10000, 10000},
        {'z', 'number', -1000, 2000},
    },
}, function(source, player, fromContainer, fromSlot, opId, x, y, z)
    local EVENT = 'whip_core:server:dropOneToGround'
    if not player.inventory then
        refuseOp(EVENT, source, nil, opId, 'Not loaded')
        return
    end
    local saved, why = pocketsSaved(source, player)
    if not saved then
        refuseOp(EVENT, source, why, opId)
        return
    end

    local slotData = Inventory.getSlot(player.inventory, fromContainer, fromSlot)
    if not slotData or slotData.amount <= 0 then
        -- Answered, so the drag does not sit in the NUI's queue waiting for a reply that never comes.
        refuseOp(EVENT, source, nil, opId, 'No item in slot')
        return
    end

    local itemKey  = slotData.item
    local metadata = slotData.metadata

    local dropX, dropY, dropZ, heading = dropSpot(source, x, y, z)
    if not dropX then
        refuseOp(EVENT, source, 'Nowhere to place!', opId)
        return
    end

    -- Take one, through the store, as dropToGround above.
    local fromStore = Stores.player(source, fromContainer)
    if not fromStore then
        refuseOp(EVENT, source, 'Could not reach your inventory', opId)
        return
    end

    local took, takeErr, removed = Stores.take(fromStore, fromSlot, 1)
    if not took or not removed then
        refuseOp(EVENT, source, takeErr or 'Failed to drop item', opId)
        return
    end
    Stores.markDirty(fromStore)   -- owed before the ground INSERT yields (see dropToGround)

    -- Same instance stamp as dropToGround — the single unit that hits the ground
    -- carries the id the rest of the stack already had (a drop-one is a split whose
    -- halves deliberately share their past).
    Log.ensureUid(removed)
    metadata = removed.metadata

    -- Create ground item (1 unit)
    local groundItem = GroundItems.create(itemKey, 1, metadata, dropX, dropY, dropZ, heading, player.charId)
    if not groundItem then
        -- Put the one unit back where it came from, or anywhere it fits.
        putBackTaken(source, player, fromStore, fromSlot, removed, 'drop')
        refuseOp(EVENT, source, 'Failed to drop item', opId)
        return
    end

    -- Save inventory (ground item already in DB from GroundItems.create). Flush, not save: the
    -- compensating action below branches on the result.
    local saveOk = Inventory.syncAndFlush(source, player, opId > 0)
    if not saveOk then
        -- Compensating action: undo the ground item, then put the unit back through the store. Only
        -- if the ground row really went: if it could not be deleted the drop stands (memory agrees,
        -- and the inventory's write is still owed), and the player is shown what they hold.
        if not GroundItems.delete(groundItem.id) then
            print(('[whip_core:ground] drop-one by %s: inventory save failed and the ground row %s could not be undone — the drop stands')
                :format(tostring(player.charId), tostring(groundItem.id)))
            DevTools.refresh('gim')
            Inventory.syncToClient(source, player, opId > 0)
            return
        end
        putBackTaken(source, player, fromStore, fromSlot, removed, 'drop')
        refuseOp(EVENT, source, 'Save failed, try again', opId)
        return
    end

    DevTools.refresh('gim')
    Log.item(player.charId, 'dropped', groundItem,
        { amount = 1, x = groundItem.x, y = groundItem.y, z = groundItem.z })
end)

--- What a ground pile carries into the pockets.
---
--- A pile that fits ONE slot keeps its identity: a bare one is filled in by the generator first
--- (keeping any uid it had), then stamped as before. A pile that needs SEVERAL slots carries no pile
--- uid: a bare one goes in with no metadata, so addItem runs the generator per slot; one with real
--- metadata goes in without its uid. Each slot is stamped at its next logged touch.
---@param gItem table  the live ground row
---@param ctx table|nil  who picks it up, for the item's generator (Inventory.metaContext)
---@return table|nil metadata  what to add it with
---@return boolean single  true when the pile's uid rides into the pocket
local function pickupMetadata(gItem, ctx)
    local def = Config.Items[gItem.item]
    local perSlot = (def and def.stack and def.maxStack) and def.maxStack or 1
    -- What says where the pile lay (GroundItems.PILE_KEYS) stays with the pile: the item comes up without it
    local pile = type(gItem.metadata) == 'table' and gItem.metadata or nil
    if pile then
        for k in pairs(GroundItems.PILE_KEYS) do
            if pile[k] ~= nil then
                local copy = {}
                for mk, v in pairs(pile) do if not GroundItems.PILE_KEYS[mk] then copy[mk] = v end end
                gItem.metadata = copy
                break
            end
        end
    end
    local meta = gItem.metadata
    local bare = meta == nil or next(meta) == nil
        or (next(meta) == 'uid' and next(meta, 'uid') == nil)

    if (gItem.amount or 1) <= perSlot then
        if bare then
            local fresh = Inventory.runMetaGen(Inventory.MetaGenerators and Inventory.MetaGenerators[gItem.item],
                gItem.item, ctx)
            if fresh then
                fresh.uid = meta and meta.uid or nil
                gItem.metadata = fresh
            end
        end
        Log.ensureUid(gItem)
        return gItem.metadata, true
    end

    if bare then return nil, false end
    local copy = {}
    for k, v in pairs(meta) do
        if k ~= 'uid' then copy[k] = v end
    end
    return copy, false
end

--- The pickup's timeline row: against the pile's uid when it has one (its history ends here, or
--- carries on in the pocket), plainly otherwise — a uid minted now would name nothing that exists.
local function logPickup(charId, gItem, single)
    if single or (gItem.metadata and gItem.metadata.uid) then
        Log.item(charId, 'picked_up', gItem)
    else
        Log.write(charId, 'picked_up', { itemKey = gItem.item, amount = gItem.amount })
    end
end

--- What a player is told when their pockets take none of a pile (Inventory.canFitItem's `full`).
local function noRoomWords(full)
    return full == 'Too heavy' and 'Too heavy to carry any more' or 'Your pockets are full'
end

--- Pick up as much of a ground pile as the pockets take now (274 of a 999 pile, not a refusal): all of it, and the row
--- goes, or part, and the pile keeps the rest, as a split leaves it. Off the ground first, then in, as
--- every ground path here: a failure loses rather than duplicates, and what could not go in goes back on the ground.
--- `at` = { container, slot }: the slot the player dropped it on, honoured when it fits there. The caller holds the
--- pile's lock; it is released on every path.
---@param gItem table  the live ground row, locked
---@param at table|nil
---@return table|nil got  { taken = { item, amount, metadata } (for the log), single, meta (what it went in with), left }
---@return string|nil why
local function takeFromPile(source, player, gItem, at)
    local id, total = gItem.id, gItem.amount or 1
    -- WITH the item's metadata: without it a full bag weighed as an empty one.
    local _, room, full = Inventory.canFitItem(player.inventory, gItem.item, total, gItem.metadata)
    if (room or 0) < 1 then
        GroundItems.unlock(id)
        return nil, noRoomWords(full)
    end
    local take = math.min(room, total)
    local part = take < total

    -- What goes in. All of it: the row itself, stamped (pickupMetadata), since the row goes. Part: a copy, so the pile
    -- keeps its own; part of a pile that does not stack leaves the pile its uid, as a split does.
    local def = Config.Items[gItem.item]
    local taken = gItem
    if part then
        local meta = Inventory.copyMetadata(gItem.metadata)
        if type(meta) == 'table' and not (def and def.stack) then meta.uid = nil end
        taken = { item = gItem.item, amount = take, metadata = meta }
    end
    local pickCtx = Inventory.metaContext(source, 'pickup')
    local addMeta, single = pickupMetadata(taken, pickCtx)

    -- GroundItems.delete and setAmount are write-through (row, cache, grid and broadcast in one call): once one
    -- returns true, what is taken exists NOWHERE, and everything after is an ADD into a live cache, which can't
    -- overwrite another viewer's work.
    local off
    if part then off = GroundItems.setAmount(id, total - take) else off = GroundItems.delete(id) end
    if not off then
        GroundItems.unlock(id)
        return nil, 'Could not pick that up, try again'
    end

    -- Stores.place (a conjure: it is off the ground) brings the TARGETED container's weight limit, a metadata
    -- comparison before merging, and the maxStack cap. Not more than one slot holds: place() into an empty slot would
    -- take it whole (three wallets sharing one metadata table); addUpTo lays it out a stack (or, for a non-stackable,
    -- one) a slot, the pockets first, then the strip.
    local perSlot = (def and def.stack and def.maxStack) and def.maxStack or 1
    local added, err = 0, nil
    if at and take <= perSlot then
        local target = Stores.player(source, at.container)
        if target and Stores.place(target, at.slot, gItem.item, take, addMeta) then added = take end
    end
    if added == 0 then added, err = Inventory.addUpTo(player.inventory, gItem.item, take, addMeta, pickCtx) end

    -- What did not go in goes back: onto the pile it came off, or, the row gone, as a new one where it lay, placed flag
    -- and tilt and all (a placed item goes back on its table at its angle). CHECKED: if even that fails it exists
    -- nowhere, and the log has to say so.
    local back = take - added
    if back > 0 then
        local put
        if part then
            put = GroundItems.setAmount(id, total - take + back)
        else
            put = GroundItems.create(gItem.item, back, gItem.metadata, gItem.x, gItem.y, gItem.z, gItem.heading or 0.0,
                player.charId, gItem.placed and { rx = gItem.rx, ry = gItem.ry } or nil)
        end
        if not put then
            print(('[whip_core:ground] CRITICAL: %s x%s picked up by %s could not go into the inventory OR back on the ground — lost')
                :format(tostring(gItem.item), tostring(back), tostring(player.charId)))
            Log.lost(player.charId, gItem.item, back, 'pickup failed and could not be put back')
        end
        DevTools.refresh('gim')
    end
    if part then GroundItems.unlock(id) end
    if added == 0 then return nil, err or 'Could not pick up item' end

    if added < take then taken = { item = taken.item, amount = added, metadata = taken.metadata } end
    return { taken = taken, single = single, meta = addMeta, left = total - added }
end

--- The pick up's toast: how many, and how many it had no room for.
local function pickedUpWords(got)
    local def = Config.Items[got.taken.item]
    local name = def and def.name or got.taken.item
    if got.left > 0 then
        return ('Picked up %s x%d, no room for the other %d'):format(name, got.taken.amount, got.left)
    end
    return ('Picked up %s x%d'):format(name, got.taken.amount)
end

--- Player drags from Ground panel to inventory (pickup)
SecureEvent('whip_core:server:pickupGroundItem', {
    rateLimit = 200,
    onReject  = revertOpAt(4),   -- see revertOpAt at the top of this file
    params = {
        {'groundItemId', 'id'},
        {'toContainer', 'enum', PlayerContainers, 'player'},
        {'toSlot', 'id', 1, POCKET_SLOT_MAX},
        {'opId', 'int', 0, 2000000000, 0},   -- see dropToGround above
    },
}, function(source, player, groundItemId, toContainer, toSlot, opId)
    local EVENT = 'whip_core:server:pickupGroundItem'
    if not player.inventory then
        refuseOp(EVENT, source, 'Not loaded', opId)
        return
    end
    local saved, why = pocketsSaved(source, player)
    if not saved then
        refuseOp(EVENT, source, why, opId)
        return
    end

    -- Race condition lock
    if not GroundItems.tryLock(groundItemId) then
        refuseOp(EVENT, source, 'Someone else is picking this up', opId)
        return
    end

    local gItem = GroundItems.getById(groundItemId)
    if not gItem then
        GroundItems.unlock(groundItemId)
        refuseOp(EVENT, source, 'Item no longer exists', opId)
        return
    end

    -- Distance check, through the one proximity test (IsPlayerNear, which also refuses a player
    -- still in the character creator). From where the pile is NOW: one still flying is wherever its
    -- object has got to (GroundItems.where).
    local gx, gy, gz = GroundItems.where(gItem)
    if not IsPlayerNear(source, gx, gy, gz, Config.GroundItemPickupRange + 5.0) then
        GroundItems.unlock(groundItemId)
        refuseOp(EVENT, source, 'Too far away', opId)
        return
    end

    -- As much as fits (takeFromPile): honouring the slot the player dropped it on, then wherever it fits. No failure
    -- duplicates:
    --   * coming off the ground fails — nothing has changed, and "try again" is honest.
    --   * going in fails      — what did not go in goes back on the ground.
    --   * the inventory write is merely owed — retried by the flush thread.
    local at = (toContainer and toSlot and toSlot >= 1) and { container = toContainer, slot = toSlot } or nil
    local got, refused = takeFromPile(source, player, gItem, at)
    if not got then
        refuseOp(EVENT, source, refused, opId)
        return
    end

    -- Flush rather than defer: the ground half already wrote through, so a deferred inventory write
    -- leaves a crash window with the item nowhere. The reply to the drag, when there is one, and a
    -- push of what they hold when the write failed (as quickPickup).
    if not Inventory.syncAndFlush(source, player, opId > 0) then
        Inventory.syncToClient(source, player, opId > 0)
    end

    DevTools.refresh('gim')
    ShowSuccess(source, pickedUpWords(got))
    logPickup(player.charId, got.taken, got.single)
end)

--- The ground option `action` on `itemKey` (its definition's groundOptions: server/item_options.lua), or nil.
---@return table|nil
local function groundOptionOf(itemKey, action)
    local def = Config.Items[itemKey]
    for _, o in ipairs(def and def.groundOptions or {}) do
        if o.action == action then return o end
    end
    return nil
end

--- A pick up's ground option (Equip), checked before anything moves: the item's, an option of its own, allowed for
--- this player now, and something runs it. '' is Pick up alone.
---@return table|nil ground  the ground option, or nil for Pick up alone
---@return string|nil why  when it can't be done
local function groundOptionCheck(source, player, gItem, option)
    if option == '' then return nil, nil end
    local ground = groundOptionOf(gItem.item, option)
    local def = Config.Items[gItem.item]
    local opt = Inventory.optionFor(gItem.item, option)
    if not ground or (not opt and not (def and def.defaultAction == option)) then
        return nil, "That can't be done with this"
    end
    if opt then
        local allowed, no = Inventory.optionAllowed(source, player, opt, gItem)
        if not allowed then return nil, no end
    end
    if Inventory.ContextActions[option] == nil then
        return nil, ("%s isn't available right now"):format(ground.label)
    end
    return ground, nil
end

--- How near an E pick up may be: the interaction range and a small buffer.
local function quickPickupReach()
    return (Config.InteractActiveRange or 3.0) + 2.0
end

--- Where `item` went in the pockets: the slot holding its uid when it has one, else the first holding the item.
---@return string|nil container, number|nil slot, table|nil slotData
local function pocketHolding(cache, item, uid)
    local fc, fs, fd
    for _, c in ipairs(PlayerContainers) do
        for slot, d in pairs(cache[c] or {}) do
            if type(d) == 'table' and d.item == item then
                if uid ~= nil and type(d.metadata) == 'table' and d.metadata.uid == uid then return c, slot, d end
                if not fc then fc, fs, fd = c, slot, d end
            end
        end
    end
    return fc, fs, fd
end

--- E-key quick pickup: auto-places ground item in first available inventory slot.
---
--- `option`: one of the item's ground options (its groundOptions, server/item_options.lua: "Equip" on a gun). Checked
--- BEFORE anything moves (it is the item's, its option may be used by this player now, and something runs it); then
--- the item is picked up exactly as without it, and only once it is in the pockets is that option run on the slot it
--- landed in, as the inventory runs it (Inventory.runContextAction). '' (the default) is Pick up alone.
SecureEvent('whip_core:server:quickPickupGroundItem', {
    rateLimit = 200,
    params = { {'groundItemId', 'id'}, {'option', 'string', 32, ''} },   -- an address: rejected, never clamped
}, function(source, player, groundItemId, option)
    if not player.inventory then return end
    local saved, why = pocketsSaved(source, player)
    if not saved then return false, why end

    -- Each refusal is `return false, 'why'`: shown to the player and recorded.

    -- Race condition lock
    if not GroundItems.tryLock(groundItemId) then
        return false, 'Someone else is picking this up'
    end

    local gItem = GroundItems.getById(groundItemId)
    if not gItem then
        GroundItems.unlock(groundItemId)
        return false, 'Item no longer exists'
    end

    -- Distance check (interaction range + small buffer), through the one proximity test
    -- (IsPlayerNear, which also refuses a player still in the character creator). From where the
    -- pile is now: anyone in reach may grab a throw out of the air.
    local gx, gy, gz = GroundItems.where(gItem)
    if not IsPlayerNear(source, gx, gy, gz, quickPickupReach()) then
        GroundItems.unlock(groundItemId)
        return false, 'Too far away'
    end

    -- A ground option (Equip), asked before anything moves, so a refusal leaves the item where it lies.
    local ground, no = groundOptionCheck(source, player, gItem, option)
    if no then
        GroundItems.unlock(groundItemId)
        return false, no
    end

    -- As much as fits, off the ground first, then in (takeFromPile, as pickupGroundItem). It releases the lock.
    local got, refused = takeFromPile(source, player, gItem, nil)
    if not got then return false, refused end

    -- Flush rather than defer, as pickupGroundItem. syncAndFlush pushes the inventory when the write
    -- lands, so the push here is for a failed write only.
    if not Inventory.syncAndFlush(source, player) then
        Inventory.syncToClient(source, player)
    end

    DevTools.refresh('gim')
    ShowSuccess(source, pickedUpWords(got))
    logPickup(player.charId, got.taken, got.single)

    -- In the pockets: now the ground option, on the slot it landed in (found by its uid), as the inventory runs it.
    if ground then
        local container, slot, slotData = pocketHolding(player.inventory, gItem.item, got.meta and got.meta.uid)
        if not slot then return false, ("Picked up, but it couldn't be found to %s"):format(ground.label:lower()) end
        Log.item(player.charId, 'ctx_' .. option, slotData)
        local _, _, optRefused = Inventory.runContextAction(option, source, player, slotData, container, slot, { from = 'ground' })
        if optRefused then return false, optRefused end
    end
end)

--- Before the grab plays (client/ground.lua pickUpPile: no grab for a pick up that takes nothing): how
--- many of this pile the E pick up would take now, and of how many, or `false, why` (pockets full, too heavy, gone,
--- out of reach, an option it can't do). Nothing moves, and the pick up asks it all again.
SecureCallback('whip_core:server:groundPickupRoom', {
    params = { {'groundItemId', 'id'}, {'option', 'string', 32, ''} },
}, function(source, player, groundItemId, option)
    if not player.inventory then return false, 'Not loaded' end
    local saved, why = pocketsSaved(source, player)
    if not saved then return false, why end
    local gItem = GroundItems.getById(groundItemId)
    if not gItem then return false, 'Item no longer exists' end
    local gx, gy, gz = GroundItems.where(gItem)
    if not IsPlayerNear(source, gx, gy, gz, quickPickupReach()) then return false, 'Too far away' end
    local _, no = groundOptionCheck(source, player, gItem, option)
    if no then return false, no end
    local total = gItem.amount or 1
    local _, room, full = Inventory.canFitItem(player.inventory, gItem.item, total, gItem.metadata)
    if (room or 0) < 1 then return false, noRoomWords(full) end
    return math.min(room, total), total
end)

--- The ground pile a player is working on from their Nearby panel: locked, still there, and within
--- the pickup reach. Refuses (recorded, and the op reverted) and answers nil otherwise. The lock is
--- the caller's to release — GroundItems.delete releases it too.
---@param eventName string
---@param source number
---@param groundItemId number
---@param opId number
---@return table|nil gItem  the live cache row
local function groundPileInReach(eventName, source, groundItemId, opId)
    if not GroundItems.tryLock(groundItemId) then
        refuseOp(eventName, source, 'Someone else is using that', opId)
        return nil
    end
    local gItem = GroundItems.getById(groundItemId)
    if not gItem then
        GroundItems.unlock(groundItemId)
        refuseOp(eventName, source, 'Item no longer exists', opId)
        return nil
    end
    -- Splitting or destroying a pile in the air would leave half of it on the launch spot.
    if gItem.flight then
        GroundItems.unlock(groundItemId)
        refuseOp(eventName, source, 'Wait for it to land', opId)
        return nil
    end
    -- The same reach as a pickup: the Nearby panel lists what is within the pickup range.
    if not IsPlayerNear(source, gItem.x, gItem.y, gItem.z, Config.GroundItemPickupRange + 5.0) then
        GroundItems.unlock(groundItemId)
        refuseOp(eventName, source, 'Too far away', opId)
        return nil
    end
    return gItem
end

--- Context menu on the Nearby panel: split a pile on the ground into two piles in the same spot.
---
--- What it is for: a pickup takes a whole pile, so this is how a player takes PART of one — split
--- it, pick up the half they want.
---
--- Shrink first, then create: if the new pile cannot be made, the old one is put back; if even that
--- fails the split-off part is gone and the log says so. That order loses rather than duplicates,
--- the direction every ground path here takes (see pickupGroundItem).
SecureEvent('whip_core:server:splitGroundItem', {
    rateLimit = 200,
    burst     = 3,
    onReject  = revertOpAt(3),
    params = {
        {'groundItemId', 'id'},
        {'splitAmount', 'int', 1, 999999},
        {'opId', 'int', 0, 2147483647, 0},
    },
}, function(source, player, groundItemId, splitAmount, opId)
    local EVENT = 'whip_core:server:splitGroundItem'
    local gItem = groundPileInReach(EVENT, source, groundItemId, opId)
    if not gItem then return end

    local total = gItem.amount or 1
    if total <= 1 then
        GroundItems.unlock(groundItemId)
        return refuseOp(EVENT, source, 'Nothing to split', opId)
    end
    -- A split always leaves at least one behind.
    if splitAmount >= total then splitAmount = total - 1 end

    if not GroundItems.setAmount(groundItemId, total - splitAmount) then
        GroundItems.unlock(groundItemId)
        return refuseOp(EVENT, source, 'Could not split that, try again', opId)
    end

    -- Same spot, same way up: a placed item's tilt rides along so the new pile sits where the old one does.
    local placed = gItem.placed and { rx = gItem.rx, ry = gItem.ry } or nil
    -- A stacking item's halves share their past, uid and all (as a drop-one does). One that does NOT
    -- stack is a pile of separate things, so the uid stays with the old pile (two wallets sharing one
    -- uid would share one panel id).
    local newMeta = Inventory.copyMetadata(gItem.metadata)
    local def = Config.Items[gItem.item]
    if type(newMeta) == 'table' and not (def and def.stack) then newMeta.uid = nil end
    local pile = GroundItems.create(gItem.item, splitAmount, newMeta,
        gItem.x, gItem.y, gItem.z, gItem.heading or 0.0, player.charId, placed)
    if not pile then
        if not GroundItems.setAmount(groundItemId, total) then
            print(('[whip_core:ground] CRITICAL: splitting %s x%s on the ground (by %s) failed and could not be undone — %s lost')
                :format(tostring(gItem.item), tostring(total), tostring(player.charId), tostring(splitAmount)))
            Log.lost(player.charId, gItem.item, splitAmount, 'ground split failed and could not be undone')
        end
        GroundItems.unlock(groundItemId)
        return refuseOp(EVENT, source, 'Could not split that, try again', opId)
    end

    GroundItems.unlock(groundItemId)
    DevTools.refresh('gim')
    -- No inventory push answers this, so the op is acknowledged by id. The Nearby panel is
    -- redrawn by the ground broadcasts above.
    if opId > 0 then TriggerClientEvent('whip_core:client:moveAck', source, opId) end

    Log.item(player.charId, 'organised', pile,
        { detail = ('on the ground · %d split off a pile of %d'):format(splitAmount, total) })
end)

--- Context menu on the Nearby panel: destroy a pile on the ground. Developers only, as destroyItem.
SecureEvent('whip_core:server:destroyGroundItem', {
    rateLimit = 200,
    burst     = 3,
    ace       = 'whip.devtools',   -- with developer mode on (DevTools.aceRefusal); the NUI offers it only then
    onReject  = revertOpAt(2),
    params = {
        {'groundItemId', 'id'},
        {'opId', 'int', 0, 2147483647, 0},
    },
}, function(source, player, groundItemId, opId)
    local EVENT = 'whip_core:server:destroyGroundItem'
    local gItem = groundPileInReach(EVENT, source, groundItemId, opId)
    if not gItem then return end

    -- What it was, kept for the log: delete drops the cache row.
    local gone = {
        item = gItem.item, amount = gItem.amount, metadata = gItem.metadata,
        x = gItem.x, y = gItem.y, z = gItem.z,
    }
    if not GroundItems.delete(groundItemId) then
        GroundItems.unlock(groundItemId)
        return refuseOp(EVENT, source, 'Could not destroy that, try again', opId)
    end

    DevTools.refresh('gim')
    if opId > 0 then TriggerClientEvent('whip_core:client:moveAck', source, opId) end

    -- The row that closes the item's timeline.
    Log.item(player.charId, 'destroyed', gone,
        { detail = 'from the ground', x = gone.x, y = gone.y, z = gone.z })
end)

--- Player threw an item — relayed to the clients in network range with the flying object's network id:
--- each game nearby watches it (thrown hard into its own player, it knocks them down: client/inventory.lua,
--- watchThrows). Sent at once, before the launch is written.
SecureEvent('whip_core:server:throwStarted', {
    rateLimit = 200,
    params = { {'netId', 'id'} },
}, function(source, _, netId)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)
    SendToPlayers(PlayersInRange(c.x, c.y), 'whip_core:client:playerThrew', source, netId)
end)

--- Tennis ball throw landed — create ground item at landing position.
---
--- As it landed: a throw that came to rest sends the prop's own pose (`posed`, with tilt rx, ry and yaw
--- heading), and the row is born placed. Without `posed` (the prop timed out still moving, or never
--- existed) it is snapped upright.
SecureEvent('whip_core:server:throwItemLanded', {
    rateLimit = 200,
    params = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
        {'amount', 'int', 1, 999999},
        {'x', 'number', -10000, 10000},
        {'y', 'number', -10000, 10000},
        {'z', 'number', -1000, 2000},
        {'heading', 'number', 0, 360},
        {'rx', 'number', -180, 180, 0.0},
        {'ry', 'number', -180, 180, 0.0},
        {'posed', 'bool', false},
    },
}, function(source, player, container, slot, amount, x, y, z, heading, rx, ry, posed)
    local EVENT = 'whip_core:server:throwItemLanded'
    if not player.inventory then return end
    local saved, why = pocketsSaved(source, player)
    if not saved then return false, why end

    local slotData = Inventory.getSlot(player.inventory, container, slot)
    if not slotData then
        RecordEventRejection(EVENT, source, 'No item in that slot')
        return
    end

    -- Distance sanity check: a throw's reach (GroundItems.withinThrow, further the further it fell),
    -- not the stream range.
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local dist = #(coords - vector3(x, y, z))
    if not GroundItems.withinThrow(coords, vector3(x, y, z)) then
        print(('[whip_core:ground] WARNING: throw landing rejected — too far (%.1fm) for %s [%d]'):format(
            dist, player.fullName, source
        ))
        RecordEventRejection(EVENT, source, 'Too far away')
        return
    end

    local itemKey  = slotData.item
    local metadata = slotData.metadata
    local slotAmount = slotData.amount

    if amount > slotAmount then amount = slotAmount end

    -- Take it, through the store. Refused by answering, not inventoryRevert: a throw is not one of
    -- the NUI's tracked drags, and a revert with no opId would roll back the oldest pending drag.
    local fromStore = Stores.player(source, container)
    if not fromStore then
        return false, 'Could not reach your inventory'
    end

    local took, takeErr, removed = Stores.take(fromStore, slot, amount)
    if not took or not removed then
        return false, takeErr or 'Could not throw that'
    end
    Stores.markDirty(fromStore)   -- owed before the ground INSERT yields (see dropToGround)

    -- Instance stamp on the taken stack — the ground row below stores this exact
    -- metadata table, so the timeline follows the item through the air.
    Log.ensureUid(removed)
    metadata = removed.metadata

    -- Create ground item at landing position (as it lay, when the client saw it come to rest)
    local groundItem = GroundItems.create(itemKey, amount, metadata, x, y, z, heading, player.charId,
        posed and { rx = rx, ry = ry } or nil)
    if not groundItem then
        -- Put it back where it came from, or anywhere it fits.
        putBackTaken(source, player, fromStore, slot, removed, 'throw')
        Inventory.syncToClient(source, player)
        return false, 'Failed to throw item'
    end

    DevTools.refresh('gim')
    -- Flush, not save, as dropToGround. A failed write still pushes.
    if not Inventory.syncAndFlush(source, player) then Inventory.syncToClient(source, player) end

    local def = Config.Items[itemKey]
    local defName = def and def.name or itemKey
    ShowSuccess(source,
        'Threw ' .. defName .. ' x' .. amount)

    Log.item(player.charId, 'threw', groundItem,
        { x = groundItem.x, y = groundItem.y, z = groundItem.z })
end)

-- ---- A throw is a ground item from the moment it leaves the hand ----
--
-- The client names its flying object as it lets go (throwLaunched): the item leaves the pockets and the
-- pile exists at once, FLYING (GroundItems.create's `flight`), and anyone in reach may grab it out
-- of the air. When it stops, the thrower says how it lies (throwSettled) and GroundItems.settle
-- moves the pile there; clients draw it in place before the flying object is deleted. A thrower who
-- never says (a crash, a disconnect) is the watchdog's, in server/ground.lua. How far a throw may
-- carry is GroundItems.withinThrow's (ground.lua), here as at throwItemLanded.

--- The networked object a client just made, once the server has heard of it: the event naming it
--- can arrive a moment before the object does.
---@param netId number
---@param ms number
---@return number|nil entity
local function awaitEntity(netId, ms)
    local deadline = GetGameTimer() + ms
    while true do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
        if GetGameTimer() > deadline then return nil end
        Wait(50)
    end
end

--- A hash as one unsigned number, so the server's and GetHashKey's spellings compare.
local function uhash(h) return (math.tointeger(h) or 0) & 0xFFFFFFFF end

SecureEvent('whip_core:server:throwLaunched', {
    rateLimit = 200,
    params = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
        {'amount', 'int', 1, 999999},
        {'netId', 'id'},
    },
}, function(source, player, container, slot, amount, netId)
    local EVENT = 'whip_core:server:throwLaunched'
    -- Every refusal also tells the thrower's game to drop its flying object: the item never left.
    local function refuse(why, recorded)
        if recorded then RecordEventRejection(EVENT, source, recorded) end
        TriggerClientEvent('whip_core:client:throwRefused', source, netId)
        return false, why
    end
    if not player.inventory then return refuse(nil) end
    local saved, why = pocketsSaved(source, player)
    if not saved then return refuse(why) end

    local slotData = Inventory.getSlot(player.inventory, container, slot)
    if not slotData then return refuse(nil, 'No item in that slot') end

    -- The object is theirs and of this item: their own networked object, of the item's model
    -- (or the box an item without one throws as), not far off. A ground row must not be pinned to
    -- somebody's car.
    local entity = awaitEntity(netId, 1500)
    if not entity then return refuse('The throw was lost') end
    -- Read again after the wait (a move can land in it). Nothing yields between here and the take.
    slotData = player.inventory and Inventory.getSlot(player.inventory, container, slot)
    if not slotData then return refuse(nil, 'No item in that slot') end
    if GetEntityType(entity) ~= 3 or NetworkGetEntityOwner(entity) ~= source then
        return refuse(nil, 'not their own thrown object')
    end
    local def = Config.Items[slotData.item]
    local model = uhash(GetEntityModel(entity))
    if model ~= uhash(GetHashKey((def and def.prop) or Config.DefaultGroundProp))
        and model ~= uhash(GetHashKey(Config.DefaultGroundProp)) then
        return refuse(nil, 'the thrown object is not that item')
    end
    local at = GetEntityCoords(entity)
    local ped = GetPlayerPed(source)
    if not GroundItems.withinThrow(GetEntityCoords(ped), at) then
        return refuse('Too far away', 'thrown object too far from the thrower')
    end

    local itemKey = slotData.item
    if amount > slotData.amount then amount = slotData.amount end

    -- Pockets still not held still after the wait (a bank write that fills them can freeze them inside
    -- it). Nothing yields between here and the take.
    local pockets = Stores.player(source, 'player')
    if pockets and Stores.isFrozen(pockets.unit) then return refuse('Paying — wait a moment') end

    -- Taken now, through the store, as throwItemLanded does at the landing.
    local fromStore = Stores.player(source, container)
    if not fromStore then return refuse('Could not reach your inventory') end
    local took, takeErr, removed = Stores.take(fromStore, slot, amount)
    if not took or not removed then return refuse(takeErr or 'Could not throw that') end
    Stores.markDirty(fromStore)
    Log.ensureUid(removed)

    local groundItem = GroundItems.create(itemKey, amount, removed.metadata, at.x, at.y, at.z,
        GetEntityHeading(entity), player.charId, nil, { netId = netId, owner = source })
    if not groundItem then
        putBackTaken(source, player, fromStore, slot, removed, 'throw')
        Inventory.syncToClient(source, player)
        return refuse('Failed to throw item')
    end

    DevTools.refresh('gim')
    -- Flush, not save, as throwItemLanded.
    if not Inventory.syncAndFlush(source, player) then Inventory.syncToClient(source, player) end
    TriggerClientEvent('whip_core:client:throwAccepted', source, netId, groundItem.id)

    ShowSuccess(source, 'Threw ' .. ((def and def.name) or itemKey) .. ' x' .. amount)
    Log.item(player.charId, 'threw', groundItem, { x = groundItem.x, y = groundItem.y, z = groundItem.z })
end)

--- The thrower's game saw its throw come to rest: `posed` with the way it lies (yaw as heading, rx
--- and ry), or snapped upright when it never settled. Only the thrower may say, within a throw's
--- reach of where it left the hand; a landing far from where the server sees the object is put
--- where the server sees it, upright.
SecureEvent('whip_core:server:throwSettled', {
    rateLimit = 200,
    params = {
        {'groundId', 'id'},
        {'x', 'number', -10000, 10000},
        {'y', 'number', -10000, 10000},
        {'z', 'number', -1000, 2000},
        {'heading', 'number', 0, 360},
        {'rx', 'number', -180, 180, 0.0},
        {'ry', 'number', -180, 180, 0.0},
        {'posed', 'bool', false},
    },
}, function(source, _, groundId, x, y, z, heading, rx, ry, posed)
    local EVENT = 'whip_core:server:throwSettled'
    local owner = GroundItems.flightOwner(groundId)
    local data = GroundItems.getById(groundId)
    -- Already settled (the watchdog), or picked out of the air: nothing to say.
    if not owner or not data then return end
    if owner ~= source then
        RecordEventRejection(EVENT, source, 'not their throw')
        return
    end
    if not GroundItems.withinThrow(data, vector3(x, y, z)) then   -- data: the launch, while it flies
        RecordEventRejection(EVENT, source, 'landed too far from the launch')
        x, y, z, posed = data.x, data.y, data.z, false
    end
    local sx, sy, sz = GroundItems.where(data)
    if #(vector3(x, y, z) - vector3(sx, sy, sz)) > 3.0 then
        x, y, z, posed = sx, sy, sz, false
    end
    GroundItems.settle(groundId, x, y, z, heading, posed and { rx = rx, ry = ry } or nil)
end)

-- ---- A thrown item knocks people over — all on the clients ----
-- A player is knocked down by their own game when a throw flies into them on their screen (client/inventory.lua,
-- watchThrows: it hears of the throw from throwStarted, above); people of the street by the thrower's game. Nothing
-- here: a game only ever knocks down its own player.

--- Placing mode confirmed — create a ground item EXACTLY where the client's ghost stood.
--- Same skeleton as throwItemLanded above, with two deliberate differences: the distance
--- clamp is the placing reach rather than the throw's stream range, and the ground row is
--- born with `placed = true` so every client renders it at the exact z/heading instead of
--- snapping it to the ground (the whole point of the feature — a wallet ON the table).
SecureEvent('whip_core:server:placeItem', {
    rateLimit = 200,
    params = {
        {'container', 'enum', PlayerContainers, 'player'},
        {'slot', 'id', 1, POCKET_SLOT_MAX},
        {'amount', 'int', 1, 999999},
        {'x', 'number', -10000, 10000},
        {'y', 'number', -10000, 10000},
        {'z', 'number', -1000, 2000},
        {'heading', 'number', 0, 360},
        -- Surface tilt, so an item placed on a slope lies ON the slope everywhere.
        {'rx', 'number', -180, 180},
        {'ry', 'number', -180, 180},
    },
}, function(source, player, container, slot, amount, x, y, z, heading, rx, ry)
    if not player.inventory then return end
    local saved, why = pocketsSaved(source, player)
    if not saved then return false, why end

    local slotData = Inventory.getSlot(player.inventory, container, slot)
    if not slotData then
        RecordEventRejection('whip_core:server:placeItem', source, 'No item in that slot')
        return
    end

    -- Reach check. PlaceItemRange is measured from the CAMERA on the client, and in third
    -- person the camera sits metres behind the ped — so ped-to-point legitimately exceeds
    -- the reach. +6.0 covers the farthest third-person camera; beyond that is a modded
    -- client, and the surface itself cannot be validated server-side (same trust shape as
    -- throwItemLanded's landing point, just on a far shorter leash). Answered `false, why`, so it is
    -- recorded and the player told.
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local dist = #(coords - vector3(x, y, z))
    if dist > (Config.PlaceItemRange or 10.5) + 6.0 then
        print(('[whip_core:ground] WARNING: place rejected — too far (%.1fm) for %s [%d]'):format(
            dist, player.fullName, source
        ))
        return false, 'Too far away to place that'
    end

    local itemKey  = slotData.item
    local metadata = slotData.metadata
    local slotAmount = slotData.amount

    if amount > slotAmount then amount = slotAmount end

    -- Refused by answering — see throwItemLanded.
    local fromStore = Stores.player(source, container)
    if not fromStore then
        return false, 'Could not reach your inventory'
    end

    local took, takeErr, removed = Stores.take(fromStore, slot, amount)
    if not took or not removed then
        return false, takeErr or 'Could not place that'
    end
    Stores.markDirty(fromStore)   -- owed before the ground INSERT yields (see dropToGround)

    -- Instance stamp, same as the throw path above.
    Log.ensureUid(removed)
    metadata = removed.metadata

    -- The one birthplace of a placed row. The table form of the 9th arg carries the
    -- tilt; a bare `true` (older callers, tests) still just flags the row.
    local groundItem = GroundItems.create(itemKey, amount, metadata, x, y, z, heading, player.charId,
        { rx = rx, ry = ry })
    if not groundItem then
        -- Put it back where it came from, or anywhere it fits.
        putBackTaken(source, player, fromStore, slot, removed, 'place')
        Inventory.syncToClient(source, player)
        return false, 'Failed to place item'
    end

    DevTools.refresh('gim')
    -- Flush, not save, as throwItemLanded above. A failed write still pushes.
    if not Inventory.syncAndFlush(source, player) then Inventory.syncToClient(source, player) end

    local def = Config.Items[itemKey]
    local defName = def and def.name or itemKey
    ShowSuccess(source,
        'Placed ' .. defName .. ' x' .. amount)

    Log.item(player.charId, 'placed', groundItem,
        { x = groundItem.x, y = groundItem.y, z = groundItem.z })
end)

-- ============================================
-- Ground Item Proximity Sync
-- ============================================

--- Override broadcastCreate: only send to players whose synced cells include the item's cell
--- (PlayersNearPoint, server/player_lifecycle.lua).
---@diagnostic disable-next-line: duplicate-set-field -- replaces ground.lua's default on purpose
GroundItems.broadcastCreate = function(data)
    for _, src in ipairs(PlayersNearPoint(data.x, data.y)) do
        TriggerClientEvent('whip_core:client:groundItemCreated', src, data)
    end
end

--- Override broadcastUpdate the same way: a pile's amount changed (a split on the ground). Only the
--- players who were sent the pile in the first place can be holding it.
---@diagnostic disable-next-line: duplicate-set-field -- replaces ground.lua's default on purpose
GroundItems.broadcastUpdate = function(data)
    for _, src in ipairs(PlayersNearPoint(data.x, data.y)) do
        TriggerClientEvent('whip_core:client:groundItemUpdated', src, data.id, data.amount)
    end
end

--- Periodic proximity sync: detect player movement into new cells and send incremental data.
---
--- On Every (lifecycle.lua), so one error doesn't end the sync for the session.
Every('ground and door cell sync', function() return (Config.GroundSyncInterval or 1) * 1000 end, function()
    local streamRange = Config.GroundItemStreamRange or 100.0

    for src, syncData in pairs(GroundSync) do
        local player = Players[src]
        if player then
            local ped = GetPlayerPed(src)
            local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or nil

            -- Nothing to do until the player changes cell: the same cell gives the same square of
            -- cells, exactly. lastCell starts empty at login, so the first pass always runs.
            local cell = coords and GroundItems.cellKey(coords.x, coords.y)
            if cell and coords and cell ~= syncData.lastCell then
                syncData.lastCell = cell
                local currentCells = GroundItems.getNearbyCellKeys(coords.x, coords.y, streamRange)

                -- Find cells the player hasn't received yet
                local newCells = {}
                local hasNew = false
                for key in pairs(currentCells) do
                    if not syncData.syncedCells[key] then
                        newCells[key] = true
                        hasNew = true
                    end
                end

                if hasNew then
                    -- The new cells' whole contents, sent even when empty, and the cells left. Deletes
                    -- go only to the players holding a pile's cell, so the client forgets the cells it no
                    -- longer holds (each at least the stream range away) and drops what it holds in a
                    -- new cell that the batch does not carry: it holds exactly what it is told about.
                    local newItems = GroundItems.getItemsInCells(newCells)
                    local leftCells = {}
                    for key in pairs(syncData.syncedCells) do
                        if not currentCells[key] then leftCells[key] = true end
                    end
                    TriggerClientEvent('whip_core:client:groundItemsBatchAdd', src, newItems, newCells, leftCells)

                    -- Doors ride the same cell grant: lock changes go only to players already holding
                    -- a door's cell (Doors.updateState), so a player arriving is caught up here. Cells
                    -- sit ~75m+ out at the nearest, so the batch lands before the door is in reach; a
                    -- cell left and re-entered is re-granted. One batched event, not one per door.
                    --
                    -- A player with no GroundSync entry gets neither ground items nor door
                    -- states — one invariant, seeded at login, cleared at drop.
                    local doorStates = Doors.getStatesInCells(newCells)
                    if #doorStates > 0 then
                        TriggerClientEvent('whip_core:client:doorStatesBatch', src, doorStates)
                    end

                    -- Replace synced set with current view (safe: a cell granted again is caught up whole)
                    syncData.syncedCells = currentCells
                end
            end
        end
    end
end)
