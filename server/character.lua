-- ============================================
-- Character CRUD — server/character.lua
-- ============================================

Character = {}

-- ============================================
-- Lifecycle — core's own reactions, then the event
-- ============================================
--
-- Core's bookkeeping is called, not heard (the rule Vehicles.onLife follows): `whip_core:character:*`
-- are local events any server resource can fire, so the place each step happens runs core's hooks
-- directly, then fires the event for everyone else; a fired copy changes nothing in whip_core.

local _lifeHooks = {}

--- Run `fn(payload)` whenever whip_core ITSELF announces `kind`:
---   'loaded'   { source, charId, name, newCharacter, player } — a character finished loading, just
---              before `whip_core:player:loaded`
---   'deleted'  { source, charId } — a character was deleted (the account's own delete)
---   'logout'   { source, charId, player, why } — a session ended; why = 'logout' | 'disconnect'
---   'died'     { source, charId, killer, reported } — they went down (MarkPlayerDead, events_misc.lua),
---              just before `whip_core:player:died`; killer = the server's own finding (a server id)
---   'revived'  { source, charId, how, reason } — up again (MarkPlayerAlive), just before
---              `whip_core:player:revived`; how = 'revived' | 'respawned'
--- For whip_core's own files. A satellite listens to `whip_core:player:loaded` /
--- `whip_core:character:deleted` / `whip_core:player:logout`.
---@param kind string
---@param fn fun(payload: table)
function Character.onLife(kind, fn)
    local list = _lifeHooks[kind]
    if not list then list = {}; _lifeHooks[kind] = list end
    list[#list + 1] = fn
end

--- Run core's hooks for `kind`, in the order they were added. The caller fires the public event
--- after (WhipEmit, which also carries the old event names). A hook that errors is reported and the
--- rest still run; a hook may wait on the database, and the next one runs after it.
---@param kind string
---@param payload table
function Character.runHooks(kind, payload)
    for _, fn in ipairs(_lifeHooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('[whip_core:character] a "%s" hook errored: %s'):format(kind, tostring(err))) end
    end
end

-- ============================================
-- After the first character loads
-- ============================================
--
-- whip makes its standing NPCs (shop keepers, the Director's standing things) once a character has
-- loaded: not when someone connects, as a player still in FiveM's menus is connected. Nobody is there to
-- see an NPC before then, so it costs nothing. (It began as a workaround: on FiveM for GTAV Enhanced in
-- Oct 2026, an entity the server made with nobody in the game had its network id handed out again to a
-- player's ped or car. Cfx has patched that, and cfx-server b177 no longer does it.)

local _firstLoaded = false
local _afterFirst = {}

--- Run `fn()` once a character has loaded since whip_core started: now if one has, else just after
--- the first load (in its own thread, so that player's load never waits on it).
---@param fn fun()
function Character.afterFirstLoad(fn)
    if _firstLoaded then fn() return end
    _afterFirst[#_afterFirst + 1] = fn
end

Character.onLife('loaded', function()
    if _firstLoaded then return end
    _firstLoaded = true
    local list = _afterFirst
    _afterFirst = {}
    CreateThread(function()
        for _, fn in ipairs(list) do
            local ok, err = pcall(fn)
            if not ok then print('[whip_core:character] something waiting on the first character errored: ' .. tostring(err)) end
        end
    end)
end)

--- Finish what a delete started, at every start.
---
--- A delete commits the soft-delete FIRST, then runs the 'deleted' hooks once: homes, keys, jobs,
--- stashes. A hook whose write failed would leave a deleted character holding them, so this asks which
--- deleted characters still hold any of those and runs the hooks again for them. The hooks are safe to repeat (each releases
--- only what is still there), so a character already released costs nothing. Housekeeping calls it,
--- after every loader has filled the caches the hooks read.
function Character.reconcileDeleted()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT c.`charId` FROM `characters` c
        WHERE c.`deleted` IS NOT NULL AND (
               EXISTS (SELECT 1 FROM `job_employees` e WHERE e.`charId` = c.`charId`)
            OR EXISTS (SELECT 1 FROM `jobs` j WHERE j.`ownerCharId` = c.`charId`)
            OR EXISTS (SELECT 1 FROM `properties` p WHERE p.`ownerCharId` = c.`charId`)
            OR EXISTS (SELECT 1 FROM `property_keys` k WHERE k.`charId` = c.`charId`)
            OR EXISTS (SELECT 1 FROM `containers` ct WHERE ct.`ownerCharId` = c.`charId` OR ct.`accessCharId` = c.`charId`)
        )
    ]])
    if not ok then
        print(('[whip_core:character] could not check deleted characters for leftovers: %s'):format(tostring(rows)))
        return
    end
    for _, row in ipairs(rows or {}) do
        print(('[whip_core:character] deleted character %d still held a job, home, key or stash — releasing it now')
            :format(row.charId))
        Character.runHooks('deleted', { charId = row.charId })
    end
end

--- A JSON column of the character row (`statuses`, `metadata`) as a table: `{}` when it is empty or not an object.
---
--- Type-checked, as Inventory.readMetadata is for item rows: the column's JSON check takes any JSON, so a hand edit
--- can leave `0` or `"note"` there. What cannot be read is dropped, and the console says so.
---@param raw any      the column as oxmysql gave it (a string, or already a table)
---@param what string  for the console ("charId 12 statuses")
---@return table
function Character.readJson(raw, what)
    if type(raw) == 'table' then return raw end
    if raw == nil or raw == '' then return {} end
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then return decoded end
    print(('[whip_core] %s is not readable (%s) — loaded as empty'):format(tostring(what), ok and type(decoded) or 'not JSON'))
    return {}
end

--- Get list of active characters for a user.
---
--- Includes each character's APPEARANCE, because the character select screen stands the
--- characters up in the world and they have to look like themselves. Appearance is not a
--- column — it lives inside the `metadata` JSON — so the row is read and the one key pulled
--- out here rather than shipping the whole metadata blob to the client, which may hold things
--- a player at the character screen has no business seeing.
---
--- Characters with no appearance yet (created but never through the creator) come back with
--- `appearance = nil`; the client falls back to a default look for their gender.
---
--- And where each may arrive (`spawns`, server/spawn_choices.lua) for the spawn picker, and `isDead`
--- (a dead character arrives where they fell: no picker). Not the raw position.
---@param userId number
---@return table[]
function Character.list(userId)
    -- Cash is counted from the inventory (`character_inventory`), not read from a column: cash is an
    -- item, and this screen choosing to show one particular item is a display decision.
    local rows = MySQL.query.await([[
        SELECT c.`charId`, c.`firstName`, c.`lastName`,
               DATE_FORMAT(c.`dateOfBirth`, '%Y-%m-%d') AS `dateOfBirth`, c.`gender`,
               c.`lastPlayed`, c.`metadata`, c.`x`, c.`y`, c.`z`, c.`heading`, c.`isDead`,
               COALESCE((SELECT SUM(i.`amount`) FROM `character_inventory` i
                          WHERE i.`charId` = c.`charId` AND i.`item` = 'cash'), 0) AS `cash`
          FROM `characters` c
         WHERE c.`userId` = ? AND c.`deleted` IS NULL
         ORDER BY c.`charId` ASC
    ]], {userId}) or {}

    for _, row in ipairs(rows) do
        local meta = row.metadata
        if type(meta) == 'string' then
            local ok, decoded = pcall(json.decode, meta)
            meta = ok and decoded or nil
        end
        row.appearance = (type(meta) == 'table') and meta.appearance or nil
        row.metadata = nil   -- do not ship the rest of it
        row.isDead = DbBool(row.isDead)
        row.spawns = SpawnChoices.list(row)
        row.x, row.y, row.z, row.heading = nil, nil, nil, nil
    end

    return rows
end

--- Load full character data by charId
---@param charId number
---@return table|nil
function Character.load(charId)
    local rows = MySQL.query.await(
        "SELECT *, DATE_FORMAT(`dateOfBirth`, '%Y-%m-%d') AS `dobText` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL LIMIT 1",
        {charId}
    )
    local row = rows and rows[1]
    if not row then return nil end
    -- The date of birth as the 'YYYY-MM-DD' text it was created from, which is what player.dateOfBirth
    -- is documented to be. oxmysql turns a DATE column into epoch milliseconds, so the raw column
    -- gave every satellite a number, and one that os.date cannot even read back for a birthday
    -- before 1970. Formatted by the database, so no time zone gets a vote.
    row.dateOfBirth, row.dobText = row.dobText, nil
    return row
end

--- Create a new character
---@param userId number
---@param firstName string
---@param lastName string
---@param dateOfBirth string  Format: YYYY-MM-DD
---@param gender string
---@return number|nil charId
---@return string|nil why
function Character.create(userId, firstName, lastName, dateOfBirth, gender)
    -- Check character limit. Read in a pcall: the read's await throws on a database error, and the create screen
    -- must get an answer.
    local listed, existing = pcall(Character.list, userId)
    if not listed then
        print(('[whip_core] creating a character for userId %s: the character list could not be read: %s')
            :format(tostring(userId), tostring(existing)))
        return nil, 'The server could not read your characters — try again in a moment'
    end
    if #existing >= Config.MaxCharacters then
        return nil, 'Character limit reached (' .. Config.MaxCharacters .. ')'
    end

    -- Validate inputs
    if not firstName or #firstName < 2 or #firstName > 30 then
        return nil, 'First name must be 2-30 characters'
    end
    if not lastName or #lastName < 2 or #lastName > 30 then
        return nil, 'Last name must be 2-30 characters'
    end
    if not dateOfBirth or not dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$') then
        return nil, 'Date of birth must be YYYY-MM-DD format'
    end
    -- A real date, not just the shape ('2024-13-45'). The date picker cannot make one; only a forged
    -- request can, but it gets a reason.
    do
        local y, m, d = dateOfBirth:match('^(%d+)%-(%d+)%-(%d+)$')
        y, m, d = tonumber(y), tonumber(m), tonumber(d)
        local daysIn = { 31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        if y < 1900 or y > 2100 or m < 1 or m > 12 or d < 1 or d > daysIn[m] then
            return nil, 'That date of birth is not a real date'
        end
    end

    if gender ~= 'male' and gender ~= 'female' then
        return nil, 'Gender must be male or female'
    end

    -- None stored: each stat starts at its own start value (Stats.initPlayer), so hunger and thirst start full.
    local defaultStatuses = '{}'

    -- No `cash` column: the banknotes below are the character's starting money and the only record of it.
    -- Guarded, so a DB error answers rather than throwing out of the caller.
    local insertOk, charId = pcall(MySQL.insert.await,
        'INSERT INTO `characters` (`userId`, `firstName`, `lastName`, `dateOfBirth`, `gender`, `statuses`, `metadata`) VALUES (?, ?, ?, ?, ?, ?, ?)',
        {userId, firstName, lastName, dateOfBirth, gender, defaultStatuses, '{}'}
    )

    if not insertOk or not charId then
        print(('[whip_core] ERROR creating character for userId %d: %s')
            :format(userId, tostring(charId)))
        return nil, 'Failed to create character in database'
    end

    -- Insert starting cash as inventory items
    if Config.DefaultCash > 0 then
        local cashOk, cashErr = pcall(MySQL.insert.await,
            'INSERT INTO `character_inventory` (`charId`, `container`, `slot`, `item`, `amount`, `metadata`) VALUES (?, ?, ?, ?, ?, ?)',
            { charId, 'player', 1, 'cash', Config.DefaultCash, '{}' }
        )
        if not cashOk then
            -- COMPENSATING ROLLBACK, not a warning. These two rows are one logical creation:
            -- the warned-and-kept version minted a permanent, playable character with empty
            -- pockets and nothing to ever reconcile it. Hard delete — the row is milliseconds
            -- old and owns nothing else yet.
            local rolledBack, rbErr = pcall(MySQL.query.await, 'DELETE FROM `characters` WHERE `charId` = ?', { charId })
            print(('[whip_core] ERROR: starting cash failed for charId %d — creation rolled back: %s')
                :format(charId, tostring(cashErr)))
            if not rolledBack then
                -- Said, not swallowed: the row is left, a character with empty
                -- pockets that will show on the player's list. The admin can delete it.
                print(('[whip_core] ERROR: and the rollback failed too — charId %d is left with no starting cash: %s')
                    :format(charId, tostring(rbErr)))
            end
            return nil, 'Failed to create character in database'
        end
        -- Money entering the game, like any other (Log.gained in activity_log.lua).
        Log.gained(charId, 'cash', Config.DefaultCash, 'starting cash for a new character')
    end

    return charId
end

--- A character's names as whip keeps them: letters, spaces and hyphens only, spaces collapsed and trimmed, at least
--- two letters and at most 30 characters each. The one rule for a new character (player_lifecycle.lua) and a rename.
---@param firstName any
---@param lastName any
---@return string|nil firstName, string|nil lastName, string|nil why
function Character.cleanNames(firstName, lastName)
    local function clean(s)
        if type(s) ~= 'string' then return '' end
        s = s:gsub('[^%a%s%-]', ''):gsub('%s+', ' ')
        return s:match('^%s*(.-)%s*$')
    end
    local first, last = clean(firstName), clean(lastName)
    if #first:gsub('[^%a]', '') < 2 or #last:gsub('[^%a]', '') < 2 then
        return nil, nil, 'Names need at least two letters each.'
    end
    if #first > 30 or #last > 30 then return nil, nil, 'Names are 30 characters at most.' end
    return first, last
end

--- Change a character's name. THE NAME ONLY: the charId, and everything kept by it (their money, inventory, cars,
--- property, phone number, bank accounts, jobs, notes, history), stays exactly as it is. whip identifies a character
--- by charId everywhere, never by name; a name is only ever shown. (Josh, 1 Nov: names changeable in the admin panel.)
---
--- Online, the change is live: their sheet's names (player.firstName / lastName / fullName), their own game's copy
--- (PlayerData), and `whip_core:character:renamed` for anything that keeps a name to show (server and their client).
---@param charId number
---@param firstName string
---@param lastName string
---@param by string|nil  who renamed them, for the activity log
---@return boolean ok, string fullNameOrWhy, string|nil oldName
function Character.rename(charId, firstName, lastName, by)
    local id = tonumber(charId)
    if not id then return false, 'No such character' end
    charId = id
    local first, last, why = Character.cleanNames(firstName, lastName)
    if not first or not last then return false, why --[[@as string]] end

    local okRead, rows = pcall(MySQL.query.await,
        'SELECT `firstName`, `lastName` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL LIMIT 1', { charId })
    if not okRead then return false, 'The character could not be read. Check the server console.' end
    local row = rows and rows[1]
    if not row then return false, 'No such character' end
    local oldName = ('%s %s'):format(row.firstName or '', row.lastName or '')
    local fullName = first .. ' ' .. last
    if row.firstName == first and row.lastName == last then return true, fullName, oldName end

    local ok, affected = pcall(MySQL.update.await,
        'UPDATE `characters` SET `firstName` = ?, `lastName` = ? WHERE `charId` = ? AND `deleted` IS NULL',
        { first, last, charId })
    if not ok or not affected or affected < 1 then
        print(('[whip_core] renaming charId %d failed: %s'):format(charId, tostring(affected)))
        return false, 'The name did not save. Check the server console.'
    end

    -- Live, when they are in: the sheet every satellite reads, and their own game's copy.
    local p = PlayersByCharId[charId]
    if p then
        p.firstName, p.lastName, p.fullName = first, last, fullName
        TriggerClientEvent('whip_core:client:nameChanged', p.source, first, last)
    end

    Log.write(charId, 'renamed', { detail = ('%s -> %s%s'):format(oldName, fullName, by and (' (by ' .. by .. ')') or '') })
    print(('[whip_core] charId %d renamed: %s -> %s%s'):format(charId, oldName, fullName, by and (' by ' .. by) or ''))
    -- For anything that keeps a name to show. charId is the key. whip_core's own caches first, on its own hook (helpers.lua,
    -- dev_ground.lua: Character.onLife('renamed')), then the news for everyone else (whip_phone's people): an invariant
    -- of whip_core's never rides a public event any resource may fire (audit 20, ARC-5).
    local renamed = {
        charId = charId, source = p and p.source or nil, firstName = first, lastName = last, name = fullName,
        oldName = oldName, by = by,
    }
    Character.runHooks('renamed', renamed)
    WhipEmit('whip_core:character:renamed', renamed)
    return true, fullName, oldName
end

--- Soft delete a character
---@param charId number
---@param userId number  For ownership validation
---@return boolean success
---@return string|nil error
function Character.delete(charId, userId)
    -- Under pcall: oxmysql's await throws on a query error, and the caller holds the character marked
    -- 'deleting' across this call; a throw would leave the mark set. Answered as a failure instead.
    local ok, affected = pcall(MySQL.update.await,
        'UPDATE `characters` SET `deleted` = CURRENT_TIMESTAMP WHERE `charId` = ? AND `userId` = ? AND `deleted` IS NULL',
        {charId, userId}
    )
    if not ok or type(affected) ~= 'number' then
        print(('[whip_core] ERROR: deleting charId %s failed: %s'):format(tostring(charId), tostring(affected)))
        return false, DB_ERROR
    end
    if affected == 0 then
        return false, 'Character not found or already deleted'
    end
    return true
end

--- Is this character one of the account's own, and not deleted? What the character screen's pick and
--- delete ask of the charId the client names.
---
--- By charId, checked, rather than by list position (a second session of the same account can move
--- every index): a client cannot name a character that is not its own.
---@param userId number
---@param charId number
---@return boolean
function Character.isOwnLive(userId, charId)
    local ok, row = pcall(MySQL.single.await,
        'SELECT `charId` FROM `characters` WHERE `charId` = ? AND `userId` = ? AND `deleted` IS NULL',
        { charId, userId })
    return ok and row ~= nil
end

--- Is this character gone — deleted, or never there? The check a satellite makes before it acts on
--- `whip_core:character:deleted`, which any server resource can fire (never raw SQL against whip's
--- own table).
---
---     local gone = exports.whip_core:IsCharacterDeleted(e.charId)
---     if not gone then return end   -- a fired copy, or a read that failed: remove nothing
---
--- `true, 'deleted'` / `true, 'no such character'`; `false` for a live one — and `false, why` when it
--- cannot be told (a bad id, the database not answering), so a doubt never removes anything.
---@param charId number
---@return boolean gone
---@return string|nil why
exports('IsCharacterDeleted', function(charId)
    local id = Sanitize.id(charId)
    if not id then return false, 'a character is named by its charId' end
    charId = id
    if PlayersByCharId and PlayersByCharId[charId] then return false end   -- playing right now
    local ok, row = pcall(MySQL.single.await,
        'SELECT `deleted` FROM `characters` WHERE `charId` = ? LIMIT 1', { charId })
    if not ok then return false, 'could not read the character' end
    if not row then return true, 'no such character' end
    if row.deleted ~= nil then return true, 'deleted' end
    return false
end)

exports('RenameCharacter', function(who, firstName, lastName)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    return Character.rename(charId, firstName, lastName, GetInvokingResource() or GetCurrentResourceName())
end)
