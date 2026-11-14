-- ============================================
-- MONEY HELD — pay now, settle for what was used
-- ============================================
--
-- For a service that is metered, whatever runs it: the fuel a pump pours, a taxi's fare, a charging point's
-- minutes, a car wash's cycles. A resource HOLDS the most it could cost — taken now, cash or bank — and as the
-- service runs it says how much is used so far; when it ends it SETTLES, and the rest comes back.
--
--   HoldMoney(source, amount, { method, reason, vehicle })   takes `amount` now. In the SAME write the refund owed
--                                                             for all of it is noted on the payer's row (metadata
--                                                             OWED_KEY). `vehicle`: that vehicle's row is held
--                                                             unwritten till the settle (Stores.hold), so what it
--                                                             was given and not yet paid for is never saved
--   SpendMoneyHold(id, spent)                                how much is used so far (money, 0 to the amount)
--   SettleMoneyHold(id, spent?)                              the rest back: the change, the note cleared and the
--                                                             held vehicle's row, written together
--
-- Nothing can be lost either way. A crash before the settle leaves the note (and nothing of the vehicle written):
-- the next login pays it back. A payer who leaves (ReleaseCharacterSession), the resource that holds it stopping,
-- whip_core stopping: settled there and then, for what was used so far. Cash change goes to the pockets, or the bank
-- when it does not fit; a bank refund that cannot be made now is owed, and paid at the next login.
--
-- A hold is its resource's own: only it spends or settles it.

MoneyHolds = {}

--- The character metadata key holding the refunds owed: a list of { hold?, amount, method, accountId }.
local OWED_KEY = 'moneyHeldOwed'

local holds = {}   -- [id] = { id, owner, src, charId, method, accountId, amount, spent, token, vehicleId?, rowHold? }
local nextId = 0

--- The character's own save unit: pockets, row and metadata (stores.lua 'player').
local function playerUnit(src) return Stores.player(src, 'player') end

-- ============================================
-- The notes: refunds owed
-- ============================================

--- The refunds owed, as a list (under `key`, OWED_KEY unless named).
---@return table[]
local function owedList(player, key)
    local v = player.metadata and player.metadata[key or OWED_KEY]
    if type(v) ~= 'table' then return {} end
    if tonumber(v.amount) then return { v } end   -- a single note, as the old pump wrote
    local out = {}
    for _, e in ipairs(v) do
        if type(e) == 'table' and tonumber(e.amount) then out[#out + 1] = e end
    end
    return out
end

--- The notes whip_core's old pump wrote (before the pumps were whip_fuel's, on these holds): paid the same way at
--- login, then never written again.
local OLD_PUMP_KEY = 'pourRefundOwed'

