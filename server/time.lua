-- ============================================
-- TIME & WEATHER — Server Module
-- Server-authoritative time and weather sync
-- with per-player override support
-- ============================================

TimeWeather = {}

-- ============================================
-- State
-- ============================================

--- The clock is not stored, it is derived: `anchor + elapsed x rate`. What lives here is what
--- genuinely CHANGES (all four move only on an admin action) and the anchor the time is measured
--- from. Read the clock with TimeWeather.now(); there is no field to read instead.
TimeWeather.state = {
    weather   = Config.StartWeather or 'CLEAR',
    frozen    = false,
    blackout  = false,
    timeScale = Config.TimeScale or 1.0,
}

--- The point the clock is measured from: "at real millisecond R, the game clock read M".
---
--- `realMs` is GetGameTimer rather than a wall clock deliberately. It is monotonic, it has
--- millisecond resolution where os.time has one second, and nothing needs it to survive a
--- restart — the anchor is re-taken against the new timer on load.
TimeWeather._anchor = {
    gameMinutes = ((Config.StartTime and Config.StartTime.hour or 12) * 60)
                + (Config.StartTime and Config.StartTime.minute or 0),
    realMs      = 0,
}

TimeWeather._layers      = {}  -- [source] = { [name] = { priority, hour, minute, weather, ... } }
TimeWeather._layerOwners = {}  -- [source] = { [name] = resource }: who set it, cleared when they stop

--- Game minutes per real millisecond at scale 1.0. GTA runs 30 in-game seconds per real second,
--- so 0.5 game minutes per real second, so 0.0005 per millisecond.
local MINUTES_PER_MS = 30 / 60 / 1000

local MINUTES_PER_DAY = 24 * 60

-- ============================================
-- Weather Validation
-- ============================================

local weatherSet = {}
for _, w in ipairs(Config.WeatherTypes or {}) do
    weatherSet[w] = true
end

-- The list changed in /whip → Settings. It changes in place, so the request checks and cards that
-- hold the table see it already; this set is the one copy.
Settings.onChange('WeatherTypes', function()
    weatherSet = {}
    for _, w in ipairs(Config.WeatherTypes or {}) do weatherSet[w] = true end
end)

function TimeWeather.isValidWeather(weather)
    return weatherSet[string.upper(weather)] == true
end

function TimeWeather.getWeatherTypes()
    return Config.WeatherTypes or {}
end

-- ============================================
-- The Clock
-- ============================================

--- The current game time, in minutes since midnight. Fractional; callers round.
---@return number
function TimeWeather.nowMinutes()
    local a = TimeWeather._anchor
    if TimeWeather.state.frozen then return a.gameMinutes end

    local elapsed = GetGameTimer() - a.realMs
    return (a.gameMinutes + elapsed * MINUTES_PER_MS * TimeWeather.state.timeScale) % MINUTES_PER_DAY
end

--- The current game time as hour, minute.
---@return number hour
---@return number minute
function TimeWeather.now()
    local m = TimeWeather.nowMinutes()
    return math.floor(m / 60) % 24, math.floor(m % 60)
end

--- Re-take the anchor, optionally at a specific game time.
---
--- Needed whenever the BASIS of the derivation moves rather than the time itself — freezing,
--- unfreezing, or any change to timeScale. Skip it on a scale change and the new rate is applied
--- retroactively to every millisecond since the last anchor, and the clock jumps.
---@param gameMinutes number|nil  defaults to the current derived time
function TimeWeather.reanchor(gameMinutes)
    TimeWeather._anchor.gameMinutes = (gameMinutes or TimeWeather.nowMinutes()) % MINUTES_PER_DAY
    TimeWeather._anchor.realMs      = GetGameTimer()
end

-- ============================================
-- Persistence (whip_world)
-- ============================================
--
-- One row, and a MySQL row rather than a KVP entry: SetResourceKvp is SYNCHRONOUS (it blocked the
-- server tick for 4.3ms in a profiler capture). oxmysql runs its queries on another thread, so
-- `await` here yields this coroutine rather than stopping the server.

