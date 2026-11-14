-- ============================================
-- PLAYER PREFERENCES — the pause menu's Server Settings page
-- ============================================
--
-- "We have the normal GTA settings, but now we need client 'server' settings ... anything that should be
-- configurable for the player should go into the pause menu under 'server settings', just below the normal
-- 'Settings' menu." Each player's own choices about how whip looks and handles on THEIR screen: the menu
-- cursor's speed on a pad, which dial the car shows, the speed unit, the map's border. Kept on the player's
-- PC (resource KVP), like the Controller screen's layout.
--
-- NOT /whip → Settings. That page (Settings, client/settings.lua) is the SERVER's config, changed by an admin
-- for everyone. A preference here often starts from one of those — the speed unit's default is the server's
-- Config.VehicleHud.speedUnit — and a player who never changes it follows the server, even when an admin
-- changes it later: only a choice that differs from the default is kept (as client/pad.lua keeps a layout).
--
-- DECLARED BY THE FILE THAT USES IT, read where it is used:
--
--     PlayerPrefs.define({
--         key = 'dial.speedUnit', group = 'Vehicles', label = 'Speed unit',
--         help = 'What the dial shows your speed in.',
--         type = 'choice', options = { { value = 'mph', label = 'mph' }, { value = 'kmh', label = 'km/h' } },
--         default = function() return Config.VehicleHud.speedUnit == 'kmh' and 'kmh' or 'mph' end,
--     })
--     local unit = PlayerPrefs.get('dial.speedUnit')
--     PlayerPrefs.onChange('dial.speedUnit', function(value) ... end)
--
-- Types: 'toggle' (true / false), 'choice' (one of `options`' values), 'slider' (a number, min to max in steps
-- of `step`, shown with `unit`). `visible = function()` hides a row that means nothing now (the map border with
-- the classic HUD). `page = true` sends the value to whip_core's page too (the cursor speed, read in JS).
--
-- DECIDED BY THE SERVER: `forced = function()` answers the value the server's config gives everyone (/whip →
-- Config → Map options), or nil while the player chooses. While it answers, that is the value in force, the row
-- shows greyed ("Disabled by server admin") and a change is refused; the player's own choice is kept for when the
-- server lets go. A file whose config moved calls PlayerPrefs.recheck so its listeners hear the new value.
--
-- A SATELLITE'S ROW (whip_chat's chat visibility, whip_voice's volumes) is the satellite's own value, kept
-- where it always was: it registers with `get` and `set` (Whip.playerSetting in lib/satellite.lua, or the
-- __RegisterPlayerSetting export, behind Whip.playerSetting), and this page only shows it and changes it through them. Its row goes when
-- its resource stops.

PlayerPrefs = {}

local KVP = 'whip_core:prefs'
local KVP_VERSION = 1

--- The page's tabs, in this order; a group not listed here comes after them, in the order it was first used.
local GROUP_ORDER = { 'Controller', 'Vehicles', 'Map & HUD', 'Minimap', 'Chat & voice' }

local _defs = {}      -- [key] = def: whip_core's own rows, and the registry's store for satellites' (see below)
local _order = {}     -- the keys in the order they were declared: the order of the rows in a group
local _listed = {}    -- [key] = true once in _order: a satellite that restarts keeps its place, not a second row
local _chosen = {}    -- [key] = the player's choice, for whip_core's own rows (only ones that differ from the default)
local _hooks = {}     -- [key] = { fn, ... }: whip_core's own listeners (onChange)

-- ---- saved on this PC ----

local function load()
    local raw = GetResourceKvpString(KVP)
    if type(raw) ~= 'string' or raw == '' then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.values) ~= 'table' then return end
    for k, v in pairs(data.values) do
        if type(k) == 'string' then _chosen[k] = v end
    end
end

local function save()
    if next(_chosen) == nil then DeleteResourceKvp(KVP) return end
    SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, values = _chosen }))
end

load()

-- ---- values ----

--- Not `ok and v or nil`: a default of false (A sprints too, on a stock config) would come out nil.
local function defaultOf(def)
    local d = def.default
    if type(d) == 'function' then
        local ok, v = pcall(d)
        if ok then d = v else d = nil end
    end
    return d
