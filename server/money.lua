-- ============================================
-- Money — take a payment, and give it back
-- ============================================
--
-- One way to charge a player: take the money, do the thing, and hand the money back if the thing
-- failed.
--
--     local receipt, err = exports.whip_core:ChargePlayer(source, 500, { method = 'bank', reason = 'Car wash' })
--     if not receipt then return notify(source, err) end
--     if not washTheCar() then exports.whip_core:RefundPlayer(receipt) end
--
-- The receipt is the server's, not the caller's: what a caller holds is a copy with an id; a refund
-- is decided from the record kept here. Trusting a table handed back would let anyone write
-- `{ method = 'bank', accountId = 5, amount = 1e9 }` and have whip pay it out with no permission
-- check. A record refunds at most what it took, only for the resource that took it, and only for
-- RECEIPT_TTL — refunds happen seconds after a charge, not days.

Money = Money or {}

--- [id] = { id, owner, source, charId, amount, method, accountId, currency, reason, refunded, at }
Money._receipts = {}

-- Seeded from the clock, not 0: receipts live in memory, and a satellite still holding a receipt id
-- from before a restart must not refund someone else's payment. From the boot second × 1000, the ids
-- of two runs meet only if the older one took a thousand payments a second for its whole life.
local _nextId = math.floor(os.time()) * 1000

--- How long a payment stays refundable. Refunds undo the step right after a charge; anything later
--- is a new payment the other way, and should be one (BankSystemDeposit, PayPlayer).
local RECEIPT_TTL_MS = 30 * 60 * 1000
--- A Systems Creator system's payment (owner 'system:<id>') is refunded by the system's walker when
--- the pulse that took it is called off, and a pulse lives up to an hour (shared/systems/walk.lua's
--- pulseLifeMs): its receipt outlives that, or a late cancel would keep the money.
local SYSTEM_RECEIPT_TTL_MS = 70 * 60 * 1000

local AMOUNT_ERR = 'Amount must be a whole number of 0 or more'

--- Is this receipt past its time? Then it refunds nothing (audit 20, ECO-4: the sweep below runs only on a charge, so
--- on a quiet server an old receipt still refunded).
local function expired(rec, now)
    local ttl = (type(rec.owner) == 'string' and rec.owner:sub(1, 7) == 'system:') and SYSTEM_RECEIPT_TTL_MS or RECEIPT_TTL_MS
    return (now or GetGameTimer()) - rec.at > ttl
end

--- Forget receipts past their time. Run on each charge; there are only ever a handful.
local function sweepExpired()
    local now = GetGameTimer()
    for id, rec in pairs(Money._receipts) do
        if expired(rec, now) then Money._receipts[id] = nil end
    end
end

--- What the caller is given: the facts, and the id that points back at the real record.
---@param rec table
---@return table
local function receiptView(rec)
    return {
        id        = rec.id,
        amount    = rec.amount,
        method    = rec.method,
        accountId = rec.accountId,
        currency  = rec.currency,
        refunded  = rec.refunded,
    }
end

--- A currency's name as a player reads it: 'cash', or the item's name ('Gold Bar').
local function currencyName(currency)
    if currency == 'cash' then return 'cash' end
    local def = Config.Items[currency]
    return (def and def.name) or currency
end

--- An amount of a currency as a player reads it: '$500' for banknotes, '5 Gold Bar' for anything else.
local function priced(currency, n)
    if currency == 'cash' then return '$' .. tostring(n) end
    return ('%d %s'):format(n, currencyName(currency))
end

-- ============================================
-- Cash in a wallet
-- ============================================
--
-- A wallet's notes live in its metadata, not in a pocket slot. A cash payment counts them too: loose notes first, then
-- each wallet carried in the pockets or on the strip (not one inside a bag). A WALLET is any panel item made to hold
-- cash: its registration names the items it takes, cash among them, with no read/write of its own (whip's wallet; a
-- duffle takes anything and is not one). Notes another character of the same player left in it stay theirs
-- (CashMarks.blockedAt), as they would be if taken out by hand, and its tally shrinks with what is spent
-- (CashMarks.spent). An open wallet panel is repainted from its item (Panels.refreshFromHost).

