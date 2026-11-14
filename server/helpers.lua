-- ============================================
-- Shared Server Helpers — the framework's basics
-- Loaded before all event/lifecycle files.
-- ============================================
--
-- Used all over whip_core and belonging to no one system: the schema helper, the database-error
-- words, waiting for start-up, naming a person, the rate limiter, the teardown save, proximity,
-- server ids, flag columns and character names. Capitalised globals, like SecureEvent, on purpose.

-- ---- Schema ----

--- How every whip table sorts and compares its text. Named, not left to the database server: its own default
--- differs between MariaDB and MySQL versions (and the newest MariaDB's does not exist on MySQL), and two tables
--- that sort differently cannot compare their text ("Illegal mix of collations"). JSON columns keep their own.
TABLE_COLLATION = 'utf8mb4_unicode_ci'

--- A `CREATE TABLE` with TABLE_COLLATION in its table options, unless it names a collation of its own there.
--- The options are what follows the column list's closing bracket.
---@param ddl string
---@return string
function WithTableCollation(ddl)
    local close = ddl:match('^.*()%)')
    if not close then return ddl end
    local options = ddl:sub(close + 1)
    if options:upper():find('COLLATE', 1, true) then return ddl end
    local body, tail = options:match('^(.-)(%s*;?%s*)$')
    return ddl:sub(1, close) .. body .. ' COLLATE=' .. TABLE_COLLATION .. tail
end

--- Run one `CREATE TABLE IF NOT EXISTS`, say what failed, and answer whether it worked.
---
--- The schema is these statements: each module's ensureTable builds its tables complete (columns,
--- keys, foreign keys, checks) the first time. Every ensureTable answers, and start-up refuses to
--- run when one of them says no (server/player_lifecycle.lua).
---
--- A table with a FOREIGN KEY needs the table it points at to exist first, which is why
--- start-up builds them in a fixed order, parents first. Its text sorts by TABLE_COLLATION (WithTableCollation).
---@param name string  the table, for the message
---@param ddl string
---@return boolean ok
function CreateTable(name, ddl)
    local ok, err = pcall(MySQL.query.await, WithTableCollation(ddl))
    if not ok then
        print(('^1[whip_core:schema] could not create `%s`: %s^0'):format(name, tostring(err)))
    end
    return ok
end

