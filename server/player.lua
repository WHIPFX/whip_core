-- ============================================
-- WhipPlayer — Server-side player metatable class
-- ============================================

-- The public fields and methods are declared in types/classes.lua; these are the ones whip_core keeps
-- to itself.
---@class WhipPlayer
---@field session number|nil            this character load's number (IsSessionCurrent); nil on a load-test phantom
---@field inventory WhipInventoryCache|nil the pockets; set before the player is in Players (a phantom has none)
---@field accountNumber string|nil       the default bank account's number, cached at the load
---@field phantom boolean|nil            a load-test stand-in (__TestPhantoms): nothing about it is saved
---@field closing boolean|nil            logging out or dropped: the session's events are refused from here on
---@field dropped boolean|nil            disconnected
---@field _inCreator boolean|nil         in the character creator, until creatorDone
---@field placed boolean|nil            the ped has arrived where the character was sent (getCoords)
---@field loadedAt number|nil           GetGameTimer() at the load (or the creator's end); nil on a phantom
---@field diedAt number|nil              GetGameTimer() at the death, while dead
---@field lifeGen number|nil             counts revivals, so a death timer can tell its life from the next
---@field _haveItemDefs boolean|nil      the client already has the item definitions
---@field _inventoryLocked boolean|nil   an admin is viewing this inventory
---@field _metadataDirty number|boolean|nil metadata changed since the last row write (the row's ticket)
---@field _clampSaid table<string, boolean>|nil columns already said to be out of range
---@field _rowBuildSaid boolean|nil      a row that could not be built was already said
---@field _finalRow table|nil            the teardown's last row, owed until written (PlayerRows.freeze)
---@field _finalPos table|nil            the teardown's last position, owed until written
---@field watchPlacement fun(self: WhipPlayer)
---@field handlerSheet fun(self: WhipPlayer): table
---@field lightSheet fun(self: WhipPlayer): table

WhipPlayer = {}
WhipPlayer.__index = WhipPlayer

-- ============================================
-- Database — Table Creation (first-time setup)
-- ============================================

--- Ensure core identity tables exist (users + characters).
--- Called on resource start so the DB bootstraps automatically.
---@return boolean ok
function WhipPlayer.ensureTable()
    local okUsers = CreateTable('users', [[
        CREATE TABLE IF NOT EXISTS `users` (
            `userId`    INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `license`   VARCHAR(60)  NOT NULL,
            `steam`     VARCHAR(25)  DEFAULT NULL,
            `discord`   VARCHAR(25)  DEFAULT NULL,
            `fivem`     VARCHAR(15)  DEFAULT NULL,
            `name`      VARCHAR(50)  DEFAULT NULL,
            `createdAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `lastSeen`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`userId`),
            UNIQUE KEY `uk_license` (`license`),
            -- Identity falls back to fivem, then discord, when a license lookup misses (a Rockstar
            -- account change rotates the license): indexed so those lookups are not table scans.
            KEY `idx_users_fivem` (`fivem`),
            KEY `idx_users_discord` (`discord`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    local okChars = CreateTable('characters', [[
        CREATE TABLE IF NOT EXISTS `characters` (
            `charId`      INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `userId`      INT UNSIGNED NOT NULL,
            `firstName`   VARCHAR(30)  NOT NULL,
            `lastName`    VARCHAR(30)  NOT NULL,
            `dateOfBirth` DATE         NOT NULL,
            `gender`      ENUM('male','female') NOT NULL DEFAULT 'male',
            -- NO `cash` COLUMN. Cash is an item in `character_inventory`.
            `x`           FLOAT        DEFAULT NULL,
            `y`           FLOAT        DEFAULT NULL,
            `z`           FLOAT        DEFAULT NULL,
            `heading`     FLOAT        DEFAULT NULL,
            `health`      SMALLINT     NOT NULL DEFAULT 200,
            `armour`      TINYINT      NOT NULL DEFAULT 0,
            `isDead`      TINYINT(1)   NOT NULL DEFAULT 0,
            `statuses`    JSON         DEFAULT NULL,
            `metadata`    JSON         DEFAULT NULL,
            `lastPlayed`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            `createdAt`   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `deleted`     TIMESTAMP    NULL DEFAULT NULL,
            PRIMARY KEY (`charId`),
            KEY `idx_userId` (`userId`),
            KEY `idx_deleted` (`deleted`),
            CONSTRAINT `fk_characters_userId` FOREIGN KEY (`userId`)
                REFERENCES `users` (`userId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    return okUsers and okChars
end

--- Active player cache (keyed by source)
---@type table<number, WhipPlayer>
Players = {}

--- Reverse-index tables for O(1) lookups by charId/userId
---@type table<number, WhipPlayer>
PlayersByCharId = {}
---@type table<number, WhipPlayer>
PlayersByUserId = {}

--- Pending players who connected but haven't selected a character yet
---@type table<number, table>
PendingPlayers = {}

--- Every character load gets its own number. A handler that waits (a DB await, a Wait) can ask
--- afterwards whether the player it started with is still the one on that source: the same source
--- can be a different character after a logout.
---
--- Starts from the clock, not 0, so a number is never reused across a whip_core restart (and stays
--- well inside what a double holds exactly).
local _sessionSeq = os.time() * 1000

--- Create a new WhipPlayer instance from DB data
---@param source number
---@param userData table  Row from users table + identifiers
---@param charData table  Row from characters table
---@return WhipPlayer
function WhipPlayer.new(source, userData, charData)
    local self = setmetatable({}, WhipPlayer)

    _sessionSeq = _sessionSeq + 1
    self.session = _sessionSeq

    -- Connection info
    self.source    = source
    self.userId    = userData.userId
    self.license   = userData.license
    self.steam     = userData.steam
    self.discord   = userData.discord
    self.fivem     = userData.fivem

    -- Character data
    self.charId      = charData.charId
    self.firstName   = charData.firstName
    self.lastName    = charData.lastName
    self.fullName    = charData.firstName .. ' ' .. charData.lastName
    self.dateOfBirth = charData.dateOfBirth
    self.gender      = charData.gender
    -- No cash field: cash is an item in `character_inventory`, and `getCash()` counts it (0 before the
    -- inventory loads).

    -- Position
    local x = charData.x or Config.DefaultSpawn.x
    local y = charData.y or Config.DefaultSpawn.y
    local z = charData.z or Config.DefaultSpawn.z
    local h = charData.heading or Config.DefaultSpawn.w
    self.position = vector4(x, y, z, h)
    -- Not in the world yet: the ped is still on the character screen. See getCoords.
    self.placed   = false
    self.loadedAt = GetGameTimer()

    -- Health/Armour (initial values — Stats system becomes authoritative after init)
    self.health = charData.health or 200
    self.armour = charData.armour or 0
    -- DbBool, not `== 1`: oxmysql's query path hands TINYINT(1) back as a boolean.
    self.isDead = DbBool(charData.isDead)
    -- A character loaded dead needs a moment of death for playerRespawned to accept: the load is
    -- the moment the death clock starts.
    self.diedAt = self.isDead and GetGameTimer() or nil

    -- Metadata (JSON from DB or empty table), type-checked: a non-object would make every later read throw.
    self.metadata = Character.readJson(charData.metadata, ('charId %s metadata'):format(tostring(charData.charId)))

    return self
end

-- Cash methods (getCash, addCash, removeCash): see server/items/cash.lua

-- ============================================
-- Metadata Methods
-- ============================================

---@param key string
---@return any
function WhipPlayer:getMetadata(key)
    if key then
        return self.metadata[key]
    end
    return self.metadata
end

---@param key string
---@param value any
---@return boolean ok
---@return string|nil err
function WhipPlayer:setMetadata(key, value)
    -- Only what can be saved: metadata is written as JSON, so a value JSON can't hold (a vector3, a
    -- function, NaN) is refused here, with the reason.
    if value ~= nil then
        local encodable = pcall(json.encode, { v = value })
        if not encodable then
            return false, ('metadata "%s" cannot be saved (not JSON-encodable — store plain numbers, strings and tables)')
                :format(tostring(key))
        end
    end

    self.metadata[key] = value

    -- The only way metadata reaches the database: nothing sweeps it, so assigning to `player.metadata`
    -- directly survives only until the next restart. The flag makes the row carry metadata (the
    -- appearance and all) only when it changed; it holds the row's ticket (PlayerRows.markDirty), so a
    -- write clears it only if no newer change came while it was out.
    PlayerRows.markDirty(self.source)
    self._metadataDirty = (self.source and PlayerRows._dirty[self.source]) or true

    -- And to the player's own client (the client's GetPlayer), which had the whole table at login anyway. Only
    -- for a player in the world under this object (an offline character's sheet has no client).
    if Players[self.source] == self then
        TriggerClientEvent('whip_core:client:metadataChanged', self.source, key, value)
    end
    return true
end

-- ============================================
-- Position / Coords
-- ============================================

--- How close the ped must come to where the character was sent before it counts as placed, and how
--- long after the load it counts anyway (a spawn that put them somewhere else; never in the creator).
local PLACED_RANGE    = 15.0
local PLACED_AFTER_MS = 60000

--- Where the character is: the ped, once the character is in the world — and until then the
--- position it was loaded with.
---
--- Not the ped before it has been put there: at the load it is still posed on the character screen,
--- and that spot must not become the saved position. The ped becomes the answer once it has arrived
--- within PLACED_RANGE of where the character was sent (the saved spot, or the spawn point after the
--- creator), or PLACED_AFTER_MS after the load outside the creator, whichever is first.
---@return vector4
function WhipPlayer:getCoords()
    local ped = GetPlayerPed(self.source)
    if ped and ped ~= 0 then
        local coords = GetEntityCoords(ped)
        -- Only update if coords are valid (not 0,0,0 which means ped doesn't exist or hasn't loaded)
        if coords.x ~= 0.0 or coords.y ~= 0.0 or coords.z ~= 0.0 then
            if not self.placed then
                local p = self.position
                local dx, dy, dz = coords.x - p.x, coords.y - p.y, coords.z - p.z
                if dx * dx + dy * dy + dz * dz <= PLACED_RANGE * PLACED_RANGE
                    or (not self._inCreator and GetGameTimer() - (self.loadedAt or 0) > PLACED_AFTER_MS) then
                    self.placed = true
                end
            end
            if self.placed then
                self.position = vector4(coords.x, coords.y, coords.z, GetEntityHeading(ped))
            end
        end
    end
    -- Falls back to self.position (last known good position from DB or previous update)
    return self.position
end

-- ---- watching for the arrival ----
--
-- `placed` flips only when something READS the coords while the ped is near the spot, so a player
-- who is not placed yet is looked at once a second until they are (or they drive off unseen): from
-- the load (and again from the creator's end, which restarts the clock), for at most PLACE_WATCH_MS.
local PLACE_WATCH_MS = 120000
local _unplaced, _placeWatching = {}, false

--- Look at this player's ped every second until it has arrived (or the watch runs out).
function WhipPlayer:watchPlacement()
    if self.placed then return end
    _unplaced[self] = GetGameTimer()
    if _placeWatching then return end
    _placeWatching = true
    CreateThread(function()
        while next(_unplaced) ~= nil do
            Wait(1000)
            local now = GetGameTimer()
            for p, since in pairs(_unplaced) do
                if p.placed or p.closing or p.dropped or now - since > PLACE_WATCH_MS then
                    _unplaced[p] = nil
                else
                    p:getCoords()
                    if p.placed then _unplaced[p] = nil end
                end
            end
        end
        _placeWatching = false
    end)
end

-- ============================================
-- Character row — write-behind
-- ============================================
--
-- The character row and position save with the pockets: they are part of the player's save unit,
-- `player:<charId>` (stores.lua, the 'player' kind's persist), one transaction, one writer of a
-- character's rows. A teardown write that fails is a unit still owed, which a relog waits for.

--- Its own namespace, not a field on `Players`: every `for _, player in pairs(Players)` assumes each
--- value is a WhipPlayer.
PlayerRows = {}

--- Players whose character row has changed since the last flush. [source] = ticket
---
--- Keyed by SOURCE, not charId: the row is rebuilt from live state at flush time, which needs the
--- handle. A player who disconnects between mark and flush is flushed by their teardown first.
PlayerRows._dirty = {}

--- Position is tracked separately, the way vehicle positions are (Vehicles._lastPos / _dirtyPos /
--- markPosition / flushPositions): it changes every frame anyone walks, so it can't share the row's
--- flag.
---   * `_lastPos` is what is ACTUALLY ON DISK; the movement test compares against that, so a walk in
---     a circle is not written at all.
---   * A sweep marks only players who have moved more than an epsilon, so standing still is free.
---   * A failure keeps the mark rather than losing it.
PlayerRows._lastPos  = {}   -- [source] = { x, y, z, heading }  as last committed
PlayerRows._dirtyPos = {}   -- [source] = { x, y, z, heading }  pending

PlayerRows._seq = 0   -- the last mark's ticket (markDirty)

--- This player's character row needs writing; the next save of their unit carries it.
---
--- Two assignments and nothing else: Stats.set calls this on every hunger, thirst and health tick,
--- for every player (stores.lua marks the unit before each save, Stores.beforeFlush below). The
--- number is a ticket: a write clears the mark only if no newer one came while it was out.
---
--- Who calls this: Stats.set (health and armour; a persisted need or custom stat goes through markSoon, below)
--- and setMetadata.
---   * `isDead` is covered TRANSITIVELY: every site that changes it moves health through Stats.set in
---     the same breath. A future site that changes isDead WITHOUT touching health must mark by hand.
---   * `x/y/z/heading` is not a trigger: the position sweep below marks whoever has moved.
---@param source number
function PlayerRows.markDirty(source)
    if not source then return end
    PlayerRows._seq = PlayerRows._seq + 1
    PlayerRows._dirty[source] = PlayerRows._seq
end

PlayerRows._soon = {}   -- [source] = true

--- This player's row needs writing, but not this second: a need or a custom stat (hunger and thirst each drop every
--- ten seconds, which made the row a write every five for every player). Marked for real by the next position sweep
--- (below, every PlayerPositionSaveInterval), so it goes out with the position. Health, armour and death still mark
--- at once (markDirty); a logout, a restart and the final save mark everyone anyway.
---@param source number
function PlayerRows.markSoon(source)
    if source then PlayerRows._soon[source] = true end
end

--- Clamped to what the column holds (`health` SMALLINT, `armour` TINYINT, the CREATE TABLE above):
--- past it the whole write would fail under strict mode, the player's pockets with it. Said once.
local function clampColumn(player, name, value, max)
    local v = tonumber(value) or 0
    if v >= 0 and v <= max then return v end
    player._clampSaid = player._clampSaid or {}
    if not player._clampSaid[name] then
        player._clampSaid[name] = true
        print(('[whip_core] %s of %s is %s, past what its column holds (0-%d) — saved as %d')
            :format(name, tostring(player.fullName), tostring(v), max, math.max(0, math.min(max, v))))
    end
    return math.max(0, math.min(max, v))
end

--- The row's UPDATE from live state. Metadata only when asked: it carries the appearance, so it is not
--- encoded on every vitals tick. Raises on a value json cannot encode.
local function buildRow(player, withMeta)
    local saveData = Stats.getForSave(player.source)
    local health = clampColumn(player, 'health', saveData.health, 32767)
    local armour = clampColumn(player, 'armour', saveData.armour, 127)
    local q
    if withMeta then
        q = {
            query = 'UPDATE `characters` SET `health`=?, `armour`=?, `isDead`=?, `statuses`=?,'
                .. ' `metadata`=?, `lastPlayed`=CURRENT_TIMESTAMP WHERE `charId`=?',
            values = { health, armour, player.isDead and 1 or 0, json.encode(saveData.statuses),
                       json.encode(player.metadata), player.charId },
        }
    else
        q = {
            query = 'UPDATE `characters` SET `health`=?, `armour`=?, `isDead`=?, `statuses`=?,'
                .. ' `lastPlayed`=CURRENT_TIMESTAMP WHERE `charId`=?',
            values = { health, armour, player.isDead and 1 or 0, json.encode(saveData.statuses), player.charId },
        }
    end
    player.health = saveData.health
    player.armour = saveData.armour
    return q
end

local function positionQuery(pos, charId)
    return {
        query  = 'UPDATE `characters` SET `x`=?,`y`=?,`z`=?,`heading`=? WHERE `charId`=?',
        values = { pos.x, pos.y, pos.z, pos.heading, charId },
    }
end

--- What this character's row owes, for their unit's save: the row and the position, and a confirm
--- that clears only what this write carried. A session still in the game builds from live state; one
--- being torn down writes what PlayerRows.freeze captured (its stats are gone, and its source may be
--- someone else's, by the time a failed write is retried).
---@param player table
---@return table[] queries
---@return function|nil confirm
function PlayerRows.pending(player)
    local queries, done = {}, {}
    if not player or player.phantom or not player.charId then return queries end
    local source = player.source
    local live = Players[source] == player

    if player._finalRow then
        local q = player._finalRow
        queries[#queries + 1] = q
        done[#done + 1] = function() if player._finalRow == q then player._finalRow = nil end end
    elseif live and PlayerRows._dirty[source] then
        local ticket, metaTicket = PlayerRows._dirty[source], player._metadataDirty
        local built, q = pcall(buildRow, player, metaTicket ~= nil)
        if built then
            player._rowBuildSaid = nil
            queries[#queries + 1] = q
            done[#done + 1] = function()
                if PlayerRows._dirty[source] == ticket then PlayerRows._dirty[source] = nil end
                if metaTicket ~= nil and player._metadataDirty == metaTicket then player._metadataDirty = nil end
            end
        elseif not player._rowBuildSaid then
            -- json.encode throws on a vector3, a function, NaN in metadata. Kept owed; the pockets save.
            player._rowBuildSaid = true
            print(('[whip_core] character row for %s [%d] could not be built — kept owed: %s')
                :format(tostring(player.fullName), source, tostring(q)))
        end
    end

    if player._finalPos then
        local q = player._finalPos
        queries[#queries + 1] = q
        done[#done + 1] = function() if player._finalPos == q then player._finalPos = nil end end
    elseif live then
        -- `charId` rides with a mark: another character on this source is not the one who stood there.
        local pos = PlayerRows._dirtyPos[source]
        if pos and (pos.charId == nil or pos.charId == player.charId) then
            queries[#queries + 1] = positionQuery(pos, player.charId)
            done[#done + 1] = function()
                if PlayerRows._dirtyPos[source] == pos then PlayerRows._dirtyPos[source] = nil end
                PlayerRows._lastPos[source] = pos   -- what is on disk now; the sweep measures from it
            end
        end
    end

    if #done == 0 then return queries end
    return queries, function() for _, f in ipairs(done) do f() end end
end

--- A teardown's last row (metadata included) and position, captured now and written by the unit's
--- next save — owed until it lands, so a relog waits for it. The live marks go with it; a logout
--- listener that changes the character afterwards marks it again (PlayerRows.saveIfChanged).
---@param player table
function PlayerRows.freeze(player)
    if player.phantom or not player.charId then return end
    local built, q = pcall(buildRow, player, true)
    if built then
        player._finalRow = q
        PlayerRows._dirty[player.source] = nil
        player._metadataDirty = nil
    else
        print(('[whip_core] last character row of %s [%d] could not be built — not saved: %s')
            :format(tostring(player.fullName), player.source, tostring(q)))
    end
    local ok, c = pcall(function() return player:getCoords() end)
    if ok and c then
        player._finalPos = positionQuery({ x = c.x, y = c.y, z = c.z, heading = c.w }, player.charId)
        PlayerRows._dirtyPos[player.source] = nil
    end
end

--- Logout listeners may still change the character (metadata, a custom stat) after the last save;
--- write it if they did. Called after whip_core:player:logout, before the stats are cleaned up.
---@param player table
---@return boolean ok
function PlayerRows.saveIfChanged(player)
    if not player or player.phantom then return true end
    if not PlayerRows._dirty[player.source] and not player._metadataDirty then return true end
    -- The teardown save's row, not its seat: the seat they left was noted by the first save, and the logout hooks
    -- have let it go since, so noting it again wrote "no seat" over it (audit 20, PLY-3)
    return player:save(true, true)
end

--- Save, now, the units of the players marked in `set` (rows or positions), or just `onlySource`.
local function flushMarked(set, onlySource)
    local sources = {}
    for source in pairs(set) do
        if not onlySource or source == onlySource then sources[#sources + 1] = source end
    end
    local ok = true
    for _, source in ipairs(sources) do
        local player = Players[source]
        local store = player and not player.phantom and Stores.player(source, 'player')
        if store then
            Stores.markDirty(store)
            if not Stores.flushNow(store) then ok = false end
        end
    end
    return ok
end

--- Write marked character rows now, each with its pockets and position (one transaction per player).
--- For callers that need it on disk (whip_test's flush seam); the save thread does this by itself.
---@param onlySource number|nil
---@return boolean ok
function PlayerRows.flush(onlySource)
    -- The rows owed with the next sweep too (PlayerRows.markSoon): a caller that needs it on disk needs all of it
    for source in pairs(PlayerRows._soon) do
        if onlySource == nil or source == onlySource then
            PlayerRows._soon[source] = nil
            PlayerRows.markDirty(source)
        end
    end
    return flushMarked(PlayerRows._dirty, onlySource)
end

--- Take this player's current position for the next flush.
---
--- Synchronous and database-free, exactly like Vehicles.markPosition, so a teardown path can call
--- it without yielding while it is halfway through dropping the session.
---@param source number
function PlayerRows.markPosition(source)
    local player = Players[source]
    if not player or player.phantom then return end

    local ok, coords = pcall(function() return player:getCoords() end)
    if not ok or not coords then return end

    -- `charId` rides with it: the queue is keyed by SOURCE, and a source can be a different character
    -- by the time the position is written.
    PlayerRows._dirtyPos[source] = {
        x = coords.x, y = coords.y, z = coords.z, heading = coords.w, charId = player.charId,
    }
end

--- Drop everything held for this source: the dirty mark, the pending position and the last written
--- one. For when a character leaves (logout, disconnect), AFTER its row is written — the next
--- character on this source must not inherit a `_lastPos` and have its first real move measured
--- against somebody else's.
---@param source number
function PlayerRows.forget(source)
    PlayerRows._dirty[source]    = nil
    PlayerRows._soon[source]     = nil
    PlayerRows._dirtyPos[source] = nil
    PlayerRows._lastPos[source]  = nil
end

--- Write marked positions now, each with its player's pockets and row (one transaction per player).
--- For callers that need it on disk (whip_test's flush seam); the save thread does this by itself. A
--- failed write keeps the mark, so `_lastPos` (what is on disk) only moves when one lands.
---@param onlySource number|nil
---@return boolean
function PlayerRows.flushPositions(onlySource)
    return flushMarked(PlayerRows._dirtyPos, onlySource)
end

--- Has this player moved far enough since their last WRITE to be worth another one?
local function playerMoved(source, player, epsilon)
    local last = PlayerRows._lastPos[source]
    if not last then return true end

    local ok, c = pcall(function() return player:getCoords() end)
    if not ok or not c then return false end

    return #(vector3(c.x, c.y, c.z) - vector3(last.x, last.y, last.z)) > epsilon
end

-- The position sweep: the same shape and defaults as the vehicle one in vehicles.lua. On Every, so
-- one error in a pass doesn't end it.
do
    -- Both read at each pass, so a change in /whip → Settings takes effect from the next one.
    local function everyMs() return math.max(5000, (Config.PlayerPositionSaveInterval or 30) * 1000) end

    Every('player position sweep', everyMs, function()
        local epsilon = Config.PlayerPositionEpsilon or 2.0
        for source, player in pairs(Players) do
            if not player.phantom and playerMoved(source, player, epsilon) then
                PlayerRows.markPosition(source)
            end
        end
        -- Needs and custom stats that moved since the last sweep (PlayerRows.markSoon): written with the position
        for source in pairs(PlayerRows._soon) do
            PlayerRows._soon[source] = nil
            local player = Players[source]
            if player and not player.phantom then PlayerRows.markDirty(source) end
        end

        -- Marked, not flushed: the sweep decides WHO has moved; the save engine decides WHEN anything
        -- is written (one writer of `characters`).
    end)
end

-- Before every save pass (stores.lua runs this through Stores.beforeFlush: the 1 s flush thread, every
-- forced flush, the stop's dispatch): a player whose row or position changed owes their unit a write.
-- Marked here, not on every stat tick, so Stats.set stays two assignments. A player being torn down
-- is not marked: their unit already owes what PlayerRows.freeze took.
-- (Registered from stores.lua: this file loads first, and `Stores` does not exist yet at its file scope.)
function PlayerRows.markUnits()
    local marked = {}
    for _, set in ipairs({ PlayerRows._dirty, PlayerRows._dirtyPos }) do
        for source in pairs(set) do
            local player = Players[source]
            if not marked[source] and player and not player.phantom and not player.closing then
                marked[source] = true
                local store = Stores.player(source, 'player')
                if store then Stores.markDirty(store) end
            end
        end
    end
end

-- Step 40 of whip_core's stop (server/lifecycle.lua): everyone's position and row are marked — up to a
-- sweep interval of walking exists only in memory — and step 60's dispatch sends them with each
-- player's pockets (PlayerRows.markUnits, above). Nothing here may wait: a stop handler never resumes.
CoreStop.add(40, 'players: rows and positions', function()
    for source, player in pairs(Players) do
        if not player.phantom then
            PlayerRows.markPosition(source)
            PlayerRows.markDirty(source)
        end
    end
end)

-- Step 20 of the final save (server/lifecycle.lua): everyone's row and position, with their pockets,
-- waited for. A player already closing is left to their own teardown save.
FinalSave.add(20, 'character rows and positions', function()
    for source, player in pairs(Players) do
        if not player.phantom and not player.closing then
            PlayerRows.markPosition(source)
            PlayerRows.markDirty(source)
        end
    end
    return Stores.flushAll({ force = true })
end, function()
    local n = 0
    for _ in pairs(PlayerRows._dirty) do n = n + 1 end
    for _ in pairs(PlayerRows._dirtyPos) do n = n + 1 end
    return n
end)

-- ============================================
-- Save
-- ============================================

--- Save this character now: pockets, row and position, in one transaction (their unit). Every caller
--- is a teardown or an admin save. A teardown freezes the row and position
--- first (PlayerRows.freeze), so a write that fails stays owed with the session's own values and a
--- relog waits for it.
---
--- Position always: the sweep only marks a player who has moved more than the epsilon since their last
--- write, so someone who logs out after a short walk may have nothing pending, and where they logged
--- out is exactly where they expect to be standing next time.
---@param teardown boolean|nil  the last save of this character's session (disconnect, logout): its seat noted, its row frozen
---@param seatNoted boolean|nil  a teardown save after the first (PlayerRows.saveIfChanged): the seat is not noted again
---@return boolean ok
function WhipPlayer:save(teardown, seatNoted)
    if self.phantom then return true end
    PlayerRows.markPosition(self.source)
    PlayerRows.markDirty(self.source)
    if teardown then
        -- The seat they are leaving in, so they wake up in it (Vehicles.noteLastSeat). Before freeze:
        -- it is metadata, and freeze builds the last row.
        if not seatNoted then Vehicles.noteLastSeat(self) end
        PlayerRows.freeze(self)
    end

    local store = Stores.player(self.source, 'player')
    if store then
        Stores.markDirty(store)
        return Stores.flushNow(store)
    end

    -- No pockets to save with (a character that never finished loading): the row alone.
    local queries, confirm = PlayerRows.pending(self)
    if #queries == 0 then return true end
    local ok = Stores.runTransaction(queries, 'character_row')
    if ok and confirm then confirm() end
    return ok
end

-- ============================================
-- Kick
-- ============================================

---@param reason string
function WhipPlayer:kick(reason)
    DropPlayer(tostring(self.source), reason or 'Kicked from server')
end

-- ============================================
-- Logout (return to character select)
-- ============================================

---@param invoker string|nil  the resource that asked (LogoutPlayer passes it; see the drain below)
function WhipPlayer:logout(invoker)
    -- A teardown, through the same funnel as a disconnect (SafeSavePlayer): the same character may
    -- load next into a FRESH inventory table, and the queued store handle holds this session's cache
    -- by reference, so the write queue must be cleared with the write.
    --
    -- ReleaseCharacterSession (player_lifecycle.lua, shared with playerDropped) runs before the save,
    -- so the next character doesn't inherit open stashes, panels, escort, clock-on, basket or money held,
    -- and anything it folds back into the inventory is saved.
    --
    -- Once: a second logout (the LogoutPlayer export landing during this one's awaits) would run the
    -- whole teardown again.
    if self.closing then return false end

    -- Closing first, before anything here yields: the secure layer refuses this session's events from
    -- now on, so nothing the client sends can change a cache that is about to be dropped.
    self.closing = true

    -- Let what is already running finish. A handler already past the gate that yields would resume
    -- against a dropped cache, or through a source-keyed export against the character picked next.
    -- Bars and skill checks end first, so a handler waiting on one answers now; the rest get two
    -- seconds. A handler that called this logout is not waited on: HandlersInFlight leaves the asker
    -- out (whip_core's own by its coroutine, a satellite's by `invoker`).
    if EndTimedActionsFor then EndTimedActionsFor(self.source) end
    if EndSkillChecksFor then EndSkillChecksFor(self.source) end
    if EndAsksFor then EndAsksFor(self.source) end
    local drainBy = GetGameTimer() + 2000
    while HandlersInFlight and HandlersInFlight(self.source, invoker) > 0 and GetGameTimer() < drainBy do
        Wait(50)
    end
    if self.dropped then return end

    if ReleaseCharacterSession then ReleaseCharacterSession(self.source, self) end

    -- Disconnected while that waited? Then playerDropped owns the rest; carrying on would re-create
    -- what the drop just cleared (a PendingPlayers entry a reissued server id would inherit). Asked
    -- after each wait.
    if self.dropped then return end

    -- Effects end BEFORE the save, so what their onRemove changes is in it.
    if Stats and Stats.endEffects then Stats.endEffects(self.source, 'logout') end

    SafeSavePlayer(self, 'logout', true)
    if self.dropped then return end
    Inventory.clearCooldowns(self.source)

    local source = self.source
    local userId = self.userId

    Sentinel.setPlayerKey(source, PLAYER_DMGMOD_KEY, nil)
    Sentinel.setPlayerKey(source, PLAYER_MELEEMOD_KEY, nil)
    Sentinel.setPlayerKey(source, PLAYER_ESCORTER_KEY, nil)
    -- And the rest of what said who they were, so dead or on duty doesn't stay through character select.
    Sentinel.setPlayerKey(source, PLAYER_DEAD_KEY, nil)
    Sentinel.setPlayerKey(source, PLAYER_JOB_KEY, nil)
    Sentinel.setPlayerKey(source, PLAYER_MOOD_KEY, nil)

    -- On the record, as a disconnect is.
    Log.write(self.charId, 'logout', { detail = 'to character select' })

    -- The row is written; the next character starts its own position tracking.
    PlayerRows.forget(source)

    -- Out of the shared world BEFORE the client is told anything: the client hides the ped locally
    -- and fades for half a second, which everyone else would watch it stand frozen through.
    if EnterCharSelectBucket then EnterCharSelectBucket(source) end

    -- Logout event before cleanup (whip_core:player:logout, why = 'logout'). Core's own hooks first
    -- (Character.onLife), then the news.
    local sheet = self:serialize()
    local ended = { source = source, charId = self.charId, player = sheet, why = 'logout' }
    Character.runHooks('logout', ended)
    WhipEmit('whip_core:player:logout', ended)
    TriggerClientEvent('whip_core:client:playerLogout', source)

    -- What a listener changed on the character (metadata, a stat) is saved too, then the source's
    -- tracking goes.
    PlayerRows.saveIfChanged(self)
    if self.dropped then return end   -- (that may have waited: see above)
    PlayerRows.forget(source)

    -- Stats belong to the character; initPlayer rebuilds them for the next one. AFTER the event, as
    -- on a disconnect, so a listener can still read GetStat. The modifier bags were cleared above.
    if Stats and Stats.cleanupPlayer then Stats.cleanupPlayer(source) end

    -- Remove from active players, put back in pending
    Players[source] = nil
    PlayersByCharId[self.charId] = nil
    -- Only if it is still US: two connections of one account may each have a character in, and the
    -- other one, if it has, is the account's from here (rather than none).
    if PlayersByUserId[self.userId] == self then
        PlayersByUserId[self.userId] = nil
        for _, other in pairs(Players) do
            if other.userId == self.userId then PlayersByUserId[self.userId] = other; break end
        end
    end
    PendingPlayers[source] = {
        userId = userId,
        license = self.license,
        steam = self.steam,
        discord = self.discord,
        fivem = self.fivem,
    }
end

-- ============================================
-- Serialize (for sending to client / events)
-- ============================================

---
--- Health and armour are read live from the stats cache; `self.health` / `self.armour` are only
--- refreshed on a save and stand in before stats have loaded.
---@return table
function WhipPlayer:serialize()
    local health = Stats and Stats.get(self.source, 'health')
    local armour = Stats and Stats.get(self.source, 'armour')
    -- Position live too (three natives); the last good position stands in before the ped exists.
    local pos = self:getCoords()
    return {
        source     = self.source,
        session    = self.session,   -- see IsSessionCurrent
        userId     = self.userId,
        charId     = self.charId,
        firstName  = self.firstName,
        lastName   = self.lastName,
        fullName   = self.fullName,
        dateOfBirth = self.dateOfBirth,
        gender     = self.gender,
        cash       = self:getCash(),
        position   = {x = pos.x, y = pos.y, z = pos.z, w = pos.w},
        health     = health or self.health,
        armour     = armour or self.armour,
        isDead     = self.isDead,
        metadata   = self.metadata,
    }
end

--- The sheet another resource's HANDLER is handed — a SecureEvent or SecureCallback handler, an item
--- use handler, a context action, an effect callback: serialize() without `metadata`.
---
--- FiveM copies every argument across the resource boundary, and metadata is the appearance (about a
--- kilobyte) on every shot and every effect tick. GetPlayer(source) has the whole sheet.
---@return table
function WhipPlayer:handlerSheet()
    local sheet = self:serialize()
    sheet.metadata = nil
    return sheet
end

--- The LIGHT sheet, for a SecureEvent/SecureCallback declared `sheet = 'light'`: who the player is and
--- whether they are dead — the fields that cost nothing to read. No position (three natives), no
--- cash (a scan of the pockets), no health or armour (stat reads). For an event fired many times a
--- second whose handler never reads those. GetPlayer(source) has the rest.
---@return table
function WhipPlayer:lightSheet()
    return {
        source      = self.source,
        session     = self.session,
        userId      = self.userId,
        charId      = self.charId,
        firstName   = self.firstName,
        lastName    = self.lastName,
        fullName    = self.fullName,
        dateOfBirth = self.dateOfBirth,
        gender      = self.gender,
        isDead      = self.isDead,
    }
end

--- Is this still the same character session — loaded, not logging out, not replaced? For a handler
--- that waited (a DB await, a Wait, a bar) before it gives or takes something:
---
---     local receipt, err = exports.whip_core:ChargePlayer(source, 500, { method = 'bank' })  -- yields
---     if not receipt then return false, err end
---     Wait(4000)                                                    -- the animation
---     if not exports.whip_core:IsSessionCurrent(source, player.session) then
---         exports.whip_core:RefundPlayer(receipt)
---         return false, 'You left before the sale went through'
---     end
---     exports.whip_core:AddItem(source, 'thing', 1)
---
--- Logout also waits up to two seconds for running handlers, so the common short wait is covered
--- without this; the check is for the long one.
---@param source number
---@param session number  the `session` from the sheet your handler was given
---@return boolean
local function IsSessionCurrent(source, session)
    local p = Players[tonumber(source)]
    return p ~= nil and session ~= nil and p.session == session and not p.closing
end

exports('IsSessionCurrent', IsSessionCurrent)

-- ============================================
-- Public Exports
-- ============================================
-- These return data (WhipPlayer:serialize()), not the live object: FiveM copies values across a
-- resource boundary and a metatable doesn't survive the copy, so the methods get exports of their
-- own below. In-core code uses Players[source] and keeps the methods.
--
-- The identifiers (discord, fivem, license, steam) are not on the sheet: it is also sent to the
-- client on playerLoaded. GetPlayerIdentifiers has them.

--- The identifier kinds GetPlayer finds a player by: the four GetPlayerIdentifiers returns.
local IDENTIFIER_TYPES = { license = true, steam = true, discord = true, fivem = true }

--- The online player a `who` names: a server id, or `{ charId = }`, `{ userId = }` or
--- `{ identifier = 'license:...' }`. Only identifier fields, and never nil: a nil identifier would match the
--- first player missing it.
---@param who any
---@return table|nil player  the live object
local function onlinePlayerOf(who)
    if type(who) ~= 'table' then return Players[tonumber(who)] end
    if who.charId ~= nil then return PlayersByCharId[Sanitize.id(who.charId)] end
    if who.userId ~= nil then return PlayersByUserId[Sanitize.id(who.userId)] end
    local identifier = who.identifier
    if type(identifier) ~= 'string' then return nil end
    local kind = identifier:match('^(%w+):.')
    if not kind or not IDENTIFIER_TYPES[kind] then return nil end
    for _, player in pairs(Players) do
        if player[kind] == identifier then return player end
    end
    return nil
end

--- A player as plain, copyable data: by server id, or by `{ charId = }`, `{ userId = }` or
--- `{ identifier = 'license:...' }`. nil when nobody online matches.
---@param who number|table
---@return table|nil
exports('GetPlayer', function(who)
    local player = onlinePlayerOf(who)
    return player and player:serialize() or nil
end)

--- Their charId, or nil while no character is loaded: the one number most code wants, without copying the sheet
--- (GetPlayer copies all of it, appearance and inventory included).
---@param source number
---@return integer|nil
exports('GetCharId', function(source)
    local player = Players[tonumber(source)]
    return player and player.charId or nil
end)

--- Is a character loaded for this server id? The cheap readiness check.
---@param source number
---@return boolean
exports('IsPlayerLoaded', function(source)
    return Players[tonumber(source)] ~= nil
end)

--- Are they down? The server's own reading (what SecureEvent's whileDead asks), from memory. false for nobody loaded.
---@param source number
---@return boolean
exports('IsPlayerDead', function(source)
    local player = Players[tonumber(source)]
    return player ~= nil and player.isDead == true
end)

--- Every loaded player, keyed by server id, as plain data (a copy, not the live registry).
---
--- `{ light = true }` for the light sheet of each: cheaper for a caller that wants names and charIds.
---@return table<number, table>
exports('GetPlayers', function(opts)
    local light = type(opts) == 'table' and opts.light == true
    local out = {}
    for src, player in pairs(Players) do
        out[src] = light and player:lightSheet() or player:serialize()
    end
    return out
end)

--- The identifiers serialize() deliberately leaves out (the sheet also goes to the client), behind
--- their own call so adding a field to the sheet can never publish one.
---@param source number
---@return table|nil  { discord, fivem, license, steam }
exports('GetPlayerIdentifiers', function(source)
    local player = Players[source]
    if not player then return nil end
    return {
        discord = player.discord,
        fivem   = player.fivem,
        license = player.license,
        steam   = player.steam,
    }
end)

-- ============================================
-- The methods, as exports
--
-- WhipPlayer's methods don't cross a resource boundary, so each one a satellite could want gets a
-- call of its own, same behaviour and argument order. Each resolves the player itself rather than
-- taking a sheet back in, which could be stale.
-- ============================================

---@param source number
---@return number cash
exports('GetPlayerCash', function(source)
    local player = Players[source]
    -- A count answers 0 and why when there is no player, as GetItemCount does.
    if not player then return 0, 'Player not loaded' end
    return player:getCash()
end)

local NOTIFY_KINDS = { 'info', 'success', 'warning', 'error' }

--- Show a player one of whip's toasts, of any kind, from the server.
---
---     exports.whip_core:NotifyPlayer(source, 'Your rental ends in 5 minutes', 'warning')
---
--- `-1` for everyone on the server.
---@param source number  a player, or -1 for everyone
---@param text string
---@param kind string|nil  'info' (default), 'success', 'warning' or 'error'
---@param duration number|nil  milliseconds; leave it out for the usual short toast
---@return boolean sent  false for a player who is not on the server, or no text
---@return string|nil why
---
--- A global as well as the export, so whip_core's own code sends the same toast: a SecureEvent
--- handler's `return false, 'why'` is shown through it (server/secure.lua).
function NotifyPlayer(source, text, kind, duration)
    if source ~= -1 then
        local id = Sanitize.id(source)
        if not id or not GetPlayerName(id) then return false, 'They are not on the server' end
        source = id
    end
    text = Sanitize.string(text, 300)
    if text == '' then return false, 'Nothing to say: the text is empty' end

    duration = tonumber(duration)
    if duration then duration = math.max(500, math.min(30000, math.floor(duration))) end

    TriggerClientEvent('whip_core:client:notify', source, text,
        Sanitize.enum(kind, NOTIFY_KINDS, 'info'), duration)
    return true
end

exports('NotifyPlayer', NotifyPlayer)

--- whip_core's own red and green toasts: NotifyPlayer with the kind filled in, one toast path.
--- `(target, text, duration?)`. A non-string text is shown as text rather than dropped.
---@param source number  a player, or -1 for everyone
---@param text any
---@param duration number|nil  milliseconds
---@return boolean sent
function ShowError(source, text, duration)
    if text ~= nil and type(text) ~= 'string' then text = tostring(text) end
    return NotifyPlayer(source, text, 'error', duration)
end

---@param source number  a player, or -1 for everyone
---@param text any
---@param duration number|nil  milliseconds
---@return boolean sent
function ShowSuccess(source, text, duration)
    if text ~= nil and type(text) ~= 'string' then text = tostring(text) end
    return NotifyPlayer(source, text, 'success', duration)
end

--- An offline character's metadata, read from their row (it is in memory only while they play), or nil and why.
---@param charId number
---@return table|nil metadata
---@return string|nil why
local function offlineMetadata(charId)
    -- The row, not the column alone: a character whose metadata is NULL is still a character.
    local ok, row = pcall(MySQL.single.await,
        'SELECT `metadata` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL', { charId })
    if not ok then return nil, 'The database could not be reached — try again' end
    if type(row) ~= 'table' then return nil, 'No such character' end
    return Character.readJson(row.metadata, ('charId %s metadata'):format(tostring(charId)))
end

--- A person's metadata, one key or all of it: a server id, or `{ charId = n }` for a character online or not (an
--- offline one's is read from the database, so this waits). nil for nobody.
exports('GetPlayerMetadata', function(who, key)
    local charId, src = WhoIs(who)
    if not charId then return nil end
    ---@cast src number|nil   -- with a charId, WhoIs's second answer is their source
    local player = src and Players[src]
    if player then return player:getMetadata(key) end
    local metadata = offlineMetadata(charId)
    if not metadata then return nil end
    if key then return metadata[key] end
    return metadata
end)

-- whip_core's own keys in a character's metadata, written only by the calls that own them (the creator and
-- appearance, outfits, walks and moods, player flags, money holds, the last-seat note). A resource storing its own
-- 'mood' would overwrite whip's, and an 'appearance' would skip its checks, so SetPlayerMetadata refuses them.
-- Reading them (GetPlayerMetadata) is fine.
local CORE_METADATA_KEYS = {
    appearance = true, outfits = true, creatorPending = true, walk = true, mood = true,
    whipFlags = true, moneyHeldOwed = true, pourRefundOwed = true, lastSeat = true,
}

--- [charId] = true while an offline character's metadata is being written: one write at a time, or the second
--- would read before the first lands and put the old value back.
local _offlineMetadataWrite = {}

--- Set one key on a character who is not playing: their row, read and written back. Refused while they are logging
--- in (the login reads the row, and would keep the old one).
---@return boolean ok
---@return string|nil why
local function setOfflineMetadata(charId, key, value)
    if value ~= nil and not pcall(json.encode, { v = value }) then
        return false, ('metadata "%s" cannot be saved (not JSON-encodable — store plain numbers, strings and tables)')
            :format(key)
    end
    if (LoadingCharIds and LoadingCharIds[charId]) or _offlineMetadataWrite[charId] then
        return false, 'That character is busy right now — try again in a moment'
    end
    _offlineMetadataWrite[charId] = true
    local ok, done, why = pcall(function()
        local metadata, readWhy = offlineMetadata(charId)
        if not metadata then return false, readWhy end
        -- Logged in while it was read: the live sheet is the one to change now.
        if PlayersByCharId[charId] or (LoadingCharIds and LoadingCharIds[charId]) then
            return false, 'That character is busy right now — try again in a moment'
        end
        metadata[key] = value
        -- (No count check: a write that changes nothing may count 0 rows.)
        local wrote = pcall(MySQL.update.await,
            'UPDATE `characters` SET `metadata` = ? WHERE `charId` = ? AND `deleted` IS NULL',
            { json.encode(metadata), charId })
        if not wrote then return false, 'Could not save that (database error)' end
        return true
    end)
    _offlineMetadataWrite[charId] = nil
    if not ok then return false, tostring(done) end
    if not done then return false, why end
    return true
end

--- Set one key of a person's metadata: a server id, or `{ charId = n }` for a character online or not (an
--- offline one's row is written, so this waits). Not whip_core's own keys.
exports('SetPlayerMetadata', function(who, key, value)
    if type(key) ~= 'string' or key == '' then return false, 'a metadata key is a string, such as "myresource_licences"' end
    if CORE_METADATA_KEYS[key] then
        local res = GetInvokingResource() or 'myresource'
        return false, ("metadata '%s' is whip_core's own (it has its own calls): give yours another name, such as '%s_%s'")
            :format(key, res, key)
    end
    local charId, src = WhoIs(who)
    if not charId then return false, src --[[@as string]] end
    ---@cast src number|nil   -- with a charId, WhoIs's second answer is their source
    local player = src and Players[src]
    if not player then return setOfflineMetadata(charId, key, value) end
    local ok, err = player:setMetadata(key, value)
    if not ok then return false, err end
    return true
end)

exports('GetPlayerCoords', function(source)
    local player = Players[source]
    return player and player:getCoords() or nil
end)

--- The character's full name, or nil for a player not in a character: one string, cheaper than the
--- whole sheet. Not FiveM's GetPlayerName, which is the account's name.
---@param source number
---@return string|nil
exports('GetPlayerFullName', function(source)
    local player = Players[source]
    return player and player.fullName or nil
end)

--- Characters' names by charId, online or not: { [charId] = 'First Last' }. A charId that names no
--- character is left out. For a list of people that are not all online: a shared bank account's
--- users, a job's staff. Up to 200 at a time.
---@param charIds number[]
---@return table<number, string>
exports('GetCharacterNames', function(charIds)
    if type(charIds) ~= 'table' then return {} end
    local ids = {}
    for _, v in ipairs(charIds) do
        local id = Sanitize.id(v)
        if id then ids[#ids + 1] = id end
        if #ids >= 200 then break end
    end
    return ResolveCharNames(ids)
end)

--- A client asking another player's name. Names are not on statebags (every client would get every
--- name); the server answers under Config.ShowPlayerNames, the name rule MayKnowName (helpers.lua).
--- Your own name you always get. The client export GetPlayerFullName caches what this answers.
---@return string|false name
---@return string|nil why
SecureCallback('whip_core:playerName', {
    whileDead = true,
    rateLimit = 100,
    burst     = 20,
    params    = { {'target', 'id'} },
}, function(source, _, target)
    local who = Players[target]
    if not who or not who.fullName then return false, 'Player not loaded' end
    local ok, why = MayKnowName(source, target)
    if not ok then return false, why end
    return who.fullName
end)

--- May this player be shown that one's character name? whip's name rule, Config.ShowPlayerNames
--- (MayKnowName): for a resource that shows players other people's names — a list of who is nearby,
--- who sent this. Both are people: a source, or { charId = n } (an offline character is never "nearby").
---@return boolean ok
---@return string|nil why
exports('CanSeePlayerName', function(viewer, target)
    return MayKnowName(viewer, target)
end)

--- Save the player now: the pockets (the whole player unit, with any move it is half of), then the
--- row. For a satellite pairing an inventory change with its own write (a sales ledger row after a
--- RemoveItem): put the inventory half on disk first. Answers true, or (false, 'why').
exports('SavePlayer', function(source)
    local player = Players[source]
    if not player then return false, 'Player not loaded' end
    local invOk = true
    local store = Stores and Stores.player and Stores.player(source, 'player')
    if store then invOk = Stores.flushNow(store) == true end
    local rowOk = player:save()
    if invOk and rowOk then return true end
    return false, 'The save did not complete (it is retried)'
end)

exports('KickPlayer', function(source, reason)
    local player = Players[source]
    if not player then return false, 'Player not loaded' end
    player:kick(reason)
    return true
end)

exports('LogoutPlayer', function(source)
    local invoker = GetInvokingResource()   -- first, before anything can yield
    local player = Players[source]
    if not player then return false, 'Player not loaded' end
    -- Already on the way out: logout() does nothing a second time, so say so.
    if player.closing then return false, 'Already leaving' end
    player:logout(invoker)
    return true
end)

-- The pause menu's Quit (client/pause.lua): leave the server, back to FiveM's
-- server list. The character saves on the drop, as on any disconnect. Allowed dead, or with no
-- character: leaving is never something to refuse.
SecureEvent('whip_core:server:leaveServer', {
    rateLimit = 2000,
    requirePlayer = false,
    whileDead = true,
}, function(source)
    DropPlayer(tostring(source), 'You left the server.')
end)