end

local function listed(key)
    if _listed[key] then return end
    _listed[key] = true
    _order[#_order + 1] = key
end

--- `value` made into what `def` takes, or nil (refused). `asIs`: a slider's value is only kept in range, not put on a
--- step — a resource's own value, read back (/voicevolume 98 is 98, not the page's nearest 100).
local function clean(def, value, asIs)
    if def.type == 'toggle' then
        if value == true or value == false then return value end
        return nil
    elseif def.type == 'choice' then
        for _, o in ipairs(def.options or {}) do
            if o.value == value then return value end
        end
        return nil
    elseif def.type == 'slider' then
        local n = tonumber(value)
        if not n or n ~= n then return nil end
        local min, max, step = tonumber(def.min) or 0, tonumber(def.max) or 100, tonumber(def.step) or 1
        n = math.max(min, math.min(max, n))
        if step > 0 and not asIs then n = min + math.floor((n - min) / step + 0.5) * step end
        return math.max(min, math.min(max, n))
    end
    return nil
end

--- The value the server's config gives everyone for this row (its `forced`), or nil while the player chooses.
local function forcedOf(def)
    if not def.forced then return nil end
    local ok, v = pcall(def.forced)
    if not ok or v == nil then return nil end
    return clean(def, v)
end

--- The value in force: the server's, when it decides (`forced`); else the player's choice, else the default. A
--- satellite's row asks its owner.
---@param key string
---@return any
function PlayerPrefs.get(key)
    local def = _defs[key]
    if not def then return nil end
    local f = forcedOf(def)
    if f ~= nil then return f end
    if def.getter then
        -- NOT `ok and clean(...) or nil`: a resource's toggle that is off would read as its default (review).
        local ok, v = pcall(def.getter)
        if ok then v = clean(def, v, true) else v = nil end
        if v == nil then v = clean(def, defaultOf(def)) end
        return v
    end
    local v = _chosen[key]
    if v ~= nil then
        v = clean(def, v)
        if v ~= nil then return v end
    end
    return clean(def, defaultOf(def))
end

local function sendPageValues()
    local values = {}
    for key, def in pairs(_defs) do
        if def.page then values[key] = PlayerPrefs.get(key) end
    end
    SendNUIMessage({ action = 'playerPrefs', values = values })
end

local function fire(key, value)
    for _, fn in ipairs(_hooks[key] or {}) do
        local ok, err = pcall(fn, value)
        if not ok then print(('[whip_core:prefs] the hook for %s failed: %s'):format(key, tostring(err))) end
    end
    local def = _defs[key]
    if def and def.page then sendPageValues() end
end

--- The server's config for these rows moved, so their `forced` may answer differently: their listeners hear the
--- value in force now, and the page is told once.
---@param keys string[]
function PlayerPrefs.recheck(keys)
    for _, key in ipairs(keys or {}) do
        if _defs[key] then
            local value = PlayerPrefs.get(key)
            for _, fn in ipairs(_hooks[key] or {}) do
                local ok, err = pcall(fn, value)
                if not ok then print(('[whip_core:prefs] the hook for %s failed: %s'):format(key, tostring(err))) end
            end
        end
    end
    sendPageValues()
end

--- Change one, as the page does. A choice equal to the default is not kept: the player follows the default again.
---@param key string
---@param value any
---@return boolean ok, string|nil why
function PlayerPrefs.set(key, value)
    local def = _defs[key]
    if not def then return false, 'no such setting' end
    if forcedOf(def) ~= nil then return false, 'Disabled by server admin' end
    local v = clean(def, value)
    if v == nil then return false, 'not a value this setting takes' end
    if def.setter then
        local ok, err = pcall(def.setter, v)
        if not ok then return false, tostring(err) end
        fire(key, v)
        return true
    end
    local was = PlayerPrefs.get(key)
    if v == clean(def, defaultOf(def)) then _chosen[key] = nil else _chosen[key] = v end
    save()
    if v ~= was then fire(key, v) end
    return true
end

