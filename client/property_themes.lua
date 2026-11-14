-- ============================================
-- PROPERTY THEMES — the sign's Theme, Client
-- ============================================
--
-- Beside Furnish, a Theme option: the home's looks as colour swatches, like whip_autos' paints. The
-- looks are the interior resource's (server/property_themes.lua finds them); this asks the server for
-- them, shows them as swatches (html/js/property-themes.js), and
-- sends the one picked. The page stays open, so the next can be tried: the home is redrawn around the
-- player each time (its resource fades the screen while it does).
--
-- Mouse, keys and pad, as every whip screen: the page's nav scope takes the pad.

local openId = nil     -- the property the picker is open on

local function close()
    if not openId then return end
    openId = nil
    Focus.release('propertyThemes')
    SendNUIMessage({ action = 'propertyThemesClose' })
end

--- Open the picker on a property's looks (its sign's Theme). The server decides who may.
---@param propertyId number|nil
function OpenPropertyThemes(propertyId)
    propertyId = tonumber(propertyId)
    if openId or not propertyId then return end
    if MayOpenScreen and not MayOpenScreen() then return end
    CreateThread(function()
        local info, why = Callback('whip_core:property:themes', propertyId)
        if type(info) ~= 'table' or type(info.themes) ~= 'table' then
            UI.Notify(type(why) == 'string' and why or 'Could not read its themes', 'error')
            return
        end
        if openId or (MayOpenScreen and not MayOpenScreen()) then return end
        openId = propertyId
        Focus.take('propertyThemes', { screen = true })
        SendNUIMessage({
            action = 'propertyThemesOpen',
            title = info.name or 'Theme', label = info.label, current = info.current, themes = info.themes,
        })
        -- Gone from the home, dead or logged out: the picker goes too.
        local start = GetEntityCoords(PlayerPedId())
        while openId == propertyId do
            Wait(500)
            local here = GetEntityCoords(PlayerPedId())
            if PlayerIsDead or not PlayerLoaded or #(here - start) > 15.0 then close() end
        end
    end)
end

RegisterNUICallback('propertyThemePick', function(data, cb)
    cb('ok')
    local id = math.tointeger(tonumber(data and data.id))
    if openId and id then TriggerServerEvent('whip_core:server:propertySetTheme', openId, id) end
end)

RegisterNUICallback('propertyThemesClose', function(_, cb)
    cb('ok')
    close()
end)

-- The server's answer: the page marks the theme in force (or takes back its "Applying…").
RegisterNetEvent('whip_core:client:propertyThemeSet', function(propertyId, ok, themeId)
    if openId and tonumber(propertyId) == openId then
        SendNUIMessage({ action = 'propertyThemeSet', ok = ok == true, id = themeId })
    end
end)

AddEventHandler('whip_core:player:logout', function() close() end)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then Focus.release('propertyThemes') end
end)