---@return boolean ok
function TimeWeather.ensureTable()
    return CreateTable('whip_world', [[
        CREATE TABLE IF NOT EXISTS `whip_world` (
            `id`          TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `gameMinutes` DOUBLE           NOT NULL DEFAULT 720,
            `weather`     VARCHAR(32)      NOT NULL DEFAULT 'CLEAR',
            `frozen`      TINYINT(1)       NOT NULL DEFAULT 0,
            `blackout`    TINYINT(1)       NOT NULL DEFAULT 0,
            `timeScale`   DOUBLE           NOT NULL DEFAULT 1.0,
            `updatedAt`   TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                    ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        )
    ]])
end

--- Has TimeWeather.loadAll read the saved world yet? Until it has, what is in memory is config's
--- defaults, and nothing may write them over the saved row.
TimeWeather._loaded = false

--- Write the world row. Upsert on a fixed id, because there is exactly one world.
---
--- Not before the saved one has been read: the five-minute save, the stop step and every setter
--- would otherwise write config's defaults over the saved world. The loader refuses to treat a
--- failed read as a first boot for the same reason.
local function SaveState()
    if not TimeWeather._loaded then return end
    local s = TimeWeather.state
    local ok, err = pcall(MySQL.update.await, [[
        INSERT INTO `whip_world` (`id`, `gameMinutes`, `weather`, `frozen`, `blackout`, `timeScale`)
        VALUES (1, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `gameMinutes` = VALUES(`gameMinutes`),
            `weather`     = VALUES(`weather`),
            `frozen`      = VALUES(`frozen`),
            `blackout`    = VALUES(`blackout`),
            `timeScale`   = VALUES(`timeScale`)
    ]], {
        TimeWeather.nowMinutes(),
        s.weather,
        s.frozen and 1 or 0,
        s.blackout and 1 or 0,
        s.timeScale,
    })
    -- Said, not swallowed: the next save tries again, but a clock that stops saving comes back at the
    -- wrong time after a restart, and this line is the only clue.
    if not ok then print('[whip_core:time] could not save the world clock: ' .. tostring(err)) end
end

--- Read the world back and anchor to it. Called once, from the startup sequence.
---
--- The stored `gameMinutes` becomes the anchor and the anchor's real time is taken as NOW, so
--- the clock resumes where it left off rather than advancing by however long the server was
--- down. Deliberate.
---@return boolean|nil ok  false when the read failed (start-up halts)
function TimeWeather.loadAll()
    local ok, rows = pcall(MySQL.query.await,
        'SELECT * FROM `whip_world` WHERE `id` = 1 LIMIT 1')
    if not ok then
        -- A failed read is not a first boot (that would overwrite the saved world with the default
        -- time). Start-up halts instead.
        print(('[whip_core:time] ERROR loading the world row: %s'):format(tostring(rows)))
        return false
    end
    local row = rows and rows[1] or nil

    if not row then
        -- First boot against this database. Anchor the configured start time and write the row,
        -- so every save after this one is a plain update.
        TimeWeather.reanchor(TimeWeather._anchor.gameMinutes)
        TimeWeather._loaded = true
        SaveState()
        return
    end

    if row.weather and TimeWeather.isValidWeather(row.weather) then
        TimeWeather.state.weather = row.weather
    end
    -- DbBool, not tonumber: the row arrives with these as booleans, and tonumber(true) is nil.
    TimeWeather.state.frozen    = DbBool(row.frozen)
    TimeWeather.state.blackout  = DbBool(row.blackout)
    TimeWeather.state.timeScale = tonumber(row.timeScale) or TimeWeather.state.timeScale

    -- Explicit value, so this is correct whether or not the clock loaded frozen.
    TimeWeather.reanchor(tonumber(row.gameMinutes) or TimeWeather._anchor.gameMinutes)
    TimeWeather._loaded = true
end

-- ============================================
-- Sync Data
-- ============================================

function TimeWeather.getSyncData()
    local hour, minute = TimeWeather.now()
    return {
        hour      = hour,
        minute    = minute,
        weather   = TimeWeather.state.weather,
        frozen    = TimeWeather.state.frozen,
        blackout  = TimeWeather.state.blackout,
        timeScale = TimeWeather.state.timeScale,
    }
end

function TimeWeather.broadcast()
    TriggerClientEvent('whip_core:client:timeSync', -1, TimeWeather.getSyncData())
end

-- ============================================
-- Setters
-- ============================================

--- A finite number, or nil: the setters' input check.
local function finite(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end
TimeWeather.finite = finite

---@return boolean ok, string|nil reason
function TimeWeather.setTime(hour, minute)
    local hn, mn = finite(hour), finite(minute or 0)
    if not hn then return false, 'hour must be a number' end
    if not mn then return false, 'minute must be a number' end
    local h = math.floor(hn) % 24
    local m = math.floor(mn) % 60

    TimeWeather.reanchor(h * 60 + m)
    TimeWeather.broadcast()
    SaveState()
    local changed = { hour = h, minute = m }
    WhipEmit('whip_core:time:changed', changed)
    return true
end

function TimeWeather.setWeather(weather)
    if type(weather) ~= 'string' then return false, 'weather must be a weather type name' end
    weather = string.upper(weather)
    if not TimeWeather.isValidWeather(weather) then
        return false, 'Invalid weather type'
    end
    TimeWeather.state.weather = weather
    TimeWeather.broadcast()
    SaveState()
    WhipEmit('whip_core:weather:changed', { weather = weather })
    return true
end

function TimeWeather.setFrozen(frozen)
    -- Read the clock BEFORE the flag moves, then anchor to what it said. Correct in both
    -- directions: freezing pins the time where it was, unfreezing restarts elapsed from now
    -- instead of crediting the clock with however long it stood still.
    local at = TimeWeather.nowMinutes()
    TimeWeather.state.frozen = frozen and true or false
    TimeWeather.reanchor(at)

    TimeWeather.broadcast()
    SaveState()
    local frozenNow = { frozen = TimeWeather.state.frozen }
    -- :freezeChanged, not :frozen — it fires for the unfreeze too.
    WhipEmit('whip_core:time:freezeChanged', frozenNow)
    return true
end

function TimeWeather.setBlackout(blackout)
    TimeWeather.state.blackout = blackout and true or false
    TimeWeather.broadcast()
    SaveState()
    return true
end

---@return boolean ok, string|nil reason
function TimeWeather.setTimeScale(scale)
    -- A scale that is not a number is refused, not read as 1.0: the caller meant something.
    local s = finite(scale)
    if not s then return false, 'scale must be a number (0 to 10)' end

    -- Same reason as setFrozen, and here it is load-bearing: the elapsed time since the last
    -- anchor is multiplied by the scale, so changing the scale without re-anchoring re-rates
    -- every millisecond of it and the clock jumps.
    local at = TimeWeather.nowMinutes()
    TimeWeather.state.timeScale = math.max(0, math.min(10, s))
    TimeWeather.reanchor(at)

    -- Broadcast now, or clients keep the old rate until the next periodic sync.
    TimeWeather.broadcast()
    SaveState()
    return true
end

-- Config.TimeScale changed in /whip → Settings: the running clock takes it now (it is otherwise
-- only the first start's, as the saved world keeps its own scale).
Settings.onChange('TimeScale', function(v)
    -- Before the saved world is read (the settings load first at boot), the scale just goes into the
    -- state the load replaces; nothing is sent or saved.
    if not TimeWeather._loaded then
        local n = tonumber(v)
        if n then TimeWeather.state.timeScale = math.max(0, math.min(10, n)) end
        return
    end
    -- A thread: setTimeScale saves the world, which waits on the database, and a hook may not wait.
    CreateThread(function()
        local ok, why = TimeWeather.setTimeScale(v)
        if not ok then print(('[whip_core:time] the clock did not take the new scale: %s'):format(tostring(why))) end
    end)
end)

-- ============================================
-- Per-Player Layers
-- ============================================
--
-- A player can carry several named layers at once — a zone, a
-- mission, the character screen — and each source clears only its own, so what was underneath
-- comes back. The client resolves them per field over the server's world state.
--
-- Set from the server when the SERVER decides (an admin tool, a scripted scene, a job). For
-- anything the client already knows about, like standing in a zone, use the client export
-- directly and skip the round trip: a layer only ever affects the one machine.

--- A layer's options, checked and copied: only what a layer can carry reaches the client.
---@return table|nil clean
---@return string|nil why
local function cleanLayer(opts)
    local c = {}
    if opts.priority ~= nil then
        c.priority = finite(opts.priority)
        if not c.priority then return nil, 'priority must be a number' end
    end
    if opts.hour ~= nil then
        local n = finite(opts.hour)
        if not n then return nil, 'hour must be a number' end
        c.hour = math.floor(n) % 24
    end
    if opts.minute ~= nil then
        local n = finite(opts.minute)
        if not n then return nil, 'minute must be a number' end
        c.minute = math.floor(n) % 60
    end
    if opts.weather ~= nil then
        if type(opts.weather) ~= 'string' or not TimeWeather.isValidWeather(string.upper(opts.weather)) then
            return nil, 'Invalid weather type'
        end
        c.weather = string.upper(opts.weather)
    end
    if opts.frozen ~= nil then c.frozen = opts.frozen and true or false end
    if opts.blackout ~= nil then c.blackout = opts.blackout and true or false end
    return c
end

local CORE = GetCurrentResourceName()

--- Set (or, with nil, clear) a named layer on one player.
---
--- A layer belongs to the resource that set it: it is cleared when that resource stops, and another
--- running resource may not replace or clear it (whip_core may: its admin tools answer for the server).
---@param source number|string|nil
---@param name string   unique per source, e.g. 'mission:heist'
---@param opts table|nil  { priority?, hour?, minute?, weather?, frozen?, blackout? }; nil clears
---@param owner string|nil  the setting resource (the exports fill it in)
---@return boolean ok, string|nil reason
function TimeWeather.setPlayerLayer(source, name, opts, owner)
    if type(name) ~= 'string' or name == '' or #name > 64 then
        return false, 'a layer needs a name (at most 64 characters)'
    end
    source = tonumber(source)
    if not source or GetPlayerName(source) == nil then return false, 'no such player' end
    owner = owner or CORE

    local owners = TimeWeather._layerOwners[source]
    local holder = owners and owners[name]
    if holder and holder ~= owner and owner ~= CORE and Registry.alive(holder) then
        return false, ('layer "%s" belongs to %s'):format(name, holder)
    end

    local clean
    if opts ~= nil then
        if type(opts) ~= 'table' then return false, 'opts must be a table, or nil to clear' end
        local why
        clean, why = cleanLayer(opts)
        if not clean then return false, why end
    end

    TimeWeather._layers[source] = TimeWeather._layers[source] or {}
    TimeWeather._layers[source][name] = clean
    TimeWeather._layerOwners[source] = owners or {}
    TimeWeather._layerOwners[source][name] = clean and owner or nil

    TriggerClientEvent('whip_core:client:weatherLayer', source, name, clean)
    return true
end

---@param source number
---@param name string
---@param owner string|nil
function TimeWeather.clearPlayerLayer(source, name, owner)
    return TimeWeather.setPlayerLayer(source, name, nil, owner)
end

-- A stopping resource's layers come off every player it set them on.
AddEventHandler('onResourceStop', function(res)
    if res == CORE then return end
    for src, owners in pairs(TimeWeather._layerOwners) do
        for name, holder in pairs(owners) do
            if holder == res then TimeWeather.setPlayerLayer(src, name, nil, CORE) end
        end
    end
end)

--- What the server believes this player is carrying. The client is the authority on what is
--- actually applied — it also holds layers the client set for itself.
function TimeWeather.getPlayerLayers(source)
    return TimeWeather._layers[source] or {}
end

--- Per-source state dies with the source, swept HERE, as every module with per-source state owns
--- its own sweep (or layers leak onto recycled server ids). No client events on a drop: there is
--- nobody to tell.
AddEventHandler('playerDropped', function()
    TimeWeather._layers[source] = nil
    TimeWeather._layerOwners[source] = nil
end)

-- ============================================
-- Threads
-- ============================================

-- One thread (nothing has to advance the clock), with two intervals inside it, deliberately
-- separate: the save has a constant of its own that a change to Config.TimeSyncInterval can't move.
local SAVE_EVERY_MS = 300000   -- 5 minutes. Independent of TimeSyncInterval, on purpose.

-- On Every (lifecycle.lua), so one error doesn't end the broadcast and its save.
-- The interval is read at each pass, so a change in /whip → Settings takes effect from the next
-- one. The save is timed rather than counted in intervals: an interval that changes in between
-- would be counted as the new length, not the one actually waited.
local lastSaveAt = GetGameTimer()
Every('world clock broadcast', function() return Config.TimeSyncInterval or 5000 end, function()
    TimeWeather.broadcast()

    -- The periodic save is crash insurance, and nothing else: every setter writes at once and a clean
    -- stop writes below. An anchor last written hours ago would come back hours stale after a crash;
    -- re-anchoring on a timer bounds that at five minutes.
    --
    -- Frozen time cannot go stale — the anchor already IS the answer — so there is nothing
    -- to write. (Nor is anything written before the saved world has been read: SaveState.)
    if GetGameTimer() - lastSaveAt >= SAVE_EVERY_MS then
        lastSaveAt = GetGameTimer()
        if not TimeWeather.state.frozen then SaveState() end
    end
end)

-- The last save, so a planned restart resumes exactly rather than up to five minutes behind.
--
-- Dispatched, not confirmed: a handler for our own onResourceStop can't be resumed, but
-- MySQL.update.await hands the query to the JS runtime before it awaits, so the write lands (as the
-- vehicle stat flush in server/vehicle_stats.lua). Step 90 of whip_core's stop (server/lifecycle.lua):
-- last, because it waits.
CoreStop.add(90, 'world clock: save', function()
    SaveState()
end)

-- Step 70 of the final save (server/lifecycle.lua): last, the least to lose.
FinalSave.add(70, 'world clock', function()
    SaveState()
end)

-- ============================================
-- Time & Weather — Server Exports
-- ============================================

-- Derived on read, not stored: see TimeWeather.now.
exports('GetTime', function() return TimeWeather.now() end)
exports('GetWeather', function() return TimeWeather.state.weather end)
exports('IsTimeFrozen', function() return TimeWeather.state.frozen end)
exports('GetTimeScale', function() return TimeWeather.state.timeScale end)
exports('IsBlackout', function() return TimeWeather.state.blackout == true end)
-- (true) or (false, reason) from every setter. And they wait for whip_core to finish starting, as
-- every Ensure* does: a change before the saved world is read would be thrown away by the load.
local function whenReady(fn)
    return function(...)
        if not WaitForCoreReady() then return false, NOT_READY end
        return fn(...)
    end
end
exports('SetTime', whenReady(function(h, m) return TimeWeather.setTime(h, m) end))
exports('SetWeather', whenReady(function(w) return TimeWeather.setWeather(w) end))
exports('SetFrozen', whenReady(function(f) return TimeWeather.setFrozen(f) end))
exports('SetBlackout', whenReady(function(b) return TimeWeather.setBlackout(b) end))
exports('SetTimeScale', whenReady(function(s) return TimeWeather.setTimeScale(s) end))

--- Push a named time/weather layer onto one player.
---
--- Several can be active at once and each clears independently, so a mission storm ending
--- restores the zone fog that was underneath it rather than clearing the lot. Resolution is
--- per field: a layer that sets only `weather` leaves the time to whatever is below it.
---
--- For anything the CLIENT already knows about — standing in a zone, opening a menu — use the
--- client export of the same name instead and skip the round trip. A layer only ever affects
--- the one machine, so there is nothing to protect.
---@param src number
---@param name string     unique per source, e.g. 'mission:heist'
---@param opts table|nil  { priority?, hour?, minute?, weather?, frozen?, blackout? }; nil clears
exports('SetPlayerWeatherLayer', function(src, name, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    return TimeWeather.setPlayerLayer(src, name, opts, owner)
end)

exports('ClearPlayerWeatherLayer', function(src, name)
    local owner = Registry.caller()
    return TimeWeather.clearPlayerLayer(src, name, owner)
end)

exports('GetPlayerWeatherLayers', function(src)
    return TimeWeather.getPlayerLayers(src)
end)