--- A picture another resource ships, as the URL any page loads it from: '@mypack/img/car.webp' (or 'img/car.webp',
--- the caller's own) -> 'https://cfx-nui-mypack/img/car.webp'. The file must be there and listed in that resource's
--- `files { }`, or the page cannot load it. nil and why when it is not there.
---@param owner string  the resource asking (a bare path is its own)
---@param image string
---@return string|nil url
---@return string|nil why
function ResourceFileUrl(owner, image)
    if type(image) ~= 'string' or image == '' then return nil, 'image is a path like "@yourresource/img/x.webp"' end
    local res, path = image:match('^@([%w_%-]+)/(.+)$')
    if not res then res, path = owner, image end
    if path:find('..', 1, true) then return nil, 'the image path may not go up a folder' end
    local data = LoadResourceFile(res, path)
    if not data or #data == 0 then return nil, ('no file %s in %s'):format(path, res) end
    return ('https://cfx-nui-%s/%s'):format(res, path)
end

--- The reason every export gives when the database refused a write, in WORDS like every other reason
--- whip answers. One constant, so code that has to recognise it compares against this rather than a
--- copy of the text.
DB_ERROR = 'Could not save that (database error)'

--- Wait until whip_core has finished starting — at most 60 seconds — and answer whether it has.
---
--- For the Ensure* exports: resources listed after whip_core in server.cfg start while whip_core is
--- still building tables and loading its caches, and a declaration made then would find an empty
--- cache. Bounded, so a caller never hangs on a whip_core that failed to start.
---@return boolean ready
function WaitForCoreReady()
    if CoreReady == true then return true end
    local untilT = GetGameTimer() + 60000
    while CoreReady ~= true and GetGameTimer() < untilT do Wait(250) end
    return CoreReady == true
end

--- The answer an Ensure* export gives when WaitForCoreReady says no.
NOT_READY = 'whip_core has not finished starting (see its console)'

--- A person, the way every export takes one: a bare number is a SERVER ID (the `source` a handler
--- already holds), and a character, online or not, is `{ charId = n }`. One rule, so the same number
--- never names two people. An export whose own NAME says Character or CharId (GetCharacterProperties)
--- takes the charId it names.
---
--- Answers `charId, source` (source only while they are online), or `nil, why`.
---@param ref number|table
---@return number|nil charId
---@return number|string|nil sourceOrWhy
function WhoIs(ref)
    if type(ref) == 'table' then
        local charId = Sanitize.id(ref.charId)
        if not charId then return nil, 'A character is { charId = n }' end
        local p = PlayersByCharId and PlayersByCharId[charId]
        return charId, p and p.source or nil
    end
    local src = tonumber(ref)
    local player = src and Players[src]
    if not player or not player.charId then
        return nil, 'No player with that server id is online (for a character, pass { charId = n })'
    end
    return player.charId, src
end

--- A TIMESTAMP/DATETIME read from the database as epoch SECONDS — the unit os.time() gives, and the
--- one whip keeps in memory.
---
--- oxmysql hands these columns back as epoch MILLISECONDS, while rows made this session carry
--- os.time(). A value already in seconds passes through, and so does a 'YYYY-MM-DD HH:MM:SS' string,
--- should a driver setting ever return text.
---@param v any
---@return integer|nil
function EpochSeconds(v)
    if type(v) == 'number' then
        if v >= 1e11 then return math.floor(v / 1000) end   -- ms: any date after 1973
        return math.floor(v)
    end
    if type(v) == 'string' then
        local y, mo, d, h, mi, s = v:match('^(%d+)%-(%d+)%-(%d+)[ T](%d+):(%d+):(%d+)')
        if y then
            -- (digits, by the pattern: tonumber always answers)
            return os.time({ year = tonumber(y) --[[@as integer]], month = tonumber(mo) --[[@as integer]],
                             day = tonumber(d) --[[@as integer]],
                             hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
        end
    end
    return nil
end

-- ---- Rate Limiter ----

local _rateLimits = {}

--- Token-bucket rate limiter.
---
--- `cooldownMs` is the sustained interval between calls. `burst` is how many calls may arrive
--- back-to-back before that interval starts being enforced; it defaults to 1 (a flat cooldown).
---
--- The burst matters for drag-and-drop: the NUI applies moves optimistically, and a flat cooldown
--- would drop quick moves silently.
---@param source number
---@param action string
---@param cooldownMs number
---@param burst number|nil  max back-to-back calls (default 1)
---@return boolean allowed
function RateLimit(source, action, cooldownMs, burst)
    -- A load test's bypass: armed only through the __TestRateLimitBypass export, only when
    -- Config.EnableTestSeams is on, and self-expiring (server/testseams.lua, which owns it).
    if TestSeams and TestSeams.rateLimitBypassed() then return true end

    burst = burst or 1
    local now = GetGameTimer()

    local bySource = _rateLimits[source]
    if not bySource then
        bySource = {}
        _rateLimits[source] = bySource
    end

    local bucket = bySource[action]
    if not bucket then
        bySource[action] = { tokens = burst - 1, last = now }
        return true
    end

    -- Refill at one token per cooldownMs, capped at the burst size.
    if cooldownMs > 0 then
        local refill = (now - bucket.last) / cooldownMs
        if refill > 0 then
            bucket.tokens = math.min(burst, bucket.tokens + refill)
            bucket.last = now
        end
    end

    if bucket.tokens >= 1 then
        bucket.tokens = bucket.tokens - 1
        return true
    end
    return false
end

AddEventHandler('playerDropped', function()
    _rateLimits[source] = nil
end)

-- ---- Safe Save Helper ----

--- Save a player's character row and inventory, reporting honestly whether both landed.
---
--- The funnel for the two teardowns (playerDropped and WhipPlayer:logout) plus the /whip_save
--- command: both teardowns are about to drop the handle that owns the inventory cache, so the
--- write is forced rather than left to the write-behind thread. (whip_core's own stop and the
--- scheduled-restart warning mark everyone and write them in one batch instead.)
---@param player WhipPlayer
---@param label string
---@param teardown boolean|nil  true only when the session is about to be dropped (disconnect,
---                             logout): the row is frozen first, so a failed write stays owed (player.lua)
---@return boolean ok  false if either half failed to commit
function SafeSavePlayer(player, label, teardown)
    -- Phantom guard: load tests inject fake players into `Players` (TestSeams.phantoms), which have no
    -- character row. Here because this is the single funnel every save path goes through.
    if player.phantom then return true end

    local ok = true

    -- Both failures count: a throw, and save() answering false.
    local pcallOk, saved = pcall(function() return player:save(teardown) end)
    if not pcallOk or saved == false then
        ok = false
        print(('[whip_core] ERROR saving player %s [%d] during %s: %s'):format(
            player.fullName, player.source, label,
            pcallOk and 'the save did not commit — still owed, retried' or tostring(saved)
        ))
    end

    -- The pockets went with the row: player:save writes the character's unit — pockets, row and
    -- position — in one transaction. Only a session whose store cannot resolve
    -- any more saves its cache directly here.
    if player.inventory and not Stores.player(player.source, 'player') then
        local invOk, invErr
        do
            -- The session handle is already gone on some paths, so the store cannot resolve.
            -- The cache itself is still right here, so save it directly rather than skipping
            -- the save, and drop the queue entry ONLY if that landed (a failed one stays owed, and
            -- linked to the other half of its move).
            local saveRan, saveOk2, saveErr2 = pcall(Inventory.save, player.charId, player.inventory)
            if saveRan then
                invOk, invErr = saveOk2, saveErr2
            else
                invOk, invErr = false, saveOk2
            end
            if invOk then Stores.forget('player:' .. tostring(player.charId)) end
        end

        -- pcall succeeding only means it did not throw; the save's own return says whether the
        -- transaction actually committed.
        if not invOk then
            ok = false
            print(('[whip_core] ERROR saving inventory for %s [%d] during %s: %s'):format(
                player.fullName, player.source, label, tostring(invErr)
            ))
        end
    end

    -- NOT clearCooldowns here: it belongs on the disconnect paths, which call it directly. A save
    -- called on a timer would otherwise hand out cooldown resets.
    return ok
end

-- ============================================
-- Proximity — one implementation
-- ============================================
--
-- One implementation, so every proximity check agrees. Compares squared distances (no square root
-- on a path that runs on every interaction), and treats a missing ped as "not near": a player whose
-- ped has not spawned is not standing next to anything.
--
-- Nor is a player still in the character creator: a new character is built in a private routing
-- bucket, invisible to everyone, and a client that never says it is done could otherwise work
-- stashes, doors and shops unseen.
---@param source number
---@param x number
---@param y number
---@param z number
---@param range number
---@return boolean
function IsPlayerNear(source, x, y, z, range)
    local player = Players and Players[source]
    if player and player._inCreator then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local pos = GetEntityCoords(ped)
    local dx, dy, dz = pos.x - x, pos.y - y, pos.z - z
    return (dx * dx + dy * dy + dz * dz) <= (range * range)
end

--- May `viewer` learn `target`'s character name? The one name rule, Config.ShowPlayerNames:
---   'nearby' (default) — someone in the city within Config.PlayerNameRange, in the same routing bucket, and
---                        neither of them in the character creator (an offline character is never nearby);
---   'always'           — anyone's;   'never' — nobody's.
--- Your own name you always may. Both are people (WhoIs): a source, or { charId = n }; the viewer must be on.
--- One rule for every place a player is shown a name: the client's GetPlayerFullName, the phone's lists of
--- people nearby, the Director's Pick Team.
---@param viewer number|table
---@param target number|table
---@return boolean ok
---@return string|nil why
function MayKnowName(viewer, target)
    local viewerChar, viewerSrc = WhoIs(viewer)
    local targetChar, targetSrc = WhoIs(target)
    if not viewerChar or not viewerSrc or not targetChar then return false, 'Player not loaded' end
    -- (With a charId, WhoIs answers their source or nil, not a why.)
    ---@cast viewerSrc number
    ---@cast targetSrc number|nil
    if viewerChar == targetChar then return true end
    local rule = Config.ShowPlayerNames
    if rule == 'never' then return false, 'Names are hidden on this server' end
    if rule == 'always' then return true end
    local who = targetSrc and Players[targetSrc]
    if not targetSrc or not who or who._inCreator or GetPlayerRoutingBucket(targetSrc) ~= GetPlayerRoutingBucket(viewerSrc) then
        return false, 'Too far away'
    end
    local ped = GetPlayerPed(targetSrc)
    if not ped or ped == 0 then return false, 'Too far away' end
    local at = GetEntityCoords(ped)
    if not IsPlayerNear(viewerSrc, at.x, at.y, at.z, tonumber(Config.PlayerNameRange) or 25.0) then
        return false, 'Too far away'
    end
    return true
end

--- Resolve a raw value as a server id — by REJECTING, never by clamping.
---
--- An id is an ADDRESS: Sanitize.int CLAMPS, and a clamped id acts on whoever holds that slot (a
--- kick, a teleport, a given item). One implementation, used by every handler that takes a player id
--- off the wire.
---@param raw any
---@return number|nil  nil when it is not a whole positive number
function AsServerId(raw)
    -- Sanitize.id: also refuses NaN and infinity, which `math.floor(x) == x` let through.
    return Sanitize.id(raw, 1)
end

--- Read a TINYINT(1) flag column as a boolean, whichever shape it arrives in.
---
--- oxmysql's query/single/scalar hand TINYINT(1) back as a Lua BOOLEAN, while prepare/rawExecute
--- hand back a number, so `row.frozen == 1` never fires on the query path. One helper so every flag
--- read answers the same way.
---@param v any
---@return boolean
function DbBool(v)
    return v == true or (tonumber(v) or 0) ~= 0
end

--- Offline names already read: [charId] = name. Good for the session, until the character is renamed (the admin
--- panel can, since 1 Nov: Character.rename), which forgets it here. The admin panels that ask rebroadcast on every
--- change.
local _nameCache = {}
--- [charId] = when the table did not know that id; asked again after NAME_MISS_MS, not every time.
local _nameMissAt = {}
local NAME_MISS_MS = 60000
Character.onLife('renamed', function(e)   -- core's own hook, not the public event (character.lua Character.rename)
    if type(e) ~= 'table' or not e.charId then return end
    _nameCache[e.charId], _nameMissAt[e.charId] = nil, nil
end)

--- Resolve character names for a list of charIds — online players from their live record,
--- offline ones from a cache, and whatever is left from one batched query.
---
--- The one name resolver: whip_core's panels use it, and other resources reach it through
--- GetCharacterNames.
---@param charIds number[]
---@return table  [charId] = display name
function ResolveCharNames(charIds)
    local names = {}
    local missing, asked = {}, {}
    local now = GetGameTimer()

    for _, charId in ipairs(charIds) do
        local p = PlayersByCharId[charId]
        if p then
            names[charId] = p.fullName
        elseif _nameCache[charId] then
            names[charId] = _nameCache[charId]
        elseif not asked[charId] and not (_nameMissAt[charId] and now - _nameMissAt[charId] < NAME_MISS_MS) then
            asked[charId] = true
            missing[#missing + 1] = charId
        end
    end

    if #missing > 0 then
        local placeholders = {}
        for i = 1, #missing do placeholders[i] = '?' end
        local sql = 'SELECT `charId`, `firstName`, `lastName` FROM `characters` WHERE `charId` IN (' .. table.concat(placeholders, ',') .. ')'
        local ok, rows = pcall(MySQL.query.await, sql, missing)
        if ok and rows then
            for _, row in ipairs(rows) do
                local name = (row.firstName or '') .. ' ' .. (row.lastName or '')
                _nameCache[row.charId] = name
                names[row.charId] = name
            end
            for _, charId in ipairs(missing) do
                if not _nameCache[charId] then _nameMissAt[charId] = now end
            end
        end
    end

    return names
end
