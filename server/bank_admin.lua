-- ============================================
-- /whip → Banks: the server half (html/js/wp/banks.js)
-- ============================================
--
-- Everything that can hold a bank account, with one or without: players (their characters hold the money),
-- businesses (jobs), lore characters, and any account nobody holds. Each opens on a dashboard: their money,
-- what they are worth, every transaction. From there an admin makes, changes and closes accounts.
--
-- WHAT THEY ARE WORTH is an estimate: their bank accounts, their cash, their cars at what the sellers ask, their
-- properties at their listed price, what they hold (pockets, boots, stashes, and inside other items) at the average
-- of the shops selling it, and any business they own. What nobody sells counts for nothing, and is named.
--
-- A DELETED CHARACTER counts while it still has an open account: that money is still in the game. "Delete" closes an
-- account (Bank.CloseAccount): its ledger rows are records and stay, with the account they name.
--
-- Money moves through Bank.System*, so it has its ledger row and its event like any other. Everything done here goes
-- on the activity log as bank_admin, on the admin's timeline and the account owner's.

local ACE = 'whip.devtools'
local MAX_MONEY = 1000000000000
local LOG_PAGE = 50
local CASH_PAGE = 30
local CHART_DAYS = 30
local PUSH_EVERY_MS = 3000   -- a busy shop's sales reach an open page together
local KINDS = { 'player', 'business', 'lore', 'other' }

---@param kind 'query'|'scalar'|'single'
---@return any result  nil on a database error
---@return string|nil err
local function read(kind, sql, params)
    local ok, result = pcall(MySQL[kind].await, sql, params or {})
    if not ok then
        print(('[whip_core:banks] read failed: %s'):format(tostring(result)))
        return nil, DB_ERROR
    end
    return result
end

local function marks(n) return string.rep('?', n, ',') end
local function num(v) return tonumber(v) or 0 end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

