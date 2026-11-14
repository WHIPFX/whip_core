-- ============================================
-- Cash left in the world: whose it was
-- ============================================
--
-- With Config.BlockOwnCharacterTransfers on, a player's characters pass no
-- money to each other: the bank half is server/bank.lua (Bank.notOwnOther), and this is the cash half. A new
-- character's starting cash, dropped or left in a boot for the player's main character to collect before the new
-- one is deleted and made again, is refused: "Your other character is linked to this item".
--
-- The money itself is never marked: notes stack with every other note, everywhere. What is remembered is where cash was
-- LEFT, and by whom:
--   GROUND PILES already say who dropped them (ground_items.createdBy): a pickup by another character of the same
--     player is refused (CashMarks.mayPickUp, from server/events_inventory.lua's pickups).
--   BOOTS, GLOVEBOXES, STASHES AND WALLETS hold everyone's cash in one stack, so each keeps a hidden tally: "this
--     character of that player left $N here". Another character of that player may take out only what the others
--     left (CashMarks.checkMove, from Stores.beforeMove); taking money out, by anyone, shrinks the tally
--     (CashMarks.noteMove, from Stores.afterMove). A wallet's tally goes by the wallet itself (its uid), so it
--     follows the wallet wherever it is carried, dropped or stashed.
--
-- HOW LONG: until the money is taken out. A tally line untouched for MARK_DAYS goes (a car or stash that was
-- deleted leaves nothing behind for ever).
-- WHAT IT COSTS: one small row per character per container they left cash in. Nothing is ever scanned: a move of
-- cash looks at the one container it touches. 200 new characters cost nothing until they put cash somewhere.
-- WHAT IT DOES NOT COVER: a third player passing it on (collusion), and things that are not cash.
--
-- The tally is kept whatever the setting, so switching it on later knows where cash already lies; only the
-- refusals follow the setting.

local CashMarks = {}
Stores.cashMarks = CashMarks

local CASH = 'cash'
local MARK_DAYS = 30
local LINKED = 'Your other character is linked to this item'

--- [markKey] = { [charId] = { userId, amount, at } }
local marks = {}
--- [markKey .. '|' .. charId] = { key, charId }: lines to write (the flush writes what memory holds then)
local dirty = {}

--- The tally key of a store cash can be left in, or nil for one that is not tracked (pockets, a basket, a shop, a
--- satellite's own kind). A wallet goes by its item's uid, not the panel's session, which changes every time it opens.
---@param store table
---@return string|nil
local function markKey(store)
    local kind = store and store.kind and store.kind.id
    if kind == 'container' or kind == 'vehicle' then return store.unit end
    if kind == 'panel' then
        local s = store.handle and store.handle.session
        local uid = s and s.host and s.host.uid
        return uid ~= nil and ('item:' .. tostring(uid)) or nil
    end
    return nil
end

--- How much cash a store holds now.
local function cashIn(store)
    local n, kind, h = 0, store.kind, store.handle
    for slot = 1, tonumber(kind.slots(h)) or 0 do
        local d = kind.get(h, slot)
        if d and d.item == CASH then n = n + (tonumber(d.amount) or 0) end
    end
    return n
end

--- The player behind a move, or nil (a resource's own move: not a player's to check).
local function mover(source)
    local p = source and Players[source]
    if p and p.charId and p.userId then return p end
    return nil
end

local function touch(key, charId)
    dirty[key .. '|' .. tostring(charId)] = { key, charId }
end

--- What other characters of this player's account left at `key`.
local function blockedFor(key, p)
    local n = 0
    for charId, m in pairs(marks[key] or {}) do
        if charId ~= p.charId and m.userId == p.userId then n = n + m.amount end
    end
    return n
end

--- Before a move (Stores.beforeMove): may the player take this cash out of where it is? Answers why not, or nil.
--- Only the forward half: a swap's returning half is asked through Stores.beforeMove by itself.
---@param from table  { store, slot }
---@param detail table  { item, amount, source }
---@return string|nil why
function CashMarks.checkMove(from, _, detail)
    if Config.BlockOwnCharacterTransfers == false then return nil end
    if not detail or detail.item ~= CASH then return nil end
    local key = markKey(from.store)
    if not key or not marks[key] then return nil end
    local p = mover(detail.source)
    if not p then return nil end
    local blocked = blockedFor(key, p)
    if blocked <= 0 then return nil end
    local amount = tonumber(detail.amount) or 0
    local free = cashIn(from.store) - blocked
    if amount <= free then return nil end
    print(('[whip_core:cash] %s (charId %s) was refused $%d from %s: $%d of it was left there by another character of the same player')
        :format(tostring(p.fullName), tostring(p.charId), amount, key, blocked))
    return LINKED
end

--- `amount` of cash went out of the store at `key`: the mover's own line first, then, if what is left there is less
--- than the tally says (someone else took some), the oldest lines down to it.
local function took(key, store, amount, p)
    local t = marks[key]
    if not t then return end
    if p and t[p.charId] then
        local own = t[p.charId]
        local n = math.min(own.amount, amount)
        own.amount = own.amount - n
        touch(key, p.charId)
    end
    local there, total, list = cashIn(store), 0, {}
    for charId, m in pairs(t) do
        total = total + m.amount
        list[#list + 1] = { charId, m }
    end
    if total > there then
        table.sort(list, function(a, b) return a[2].at < b[2].at end)
        local over = total - there
        for _, e in ipairs(list) do
            if over <= 0 then break end
            local n = math.min(e[2].amount, over)
            e[2].amount, over = e[2].amount - n, over - n
            touch(key, e[1])
        end
    end
    for charId, m in pairs(t) do
        if m.amount <= 0 then t[charId] = nil end
    end
    if next(t) == nil then marks[key] = nil end
end

--- `amount` of cash was left at `key` by this player.
local function left(key, p, amount)
    local t = marks[key]
    if not t then t = {}; marks[key] = t end
    local m = t[p.charId]
    if not m then m = { userId = p.userId, amount = 0, at = 0 }; t[p.charId] = m end
    m.amount, m.at = m.amount + amount, os.time()
    touch(key, p.charId)
end

local function moved(fromStore, toStore, amount, source)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    local fromKey, toKey = markKey(fromStore), markKey(toStore)
    if fromKey == toKey then return end   -- within one container (or between two untracked stores)
    local p = mover(source)
    if fromKey then took(fromKey, fromStore, amount, p) end
    if toKey and p then left(toKey, p, amount) end
end

--- After a committed move (Stores.afterMove): keep the tallies in step. The swap's returning half went the other way.
function CashMarks.noteMove(from, to, detail)
    if not detail then return end
    if detail.item == CASH then moved(from.store, to.store, detail.amount, detail.source) end
    local back = detail.replacing
    if back and back.item == CASH then moved(to.store, from.store, back.amount, detail.source) end
end

--- May this player pick up this ground pile? Answers why not, or nil. Cash dropped by another character of the same
--- player is refused (ground_items.createdBy is who dropped it; a split keeps it).
---@param player table  WhipPlayer
---@param pile table    the ground item ({ item, amount, createdBy })
---@return string|nil why
function CashMarks.mayPickUp(player, pile)
    if Config.BlockOwnCharacterTransfers == false then return nil end
    if not pile or pile.item ~= CASH or not pile.createdBy or not player or pile.createdBy == player.charId then return nil end
    local ok, why = Bank.notOwnOther(player.charId, pile.createdBy)
    if ok then return nil end
    if why == DB_ERROR then return 'Could not check that, try again' end
    print(('[whip_core:cash] %s (charId %s) was refused $%s on the ground: dropped by another character of the same player (charId %s)')
        :format(tostring(player.fullName), tostring(player.charId), tostring(pile.amount), tostring(pile.createdBy)))
    return LINKED
end

-- ============================================
-- Saving
-- ============================================

function CashMarks.ensureTable()
    return CreateTable('cash_marks', [[
        CREATE TABLE IF NOT EXISTS `cash_marks` (
            `markKey`   VARCHAR(100) NOT NULL,
            `charId`    INT UNSIGNED NOT NULL,
            `userId`    INT UNSIGNED NOT NULL,
            `amount`    INT UNSIGNED NOT NULL,
            `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`markKey`, `charId`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- At start: lines older than MARK_DAYS go, the rest are read. A failed read is said, and start-up carries on: a
--- missing tally only lets cash through that would have been refused, it destroys nothing.
function CashMarks.loadAll()
    CashMarks.ensureTable()
    pcall(MySQL.update.await, 'DELETE FROM `cash_marks` WHERE `updatedAt` < (NOW() - INTERVAL ? DAY)', { MARK_DAYS })
    local ok, rows = pcall(MySQL.query.await, 'SELECT `markKey`, `charId`, `userId`, `amount`, UNIX_TIMESTAMP(`updatedAt`) AS `at` FROM `cash_marks`')
    if not ok or type(rows) ~= 'table' then
        print('^3[whip_core:cash] the cash tallies could not be read: cash left in containers before this start is not watched^7')
        return true
    end
    marks = {}
    for _, r in ipairs(rows) do
        local charId, amount = tonumber(r.charId), tonumber(r.amount) or 0
        if charId and amount > 0 then
            marks[r.markKey] = marks[r.markKey] or {}
            marks[r.markKey][charId] = { userId = tonumber(r.userId), amount = amount, at = tonumber(r.at) or os.time() }
        end
    end
    return true
end

--- Write what memory holds for each changed line: the amount, or the line gone. Sent one after another, so two
--- changes to one line never land out of order.
---@param wait boolean  false: whip_core is stopping, sent without waiting
local function flush(wait)
    local due = dirty
    dirty = {}
    for _, d in pairs(due) do
        local key, charId = d[1], d[2]
        local m = marks[key] and marks[key][charId]
        local sql, params
        if m and m.amount > 0 then
            sql = 'INSERT INTO `cash_marks` (`markKey`, `charId`, `userId`, `amount`) VALUES (?, ?, ?, ?) '
                .. 'ON DUPLICATE KEY UPDATE `amount` = VALUES(`amount`), `userId` = VALUES(`userId`)'
            params = { key, charId, m.userId, math.floor(m.amount) }
        else
            sql, params = 'DELETE FROM `cash_marks` WHERE `markKey` = ? AND `charId` = ?', { key, charId }
        end
        if wait then
            local ok, err = pcall(MySQL.query.await, sql, params)
            if not ok then
                print(('[whip_core:cash] a cash tally could not be saved (tried again shortly): %s'):format(tostring(err)))
                dirty[key .. '|' .. tostring(charId)] = d
            end
        else
            pcall(MySQL.query --[[@as function]], sql, params)
        end
    end
end

CreateThread(function()
    local sweptAt = os.time()
    while true do
        Wait(2000)
        if next(dirty) then flush(true) end
        -- Lines untouched for MARK_DAYS go from memory too, about once an hour (the table loses them at the next start).
        if os.time() - sweptAt > 3600 then
            sweptAt = os.time()
            local cutoff = os.time() - MARK_DAYS * 86400
            for key, t in pairs(marks) do
                for charId, m in pairs(t) do
                    if m.at < cutoff then t[charId] = nil end
                end
                if next(t) == nil then marks[key] = nil end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and next(dirty) then flush(false) end
end)