--- The registration of an item made to hold `currency`, or nil.
---@param itemKey string
---@param currency string
---@return table|nil reg
local function walletReg(itemKey, currency)
    local reg = Panels and Panels.itemConfigs and Panels.itemConfigs[itemKey]
    if type(reg) ~= 'table' or reg.read or reg.write then return nil end
    local allowed = reg.allowedItems
    if type(allowed) ~= 'table' then return nil end
    if allowed[currency] == true then return reg end
    for _, k in ipairs(allowed) do
        if k == currency then return reg end
    end
    return nil
end

--- Every wallet the player carries, with what it holds of `currency` and how much of that they may spend.
---@return { container: string, slot: number, key: string|nil, uid: any, storageKey: string, have: number, usable: number }[] wallets
---@return number usable  all of them together
local function walletsOf(source, player, currency)
    local out, total = {}, 0
    for _, container in ipairs(PlayerContainers) do
        for slot, sd in pairs(player.inventory[container] or {}) do
            local reg = type(sd) == 'table' and walletReg(sd.item, currency)
            local meta = reg and type(sd.metadata) == 'table' and sd.metadata
            local storageKey = reg and (reg.storageKey or 'slots')
            local inside = meta and meta[storageKey]
            if type(inside) == 'table' then
                local have = 0
                for _, e in pairs(inside) do
                    if type(e) == 'table' and e.item == currency then have = have + (tonumber(e.amount) or 0) end
                end
                if have > 0 then
                    local key = Stores.cashMarks and Stores.cashMarks.itemKey(meta.uid) or nil
                    local blocked = key and Stores.cashMarks.blockedAt(key, source) or 0
                    local usable = math.max(0, have - blocked)
                    out[#out + 1] = { container = container, slot = slot, key = key, uid = meta.uid,
                                      storageKey = storageKey, have = have, usable = usable }
                    total = total + usable
                end
            end
        end
    end
    return out, total
end