--- The lists one after another, for a query that names them in turn.
local function joined(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do out[#out + 1] = v end
    end
    return out
end

-- ---- accounts ----

local ACCOUNT_SELECT = [[SELECT b.`accountId`, b.`accountNumber`, b.`label`, b.`type`, b.`balance`, b.`isDefault`, b.`frozen`,
        b.`ownerCharId`, b.`jobId`, UNIX_TIMESTAMP(b.`createdAt`) AS `openedAt`, UNIX_TIMESTAMP(b.`closedAt`) AS `closedAt`,
        CONCAT(c.`firstName`, ' ', c.`lastName`) AS `ownerName`, c.`userId` AS `ownerUserId`,
        c.`deleted` IS NOT NULL AS `ownerGone`
    FROM `bank_accounts` b LEFT JOIN `characters` c ON c.`charId` = b.`ownerCharId` ]]

--- Account rows as the page reads them. nil and why when the read failed.
local function accountRows(where, params)
    local rows, err = read('query', ACCOUNT_SELECT .. where, params)
    if not rows then return nil, err end
    for _, r in ipairs(rows) do
        r.balance = num(r.balance)
        r.isDefault, r.frozen, r.ownerGone = DbBool(r.isDefault), DbBool(r.frozen), DbBool(r.ownerGone)
        local job = r.jobId and Jobs.cache[r.jobId]
        if job then r.jobName = job.name end
    end
    return rows
end

--- One account, open or closed. nil and why.
local function accountById(accountId)
    local rows, err = accountRows('WHERE b.`accountId` = ?', { accountId })
    if not rows then return nil, err end
    if not rows[1] then return nil, 'That account is gone' end
    return rows[1]
end

--- The lore character this account belongs to, if one does.
local function loreOfAccount(accountId)
    for _, c in ipairs(DirectorLore.list(true)) do
        if c.accountId == accountId then return c end
    end
    return nil
end

--- The WHERE for the accounts nobody holds: no owner, no job that exists, no lore character. And its params.
local function nobodysWhere()
    local jobs, lore = {}, {}
    for jobId in pairs(Jobs.cache) do jobs[#jobs + 1] = jobId end
    for _, c in ipairs(DirectorLore.list(true)) do
        if c.accountId then lore[#lore + 1] = c.accountId end
    end
    local where = 'b.`ownerCharId` IS NULL AND b.`closedAt` IS NULL'
    if #jobs > 0 then where = where .. ' AND (b.`jobId` IS NULL OR b.`jobId` NOT IN (' .. marks(#jobs) .. '))' end
    if #lore > 0 then where = where .. ' AND b.`accountId` NOT IN (' .. marks(#lore) .. ')' end
    return where, joined(jobs, lore)
end

-- ---- the list ----

local function directory()
    local online = {}
    for src, p in pairs(Players) do
        if p.userId and not online[p.userId] then online[p.userId] = { source = src, charId = p.charId, name = p.fullName } end
    end

    -- Only an account with a character can hold money: one that never made a character has nothing to list.
    local users, err = read('query', [[
        SELECT u.`userId`, u.`name`, u.`license`, u.`lastSeen`,
            (SELECT GROUP_CONCAT(CONCAT(c.`firstName`, ' ', c.`lastName`) SEPARATOR ', ')
               FROM `characters` c WHERE c.`userId` = u.`userId` AND c.`deleted` IS NULL) AS `characterNames`,
            (SELECT c.`charId` FROM `characters` c WHERE c.`userId` = u.`userId` AND c.`deleted` IS NULL
              ORDER BY c.`lastPlayed` DESC LIMIT 1) AS `faceCharId`,
            a.`accounts`, a.`bank`, a.`numbers`
        FROM `users` u
        LEFT JOIN (
            SELECT c.`userId`, COUNT(*) AS `accounts`, SUM(b.`balance`) AS `bank`,
                   GROUP_CONCAT(b.`accountNumber` SEPARATOR ' ') AS `numbers`
            FROM `bank_accounts` b JOIN `characters` c ON c.`charId` = b.`ownerCharId`
            WHERE b.`closedAt` IS NULL AND b.`jobId` IS NULL
            GROUP BY c.`userId`
        ) a ON a.`userId` = u.`userId`
        HAVING `characterNames` IS NOT NULL OR `accounts` > 0
        ORDER BY u.`lastSeen` DESC
        LIMIT 1000
    ]])
    if not users then return false, err end

    local entries = {}
    for _, u in ipairs(users) do
        local on = online[u.userId]
        entries[#entries + 1] = {
            kind = 'player', id = tostring(u.userId), userId = u.userId, name = u.name or 'Unknown', license = u.license,
            online = on ~= nil, source = on and on.source or nil, currentChar = on and on.name or nil,
            faceCharId = (on and on.charId) or u.faceCharId, characterNames = u.characterNames, lastSeen = u.lastSeen,
            accounts = num(u.accounts), bank = num(u.bank), numbers = u.numbers,
        }
    end

    local byJob
    byJob, err = read('query', [[SELECT `jobId`, COUNT(*) AS `accounts`, SUM(`balance`) AS `bank`,
            GROUP_CONCAT(`accountNumber` SEPARATOR ' ') AS `numbers`
        FROM `bank_accounts` WHERE `jobId` IS NOT NULL AND `closedAt` IS NULL GROUP BY `jobId`]])
    if not byJob then return false, err end
    local jobMoney = {}
    for _, r in ipairs(byJob) do jobMoney[r.jobId] = r end
    local ownerIds = {}
    for _, job in pairs(Jobs.cache) do
        if job.ownerCharId then ownerIds[#ownerIds + 1] = job.ownerCharId end
    end
    local owners = ResolveCharNames(ownerIds)
    for jobId, job in pairs(Jobs.cache) do
        local m = jobMoney[jobId]
        entries[#entries + 1] = {
            kind = 'business', id = tostring(jobId), name = job.name or ('Job #' .. jobId), key = job.key,
            ownerName = job.ownerCharId and owners[job.ownerCharId] or nil,
            accounts = m and num(m.accounts) or 0, bank = m and num(m.bank) or 0, numbers = m and m.numbers or nil,
        }
    end

    -- Lore characters: a retired one only while it still has money to account for.
    local lore, loreIds = DirectorLore.list(true), {}
    for _, c in ipairs(lore) do
        if c.accountId then loreIds[#loreIds + 1] = c.accountId end
    end
    local loreMoney = {}
    if #loreIds > 0 then
        local rows
        rows, err = read('query', 'SELECT `accountId`, `balance`, `accountNumber` FROM `bank_accounts` WHERE `closedAt` IS NULL AND `accountId` IN ('
            .. marks(#loreIds) .. ')', loreIds)
        if not rows then return false, err end
        for _, r in ipairs(rows) do loreMoney[r.accountId] = r end
    end
    for _, c in ipairs(lore) do
        local m = c.accountId and loreMoney[c.accountId]
        if m or not c.retired then
            entries[#entries + 1] = {
                kind = 'lore', id = c.key, name = c.name, retired = c.retired or nil, bankName = c.bankName,
                accounts = m and 1 or 0, bank = m and num(m.balance) or 0, numbers = m and m.accountNumber or nil,
            }
        end
    end

    local where, params = nobodysWhere()
    local nobody
    nobody, err = read('single', 'SELECT COUNT(*) AS `accounts`, COALESCE(SUM(b.`balance`), 0) AS `bank`, '
        .. "GROUP_CONCAT(b.`accountNumber` SEPARATOR ' ') AS `numbers` FROM `bank_accounts` b WHERE " .. where, params)
    if not nobody then return false, err or 'The bank did not answer' end
    if num(nobody.accounts) > 0 then
        entries[#entries + 1] = {
            kind = 'other', id = 'none', name = 'Accounts with no holder',
            accounts = num(nobody.accounts), bank = num(nobody.bank), numbers = nobody.numbers,
        }
    end

    -- The whole bank at a glance, for the page with nobody picked.
    local bank, moved, cash
    bank, err = read('single', [[SELECT COUNT(*) AS `accounts`, COALESCE(SUM(`balance`), 0) AS `bank`,
        COALESCE(SUM(`frozen`), 0) AS `frozen` FROM `bank_accounts` WHERE `closedAt` IS NULL]])
    if not bank then return false, err or 'The bank did not answer' end
    moved, err = read('single', [[SELECT COUNT(*) AS `count`, COALESCE(SUM(`amount`), 0) AS `amount`
        FROM `bank_transactions` WHERE `createdAt` >= NOW() - INTERVAL 1 DAY]])
    if not moved then return false, err or 'The bank did not answer' end
    cash, err = read('scalar', "SELECT COALESCE(SUM(`amount`), 0) FROM `character_inventory` WHERE `item` = 'cash'")
    if err then return false, err end

    return {
        entries = entries,
        totals = {
            accounts = num(bank.accounts), bank = num(bank.bank), frozen = num(bank.frozen), cash = num(cash),
            movedCount = num(moved.count), movedAmount = num(moved.amount),
        },
    }
end

-- ---- what a page is about ----

--- Who a page is about, and every account that is theirs (closed ones too: their statements stay part of the log).
---@param kind string
---@param id string
---@param charId number  a player's page narrowed to one character; 0 for all of them
---@return table|false scope
---@return string|nil why
local function scopeOf(kind, id, charId)
    local scope = { kind = kind, id = id, charIds = {} }
    local err

    if kind == 'player' then
        local userId = Sanitize.id(id)
        local user = userId and read('single', 'SELECT `userId`, `name`, `lastSeen` FROM `users` WHERE `userId` = ?', { userId })
        if not user then return false, 'That player is gone' end
        scope.userId, scope.name, scope.lastSeen = user.userId, user.name or 'Unknown', user.lastSeen

        local chars
        chars, err = read('query', [[SELECT c.`charId`, c.`firstName`, c.`lastName`, c.`deleted` IS NOT NULL AS `gone`,
                (SELECT COUNT(*) FROM `bank_accounts` b WHERE b.`ownerCharId` = c.`charId` AND b.`jobId` IS NULL
                  AND b.`closedAt` IS NULL) AS `open`
            FROM `characters` c WHERE c.`userId` = ? ORDER BY c.`deleted` IS NOT NULL, c.`charId`]], { userId })
        if not chars then return false, err end
        scope.characters = {}
        local all, known = {}, {}
        for _, c in ipairs(chars) do
            local gone = DbBool(c.gone)
            if not gone or num(c.open) > 0 then
                local on = PlayersByCharId[c.charId]
                scope.characters[#scope.characters + 1] = {
                    charId = c.charId, name = trim((c.firstName or '') .. ' ' .. (c.lastName or '')), gone = gone,
                    online = on ~= nil, source = on and on.source or nil,
                }
                all[#all + 1] = c.charId
                known[c.charId] = true
            end
        end
        if charId and charId > 0 and known[charId] then
            scope.charIds = { charId }
            scope.charId = charId
        else
            scope.charIds = all
            scope.charId = 0
        end
        if #scope.charIds > 0 then
            scope.accounts, err = accountRows('WHERE b.`ownerCharId` IN (' .. marks(#scope.charIds) .. ') AND b.`jobId` IS NULL '
                .. 'ORDER BY b.`closedAt` IS NOT NULL, b.`isDefault` DESC, b.`accountId`', scope.charIds)
            if not scope.accounts then return false, err end
        else
            scope.accounts = {}
        end

    elseif kind == 'business' then
        local jobId = Sanitize.id(id)
        local job = jobId and Jobs.cache[jobId]
        if not job then return false, 'That business is gone' end
        scope.jobId, scope.name, scope.key = jobId, job.name or ('Job #' .. jobId), job.key
        if job.ownerCharId then
            scope.ownerCharId = job.ownerCharId
            scope.ownerName = ResolveCharNames({ job.ownerCharId })[job.ownerCharId]
        end
        scope.accounts, err = accountRows('WHERE b.`jobId` = ? ORDER BY b.`closedAt` IS NOT NULL, b.`accountId`', { jobId })
        if not scope.accounts then return false, err end

    elseif kind == 'lore' then
        local c = DirectorLore.get(id)
        if not c then return false, 'That lore character is gone' end
        scope.name, scope.retired, scope.bankName = c.name, c.retired or nil, c.bankName
        if c.accountId then
            scope.accounts, err = accountRows('WHERE b.`accountId` = ?', { c.accountId })
            if not scope.accounts then return false, err end
        else
            scope.accounts = {}
        end

    elseif kind == 'other' then
        scope.name = 'Accounts with no holder'
        local where, params = nobodysWhere()
        scope.accounts, err = accountRows('WHERE ' .. where .. ' ORDER BY b.`accountId`', params)
        if not scope.accounts then return false, err end

    else
        return false, 'Nothing to show'
    end

    scope.accountIds = {}
    for i, a in ipairs(scope.accounts) do scope.accountIds[i] = a.accountId end
    return scope
end

-- ---- what they are worth ----

--- Count a stack, and what is inside it (a bag's contents, a gun's magazine, a wallet's cash).
local function tally(into, item, amount, metadata, depth)
    if type(metadata) == 'string' then
        local ok, decoded = pcall(json.decode, metadata)
        metadata = ok and decoded or nil
    end
    amount = num(amount)
    if item == 'cash' then
        into.cash = into.cash + amount
    else
        into.items[item] = (into.items[item] or 0) + amount
    end
    if depth >= Inventory.MAX_NESTING then return end
    for _, entry in pairs(Inventory.contentsOf(item, metadata) or {}) do
        if type(entry) == 'table' and entry.item then
            tally(into, entry.item, entry.amount or 1, entry.metadata, depth + 1)
        end
    end
end

--- Every job's shelves: [containerId] = jobId. They are the business's stock, whoever's name is on the container.
local function jobShelves()
    local out = {}
    for _, def in pairs(Shops.cache) do
        if def.jobId and def.containerId then out[def.containerId] = def.jobId end
    end
    return out
end

--- Everything these characters hold: pockets, their cars' boots, their stashes and their properties' stashes.
---@return table|nil tally  { cash, items = { [item] = amount } }
---@return string|nil why
local function holdingsOf(charIds)
    local into = { cash = 0, items = {} }
    if #charIds == 0 then return into end
    local list = marks(#charIds)
    local rows, err = read('query', 'SELECT `item`, `amount`, `metadata` FROM `character_inventory` WHERE `charId` IN (' .. list .. ')', charIds)
    if not rows then return nil, err end
    for _, r in ipairs(rows) do tally(into, r.item, r.amount, r.metadata, 1) end

    rows, err = read('query', 'SELECT i.`item`, i.`amount`, i.`metadata` FROM `vehicle_inventory` i JOIN `vehicles` v ON v.`vehicleId` = i.`vehicleId` '
        .. 'WHERE v.`ownerCharId` IN (' .. list .. ')', charIds)
    if not rows then return nil, err end
    for _, r in ipairs(rows) do tally(into, r.item, r.amount, r.metadata, 1) end

    rows, err = read('query', 'SELECT i.`containerId`, i.`item`, i.`amount`, i.`metadata` FROM `container_inventory` i '
        .. 'JOIN `containers` c ON c.`containerId` = i.`containerId` LEFT JOIN `properties` p ON p.`propertyId` = c.`propertyId` '
        .. 'WHERE c.`ownerCharId` IN (' .. list .. ') OR (p.`ownerCharId` IN (' .. list .. ') AND p.`deletedAt` IS NULL)',
        joined(charIds, charIds))
    if not rows then return nil, err end
    local shelves = jobShelves()
    for _, r in ipairs(rows) do
        if not shelves[r.containerId] then tally(into, r.item, r.amount, r.metadata, 1) end
    end
    return into
end

--- Items at the shops' average: what has a price, what has none. Biggest first.
local function valueItems(items, book)
    local out = { total = 0, list = {}, unpriced = {} }
    for item, amount in pairs(items) do
        local def = Config.Items[item]
        local name = def and def.name or item
        local p = book[item]
        if p then
            local value = p.price * amount
            out.total = out.total + value
            out.list[#out.list + 1] = { item = item, name = name, amount = amount, price = p.price, shops = p.shops, value = value }
        else
            out.unpriced[#out.unpriced + 1] = { item = item, name = name, amount = amount }
        end
    end
    table.sort(out.list, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.name < b.name
    end)
    table.sort(out.unpriced, function(a, b) return a.name < b.name end)
    return out
end

local function valueVehicles(charIds)
    local out = { total = 0, list = {}, unpriced = 0 }
    if #charIds == 0 then return out end
    local rows, err = read('query', 'SELECT `vehicleId`, `model`, `plate`, `state` FROM `vehicles` WHERE `ownerCharId` IN (' .. marks(#charIds) .. ') ORDER BY `vehicleId`', charIds)
    if not rows then return nil, err end
    for _, r in ipairs(rows) do
        local price, sellers = Prices.vehicle(r.model)
        local entry = VehicleCatalog.rows[tostring(r.model):lower()]
        out.list[#out.list + 1] = {
            vehicleId = r.vehicleId, model = r.model, name = entry and entry.displayName or r.model, plate = r.plate,
            state = r.state, value = price, sellers = sellers,
        }
        if price then out.total = out.total + price else out.unpriced = out.unpriced + 1 end
    end
    table.sort(out.list, function(a, b) return (a.value or 0) > (b.value or 0) end)
    return out
end

local function valueProperties(charIds)
    local out = { total = 0, list = {}, unpriced = 0 }
    local wanted = {}
    for _, id in ipairs(charIds) do wanted[id] = true end
    for propertyId, rec in pairs(Properties.getAll()) do
        if wanted[rec.ownerCharId] then
            local price = Prices.property(rec)
            out.list[#out.list + 1] = { propertyId = propertyId, name = rec.name or ('Property #' .. propertyId), value = price }
            if price then out.total = out.total + price else out.unpriced = out.unpriced + 1 end
        end
    end
    table.sort(out.list, function(a, b) return (a.value or 0) > (b.value or 0) end)
    return out
end

--- A business: what is in its accounts, and its shelves at the shops' average.
local function valueBusiness(jobId, book)
    local money, err = read('scalar', 'SELECT COALESCE(SUM(`balance`), 0) FROM `bank_accounts` WHERE `jobId` = ? AND `closedAt` IS NULL', { jobId })
    if err then return nil, err end
    local shelves = {}
    for containerId, owner in pairs(jobShelves()) do
        if owner == jobId then shelves[#shelves + 1] = containerId end
    end
    local into = { cash = 0, items = {} }
    if #shelves > 0 then
        local rows
        rows, err = read('query', 'SELECT `item`, `amount`, `metadata` FROM `container_inventory` WHERE `containerId` IN (' .. marks(#shelves) .. ')', shelves)
        if not rows then return nil, err end
        for _, r in ipairs(rows) do tally(into, r.item, r.amount, r.metadata, 1) end
    end
    local stock = valueItems(into.items, book)
    return { bank = num(money), cash = into.cash, stock = stock, total = num(money) + into.cash + stock.total }
end

--- What this page's holder is worth. nil and why when something could not be read.
local function worthOf(scope)
    local bank = 0
    for _, a in ipairs(scope.accounts) do
        if not a.closedAt then bank = bank + a.balance end
    end
    local worth = { bank = bank, cash = 0, total = bank }
    if scope.kind ~= 'player' and scope.kind ~= 'business' then return worth end

    local book = Prices.items()
    if scope.kind == 'business' then
        local b, err = valueBusiness(scope.jobId, book)
        if not b then return nil, err end
        worth.cash, worth.items, worth.total = b.cash, b.stock, b.total
        return worth
    end

    local held, err = holdingsOf(scope.charIds)
    if not held then return nil, err end
    worth.cash = held.cash
    worth.items = valueItems(held.items, book)
    worth.vehicles, err = valueVehicles(scope.charIds)
    if not worth.vehicles then return nil, err end
    worth.properties = valueProperties(scope.charIds)

    worth.businesses = { total = 0, list = {} }
    local owned = {}
    for _, charId in ipairs(scope.charIds) do owned[charId] = true end
    local jobs = {}
    for jobId, job in pairs(Jobs.cache) do
        if owned[job.ownerCharId] then jobs[#jobs + 1] = { jobId = jobId, name = job.name } end
    end
    table.sort(jobs, function(a, b) return a.jobId < b.jobId end)
    for _, job in ipairs(jobs) do
        local b
        b, err = valueBusiness(job.jobId, book)
        if not b then return nil, err end
        worth.businesses.list[#worth.businesses.list + 1] = { jobId = job.jobId, name = job.name, bank = b.bank, stock = b.stock.total, value = b.total }
        worth.businesses.total = worth.businesses.total + b.total
    end

    worth.total = bank + worth.cash + worth.items.total + worth.vehicles.total + worth.properties.total + worth.businesses.total
    return worth
end

-- ---- transactions ----

--- How many, and what came in and went out by day over the last CHART_DAYS. Between the holder's own accounts is
--- neither.
local function activityOf(ids)
    local stamp = os.date('*t') --[[@as osdate]]
    stamp.hour, stamp.min, stamp.sec = 0, 0, 0
    local since = os.time(stamp) - (CHART_DAYS - 1) * 86400
    local out = { count = 0, moneyIn = 0, moneyOut = 0, since = since, days = CHART_DAYS, series = {} }
    if #ids == 0 then return out end
    local list = marks(#ids)

    local count, err = read('scalar', 'SELECT COUNT(*) FROM `bank_transactions` WHERE `fromAccountId` IN (' .. list .. ') OR `toAccountId` IN (' .. list .. ')', joined(ids, ids))
    if err then return nil, err end
    out.count = num(count)

    local byDay = {}
    local function side(column, other, field)
        local rows, why = read('query', ('SELECT FLOOR((UNIX_TIMESTAMP(`createdAt`) - ?) / 86400) AS `b`, SUM(`amount`) AS `total` FROM `bank_transactions` '
            .. 'WHERE `%s` IN (%s) AND (`%s` IS NULL OR `%s` NOT IN (%s)) AND `createdAt` >= FROM_UNIXTIME(?) GROUP BY `b`'):format(column, list, other, other, list),
            joined({ since }, ids, ids, { since }))
        if not rows then return why end
        for _, r in ipairs(rows) do
            local b = math.floor(num(r.b))
            local day = byDay[b]
            if not day then day = { b = b, ['in'] = 0, out = 0 }; byDay[b] = day end
            day[field] = day[field] + num(r.total)
            if field == 'in' then out.moneyIn = out.moneyIn + num(r.total) else out.moneyOut = out.moneyOut + num(r.total) end
        end
    end
    local why = side('toAccountId', 'fromAccountId', 'in') or side('fromAccountId', 'toAccountId', 'out')
    if why then return nil, why end
    for _, day in pairs(byDay) do out.series[#out.series + 1] = day end
    table.sort(out.series, function(a, b) return a.b < b.b end)
    return out
end

--- A page of the ledger, newest first, each row said from this holder's side.
---@param ids number[]  every account of the holder
---@param within number[]  the accounts asked about (`ids`, or one of them)
---@param dir string  'all' | 'in' | 'out'
---@param beforeId number  older than this row (0: from the top)
local function ledgerPage(ids, within, dir, beforeId)
    if #ids == 0 or #within == 0 then return { rows = {}, more = false } end
    local inside, all = marks(#within), marks(#ids)
    local where, params
    if dir == 'in' then
        where = 't.`toAccountId` IN (' .. inside .. ') AND (t.`fromAccountId` IS NULL OR t.`fromAccountId` NOT IN (' .. all .. '))'
        params = joined(within, ids)
    elseif dir == 'out' then
        where = 't.`fromAccountId` IN (' .. inside .. ') AND (t.`toAccountId` IS NULL OR t.`toAccountId` NOT IN (' .. all .. '))'
        params = joined(within, ids)
    else
        where = '(t.`fromAccountId` IN (' .. inside .. ') OR t.`toAccountId` IN (' .. inside .. '))'
        params = joined(within, within)
    end
    if beforeId > 0 then
        where = where .. ' AND t.`txId` < ?'
        params[#params + 1] = beforeId
    end
    params[#params + 1] = LOG_PAGE + 1

    local rows, err = read('query', [[SELECT t.`txId`, t.`fromAccountId`, t.`toAccountId`, t.`amount`, t.`type`, t.`message`,
            t.`fromBalance`, t.`toBalance`, UNIX_TIMESTAMP(t.`createdAt`) AS `at`,
            fa.`label` AS `fromLabel`, fa.`accountNumber` AS `fromNumber`, fa.`jobId` AS `fromJobId`,
            ta.`label` AS `toLabel`, ta.`accountNumber` AS `toNumber`, ta.`jobId` AS `toJobId`,
            CONCAT(fc.`firstName`, ' ', fc.`lastName`) AS `fromOwner`, fc.`userId` AS `fromUserId`,
            CONCAT(tc.`firstName`, ' ', tc.`lastName`) AS `toOwner`, tc.`userId` AS `toUserId`,
            CONCAT(ac.`firstName`, ' ', ac.`lastName`) AS `actorName`, ac.`userId` AS `actorUserId`
        FROM `bank_transactions` t
        LEFT JOIN `bank_accounts` fa ON fa.`accountId` = t.`fromAccountId`
        LEFT JOIN `characters` fc ON fc.`charId` = fa.`ownerCharId`
        LEFT JOIN `bank_accounts` ta ON ta.`accountId` = t.`toAccountId`
        LEFT JOIN `characters` tc ON tc.`charId` = ta.`ownerCharId`
        LEFT JOIN `characters` ac ON ac.`charId` = t.`actorCharId`
        WHERE ]] .. where .. ' ORDER BY t.`txId` DESC LIMIT ?', params)
    if not rows then return nil, err end

    local mine = {}
    for _, id in ipairs(ids) do mine[id] = true end
    local out = { rows = {}, more = #rows > LOG_PAGE }
    for i = 1, math.min(#rows, LOG_PAGE) do
        local r = rows[i]
        local fromMine, toMine = mine[r.fromAccountId], mine[r.toAccountId]
        local dirWas = (fromMine and toMine) and 'own' or toMine and 'in' or 'out'
        local row = { txId = r.txId, at = r.at, type = r.type, amount = num(r.amount), message = r.message, dir = dirWas,
                      by = r.actorName, byUserId = r.actorUserId }
        -- The account of theirs it touched, and the other side.
        if dirWas == 'in' then
            row.account, row.number, row.balance = r.toLabel, r.toNumber, r.toBalance
            row.other, row.otherNumber, row.otherLabel, row.otherUserId, row.otherJobId = r.fromOwner, r.fromNumber, r.fromLabel, r.fromUserId, r.fromJobId
        elseif dirWas == 'out' then
            row.account, row.number, row.balance = r.fromLabel, r.fromNumber, r.fromBalance
            row.other, row.otherNumber, row.otherLabel, row.otherUserId, row.otherJobId = r.toOwner, r.toNumber, r.toLabel, r.toUserId, r.toJobId
        else
            row.account, row.number, row.balance = r.fromLabel, r.fromNumber, r.fromBalance
            row.other, row.otherNumber, row.otherLabel = nil, r.toNumber, r.toLabel
        end
        out.rows[i] = row
    end
    return out
end

-- ---- reads for the page ----

--- Open a list like every other tool's: asking registers the viewer, a re-ask is harmless.
SecureCallback('whip_core:bank:directory', {
    ace = ACE, rateLimit = 250, burst = 5,
}, function(source)
    DevTools.viewers.banks[source] = true
    return directory()
end)

SecureCallback('whip_core:bank:dashboard', {
    -- Burst room: a refused read would leave the previous holder's page on screen beside the new row.
    ace = ACE, rateLimit = 100, burst = 5,
    params = { {'kind', 'enum', KINDS}, {'id', 'key', 64}, {'charId', 'id', 0} },
}, function(_, _, kind, id, charId)
    local scope, why = scopeOf(kind, id, charId)
    if not scope then return false, why end
    local worth, activity
    worth, why = worthOf(scope)
    if not worth then return false, why end
    activity, why = activityOf(scope.accountIds)
    if not activity then return false, why end

    -- Other people's accounts their characters can use: not theirs, so counted nowhere; still worth seeing.
    local shared = {}
    if #scope.charIds > 0 then
        local list = marks(#scope.charIds)
        local rows, err = read('query', [[SELECT x.`charId`, x.`role`, b.`accountId`, b.`accountNumber`, b.`label`, b.`type`, b.`balance`, b.`frozen`,
                b.`jobId`, CONCAT(c.`firstName`, ' ', c.`lastName`) AS `ownerName`
            FROM `bank_access` x JOIN `bank_accounts` b ON b.`accountId` = x.`accountId`
            LEFT JOIN `characters` c ON c.`charId` = b.`ownerCharId`
            WHERE x.`charId` IN (]] .. list .. [[) AND b.`closedAt` IS NULL
              AND (b.`jobId` IS NOT NULL OR b.`ownerCharId` IS NULL OR b.`ownerCharId` NOT IN (]] .. list .. [[))
            ORDER BY b.`accountId`]], joined(scope.charIds, scope.charIds))
        if not rows then return false, err end
        for _, r in ipairs(rows) do
            local job = r.jobId and Jobs.cache[r.jobId]
            shared[#shared + 1] = {
                accountId = r.accountId, accountNumber = r.accountNumber, label = r.label, type = r.type, balance = num(r.balance),
                frozen = DbBool(r.frozen), role = r.role, ownerName = r.ownerName, jobName = job and job.name or nil,
            }
        end
    end

    return {
        kind = scope.kind, id = scope.id, name = scope.name, userId = scope.userId, lastSeen = scope.lastSeen,
        characters = scope.characters, charId = scope.charId, jobId = scope.jobId, key = scope.key,
        ownerCharId = scope.ownerCharId, ownerName = scope.ownerName, retired = scope.retired, bankName = scope.bankName,
        accounts = scope.accounts, shared = shared, worth = worth, activity = activity,
    }
end)

--- The ledger. kind 'account' is one account's own, whoever holds it; otherwise a page's, optionally one of its
--- accounts (`accountId`).
SecureCallback('whip_core:bank:ledger', {
    ace = ACE, rateLimit = 100, burst = 5,
    params = {
        {'kind', 'enum', { 'player', 'business', 'lore', 'other', 'account' }}, {'id', 'key', 64}, {'charId', 'id', 0},
        {'accountId', 'id', 0}, {'dir', 'enum', { 'all', 'in', 'out' }, 'all'}, {'beforeId', 'id', 0},
    },
}, function(_, _, kind, id, charId, accountId, dir, beforeId)
    local ids
    if kind == 'account' then
        local only = Sanitize.id(id)
        if not only then return false, 'That account is gone' end
        ids = { only }
    else
        local scope, why = scopeOf(kind, id, charId)
        if not scope then return false, why end
        ids = scope.accountIds
    end
    local within = ids
    if accountId > 0 then
        within = {}
        for _, known in ipairs(ids) do
            if known == accountId then within = { known } end
        end
    end
    local page, why = ledgerPage(ids, within, dir, beforeId)
    if not page then return false, why end
    return page
end)

--- The cash side of the log: the characters' cash coming and going, off the activity log.
SecureCallback('whip_core:bank:cashLog', {
    ace = ACE, rateLimit = 100, burst = 5,
    params = { {'id', 'key', 64}, {'charId', 'id', 0}, {'beforeId', 'id', 0} },
}, function(_, _, id, charId, beforeId)
    local scope, why = scopeOf('player', id, charId)
    if not scope then return false, why end
    return { rows = Log.cashRows(scope.charIds, beforeId, CASH_PAGE), page = CASH_PAGE }
end)

SecureCallback('whip_core:bank:account', {
    ace = ACE, rateLimit = 100, burst = 5,
    params = { {'accountId', 'id'} },
}, function(_, _, accountId)
    local a, why = accountById(accountId)
    if not a then return false, why end
    local lore = loreOfAccount(accountId)
    if lore then a.loreName = lore.name end

    local access
    access, why = read('query', [[SELECT x.`charId`, x.`role`, CONCAT(c.`firstName`, ' ', c.`lastName`) AS `name`, c.`deleted` IS NOT NULL AS `gone`
        FROM `bank_access` x LEFT JOIN `characters` c ON c.`charId` = x.`charId` WHERE x.`accountId` = ?
        ORDER BY FIELD(x.`role`, 'owner', 'manager', 'withdraw', 'deposit', 'view'), x.`charId`]], { accountId })
    if not access then return false, why end
    for _, row in ipairs(access) do row.gone = DbBool(row.gone) end

    -- The holder's other open accounts: where its money can go when it closes.
    local siblings = {}
    if a.jobId then
        siblings, why = accountRows('WHERE b.`jobId` = ? AND b.`accountId` <> ? AND b.`closedAt` IS NULL ORDER BY b.`accountId`', { a.jobId, accountId })
    elseif a.ownerCharId then
        siblings, why = accountRows('WHERE b.`ownerCharId` = ? AND b.`accountId` <> ? AND b.`jobId` IS NULL AND b.`closedAt` IS NULL ORDER BY b.`accountId`', { a.ownerCharId, accountId })
    end
    if not siblings then return false, why end

    local activity
    activity, why = activityOf({ accountId })
    if not activity then return false, why end
    return { account = a, access = access, siblings = siblings, activity = activity }
end)

-- ---- changes ----

--- On the admin's timeline, and the owner's when it is someone else's account.
local function logged(player, account, detail, amount)
    local line = ('%s %s (%s)'):format(player.fullName or 'An admin', detail, account.accountNumber or ('#' .. tostring(account.accountId)))
    Log.write(player.charId, 'bank_admin', { amount = amount, detail = line })
    if account.ownerCharId and account.ownerCharId ~= player.charId then
        Log.write(account.ownerCharId, 'bank_admin', { amount = amount, detail = line })
    end
end

--- An account by the number an admin typed, open. nil and why.
local function accountByNumber(number)
    number = trim(number):upper()
    if number == '' then return nil, 'Which account? Give its number, like WB-123456' end
    local account, err = Bank.GetAccountByNumber(number)
    if not account then return nil, err or ('No open account is numbered ' .. number) end
    return account
end

SecureCallback('whip_core:bank:create', {
    ace = ACE, rateLimit = 500, burst = 3,
    params = {
        {'kind', 'enum', KINDS}, {'id', 'key', 64}, {'charId', 'id', 0}, {'label', 'string', 50, ''},
        {'accountType', 'enum', { 'personal', 'savings', 'shared', 'business' }, 'personal'},
        {'opening', 'int', 0, MAX_MONEY, 0}, {'reason', 'string', 120, ''},
    },
}, function(_, player, kind, id, charId, label, accountType, opening, reason)
    label, reason = trim(label), trim(reason)
    if opening > 0 and reason == '' then return false, 'Say why this account starts with money: it goes on its statement' end
    if label == '' then label = accountType == 'savings' and 'Savings Account' or accountType == 'shared' and 'Shared Account' or '' end

    local scope, why = scopeOf(kind, id, charId)
    if not scope then return false, why end

    local account
    if kind == 'player' then
        if accountType == 'business' then return false, 'A business account belongs to a business' end
        local owner
        for _, c in ipairs(scope.characters) do
            if c.charId == charId then owner = c end
        end
        if not owner then return false, 'Pick which of their characters holds it' end
        if owner.gone then return false, 'That character was deleted' end
        account, why = Bank.CreateAccount(owner.charId, label ~= '' and label or nil, accountType, false)

    elseif kind == 'business' then
        local job = Jobs.cache[scope.jobId]
        account, why = Bank.CreateAccount(job.ownerCharId, label ~= '' and label or ((job.name or 'Business') .. ' Account'), 'business', false, scope.jobId)
        if account then
            -- Staff reach a business's accounts through their rank.
            local staff = {}
            for staffId in pairs(Jobs.employees[scope.jobId] or {}) do staff[#staff + 1] = staffId end
            for _, staffId in ipairs(staff) do Jobs.syncEmployeeBankAccess(scope.jobId, staffId) end
        end

    elseif kind == 'lore' then
        local c = DirectorLore.get(id) --[[@as table]]   -- scopeOf found it, and lore characters are never removed
        if c.accountId and Bank.GetAccount(c.accountId) then return false, 'A lore character has one account, and this one has it' end
        local accountId
        accountId, why = DirectorLore.account(id)
        if accountId then account = Bank.GetAccount(accountId) end

    else
        if accountType == 'business' then return false, 'A business account belongs to a business' end
        account, why = Bank.CreateAccount(nil, label ~= '' and label or nil, accountType, false)
    end
    if not account then return false, why or 'The account could not be made' end

    logged(player, account, ('opened "%s" for %s'):format(account.label or '', scope.name), opening > 0 and opening or nil)

    if opening > 0 then
        local paid, payWhy = Bank.SystemDeposit(account.accountId, opening, 'Opening balance: ' .. reason, player.charId)
        if not paid then
            return { ok = true, accountId = account.accountId, note = 'The account is made, but its opening balance failed: ' .. tostring(payWhy) }
        end
    end
    return { ok = true, accountId = account.accountId }
end)

SecureCallback('whip_core:bank:change', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = {
        {'accountId', 'id'}, {'what', 'enum', { 'label', 'type', 'owner', 'frozen', 'main' }}, {'value', 'string', 60, ''},
    },
}, function(_, player, accountId, what, value)
    local a, why = accountById(accountId)
    if not a then return false, why end
    if a.closedAt then return false, 'That account is closed' end
    value = trim(value)

    local ok, note
    if what == 'label' then
        if loreOfAccount(accountId) then return false, 'Its name is the lore character\'s bank name: change it on the Lore page' end
        ok, why = Bank.SetLabel(accountId, value)
        if ok then logged(player, a, ('renamed "%s" to "%s"'):format(a.label or '', value)) end

    elseif what == 'type' then
        ok, why = Bank.SetType(accountId, value)
        if ok then logged(player, a, ('made "%s" a %s account'):format(a.label or '', value)) end

    elseif what == 'frozen' then
        local frozen = value == '1'
        ok, why = Bank.SetFrozen(accountId, frozen)
        if ok then logged(player, a, ('%s "%s"'):format(frozen and 'froze' or 'unfroze', a.label or '')) end

    elseif what == 'main' then
        ok, why = Bank.SetDefault(accountId)
        if ok then logged(player, a, ('made "%s" the main account'):format(a.label or '')) end

    else
        if a.jobId then return false, 'A business\'s account follows its owner: change the owner on the Jobs page' end
        if loreOfAccount(accountId) then return false, 'A lore character\'s account has no owner' end
        -- Their main account gone, the login would make them a new one, with the starting balance.
        if a.isDefault then return false, 'This is their main account: make another one their main first' end
        local newOwner = Sanitize.id(value)
        if not newOwner then return false, 'Who owns it now? Pick a character' end
        if newOwner == a.ownerCharId then return { ok = true } end
        local name, nameErr = read('scalar', "SELECT CONCAT(`firstName`, ' ', `lastName`) FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL", { newOwner })
        if nameErr then return false, nameErr end
        if not name then return false, 'No living character has that id' end
        ok, why = Bank.SetAccountOwner(accountId, newOwner)
        if ok then
            logged(player, a, ('gave "%s" to %s'):format(a.label or '', name))
            if a.ownerCharId then note = (a.ownerName or 'The old owner') .. ' keeps manager access until you take it away' end
        end
    end
    if not ok then return false, why or 'That could not be changed' end
    return { ok = true, note = note }
end)

SecureCallback('whip_core:bank:money', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = {
        {'accountId', 'id'}, {'way', 'enum', { 'add', 'take', 'move' }}, {'amount', 'amount', MAX_MONEY},
        {'reason', 'string', 120, ''}, {'to', 'string', 20, ''},
    },
}, function(_, player, accountId, way, amount, reason, to)
    reason = trim(reason)
    if reason == '' then return false, 'Say why: it goes on the statement' end
    local a, why = accountById(accountId)
    if not a then return false, why end
    if a.closedAt then return false, 'That account is closed' end
    local message = 'Admin: ' .. reason

    local ok
    if way == 'add' then
        ok, why = Bank.SystemDeposit(accountId, amount, message, player.charId)
        if ok then logged(player, a, ('added money to "%s": %s'):format(a.label or '', reason), amount) end
    elseif way == 'take' then
        ok, why = Bank.SystemWithdraw(accountId, amount, message, player.charId)
        if ok then logged(player, a, ('took money from "%s": %s'):format(a.label or '', reason), amount) end
    else
        local dest, destWhy = accountByNumber(to)
        if not dest then return false, destWhy end
        ok, why = Bank.SystemTransfer(accountId, dest.accountId, amount, message, player.charId)
        if ok then logged(player, a, ('moved money from "%s" to %s: %s'):format(a.label or '', dest.accountNumber, reason), amount) end
    end
    if not ok then return false, why or 'That could not be done' end
    return { ok = true }
end)

--- "Delete": the money goes where the admin says, then the account closes. Its statements stay.
SecureCallback('whip_core:bank:close', {
    ace = ACE, rateLimit = 500, burst = 3,
    params = {
        {'accountId', 'id'}, {'money', 'enum', { 'none', 'move', 'remove' }, 'none'},
        {'to', 'string', 20, ''}, {'reason', 'string', 120, ''},
    },
}, function(_, player, accountId, moneyGoes, to, reason)
    reason = trim(reason)
    local a, why = accountById(accountId)
    if not a then return false, why end
    if a.closedAt then return false, 'That account is already closed' end

    -- A living character keeps a main account: without one, the login makes a new one with the starting balance.
    if a.isDefault and a.ownerCharId and not a.ownerGone then
        return false, ('This is %s\'s main account: make another one their main first'):format(a.ownerName or 'their')
    end

    local moved = false
    if a.balance > 0 then
        if reason == '' then return false, 'Say why: it goes on the statement' end
        local message = 'Admin closed this account: ' .. reason
        local ok
        if moneyGoes == 'move' then
            local dest, destWhy = accountByNumber(to)
            if not dest then return false, destWhy end
            ok, why = Bank.SystemTransfer(accountId, dest.accountId, a.balance, message, player.charId)
        elseif moneyGoes == 'remove' then
            ok, why = Bank.SystemWithdraw(accountId, a.balance, message, player.charId)
        else
            return false, 'It still holds money: say where that goes'
        end
        if not ok then return false, why or 'Its money could not be moved' end
        moved = true
    end

    local closed
    closed, why = Bank.CloseAccount(accountId, a.isDefault)
    if not closed then
        if moved then logged(player, a, ('emptied "%s", but it did not close'):format(a.label or ''), a.balance) end
        return false, (moved and 'Its money has gone, but it did not close: ' or '') .. tostring(why or DB_ERROR)
    end
    logged(player, a, ('closed "%s"%s'):format(a.label or '', reason ~= '' and (': ' .. reason) or ''), moved and a.balance or nil)
    return { ok = true }
end)

--- Who may use an account, and how far. A business's follows each person's rank (Jobs), so it is not set here, and
--- the owner changes through `change`.
SecureCallback('whip_core:bank:access', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = {
        {'accountId', 'id'}, {'charId', 'id'}, {'role', 'enum', { 'view', 'deposit', 'withdraw', 'manager', 'none' }},
    },
}, function(_, player, accountId, charId, role)
    local a, why = accountById(accountId)
    if not a then return false, why end
    if a.closedAt then return false, 'That account is closed' end
    if a.jobId then return false, 'Staff reach a business\'s account through their rank: change it on the Jobs page' end

    local name, err = read('scalar', "SELECT CONCAT(`firstName`, ' ', `lastName`) FROM `characters` WHERE `charId` = ?", { charId })
    if err then return false, err end
    if not name then return false, 'No character has that id' end

    local ok
    if role == 'none' then
        ok, why = Bank.ForceRevokeAccess(accountId, charId)
        if not ok then return false, why or DB_ERROR end
        logged(player, a, ('took %s off "%s"'):format(name, a.label or ''))
    else
        if charId == a.ownerCharId then return false, 'That is the owner' end
        -- The same rule the money follows: left out here, the access would show and every payment be refused.
        ok, why = Bank.notOwnOther(a.ownerCharId, charId)
        if not ok then return false, why end
        ok = Bank.ForceSetAccess(accountId, charId, role)
        if not ok then return false, DB_ERROR end
        logged(player, a, ('gave %s %s access to "%s"'):format(name, role, a.label or ''))
    end
    WhipEmit('whip_core:bank:accountChanged', { accountId = accountId, what = 'access' })
    return { ok = true }
end)

-- ---- told, not polled ----
--
-- A balance or account changing reaches whoever has the page open, a few seconds' worth at once.

local changedIds, pushing = {}, false

local function noteChanged(ids)
    if next(DevTools.viewers.banks) == nil then return end
    for _, id in ipairs(ids) do changedIds[id] = true end
    if pushing then return end
    pushing = true
    SetTimeout(PUSH_EVERY_MS, function()
        pushing = false
        local list = {}
        for id in pairs(changedIds) do list[#list + 1] = id end
        changedIds = {}
        DevTools.eachViewer(DevTools.viewers.banks, function(src)
            TriggerClientEvent('whip_core:client:bankChanged', src, list)
        end)
    end)
end

AddEventHandler('whip_core:bank:balanceChanged', function(e)
    if type(e) ~= 'table' then return end
    local ids = {}
    for _, key in ipairs({ 'accountId', 'fromAccountId', 'toAccountId' }) do
        if e[key] then ids[#ids + 1] = e[key] end
    end
    noteChanged(ids)
end)

AddEventHandler('whip_core:bank:accountChanged', function(e)
    if type(e) == 'table' and e.accountId then noteChanged({ e.accountId }) end
end)

SecureEvent('whip_core:server:bankClosed', {   -- no ACE: leaving is never refused
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.banks[source] = nil
end)
