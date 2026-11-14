-- ============================================
-- Bank System — server/bank.lua
-- ============================================

Bank = {}

-- ============================================
-- Database — Table Creation (first-time setup)
-- ============================================

---@return boolean ok
function Bank.ensureTable()
    local okAccounts = CreateTable('bank_accounts', [[
        CREATE TABLE IF NOT EXISTS `bank_accounts` (
            `accountId`     INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `accountNumber` VARCHAR(12)  NOT NULL,
            `label`         VARCHAR(50)  NOT NULL DEFAULT 'Personal Account',
            `type`          ENUM('personal','savings','business','shared') NOT NULL DEFAULT 'personal',
            `ownerCharId`   INT UNSIGNED DEFAULT NULL,
            `jobId`         INT UNSIGNED DEFAULT NULL,
            `balance`       BIGINT       NOT NULL DEFAULT 0,
            `isDefault`     TINYINT(1)   NOT NULL DEFAULT 0,
            `frozen`        TINYINT(1)   NOT NULL DEFAULT 0,
            `createdAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `closedAt`      TIMESTAMP    NULL DEFAULT NULL,
            PRIMARY KEY (`accountId`),
            UNIQUE KEY `uk_accountNumber` (`accountNumber`),
            KEY `idx_ownerCharId` (`ownerCharId`),
            KEY `idx_jobId` (`jobId`),
            -- The overdraft rule lives HERE, in the database, not in a WHERE clause.
            --
            -- A guarded UPDATE (`... AND balance >= ?`) that matches zero rows is NOT an error:
            -- MariaDB changes nothing and reports success, oxmysql commits, and the caller is
            -- told the money moved. That is how two concurrent withdrawals both succeeded and
            -- only one of them debited.
            --
            -- A CHECK violation IS an error. oxmysql catches any error in a transaction, rolls
            -- the WHOLE thing back, and returns false (dist/build.js rawTransaction) — so the
            -- balance and its ledger row stay atomic AND an overdraft becomes unwritable.
            -- MariaDB enforces CHECK on UPDATE from 10.2.1.
            CONSTRAINT `chk_balance_nonneg` CHECK (`balance` >= 0),
            -- A CLOSED ACCOUNT HOLDS NOTHING (migration 023 adds it to an existing
            -- table). CloseAccount read the balance and then closed, and a deposit landing between
            -- the two left money in an account every query hides (they all filter closedAt). As a
            -- CHECK, whichever write comes second errors and rolls back — the same reason as above.
            CONSTRAINT `chk_closed_empty` CHECK (`closedAt` IS NULL OR `balance` = 0),
            CONSTRAINT `fk_bank_ownerCharId` FOREIGN KEY (`ownerCharId`)
                REFERENCES `characters` (`charId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    local okAccess = CreateTable('bank_access', [[
        CREATE TABLE IF NOT EXISTS `bank_access` (
            `accountId` INT UNSIGNED NOT NULL,
            `charId`    INT UNSIGNED NOT NULL,
            `role`      ENUM('owner','manager','withdraw','deposit','view') NOT NULL DEFAULT 'view',
            `grantedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `grantedBy` INT UNSIGNED DEFAULT NULL,
            PRIMARY KEY (`accountId`, `charId`),
            KEY `idx_charId` (`charId`),
            CONSTRAINT `fk_access_accountId` FOREIGN KEY (`accountId`)
                REFERENCES `bank_accounts` (`accountId`) ON DELETE CASCADE,
            CONSTRAINT `fk_access_charId` FOREIGN KEY (`charId`)
                REFERENCES `characters` (`charId`) ON DELETE CASCADE,
            CONSTRAINT `fk_access_grantedBy` FOREIGN KEY (`grantedBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    local okTx = CreateTable('bank_transactions', [[
        CREATE TABLE IF NOT EXISTS `bank_transactions` (
            `txId`          INT UNSIGNED      NOT NULL AUTO_INCREMENT,
            `actorCharId`   INT UNSIGNED      DEFAULT NULL,
            `fromAccountId` INT UNSIGNED      DEFAULT NULL,
            `toAccountId`   INT UNSIGNED      DEFAULT NULL,
            `amount`        BIGINT UNSIGNED   NOT NULL,
            `type`          ENUM('deposit','withdraw','transfer','payment') NOT NULL,
            `message`       VARCHAR(255)      DEFAULT NULL,
            `fromBalance`   BIGINT            DEFAULT NULL,
            `toBalance`     BIGINT            DEFAULT NULL,
            `createdAt`     TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`txId`),
            KEY `idx_tx_actor`   (`actorCharId`),
            KEY `idx_tx_from`    (`fromAccountId`),
            KEY `idx_tx_to`      (`toAccountId`),
            KEY `idx_tx_created` (`createdAt`),
            CONSTRAINT `fk_tx_actor` FOREIGN KEY (`actorCharId`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL,
            -- RESTRICT on purpose: a transaction is a financial record and must not disappear
            -- because an account was closed out from under it.
            CONSTRAINT `fk_tx_from` FOREIGN KEY (`fromAccountId`)
                REFERENCES `bank_accounts` (`accountId`) ON DELETE RESTRICT,
            CONSTRAINT `fk_tx_to` FOREIGN KEY (`toAccountId`)
                REFERENCES `bank_accounts` (`accountId`) ON DELETE RESTRICT
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    return okAccounts and okAccess and okTx
end

-- Role hierarchy (higher number = more permissions)
local RoleLevel = {
    view     = 1,
    deposit  = 2,
    withdraw = 3,
    manager  = 4,
    owner    = 5,
}

--- How much an access level allows, as a number to compare ('none' and anything unknown are 0). For
--- a caller that must know whether a change raises or lowers access: a job role (jobs.lua), where
--- lowering has to reach the accounts before the role changes.
---@param level string|nil
---@return number
function Bank.accessRank(level)
    return RoleLevel[level] or 0
end

--- The refusal every money movement gives for a bad amount. Sanitize.amount is the check, as for cash
--- and items: a whole number of 1 or more (nil, strings, fractions and NaN refused). Its words are Sanitize's.
local AMOUNT_ERR = Sanitize.AMOUNT_ERR

-- Permission cache: [charId] = { [accountId] = role }
-- Populated on GetCharacterAccounts, invalidated on grant/revoke/disconnect
Bank._permCache = {}

-- [charId] = a number bumped by every invalidation. A cache fill reads the database first; one
-- whose generation changed while it waited (a revoke landed) is dropped.
local permGen = {}

--- Forget what the cache says about this character.
---@param charId number
local function forgetPerms(charId)
    Bank._permCache[charId] = nil
    permGen[charId] = (permGen[charId] or 0) + 1
end

-- BALANCES IN MEMORY (GetBalance). Every write to a balance is in this file, and each reads the balance it left and
-- says it (balanceChanged): bankEmit keeps that reading, so after an account's first read GetBalance answers from
-- memory. A failed reading forgets the account (read again next time). Each character's main account is kept the
-- same way, and every account change (owner, main, type, closed) forgets them all. A read that waited on the
-- database keeps its answer only if nothing changed meanwhile (the versions), so it never puts back an older one.
local _balance, _balanceVer = {}, {}    -- [accountId] = balance; [accountId] = bumped by every reading
local _balanceTick = 0                  -- bumped by every reading of any account
local _mainOf, _mainGen = {}, 0         -- [charId] = accountId | false (none); bumped by every account change

local function noteBalance(accountId, balance)
    accountId = tonumber(accountId)
    if not accountId then return end
    _balance[accountId] = tonumber(balance)   -- nil (a failed reading) forgets it
    _balanceVer[accountId] = (_balanceVer[accountId] or 0) + 1
    _balanceTick = _balanceTick + 1
end

--- WhipEmit for this file's bank events, keeping the balances and main accounts above true.
local function bankEmit(name, tx)
    if type(tx) == 'table' then
        if name == 'whip_core:bank:balanceChanged' then
            if tx.accountId ~= nil then noteBalance(tx.accountId, tx.newBalance) end
            if tx.fromAccountId ~= nil then noteBalance(tx.fromAccountId, tx.fromBalance) end
            if tx.toAccountId ~= nil then noteBalance(tx.toAccountId, tx.toBalance) end
        elseif name == 'whip_core:bank:accountChanged' then
            _mainOf, _mainGen = {}, _mainGen + 1
            if tx.what == 'closed' then noteBalance(tx.accountId, nil) end
        end
    end
    WhipEmit(name, tx)
end

--- A read that ANSWERS instead of throwing: oxmysql's `.await` raises on a query error, which would
--- throw out of an export into the satellite that called it.
---@param kind 'query'|'scalar'
---@return any result  nil on a database error
---@return string|nil err  DB_ERROR on a database error
local function bankRead(kind, sql, params)
    local ok, result = pcall(MySQL[kind].await, sql, params)
    if not ok then
        print(('[whip_core:bank] read failed: %s'):format(tostring(result)))
        return nil, DB_ERROR
    end
    return result
end

--- An account's balance after a write, for the event. The money has already moved, so a failed read
--- here must not throw out of the caller (which then never recorded a receipt): it answers nil.
---@return number|nil
local function balanceOf(accountId)
    return (bankRead('scalar', 'SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?', { accountId }))
end

--- The money writes go through the one transaction runner, so the stall watchdog sees them and a
--- test can fault them ('bank'). Inside a player action they carry what that action saved
--- (Stores.commitWithAction): the ATM's cash and the account's credit, a sold item and its money,
--- are one transaction.
---
--- opts, whip_core only:
---   before()          runs after every read, right before the commit (the ATM puts the withdrawn
---                     cash in the pockets here, so it is written WITH the debit); false, why stops it
---   undo()            the commit failed after `before` ran: take back what it did
---   with              stores no action tied that must land in this write (the pump's fuel)
---   debitFrom, amount a refused write on an account now holding less than `amount` is said as
---                     'Insufficient funds' (oxmysql answers a refused transaction with a bare false and
---                     keeps the reason, the chk_balance_nonneg CHECK, to itself)
---@param queries table[]
---@param opts table|nil
---@return boolean ok
---@return string|nil err
local function bankWrite(queries, opts)
    opts = opts or {}
    if opts.before then
        local called, go, why = pcall(opts.before)
        if not called then
            print(('[whip_core:bank] a write was stopped: its before step raised: %s'):format(tostring(go)))
            return false, DB_ERROR
        end
        if not go then return false, why or 'Cancelled' end
    end
    local ok, err = Stores.commitWithAction(queries, 'bank', opts.with)
    if ok then return true end
    if opts.undo then opts.undo() end
    if tostring(err):find('chk_balance_nonneg', 1, true) then return false, 'Insufficient funds' end
    if opts.debitFrom then
        local balance = balanceOf(opts.debitFrom)
        if balance and balance < opts.amount then return false, 'Insufficient funds' end
    end
    print(('[whip_core:bank] write failed: %s'):format(tostring(err)))
    return false, DB_ERROR
end

-- ============================================
-- Account Number Generation
-- ============================================

--- Generate a WB-XXXXXX account number.
--- No DB check — relies on UNIQUE constraint; caller retries on collision.
---@return string
function Bank.GenerateAccountNumber()
    return string.format('WB-%06d', math.random(0, 999999))
end

-- ============================================
-- Account CRUD
-- ============================================

--- Create a new bank account with owner access row
---@param ownerCharId number|nil  nil for an account no character owns
---@param label string|nil
---@param accountType string|nil  'personal','savings','business','shared'
---@param isDefault boolean|nil
---@return table|nil account
---@return string|nil error
function Bank.CreateAccount(ownerCharId, label, accountType, isDefault, jobId)
    label = label or Config.DefaultAccountLabel
    -- 'personal' unless asked: a character's own account is always a personal one.
    accountType = accountType or 'personal'
    -- The column's own list, asked here: an unknown type would fail the INSERT as if the account number
    -- kept colliding.
    if accountType ~= 'personal' and accountType ~= 'savings' and accountType ~= 'business'
        and accountType ~= 'shared' then
        return nil, ('Unknown account type "%s" (personal, savings, business or shared)'):format(tostring(accountType))
    end
    -- The column's own limit, asked here for the same reason as the type.
    if type(label) ~= 'string' or label == '' or #label > 50 then
        return nil, 'An account label is 1 to 50 characters'
    end
    if ownerCharId ~= nil and not tonumber(ownerCharId) then
        return nil, 'An account owner is a character id'
    end
    local defaultFlag = isDefault and 1 or 0
    jobId = jobId or nil

    local startBalance = defaultFlag == 1 and Config.StartingBalance or 0

    -- A number nobody has, asked first: the transaction below answers only "rolled back", so it can't
    -- tell a colliding number from any other failure (a collision in the milliseconds between is
    -- refused like any other failure).
    local accountNumber
    for _ = 1, 10 do
        local candidate = Bank.GenerateAccountNumber()
        local taken, readErr = bankRead('scalar', 'SELECT 1 FROM `bank_accounts` WHERE `accountNumber` = ?', { candidate })
        if readErr then return nil, 'Failed to create bank account' end
        if not taken then accountNumber = candidate break end
    end
    if not accountNumber then return nil, 'Failed to create bank account' end

    -- The account, its owner's access and its starting-balance ledger row in one transaction: all three
    -- land, or none. The later rows find the account by its number (LAST_INSERT_ID moves with every
    -- insert).
    local byNumber = '(SELECT `accountId` FROM `bank_accounts` WHERE `accountNumber` = ?)'
    local queries = {
        { query = 'INSERT INTO `bank_accounts` (`accountNumber`, `label`, `type`, `ownerCharId`, `jobId`, `balance`, `isDefault`) VALUES (?, ?, ?, ?, ?, ?, ?)',
          values = { accountNumber, label, accountType, ownerCharId, jobId, startBalance, defaultFlag } },
    }
    -- Owner access (skip for system-owned accounts with no owner).
    if ownerCharId then
        queries[#queries + 1] = {
            query  = 'INSERT INTO `bank_access` (`accountId`, `charId`, `role`, `grantedBy`) VALUES (' .. byNumber .. ', ?, ?, ?)',
            values = { accountNumber, ownerCharId, 'owner', ownerCharId },
        }
    end
    -- The starting balance is money entering the game, so it gets a ledger row like any other deposit.
    if startBalance > 0 then
        queries[#queries + 1] = {
            query  = 'INSERT INTO `bank_transactions` (`actorCharId`, `toAccountId`, `amount`, `type`, `message`, `toBalance`) VALUES (?, ' .. byNumber .. ', ?, ?, ?, ?)',
            values = { ownerCharId, accountNumber, startBalance, 'deposit', 'Starting balance', startBalance },
        }
    end

    local written, writeErr = Stores.runTransaction(queries)
    if not written then
        print(('[whip_core:bank] creating an account for %s failed: %s'):format(tostring(ownerCharId), tostring(writeErr)))
        return nil, 'Failed to create bank account'
    end

    local accountId = bankRead('scalar', 'SELECT `accountId` FROM `bank_accounts` WHERE `accountNumber` = ?', { accountNumber })
    if not accountId then
        print(('[whip_core:bank] account %s was created but its id could not be read back'):format(accountNumber))
        return nil, 'Failed to create bank account'
    end

    if ownerCharId then
        -- Populate permission cache
        if not Bank._permCache[ownerCharId] then Bank._permCache[ownerCharId] = {} end
        Bank._permCache[ownerCharId][accountId] = 'owner'
    end
    -- A new main account: GetBalance's "no account" (or an older main) for its owner is forgotten.
    if defaultFlag == 1 then _mainOf, _mainGen = {}, _mainGen + 1 end
    noteBalance(accountId, startBalance)

    local account = {
        accountId     = accountId,
        accountNumber = accountNumber,
        label         = label,
        type          = accountType,
        ownerCharId   = ownerCharId,
        jobId         = jobId,
        balance       = startBalance,
        isDefault     = defaultFlag == 1,
        frozen        = false,
    }

    return account
end

--- Get account by accountId
---@param accountId number
---@return table|nil
---@return string|nil err  DB_ERROR when the read failed
function Bank.GetAccount(accountId)
    local rows, err = bankRead('query',
        'SELECT * FROM `bank_accounts` WHERE `accountId` = ? AND `closedAt` IS NULL LIMIT 1',
        {accountId}
    )
    return rows and rows[1] or nil, err
end

--- Get account by account number
---@param accountNumber string
---@return table|nil
---@return string|nil err  DB_ERROR when the read failed
function Bank.GetAccountByNumber(accountNumber)
    local rows, err = bankRead('query',
        'SELECT * FROM `bank_accounts` WHERE `accountNumber` = ? AND `closedAt` IS NULL LIMIT 1',
        {accountNumber}
    )
    return rows and rows[1] or nil, err
end

--- Get all accounts a character has access to
---@param charId number
---@return table[]
---@return string|nil err  DB_ERROR when the read failed; the list is then empty
function Bank.GetCharacterAccounts(charId)
    local gen = permGen[charId]
    local rows, err = bankRead('query',
        'SELECT ba.*, bac.`role` FROM `bank_accounts` ba INNER JOIN `bank_access` bac ON ba.`accountId` = bac.`accountId` WHERE bac.`charId` = ? AND ba.`closedAt` IS NULL ORDER BY ba.`isDefault` DESC, ba.`accountId` ASC',
        {charId}
    )
    if not rows then return {}, err end

    -- Populate permission cache from fetched rows — unless access changed during the read
    if permGen[charId] == gen then
        Bank._permCache[charId] = {}
        for _, row in ipairs(rows) do
            Bank._permCache[charId][row.accountId] = row.role
        end
    end

    return rows
end

--- Get the default (personal) account for a character
---@param charId number
---@return table|nil
---@return string|nil err  DB_ERROR when the read failed
function Bank.GetDefaultAccount(charId)
    local rows, err = bankRead('query',
        'SELECT * FROM `bank_accounts` WHERE `ownerCharId` = ? AND `isDefault` = 1 AND `closedAt` IS NULL LIMIT 1',
        {charId}
    )
    return rows and rows[1] or nil, err
end

--- How many savings and shared accounts a character owns: open ones, not a job's. What
--- Config.MaxExtraAccounts limits (CreateBankAccount).
---@param charId number
---@return number|nil count  nil when the read failed
---@return string|nil err
function Bank.countExtraAccounts(charId)
    local n, err = bankRead('scalar',
        "SELECT COUNT(*) FROM `bank_accounts` WHERE `ownerCharId` = ? AND `isDefault` = 0 AND `jobId` IS NULL AND `type` IN ('savings', 'shared') AND `closedAt` IS NULL",
        {charId}
    )
    if err then return nil, err end
    return tonumber(n) or 0
end

-- ============================================
-- Permission Checks
-- ============================================

--- Check if a character has the required role level on an account
---@param accountId number
---@param charId number
---@param requiredRole string
---@return boolean
function Bank.HasPermission(accountId, charId, requiredRole)
    local requiredLevel = RoleLevel[requiredRole]
    if not requiredLevel then return false end

    -- Check permission cache first (populated by GetCharacterAccounts)
    local cached = Bank._permCache[charId]
    local role
    if cached then
        role = cached[accountId]
    end

    -- Fallback to DB if not cached
    if not role then
        local gen = permGen[charId]
        -- A failed read is no permission, not a throw.
        role = bankRead('scalar',
            'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
            {accountId, charId}
        )
        -- Store in cache for subsequent calls — unless access changed during the read
        if role and permGen[charId] == gen then
            if not Bank._permCache[charId] then Bank._permCache[charId] = {} end
            Bank._permCache[charId][accountId] = role
        end
    end

    if not role then return false end

    local actualLevel = RoleLevel[role]
    return actualLevel and actualLevel >= requiredLevel
end

--- May this character do `role`'s worth of things on this account? HasPermission with a reason, for
--- a resource that has to decide BEFORE it acts: a shop offering only accounts that can pay, a job
--- menu hiding what a rank cannot touch.
---@param charId number
---@param accountId number
---@param role string  'view' | 'deposit' | 'withdraw' | 'manager' | 'owner'
---@return boolean ok
---@return string|nil why
function Bank.CanUse(charId, accountId, role)
    if not RoleLevel[role] then
        return false, ('unknown role "%s" (view, deposit, withdraw, manager, owner)'):format(tostring(role))
    end
    local cid, aid = Sanitize.id(charId), Sanitize.id(accountId)
    if not cid or not aid then return false, 'a charId and an accountId are needed' end
    charId, accountId = cid, aid
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if Bank.HasPermission(accountId, charId, role) then return true end
    return false, ('Needs %s access to this account'):format(role)
end

--- Set or replace the owner of an account (bypasses permission checks).
---
--- One owner, one transaction: the previous owner is stepped down to `manager` in the same
--- transaction that installs the new one, so the account is never seen with both.
---@param accountId number
---@param newOwnerCharId number
---@return boolean success
---@return string|nil error
function Bank.SetAccountOwner(accountId, newOwnerCharId)
    -- Who holds `owner` now, so their cached permission can be dropped afterwards.
    local previous, readErr = bankRead('query',
        'SELECT `charId` FROM `bank_access` WHERE `accountId` = ? AND `role` = \'owner\' AND `charId` <> ?',
        {accountId, newOwnerCharId}
    )
    if not previous then return false, readErr end

    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `ownerCharId` = ? WHERE `accountId` = ?',
          values = {newOwnerCharId, accountId} },
        { query = 'UPDATE `bank_access` SET `role` = \'manager\' WHERE `accountId` = ? AND `role` = \'owner\' AND `charId` <> ?',
          values = {accountId, newOwnerCharId} },
        { query = 'INSERT INTO `bank_access` (`accountId`, `charId`, `role`, `grantedBy`) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `role` = \'owner\', `grantedAt` = CURRENT_TIMESTAMP',
          values = {accountId, newOwnerCharId, 'owner', newOwnerCharId} },
    })
    if not ok then
        return false, err
    end

    for _, row in ipairs(previous) do
        forgetPerms(row.charId)
    end
    if not Bank._permCache[newOwnerCharId] then Bank._permCache[newOwnerCharId] = {} end
    Bank._permCache[newOwnerCharId][accountId] = 'owner'
    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'owner' })
    return true
end

-- ============================================
-- One player's characters pass no money to each other (Config.BlockOwnCharacterTransfers)
-- ============================================
-- Stops farming starting money (make a character, pass its money to your main, delete, repeat). With
-- this on (the default), a character cannot pay into, take from or transfer through an account that
-- ANOTHER character of the same player account owns, and cannot give such a character access to one.
-- Every path comes through here: the phone, ATMs, payments, and any resource's BankTransfer /
-- BankDeposit / BankWithdraw / GrantBankAccess.

--- [charId] = userId, or false for no such character: a character never changes player account, so read once.
local userOf = {}

---@return number|false|nil  nil when the read failed
local function userIdOf(charId)
    local u = userOf[charId]
    if u ~= nil then return u end
    local ok, v = pcall(MySQL.scalar.await, 'SELECT `userId` FROM `characters` WHERE `charId` = ?', { charId })
    if not ok then return nil end
    u = tonumber(v) or false
    userOf[charId] = u
    return u
end

local OWN_CHARACTER = 'That is another character of the same player: money cannot pass between them'

--- May `actor` deal with `other` (an account's owner, or someone given access)? No when they are two different
--- characters of one player account and the setting is on. A failed read is a no (it fails closed).
---@return boolean ok
---@return string|nil why
function Bank.notOwnOther(actor, other)
    if Config.BlockOwnCharacterTransfers == false then return true end
    actor, other = tonumber(actor), tonumber(other)
    if not actor or not other or actor == other then return true end
    local a, b = userIdOf(actor), userIdOf(other)
    if a == nil or b == nil then return false, DB_ERROR end
    if a and a == b then return false, OWN_CHARACTER end
    return true
end

--- May `grantedBy` give `charId` this role on the account? Every rule GrantAccess applies, nothing written: the phone
--- asks it before it sends an invite, and GrantAccess asks it again before the write.
---@param accountId number
---@param charId number
---@param role string
---@param grantedBy number
---@return boolean ok
---@return string|nil why
function Bank.checkGrant(accountId, charId, role, grantedBy)
    if not RoleLevel[role] then
        return false, 'Invalid role: ' .. tostring(role)
    end

    -- Check granter has permission (owners can grant anything, managers can grant deposit/view)
    local granterRole, readErr = bankRead('scalar',
        'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, grantedBy}
    )
    if readErr then return false, readErr end

    if not granterRole then
        return false, 'Granter has no access to this account'
    end

    local granterLevel = RoleLevel[granterRole]
    local targetLevel = RoleLevel[role]

    -- Can only grant roles below your own level
    if targetLevel >= granterLevel then
        return false, 'Cannot grant a role equal to or higher than your own'
    end

    -- ...and can only change people below your own level: the grant is an upsert, so granting a role
    -- REPLACES one already held (a manager could otherwise demote the owner). RevokeAccess's rule.
    local currentRole
    currentRole, readErr = bankRead('scalar',
        'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, charId}
    )
    if readErr then return false, readErr end
    if currentRole then
        if currentRole == 'owner' then
            return false, 'Cannot change the owner\'s access'
        end
        local currentLevel = RoleLevel[currentRole] or 0
        if currentLevel >= granterLevel then
            return false, 'Cannot change the access of someone at or above your own level'
        end
    end

    -- Not to another character of the granter's player account, or of the account owner's (Bank.notOwnOther).
    local mine, mineWhy = Bank.notOwnOther(grantedBy, charId)
    if not mine then return false, mineWhy end
    if Config.BlockOwnCharacterTransfers ~= false then
        local account, accErr = Bank.GetAccount(accountId)
        if not account then return false, accErr or 'Account not found' end
        -- The owner's other character, asked by someone else (a manager): said plainly; it is fine for
        -- them to know whose character it is.
        local theirs, theirsWhy = Bank.notOwnOther(account.ownerCharId, charId)
        if not theirs then
            if theirsWhy == OWN_CHARACTER and tonumber(account.ownerCharId) ~= tonumber(grantedBy) then
                return false, 'That is another character of the account owner\'s player: they cannot be given access to this account'
            end
            return false, theirsWhy
        end
    end
    return true
end

--- Grant access to an account
---@param accountId number
---@param charId number
---@param role string
---@param grantedBy number
---@return boolean success
---@return string|nil error
function Bank.GrantAccess(accountId, charId, role, grantedBy)
    local may, why = Bank.checkGrant(accountId, charId, role, grantedBy)
    if not may then return false, why end

    -- Upsert access
    local ok = pcall(MySQL.query.await,
        'INSERT INTO `bank_access` (`accountId`, `charId`, `role`, `grantedBy`) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `role` = VALUES(`role`), `grantedBy` = VALUES(`grantedBy`), `grantedAt` = CURRENT_TIMESTAMP',
        {accountId, charId, role, grantedBy}
    )
    if not ok then
        return false, 'Could not save the access change'
    end

    -- Invalidate permission cache for target character
    forgetPerms(charId)

    return true
end

--- Revoke access from an account
---@param accountId number
---@param charId number
---@param revokedBy number
---@return boolean success
---@return string|nil error
function Bank.RevokeAccess(accountId, charId, revokedBy)
    -- Cannot revoke owner
    local targetRole, readErr = bankRead('scalar',
        'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, charId}
    )
    if readErr then return false, readErr end

    if not targetRole then
        return false, 'Target has no access to this account'
    end
    if targetRole == 'owner' then
        return false, 'Cannot revoke owner access'
    end

    -- Check revoker has sufficient permissions
    local revokerRole
    revokerRole, readErr = bankRead('scalar',
        'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, revokedBy}
    )
    if readErr then return false, readErr end

    if not revokerRole then
        return false, 'Revoker has no access to this account'
    end

    local revokerLevel = RoleLevel[revokerRole]
    local targetLevel = RoleLevel[targetRole]

    if revokerLevel <= targetLevel then
        return false, 'Cannot revoke access for someone with equal or higher role'
    end

    -- pcall'd: a database error answers (false, reason) like every refusal above, never throws.
    local ok, err = pcall(MySQL.query.await,
        'DELETE FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, charId}
    )
    if not ok then
        print(('[whip_core:bank] ERROR revoking access to account %s for charId %s: %s')
            :format(tostring(accountId), tostring(charId), tostring(err)))
        return false, DB_ERROR
    end

    -- Invalidate permission cache for target character
    forgetPerms(charId)

    return true
end

--- Force-set bank access without permission checks (system-driven).
---@param accountId number
---@param charId number
---@param role string  'view'|'deposit'|'withdraw'|'manager'
---@return boolean
function Bank.ForceSetAccess(accountId, charId, role)
    if not RoleLevel[role] then return false end
    if role == 'owner' then return false end

    -- The IF() keeps an existing OWNER row as it is: hiring a job's owner into their own job must not
    -- make them a manager of their own account.
    local ok = pcall(MySQL.query.await,
        'INSERT INTO `bank_access` (`accountId`, `charId`, `role`, `grantedBy`) VALUES (?, ?, ?, NULL) ON DUPLICATE KEY UPDATE `role` = IF(`role` = \'owner\', `role`, VALUES(`role`)), `grantedAt` = CURRENT_TIMESTAMP',
        {accountId, charId, role}
    )
    if not ok then return false end

    forgetPerms(charId)
    return true
end

--- Force-revoke bank access without permission checks (system-driven).
---
--- A database error is RETURNED, not thrown, as ForceSetAccess does: a caller like Jobs.fire is
--- halfway through its own work.
---@param accountId number
---@param charId number
---@return boolean ok
---@return string|nil why  the owner cannot be revoked, or DB_ERROR (callers tell them apart by DB_ERROR)
function Bank.ForceRevokeAccess(accountId, charId)
    local read, targetRole = pcall(MySQL.scalar.await,
        'SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, charId}
    )
    if not read then return false, DB_ERROR end
    if not targetRole then return true end
    if targetRole == 'owner' then return false, 'The account\'s owner cannot lose access' end

    local deleted = pcall(MySQL.query.await,
        'DELETE FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        {accountId, charId}
    )
    if not deleted then return false, DB_ERROR end

    forgetPerms(charId)
    return true
end

--- Clear permission cache for a character (call on disconnect/logout)
function Bank.clearPermCache(charId)
    forgetPerms(charId)
end

-- ============================================
-- Transactions
-- ============================================

--- Deposit into an account
---@param accountId number
---@param amount number
---@param actorCharId number
---@param message string|nil
---@return boolean success
---@return string|nil error
function Bank.Deposit(accountId, amount, actorCharId, message)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole

    -- Check permission (deposit level)
    if not Bank.HasPermission(accountId, actorCharId, 'deposit') then
        return false, 'No deposit permission on this account'
    end

    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if DbBool(account.frozen) then return false, 'Account is frozen' end
    local mayPay, payWhy = Bank.notOwnOther(actorCharId, account.ownerCharId)   -- not into a sibling's account
    if not mayPay then return false, payWhy end

    -- Atomic: update balance + log transaction
    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = {amount, accountId} },
        { query = 'INSERT INTO `bank_transactions` (`actorCharId`, `toAccountId`, `amount`, `type`, `message`, `toBalance`) VALUES (?, ?, ?, ?, ?, (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?))', values = {actorCharId, accountId, amount, 'deposit', message or 'Deposit', accountId} },
    })

    if not ok then
        return false, err
    end

    local newBalance = balanceOf(accountId)

    -- Whose account and what kind ride along (read above anyway), so a listener (the phone's
    -- "Received $X") need not read it again for every deposit.
    local txData = {
        type = 'deposit', accountId = accountId, amount = amount,
        actorCharId = actorCharId, newBalance = newBalance, message = message,
        ownerCharId = account.ownerCharId, accountType = account.type, label = account.label,
    }
    bankEmit('whip_core:bank:balanceChanged', txData)

    return true
end

--- Whether an account can be debited `amount` now: found, not frozen, holding enough, and (`actor`, a player
--- withdrawing on their own permission) not another character of theirs (Bank.notOwnOther).
---@param accountId number
---@param amount integer
---@param actor number|nil
---@return boolean ok
---@return string|nil why
local function debitCheck(accountId, amount, actor)
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if DbBool(account.frozen) then return false, 'Account is frozen' end
    if account.balance < amount then return false, 'Insufficient funds' end
    if actor then
        local may, why = Bank.notOwnOther(actor, account.ownerCharId)
        if not may then return false, why end
    end
    return true
end

--- A debit's two statements: the balance and its ledger row.
local function debitQueries(accountId, amount, actorCharId, message, ledgerDefault)
    return {
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` - ? WHERE `accountId` = ?', values = {amount, accountId} },
        { query = 'INSERT INTO `bank_transactions` (`actorCharId`, `fromAccountId`, `amount`, `type`, `message`, `fromBalance`) VALUES (?, ?, ?, ?, ?, (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?))', values = {actorCharId, accountId, amount, 'withdraw', message or ledgerDefault, accountId} },
    }
end

--- Change the amount of a debit built by debitQueries and not yet written (a held payment partly
--- refunded before it landed, Money.refund).
---@param queries table[]
---@param amount integer
function Bank.setDebitAmount(queries, amount)
    queries[1].values[1] = amount
    queries[2].values[3] = amount
end

--- The account and amount of a debit built by debitQueries (it may have been resized: setDebitAmount).
---@param queries table[]
---@return number accountId
---@return integer amount
function Bank.debitOf(queries)
    return queries[1].values[2], queries[1].values[1]
end

--- An account's balance now, read fresh, or nil when the read failed. For Stores.commit deciding
--- whether held debits that failed together can ever land. Waits.
---@param accountId number
---@return number|nil
function Bank.balanceNow(accountId)
    return balanceOf(accountId)
end

--- A debit landed: tell listeners, with the balance it left. A failed read answers nil rather than
--- throwing out of the caller, which would then never record its receipt.
local function announceDebit(accountId, amount, actorCharId, message)
    local txData = {
        type = 'withdraw', accountId = accountId, amount = amount,
        actorCharId = actorCharId, newBalance = balanceOf(accountId), message = message,
    }
    bankEmit('whip_core:bank:balanceChanged', txData)
end

--- The debit itself, once the caller has decided it may happen — Withdraw by checking the actor's
--- permission, SystemWithdraw by being the system. One body, so the two cannot drift.
---@param accountId number
---@param amount integer  already a whole number of 1 or more
---@param actorCharId number|nil
---@param message string|nil  as given (the event carries it as given)
---@param ledgerDefault string  what the ledger says when no message was given
---@param hooks table|nil  { before, undo, with } — see bankWrite (the ATM's withdrawal, the pump's fuel)
---@param asActor boolean|nil  the actor withdraws on their own permission (Withdraw): see debitCheck
---@return boolean success
---@return string|nil error
local function debit(accountId, amount, actorCharId, message, ledgerDefault, hooks, asActor)
    local okCheck, why = debitCheck(accountId, amount, asActor and actorCharId or nil)
    if not okCheck then return false, why end

    -- Atomic: debit + log transaction.
    --
    -- No `AND balance >= ?` guard, deliberately: a guarded UPDATE matching zero rows is not a SQL
    -- error, so it would commit as if the money moved. The overdraft rule is the chk_balance_nonneg
    -- CHECK constraint: going negative raises a real error, which rolls back debit and ledger
    -- together. The check above only gives the player a useful message in the ordinary case.
    local ok, err = bankWrite(debitQueries(accountId, amount, actorCharId, message, ledgerDefault), {
        debitFrom = accountId, amount = amount,
        before = hooks and hooks.before, undo = hooks and hooks.undo, with = hooks and hooks.with,
    })

    if not ok then
        return false, err
    end

    announceDebit(accountId, amount, actorCharId, message)
    return true
end

--- Withdraw's checks and statements WITHOUT the write, for a payment held on its action until the
--- write it pays for (Money.charge): the queries, and what to run once they have landed.
---@return table[]|nil queries
---@return string|function why_or_landed  why not, or a function announcing the debit once it landed
function Bank.prepareWithdraw(accountId, amount, actorCharId, message)
    amount = Sanitize.amount(amount)
    if not amount then return nil, AMOUNT_ERR end
    if not Bank.HasPermission(accountId, actorCharId, 'withdraw') then
        return nil, 'No withdraw permission on this account'
    end
    local okCheck, why = debitCheck(accountId, amount, actorCharId)
    if not okCheck then return nil, why --[[@as string]] end
    local queries = debitQueries(accountId, amount, actorCharId, message, 'Withdrawal')
    return queries, function()
        -- What was written: a refund of part of it before it landed made the debit smaller (Bank.setDebitAmount, on
        -- these same queries), and the event must not say the first sum (audit 20, ECO-5)
        local _, written = Bank.debitOf(queries)
        announceDebit(accountId, written or amount, actorCharId, message)
    end
end

--- Withdraw from an account, on the actor's own permission.
---@param accountId number
---@param amount number
---@param actorCharId number
---@param message string|nil
---@param hooks table|nil  whip_core only: { before, undo } around the commit (see bankWrite)
---@return boolean success
---@return string|nil error
function Bank.Withdraw(accountId, amount, actorCharId, message, hooks)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole

    if not Bank.HasPermission(accountId, actorCharId, 'withdraw') then
        return false, 'No withdraw permission on this account'
    end
    return debit(accountId, amount, actorCharId, message, 'Withdrawal', hooks, true)
end

--- Take money OUT of an account with no permission check: a fine, an impound fee, a bill. The same
--- refusals as Withdraw otherwise (frozen, not enough). Whoever calls this has decided the account
--- owes it.
---@param accountId number
---@param amount number
---@param message string|nil
---@param actorCharId number|nil  who caused it, for the ledger
---@return boolean success
---@return string|nil error
function Bank.SystemWithdraw(accountId, amount, message, actorCharId)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole
    return debit(accountId, amount, actorCharId, message, 'System withdrawal')
end

--- The transfer itself, once the caller has decided it may happen (see debit).
---@param fromAccountId number
---@param toAccountId number
---@param amount integer
---@param actorCharId number|nil
---@param message string|nil
---@param ledgerDefault string
---@param asActor boolean|nil  the actor moves it on their own permission (Transfer): neither account may be
---       another character of theirs (Bank.notOwnOther)
---@return boolean success
---@return string|nil error
local function move(fromAccountId, toAccountId, amount, actorCharId, message, ledgerDefault, asActor)
    if fromAccountId == toAccountId then return false, 'Cannot transfer to the same account' end

    local fromAccount, fromErr = Bank.GetAccount(fromAccountId)
    if not fromAccount then return false, fromErr or 'Source account not found' end
    if DbBool(fromAccount.frozen) then return false, 'Source account is frozen' end
    if fromAccount.balance < amount then return false, 'Insufficient funds' end

    local toAccount, toErr = Bank.GetAccount(toAccountId)
    if not toAccount then return false, toErr or 'Destination account not found' end
    if DbBool(toAccount.frozen) then return false, 'Destination account is frozen' end

    if asActor then
        local mayFrom, fromWhy = Bank.notOwnOther(actorCharId, fromAccount.ownerCharId)
        if not mayFrom then return false, fromWhy end
        local mayTo, toWhy = Bank.notOwnOther(actorCharId, toAccount.ownerCharId)
        if not mayTo then return false, toWhy end
    end

    -- Atomic: debit source + credit destination + log transaction.
    --
    -- As Withdraw: chk_balance_nonneg enforces the overdraft rule, so a refused debit errors and the
    -- credit and the ledger roll back with it.
    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` - ? WHERE `accountId` = ?', values = {amount, fromAccountId} },
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = {amount, toAccountId} },
        { query = 'INSERT INTO `bank_transactions` (`actorCharId`, `fromAccountId`, `toAccountId`, `amount`, `type`, `message`, `fromBalance`, `toBalance`) VALUES (?, ?, ?, ?, ?, ?, (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?), (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?))', values = {actorCharId, fromAccountId, toAccountId, amount, 'transfer', message or ledgerDefault, fromAccountId, toAccountId} },
    }, { debitFrom = fromAccountId, amount = amount })

    if not ok then
        return false, err
    end

    local newFromBalance = balanceOf(fromAccountId)
    local newToBalance = balanceOf(toAccountId)

    local txData = {
        type = 'transfer', fromAccountId = fromAccountId, toAccountId = toAccountId,
        amount = amount, actorCharId = actorCharId,
        fromBalance = newFromBalance, toBalance = newToBalance, message = message,
        -- (as a deposit: both accounts were read above)
        fromOwnerCharId = fromAccount.ownerCharId, fromAccountType = fromAccount.type, fromLabel = fromAccount.label,
        toOwnerCharId = toAccount.ownerCharId, toAccountType = toAccount.type, toLabel = toAccount.label,
    }
    bankEmit('whip_core:bank:balanceChanged', txData)

    return true
end

--- Transfer between two accounts, on the actor's permission to withdraw from the first.
---@param fromAccountId number
---@param toAccountId number
---@param amount number
---@param actorCharId number
---@param message string|nil
---@return boolean success
---@return string|nil error
function Bank.Transfer(fromAccountId, toAccountId, amount, actorCharId, message)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole
    if fromAccountId == toAccountId then return false, 'Cannot transfer to the same account' end

    if not Bank.HasPermission(fromAccountId, actorCharId, 'withdraw') then
        return false, 'No withdraw permission on source account'
    end
    return move(fromAccountId, toAccountId, amount, actorCharId, message, 'Transfer', true)
end

--- Move money between two accounts with no permission check — payroll from a business account,
--- a fine paid to the city. The same refusals as Transfer otherwise.
---@param fromAccountId number
---@param toAccountId number
---@param amount number
---@param message string|nil
---@param actorCharId number|nil
---@return boolean success
---@return string|nil error
function Bank.SystemTransfer(fromAccountId, toAccountId, amount, message, actorCharId)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole
    return move(fromAccountId, toAccountId, amount, actorCharId, message, 'System transfer')
end

--- Money made on the spot, paid on FROM an account: a lore character paying a player (server/director/lore.lua).
--- The account is paid in (a deposit, `madeNote` on its own statement: where the money came from), then pays it to
--- `toAccountId` as a transfer with `message`. Both in ONE transaction, so the money never sits in the payer's
--- account, and the receiver's statement reads like any transfer from it.
---@param fromAccountId number
---@param toAccountId number
---@param amount number
---@param message string|nil
---@param madeNote string|nil
---@return boolean success
---@return string|nil error
function Bank.SystemPayFrom(fromAccountId, toAccountId, amount, message, madeNote)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole
    if fromAccountId == toAccountId then return false, 'Cannot transfer to the same account' end
    local fromAccount, fromErr = Bank.GetAccount(fromAccountId)
    if not fromAccount then return false, fromErr or 'Source account not found' end
    if DbBool(fromAccount.frozen) then return false, 'Source account is frozen' end
    local toAccount, toErr = Bank.GetAccount(toAccountId)
    if not toAccount then return false, toErr or 'Destination account not found' end
    if DbBool(toAccount.frozen) then return false, 'Destination account is frozen' end

    local balance = '(SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?)'
    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = { amount, fromAccountId } },
        { query = 'INSERT INTO `bank_transactions` (`toAccountId`, `amount`, `type`, `message`, `toBalance`) VALUES (?, ?, ?, ?, ' .. balance .. ')',
          values = { fromAccountId, amount, 'deposit', madeNote or 'Paid in', fromAccountId } },
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` - ? WHERE `accountId` = ?', values = { amount, fromAccountId } },
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = { amount, toAccountId } },
        { query = 'INSERT INTO `bank_transactions` (`fromAccountId`, `toAccountId`, `amount`, `type`, `message`, `fromBalance`, `toBalance`) VALUES (?, ?, ?, ?, ?, ' .. balance .. ', ' .. balance .. ')',
          values = { fromAccountId, toAccountId, amount, 'transfer', message or 'Transfer', fromAccountId, toAccountId } },
    }, { debitFrom = fromAccountId, amount = amount })
    if not ok then return false, err end

    local fromBalance, toBalance = balanceOf(fromAccountId), balanceOf(toAccountId)
    local made = {
        type = 'deposit', accountId = fromAccountId, amount = amount, newBalance = fromBalance, message = madeNote,
        ownerCharId = fromAccount.ownerCharId, accountType = fromAccount.type, label = fromAccount.label,
    }
    bankEmit('whip_core:bank:balanceChanged', made)
    local tx = {
        type = 'transfer', fromAccountId = fromAccountId, toAccountId = toAccountId, amount = amount,
        fromBalance = fromBalance, toBalance = toBalance, message = message,
        fromOwnerCharId = fromAccount.ownerCharId, fromAccountType = fromAccount.type, fromLabel = fromAccount.label,
        toOwnerCharId = toAccount.ownerCharId, toAccountType = toAccount.type, toLabel = toAccount.label,
    }
    bankEmit('whip_core:bank:balanceChanged', tx)
    return true
end

--- Get transaction history for an account
---@param accountId number
---@param limit number|nil  Default 50
---@param offset number|nil  Default 0
---@return table[]
---@return string|nil err  DB_ERROR when the read failed; the list is then empty
function Bank.GetTransactions(accountId, limit, offset)
    -- Whole numbers in range: these go straight into LIMIT/OFFSET. Newest first by txId, not by
    -- createdAt, which has one-second steps.
    limit  = Sanitize.int(limit, 1, 500, 50)
    offset = Sanitize.int(offset, 0, 1000000, 0)
    local rows, err = bankRead('query',
        'SELECT * FROM `bank_transactions` WHERE `fromAccountId` = ? OR `toAccountId` = ? ORDER BY `txId` DESC LIMIT ? OFFSET ?',
        {accountId, accountId, limit, offset}
    )
    return rows or {}, err
end

-- ============================================
-- Job-linked accounts
-- ============================================

--- Get all non-closed accounts linked to a job
---@param jobId number
---@return table[]
---@return string|nil err  DB_ERROR when the read failed; the list is then empty
function Bank.GetAccountsByJob(jobId)
    local rows, err = bankRead('query',
        'SELECT * FROM `bank_accounts` WHERE `jobId` = ? AND `closedAt` IS NULL ORDER BY `accountId` ASC',
        {jobId}
    )
    return rows or {}, err
end

-- ============================================
-- Access Management
-- ============================================

--- Get all characters with access to an account
---@param accountId number
---@return table[]
---@return string|nil err  DB_ERROR when the read failed; the list is then empty
function Bank.GetAccessList(accountId)
    local rows, err = bankRead('query',
        'SELECT `charId`, `role`, `grantedAt`, `grantedBy` FROM `bank_access` WHERE `accountId` = ? ORDER BY FIELD(`role`, \'owner\', \'manager\', \'withdraw\', \'deposit\', \'view\')',
        {accountId}
    )
    return rows or {}, err
end

-- ============================================
-- Close Account
-- ============================================

--- Soft-close an account (sets closedAt). Must have zero balance and not be default.
---
--- `evenMain`: a default account too, for an admin closing the account of a character who is gone. It keeps its
--- isDefault: the login's "no default row at all" is what pays a new one the starting balance.
---@param accountId number
---@param evenMain boolean|nil
---@return boolean success
---@return string|nil error
function Bank.CloseAccount(accountId, evenMain)
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if DbBool(account.isDefault) and not evenMain then return false, 'Cannot close default account' end
    if account.balance > 0 then return false, 'Account must have zero balance' end

    -- pcall'd for the same reason as RevokeAccess.
    --
    -- The zero balance is asked in the write, not only in the read above: money that landed in between
    -- leaves the row unmatched, and the close is refused rather than hiding it (chk_closed_empty in the
    -- CREATE holds the other order).
    local ok, changed = pcall(MySQL.update.await,
        'UPDATE `bank_accounts` SET `closedAt` = CURRENT_TIMESTAMP WHERE `accountId` = ? AND `balance` = 0 AND `closedAt` IS NULL',
        {accountId}
    )
    if not ok then
        print(('[whip_core:bank] ERROR closing account %s: %s'):format(tostring(accountId), tostring(changed)))
        return false, DB_ERROR
    end
    if (tonumber(changed) or 0) == 0 then
        return false, 'Account must have zero balance'
    end

    -- Invalidate perm cache for all who had access
    local access = Bank.GetAccessList(accountId)
    for _, row in ipairs(access) do
        forgetPerms(row.charId)
    end

    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'closed' })
    return true
end

--- Freeze or unfreeze an account. A frozen account keeps its money and its access list; nothing
--- moves in or out until it is unfrozen (every money path refuses it).
---@param accountId number
---@param frozen boolean
---@return boolean ok
---@return string|nil err
function Bank.SetFrozen(accountId, frozen)
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `bank_accounts` SET `frozen` = ? WHERE `accountId` = ? AND `closedAt` IS NULL',
        { frozen and 1 or 0, accountId })
    if not ok then
        print(('[whip_core:bank] ERROR %s account %s: %s'):format(frozen and 'freezing' or 'unfreezing',
            tostring(accountId), tostring(err)))
        return false, DB_ERROR
    end
    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'frozen' })
    return true
end

--- Rename an open account (the name its statements and the bank show).
---@param accountId number
---@param label string  1 to 50 characters
---@return boolean ok
---@return string|nil err
function Bank.SetLabel(accountId, label)
    if type(label) ~= 'string' or label == '' or #label > 50 then return false, 'An account label is 1 to 50 characters' end
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `bank_accounts` SET `label` = ? WHERE `accountId` = ? AND `closedAt` IS NULL', { label, accountId })
    if not ok then
        print(('[whip_core:bank] ERROR renaming account %s: %s'):format(tostring(accountId), tostring(err)))
        return false, DB_ERROR
    end
    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'label' })
    return true
end

--- Change what kind of account this is. A job's account stays a business one, and only a job's is; a character's
--- main account stays personal.
---@param accountId number
---@param accountType string  'personal' | 'savings' | 'shared'
---@return boolean ok
---@return string|nil err
function Bank.SetType(accountId, accountType)
    if accountType ~= 'personal' and accountType ~= 'savings' and accountType ~= 'shared' then
        return false, 'An account is personal, savings or shared (a business account belongs to a job)'
    end
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if account.jobId then return false, 'A job\'s account stays a business account' end
    if DbBool(account.isDefault) and accountType ~= 'personal' then
        return false, 'A character\'s main account stays a personal account'
    end
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `bank_accounts` SET `type` = ? WHERE `accountId` = ? AND `closedAt` IS NULL', { accountType, accountId })
    if not ok then
        print(('[whip_core:bank] ERROR changing the type of account %s: %s'):format(tostring(accountId), tostring(err)))
        return false, DB_ERROR
    end
    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'type' })
    return true
end

--- Make this its owner's main account: the one wages land in, and the one the inventory names. One at a time, in
--- one write, so they never have none (the login would make one, with the starting balance) or two.
---@param accountId number
---@return boolean ok
---@return string|nil err
function Bank.SetDefault(accountId)
    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if not account.ownerCharId then return false, 'An account with no owner cannot be a main account' end
    if account.jobId then return false, 'A job\'s account cannot be a character\'s main account' end
    if DbBool(account.isDefault) then return true end
    if account.type ~= 'personal' then return false, 'A character\'s main account is a personal account: change its type first' end
    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `isDefault` = 0 WHERE `ownerCharId` = ? AND `isDefault` = 1', values = { account.ownerCharId } },
        { query = 'UPDATE `bank_accounts` SET `isDefault` = 1 WHERE `accountId` = ?', values = { accountId } },
    })
    if not ok then return false, err end
    local online = PlayersByCharId[account.ownerCharId]
    if online then online.accountNumber = account.accountNumber end
    bankEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'main' })
    return true
end

-- ============================================
-- System Deposit (no permission check)
-- Used by shop system to deposit revenue into business accounts
-- ============================================

--- Deposit without permission check. Used by shops/system processes.
--- Unlike Bank.Deposit, this skips the access permission check — the caller
--- is responsible for authorization. actorCharId is optional for audit trail
--- (e.g. the buyer's charId on a shop sale).
---@param accountId number
---@param amount number
---@param message string|nil
---@param actorCharId number|nil  Who triggered this (nil for pure system actions)
---@param hooks table|nil  whip_core only: { with = stores } written in the same transaction (see bankWrite)
---@return boolean success
---@return string|nil error
function Bank.SystemDeposit(accountId, amount, message, actorCharId, hooks)
    local whole = Sanitize.amount(amount)
    if not whole then return false, AMOUNT_ERR end
    amount = whole

    -- During whip_core's own stop, sent without waiting: a stop step that waits never comes back (a
    -- pump's unspent bank prepay is refunded at step 20). One transaction with no read first: the CHECK
    -- constraints still refuse a closed account, and an unknown one changes no row. (It can't say what
    -- happened, so it is only for the stop.)
    if CoreStop and CoreStop.running then
        local sent = pcall(MySQL.transaction --[[@as function]], {
            { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = {amount, accountId} },
            { query = 'INSERT INTO `bank_transactions` (`actorCharId`, `toAccountId`, `amount`, `type`, `message`, `toBalance`) VALUES (?, ?, ?, ?, ?, (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?))', values = {actorCharId, accountId, amount, 'deposit', message or 'System deposit', accountId} },
        })
        if sent then return true end
        return false, 'could not send the deposit while stopping'
    end

    local account, readErr = Bank.GetAccount(accountId)
    if not account then return false, readErr or 'Account not found' end
    if DbBool(account.frozen) then return false, 'Account is frozen' end
    -- Said plainly; one closed after this read is refused by chk_closed_empty.
    if account.closedAt ~= nil then return false, 'Account is closed' end

    local ok, err = bankWrite({
        { query = 'UPDATE `bank_accounts` SET `balance` = `balance` + ? WHERE `accountId` = ?', values = {amount, accountId} },
        { query = 'INSERT INTO `bank_transactions` (`actorCharId`, `toAccountId`, `amount`, `type`, `message`, `toBalance`) VALUES (?, ?, ?, ?, ?, (SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?))', values = {actorCharId, accountId, amount, 'deposit', message or 'System deposit', accountId} },
    }, { with = hooks and hooks.with })

    if not ok then
        return false, err
    end

    local newBalance = balanceOf(accountId)

    local txData = {
        type = 'deposit', accountId = accountId, amount = amount,
        actorCharId = actorCharId, newBalance = newBalance, message = message,
        ownerCharId = account.ownerCharId, accountType = account.type, label = account.label,   -- (see Bank.Deposit)
    }
    bankEmit('whip_core:bank:balanceChanged', txData)

    return true
end

-- ============================================
-- Startup assertion — the overdraft rule must actually be in the database
-- ============================================
--
-- Withdraw and Transfer rest entirely on the chk_balance_nonneg CHECK constraint that
-- Bank.ensureTable declares. A database that doesn't enforce it (MariaDB older than 10.2.1 accepts
-- the clause and ignores it; a `bank_accounts` built by hand without it) has NO overdraft
-- protection, so this checks the database itself rather than trusting the CREATE.
--
-- Deliberately loud and repeated: the server operator has to fix the schema.
--
-- A step of start-up's housekeeping, after the schema, the migrations and the loads
-- (player_lifecycle.lua).
function Bank.checkBalanceRule()
    local ok, present = pcall(MySQL.scalar.await, [[
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'bank_accounts'
          AND `CONSTRAINT_NAME` = 'chk_balance_nonneg'
    ]])

    if not ok then
        print('[whip_core:bank] could not verify the balance constraint: ' .. tostring(present))
        return
    end

    if (present or 0) > 0 then return end   -- healthy, say nothing

    for _ = 1, 3 do
        print('[whip_core:bank] ============================================================')
        print('[whip_core:bank] chk_balance_nonneg IS MISSING FROM bank_accounts.')
        print('[whip_core:bank] Withdrawals and transfers have NO overdraft protection.')
        print('[whip_core:bank] Balances can go negative and money can be created.')
        print('[whip_core:bank] CHECK constraints need MariaDB 10.2.1 or MySQL 8.0.16 or newer — see the startup log above.')
        print('[whip_core:bank] ============================================================')
    end
end

-- ============================================
-- Public Exports
-- ============================================
-- Not all pure forwards: CreateBankAccount reshapes its arguments (isDefault is pinned false and
-- jobId shifts position), so the wrapper IS the public API surface; don't "simplify" it into an
-- alias. Every name says "Bank".

--- Reason and actor from a system money call's `opts`, { reason, actorCharId }.
---@param opts any
---@return string|nil reason
---@return number|nil actorCharId
---@return string|nil why  for opts that are not a table
local function reasonAndActor(opts)
    if opts == nil then return nil, nil end
    if type(opts) ~= 'table' then return nil, nil, 'opts is { reason?, actorCharId? }' end
    local reason = opts.reason
    reason = type(reason) == 'string' and reason ~= '' and reason:sub(1, 120) or nil
    return reason, tonumber(opts.actorCharId)
end

--- A system money movement a SATELLITE asked for, on the activity log with the resource's name.
--- The bank ledger has the movement itself; what it cannot say is which resource moved money with
--- no permission check, and that is the question an admin will be asking.
---@param what string  'deposit to #5', 'withdrawal from #5', 'transfer #5 → #9'
local function logSystemMove(what, amount, reason, actorCharId, by)
    if not by then return end   -- whip_core's own system moves are its ordinary business
    Log.write(actorCharId, 'bank_system', {
        amount = amount,
        detail = ('%s%s · %s'):format(what, reason and (' · ' .. reason) or '', by),
    })
end

--- A bank row the way the types describe it (WhipBankAccount / WhipBankTransaction / WhipBankAccess):
--- times in epoch SECONDS and flags as booleans. The database hands back milliseconds (oxmysql's
--- TIMESTAMP) and, on some query paths, 0/1. Each row is a fresh query result, so it is converted
--- in place.
---@param row table|nil
---@return table|nil
local function outRow(row)
    if type(row) ~= 'table' then return row end
    for _, f in ipairs({ 'createdAt', 'closedAt', 'grantedAt' }) do
        if row[f] ~= nil then row[f] = EpochSeconds(row[f]) end
    end
    if row.isDefault ~= nil then row.isDefault = DbBool(row.isDefault) end
    if row.frozen ~= nil then row.frozen = DbBool(row.frozen) end
    return row
end

--- And the read's why rides along: a list read answers `{}, why` when the database did not answer.
---@param rows table[]|nil
---@param err string|nil
---@return table[]
---@return string|nil err
local function outRows(rows, err)
    for _, row in ipairs(rows or {}) do outRow(row) end
    return rows or {}, err
end

--- One account: by its accountId, or `{ number = 'WB-123456' }` (its display number), `{ accountId = n }` or
--- `{ id = n }` (as every GetX(ref) takes).
exports('GetBankAccount', function(ref)
    if type(ref) == 'table' then
        if ref.number ~= nil then return outRow(Bank.GetAccountByNumber(ref.number)) end
        ref = ref.accountId or ref.id
    end
    return outRow(Bank.GetAccount(ref))
end)

--- One account's balance, from memory after its first read (see BALANCES IN MEMORY at the top).
---@return integer|false balance
---@return string|nil why
local function balanceOfAccount(accountId)
    local b = _balance[accountId]
    if b ~= nil then return b end
    local ver = _balanceVer[accountId] or 0
    local acc, err = Bank.GetAccount(accountId)
    if not acc then return false, err or 'No such account' end
    if acc.closedAt ~= nil then return false, 'That account is closed' end
    b = tonumber(acc.balance) or 0
    if (_balanceVer[accountId] or 0) == ver then _balance[accountId] = b end   -- nothing moved while it was read
    return b
end

--- A balance without the database, after the first read: a person's main account (a server id or
--- `{ charId = n }`), or one account (`{ accountId = n }`). The balance, or false and why.
exports('GetBalance', function(who)
    if type(who) == 'table' and who.accountId ~= nil then
        local accountId = tonumber(who.accountId)
        if not accountId then return false, 'accountId is a number' end
        return balanceOfAccount(accountId)
    end
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    local main = _mainOf[charId]
    if main == nil then
        local gen, tick = _mainGen, _balanceTick
        local acc, err = Bank.GetDefaultAccount(charId)
        if err then return false, err end
        main = acc and tonumber(acc.accountId) or false
        if _mainGen == gen then _mainOf[charId] = main end
        -- The row read has its balance: kept when no balance anywhere moved while it was read.
        if acc and main and _balance[main] == nil and _balanceTick == tick then _balance[main] = tonumber(acc.balance) end
    end
    if not main then return false, 'They have no bank account' end
    return balanceOfAccount(main)
end)

--- Every account a character can use, each row with their `role` on it.
exports('GetCharacterBankAccounts', function(charId)
    return outRows(Bank.GetCharacterAccounts(charId))
end)

--- A person's default account — `source` or `{ charId = n }` (WhoIs) — or nil.
exports('GetDefaultBankAccount', function(who)
    local charId = WhoIs(who)
    if not charId then return nil end
    return outRow(Bank.GetDefaultAccount(charId))
end)

--- A job's accounts, the job by jobId or KEY like every Jobs export. `{}, why` for a job that does
--- not exist.
exports('GetJobBankAccounts', function(job)
    local def = Jobs.resolve(job)
    if not def then return {}, 'No such job' end
    return outRows(Bank.GetAccountsByJob(def.jobId))
end)

exports('GetBankTransactions', function(accountId, limit, offset)
    return outRows(Bank.GetTransactions(accountId, limit, offset))
end)

exports('GetBankAccessList', function(accountId)
    return outRows(Bank.GetAccessList(accountId))
end)

--- Open a bank account.
---
--- `false`, not nil, on failure: a FiveM export truncates its return list at the first nil, which
--- would take the reason with it. Same rule as CreateGarage.
---
--- Every person here is `source` or `{ charId = n }` (WhoIs): the owner, the grantee, who granted
--- it, who is moving money.
---@return table|false account
---@return string|nil err
exports('CreateBankAccount', function(owner, label, opts)
    if opts ~= nil and type(opts) ~= 'table' then return false, "opts is { type?, job? }: CreateBankAccount(owner, label, { type = 'savings' })" end
    local accountType, job = opts and opts.type, opts and opts.job
    local ownerCharId, why = WhoIs(owner)
    if not ownerCharId then return false, why --[[@as string]] end
    -- The job by jobId or KEY, and one that exists, as every Jobs export takes it: a linked account
    -- joins that job's payroll-access sync.
    local jobId = nil
    if job ~= nil then
        local def = Jobs.resolve(job)
        if not def then return false, 'No such job' end
        jobId = def.jobId
    end
    -- At most Config.MaxExtraAccounts savings and shared accounts a character (the kinds a player opens
    -- for themselves). Their personal account and a job's accounts do not count.
    local kind = accountType or 'personal'
    if jobId == nil and (kind == 'savings' or kind == 'shared') then
        local limit = tonumber(Config.MaxExtraAccounts) or 5
        local have, readErr = Bank.countExtraAccounts(ownerCharId)
        if not have then return false, readErr end
        if have >= limit then
            if limit <= 0 then return false, 'Savings and shared accounts are turned off' end
            return false, ('A character may have at most %d savings and shared accounts'):format(limit)
        end
    end
    local account, err = Bank.CreateAccount(ownerCharId, label, accountType, false, jobId)
    if not account then return false, err or 'Could not create the account' end
    return account
end)

--- Close an account; it must be empty.
---
--- `who` is the player closing it, `source` or `{ charId = n }`, and is checked: they own it, and it is
--- a savings or shared account, not their personal one and not a job's (that closes with the job).
--- Leave `who` out when your own code decides (trusted).
exports('CloseBankAccount', function(accountId, who)
    if who ~= nil then
        local charId, why = WhoIs(who)
        if not charId then return false, why end
        accountId = Sanitize.id(accountId)
        if not accountId then return false, 'Account not found' end
        local account, readErr = Bank.GetAccount(accountId)
        if not account then return false, readErr or 'Account not found' end
        if not Bank.HasPermission(accountId, charId, 'owner') then
            return false, 'Only the owner can close this account'
        end
        if DbBool(account.isDefault) then return false, 'Cannot close default account' end
        if account.jobId then return false, 'A job\'s account closes with the job' end
        if account.type ~= 'savings' and account.type ~= 'shared' then
            return false, 'Only a savings or shared account can be closed'
        end
    end
    return Bank.CloseAccount(accountId)
end)

--- Freeze (true) or unfreeze (false) an account: while frozen, no money goes in or out of it.
--- Trusted — your code decides who may; the activity log records which resource did it.
exports('SetBankAccountFrozen', function(accountId, frozen)
    local by = Log.byCaller()   -- before anything can yield
    local ok, err = Bank.SetFrozen(accountId, frozen == true)
    if ok then
        Log.write(nil, 'bank_system', {
            detail = ('account #%s %s · %s'):format(tostring(accountId), frozen == true and 'frozen' or 'unfrozen',
                by or GetCurrentResourceName()),
        })
    end
    return ok, err
end)

--- Give a person a role on an account. `grantedBy` is a person too, and must be allowed to grant it.
exports('GrantBankAccess', function(accountId, who, role, grantedBy)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    local byCharId, byWhy = WhoIs(grantedBy)
    if not byCharId then return false, byWhy end
    return Bank.GrantAccess(accountId, charId, role, byCharId)
end)

--- Would GrantBankAccess with these arguments be allowed? Every one of its rules, nothing written: for asking before
--- a step that waits on someone (the phone sends an invite, and grants when it is accepted).
exports('CanGrantBankAccess', function(accountId, who, role, grantedBy)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    local byCharId, byWhy = WhoIs(grantedBy)
    if not byCharId then return false, byWhy end
    return Bank.checkGrant(accountId, charId, role, byCharId)
end)

exports('RevokeBankAccess', function(accountId, who, revokedBy)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    local byCharId, byWhy = WhoIs(revokedBy)
    if not byCharId then return false, byWhy end
    return Bank.RevokeAccess(accountId, charId, byCharId)
end)

-- ---- A PLAYER's money: their permission on the account is checked ----
-- `actor` is the person doing it: `source` or `{ charId = n }`.

--- The reason in a bank call's `opts` ({ reason }), or nil and why for opts that are not a table.
---@return string|nil reason
---@return string|nil why
local function optsReason(opts)
    if opts == nil then return nil end
    if type(opts) ~= 'table' then return nil, 'opts is { reason = ... }' end
    return opts.reason
end

exports('BankDeposit', function(accountId, amount, actor, opts)
    local reason, bad = optsReason(opts)
    if bad then return false, bad end
    local charId, why = WhoIs(actor)
    if not charId then return false, why end
    return Bank.Deposit(accountId, amount, charId, reason)
end)

exports('BankWithdraw', function(accountId, amount, actor, opts)
    local reason, bad = optsReason(opts)
    if bad then return false, bad end
    local charId, why = WhoIs(actor)
    if not charId then return false, why end
    return Bank.Withdraw(accountId, amount, charId, reason)
end)

exports('BankTransfer', function(fromId, toId, amount, actor, opts)
    local reason, bad = optsReason(opts)
    if bad then return false, bad end
    local charId, why = WhoIs(actor)
    if not charId then return false, why end
    return Bank.Transfer(fromId, toId, amount, charId, reason)
end)

-- ---- The SYSTEM's money: no permission check, so the caller decides who may ----
--
-- The last argument is `opts`: { reason, actorCharId }. A satellite's system move is
-- written to the activity log with its name (logSystemMove).

--- Pay money into an account — a sale's takings, a wage, a refund.
exports('BankSystemDeposit', function(accountId, amount, opts)
    local by = Log.byCaller()   -- before anything can yield
    local reason, actor, bad = reasonAndActor(opts)
    if bad then return false, bad end
    local ok, err = Bank.SystemDeposit(accountId, amount, reason, actor)
    if ok then logSystemMove(('deposit to account #%s'):format(tostring(accountId)), amount, reason, actor, by) end
    return ok, err
end)

--- Take money out of an account — a fine, a fee, a bill. Refused for a frozen account or
--- one without enough in it.
exports('BankSystemWithdraw', function(accountId, amount, opts)
    local by = Log.byCaller()
    local reason, actor, bad = reasonAndActor(opts)
    if bad then return false, bad end
    local ok, err = Bank.SystemWithdraw(accountId, amount, reason, actor)
    if ok then logSystemMove(('withdrawal from account #%s'):format(tostring(accountId)), amount, reason, actor, by) end
    return ok, err
end)

--- Move money between two accounts — payroll out of a business account.
exports('BankSystemTransfer', function(fromId, toId, amount, opts)
    local by = Log.byCaller()
    local reason, actor, bad = reasonAndActor(opts)
    if bad then return false, bad end
    local ok, err = Bank.SystemTransfer(fromId, toId, amount, reason, actor)
    if ok then
        logSystemMove(('transfer from account #%s to #%s'):format(tostring(fromId), tostring(toId)), amount, reason, actor, by)
    end
    return ok, err
end)

--- May this person use this account for `role` ('view', 'deposit', 'withdraw', 'manager',
--- 'owner')? Answers `true`, or `false, reason`.
---
--- The account first, then the person (`source` or `{ charId = n }`), the order of every other bank
--- export.
exports('CanUseBankAccount', function(accountId, who, role)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    return Bank.CanUse(charId, accountId, role)
end)
