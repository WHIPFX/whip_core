-- ============================================
-- Item settings — the client half
-- ============================================
--
-- Every item's own settings (server/item_settings.lua), as the server has them in force: sent when
-- this game asks as it starts (and again when whip_core is ready), and again for an item whenever one
-- of its settings changes. A resource reads them as it does on the server:
--
--     local capacity = exports.whip_core:GetItemSetting('pistol_mag', 'capacity')
--     exports.whip_core:OnItemSettingChanged('pistol_mag', 'capacity', function(value, old) end)
--
-- Until the server has answered, GetItemSetting answers nil: keep your own value until then, and take
-- the server's in the change hook, which runs when it arrives. (Only an item's own settings here: its
-- name, description and weight reach this game in the inventory's item definitions.)

ItemSettings = {}

local values = {}   -- [item] = { [key] = value }

-- '<resource>:<item>|<key>' = fn: one per resource for each setting, gone when it stops.
local listeners = {}
local _listeners = Registry.new('ItemSettingListener', {
    label = 'item setting listener', store = listeners, scoped = true, same = false,
})

---@param item string
---@param key string
---@param value any
---@param old any
local function tell(item, key, value, old)
    local suffix = ':' .. item .. '|' .. key
    for k, fn in pairs(listeners) do
        if k:sub(-#suffix) == suffix then
            local ok, err = pcall(fn, value, old, item, key)
            if not ok then
                print(('^1[whip_core:items] %s\'s hook for %s %s errored: %s^0'):format(k:match('^[^:]+'), item, key, tostring(err)))
            end
        end
    end
end

--- An item's settings as the server sent them: each one that differs from what we had is told.
---@param item string
---@param list table|nil  { [key] = value }; nil when it has none now
local function adopt(item, list)
    local had = values[item] or {}
    local now = type(list) == 'table' and list or {}
    values[item] = next(now) and now or nil
    for key, v in pairs(now) do
        if not Settings.same(had[key], v) then tell(item, key, v, had[key]) end
    end
    for key, v in pairs(had) do
        if now[key] == nil then tell(item, key, nil, v) end
    end
end

-- `whole`: the answer to our hello, every item's; an item not in it has no settings of its own now.
RegisterNetEvent('whip_core:client:itemSettings', function(items, whole)
    if type(items) ~= 'table' then return end
    if whole then
        for item in pairs(values) do
            if items[item] == nil then adopt(item, nil) end
        end
    end
    for item, list in pairs(items) do
        if type(item) == 'string' then adopt(item, list) end
    end
end)

TriggerServerEvent('whip_core:server:itemSettingsHello')
RegisterNetEvent('whip_core:client:coreReady', function()
    TriggerServerEvent('whip_core:server:itemSettingsHello')
end)

--- One of an item's own settings in force, or nil (not known yet, or not one it has).
---@param item string
---@param key string
---@return any
---@diagnostic disable-next-line: duplicate-set-field -- the server's ItemSettings is a different table
function ItemSettings.get(item, key)
    local list = type(item) == 'string' and values[item]
    if not list or type(key) ~= 'string' then return nil end
    return Settings.copy(list[key])
end

exports('GetItemSetting', function(item, key)
    return ItemSettings.get(item, key)
end)

--- fn(value, old, item, key) after one of an item's own settings changes on this game, including the
--- first time the server sends it. ONE per resource for each setting: calling again replaces it.
exports('OnItemSettingChanged', function(item, key, fn)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(item) ~= 'string' or type(key) ~= 'string' or fn == nil then
        return false, 'OnItemSettingChanged(item, key, function(value, old, item, key) end)'
    end
    local ok, why = _listeners:add(owner, item .. '|' .. key, fn)
    if not ok then return false, why end
    return true
end)
