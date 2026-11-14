-- ============================================
-- PlayerStats — Unified stat & effect system
-- Server-authoritative for framework changes.
-- GTA ped native owns combat damage.
-- ============================================

Stats = {}
Stats._registry    = {}   -- [name] = config (a COPY of what the caller passed — see register)
Stats._owners      = {}   -- [name] = resource that registered it
Stats._cache       = {}   -- [source] = { [name] = value }
Stats._recentSets  = {}   -- [source] = { [name] = gameTimer }
Stats._effects     = {}   -- [source] = { [name] = effectData }
Stats._changeLog   = {}   -- [source] = capped list of recent changes, oldest trimmed
Stats._debugViewers = {}  -- [source] = true (players with debug overlay on)
Stats._lastDecay   = {}   -- [source] = { [name] = lastTickTime }
Stats._spawnGuard  = {}   -- [source] = gameTimer (10s immunity after respawn/revive)
Stats._stored      = {}   -- [source] = { [name] = value } — the statuses column as loaded (see initPlayer)
Stats._underwater  = {}   -- [source] = true while their game says they are under water (reportVitals; oxygen's tick)

local CHANGE_LOG_MAX = 20

-- ============================================
-- Registration
-- ============================================

--- The stats whip_core itself defines and owns: a satellite may not replace them.
Stats.ReservedNames = { health = true, armour = true, oxygen = true, developer = true }

--- Broadcast HUD defs to everyone online. Registering and unregistering both change what the
--- HUD should draw, so both call this.
local function broadcastHudDefs()
    if next(Players) == nil then return end
    local defs = Stats.getHudDefs()
    for src in pairs(Players) do
        TriggerClientEvent('whip_core:client:hudDefs', src, defs)
    end
end

--- The stat registry, on the one registration rule (shared/registry.lua): the same definition again
--- is a no-op (satellites re-register on every whip_core:onReady), and only a real change
--- rebroadcasts the HUD definitions. A stopping resource's stats go with it (onRemove below).
local _stats = Registry.new('Stat', {
    label = 'stat',
    store = Stats._registry,
    prefixed = true,   -- one list for the server (shared/registry.lua)
    onAdd = function(name, entry, owner, old)
        Stats._owners[name] = owner

        -- A stat registered AFTER players loaded (a satellite starting late, or restarting) starts
        -- them at their STORED value rather than the default — initPlayer could not load what was
        -- not registered yet, and the next save would otherwise have written the default over it.
        if (entry.type == 'need' or entry.type == 'custom') then
            for src, cache in pairs(Stats._cache) do
                if cache[name] == nil then
                    local stored = Stats._stored[src] and Stats._stored[src][name]
                    cache[name] = (entry.persist and tonumber(stored)) or entry.default
                end
            end
        end

        if entry.hud or (old and old.hud) then broadcastHudDefs() end
    end,
    onRemove = function(name, entry, owner, why)
        Stats._owners[name] = nil
        if entry and entry.hud then broadcastHudDefs() end
        if why == 'stopped' then
            print(('[whip_core:stats] dropped stat "%s" — %s stopped'):format(name, owner))
        end
    end,
})

--- Register a stat type. Called from config (built-ins) or exports (external resources).
---
--- Validates, refuses, and copies:
---   * the caller's table is copied, never kept (the registry would alias a table the satellite
---     still owns, or Config.Stats itself).
---   * reserved names and foreign re-registration are refused with a reason. Re-registering
---     your OWN stat stays allowed; that is what a hot restart looks like.
---   * `decay = 0` is treated as no decay. 0 is truthy in Lua, so it would otherwise run the
---     decay branch every interval and add nothing.
---@param name string
---@param config table  { type, default, min, max, persist, decay, decayInterval, thresholds, hud }
---@param owner string|nil  resource name; defaults to the caller
---@return boolean ok
---@return string|nil err
function Stats.register(name, config, owner)
    if type(name) ~= 'string' or name == '' then
        return false, 'a stat needs a name'
    end
    if type(config) ~= 'table' then
        return false, ('stat "%s": expected a config table'):format(name)
    end

    owner = owner or GetCurrentResourceName()

    if Stats.ReservedNames[name] and owner ~= GetCurrentResourceName() then
        return false, ('stat "%s" is owned by whip_core'):format(name)
    end

    -- A type whip knows: only 'need' and 'custom' are loaded and saved, so a typo ('needs') would
    -- reset at every login. 'vital' is whip_core's own (health, armour).
    local statType = config.type or 'custom'
    if statType ~= 'need' and statType ~= 'custom'
        and not (statType == 'vital' and owner == GetCurrentResourceName()) then
        return false, ('stat "%s": type is \'need\' or \'custom\', not "%s"'):format(name, tostring(statType))
    end

    local entry = {
        name          = name,
        type          = statType,
        default       = tonumber(config.default) or 0,
        min           = tonumber(config.min) or 0,
        max           = tonumber(config.max) or 100,
        persist       = config.persist ~= false,
        decay         = tonumber(config.decay),
        decayInterval = tonumber(config.decayInterval) or 10,
        thresholds    = nil,
        hud           = nil,
    }

    if entry.decay == 0 then entry.decay = nil end

    if type(config.thresholds) == 'table' then
        entry.thresholds = {}
        for i, t in ipairs(config.thresholds) do
            -- Refused here rather than discovered by the tick: a threshold without a numeric
            -- `value` would throw inside it.
            if type(t) ~= 'table' or type(t.stat) ~= 'string'
                or tonumber(t.delta) == nil or tonumber(t.value) == nil then
                return false, ('stat "%s": threshold %d needs { stat = <name>, delta = <number>, value = <number> }')
                    :format(name, i)
            end
            entry.thresholds[i] = {
                stat  = t.stat,
                delta = tonumber(t.delta),
                value = tonumber(t.value),
                below = t.below,
            }
        end
    end

    if type(config.hud) == 'table' then
        entry.hud = {
            color         = config.hud.color,
            icon          = config.hud.icon,
            iconCritical  = config.hud.iconCritical,
            order         = tonumber(config.hud.order) or 99,
            heartbeat     = config.hud.heartbeat or false,
            hideWhenEmpty = config.hud.hideWhenEmpty or false,
            noCritical    = config.hud.noCritical or false,
            showAboveZero = config.hud.showAboveZero or false,
            -- Shown only while the stat is under its maximum: a reserve that is usually full (oxygen).
            showBelowFull = config.hud.showBelowFull or false,
            -- Moves between readings at a steady speed, not step by step: a stat the tick moves each second (oxygen).
            glide         = config.hud.glide or false,
            -- An allow-list, one of two: a hud option must be named HERE (what the registry keeps)
            -- and in Stats.getHudDefs below (what is sent to clients), or it is dropped in silence.
            --
            -- interruptDelta: how far this stat may move, in DISPLAY PERCENT, while the capsule is
            -- busy with chat or a notification before the gauge pushes back on screen. nil when
            -- unset: never interrupt.
            interruptDelta = tonumber(config.hud.interruptDelta) or nil,
        }
    end

    -- Ownership, the no-op and the broadcast are the registry's (_stats above).
    local ok, why = _stats:add(owner, name, entry)
    if not ok then return false, why --[[@as string]] end
    return true
end

--- Drop a stat from the registry, and take its gauge off everyone's HUD. Internal (whip_test's
--- seam); a stopping resource's stats are dropped by the registry's sweep.
---
--- Per-player cache values are left alone on purpose: getForSave and the tick both walk the
--- REGISTRY, so an unregistered stat's leftover number is inert and clears on relog.
---@param name string
function Stats.unregister(name)
    local owner = Stats._owners[name]
    if owner then _stats:remove(owner, name) end
end

