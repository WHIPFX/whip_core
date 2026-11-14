-- ============================================
-- ATM — server
-- The cash window: balances in, cash out, and nothing else
-- ============================================
--
-- Three SecureCallbacks: the ATM is a prompt waiting for an answer, so they RETURN it (did it work,
-- and if not, why not, in words it can put on the badge) rather than firing a toast.
--
-- About proximity: these have no `near` clause, because there is no server-side list of ATM
-- positions (machines are found from their MODEL on the client, client/atm.lua, so any map works).
-- A client could call these from anywhere. That does NOT let anyone create money: the permission,
-- balance and cash-held checks and the chk_balance_nonneg constraint all run here on the server.
-- What it costs is the ROLEPLAY constraint of standing at a machine.

-- ============================================
-- Reading the accounts
-- ============================================

--- What this character may do at a machine.
---
--- One row per account they can touch, including ones they only have access to rather than own — a
--- mechanic with withdraw rights on the business account should be able to take wages out at an
--- ATM, which is the case Bank.GetCharacterAccounts already covers.
---
--- The permissions come down with the row so the PROMPT does not offer a Withdraw that is bound to be
--- refused; the deposit and withdraw callbacks below re-check on the server every time.
SecureCallback('whip_core:atm:accounts', {
    rateLimit = 500,
}, function(_, player)
    local accounts = Bank.GetCharacterAccounts(player.charId) or {}
    local out = {}

    for i = 1, #accounts do
        local a = accounts[i]
        out[#out + 1] = {
            accountId     = a.accountId,
            label         = a.label,
            accountNumber = a.accountNumber,
            balance       = a.balance or 0,
            -- TINYINT(1) arrives as a boolean on oxmysql's query path and a number on prepare;
            -- DbBool (helpers.lua) accepts both, like every other flag read.
            frozen        = DbBool(a.frozen),
            canDeposit    = Bank.HasPermission(a.accountId, player.charId, 'deposit') and true or false,
            canWithdraw   = Bank.HasPermission(a.accountId, player.charId, 'withdraw') and true or false,
        }
    end

    return out, player:getCash()
end)

-- ============================================
-- Moving the money
-- ============================================

--- Cash in the player's hands → the account.
---
--- Take before give: the cash leaves the pockets FIRST and the ledger is credited second, so the worst
--- a failure can do is hand the player's own cash back to them (a compensating Bank.Withdraw would be
--- permissioned, and could fail). Taken and handed back through Money, the one charge-and-refund
--- every payment in whip uses.
---
--- One transaction on disk: the banknotes come out of the pockets marked, not written, and the
--- credit's write carries them (Stores.commitWithAction).
SecureCallback('whip_core:atm:deposit', {
    rateLimit = 1000,
    params = {
        {'accountId', 'id'},
        -- 'amount', not 'int': refused unless whole and 1 or more. 'int' clamped — 0.5 became $1.
        {'amount', 'amount', 999999999},
    },
}, function(source, player, accountId, amount)
    -- The cash is ITEMS in the inventory, not a number on the character, so what they carry is
    -- checked (by the charge) before the ledger moves.
    local receipt, payErr = Money.charge(source, amount, { method = 'cash', reason = 'ATM deposit' },
        GetCurrentResourceName(), 'ATM deposit', true)
    if not receipt then
        return false, payErr or 'Could not take the cash'
    end

    local ok, err = Bank.Deposit(accountId, amount, player.charId, 'ATM deposit')
    if not ok then
        -- The bank never moved, so the cash goes straight back — dropped at their feet if their
        -- pockets filled meantime, never destroyed (Money.refund).
        local back = Money.refund(receipt, nil, GetCurrentResourceName())
        Inventory.syncAndSave(source, player)
        if not back then return false, 'Deposit failed — contact an admin' end
        return false, err or 'Deposit failed'
    end

    Inventory.syncAndSave(source, player)

    local account = Bank.GetAccount(accountId)
    return true, nil, (account and account.balance) or 0, player:getCash()
end)

--- The account → cash in the player's hands.
---
--- The capacity check comes first, before the debit: cash is items and items need slots, so
--- Bank.Withdraw is only reached once the inventory has said it can hold the result.
---
--- One transaction on disk: the banknotes go into the pockets after every check and read, right
--- before the debit commits, and are written with it; if it does not commit they come straight back out.
SecureCallback('whip_core:atm:withdraw', {
    rateLimit = 1000,
    params = {
        {'accountId', 'id'},
        {'amount', 'amount', 999999999},   -- see atm:deposit
    },
}, function(source, player, accountId, amount)
    if not player.inventory then
        return false, 'Inventory not loaded'
    end

    local canFit, capacity = Inventory.canFitItem(player.inventory, 'cash', amount)
    if not canFit then
        return false, ('No room — you can carry $%d more'):format(capacity or 0)
    end

    -- The player's own withdraw permission on this account decides (Bank.Withdraw).
    local frozen   -- this withdrawal's hold on the pockets while the debit is out (below)
    local called, ok, err = pcall(Bank.Withdraw, accountId, amount, player.charId, 'ATM withdrawal', {
        before = function()
            -- Still the same session after the reads waited? A /logout in that wait tears this
            -- session down, and cash added then would go to a dropped inventory.
            if Players[source] ~= player or player.closing then
                return false, 'Withdrawal cancelled — you left the character'
            end
            -- The pockets hold still until the debit answers: the notes stack onto cash the player can
            -- see, and a drag of that stack while the write is out would carry them off. Stores.freeze
            -- refuses every move in or out; drops and throws refuse while it holds ('Paying — wait a
            -- moment'), a throw asking again after its wait for the thrown object.
            local pockets = Stores.player(source, 'player')
            if pockets and pockets.unit then frozen = Stores.freeze(pockets.unit) end
            -- Can still be refused despite the pre-check (canFitItem is a read, and the pockets can
            -- change under it); nothing has been debited then.
            -- QUIET: not shown until the debit lands, below.
            return player:addCash(amount, 'ATM withdrawal', 'quiet')
        end,
        undo = function()
            if not player:removeCash(amount, 'ATM withdrawal failed — taken back', 'quiet') then
                -- Moved on in the moment the debit was out (a drag into a stash): said, and on record.
                print(('[whip_core:atm] CRITICAL: a failed $%d withdrawal could not take its cash back from charId %s')
                    :format(amount, tostring(player.charId)))
                Log.write(player.charId, 'withdraw_undo_short', {
                    itemKey = 'cash', amount = amount, detail = 'ATM withdrawal failed; its cash was no longer in the pockets',
                })
            end
        end,
    })
    if frozen then Stores.unfreeze(frozen) end
    if not called then error(ok, 0) end
    -- Landed or not, the screen shows what the pockets hold now (to this character, if they are still
    -- on it): the notes on success; on a failure, nothing a push in the wait may have shown.
    if Players[source] == player then
        Inventory.syncToClient(source, player)
        TriggerClientEvent('whip_core:client:updateCash', source, player:getCash())
    end
    if not ok then
        return false, err or 'Withdrawal failed'
    end

    local account = Bank.GetAccount(accountId)
    return true, nil, (account and account.balance) or 0, player:getCash()
end)
