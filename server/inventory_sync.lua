-- ============================================
-- Inventory sync: saving a player's inventory, telling their client, and giving items
-- ============================================
--
-- Part of the Inventory module (server/inventory.lua). Everything here is called at runtime.

-- ---- Build Inventory Payload ----

--- Build the base inventory payload for NUI (openInventory, openContainer, openShop, etc.)
--- Returns a table with all common fields. Callers add their specific fields on top.
---
--- The item definitions are sent only when the client says it lacks them: msgpack-encoding the whole
--- set on every open was most of openInventory's cost, and the client caches them since login.
---
--- Client-driven rather than tracked per player on purpose: a client that loses its copy simply says
--- so and is sent them again; no server-side flag can go stale. Only the plain inventory open carries
--- `haveDefs` on the wire (the path a player can spam); it is recorded on the player, and every other
--- opener (a stash, a boot, a shop, a satellite's panel) reads it from there.
---@param player table
---@param haveDefs boolean|nil  overrides the recorded value; nil means "use what the client last said"
---@return table
function Inventory.buildPayload(player, haveDefs)
    if haveDefs == nil then haveDefs = player._haveItemDefs end

    return {
        inventory     = Inventory.serialize(player.inventory),
        weights       = Inventory.buildWeights(player.inventory),
        itemDefs      = (not haveDefs) and Inventory.cachedItemDefs() or nil,
        charName      = player.fullName,
        charId        = player.charId,
        -- Cached on the player at load, not queried on every open.
        accountNumber = player.accountNumber,
        maxSlots      = Config.ContainerSlots,
        maxWeight     = Config.MaxWeight,
    }
end

-- ---- Inventory Sync Helper ----

--- Persist a player's inventory and sync it to the client.
---@param source number
---@param player WhipPlayer
---@param force boolean|nil  commit NOW regardless of the kind's declared durability
---@param quiet boolean|nil  persist only; do not push the inventory to the client
---@param reply boolean|nil  this push answers the player's own drag (see Inventory.syncToClient)
---@return boolean
local function syncAndPersist(source, player, force, quiet, reply)
    -- Whatever changed is announced first — before the save, so a failed write (which is owed, not
    -- undone) cannot hold back itemAdded / itemRemoved, and before a quiet return.
    Inventory.announceChanges(source, player)

    -- Routed through the store so the kind's declared durability decides whether this commits now or
    -- joins the flush queue. For a deferred kind `true` means the change is in memory and owed to
    -- disk: memory is the source of truth, and a write that later fails is quarantined and logged
    -- rather than rolled back.
    local store = Stores.player(source, 'player')
    local ok, saved, saveErr

    if store then
        ok, saved, saveErr = pcall(force and Stores.flushNow or Stores.save, store)
    else
        -- No resolvable session — an offline-admin cache, or a teardown that already dropped
        -- the handle. Write it directly rather than silently skipping the save.
        ok, saved, saveErr = pcall(Inventory.save, player.charId, player.inventory)
    end

    -- Two layers of failure: pcall catches a Lua error in save itself, and `saved` is save's own
    -- report of whether the transaction went through. Both are checked.
    if not ok or not saved then
        print(('[whip_core] Inventory.syncAndSave FAILED for %s [%d]: %s'):format(
            player.fullName, source, tostring(ok and saveErr or saved)))
        return false
    end

    if quiet then return true end

    -- Only sync to client after confirmed DB save
    Inventory.syncToClient(source, player, reply)
    return true
end

--- Save inventory to DB, then sync to client on success.
--- Returns true/false so callers can react to save failures.
---@param source number
---@param player WhipPlayer
---@param reply boolean|nil  true ONLY when this answers the player's own drag (see Inventory.syncToClient)
---@return boolean
function Inventory.syncAndSave(source, player, reply)
    return syncAndPersist(source, player, false, false, reply)
end

--- Save the inventory WITHOUT pushing it to the client.
---
--- For a change the client already shows by another route, made too often for a full push each
--- time: gunny's round count, on every shot. The next ordinary push (any other change, or opening
--- the inventory) carries it anyway.
---@param source number
---@param player WhipPlayer
---@return boolean
function Inventory.saveQuietly(source, player)
    return syncAndPersist(source, player, false, true)
end

