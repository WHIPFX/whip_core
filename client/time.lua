-- Time and weather, client side. The server broadcasts one world time and weather; this client stacks named layers on
-- top that change only what it sees. Each source clears only its own layer. Each field (hour, minute, weather, frozen,
-- blackout) resolves independently: the highest-priority layer that mentions it wins, else the server's value.
-- Ties are broken by name so the outcome is stable.

local twServer = {
    hour      = 12,
    minute    = 0,
    weather   = 'CLEAR',
    frozen    = false,
    blackout  = false,
    timeScale = 1.0,
    synced    = false,
}

--- [name] = { priority, hour?, minute?, weather?, frozen?, blackout? }
local twLayers = {}
--- Layer names, highest priority first; rebuilt when a layer changes.
local twOrder = {}

-- The running local clock; separate from the resolved values because time progresses between server syncs.
local clientHour   = 12
local clientMinute = 0.0

--- Which layer supplies the time ('' = the server), so the clock re-seeds the moment that changes.
local timeOwner = ''

--- The hour/minute the clock was last seeded from, so a layer changing its time under the same name re-seeds. nil: the server's.
local seededHour, seededMinute = nil, nil

-- Last values pushed to the engine, so nothing is re-applied every tick.
local appliedWeather  = nil
local appliedBlackout = nil

-- Apply natives

local function ApplyTime(hour, minute, second)
    NetworkOverrideClockTime(math.floor(hour), math.floor(minute), math.floor(second or 0))
end

local function ApplyWeather(weather)
    if not weather then return end
    SetWeatherTypeNowPersist(weather)
    SetWeatherTypeNow(weather)
    SetOverrideWeather(weather)
end

local function ApplyBlackout(blackout)
    SetBlackout(blackout and true or false)
end

-- Layer resolution