--- fn(value) when it changes on this PC (the page, or Reset). Not called for a change of the server's default:
--- a file whose default follows Config hears that through Settings.onChange as before.
---@param key string
---@param fn function
function PlayerPrefs.onChange(key, fn)
    if type(key) ~= 'string' or type(fn) ~= 'function' then return end
    _hooks[key] = _hooks[key] or {}
    table.insert(_hooks[key], fn)
end

-- ---- declaring ----

local TYPES = { toggle = true, choice = true, slider = true }

--- `def` checked and copied into what this file keeps. Answers nil and why for one it cannot show.
local function normalise(def)
    if type(def) ~= 'table' then return nil, 'needs a table' end
    if type(def.key) ~= 'string' or not def.key:match('^[%w_%.%-]+$') or #def.key > 64 then
        return nil, 'key must be letters, digits, dots, dashes or underscores (1-64)'
    end
    if not TYPES[def.type] then return nil, 'type must be toggle, choice or slider' end
    if type(def.label) ~= 'string' or def.label == '' then return nil, 'label is required' end
    local d = {
        key = def.key, type = def.type, label = def.label:sub(1, 60),
        group = type(def.group) == 'string' and def.group:sub(1, 30) or 'Other',
        help = type(def.help) == 'string' and def.help:sub(1, 240) or nil,
        unit = type(def.unit) == 'string' and def.unit:sub(1, 12) or nil,
        default = def.default, visible = def.visible, page = def.page == true,
        forced = type(def.forced) == 'function' and def.forced or nil,
    }
    if def.type == 'choice' then
        local opts = {}
        for _, o in ipairs(type(def.options) == 'table' and def.options or {}) do
            if type(o) == 'table' and o.value ~= nil and type(o.label) == 'string' then
                opts[#opts + 1] = { value = o.value, label = o.label:sub(1, 40) }
            end
        end
        if #opts < 2 then return nil, 'a choice needs at least two options, each { value, label }' end
        d.options = opts
    elseif def.type == 'slider' then
        d.min, d.max, d.step = tonumber(def.min), tonumber(def.max), tonumber(def.step) or 1
        if not d.min or not d.max or d.max <= d.min or d.step <= 0 then
            return nil, 'a slider needs min < max and a step over 0'
        end
    end
    return d
end

--- whip_core's own rows. Call at file scope, in the file that reads the value.
---@param def table
function PlayerPrefs.define(def)
    local d, why = normalise(def)
    if not d then
        print(('[whip_core:prefs] %s is left off the page: %s'):format(tostring(type(def) == 'table' and def.key), why))
        return false
    end
    listed(d.key)
    _defs[d.key] = d
    return true
end

-- A satellite's rows: on the one registration rule (shared/registry.lua), unscoped, so a key is its resource's,
-- another running resource asking for it is refused, and the rows go when their resource stops. Its value stays
-- with it: `get` and `set` are called across the export (callable, though not of type 'function' there).
local satReg = Registry.new('playerSettings', {
    label  = 'player setting',
    store  = {},
    onAdd = function(_, value)
        listed(value.key)   -- once: a restarted resource's row goes back in its place
        _defs[value.key] = value
    end,
    onRemove = function(_, value)
        if _defs[value.key] == value then _defs[value.key] = nil end
    end,
})

exports('__RegisterPlayerSetting', function(def)
    local owner = Registry.caller()
    local d, why = normalise(def)
    if not d then return false, why end
    if def.get == nil or def.set == nil then return false, 'a resource\'s setting needs get and set (its value stays yours)' end
    if _defs[d.key] and not _defs[d.key].owner then return false, ('%s is one of whip_core\'s own'):format(d.key) end
    -- Data only across the export: no `visible`, and a default that is a value (the reset puts it back).
    -- Required: with none, or a function (which arrives as no value), the row reads "changed" for good and
    -- Reset puts nothing back.
    d.visible = nil
    d.default = clean(d, def.default)
    if d.default == nil then
        return false, 'a resource\'s setting needs a default: a plain value its type takes (Reset puts it back)'
    end
    d.getter, d.setter, d.owner = def.get, def.set, owner
    return satReg:add(owner, d.key, d)
end)

--- A setting's value in force (whip_core's own or a resource's), for a resource that wants to read one.
exports('GetPlayerSetting', function(key)
    return PlayerPrefs.get(key)
end)

--- Change one as the page does, for a resource that shows the same setting in its own screen (whip_phone's call
--- volume, from its Settings). The player's own choice on their own PC: any resource may.
exports('SetPlayerSetting', function(key, value)
    if type(key) ~= 'string' then return false, 'no such setting' end
    return PlayerPrefs.set(key, value)
end)

-- ---- the page (html/js/prefs.js) ----

local function rowOf(def)
    if type(def.visible) == 'function' then
        local ok, v = pcall(def.visible)
        if ok and not v then return nil end
    end
    local value = PlayerPrefs.get(def.key)
    local default = clean(def, defaultOf(def))
    -- Decided by the server: shown greyed with what it is, never "changed" (a page's reset has nothing to put back).
    local locked = forcedOf(def) ~= nil
    return {
        key = def.key, type = def.type, label = def.label, help = def.help, unit = def.unit,
        options = def.options, min = def.min, max = def.max, step = def.step,
        value = value, default = default, changed = not locked and value ~= default, locked = locked or nil,
    }
end

--- Every row, by group, in the page's order.
local function pageState(extra)
    local byName = {}
    local function groupOf(name)
        local g = byName[name]
        if not g then
            g = { id = name, label = name, rows = {} }
            byName[name] = g
        end
        return g
    end
    for _, name in ipairs(GROUP_ORDER) do groupOf(name) end
    local any = false
    for _, key in ipairs(_order) do
        local def = _defs[key]
        local row = def and rowOf(def)
        if row then
            table.insert(groupOf(def.group).rows, row)
            if row.changed then any = true end
        end
    end
    local list = {}
    for _, name in ipairs(GROUP_ORDER) do
        if #byName[name].rows > 0 then list[#list + 1] = byName[name] end
        byName[name] = nil
    end
    -- Groups no one listed, in the order their first row came.
    for _, key in ipairs(_order) do
        local def = _defs[key]
        local g = def and byName[def.group]
        if g and #g.rows > 0 then
            list[#list + 1] = g
            byName[def.group] = nil
        end
    end
    local st = { groups = list, changed = any }
    if extra then for k, v in pairs(extra) do st[k] = v end end
    return st
end

RegisterNUICallback('prefsState', function(_, cb)
    cb(pageState())
end)

RegisterNUICallback('prefsSet', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' then return cb(pageState({ error = 'no such setting' })) end
    local ok, why = PlayerPrefs.set(data.key, data.value)
    cb(pageState(ok and nil or { error = why }))
end)

--- Every row back to its default — on one page (`group`: the page's "Reset this page", its tab's id) or on all of them:
--- whip_core's own forgotten, a resource's set to the default it gave.
RegisterNUICallback('prefsReset', function(data, cb)
    local group = type(data) == 'table' and type(data.group) == 'string' and data.group or nil
    for _, key in ipairs(_order) do
        local def = _defs[key]
        if def and (not group or def.group == group) then
            local d = clean(def, defaultOf(def))
            if d ~= nil and PlayerPrefs.get(key) ~= d then PlayerPrefs.set(key, d) end
        end
    end
    -- All of them: anything kept for a row no longer declared goes too. One page: set to its defaults, which a row
    -- that is whip_core's own forgets by itself (PlayerPrefs.set).
    if not group then _chosen = {} end
    save()
    cb(pageState())
end)

-- The page's own values (the cursor speed) once it is up; again for a page that reloaded.
CreateThread(function()
    Wait(1000)
    sendPageValues()
end)
RegisterNetEvent('whip_core:client:playerLoaded', sendPageValues)

-- ---- the menu cursor's speed on a pad (html/js/pad-cursor.js reads it) ----

PlayerPrefs.define({
    key = 'pad.cursorSpeed', group = 'Controller', type = 'slider', label = 'Menu cursor speed',
    help = 'How fast the circle moves with the left stick in the inventory, /whip and other menus.',
    min = 50, max = 200, step = 10, unit = '%', default = 100, page = true,
})