--- Take `amount` of `currency` out of the player's wallets, in memory only (the caller writes it). Answers an undo
--- (puts every wallet back as it was) and a finish (the tallies, the open panels: once it is written for good), or
--- nil when they hold less than that to spend.
---@return function|nil undo
---@return function|nil finish
local function takeFromWallets(source, player, wallets, currency, amount)
    local undos, done, left = {}, {}, amount
    for _, w in ipairs(wallets) do
        if left <= 0 then break end
        local n = math.min(w.usable, left)
        if n > 0 then
            local sd = Inventory.getSlot(player.inventory, w.container, w.slot)
            local before = Inventory.copyMetadata(sd.metadata)
            local meta = Inventory.copyMetadata(sd.metadata)
            local inside = meta[w.storageKey]
            local slots = {}
            for s, e in pairs(inside) do
                if type(e) == 'table' and e.item == currency then slots[#slots + 1] = s end
            end
            table.sort(slots, function(a, b) return (tonumber(a) or 0) > (tonumber(b) or 0) end)
            local need = n
            for _, s in ipairs(slots) do
                if need <= 0 then break end
                local e = inside[s]
                local take = math.min(tonumber(e.amount) or 0, need)
                e.amount = (tonumber(e.amount) or 0) - take
                if e.amount <= 0 then inside[s] = nil end
                need = need - take
            end
            Inventory.setSlot(player.inventory, w.container, w.slot, sd.item, sd.amount, meta)
            undos[#undos + 1] = { w = w, item = sd.item, amount = sd.amount, meta = before }
            done[#done + 1] = { w = w, spent = n }
            left = left - n
        end
    end
    local function undo()
        for i = #undos, 1, -1 do
            local u = undos[i]
            Inventory.setSlot(player.inventory, u.w.container, u.w.slot, u.item, u.amount, u.meta)
        end
    end
    if left > 0 then
        undo()
        return nil
    end
    local function finish()
        for _, d in ipairs(done) do
            if Stores.cashMarks then Stores.cashMarks.spent(d.w.key, source, d.spent, d.w.have - d.spent) end
            -- Its panel open on their screen: re-read from the wallet, so the notes spent are gone there too
            for _, session in pairs((Panels and Panels._sessions[source]) or {}) do
                if type(session) == 'table' and session.host and d.w.uid ~= nil and session.host.uid == d.w.uid then
                    Panels.refreshFromHost(source, session)
                end
            end
        end
    end
    return undo, finish
end

--- What a cash payment can take from this player now: loose notes and their wallets' (Money.charge's count). For a
--- look before a payment, so it decides as Money.charge will.
---@return number
function Money.spendableCash(source, player)
    local _, inWallets = walletsOf(source, player, 'cash')
    return Inventory.getItemCountAcrossContainers(player.inventory, 'cash') + inWallets
end

--- Take a payment from a player.
---
--- opts:
---   method    'cash' | 'bank' | 'auto' (default). auto: cash if they carry enough, else the bank.
---   accountId the account to pay from (bank). Default: their default account. Their own WITHDRAW
---             permission on it is checked — a job account they only view cannot pay.
---   currency  the item that counts as money for a cash payment (default 'cash'): a shop that
---             trades in gold bars charges gold bars. Refunded in the same item: the very stacks it took.
---   reason    what it was for, as the player's bank statement and the activity log will say it.
---
--- An amount of 0 takes nothing and still answers a receipt, so a free thing needs no special case.
---@param source number
---@param amount number|nil
---@param opts table|nil
---@param owner string  the resource charging (the export passes the caller)
---@param why string|nil  the activity-log reason (the export's Log.reasonFrom); defaults to opts.reason
---@param saveWith any  whip_core only — how the payment is written:
---       nil     at once, on its own
---       true    banknotes only marked, so the bank write that follows carries them (the ATM)
---       'held'  inside ONE player action, written WITH what it pays for: the action's next write, or
---               its end (the ChargePlayer export passes it). Anywhere else, at once.
---       table[] in one transaction with these stores (the pump: the fuel it paid for)
---@return table|false receipt
---@return string|nil err
function Money.charge(source, amount, opts, owner, why, saveWith)
    opts = type(opts) == 'table' and opts or {}
    amount = Sanitize.id(amount, 0)
    if not amount then return false, AMOUNT_ERR end

    local player = Players[source]
    if not player or not player.inventory then return false, 'Player not loaded' end

    local method = opts.method or 'auto'
    if method ~= 'cash' and method ~= 'bank' and method ~= 'auto' then
        return false, "method must be 'cash', 'bank' or 'auto'"
    end
    local currency = opts.currency or 'cash'
    if type(currency) ~= 'string' or not Config.Items[currency] then
        return false, ('Unknown currency item "%s"'):format(tostring(currency))
    end
    if currency ~= 'cash' and method == 'bank' then
        return false, 'a bank payment is in dollars — currency is for a cash payment'
    end
    local reason = type(opts.reason) == 'string' and opts.reason ~= '' and opts.reason:sub(1, 120) or 'Payment'
    why = why or reason
    local by = owner ~= GetCurrentResourceName() and ('by ' .. owner) or nil

    -- Loose notes, and (dollars only) what their wallets hold for them to spend
    local loose = Inventory.getItemCountAcrossContainers(player.inventory, currency)
    local wallets, inWallets = {}, 0
    if currency == 'cash' then wallets, inWallets = walletsOf(source, player, currency) end
    local haveCash = loose + inWallets
    local wasAuto = method == 'auto'
    if wasAuto then
        method = (currency ~= 'cash' or amount == 0 or haveCash >= amount) and 'cash' or 'bank'
    end

    -- Held only when the call has ONE action, not the payer's one of several: what
    -- it pays for may be written by a call that cannot tell which is the payer's (a car's row, with
    -- another customer at the next car), and would land first with the payment after. Several: paid now.
    if saveWith == 'held' and not (Actions and #Actions.current() == 1) then saveWith = nil end
    local withStores = type(saveWith) == 'table' and saveWith or nil

    local accountId, held, stacks = nil, nil, nil
    if amount > 0 and method == 'cash' then
        -- Not out of pockets held still for a bank write (Stores.freeze, the ATM): the notes in them may
        -- be a withdrawal that is not paid for yet.
        local pockets = Stores.player(source, 'player')
        if pockets and Stores.isFrozen(pockets.unit) then return false, 'Paying — wait a moment' end
        if haveCash < amount then
            return false, ('Not enough %s (have %s, need %s)'):format(
                currencyName(currency), priced(currency, haveCash), priced(currency, amount))
        end
        if currency == 'cash' then
            -- Loose notes first; what they do not cover comes out of the wallets.
            local fromLoose = math.min(loose, amount)
            local fromWallets = amount - fromLoose
            local undoWallets, finishWallets
            if fromWallets > 0 then
                -- In memory first, so the write below (removeCash's, or ours) carries the wallets with it
                undoWallets, finishWallets = takeFromWallets(source, player, wallets, currency, fromWallets)
                if not undoWallets then return false, 'Could not take the cash' end
            end
            if fromLoose > 0 then
                -- The framework's cash path: logged, the cash counter told, and written now — or only
                -- marked, when something written with it carries it (saveWith).
                local ok = player:removeCash(fromLoose, why, saveWith ~= nil)
                if not ok then
                    if undoWallets then undoWallets() end
                    return false, 'Could not take the cash'
                end
            end
            if fromWallets > 0 then
                Log.lost(player.charId, 'cash', fromWallets, why)
                if fromLoose == 0 then
                    -- No removeCash to write it: written as it would have been
                    Inventory.noteChangeReason(source, why, by)
                    if saveWith ~= nil then Inventory.syncAndSave(source, player) else Inventory.syncAndFlush(source, player) end
                    TriggerClientEvent('whip_core:client:updateCash', source, player:getCash())
                end
                finishWallets()
            end
            if withStores then
                local together = { Stores.player(source, 'player') }
                for _, s in ipairs(withStores) do together[#together + 1] = s end
                Stores.writeTogether(together)
            end
        else
            -- The items themselves are kept on the receipt: a refund hands back those very stacks, and a
            -- shop puts them in its stock room (Money.handOn), never fresh copies (serials, durability,
            -- a wallet's contents).
            stacks = {}
            local ok = Inventory.removeItemAcrossContainers(player.inventory, currency, amount, nil, stacks)
            if not ok then return false, ('Could not take the %s'):format(currencyName(currency)) end
            Log.lost(player.charId, currency, amount, why)
            Inventory.noteChangeReason(source, why, by)
            -- Written as banknotes are (items/cash.lua persistCash): with what it pays for when the caller
            -- holds it ('held', a table of stores), at once otherwise.
            if saveWith ~= nil then
                Inventory.syncAndSave(source, player)
                if withStores then
                    local together = { Stores.player(source, 'player') }
                    for _, s in ipairs(withStores) do together[#together + 1] = s end
                    Stores.writeTogether(together)
                end
            else
                Inventory.syncAndFlush(source, player)
            end
        end
    elseif amount > 0 then   -- bank
        accountId = opts.accountId ~= nil and Sanitize.id(opts.accountId) or nil
        if opts.accountId ~= nil and not accountId then return false, 'No such account' end
        if not accountId then
            local acct, readErr = Bank.GetDefaultAccount(player.charId)
            -- A read that failed is not "no account".
            if not acct and readErr then
                return false, 'The bank could not be reached — try again'
            end
            if not acct then
                return false, wasAuto and ('Not enough cash (have $%d, need $%d), and no bank account'):format(haveCash, amount)
                    or 'You have no bank account'
            end
            accountId = acct.accountId
        end
        -- Withdraw, not SystemWithdraw: the player is paying, so it is THEIR permission that counts.
        -- Held: checked now, written by the write it pays for (Stores.carryWithAction, below).
        local ok, err
        if saveWith == 'held' then
            local queries, landedOrWhy = Bank.prepareWithdraw(accountId, amount, player.charId, reason)
            ok, err = queries ~= nil, landedOrWhy
            if ok then held = { queries = queries, announce = landedOrWhy } end
        else
            ok, err = Bank.Withdraw(accountId, amount, player.charId, reason, withStores and { with = withStores } or nil)
        end
        if not ok then
            ---@cast err string|nil
            if wasAuto then
                return false, ('Not enough cash (have $%d, need $%d), and the bank said: %s'):format(haveCash, amount, tostring(err))
            end
            return false, err or 'The bank declined it'
        end
    end

    sweepExpired()
    _nextId = _nextId + 1
    local rec = {
        id        = _nextId,
        owner     = owner,
        source    = source,
        charId    = player.charId,
        amount    = amount,
        method    = method,
        accountId = accountId,
        currency  = method == 'cash' and currency or nil,
        reason    = reason,
        refunded  = 0,
        at        = GetGameTimer(),
        stacks    = stacks,   -- an item currency's stacks as they were taken (not handed out: receiptView)
    }

    -- A held debit rides the action's next write: a dealership's car row, Whiplash's tuning. Landed, it
    -- is an ordinary payment. A 'now' write that failed took nothing (voided), and the refund the
    -- satellite then asks for has nothing to pay back. One failed at the action's end stays held,
    -- waiting with the saves it paid for: they land together or not at all.
    if held then
        held.landed = function()
            rec.held = nil
            held.announce()
        end
        held.failed = function(err, goodsKept)
            rec.held, rec.voided = nil, true
            print(('[whip_core:money] a $%d payment by charId %s (%s) was not taken: the write it rode failed (%s)')
                :format(amount, tostring(player.charId), reason, tostring(err)))
            if goodsKept then
                -- Refused for good while what it bought was already theirs (Stores.commit): on their
                -- timeline, so an admin can see who kept goods unpaid.
                Log.write(player.charId, 'payment_unpaid', {
                    itemKey = 'cash', amount = rec.amount - rec.refunded,
                    detail  = ('%s · charged by %s · the account could not cover it'):format(reason, tostring(owner)),
                })
            end
        end
        -- What Stores.commit asks when a write carrying it fails: its account and amount, the balance now,
        -- and its order (the newest is let go first). Debits that cannot all land are not retried, with
        -- the saves they ride, for ever.
        held.debit   = function() return Bank.debitOf(held.queries) end
        held.balance = function(acct) return Bank.balanceNow(acct) end
        held.seq     = rec.id
        if Stores.carryWithAction(held, source) then
            rec.held = held
        else
            -- No single action to ride after all: written now, alone.
            local ok, err = Stores.commitWithAction(held.queries, 'bank')
            if not ok then return false, err or 'The bank declined it' end
            held.announce()
        end
    end

    Money._receipts[rec.id] = rec
    return receiptView(rec)
end

--- `amount` of an item payment's own stacks, taken off its receipt (newest taken first, a stack split when
--- only part of it is wanted), or nil when the receipt keeps none (money) or keeps less than that, and
--- the caller falls back to giving new items.
---@param rec table
---@param amount number
---@return table[]|nil stacks  { { amount, metadata }, ... }
local function takeStacks(rec, amount)
    local list = rec.stacks
    if type(list) ~= 'table' or #list == 0 then return nil end
    local have = 0
    for _, s in ipairs(list) do have = have + s.amount end
    if have < amount then return nil end
    local out, left = {}, amount
    while left > 0 do
        local s = list[#list]
        if s.amount <= left then
            list[#list] = nil
            out[#out + 1] = s
            left = left - s.amount
        else
            s.amount = s.amount - left
            out[#out + 1] = { amount = left, metadata = Inventory.copyMetadata(s.metadata) }
            left = 0
        end
    end
    return out
end

--- Put money back the way it came. Answers whether it arrived.
---
--- Where it came from, with no permission check: a refund is the payee undoing its own charge, not
--- the player making a deposit. A bank refund that fails (the account was frozen meanwhile) goes
--- back as cash rather than vanishing; a cash refund to a player who has LEFT goes to their bank
--- instead. An item currency has no bank to fall back on.
---@param rec table
---@param amount integer
---@return boolean ok
---@return string|nil err
---@return number|nil undelivered  how much of it did not arrive
local function payBack(rec, amount)
    local reasonText = 'Refund: ' .. rec.reason

    if rec.method == 'bank' then
        local ok, err = Bank.SystemDeposit(rec.accountId, amount, reasonText, rec.charId)
        if ok then return true end
        print(('[whip_core:money] bank refund of $%d to account %s failed (%s) — refunding in cash')
            :format(amount, tostring(rec.accountId), tostring(err)))
    end

    local currency = rec.currency or 'cash'
    local player = Players[rec.source]
    if player and player.charId == rec.charId then
        -- An item currency's own stacks go back, newest taken first: what was paid, not a copy.
        -- What did not arrive stays on the receipt: a stack that could not be handed back goes back
        -- onto the receipt and its amount is answered as undelivered, so Money.refund keeps that much refundable
        -- (and only that much: what arrived is not paid twice) and answers false, as the money paths do.
        local backStacks = takeStacks(rec, amount)
        if backStacks then
            local undelivered = 0
            for _, s in ipairs(backStacks) do
                local ok = Inventory.giveOrDrop(rec.source, player, currency, s.amount, s.metadata, { reason = reasonText:lower() })
                if not ok then
                    undelivered = undelivered + s.amount
                    -- At the front: taken last, so a hand-on of the rest (Money.handOn) passes on the stacks that
                    -- were paid and kept, and these stay for this buyer's refund.
                    table.insert(rec.stacks, 1, s)
                    print(('[whip_core:money] refund of %s for charId %s (%s) could not be delivered — still refundable')
                        :format(priced(currency, s.amount), tostring(rec.charId), rec.reason))
                end
            end
            if undelivered > 0 then return false, 'The refund could not be delivered', undelivered end
            return true
        end
        local ok = Inventory.giveOrDrop(rec.source, player, currency, amount, nil, { reason = reasonText:lower() })
        if ok then return true end
    elseif currency == 'cash' then
        local acct = Bank.GetDefaultAccount(rec.charId)
        if acct and Bank.SystemDeposit(acct.accountId, amount, reasonText .. ' (you had left)', rec.charId) then
            return true
        end
    end

    print(('[whip_core:money] CRITICAL: refund of %s for charId %s (%s, charged by %s) could not be delivered')
        :format(priced(currency, amount), tostring(rec.charId), rec.reason, tostring(rec.owner)))
    -- On their timeline too, so an admin can find what is owed and pay it.
    Log.write(rec.charId, 'refund_failed', {
        itemKey = currency, amount = amount,
        detail  = ('%s · charged by %s'):format(rec.reason, tostring(rec.owner)),
    })
    return false, 'The refund could not be delivered'
end

--- Give back all of a payment, or `amount` of it (a basket where one line could not be handed over).
---
--- Only the resource that charged may refund, only up to what is left of the payment, and only while
--- the receipt lasts (RECEIPT_TTL_MS). `receipt` is what ChargePlayer answered, or just its id.
---@param receipt table|number
---@param amount number|nil  default: everything not yet refunded
---@param owner string  the resource asking (the export passes the caller)
---@return boolean ok
---@return string|nil err
function Money.refund(receipt, amount, owner)
    -- rawget: a receipt handed back by a satellite is a plain copy, but never trust a table's shape.
    local id = tonumber(type(receipt) == 'table' and rawget(receipt, 'id') or receipt)
    local rec = id and Money._receipts[id]
    if id and rec and not rec.held and expired(rec) then
        Money._receipts[id] = nil
        rec = nil
    end
    if not rec then return false, 'No such payment to refund (a receipt lasts 30 minutes)' end
    if rec.owner ~= owner then return false, ('That payment was taken by %s'):format(tostring(rec.owner)) end

    -- A write carrying this held payment is out: its answer decides between letting the payment go (it
    -- failed) and paying it back (it landed), so wait for it. The write is bounded (db_guard).
    while rec.held and rec.held.inFlight do Wait(50) end

    local left = rec.amount - rec.refunded
    if amount == nil then
        amount = left
    else
        amount = Sanitize.id(amount, 0)
        if not amount then return false, AMOUNT_ERR end
    end
    if amount > left then
        return false, ('Only %s of that payment is left to refund'):format(priced(rec.currency or 'cash', left))
    end
    if amount == 0 then return true end

    -- A payment that never landed is let go, not paid back. Still held (no write has carried
    -- it): taken off its action, or made smaller. Voided (the write that carried it failed): nothing
    -- was taken. Paying either back would hand out money nobody paid.
    if rec.held or rec.voided then
        if rec.held then
            if amount == left then
                -- Not found to take back (a write has it that will not answer): not let go blind, or the
                -- debit lands with the refund saying yes.
                if not Stores.cancelCarried(rec.held) then
                    return false, 'That payment is still being written — try again in a moment'
                end
                rec.held = nil
                rec.voided = true
            else
                Bank.setDebitAmount(rec.held.queries, left - amount)
            end
        end
        rec.refunded = rec.refunded + amount
        return true
    end

    -- Reserved before anything yields: the bank refund waits on the database; two refunds for the
    -- same receipt arriving together would otherwise both see the full amount left and both pay it.
    rec.refunded = rec.refunded + amount
    -- `undelivered`: how much of it did not arrive (an item refund's stacks that could not be handed back; the
    -- money paths answer all or nothing). Only that much is refundable again.
    local ok, err, undelivered = payBack(rec, amount)
    if not ok then rec.refunded = rec.refunded - (undelivered or amount) end
    return ok, err
end

--- Pass an item payment on: what is left of it, as the very stacks the buyer paid with, for
--- whip_core to put somewhere — a shop's stock room. The receipt is spent by it: nothing is left to refund
--- after. nil when it kept no stacks (money, or nothing left), and the caller decides what that means.
---@param receipt table|number
---@param owner string  only whip_core's own code passes its payments on
---@param amount number|nil  how much of it (default: all that is left). A refund that could not be delivered stays
---                          on the receipt and is not passed on with the rest.
---@return table[]|nil stacks  { { amount, metadata }, ... }
function Money.handOn(receipt, owner, amount)
    local id = tonumber(type(receipt) == 'table' and rawget(receipt, 'id') or receipt)
    local rec = id and Money._receipts[id]
    if not id or not rec or rec.owner ~= owner or owner ~= GetCurrentResourceName() then return nil end
    if not rec.held and expired(rec) then Money._receipts[id] = nil return nil end
    local left = rec.amount - rec.refunded
    amount = math.min(math.tointeger(tonumber(amount)) or left, left)
    if amount <= 0 then return nil end
    local stacks = takeStacks(rec, amount)
    if not stacks then return nil end
    rec.refunded = rec.refunded + amount
    return stacks
end

--- Pay a player: the other way from Money.charge, for a job's wage, a reward, a sale (the Director's
--- payouts). ONE WAY, so a payout is never lost and always on the record:
---
---   who       a server id (online), or { charId = n } (online or not)
---   opts:
---     method    'cash' | 'bank' | 'auto' (default). auto: cash while they are online, else their bank.
---     accountId the account to pay into (bank). Default: their default account.
---     currency  the item paid as cash (default 'cash'): gold bars, chips.
---     reason    what it was for: their bank statement and the activity log say it.
---
--- Cash that does not fit their pockets lands at their feet (giveOrDrop), never in nowhere. A
--- character who is not online can only be paid into the bank. 0 pays nothing and answers true.
---@param who number|table
---@param amount number|nil
---@param opts table|nil
---@param owner string  the resource paying (the export passes the caller)
---@param why string|nil  the activity-log reason (the export's Log.reasonFrom); defaults to opts.reason
---@return boolean ok
---@return table|string result  { method, amount, currency?, accountId?, placement? } or why not
function Money.pay(who, amount, opts, owner, why)
    opts = type(opts) == 'table' and opts or {}
    amount = Sanitize.id(amount, 0)
    if not amount then return false, AMOUNT_ERR end

    local charId, src = WhoIs(who)
    if not charId then return false, src --[[@as string|nil]] or 'No such player' end
    -- (With a charId, WhoIs answers their source or nil, not a why.)
    ---@cast src number|nil
    local player = src and Players[src] or nil
    if player and player.charId ~= charId then player = nil end

    local method = opts.method or 'auto'
    if method ~= 'cash' and method ~= 'bank' and method ~= 'auto' then
        return false, "method must be 'cash', 'bank' or 'auto'"
    end
    local currency = opts.currency or 'cash'
    if type(currency) ~= 'string' or not Config.Items[currency] then
        return false, ('Unknown currency item "%s"'):format(tostring(currency))
    end
    if currency ~= 'cash' and method == 'bank' then
        return false, 'a bank payment is in dollars — currency is for a cash payment'
    end
    if method == 'auto' then method = (player or currency ~= 'cash') and 'cash' or 'bank' end
    local reason = type(opts.reason) == 'string' and opts.reason ~= '' and opts.reason:sub(1, 120) or 'Payment'
    why = why or reason

    if amount == 0 then return true, { method = method, amount = 0 } end

    if method == 'cash' then
        if not player then return false, 'They are not online: pay a character who is away into the bank' end
        local ok, err, placement
        if currency == 'cash' then
            -- The framework's cash path first (logged, written now, the cash counter told); full
            -- pockets fall back to the give that drops at their feet.
            ok = player:addCash(amount, why)
            if ok then placement = 'inventory' end
        end
        if not ok then
            ok, err, placement = Inventory.giveOrDrop(src --[[@as number]], player, currency, amount, nil, { reason = why })
            if not ok then return false, err or 'Could not pay them' end
        end
        return true, { method = 'cash', amount = amount, currency = currency, placement = placement }
    end

    local accountId = opts.accountId ~= nil and Sanitize.id(opts.accountId) or nil
    if opts.accountId ~= nil and not accountId then return false, 'No such account' end
    if not accountId then
        local acct, readErr = Bank.GetDefaultAccount(charId)
        if not acct and readErr then return false, 'The bank could not be reached — try again' end
        if not acct then return false, 'They have no bank account' end
        accountId = acct.accountId
    end
    -- SystemDeposit: the payer is a resource, not the player, so no permission of theirs is asked.
    local ok, err = Bank.SystemDeposit(accountId, amount, reason, charId)
    if not ok then return false, err or 'The bank refused it' end
    if owner ~= GetCurrentResourceName() then
        Log.write(charId, 'bank_system', {
            amount = amount,
            detail = ('pay to account #%s · %s · by %s'):format(tostring(accountId), why, tostring(owner)),
        })
    end
    return true, { method = 'bank', amount = amount, accountId = accountId }
end

-- A stopped resource can no longer refund anything it charged, so its receipts go with it.
--
-- Not whip_core's own: its stop still has refunds to make with these receipts (a pump's unspent
-- money, step 20 in server/lifecycle.lua), and the table goes with it anyway.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    for id, rec in pairs(Money._receipts) do
        if rec.owner == res then Money._receipts[id] = nil end
    end
end)

-- ============================================
-- Exports
-- ============================================

--- What a cash payment can take from this player now: loose notes, and what the wallets they carry hold for them to
--- spend (not another character's notes in one, with Config.BlockOwnCharacterTransfers on). For a "can they afford
--- it" before a ChargePlayer / HoldMoney with method 'cash'; GetPlayerCash is the loose notes alone.
---
---     if exports.whip_core:GetSpendableCash(source) < price then return 'Not enough cash' end
exports('GetSpendableCash', function(source)
    local player = Players[source]
    if not player or not player.inventory then return 0, 'Player not loaded' end
    return Money.spendableCash(source, player)
end)

--- Take a payment from a player: `receipt`, or `false, reason` (a reason the player can read —
--- 'Not enough cash (have $20, need $50)', 'No withdraw permission on this account').
---
---     local receipt, err = exports.whip_core:ChargePlayer(source, 500, {
---         method = 'auto',            -- 'cash' | 'bank' | 'auto' (cash if they carry enough, else bank)
---         accountId = nil,            -- bank: which account; default their default account
---         reason = 'Car wash',        -- on their bank statement and the activity log
---     })
---
--- Keep the receipt if the thing being paid for can still fail, and hand it to RefundPlayer if it does.
exports('ChargePlayer', function(source, amount, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    local why = Log.reasonFrom(type(opts) == 'table' and opts.reason or nil)
    -- Inside the satellite's SecureEvent the payment lands WITH what it pays for: a crash between
    -- paying and delivering can't keep the money and lose the goods.
    return Money.charge(source, amount, opts, owner, why, 'held')
end)

--- Give back a payment ChargePlayer took — all of it, or `amount`. `true`, or `false, reason`.
exports('RefundPlayer', function(receipt, amount)
    local owner = Registry.caller()
    return Money.refund(receipt, amount, owner)
end)

--- Pay a player — a wage, a reward, a sale: `result`, or `false, reason`, as ChargePlayer returns its receipt.
---
---     exports.whip_core:PayPlayer(source, 250, { method = 'auto', reason = 'Courier job' })
---     exports.whip_core:PayPlayer({ charId = 12 }, 250, { method = 'bank', reason = 'Wages' })
exports('PayPlayer', function(who, amount, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    local why = Log.reasonFrom(type(opts) == 'table' and opts.reason or nil)
    local ok, result = Money.pay(who, amount, opts, owner, why)
    if not ok then return false, result end
    return result
end)
