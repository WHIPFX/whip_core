--[[
    NUI CAPS — what the game's browser can do

    FiveM's browser is moving from Chromium 103 to Chromium 144. whip's pages ask the browser what it can do, feature by feature (html/js/caps.js), and
    whip_core's page tells this file once it is up (html/js/nui-caps.js), so Lua and other resources
    can ask too:

        exports.whip_core:GetNuiCaps()     -- Whip.call('GetNuiCaps') from a satellite
        AddEventHandler('whip_core:nui:capsDetected', function(caps) ... end)

    /nuicaps prints the answers; /nuicaps gameview shows FiveM's new game view in a box for a few
    seconds (the test that it works on this build).
]]

-- What the page may report, and each one's type: anything else it sends is dropped
local KNOWN = {
    chrome = 'number',
    has = 'boolean', colorMix = 'boolean', relativeColor = 'boolean', textBalance = 'boolean',
    startingStyle = 'boolean', heightAuto = 'boolean', anchor = 'boolean', fieldSizing = 'boolean',
    viewTransitions = 'boolean', schedulerYield = 'boolean', webgpu = 'boolean',
    zoomScreenPx = 'boolean', gameView = 'boolean',
}

-- In the order /nuicaps prints them
local ORDER = { 'chrome', 'has', 'colorMix', 'relativeColor', 'textBalance', 'startingStyle', 'heightAuto',
    'anchor', 'fieldSizing', 'viewTransitions', 'schedulerYield', 'webgpu', 'zoomScreenPx', 'gameView' }

---@type table|nil
local caps = nil

local function copyCaps()
    ---@cast caps -nil   -- asked for only once the page has said
    local out = {}
    for key, value in pairs(caps) do out[key] = value end
    return out
end

RegisterNUICallback('nuiCaps', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' then return end
    local fresh = {}
    for key, kind in pairs(KNOWN) do
        if type(data[key]) == kind then fresh[key] = data[key] end
    end
    local changed = caps == nil
    if caps then
        for key in pairs(KNOWN) do
            if caps[key] ~= fresh[key] then changed = true break end
        end
    end
    caps = fresh
    if changed then WhipEmit('whip_core:nui:capsDetected', copyCaps()) end
end)

--- What the game's browser can do, once whip_core's page has said: a copy, so a caller can keep it.
--- Before then: false, 'not_detected_yet' (listen for whip_core:nui:capsDetected).
exports('GetNuiCaps', function()
    if not caps then return false, 'not_detected_yet' end
    return copyCaps()
end)

DevCommand('nuicaps', function(_, args)
    if not caps then
        print('[whip_core] the page has not reported what the browser can do yet')
        return
    end
    if args[1] == 'gameview' then
        if not caps.gameView then
            UI.Notify('This FiveM build has no new game view (it came with Chromium 144)', 'error')
            return
        end
        SendNUIMessage({ action = 'nuiCapsGameView', seconds = 8 })
        return
    end
    print('[whip_core] what the game\'s browser can do:')
    for _, key in ipairs(ORDER) do
        print(('  %-16s %s'):format(key, tostring(caps[key])))
    end
    local newer = caps.zoomScreenPx and caps.startingStyle
    UI.Notify(('Browser: Chrome %s, %s (F8 for the list)'):format(tostring(caps.chrome or '?'),
        newer and 'the new features are on' or 'FiveM\'s older browser'), 'info')
end)