local function rebuildOrder()
    twOrder = {}
    for name in pairs(twLayers) do twOrder[#twOrder + 1] = name end
    table.sort(twOrder, function(a, b)
        local pa = twLayers[a].priority or 0
        local pb = twLayers[b].priority or 0
        if pa ~= pb then return pa > pb end
        return a < b            -- stable, so the same set always resolves the same way
    end)
end

--- The winning value for one field, and the layer that supplied it.
---@return any value
---@return string owner  layer name, or '' when it came from the server
local function resolve(field)
    for i = 1, #twOrder do
        local l = twLayers[twOrder[i]]
        if l and l[field] ~= nil then return l[field], twOrder[i] end
    end
    return twServer[field], ''
end


--- Push resolved state to the engine, re-seeding the clock if the time source changed. Called on a server sync or a
--- layer change.
local function refresh()
    -- Not gated on twServer.synced: the first timeSync can be a minute away and a layer carries its own values.
    local weather, _ = resolve('weather')
    local blackout, _ = resolve('blackout')
    local hour, hourOwner = resolve('hour')
    local minute = resolve('minute')

    -- Weather and blackout only on change, compared with what was last applied (not the server's value, which
    -- would let a server weather change stomp an active layer).
    if weather ~= appliedWeather then
        appliedWeather = weather
        ApplyWeather(weather)
    end
    if blackout ~= appliedBlackout then
        appliedBlackout = blackout
        ApplyBlackout(blackout)
    end

    -- Re-seed when the time changes hands or a layer is re-set under the same name with a different time. Not when
    -- the server owns the time and its hour merely moved on: the local clock tracks it.
    local reseed = false
    if hourOwner ~= timeOwner then
        reseed = true
    elseif hourOwner ~= '' and (hour ~= seededHour or minute ~= seededMinute) then
        reseed = true
    end

    if reseed then
        timeOwner    = hourOwner
        seededHour   = hour
        seededMinute = minute
        clientHour   = hour or twServer.hour
        clientMinute = minute or twServer.minute
        ApplyTime(clientHour, clientMinute, 0)
    end
end

-- Server sync

RegisterNetEvent('whip_core:client:timeSync', function(data)
    if not data then return end

    twServer.hour      = data.hour or twServer.hour
    twServer.minute    = data.minute or twServer.minute
    twServer.weather   = data.weather or twServer.weather
    twServer.frozen    = data.frozen or false
    twServer.blackout  = data.blackout or false
    twServer.timeScale = data.timeScale or 1.0
    twServer.synced    = true

    PauseClock(true)

    -- Correct drift only while the server owns the time, and not while a layer freezes it.
    local _, frozenOwner = resolve('frozen')
    if timeOwner == '' and frozenOwner == '' then
        clientHour   = twServer.hour
        clientMinute = twServer.minute
        ApplyTime(clientHour, clientMinute, math.floor((clientMinute % 1) * 60))
    end

    refresh()
end)

-- Layers

local CORE_RES = GetCurrentResourceName()

--- [name] = the resource that set the layer.
local layerOwners = {}

--- The weathers a layer may name: Config.WeatherTypes.
local validWeather = {}
for _, w in ipairs(Config.WeatherTypes or {}) do validWeather[string.upper(w)] = true end

-- Rebuild the copy when the setting changes.
Settings.onChange('WeatherTypes', function()
    validWeather = {}
    for _, w in ipairs(Config.WeatherTypes or {}) do validWeather[string.upper(w)] = true end
end)

--- A real, finite number, or nil.
local function finiteNum(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

--- Add or replace a layer; nil opts removes it. Fields left out are not overridden. A layer belongs to the resource
--- that set it: another resource may not replace or clear it (whip_core may), and it comes off when its resource stops.
---@param name string        unique per source, e.g. 'zone:swamp' or 'charselect'
---@param opts table|nil     { priority?, hour?, minute?, weather?, frozen?, blackout? }
---@param owner string|nil   the resource setting it (the exports pass the caller); whip_core when nil
---@return boolean ok, string|nil why
local function setLayer(name, opts, owner)
    if type(name) ~= 'string' or name == '' then return false, 'a layer needs a name' end
    owner = owner or CORE_RES

    local holder = layerOwners[name]
    if holder and holder ~= owner and owner ~= CORE_RES and Registry.alive(holder) then
        return false, ('layer "%s" belongs to %s'):format(name, holder)
    end

    if opts == nil then
        if not twLayers[name] then return false, ('there is no layer "%s"'):format(name) end
        twLayers[name] = nil
        layerOwners[name] = nil
        rebuildOrder()
        refresh()
        WhipEmit('whip_core:weather:layerChanged', { name = name })
        return true
    end

    if type(opts) ~= 'table' then return false, 'opts must be a table, or nil to clear' end

    local l = { priority = 0 }
    if opts.priority ~= nil then
        l.priority = finiteNum(opts.priority)
        if not l.priority then return false, 'priority must be a number' end
    end

    if opts.hour ~= nil then
        local n = finiteNum(opts.hour)
        if not n then return false, 'hour must be a number' end
        l.hour = math.floor(n) % 24
    end
    if opts.minute ~= nil then
        local n = finiteNum(opts.minute)
        if not n then return false, 'minute must be a number' end
        l.minute = math.floor(n) % 60
    end
    if opts.weather ~= nil then
        local w = type(opts.weather) == 'string' and string.upper(opts.weather) or nil
        if not (w and validWeather[w]) then return false, 'Invalid weather type' end
        l.weather = w
    end

    -- Plain ifs: `x ~= nil and (...) or nil` would turn false into nil.
    if opts.frozen   ~= nil then l.frozen   = opts.frozen   and true or false end
    if opts.blackout ~= nil then l.blackout = opts.blackout and true or false end

    twLayers[name] = l
    layerOwners[name] = owner

    rebuildOrder()
    refresh()
    WhipEmit('whip_core:weather:layerChanged', { name = name, layer = twLayers[name] })
    return true
end

--- Server-pushed layer; the server already owner-checked it, so it arrives as whip_core's. Named 'server:<name>' so it
--- cannot take over a client resource's layer.
RegisterNetEvent('whip_core:client:weatherLayer', function(name, opts)
    if type(name) ~= 'string' or name == '' then return end
    setLayer('server:' .. name, opts, CORE_RES)
end)

-- A stopping resource's layers come off.
AddEventHandler('onClientResourceStop', function(res)
    if res == CORE_RES then return end
    local gone = {}
    for name, holder in pairs(layerOwners) do
        if holder == res then gone[#gone + 1] = name end
    end
    for _, name in ipairs(gone) do setLayer(name, nil, CORE_RES) end
end)

--- Direct entry point for whip_core's own client files (zones, the character screen).
WeatherLayer = { set = function(name, opts) return setLayer(name, opts, CORE_RES) end }

--- The local clock: ticks once a second.
CreateThread(function()
    while true do
        Wait(1000)
        -- Runs once synced or as soon as any layer is active, so a menu freezing the clock works before a sync.
        if twServer.synced or next(twLayers) ~= nil then
            local frozen = resolve('frozen')

            if frozen then
                -- Re-applied each tick because GTA drifts the clock on its own.
                ApplyTime(clientHour, clientMinute, 0)
            else
                local scale = twServer.timeScale or 1.0
                clientMinute = clientMinute + ((30 * scale) / 60)

                while clientMinute >= 60 do
                    clientMinute = clientMinute - 60
                    clientHour = clientHour + 1
                end
                while clientHour >= 24 do clientHour = clientHour - 24 end

                ApplyTime(clientHour, clientMinute, math.floor((clientMinute % 1) * 60))
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    ClearOverrideWeather()
    ClearWeatherTypePersist()
    SetBlackout(false)
end)

-- Client exports

--- Change what this client sees, without a server round trip. The layer is yours: another resource cannot replace
--- or clear it, and it comes off when your resource stops. Returns `true`, or `false, why`.
---
--- ```lua
--- exports.whip_core:SetWeatherLayer('zone:swamp', { weather = 'FOGGY', priority = 10 })
--- exports.whip_core:ClearWeatherLayer('zone:swamp')
--- ```
exports('SetWeatherLayer', function(name, opts) return setLayer(name, opts, Registry.caller()) end)
exports('ClearWeatherLayer', function(name) return setLayer(name, nil, Registry.caller()) end)

--- Every active layer, plus which one owns each field (for debugging a stack).
exports('GetWeatherLayers', function()
    local out = { layers = {}, owners = {} }
    for i = 1, #twOrder do
        local name = twOrder[i]
        out.layers[#out.layers + 1] = { name = name, priority = twLayers[name].priority }
    end
    for _, f in ipairs({ 'hour', 'minute', 'weather', 'frozen', 'blackout' }) do
        local _, owner = resolve(f)
        out.owners[f] = owner == '' and 'server' or owner
    end
    return out
end)

exports('GetTime', function()
    return math.floor(clientHour), math.floor(clientMinute)
end)

exports('GetWeather', function()
    return (resolve('weather'))
end)

exports('IsTimeFrozen', function()
    return (resolve('frozen')) and true or false
end)

exports('IsTimeOverridden', function()
    return next(twLayers) ~= nil
end)