--- A gauge's place, left to right: its place in Config.StatOrder (the drag in /whip → Settings), and after
--- every listed one, by its own hud.order, a stat the list does not name (a resource's new stat).
---@param name string
---@param config table  the registered stat
---@return number
local function hudPlace(name, config)
    for i, listed in ipairs(Config.StatOrder or {}) do
        if listed == name then return i end
    end
    return 1000 + (config.hud.order or 99)
end

--- Get HUD definitions for all stats with a hud field.
--- Returns an ordered array, left to right (hudPlace).
---@return table[]
function Stats.getHudDefs()
    local defs = {}
    for name, config in pairs(Stats._registry) do
        if config.hud then
            defs[#defs + 1] = {
                name          = name,
                type          = config.type,
                max           = config.max,
                color         = config.hud.color,
                icon          = config.hud.icon,
                iconCritical  = config.hud.iconCritical,
                order         = hudPlace(name, config),
                heartbeat     = config.hud.heartbeat or false,
                hideWhenEmpty = config.hud.hideWhenEmpty or false,
                noCritical    = config.hud.noCritical or false,
                showAboveZero = config.hud.showAboveZero or false,
                showBelowFull = config.hud.showBelowFull or false,
                glide         = config.hud.glide or false,
                -- The second allow-list (see Stats.register): register decides what is kept, this
                -- what is sent, deliberately separate.
                interruptDelta = config.hud.interruptDelta,
            }
        end
    end
    -- Never true for a stat against itself (Lua's sort compares its pivot with itself); a tie goes by name.
    table.sort(defs, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    return defs
end

--- Every registered stat an admin may set, by name: { name, min, max, owner }. The object viewer's Adjust Stats
--- (server/object_viewer.lua). Not `developer`: that one follows developer mode alone.
---@return table[]
function Stats.listDefs()
    local out = {}
    for name, config in pairs(Stats._registry) do
        if name ~= 'developer' then
            out[#out + 1] = { name = name, min = config.min, max = config.max, owner = _stats:ownerOf(name) }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ============================================
-- whip's own stats
-- ============================================
--
-- Not settings: config.lua has whether hunger and thirst are on (Config.Hunger, Config.Thirst), how many
-- minutes each takes to drain (Config.HungerMinutes, Config.ThirstMinutes), the gauges' order
-- (Config.StatOrder) and how big a drop flashes health or armour back on screen (Config.StatHitFlash). The
-- rest is here; a gauge's colour is its own (the classic HUD skin draws it; the black skin does not).

local ICONS = {
    health = 'M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z',
    armour = 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z',
    -- Shown instead when armour is nearly gone: a cracked vest. Extra paths are split by a pipe.
    armourCracked = 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z|M11 5 L10 8 L12.5 10 L10.5 14 L12 17|M10 8 L8 9.5|M12.5 10 L15 10.5|M12.5 10 L13.5 8|M10.5 14 L8.5 15|M10.5 14 L9 12.5|M12 17 L14 18',
    hunger = 'M11 9H9V2H7v7H5V2H3v7c0 2.12 1.66 3.84 3.75 3.97V22h2.5v-9.03C11.34 12.84 13 11.12 13 9V2h-2v7zm5-3v8h2.5v8H21V2c-2.76 0-5 2.24-5 4z',
    thirst = 'M12 2c-5.33 4.55-8 8.48-8 11.8 0 4.98 3.8 8.2 8 8.2s8-3.22 8-8.2c0-3.32-2.67-7.25-8-11.8z',
    -- A terminal's prompt: the arrow and the cursor (developer mode).
    developer = 'M2.97 6.13 5.23 3.87 13.36 12l-8.13 8.13-2.26-2.26L8.84 12z M14.1 16.9h7v3.2h-7z',
    -- Air bubbles rising: two rings (each drawn round, then its hole the other way) and a dot.
    oxygen = 'M3.5 15a5.5 5.5 0 1 0 11 0a5.5 5.5 0 1 0-11 0z M5.5 15a3.5 3.5 0 1 1 7 0a3.5 3.5 0 1 1-7 0z'
          .. ' M13.5 7.5a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0-7 0z M15 7.5a2 2 0 1 1 4 0a2 2 0 1 1-4 0z'
          .. ' M7 4a2 2 0 1 0 4 0a2 2 0 1 0-4 0z',
}

--- Hunger or thirst. On: drains every 10 seconds at whatever empties a full one in `minutes` (120 minutes
--- is about 0.14 a step), is saved, has a gauge, and costs Config.NeedDamage health a step once under 10 (0: none).
---
--- Off is no hunger at all, but the stat is still registered: food is still eaten, and a script or
--- Systems card reading it gets 100. No gauge, no drain, no cost, and nothing saved (so turning it back
--- on starts everyone full).
---@param on boolean
---@param minutes number  full to empty
---@param icon string
---@param color string
---@return table
local function need(on, minutes, icon, color)
    if not on then return { type = 'need', default = 100, min = 0, max = 100, persist = false } end
    local steps = math.max(1.0, (tonumber(minutes) or 120) * 6)   -- six 10-second steps a minute
    local damage = math.max(0, tonumber(Config.NeedDamage) or 1)
    return {
        type = 'need', default = 100, min = 0, max = 100, persist = true,
        decay = -100 / steps, decayInterval = 10,
        thresholds = damage > 0 and { { value = 10, below = true, stat = 'health', delta = -damage } } or nil,
        hud = { icon = icon, color = color },
    }
end

--- whip's own six, as the settings have them now.
---@return table<string, table>
local function builtInStats()
    local flash = Config.StatHitFlash or {}
    return {
        -- Oxygen, the server's like hunger: each player's game says only whether they are under water
        -- (reportVitals), and the stat tick moves the number — down under water (full to empty in
        -- Config.OxygenSeconds), back up above it (Config.OxygenRecoverPerSecond a second), each step a logged,
        -- synced change like any decay (tickOxygen). The game drowns the player when it is gone: client/stats.lua
        -- gives the ped the game's longest breath while whip's lasts and none at 0, so a death under water still
        -- reads as drowning. SetStat and AddStat work (a scuba tank could top it up). Never saved; a revive or
        -- respawn is full. The gauge shows only while it is not full, red and beating under a fifth.
        oxygen = {
            type = 'custom', default = 100, min = 0, max = 100, persist = false,
            -- glide: the tick moves it a step a second, and the gauge drains as one steady motion between them.
            hud = { icon = ICONS.oxygen, color = '#22d3ee', showBelowFull = true, heartbeat = true, glide = true },
        },
        -- Developer mode's mark, not a measure: 1 while developer mode is on (server/devtools_base.lua), 0 with
        -- no gauge otherwise. Never saved (developer mode is off at every join). Only developer mode sets it
        -- (Stats.showDeveloper).
        developer = {
            type = 'custom', default = 0, min = 0, max = 1, persist = false,
            -- The house's warning amber (--ui-warning), as the /w switch wears it. showAboveZero, not
            -- hideWhenEmpty (which only fades a gauge to a quarter).
            hud = { icon = ICONS.developer, color = '#fbbf24', showAboveZero = true, noCritical = true },
        },
        health = {
            type = 'vital', default = 200, min = 0, max = 200, persist = true,
            hud = {
                icon = ICONS.health, color = '#34d399',
                heartbeat = true,   -- the icon pulses when health is low
                -- Come back on screen after a drop this big (display percent, against what the player last
                -- saw) while chat or a notification has the capsule. nil: never (Config.StatHitFlash).
                interruptDelta = tonumber(flash.health),
            },
        },
        armour = {
            type = 'vital', default = 0, min = 0, max = 100, persist = true,
            hud = {
                icon = ICONS.armour, iconCritical = ICONS.armourCracked, color = '#818cf8',
                hideWhenEmpty = true,   -- no armour, no gauge; the hit flash beats it, so armour running out shows
                interruptDelta = tonumber(flash.armour),
            },
        },
        hunger = need(Config.Hunger == true, Config.HungerMinutes, ICONS.hunger, '#fb923c'),
        thirst = need(Config.Thirst == true, Config.ThirstMinutes, ICONS.thirst, '#38bdf8'),
    }
end

--- Register whip's own stats and this server's (Config.Stats), or only those named in `only`. Again after a
--- setting changes: the same owner registering a changed stat replaces it, and every player's HUD follows.
---@param only table|nil  { [name] = true }
local function registerOwn(only)
    local own = builtInStats()
    for name, def in pairs(Config.Stats or {}) do
        if own[name] then
            print(('[whip_core:stats] Config.Stats.%s ignored: %s is one of whip\'s own stats'):format(name, name))
        else
            own[name] = def
        end
    end
    for name, def in pairs(own) do
        if not only or only[name] then
            local ok, err = Stats.register(name, def, GetCurrentResourceName())
            if not ok then print(('[whip_core:stats] stat %s refused: %s'):format(name, tostring(err))) end
        end
    end
end

-- On load, the next tick, once every server file has run. (Not for config.lua: it is a shared script and loaded
-- before any of them.)
CreateThread(function()
    Wait(0)
    registerOwn()
end)

-- Hunger or thirst turned on or off in /whip → Settings: registered again. Turned off, everyone online is put
-- back to full, so "no hunger" is never a player stuck half-hungry with nothing to show it.
for _, name in ipairs({ 'hunger', 'thirst' }) do
    local path = name == 'hunger' and 'Hunger' or 'Thirst'
    Settings.onChange(path, function(on)
        registerOwn({ [name] = true })
        if on then return end
        for source in pairs(Stats._cache) do
            if Players[source] then Stats.set(source, name, 100, 'settings') end
        end
    end)
    -- A new drain time: registered again, and everyone drains at it from their next step. Nobody's level moves.
    Settings.onChange(path .. 'Minutes', function() registerOwn({ [name] = true }) end)
end
-- What an empty one costs: both registered again, so the next step under 10% costs the new amount.
Settings.onChange('NeedDamage', function() registerOwn({ hunger = true, thirst = true }) end)
Settings.onChange('StatHitFlash', function() registerOwn({ health = true, armour = true }) end)
Settings.onChange('StatOrder', function() broadcastHudDefs() end)

-- What the Stats page's gauge row offers to drag (/whip → Settings, Config.StatOrder): every stat with a gauge
-- now, and whip's own that have none while they are off, so their place can be set before they are on.
Settings.setChoices('StatOrder', function()
    local out, seen = {}, {}
    local function add(name, def, off)
        if seen[name] or not def.hud then return end
        seen[name] = true
        out[#out + 1] = { name = name, icon = def.hud.icon, color = def.hud.color, off = off or nil }
    end
    for name, def in pairs(Stats._registry) do add(name, def) end
    add('hunger', need(true, Config.HungerMinutes, ICONS.hunger, '#fb923c'), true)
    add('thirst', need(true, Config.ThirstMinutes, ICONS.thirst, '#38bdf8'), true)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end)

--- Every stat this player has, for their page in /whip (the Player Manager's Current Stats): the value and range,
--- and the gauge as their HUD draws it (Stats.getHudDefs' shape), whether it is on their HUD or not.
---   active    it has a gauge now. Hunger and thirst turned off still bring the gauge they have when on.
---   readOnly  the developer mark: it follows developer mode alone (Stats.set refuses it).
--- In the HUD's order, then the stats with no gauge at all, by name. nil when the player is not loaded.
---@param source number
---@return table[]|nil
function Stats.adminRows(source)
    local cache = Stats._cache[source]
    if not cache then return nil end
    local hudOf = {}
    for _, d in ipairs(Stats.getHudDefs()) do hudOf[d.name] = d end
    local whenOn = {
        hunger = need(true, Config.HungerMinutes, ICONS.hunger, '#fb923c'),
        thirst = need(true, Config.ThirstMinutes, ICONS.thirst, '#38bdf8'),
    }
    local rows = {}
    for name, config in pairs(Stats._registry) do
        local hud = hudOf[name]
        local active = hud ~= nil
        if not hud and whenOn[name] then
            local h = whenOn[name].hud
            hud = { name = name, type = config.type, max = config.max, color = h.color, icon = h.icon,
                    order = hudPlace(name, whenOn[name]) }
        end
        rows[#rows + 1] = {
            name = name, type = config.type, min = config.min, max = config.max,
            value = tonumber(cache[name]) or config.default,
            active = active, hud = hud, owner = _stats:ownerOf(name),
            readOnly = name == 'developer' or nil,
        }
    end
    table.sort(rows, function(a, b)
        local pa, pb = a.hud and a.hud.order or 5000, b.hud and b.hud.order or 5000
        if pa ~= pb then return pa < pb end
        return a.name < b.name
    end)
    return rows
end

-- ============================================
-- Player Init / Cleanup
-- ============================================

--- Initialize stats for a player from DB-loaded character data.
--- Called from LoadCharacterForPlayer with the decoded statuses table.
---@param source number
---@param charData table  { health, armour, statuses (decoded table) }
function Stats.initPlayer(source, charData)
    Stats._cache[source] = {}
    Stats._recentSets[source] = {}
    Stats._effects[source] = {}
    Stats._changeLog[source] = {}
    Stats._lastDecay[source] = {}

    -- Load vitals into cache with timestamp guard.
    -- This prevents early client reportVitals (ped hasn't spawned yet,
    -- reports 0/0) from overwriting the DB-loaded values.
    Stats._cache[source].health = charData.health or 200
    Stats._cache[source].armour = charData.armour or 0
    Stats._recentSets[source].health = GetGameTimer()
    Stats._recentSets[source].armour = GetGameTimer()
    Stats._spawnGuard[source] = GetGameTimer()

    -- Load needs/custom from DB statuses. `persist` is checked here as well as in getForSave: a stat
    -- that is not saved must not be loaded either, or it would be frozen at the last value written.
    local statuses = charData.statuses or {}

    -- What was on disk, kept: getForSave writes the statuses column wholesale, so an unregistered
    -- stat (its satellite stopped, or late) is carried forward untouched, and a stat registered after
    -- this player loaded can still be given its stored value (see Stats.register).
    Stats._stored[source] = {}
    for k, v in pairs(statuses) do Stats._stored[source][k] = v end

    for name, config in pairs(Stats._registry) do
        if config.type == 'need' or config.type == 'custom' then
            if config.persist and statuses[name] ~= nil then
                Stats._cache[source][name] = statuses[name]
            else
                Stats._cache[source][name] = config.default
            end
        end
    end
end

--- Clean up all stat data for a player leaving their character (logout or disconnect).
---
--- Each effect's onRemove runs first, with `effect.reason` = why. Called while Players[source]
--- still holds the character, so the callback gets its sheet. The
--- teardowns end the effects before their save (Stats.endEffects), so normally none are left here.
---@param source number
---@param why string|nil  'logout' (default) | 'disconnect'
function Stats.cleanupPlayer(source, why)
    Stats.endEffects(source, why)

    Stats._cache[source] = nil
    Stats._recentSets[source] = nil
    Stats._effects[source] = nil
    Stats._changeLog[source] = nil
    Stats._lastDecay[source] = nil
    Stats._debugViewers[source] = nil
    Stats._spawnGuard[source] = nil
    Stats._stored[source] = nil
    Stats._underwater[source] = nil
end

--- Start this player's spawn guard, from now: for 10 seconds the stat tick fires no thresholds or
--- effects for them, so the health just given (a revive, a respawn) is not taken straight back.
--- MarkPlayerAlive calls it.
---@param source number
function Stats.guardSpawn(source)
    Stats._spawnGuard[source] = GetGameTimer()
end

--- A full breath, on dry land (builtInStats' oxygen): a drowned player comes back breathing. MarkPlayerAlive calls
--- it; their game says again whether they are under water with its next report.
---@param source number
---@param why string|nil  the change log's label
function Stats.freshBreath(source, why)
    Stats._underwater[source] = nil
    if Stats._registry.oxygen and Stats._cache[source] then Stats.set(source, 'oxygen', 100, why or 'revive') end
end

--- Freeze every player's vitals for the resource stop: reportVitals is ignored from here on, so the
--- final save writes what the cache held. Step 10 of whip_core's stop calls it.
function Stats.freeze()
    Stats._frozen = true
end

--- End a leaving character's effects: every onRemove runs, with `reason` = why.
---
--- Before the teardown save, so a persisted stat an onRemove sets is in it. Logout and disconnect
--- call this before SafeSavePlayer; cleanupPlayer calls it again for anything applied since.
---@param source number
---@param why string|nil  'logout' (default) or 'disconnect'
function Stats.endEffects(source, why)
    local effects = Stats._effects[source]
    if not effects then return end
    -- Detached first: an onRemove that applies a follow-on effect starts a new table, which
    -- cleanupPlayer ends in turn.
    Stats._effects[source] = nil
    for _, effect in pairs(effects) do
        if effect.onRemove then
            local view = Stats._effectFor(effect)
            view.reason = why or 'logout'
            local ok, err = pcall(effect.onRemove, source, Stats._playerFor(source, effect), view)
            if not ok then
                print(('[whip_core:stats] onRemove of "%s" errored at %s: %s')
                    :format(tostring(effect.name), why or 'logout', tostring(err)))
            end
        end
    end
end

-- ============================================
-- Getters / Setters
-- ============================================

--- Get a stat value from the server cache.
---@param source number
---@param name string
---@return number|nil
function Stats.get(source, name)
    local cache = Stats._cache[source]
    if not cache then return nil end
    return cache[name]
end

--- Get all stats for a player.
---@param source number
---@return table|nil
function Stats.getAll(source)
    local cache = Stats._cache[source]
    if not cache then return nil end
    local result = {}
    for k, v in pairs(cache) do
        result[k] = v
    end
    return result
end

--- A usable number: tonumber'd, and not NaN or infinite. nil for anything else.
---@param v any
---@return number|nil
local function finite(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

--- True only inside Stats.showDeveloper: the one writer the `developer` stat takes.
local developerWrite = false

--- Set a stat value. Validates, clamps, caches, timestamps, syncs to client.
---
--- Answers, and refuses what it cannot use: a value that is not a number, and an unregistered name
--- (never saved, so a typo would work for one session only).
---@param source number
---@param name string
---@param value number|string|nil
---@param changeSource string|nil  Source of change for debug log (e.g., 'item:food', 'effect:poison')
---@return boolean ok
---@return string|nil err
---@param pedDelta number|nil  INTERNAL (Stats.add): a vital's change as an amount — see there
function Stats.set(source, name, value, changeSource, pedDelta)
    local cache = Stats._cache[source]
    if not cache then return false, 'Player not loaded' end

    local config = Stats._registry[name]
    if not config then
        return false, ('no stat named "%s" (RegisterStat it first)'):format(tostring(name))
    end
    -- The developer mark is developer mode's alone (Stats.showDeveloper): SetStat, a Systems card or an
    -- admin page setting it would fake the mark, or hide it from a developer's stream.
    if name == 'developer' and not developerWrite then
        return false, 'the developer stat follows developer mode (/w) and nothing else'
    end

    value = finite(value)
    if not value then return false, 'value must be a number' end

    local old = finite(cache[name]) or config.default
    value = math.max(config.min, math.min(config.max, value))
    cache[name] = value

    -- Timestamp guard for vitals (protects against ped read overwrite)
    if config.type == 'vital' then
        if not Stats._recentSets[source] then Stats._recentSets[source] = {} end
        Stats._recentSets[source][name] = GetGameTimer()
    end

    -- Vitals are applied to the ped on the CLIENT side via the
    -- 'whip_core:client:statUpdate' event (handled in client/stats.lua).
    -- Server cannot call SetEntityHealth/SetPedArmour — those are client natives.

    -- Log the change
    local delta = value - old
    if delta ~= 0 then
        Stats._logChange(source, name, delta, changeSource or 'direct')
    elseif config.type ~= 'vital' then
        -- Nothing moved, so nothing to send or save. Vitals are exempt: setting health to the value
        -- the server already holds is how a ped that drifted gets put back.
        return true
    end

    -- The character row now needs writing (PlayerRows.flush): a single table assignment, since this
    -- line is hot. Only for stats that actually persist (what getForSave writes). Guarded on
    -- PlayerRows so the file loads in either order.
    if PlayerRows and PlayerRows.markDirty then
        if name == 'health' or name == 'armour' then
            PlayerRows.markDirty(source)
        elseif (config.type == 'need' or config.type == 'custom') and config.persist then
            -- With the next position sweep (every 30 s by default), not at once: see PlayerRows.markSoon
            PlayerRows.markSoon(source)
        end
    end

    -- Sync to client. A vital changed BY an amount goes as that amount (see Stats.add).
    Stats._syncStat(source, name, value, config.type == 'vital' and pedDelta or nil)

    -- And to anyone on the server listening (OnStatChange). A vital re-set to the same value is
    -- a correction, not a change, so it is not announced.
    if delta ~= 0 then Stats._announce(source, name, value, old, changeSource or 'direct') end
    return true
end

--- Put the developer mark on this player's HUD, or take it off. For developer mode (server/devtools_base.lua)
--- only: Stats.set refuses the stat to everyone else. Answers as Stats.set does ('Player not loaded' on the
--- character screen — Character 'loaded' puts it on then).
---@param source number
---@param on boolean
---@return boolean ok, string|nil err
function Stats.showDeveloper(source, on)
    -- Config.HudDeveloperMark false: no mark at all (filming with developer mode on, Josh, 1 Nov).
    if on and Config.HudDeveloperMark == false then on = false end
    developerWrite = true
    local ok, set, why = pcall(Stats.set, source, 'developer', on and 1 or 0, 'developer mode')
    developerWrite = false
    if not ok then return false, tostring(set) end
    return set, why
end

--- Add to a stat value (convenience wrapper). Answers as Stats.set does; a delta that is not a
--- number is refused here rather than thrown on as `current + nil`.
---@param source number
---@param name string
---@param delta number|string|nil
---@param changeSource string|nil
---@return boolean ok
---@return string|nil err
---
--- A vital (health, armour) is changed BY the amount on the ped itself: the cache trails the ped by
--- the report interval, so an absolute would put back damage taken in that window. The client adds
--- the amount to the ped's live value and reports the result. Absolute sets (revive, respawn, admin)
--- go through Stats.set.
function Stats.add(source, name, delta, changeSource)
    delta = finite(delta)
    if not delta then return false, 'amount must be a number' end
    local current = finite(Stats.get(source, name))
    if current == nil then
        local config = Stats._registry[name]
        current = config and config.default or 0
    end
    return Stats.set(source, name, current + delta, changeSource, delta)
end

-- ============================================
-- Change listeners
-- ============================================

--- Server-side stat subscribers: [statName or '*']['<resource>:<id>'] = { fn, owner, asTable }.
---
--- The server half of OnStatChange, the same shape as the client's and OnVehicleStatChange: keyed by
--- `<resource>:<id>` (so the onReady re-fire replaces rather than stacks), the owner kept with the
--- callback, swept when the owner stops.
Stats._listeners = {}

--- [source .. '|' .. name] = true while that stat's listeners are running. See Stats._announce.
local _announcing = {}

--- Call one listener, positional or one table as it registered.
---@param reg table
---@param wildcard boolean
local function callListener(reg, wildcard, source, name, value, old, reason)
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, { source = source, key = name, value = value, old = old, reason = reason })
    elseif wildcard then
        ok, err = pcall(reg.fn, source, name, value, old, reason)
    else
        ok, err = pcall(reg.fn, source, value, old, reason)
    end
    if not ok then
        print(('[whip_core:stats] OnStatChange listener (%s) for "%s" errored: %s')
            :format(tostring(reg.owner), name, tostring(err)))
    end
end

--- Tell the listeners one stat moved. Called by Stats.set and by the vitals report (combat damage
--- writes the cache directly), which between them are every path a stat changes by.
---
--- Keyed by name, so a hunger decay tick costs a table lookup and nothing more unless someone is
--- listening to hunger (or to '*', which asked for everything).
---
--- Not re-entered for the same stat: a listener that sets the stat it is listening to (clamping it,
--- say) would otherwise call itself for as long as the value kept moving. The nested set still
--- happens and is still saved and synced; it is just not announced while that stat's listeners
--- are already running for that player.
---@param source number
---@param name string
---@param value number
---@param old number|nil
---@param reason string|nil
function Stats._announce(source, name, value, old, reason)
    local named, wild = Stats._listeners[name], Stats._listeners['*']
    if not named and not wild then return end

    local guard = source .. '|' .. name
    if _announcing[guard] then return end
    _announcing[guard] = true
    if named then
        for _, reg in pairs(named) do callListener(reg, false, source, name, value, old, reason) end
    end
    if wild then
        for _, reg in pairs(wild) do callListener(reg, true, source, name, value, old, reason) end
    end
    _announcing[guard] = nil
end

AddEventHandler('onResourceStop', function(res)
    for name, listeners in pairs(Stats._listeners) do
        for key, reg in pairs(listeners) do
            if reg.owner == res then listeners[key] = nil end
        end
        if next(listeners) == nil then Stats._listeners[name] = nil end
    end
end)

-- In GetRegistrations with the registries (Registry.addLister).
Registry.addLister('statListener', function()
    local out = {}
    for name, listeners in pairs(Stats._listeners) do
        for key, reg in pairs(listeners) do out[#out + 1] = { key = name .. ' ' .. tostring(key), owner = reg.owner } end
    end
    return out
end)

--- whip_core's OWN files hear a stat change here (the Systems Creator's "a player is hurt"), on the
--- path OnStatChange's listeners take (Stats._announce: every set, and the vitals report combat
--- damage comes by). `fn({ source, key, value, old, reason })` must not wait. Keyed `whip_core:<id>`:
--- the same id again replaces it.
---@param name string  a stat's name, or '*'
---@param id string
---@param fn function
function Stats.onChange(name, id, fn)
    local list = Stats._listeners[name]
    if not list then list = {}; Stats._listeners[name] = list end
    local owner = GetCurrentResourceName()
    list[('%s:%s'):format(owner, tostring(id))] = { fn = fn, owner = owner, asTable = true }
end

-- ============================================
-- Effect System
-- ============================================

-- An effect's onApply, onRemove or onTick that throws is said once per effect, callback and error, filed under the
-- resource that applied it (ErrorTap.caught: GetErrorLog lists it as theirs), never swallowed. Once, because onTick
-- runs every tick.
local _saidEffectError = {}
local function effectFailed(effect, name, which, err)
    local key = ('%s|%s|%s|%s'):format(tostring(effect.resource), tostring(name), which, tostring(err))
    if _saidEffectError[key] then return end
    _saidEffectError[key] = true
    ErrorTap.caught(('[whip_core:stats] ERROR in %s\'s effect "%s" %s: %s')
        :format(tostring(effect.resource), tostring(name), which, tostring(err)), effect.resource)
end

--- Apply a temporary effect to a player.
---
--- A second apply under the same name REPLACES the effect — nothing stacks. `replaceSilently = true`
--- skips the replaced instance's onRemove; by default it fires first.
---
--- Whose effect it is comes from `owner`, never from the config (a caller could otherwise claim to be
--- whip_core, or name another resource). A `resource` in the config is ignored.
---@param source number
---@param name string
---@param config table  { duration, magnitude, tickRate, onTick, onApply, onRemove, damageModifier, meleeModifier, replaceSilently }
---@param owner string|nil  the resource applying it; whip_core when nil (the export passes the caller)
---@return boolean ok
---@return string|nil err
function Stats.applyEffect(source, name, config, owner)
    if type(name) ~= 'string' or name == '' then return false, 'an effect needs a name' end
    if type(config) ~= 'table' then return false, 'an effect needs a config table' end
    if not Stats._cache[source] then return false, 'Player not loaded' end

    -- Numbers, and positive where they count time (a tickRate of 0 would never count down).
    local function positiveOrNil(v) return v == nil or (type(v) == 'number' and v > 0 and v == v) end
    if not positiveOrNil(config.duration) then return false, 'duration must be a positive number of seconds, or nil' end
    if not positiveOrNil(config.tickRate) then return false, 'tickRate must be a positive number of seconds' end
    if config.magnitude ~= nil and type(config.magnitude) ~= 'number' then return false, 'magnitude must be a number' end
    if not positiveOrNil(config.damageModifier) then return false, 'damageModifier must be a positive number' end
    if not positiveOrNil(config.meleeModifier) then return false, 'meleeModifier must be a positive number' end
    -- Refused rather than ignored: code that asks for `stackable` expects stacking.
    if config.stackable ~= nil then
        return false, "'stackable' is now 'replaceSilently' — effects never stacked; a re-apply replaces"
    end
    if config.sheet ~= nil and config.sheet ~= 'light' then
        return false, "sheet is 'light' or left out"
    end

    if not Stats._effects[source] then Stats._effects[source] = {} end

    -- A re-apply replaces whatever is there. The modifier statebag is re-synced if EITHER the old or
    -- the new instance carried a modifier.
    local previous = Stats._effects[source][name]
    local hadModifier = previous and (previous.damageModifier or previous.meleeModifier)

    -- Already there: take the old one off first (its onRemove fires), unless replaceSilently
    if previous and not config.replaceSilently then
        Stats.removeEffect(source, name)
        hadModifier = false   -- removeEffect already re-synced the bag
    end

    local effect = {
        name           = name,
        duration       = config.duration or nil,  -- nil = permanent until removed
        remaining      = config.duration or nil,
        magnitude      = config.magnitude or 1,
        tickRate       = config.tickRate or 1,
        lastTick       = GetGameTimer(),
        lastCount      = GetGameTimer(),   -- when `remaining` was last counted down
        onTick         = config.onTick,
        onApply        = config.onApply,
        onRemove       = config.onRemove,
        damageModifier = config.damageModifier or nil,  -- weapon defense multiplier (0.5 = half damage)
        meleeModifier  = config.meleeModifier or nil,   -- melee defense multiplier
        resource       = owner or GetCurrentResourceName(),
        sheet          = config.sheet,   -- 'light': a satellite's callbacks get lightSheet
    }

    Stats._effects[source][name] = effect

    -- Fire onApply callback
    if effect.onApply then
        local ok, err = pcall(effect.onApply, source, Stats._playerFor(source, effect), Stats._effectFor(effect))
        if not ok then effectFailed(effect, name, 'onApply', err) end
    end

    -- Log
    Stats._logChange(source, name, 0, 'effect:applied')

    -- Sync combined modifier to statebag so other clients can read it
    if effect.damageModifier or effect.meleeModifier or hadModifier then
        Stats._syncModifierStatebag(source)
    end

    -- Notify client
    TriggerClientEvent('whip_core:client:effectApplied', source, name, Stats.effectView(effect))
    return true
end

--- The `player` an effect callback is handed: whip_core's own callbacks get the live object; a
--- satellite's get the handler sheet (every argument is copied across, and the live object carries
--- identifiers and the whole inventory). `sheet = 'light'` in the effect's config hands the light
--- sheet instead (who and whether dead), the same opt-in a SecureEvent has.
---@param source number
---@param effect table
---@return table|nil
function Stats._playerFor(source, effect)
    local player = Players[source]
    if not player then return nil end
    if effect and effect.resource and effect.resource ~= GetCurrentResourceName() then
        if effect.sheet == 'light' then return player:lightSheet() end
        return player:handlerSheet()
    end
    return player
end

--- The `effect` an effect callback is handed — the same rule as the player above: a satellite's get
--- the plain view of an effect (Stats.effectView), plus its name.
---@param effect table
---@return table
function Stats._effectFor(effect)
    if effect.resource and effect.resource ~= GetCurrentResourceName() then
        local view = Stats.effectView(effect)
        view.name = effect.name
        return view
    end
    return effect
end

--- Remove an active effect from a player. Answers `true`, or `false, reason`.
---@param source number
---@param name string
---@return boolean ok
---@return string|nil err
function Stats.removeEffect(source, name)
    if not Stats._effects[source] then return false, 'Player not loaded' end
    local effect = Stats._effects[source][name]
    if not effect then return false, ('no effect named "%s" on this player'):format(tostring(name)) end

    -- Fire onRemove callback
    if effect.onRemove then
        local ok, err = pcall(effect.onRemove, source, Stats._playerFor(source, effect), Stats._effectFor(effect))
        if not ok then effectFailed(effect, name, 'onRemove', err) end
    end

    local hadModifier = effect.damageModifier or effect.meleeModifier
    Stats._effects[source][name] = nil

    -- Log
    Stats._logChange(source, name, 0, 'effect:removed')

    -- Update statebag if this effect had a modifier
    if hadModifier then
        Stats._syncModifierStatebag(source)
    end

    -- Notify client
    TriggerClientEvent('whip_core:client:effectRemoved', source, name)
    return true
end

--- Check if a player has an active effect.
---@param source number
---@param name string
---@return boolean
function Stats.hasEffect(source, name)
    return Stats._effects[source] ~= nil and Stats._effects[source][name] ~= nil
end

--- One effect as plain data: what a satellite, the client and the export are shown of it — never the
--- internal table with everyone's callbacks in it.
---@param effect table
---@return table
function Stats.effectView(effect)
    return {
        duration       = effect.duration,
        remaining      = effect.remaining,
        magnitude      = effect.magnitude,
        tickRate       = effect.tickRate,
        damageModifier = effect.damageModifier,
        meleeModifier  = effect.meleeModifier,
        resource       = effect.resource,
    }
end

--- Every active effect on a player as plain data, keyed by name. {} when none, or not loaded.
---@param source number
---@return table<string, table>
function Stats.getEffectViews(source)
    local out = {}
    for name, effect in pairs(Stats._effects[source] or {}) do
        out[name] = Stats.effectView(effect)
    end
    return out
end

-- ============================================
-- Tick Thread (ONE thread, all players)
-- ============================================

-- The most onTicks one late wake fires for one effect (see advanceEffects).
local MAX_TICKS_PER_WAKE = 4

--- Advance this player's effects: fire onTick when `fireTicks`, and always count their time down.
---
--- The clock runs while dead (and in the spawn guard): only the tick (onTick, which may heal or hurt)
--- is held back, so dying doesn't extend an effect.
---
--- In seconds, not loop wakes: `remaining` counts real elapsed time, lastTick advances by whole
--- tickRates, and a wake several tickRates late fires each of them (a few at most; a long hitch is
--- not replayed).
---
--- A snapshot of the names: onTick and onRemove run inside this walk and may apply another effect. An
--- effect is removed only if it is still the one that ran out.
---@param source number
---@param now number
---@param fireTicks boolean
local function advanceEffects(source, now, fireTicks)
    local effects = Stats._effects[source]
    if not effects then return end

    local names = {}
    for effectName in pairs(effects) do names[#names + 1] = effectName end

    for _, effectName in ipairs(names) do
        local effect = effects[effectName]
        if effect then
            local tickInterval = (effect.tickRate or 1) * 1000
            local due = math.floor((now - effect.lastTick) / tickInterval)
            if due > 0 then
                effect.lastTick = effect.lastTick + due * tickInterval
                if fireTicks and effect.onTick then
                    for _ = 1, math.min(due, MAX_TICKS_PER_WAKE) do
                        if effects[effectName] ~= effect then break end   -- removed by its own tick
                        local ok, err = pcall(effect.onTick, source, Stats._playerFor(source, effect), Stats._effectFor(effect))
                        if not ok then effectFailed(effect, effectName, 'onTick', err) end
                    end
                end
            end

            if effect.remaining then
                effect.remaining = effect.remaining - (now - effect.lastCount) / 1000
                effect.lastCount = now
                if effect.remaining <= 0 and effects[effectName] == effect then
                    Stats.removeEffect(source, effectName)
                end
            end
        end
    end
end

--- The breath's share of a tick (builtInStats' oxygen): down under water, so a full breath lasts
--- Config.OxygenSeconds, up above it by Config.OxygenRecoverPerSecond each second. Through Stats.add, so
--- every step is logged, announced and sent like a need's decay. Nothing while it is full on dry land,
--- or empty under water (the game is drowning them, after Config.OxygenGraceSeconds: client/stats.lua).
---
--- Whip's breath must run out before the game's: the ped is given the game's longest, 50 s, while
--- whip's lasts, so the setting is held under it (45 s).
---@param source number
---@param cache table
---@param tickMs number
local function tickOxygen(source, cache, tickMs)
    if not Stats._registry.oxygen then return end
    local under = Stats._underwater[source] == true
    local now = finite(cache.oxygen) or 100
    if (under and now <= 0) or (not under and now >= 100) then return end
    local perSecond = under and 100 / math.max(1, math.min(45, tonumber(Config.OxygenSeconds) or 20))
        or math.max(0.5, math.min(100, tonumber(Config.OxygenRecoverPerSecond) or 6))
    local step = perSecond * (tickMs / 1000)
    Stats.add(source, 'oxygen', under and -step or step, under and 'under water' or 'breathing')
end

--- One player's share of a tick: decay, thresholds, effects. Its own function so it can be pcall'd:
--- a bad stat costs that one player that one tick, loudly, never the thread.
local function tickPlayer(source, cache, now, anyDecays, tickMs)
    do
            -- Skip stat processing while dead — except the effect clock, see advanceEffects
            local player = Players[source]
            if player.isDead then
                advanceEffects(source, now, false)
                goto nextPlayer
            end

            -- The breath: its own rule, under water or not (tickOxygen).
            tickOxygen(source, cache, tickMs)

            -- Skip thresholds/effects during spawn guard (10s after respawn/revive)
            local spawnGuarded = Stats._spawnGuard[source] and (now - Stats._spawnGuard[source]) < 10000

            -- The stats that decayed on THIS pass; their thresholds fire on this pass and no other (one
            -- decay, one threshold hit).
            local decayedNow = {}

            -- 1. Process decay for any stat that has it (needs + custom)
            if not anyDecays then goto skipDamage end
            for name, config in pairs(Stats._registry) do
                if config.decay then
                    local interval = (config.decayInterval or 10) * 1000
                    local lastDecay = (Stats._lastDecay[source] or {})[name] or 0

                    if now - lastDecay >= interval then
                        if not Stats._lastDecay[source] then Stats._lastDecay[source] = {} end
                        -- By whole intervals, like the effect clock. A decay far behind (the first,
                        -- or after a death) starts afresh rather than catching up.
                        Stats._lastDecay[source][name] = (now - lastDecay < 2 * interval)
                            and lastDecay + interval or now

                        Stats.add(source, name, config.decay, 'decay')
                        decayedNow[name] = true
                    end
                end
            end

            -- 2. Process thresholds (e.g., hunger <= 10 → damage health)
            -- Skipped during spawn guard (10s immunity after respawn/revive)
            if spawnGuarded then goto skipDamage end
            for name, config in pairs(Stats._registry) do
                if config.thresholds and config.decay then
                    -- Only when it decayed on this very pass (decayedNow, above).
                    if decayedNow[name] then
                        local val = cache[name] or config.default
                        for _, threshold in ipairs(config.thresholds) do
                            if threshold.stat and threshold.delta then
                                local triggered = false
                                if threshold.below then
                                    triggered = val <= threshold.value
                                else
                                    triggered = val >= threshold.value
                                end
                                -- Don't damage health if target stat is already at min
                                if triggered then
                                    local targetConfig = Stats._registry[threshold.stat]
                                    local targetVal = cache[threshold.stat] or (targetConfig and targetConfig.default or 0)
                                    local targetMin = targetConfig and targetConfig.min or 0
                                    if targetVal > targetMin then
                                        Stats.add(source, threshold.stat, threshold.delta, 'threshold:' .. name)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            ::skipDamage::

            -- 3. Process active effects. During the spawn guard their onTick is held back, but
            -- their time still runs (advanceEffects).
            advanceEffects(source, now, not spawnGuarded)

            ::nextPlayer::
    end
end

-- The period is read each time round (Every asks it before each wait), so a change in /whip → Settings takes effect
-- from the next tick. Every, not a bare loop: one error in a pass is printed and the next pass runs, where it used to
-- end hunger, thirst, oxygen and every effect clock until a restart (audit 20, PLY-4).
local function statsTickMs() return (Config.StatsTickInterval or 1) * 1000 end
Every('stats tick', statsTickMs, function()
    if not Config.Stats then return end
    local tickMs = statsTickMs()
    local now = GetGameTimer()

    -- One pass over the registry, not one per player: with nothing decaying, the per-player
    -- decay and threshold walks below never start.
    local anyDecays = false
    for _, config in pairs(Stats._registry) do
        if config.decay then anyDecays = true break end
    end

    for source, cache in pairs(Stats._cache) do
        if Players[source] then
            -- Nothing decays and this player has no effects, and their breath is full on dry land: there is no
            -- work this tick could possibly do, so do none of it.
            local fx = Stats._effects[source]
            local breathing = Stats._underwater[source] or (tonumber(cache.oxygen) or 100) < 100
            if anyDecays or (fx and next(fx) ~= nil) or breathing then
                local ok, err = pcall(tickPlayer, source, cache, now, anyDecays, tickMs)
                if not ok then
                    print(('[whip_core:stats] tick error for src %s — skipped this tick: %s')
                        :format(tostring(source), tostring(err)))
                end
            end
        end
    end
end)

-- ============================================
-- Persistence (called by player:save)
-- ============================================

--- Get stat values formatted for DB save.
--- Uses timestamp guard: recently-set vitals override ped reads.
---@param source number
---@return table  { health, armour, statuses }
function Stats.getForSave(source)
    local result = {}
    local cache = Stats._cache[source] or {}

    -- All values come from the Stats cache (single source of truth).
    -- Client reports combat damage via reportVitals → cache stays current.
    result.health = cache.health or 200
    result.armour = cache.armour or 0

    -- Statuses: from cache for every registered, persisted stat, and carried forward for anything on
    -- disk that is not registered right now (a satellite stopped, or not started yet). The LIVE value
    -- when there is one: unregister leaves the cache alone, so a restarting resource keeps what was
    -- earned since login. A stat registered as persist = false is dropped.
    result.statuses = {}
    for name, value in pairs(Stats._stored[source] or {}) do
        if not Stats._registry[name] then
            local live = cache[name]
            result.statuses[name] = live ~= nil and live or value
        end
    end
    for name, config in pairs(Stats._registry) do
        if (config.type == 'need' or config.type == 'custom') and config.persist then
            result.statuses[name] = cache[name] or config.default
        end
    end

    -- What this save writes is what the next one carries forward (a persisted stat registered later
    -- this session included). Only for a loaded player, so a stray call can't create an entry.
    if Stats._cache[source] then
        local stored = {}
        for name, value in pairs(result.statuses) do stored[name] = value end
        Stats._stored[source] = stored
    end

    return result
end

-- ============================================
-- Client Sync
-- ============================================

--- Send a single stat update to the client.
---@param source number
---@param name string
---@param value number
---@param delta number|nil  a vital changed by an amount: the client adds it to the live ped
function Stats._syncStat(source, name, value, delta)
    TriggerClientEvent('whip_core:client:statUpdate', source, name, value, delta)
end

--- Send all stats to client (used on login and periodic).
--- Sends ALL stats (including vitals) for the client's local cache,
--- but the client only applies needs/custom to HUD — NOT vitals to ped.
--- Vitals are applied to ped only via individual statUpdate events.
---@param source number
function Stats.syncAll(source)
    local cache = Stats._cache[source]
    if not cache then return end

    local stats = {}
    for name, value in pairs(cache) do
        stats[name] = value
    end

    TriggerClientEvent('whip_core:client:statsSync', source, stats, Stats.getEffectViews(source))
end

-- Periodic full sync to clients.
--
-- Not redundant, though every Stats.set sends a statUpdate: it is the only thing that refreshes an
-- effect's `remaining` on the client, and the only thing that delivers a stat registered after a
-- player loaded. On Every (lifecycle.lua).
Every('stats sync', function() return (Config.StatsSyncInterval or 5) * 1000 end, function()
    if not Config.Stats then return end
    for source, _ in pairs(Stats._cache) do
        if Players[source] then
            Stats.syncAll(source)
        end
    end
end)

-- ============================================
-- Change Log (for debug overlay)
-- ============================================

---@param source number
---@param stat string
---@param delta number
---@param changeSource string
function Stats._logChange(source, stat, delta, changeSource)
    if not Stats._changeLog[source] then Stats._changeLog[source] = {} end
    local log = Stats._changeLog[source]

    log[#log + 1] = {
        stat   = stat,
        delta  = delta,
        source = changeSource,
        time   = GetGameTimer(),
    }

    -- Trim to max size
    while #log > CHANGE_LOG_MAX do
        table.remove(log, 1)
    end
end

-- ============================================
-- Debug Overlay Data
-- ============================================

--- Get full debug snapshot for a player (sent to debug overlay).
---@param source number
---@return table
function Stats.getDebugData(source)
    local cache = Stats._cache[source] or {}
    local ped = GetPlayerPed(source)
    local now = GetGameTimer()
    local recent = Stats._recentSets[source] or {}

    -- Stats with ped comparison (ordered: health, armour, hunger, thirst, then rest)
    local stats = {}
    local statOrder = { 'health', 'armour', 'hunger', 'thirst' }
    -- Add any registered stats not in the default order
    for name, _ in pairs(Stats._registry) do
        local found = false
        for _, o in ipairs(statOrder) do
            if o == name then found = true; break end
        end
        if not found then statOrder[#statOrder + 1] = name end
    end

    for _, name in ipairs(statOrder) do
        local config = Stats._registry[name]
        if config then
            local entry = {
                name    = name,
                value   = cache[name] or config.default,
                max     = config.max,
                type    = config.type,
                color   = config.hud and config.hud.color or nil,   -- the debug panel's bar, as the gauge
            }
            if config.type == 'vital' and ped and ped ~= 0 then
                if name == 'health' then
                    entry.ped = GetEntityHealth(ped)
                elseif name == 'armour' then
                    entry.ped = GetPedArmour(ped)
                end
            end
            if recent[name] then
                entry.setAgo = (now - recent[name]) / 1000
            end
            if config.decay then
                entry.decay = config.decay
                entry.decayInterval = config.decayInterval
            end
            stats[#stats + 1] = entry
        end
    end

    -- Effects — the one projection, so the overlay shows duration and modifiers too.
    local effects = Stats.getEffectViews(source)

    -- Recent changes (last 10)
    local changes = {}
    local log = Stats._changeLog[source] or {}
    local startIdx = math.max(1, #log - 9)
    for i = #log, startIdx, -1 do
        local entry = log[i]
        changes[#changes + 1] = {
            stat   = entry.stat,
            delta  = entry.delta,
            source = entry.source,
            ago    = (now - entry.time) / 1000,
        }
    end

    local p = Players[source]
    return { stats = stats, effects = effects, changes = changes, who = p and p.fullName or nil }
end

--- Is the sender thread alive? See startStatsDebugSender below.
local statsSenderRunning = false

-- ---- The players near a viewer, for the cards over them (tools/debug_cards.lua) ----

local NEARBY_RANGE = 40.0   -- metres
local NEARBY_MAX   = 8      -- the cards there are

--- One player's stats, small: { n = name, v = value, m = max, t = type, c = colour }, in the debug
--- panel's order (health, armour, hunger, thirst, then the rest by name).
local function cardStats(source)
    local cache = Stats._cache[source] or {}
    local out, rest = {}, {}
    for _, name in ipairs({ 'health', 'armour', 'hunger', 'thirst' }) do
        if Stats._registry[name] then out[#out + 1] = name end
    end
    for name in pairs(Stats._registry) do
        if name ~= 'health' and name ~= 'armour' and name ~= 'hunger' and name ~= 'thirst' then rest[#rest + 1] = name end
    end
    table.sort(rest)
    for _, name in ipairs(rest) do out[#out + 1] = name end
    for i, name in ipairs(out) do
        local config = Stats._registry[name]
        out[i] = { n = name, v = cache[name] or config.default, m = config.max, t = config.type,
                   c = config.hud and config.hud.color or nil }
    end
    return out
end

--- Every other player with a character within NEARBY_RANGE of `source`, the nearest first.
local function nearbyCards(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return {} end
    local me = GetEntityCoords(ped)
    local list = {}
    for src, p in pairs(Players) do
        if src ~= source and not p.phantom then
            local other = GetPlayerPed(src)
            if other and other ~= 0 then
                local at = GetEntityCoords(other)
                local dx, dy, dz = at.x - me.x, at.y - me.y, at.z - me.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= NEARBY_RANGE then
                    list[#list + 1] = { s = src, d = d, n = p.fullName, c = p.charId, stats = cardStats(src) }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    for i = #list, NEARBY_MAX + 1, -1 do list[i] = nil end
    return list
end

--- Push a stat snapshot to everyone watching, five times a second — and stop when nobody is (waking a
--- coroutine costs about 15us whatever it then does).
local function statsDebugSenderLoop()
    local tick = 0
    while true do
        Wait(200)
        tick = tick + 1

        if next(Stats._debugViewers) == nil then
            statsSenderRunning = false
            return
        end

        -- Holders of the ACE only (DevTools.eachViewer drops the rest): dev tools taken back stop the
        -- snapshot however the overlay was turned on.
        DevTools.eachViewer(Stats._debugViewers, function(source)
            if Players[source] then
                local data = Stats.getDebugData(source)
                TriggerClientEvent('whip_core:client:statsDebug', source, data)
                -- The players near them, for the cards over those players: twice a second is enough.
                if tick % 3 == 0 then
                    TriggerClientEvent('whip_core:client:statsDebugNearby', source, nearbyCards(source))
                end
            else
                Stats._debugViewers[source] = nil
            end
        end)
    end
end

--- Start the sender, unless it is already running. Called by the toggle and nowhere else.
local function startStatsDebugSender()
    if statsSenderRunning then return end
    statsSenderRunning = true
    CreateThread(statsDebugSenderLoop)
end

-- ============================================
-- Satellite Cleanup
-- ============================================

--- A satellite that registered stats has stopped. Its STATS are dropped by the registry's sweep
--- (_stats, near the top of this file); this takes its effects off players.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end

    -- Its effects: removed WITHOUT their onRemove (it lives in the stopped resource and would only
    -- error), with the modifier bag re-synced.
    for src, effects in pairs(Stats._effects) do
        local touched = false
        for effectName, effect in pairs(effects) do
            if effect.resource == res then
                effects[effectName] = nil
                touched = true
                TriggerClientEvent('whip_core:client:effectRemoved', src, effectName)
            end
        end
        if touched and Players[src] then Stats._syncModifierStatebag(src) end
    end
end)

-- ============================================
-- Exports
-- ============================================

exports('RegisterStat', function(name, config)
    local owner = Registry.caller()   -- first, before anything can yield
    local ok, why = Stats.register(name, config, owner)
    if not ok then Registry.sayRefused(owner, why) end   -- a bad config too, not only a taken name
    return ok, why
end)
--- A stat's value, or nil when there is none to read (the player is not loaded, or no such stat) —
--- a single-value read answers nothing rather than a stand-in (Return Patterns).
exports('GetStat', function(source, name) return Stats.get(source, name) end)

--- The label a stat change carries into the change log (and to OnStatChange): the caller's own,
--- or 'by <resource>' so the debug overlay still says who, when they gave none.
---@param reason any
---@param caller string
---@return string
local function statReason(reason, caller)
    if type(reason) == 'string' and reason ~= '' then return reason:sub(1, 80) end
    return 'by ' .. caller
end

-- SetStat / AddStat / RemoveEffect answer `true`, or `false, reason` ('player not loaded', 'no stat
-- named "x"', 'value must be a number', 'no effect named "x"'). `reason` is optional on both setters:
-- what caused the change ('item:food').
exports('SetStat', function(source, name, value, reason)
    local caller = Registry.caller()
    return Stats.set(source, name, value, statReason(reason, caller))
end)
exports('AddStat', function(source, name, delta, reason)
    local caller = Registry.caller()
    return Stats.add(source, name, delta, statReason(reason, caller))
end)
--- Every stat, or `{}, 'Player not loaded'` — a list read answers the empty list and why.
exports('GetAllStats', function(source)
    local all = Stats.getAll(source)
    if not all then return {}, 'Player not loaded' end
    return all
end)

--- Be told when a player's stat changes, on the server: the client's OnStatChange, with the
--- player's source first:
---
---     exports.whip_core:OnStatChange('hunger', function(source, value, old, reason)
---         if value <= 0 then ... end
---     end)
---
---     exports.whip_core:OnStatChange('*', function(source, name, value, old, reason) end)
---
--- `reason` is what caused it: 'decay', 'item:food', 'combat (reported): Pistol', 'by my_resource'...
--- Every change is heard — decay ticks, item use, effects, combat damage, other resources' SetStat.
---
--- OPTIONS, the same as OnVehicleStatChange's, third or fourth after an `id`:
---   * `table = true` — one table instead: { source, key, value, old, reason }.
---   * `now = true`   — also called once straight away for every loaded player who has the stat
---                      (old = nil, reason = 'now'), so there is no separate "read them all" step.
---
--- Keyed by `<your resource>:<id>` (id defaults to the name), so registering again from
--- whip_core:onReady replaces rather than doubles. Pass a distinct `id` to hold two listeners on one
--- stat. Cleared when your resource stops. Answers `true`, or `false, reason`.
---@param name string  a stat name, or '*' for every stat
---@param callback function
---@param id any|nil
---@param opts table|nil  { table?: boolean, now?: boolean }
---@return boolean ok
---@return string|nil err
exports('OnStatChange', function(name, callback, id, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' or name == '' then return false, "name is required (a stat name, or '*')" end
    -- `~= nil`, never a type test: a function from another resource arrives as a callable table.
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}

    local list = Stats._listeners[name]
    if not list then
        list = {}
        Stats._listeners[name] = list
    end
    local key = ('%s:%s'):format(owner, tostring(id or name))
    local reg = { fn = callback, owner = owner, asTable = opts.table == true }
    list[key] = reg

    -- `now`: off the registration path, so the caller has its `true` first.
    if opts.now then
        CreateThread(function()
            for src, cache in pairs(Stats._cache) do
                if list[key] ~= reg then return end   -- replaced or swept meanwhile
                if Players[src] then
                    if name == '*' then
                        for statName, value in pairs(cache) do
                            callListener(reg, true, src, statName, value, nil, 'now')
                        end
                    elseif cache[name] ~= nil then
                        callListener(reg, false, src, name, cache[name], nil, 'now')
                    end
                end
            end
        end)
    end
    return true
end)
-- ApplyEffect answers (true) or (false, why). The effect is always the CALLER's: a `resource` in the
-- config is ignored. See Stats.applyEffect.
exports('ApplyEffect', function(source, name, config)
    local caller = Registry.caller()   -- first, before anything can yield
    return Stats.applyEffect(source, name, config, caller)
end)
exports('RemoveEffect', function(source, name) return Stats.removeEffect(source, name) end)
exports('HasEffect', function(source, name) return Stats.hasEffect(source, name) end)
-- Plain data per effect — { duration, remaining, magnitude, tickRate, damageModifier, meleeModifier,
-- resource } — never the internal table with everyone's callbacks in it.
exports('GetEffects', function(source) return Stats.getEffectViews(source) end)

-- ============================================
-- Damage Modifier Helpers
-- ============================================

--- A combined modifier held to Config.Sentinel.damageModifierClamp — the range every attacker's
--- client holds a bag value to before applying it (client/stats.lua). Clamped HERE as well so the
--- exports answer what a hit actually does: a stack below the floor (0.5 × 0.05) reports the floor
--- every attacker uses, not a number no hit will ever do.
---@param v number
---@return number
local function clampModifier(v)
    local c = Config.Sentinel and Config.Sentinel.damageModifierClamp
    if not c then return v end
    return math.min(c.max or v, math.max(c.min or v, v))
end

--- Get the combined weapon damage modifier from all active effects, held to the configured range.
--- Returns 1.0 if no effects have damageModifier set.
---@param source number
---@return number
function Stats.getDamageModifier(source)
    local effects = Stats._effects[source]
    if not effects then return 1.0 end
    local combined = 1.0
    for _, effect in pairs(effects) do
        if effect.damageModifier then
            combined = combined * effect.damageModifier
        end
    end
    return clampModifier(combined)
end

--- Get the combined melee damage modifier from all active effects, held to the configured range.
---@param source number
---@return number
function Stats.getMeleeModifier(source)
    local effects = Stats._effects[source]
    if not effects then return 1.0 end
    local combined = 1.0
    for _, effect in pairs(effects) do
        if effect.meleeModifier then
            combined = combined * effect.meleeModifier
        end
    end
    return clampModifier(combined)
end

exports('GetDamageModifier', function(source) return Stats.getDamageModifier(source) end)
exports('GetMeleeModifier', function(source) return Stats.getMeleeModifier(source) end)

--- Sync combined damage modifier to player statebag.
--- Other clients read this to adjust outgoing damage, which is why it goes through the Sentinel (a
--- client spoofing its own modifier down would resist damage).
---@param source number
function Stats._syncModifierStatebag(source)
    local dmgMod = Stats.getDamageModifier(source)
    local meleeMod = Stats.getMeleeModifier(source)
    -- Only set when non-default (an absent key replicates nothing) — the nil IS the write.
    Sentinel.setPlayerKey(source, PLAYER_DMGMOD_KEY, dmgMod ~= 1.0 and dmgMod or nil)
    Sentinel.setPlayerKey(source, PLAYER_MELEEMOD_KEY, meleeMod ~= 1.0 and meleeMod or nil)
end

-- ============================================
-- Client Vitals Report (combat damage sync)
-- Client reads ped health/armour every 200ms and
-- reports changes. Server natives are unreliable.
-- ============================================

SecureEvent('whip_core:server:reportVitals', {
    whileDead = true,   -- a report, not an action; the handler itself ignores it while dead
    rateLimit = 150,
    -- Burst 3, not 1: the client reports only on CHANGE, so a refused report is never resent.
    burst     = 3,
    params = {
        {'health', 'int', 0, 200},
        {'armour', 'int', 0, 100},
        {'context', 'string', 120, ''},
        -- Whether the player is under water: oxygen's tick drains or refills by it (tickOxygen). Sent on a change.
        {'under', 'bool', false},
    },
}, function(source, player, health, armour, context, under)
    local cache = Stats._cache[source]
    if not cache then return end

    -- Under water or not, even while dead: the tick skips the dead, and a player who comes back is told full.
    Stats._underwater[source] = under == true or nil

    -- Ignore during resource shutdown — cache is frozen for final save
    if Stats._frozen then return end

    -- Ignore vitals reports while dead — death system owns health state
    if player.isDead then return end

    local recent = Stats._recentSets[source] or {}
    local now = GetGameTimer()
    local guardWindow = (Config.StatsSetGuardWindow or 2) * 1000

    -- Guard logic: during the guard window, reject reports where the ped
    -- hasn't loaded yet (health=0 or armour=0 when cache has real values).
    -- Accept all other reports immediately — combat damage must never be delayed.
    local guardedHealth = recent.health and (now - recent.health) < guardWindow
    local guardedArmour = recent.armour and (now - recent.armour) < guardWindow

    -- Build log label: use client damage context if provided, fallback to 'combat'. Labelled as
    -- reported, as the death path is: the context is the victim's own client's text.
    local label = (context and context ~= '') and ('combat (reported): ' .. context) or 'combat'

    -- Health: reject 0 during guard (ped not loaded), accept everything else
    if cache.health ~= health then
        local reject = guardedHealth and health == 0 and (cache.health or 200) > 0
        if not reject then
            local before = cache.health or 200
            local delta = health - before
            cache.health = health
            if delta ~= 0 then
                Stats._logChange(source, 'health', delta, label)
                -- Owed to disk, like every other health write (Stats.set marks it).
                if PlayerRows and PlayerRows.markDirty then PlayerRows.markDirty(source) end
                -- And announced (OnStatChange): this is the path combat damage takes.
                Stats._announce(source, 'health', health, before, label)
            end

            -- An accepted zero is a death, whether or not the client says so (playerDied is a
            -- courtesy report carrying the killing blow). MarkPlayerDead (events_misc.lua) no-ops
            -- when the death event got there first.
            --
            -- Confirmed against the ped first, so a client can't die on demand to get out of
            -- somewhere: after a second's grace for replication, a ped that still reads alive means
            -- the report was not true. A ped the server cannot see is given the benefit of the doubt.
            if health == 0 and MarkPlayerDead then
                local why = (context and context ~= '') and context or nil
                local life = player.lifeGen   -- revived inside the second: not this death (MarkPlayerAlive)
                CreateThread(function()
                    Wait(1000)
                    if Players[source] ~= player or player.isDead or player.lifeGen ~= life then return end
                    local ped = GetPlayerPed(source)
                    local pedHealth = (ped and ped ~= 0) and GetEntityHealth(ped) or nil
                    if pedHealth and pedHealth > 100 then
                        RecordEventRejection('whip_core:server:reportVitals', source,
                            ('reported 0 health, ped reads %d — not marked dead'):format(pedHealth))
                        return
                    end
                    MarkPlayerDead(source, player, why)
                end)
            end
        end
    end

    -- Armour: reject 0 during guard only if cache has armour
    if cache.armour ~= armour then
        local reject = guardedArmour and armour == 0 and (cache.armour or 0) > 0
        if not reject then
            local before = cache.armour or 0
            local delta = armour - before
            cache.armour = armour
            if delta ~= 0 then
                Stats._logChange(source, 'armour', delta, label)
                if PlayerRows and PlayerRows.markDirty then PlayerRows.markDirty(source) end   -- see health
                Stats._announce(source, 'armour', armour, before, label)                     -- see health
            end
        end
    end
end)

-- ============================================
-- Debug Toggle Events (from client)
-- ============================================

-- A developer overlay (each viewer costs a 5Hz snapshot), so it requires the devtools ACE.
SecureEvent('whip_core:server:statsDebugOn', {
    ace = 'whip.devtools',
    rateLimit = 1000,
}, function(source)
    Stats._debugViewers[source] = true
    startStatsDebugSender()
end)

-- No ACE: leaving is never refused (dev tools taken back turn the overlay off after the permission is gone).
SecureEvent('whip_core:server:statsDebugOff', {
    rateLimit = 1000,
    whileDead = true,
    requirePlayer = false,
}, function(source)
    Stats._debugViewers[source] = nil
end)