local function addOwed(player, entry)
    local list = owedList(player)
    list[#list + 1] = entry
    player:setMetadata(OWED_KEY, list)
end

--- Take one hold's note off (by its token); the others stay.
local function dropOwed(player, token)
    local kept = {}
    for _, e in ipairs(owedList(player)) do
        if e.hold == nil or e.hold ~= token then kept[#kept + 1] = e end
    end
    player:setMetadata(OWED_KEY, #kept > 0 and kept or nil)
end

--- Pay `amount` back to `player`, written with `stores`. Cash goes to the pockets, or the bank when it will not fit.
--- `noWait`: whip_core is stopping and the bank cannot be asked — owed instead (a note), paid at the next login.
---@return boolean paidNow
local function refundWith(player, owed, amount, stores, noWait)
    if amount <= 0 then
        Stores.writeTogether(stores)
        return true
    end
    if owed.method ~= 'bank' and player:addCash(amount, 'change', true) then
        Stores.writeTogether(stores)
        return true
    end
    local accountId = owed.accountId
    if not accountId and not noWait then
        local acct = Bank.GetDefaultAccount(player.charId)
        accountId = acct and acct.accountId
    end
    if accountId and not noWait
        and Bank.SystemDeposit(accountId, amount, 'Refund: ' .. tostring(owed.reason or 'change'), player.charId, { with = stores }) then
        return true
    end
    addOwed(player, { amount = amount, method = 'bank', accountId = accountId, reason = owed.reason })
    Stores.writeTogether(stores)
    return false
end

-- A refund still owed is paid when the character comes back: a crash mid-service, or one the bank could not take.
-- Every note, each cleared in the same write as its money (one not paid now goes back on).
Character.onLife('loaded', function(e)
    local player = e and e.source and Players[e.source]
    if not player then return end
    local list = owedList(player)
    local old = owedList(player, OLD_PUMP_KEY)
    if #list == 0 and #old == 0 then return end
    if #list > 0 then player:setMetadata(OWED_KEY, nil) end
    if #old > 0 then
        player:setMetadata(OLD_PUMP_KEY, nil)
        for _, owed in ipairs(old) do
            list[#list + 1] = { amount = owed.amount, method = owed.method, accountId = owed.accountId, reason = 'Fuel' }
        end
    end
    for _, owed in ipairs(list) do
        local amount = math.floor(tonumber(owed.amount) --[[@as number]])   -- (owedList keeps only those with one)
        if refundWith(player, owed, amount, { playerUnit(e.source) }) and amount > 0 then
            NotifyPlayer(e.source, ('$%d refunded for %s you paid for and did not get'):format(amount,
                tostring(owed.reason or 'something')), 'success', 8000)
        end
    end
end)

-- ============================================
-- Holding, spending, settling
-- ============================================

--- Take `amount` from `src` now, for a service that may use less. Nil and why when it was not taken.
---@param opts table|nil  { method = 'cash' | 'bank', reason, vehicle = vehicleId }
---@param owner string  the resource holding it
---@return integer|nil id
---@return string|nil why
function MoneyHolds.open(src, amount, opts, owner)
    opts = type(opts) == 'table' and opts or {}
    amount = Sanitize.id(amount, 0)
    if not amount then return nil, 'amount is a whole number of 0 or more' end
    local player = Players[src]
    if not player or not player.charId then return nil, 'Player not loaded' end
    local method = opts.method == 'bank' and 'bank' or 'cash'
    local reason = type(opts.reason) == 'string' and opts.reason:sub(1, 60) or 'Payment'
    local accountId = nil
    if method == 'bank' then
        -- A read that failed is not "no account" (as Money.charge; audit 20, ECO-6)
        local acct, readErr = Bank.GetDefaultAccount(player.charId)
        if not acct then
            return nil, readErr and 'The bank could not be reached — try again' or 'You have no bank account'
        end
        accountId = acct.accountId
    end

    nextId = nextId + 1
    local id = nextId
    local token = ('%d-%d'):format(os.time(), id)
    -- The note first, written WITH the payment: a crash after it hands it all back. Their row is held from the note to
    -- the payment's answer, so the background flush cannot write the note alone while the bank path waits on the
    -- database; the payment's own write carries the row (audit 20, ECO-3).
    local noteHold = Stores.hold('player:' .. tostring(player.charId))
    addOwed(player, { hold = token, amount = amount, method = method, accountId = accountId, reason = reason })
    local charged, receipt, err = pcall(Money.charge, src, amount,
        { method = method, accountId = accountId, reason = reason }, owner, Log.reasonFrom(reason), { playerUnit(src) })
    Stores.unhold(noteHold)
    if not charged then receipt, err = false, tostring(receipt) end
    if not receipt then
        dropOwed(player, token)
        return nil, err or 'Payment failed'
    end
    -- Gone while the bank answered (a drop does not wait: releasePlayer has already run and found no hold): nothing is
    -- delivered, and the note written with the payment pays it all back at their next login (audit 20, ECO-1).
    if Players[src] ~= player or player.closing or player.dropped then
        return nil, 'You left before the payment finished'
    end

    local h = { id = id, owner = owner, src = src, charId = player.charId, method = method, accountId = accountId,
                amount = amount, spent = 0, token = token, reason = reason }
    local vehicleId = tonumber(opts.vehicle)
    if vehicleId then
        h.vehicleId = vehicleId
        h.rowHold = Stores.hold('vehrow:' .. tostring(vehicleId))
    end
    holds[id] = h
    return id
end

--- How much of hold `id` is used so far (money, held to 0 - its amount).
---@return boolean
function MoneyHolds.spend(id, spent)
    local h = holds[id]
    if not h then return false end
    h.spent = math.max(0, math.min(h.amount, math.floor((tonumber(spent) or 0) + 0.5)))
    return true
end

--- Settle hold `id` for what was used (`spent`, else what SpendMoneyHold last said): the rest back, the note
--- cleared and its vehicle's row written, together. Nil when there is no such hold.
---@param noWait boolean|nil  whip_core stopping: a bank refund is owed rather than asked for
---@return table|nil { spent, refunded, paidNow }
function MoneyHolds.settle(id, spent, noWait)
    local h = holds[id]
    if not h then return nil end
    holds[id] = nil
    if spent ~= nil then
        h.spent = math.max(0, math.min(h.amount, math.floor((tonumber(spent) or 0) + 0.5)))
    end
    local refund = h.amount - h.spent

    local player = Players[h.src]
    local paidNow = false
    if player and player.charId == h.charId then
        dropOwed(player, h.token)
        local stores = { playerUnit(h.src) }
        if h.vehicleId then stores[2] = Stores.unit('vehrow', h.vehicleId) end
        paidNow = refundWith(player, { method = h.method, accountId = h.accountId, reason = h.reason }, refund,
            stores, noWait)
    else
        -- Gone before it was settled (releasePlayer settles a leaving payer's holds, and open refuses one who left
        -- while paying, so this is a payer whip_core lost track of): the note written with the payment still says all
        -- of it, and pays it at their next login. What the service gave meanwhile is saved with the vehicle's row
        -- below, unpaid.
        print(('[whip_core:money] a hold for charId %s settled after they left — refunded at their next login; what it delivered is unpaid')
            :format(tostring(h.charId)))
    end
    if h.rowHold then Stores.unhold(h.rowHold) end
    return { spent = h.spent, refunded = refund, paidNow = paidNow }
end

--- Settle every hold `src` is paying for (they are going: before their save), for what was used.
function MoneyHolds.releasePlayer(src, noWait)
    local mine = {}
    for id, h in pairs(holds) do
        if h.src == src then mine[#mine + 1] = id end
    end
    for _, id in ipairs(mine) do MoneyHolds.settle(id, nil, noWait) end
end

-- The vehicle rows stay held while their services run (a hold lets go by itself after HOLD_MAX_MS)
Every('money holds: keep vehicle rows held', 5000, function()
    for _, h in pairs(holds) do
        if h.rowHold then Stores.renewHold(h.rowHold) end
    end
end)

-- ============================================
-- For every resource
-- ============================================

--- Hold `amount` from a player for a metered service (see the top of this file). The hold's id, or false and why.
---@return integer|false id, string|nil why
exports('HoldMoney', function(source, amount, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    local id, why = MoneyHolds.open(tonumber(source), amount, opts, owner)
    if not id then return false, why end
    return id
end)

-- Why a hold id finds nothing for the caller
local function noHold(h)
    if not h then return 'No such hold: it is settled already (by you, the payer leaving, or a restart)' end
    return 'That hold is not yours: only the resource that opened it can spend or settle it'
end

--- How much of the caller's hold is used so far (money). true, or false and why.
---@return boolean ok, string|nil why
exports('SpendMoneyHold', function(id, spent)
    local owner = Registry.caller()
    local h = holds[tonumber(id)]
    if not h or h.owner ~= owner then return false, noHold(h) end
    return MoneyHolds.spend(h.id, spent)
end)

--- Settle the caller's hold for what was used (`spent`, else what SpendMoneyHold last said). { spent, refunded,
--- paidNow }, or false and why.
---@return table|false result, string|nil why
exports('SettleMoneyHold', function(id, spent)
    local owner = Registry.caller()
    local h = holds[tonumber(id)]
    if not h or h.owner ~= owner then return false, noHold(h) end
    local res = MoneyHolds.settle(h.id, spent)
    if not res then return false, noHold(nil) end
    return res
end)

--- The caller's hold: { source, amount, spent, method }, or nil.
exports('GetMoneyHold', function(id)
    local owner = Registry.caller()
    local h = holds[tonumber(id)]
    if not h or h.owner ~= owner then return nil end
    return { source = h.src, amount = h.amount, spent = h.spent, method = h.method }
end)

-- A resource stopping: its holds settled for what was used so far
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    local theirs = {}
    for id, h in pairs(holds) do
        if h.owner == res then theirs[#theirs + 1] = id end
    end
    for _, id in ipairs(theirs) do
        local ok, err = pcall(MoneyHolds.settle, id)
        if not ok then print(('[whip_core:money] settling a hold of %s failed: %s'):format(res, tostring(err))) end
    end
end)

-- whip_core stopping: every hold settled WITHOUT WAITING (a bank refund owed instead), marked to be written with the
-- stores. Step 20, before step 60 sends them (server/lifecycle.lua).
CoreStop.add(20, 'money holds: settle', function()
    local all = {}
    for id in pairs(holds) do all[#all + 1] = id end
    for _, id in ipairs(all) do
        local ok, err = pcall(MoneyHolds.settle, id, nil, true)
        if not ok then print(('[whip_core:money] settling hold %s on stop failed: %s'):format(tostring(id), tostring(err))) end
    end
end)

-- txAdmin stopping (the final save): settled in full, the bank asked, before step 10 writes the stores. Only on a
-- real shutdown.
FinalSave.add(5, 'money holds', function(deadline, shutdown)
    if not shutdown then return true end
    local all = {}
    for id in pairs(holds) do all[#all + 1] = id end
    for _, id in ipairs(all) do
        if GetGameTimer() >= deadline then return false end
        local ok, err = pcall(MoneyHolds.settle, id)
        if not ok then print(('[whip_core:money] settling hold %s in the final save failed: %s'):format(tostring(id), tostring(err))) end
    end
    return true
end, function()
    local n = 0
    for _ in pairs(holds) do n = n + 1 end
    return n
end)
