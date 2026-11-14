-- ============================================
-- GIVE ON LOGIN — an item for a character who is not playing (GiveOnLogin)
-- ============================================
--
-- AddItem reaches a player who is on. For one who is not (a reward for an offline winner, a refund owed, a rope taken
-- back while they were away), GiveOnLogin keeps the give in `pending_gives`, in the database, and hands it over at
-- their next login, into their pockets (at their feet when full: never lost), logged like any give. A character who is
-- playing gets it at once. A character deleted meanwhile takes theirs with it.

PendingGives = {}

---@return boolean ok
function PendingGives.ensureTable()
    return CreateTable('pending_gives', [[
        CREATE TABLE IF NOT EXISTS `pending_gives` (
            `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `charId`    INT UNSIGNED NOT NULL,
            `item`      VARCHAR(50)  NOT NULL,
            `amount`    INT UNSIGNED NOT NULL,
            `metadata`  JSON         DEFAULT NULL,
            `reason`    VARCHAR(120) DEFAULT NULL,
            `owner`     VARCHAR(64)  NOT NULL,
            `createdAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_pending_gives_char` (`charId`),
            CONSTRAINT `fk_pending_gives_char` FOREIGN KEY (`charId`) REFERENCES `characters` (`charId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- What a give says in the item log: its reason, and who gave it while they were away.
local function reasonOf(reason, owner)
    reason = type(reason) == 'string' and reason ~= '' and reason or 'a give'
    return ('%s (from %s, while away)'):format(reason, tostring(owner))
end

--- An item for a person, now if they are playing, else at their next login. `who`: a server id or { charId = n }.
--- `opts` is a reason or { reason }, as AddItem's. Returns 'now' or 'login', or false and why.
exports('GiveOnLogin', function(who, item, amount, metadata, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    if type(item) ~= 'string' or Config.Items[item] == nil then return false, ('Unknown item "%s"'):format(tostring(item)) end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    if metadata ~= nil then
        if type(metadata) ~= 'table' then return false, 'metadata must be a table or nil' end
        local okData, what = Inventory.saveableData(metadata)
        if not okData then return false, ('metadata cannot be saved: %s'):format(what) end
    end
    local reason = type(opts) == 'table' and opts.reason or opts
    reason = type(reason) == 'string' and reason:sub(1, 120) or nil

    -- Playing now: given now, as AddItem would.
    local online = PlayersByCharId[charId]
    if online and online.source and Players[online.source] == online then
        local placement, err = Inventory.give(online.source, item, amount, metadata, { reason = reason or ('from ' .. owner) })
        if not placement then return false, err end
        return 'now'
    end

    local ok, err = pcall(MySQL.insert.await,
        'INSERT INTO `pending_gives` (`charId`, `item`, `amount`, `metadata`, `reason`, `owner`) VALUES (?, ?, ?, ?, ?, ?)',
        { charId, item, amount, metadata and json.encode(metadata) or nil, reason, owner })
    if not ok then
        print(('[whip_core:pending] GiveOnLogin for charId %s could not be saved: %s'):format(tostring(charId), tostring(err)))
        return false, DB_ERROR
    end
    return 'login'
end)

-- A character coming on: what was kept for them, handed over now, each removed once it is given.
Character.onLife('loaded', function(e)
    local src = e and e.source
    local player = src and Players[src]
    if not player or not player.charId then return end
    local okRead, rows = pcall(MySQL.query.await,
        'SELECT `id`, `item`, `amount`, `metadata`, `reason`, `owner` FROM `pending_gives` WHERE `charId` = ? ORDER BY `id`',
        { player.charId })
    if not okRead then
        print(('[whip_core:pending] could not read the gives kept for charId %s: %s'):format(tostring(player.charId), tostring(rows)))
        return
    end
    for _, row in ipairs(rows or {}) do
        if Players[src] ~= player then return end   -- gone again meanwhile: the rest wait for the next login
        local meta = nil
        if type(row.metadata) == 'string' and row.metadata ~= '' then
            local okJson, decoded = pcall(json.decode, row.metadata)
            meta = okJson and type(decoded) == 'table' and decoded or nil
        end
        local placement, why = Inventory.give(src, row.item, tonumber(row.amount) or 1, meta,
            { reason = reasonOf(row.reason, row.owner) })
        if placement then
            local okDel, delErr = pcall(MySQL.query.await, 'DELETE FROM `pending_gives` WHERE `id` = ?', { row.id })
            if not okDel then
                print(('[whip_core:pending] gave %s x%s to charId %s but could not clear it: %s')
                    :format(row.item, tostring(row.amount), tostring(player.charId), tostring(delErr)))
            end
        else
            print(('[whip_core:pending] could not give %s x%s to charId %s (kept for next time): %s')
                :format(tostring(row.item), tostring(row.amount), tostring(player.charId), tostring(why)))
        end
    end
end)
