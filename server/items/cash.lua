-- ============================================
-- Item: cash (Banknotes)
-- Non-usable — currency add/remove/query
-- ============================================

--- How many banknotes this player is carrying.
---
--- A THIN COUNT OF AN ITEM, and nothing more. The same argument that justifies
--- GetVehicleStat(id, 'fuel') sitting beside the generic stat API: a convenience over the general
--- path is fine, a second implementation of it is not. This must never gain behaviour that
--- Inventory.getItemCountAcrossContainers does not have.
---@return number
function WhipPlayer:getCash()
    if self.inventory then
        return Inventory.getItemCountAcrossContainers(self.inventory, 'cash')
    end
    -- Inventory not loaded yet — during construction, before the pockets exist. Zero rather than a
    -- stale mirror of a dropped column: "I do not know yet" and "you have nothing" are both wrong
    -- answers here, but only one of them can be mistaken for a real balance and written somewhere.
    return 0
end

--- Commit a cash change now and tell the client. A failed write is logged by
--- Inventory.syncAndFlush and left to the store's retry; the change itself has happened.
---
--- `withNext` (whip_core only, the ATM): only mark it, tied to the running action, so the bank write
--- that follows carries it in its own transaction (Stores.commitWithAction).
--- 'quiet': and do not show it yet; the caller shows it once that write lands (cash moved before the
--- debit commits could not be taken back if it failed).
local function persistCash(player, withNext)
    if withNext == 'quiet' and Players[player.source] == player then
        Inventory.saveQuietly(player.source, player)
        return
    elseif withNext and Players[player.source] == player then
        Inventory.syncAndSave(player.source, player)
    elseif Players[player.source] == player then
        Inventory.syncAndFlush(player.source, player)
    else
        -- Not (or no longer) the live session — construction, or teardown. Nothing to sync to.
        pcall(Inventory.save, player.charId, player.inventory)
    end
    TriggerClientEvent('whip_core:client:updateCash', player.source, player:getCash())
end

--- A whole number of banknotes, 1 or more, or nil.
---
--- The exports (AddPlayerCash, RemovePlayerCash) hand these methods whatever a satellite passed.
--- Refused, not floored: Sanitize.amount, the rule every item and bank call uses (strings, NaN,
--- infinity and fractions refused).
---@param amount any
---@return integer|nil
local function cashAmount(amount)
    return Sanitize.amount(amount)
end

--- Cash never drops: unlike AddItem, banknotes that will not fit are refused, not put on the
--- floor: a payout that "succeeded" onto the pavement is money the caller thinks it paid.
---@param amount number|nil
---@param why string|nil  for the activity log, e.g. 'ATM withdrawal'; defaults to the calling resource
---@param withNext boolean|'quiet'|nil  whip_core only: saved with the bank write that follows (see persistCash)
---@return boolean ok
---@return string|nil err  why not — a whole number of dollars, a loaded player, room
function WhipPlayer:addCash(amount, why, withNext)
    amount = cashAmount(amount)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    if not self.inventory then return false, 'Player not loaded' end

    local ok, err = Inventory.addItemWithFallback(self.inventory, 'cash', amount)
    if not ok then
        print(('[whip_core] addCash FAILED for %s [%d]: %s'):format(self.fullName, self.source, err or 'Unknown'))
        return false, err or 'No room for the cash'
    end

    -- Banknotes appearing is money entering the game; see Log.gained in activity_log.lua.
    Log.gained(self.charId, 'cash', amount, why or Log.byCaller())

    -- Cash is an item, so the push below announces whip_core:item:added for it like any other. This
    -- says why.
    Inventory.noteChangeReason(self.source, why or Log.byCaller(), Log.byCaller())

    -- Flushed through the store, not Inventory.save. Cash is paired with write-through systems —
    -- the ATM, the bank, shop refunds — so it must be on disk now, not a second from now; and the
    -- store path is the one that knows about an in-flight flush of this same character and about
    -- transfer groups. It also sends the inventory update, so the banknotes appear in the grid
    -- rather than only in the cash counter. Memory is authoritative whatever the write says.
    persistCash(self, withNext)
    return true
end

---@param amount number|nil
---@param why string|nil  for the activity log, e.g. 'ATM deposit'; defaults to the calling resource
---@param withNext boolean|'quiet'|nil  whip_core only: saved with the bank write that follows (see persistCash)
---@return boolean ok
---@return string|nil err  why not
function WhipPlayer:removeCash(amount, why, withNext)
    amount = cashAmount(amount)   -- see cashAmount
    if not amount then return false, Sanitize.AMOUNT_ERR end
    if not self.inventory then return false, 'Player not loaded' end

    local ok = Inventory.removeItemAcrossContainers(self.inventory, 'cash', amount)
    if not ok then
        -- Not a fault worth a console line: "they did not have it" is the everyday refusal.
        return false, 'Not enough cash'
    end

    Log.lost(self.charId, 'cash', amount, why or Log.byCaller())

    Inventory.noteChangeReason(self.source, why or Log.byCaller(), Log.byCaller())   -- see addCash
    persistCash(self, withNext)   -- see addCash
    return true
end