--- Same, but commit to disk NOW rather than deferring.
---
--- For operations that pair an inventory change with a system that writes THROUGH. Dropping to the
--- ground: GroundItems.create writes at once (it needs the auto-increment id back), so deferring the
--- inventory half would let a crash put the item on the ground AND still in the pocket: duplication.
---
--- Stores.saveAll's rule, for paths where the other side is not a store at all. The compensating
--- rollbacks at those sites branch on the save result, which a deferred save can't give.
---@param source number
---@param player WhipPlayer
---@param reply boolean|nil  true ONLY when this answers the player's own drag (see Inventory.syncToClient)
---@return boolean
function Inventory.syncAndFlush(source, player, reply)
    return syncAndPersist(source, player, true, false, reply)
end

-- ============================================
-- Give or drop: the one place a full inventory is handled
-- ============================================
--
-- Give and move are different operations:
--
--   A GIVE brings an item in from outside the world: a reward, a purchase, a refund, an admin
--   spawn. If it will not fit, the item has nowhere else to be, so failing means DESTROYING it.
--   That is what this function exists to prevent.
--
--   A MOVE relocates an item that already exists: a ground pickup, a stash transfer, a slot
--   drag. If it will not fit, it stays where it is; a copy at the player's feet would DUPLICATE
--   it. Those paths must NOT call this (the ground pickup deletes its row only after a
--   successful add, so a failsafe drop there would make two).
--
-- Every give path routes through here so the policy lives in one place.
--
--- Put an item on the floor at a player's feet. THE ONLY drop implementation.
---
--- Split out from Inventory.giveOrDrop because shops need the drop WITHOUT the give: by the time a
--- purchase discovers there is no room, it has already taken the stock off the shelf, so
--- "try the inventory first" has happened and must not happen twice.
---
--- `coords` may be passed pre-captured. Shops do this deliberately — reading the ped position
--- part-way through a transaction can pick up a player who has since moved or disconnected.
---@param source number
---@param player WhipPlayer
---@param item string
---@param amount number|nil
---@param metadata table|nil
---@param coords vector3|nil  falls back to the player's current ped position
---@return number|nil groundItemId  the first pile's
function Inventory.dropAtFeet(source, player, item, amount, metadata, coords)
    if not coords then
        -- No ped means no feet: a player mid-disconnect cannot be given anything, and a
        -- ground item with no coordinates is worse than none.
        local ped = source and GetPlayerPed(source)
        if not ped or ped == 0 then return nil end
        coords = GetEntityCoords(ped)
    end
    if not coords then return nil end
    amount = amount or 1

    -- One pile per stack: a pile is what one inventory slot would hold (1 of an item that does not
    -- stack, maxStack of one that does), so taking a few is one drag. Past
    -- Config.MaxGroundPilesPerDrop piles the items are shared out evenly.
    local def = Config.Items[item]
    local perPile = (def and def.stack) and (def.maxStack or amount) or 1
    if perPile < 1 then perPile = 1 end
    local maxPiles = math.max(1, math.floor(tonumber(Config.MaxGroundPilesPerDrop) or 50))
    if math.ceil(amount / perPile) > maxPiles then perPile = math.ceil(amount / maxPiles) end

    -- pcall: the failsafe must never itself throw mid-transaction.
    --
    -- Nothing entered the inventory here. But what the caller took first (a swapped-out magazine, an attachment taken
    -- off: deferred, only marked) must land with the ground row, so AddItem's give-or-drop flushes the pockets right
    -- after it (giveOrDrop, below; audit 20, INV-1), as the DROP path in events_inventory does.
    -- GroundItems.create answers the ground item's whole record; the id is what this promises.
    --
    -- All or nothing: a pile that fails takes back the ones already made, so the caller's "it went to
    -- the ground" (or not) stays true of every item. Each pile its own copy of the metadata, as each
    -- inventory slot is (setSlot), and a little apart (a golden-angle spiral), never more than 0.35 m
    -- out: the server cannot see walls.
    local made, left, i = {}, amount, 0
    while left > 0 do
        local n = math.min(perPile, left)
        local r, a = math.min(0.35, 0.08 * math.sqrt(i)), i * 2.39996
        local meta = (i == 0) and metadata or Inventory.copyMetadata(metadata)
        local ok, data = pcall(GroundItems.create,
            item, n, meta,
            coords.x + r * math.cos(a), coords.y + r * math.sin(a), coords.z, 0.0,
            player and player.charId)
        if not ok or not data then
            for _, id in ipairs(made) do
                local called, gone = pcall(GroundItems.delete, id)
                if not (called and gone) then
                    -- Picked up in the moment, or the delete failed: that pile is real now. Said.
                    print(('[whip_core:ground] a split drop of %s could not take back pile #%s'):format(tostring(item), tostring(id)))
                end
            end
            return nil
        end
        made[#made + 1] = data.id
        left, i = left - n, i + 1
    end

    -- The Ground Item Manager dev tool holds a cached list; without this a dropped item is
    -- invisible to whoever is trying to work out where it went.
    DevTools.refresh('gim')
    return made[1]
end

--- Give an item to a player, dropping it at their feet if it will not fit anywhere.
---
--- Returns true when the item went to the ground: callers write `if not ok then <undo> end`, and
--- undoing a transaction whose item now exists in the world refunds twice or drops a second copy.
--- Read the third return when you need to tell the two apart. (This is whip_core's internal shape;
--- the AddItem export answers with the placement alone, or `false, reason`.)
---@param source number
---@param player WhipPlayer
---@param item string
---@param amount number|nil  a whole number of 1 or more; nil means 1
---@param metadata table|nil
---@param opts table|nil
---   container = 'player'   target ONE container instead of all
---   reason    = '...'      for the activity log (see below)
---   coords    = vector3    where to drop it if it does not fit, instead of the player's feet
---   noDrop    = true       refuse instead of dropping when it does not fit
---@return boolean ok
---@return string|false|nil err  false when it was given
---@return string|nil placement  'inventory' | 'ground' | nil
function Inventory.giveOrDrop(source, player, item, amount, metadata, opts)
    if not player or not player.inventory then return false, 'Player not loaded', nil end

    -- Not a give at all, so it must not reach the drop below: an unknown key or a bad amount is the
    -- caller's mistake, not "did not fit".
    if type(item) ~= 'string' or not Config.Items[item] then
        return false, ('Unknown item "%s"'):format(tostring(item)), nil
    end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR, nil end

    -- A pocket that is not one of the player's is the caller's mistake, not a full pocket, so it is
    -- refused like the two above rather than dropped. (AddItem calls this option `pocket`.)
    local only = opts and opts.container
    if only ~= nil and not Sanitize.enum(only, PlayerContainers) then
        return false, ('Invalid pocket "%s"'):format(tostring(only)), nil
    end

    -- Who it is for, for the item's generator (Inventory.metaContext).
    local metaCtx = Inventory.metaContext(source, 'given')
    local ok, err
    if only then
        ok, err = Inventory.addItem(player.inventory, only, item, amount, metadata, metaCtx)
    else
        ok, err = Inventory.addItemWithFallback(player.inventory, item, amount, metadata, metaCtx)
    end

    -- Every give is logged, because a give is an item entering the game: the moment a dupe would
    -- happen in. The reason is the caller's (opts.reason), or which resource asked through
    -- the AddItem export; see Log.gained in activity_log.lua.
    local why = (opts and opts.reason) or Log.byCaller()

    if ok then
        Log.gained(player.charId, item, amount or 1, why)
        -- The push below announces whip_core:item:added (Inventory.announceChanges); this says why.
        Inventory.noteChangeReason(source, why, Log.byCaller())
        Inventory.syncAndSave(source, player)
        -- `false`, NOT `nil`: giveOrDrop is what the AddItem EXPORT returns, and a FiveM export
        -- truncates its return list at the first nil (the placement would be lost).
        return true, false, 'inventory'
    end

    -- `noDrop`: this caller would rather the give simply fail — a sale it can still call off, say —
    -- than put the item on the ground. The server-wide switch is the same choice for everyone.
    if Config.DropOnFullInventory == false or (opts and opts.noDrop) then
        return false, err, nil
    end

    -- Made for them, then dropped: a bare pile gets its metadata when it is picked up,
    -- for whoever picks it up — so a SIM given to someone with full pockets would carry the finder's
    -- number. A pile of ONE slot is made for the recipient here; a bigger one stays bare, so each slot
    -- still gets its own run at pickup (an identity per item, see Inventory.addItem).
    local def0 = Config.Items[item]
    local perSlot = (def0 and def0.stack and def0.maxStack) and def0.maxStack or 1
    if metadata == nil and amount <= perSlot then
        metadata = Inventory.runMetaGen(Inventory.MetaGenerators[item], item, metaCtx)
    end

    if not Inventory.dropAtFeet(source, player, item, amount, metadata, opts and opts.coords) then
        return false, err, nil
    end
    -- The ground row is written; what the caller took to make this (only marked) is written now too, so a crash
    -- cannot leave it both on the ground and still where it came from (dropAtFeet's note).
    if Players[source] == player then Inventory.syncAndFlush(source, player) end
    Log.gained(player.charId, item, amount or 1,
        why and (why .. ' · dropped at their feet') or 'dropped at their feet')

    -- Say so. An item appearing on the floor unannounced reads as a bug, and a ground item is
    -- public — they need to know to pick it up before someone else does.
    -- A warning, not an error: nothing failed, the item is safe at their feet.
    local def = Config.Items[item]
    NotifyPlayer(source, ('Inventory full — %s dropped at your feet'):format((def and def.name) or item), 'warning')

    -- Deliberately NOT whip_core:item:added — nothing entered the inventory, and listeners that
    -- track what a player is carrying would be wrong. Ground items have their own events.
    --
    -- `err or false` so the third slot cannot be lost across the export boundary (as above).
    return true, err or false, 'ground'
end

--- Send inventory NUI update to client WITHOUT saving to DB.
--- Use this when the change has already been persisted (a store commit, a flush).
---
--- Every push is unsolicited unless it says it is a reply (house rule 7): the NUI's op queue
--- confirms its oldest pending drag on a reply, and only a handful of pushes really answer a drag
--- (storeMove's own sync or the panel fold standing in for it, dropToGround, dropOneToGround,
--- pickupGroundItem). A new push path is safe by default. A move that sends no reply at all is
--- acknowledged by id instead (whip_core:client:moveAck, from storeMove).
---@param source number
---@param player WhipPlayer
---@param reply boolean|nil  true ONLY when this answers the player's own drag
function Inventory.syncToClient(source, player, reply)
    -- The one place an inventory is pushed, so the one place item events are sure to be caught up
    -- (Inventory.announceChanges; a second call for the same change finds nothing new).
    Inventory.announceChanges(source, player)
    local invData = Inventory.serialize(player.inventory)
    -- Totalled from the weights serialize just worked out, not weighed a second time.
    local weights = Inventory.buildWeights(player.inventory, invData)
    TriggerClientEvent('whip_core:client:inventoryUpdate', source, {
        inventory   = invData,
        weights     = weights,
        unsolicited = not reply,
    })
    -- Only when the list changed (Vehicles.syncKeys).
    Vehicles.syncKeys(source, player)

    -- What a player carries changed, any way, a move between their own slots included: item:added /
    -- item:removed only fire when a COUNT changes, so a resource holding "the item in slot 4" (gunny's
    -- drawn gun) needs this. Fired here because every push comes through here ONCE per change; the one
    -- save that does not push, SetItemMetadata's `quiet`, never moves an item. A player's own live
    -- session only, as announceChanges.
    if Players[source] == player then
        WhipEmit('whip_core:inventory:changed', { source = source })
    end
end

-- ---- The player's own containers ----
--
-- The containers a player carries on their person are PlayerContainers. Anything that iterates or
-- reports on player inventory must cover all of them (`accessory` is the easy one to miss), so it is
-- one list rather than a phrase people retype.

--- Set form of the same list, for "is this one of the player's own containers?" tests.
---
--- Built from the list rather than written out: a chain of name comparisons is a container list in
--- disguise.
local IS_PLAYER_CONTAINER = {}
for _, c in ipairs(PlayerContainers) do IS_PLAYER_CONTAINER[c] = true end

--- Is this one of the containers a player carries (PlayerContainers)?
---@param name any
---@return boolean
function Inventory.isPlayerContainer(name)
    return IS_PLAYER_CONTAINER[name] == true
end

--- Build the weights table sent to the NUI for a player's inventory.
--- Single source of truth: do not hand-roll this.
---
--- Pass `serialized` (Inventory.serialize's answer for the same cache) when you have it: every row
--- already carries its weight `w`, so each item's `read` hook (across resources, for a satellite's
--- item) is not called a second time. Rounded the way Inventory.getWeight rounds, so the two agree.
---@param cache table
---@param serialized table|nil
---@return table
function Inventory.buildWeights(cache, serialized)
    local weights = {}
    for _, container in ipairs(PlayerContainers) do
        local rows = serialized and serialized[container]
        if rows then
            local total = 0
            for _, row in pairs(rows) do total = total + (row.w or 0) end
            weights[container] = math.floor(total * 100 + 0.5) / 100
        else
            weights[container] = Inventory.getWeight(cache, container)
        end
    end
    return weights
end
