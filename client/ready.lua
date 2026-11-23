-- ============================================
-- READINESS SIGNAL — CLIENT
-- ============================================
--
-- The client half of the same problem the server solves in player_lifecycle.lua.
--
-- A satellite's client code wants to register aim-target options, stat watchers, blips and item
-- behaviour against whip_core, and needs to know when whip_core can receive them.
--
-- A SATELLITE DOES NOT LISTEN TO THIS DIRECTLY. It includes the satellite helper and writes
--
--     Whip.register(register)          -- @whip_core/lib/satellite.lua
--
-- which listens here for it and runs `register` only when it matters: when whip_core finishes
-- loading or restarts underneath the satellite ({ reason = 'coreStarted' }), and when the
-- satellite ITSELF starts while whip_core is already up ({ reason = 'resourceStarted',
-- resources } naming it — see the re-announce at the bottom of this file).
--
-- A raw AddEventHandler('whip_core:onReady', register) also hears every OTHER resource starting.
-- Registration must be idempotent either way, because a core restart runs it again.
--
-- Not an export that takes the function: the registry would live in whip_core's Lua state, which a
-- whip_core restart destroys. An event handler lives in the SATELLITE's state, so it outlives core.
--
-- This file is loaded LAST in client_scripts on purpose: "ready" has to mean every client file
-- has run, or the signal is a lie.

CoreReady = false

-- A runtime theme override applyTheme brought: nil = none (Config.Theme stands), false = "no theme".
local themeNow = nil

-- The inventory UI /whip_inventory_ui picked on this client: nil = none (the configured one stands),
-- false = whip's own.
local rendererNow = nil

--- The configured custom inventory renderer: the server's replicated whip_inventory_renderer, else
--- Config.InventoryRenderer. nil = whip's own.
local function configuredRenderer()
    local renderer = GetConvar('whip_inventory_renderer', '')
    if renderer == '' then renderer = Config.InventoryRenderer end
    if renderer == '' then return nil end
    return renderer
end

--- The inventory UI this client draws with now. nil = whip's own.
local function currentRenderer()
    if rendererNow ~= nil then return rendererNow or nil end
    return configuredRenderer()
end

--- Tell the page its theme, inventory renderer and where the media packs' pictures come from.
---
--- At load, and again when a character loads: at load the page may not be listening yet, and by the
--- time a character is loaded it is. Both are safe to repeat: theme.js replaces its link, and
--- renderer-loader.js takes the configured renderer once (a live change is swapInventoryRenderer).
local function sendPageSettings()
    -- Config.Theme names a resource whose theme.css overrides base.css's tokens — html/js/theme.js
    -- does the injection and fails soft to the base look if the resource is missing.
    local theme = Config.Theme
    if themeNow ~= nil then theme = themeNow or nil end
    SendNUIMessage({ action = 'setTheme', resource = theme })
    -- The custom inventory renderer — see html/js/renderer-loader.js. Fails soft to whip's own.
    SendNUIMessage({ action = 'setInventoryRenderer', resource = configuredRenderer() })
    -- Each media pack: its own pictures, or WHIP's CDN's (server/media.lua, html/js/assets.js)
    SendNUIMessage({ action = 'whipAssetSources', sources = GlobalState.whipMedia })
end

-- The server changed where a pack's pictures come from (a pack started or stopped, a fresh CDN list): this page and
-- the world pages that show pictures.
AddStateBagChangeHandler('whipMedia', 'global', function(_, _, value)
    SendNUIMessage({ action = 'whipAssetSources', sources = value })
    DuiPage.sendAssetSources(value)
end)

--- Announce readiness locally.
---
--- Fired on this client only. Satellites listen with a plain AddEventHandler; there is no
--- network hop, so there is nothing here for a client to spoof to anyone but itself.
local function announce()
    if CoreReady then return end
    CoreReady = true
    -- { reason = 'coreStarted' }: whip_core has just loaded on this client and remembers nothing,
    -- so everything must be registered. See the re-announce below for the other reason.
    TriggerEvent('whip_core:onReady', { reason = 'coreStarted' })
    -- After a restart the server starts the satellites again only once every game has said this
    -- (server/satellites_back.lua): started before whip_core was up here, they left it half working.
    TriggerServerEvent('whip_core:server:coreUpHere')

    sendPageSettings()
end

RegisterNetEvent('whip_core:client:playerLoaded', function()
    sendPageSettings()
end)

--- The server's "finished starting" broadcast — a backstop, and in practice a no-op. whip_core's
--- client scripts restart together with its server scripts, and the local announce below runs a
--- tick after they load: seconds before the server is through its schema, migrations and loaders.
--- By the time this arrives, CoreReady is already true.
RegisterNetEvent('whip_core:client:coreReady', announce)

--- The announcement that actually fires, on start and on every whip_core restart: whip_core's
--- client scripts have all loaded.
---
--- So "ready" on the client means the client files have loaded, not that the server is up. Client
--- registrations — aim-targets, item behaviour, stat watchers — need nothing more. Anything that
--- ASKS the server at that moment can find it still booting, and has to retry:
--- RequestCharacterList (client/main.lua) does.
CreateThread(announce)

--- Has whip_core finished loading on this client?
---
--- For code that needs to ASK rather than be told (Whip.isReady asks this). Registration does not
--- need it — Whip.register covers every case on its own.
---@return boolean
exports('IsReady', function()
    return CoreReady == true
end)

-- ============================================
-- Re-announcing for late starters
-- ============================================
--
-- An event cannot reach a listener that was not there when it fired, so a satellite whose client
-- scripts start after whip_core is already loaded would hear nothing. Announcing again when any
-- resource starts closes that, and is what lets Whip.register be a single call instead of an
-- IsReady() check in a thread.
--
-- Coalesced to one announcement per tick: at boot, or after a mass restart, this would otherwise
-- fire once per resource and re-run every satellite's registration each time. The one
-- announcement names every resource in the burst: { reason = 'resourceStarted', resources = {...} }.
local reannounceQueued = nil   -- the names collected this tick, or nil when none is queued

AddEventHandler('onResourceStart', function(res)
    if res == GetCurrentResourceName() then return end
    if not CoreReady then return end
    if reannounceQueued then
        reannounceQueued[#reannounceQueued + 1] = res
        return
    end

    reannounceQueued = { res }
    CreateThread(function()
        Wait(0)
        local started = reannounceQueued
        reannounceQueued = nil
        if CoreReady then
            TriggerEvent('whip_core:onReady', { reason = 'resourceStarted', resources = started })
        end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then CoreReady = false end
end)

-- ============================================
-- Theme iteration (dev)
-- ============================================
--
-- Re-sends setTheme live, so a theme author can edit theme.css and re-apply without a core
-- restart (the browser refetches the link). `/whip_theme` alone re-applies whatever the
-- server currently says — the runtime override if one is active (server/themes.lua), else
-- Config.Theme; `/whip_theme none` drops to the base look; `/whip_theme <resource>` tries
-- any resource. Gated on the devtools ACE via the same callback every dev tool uses.
RegisterCommand('whip_theme', function(_, args)
    TriggerServerEvent('whip_core:server:requestThemeSwap', args[1])
end, false)

RegisterNetEvent('whip_core:client:applyTheme', function(resource)
    themeNow = resource or false   -- so the login re-send (sendPageSettings) keeps it, not Config.Theme
    SendNUIMessage({ action = 'setTheme', resource = resource })
end)

-- Config.Theme changed in /whip → Settings. Players online also get the server's applyTheme; this
-- is for one who joined after the change, whose page took the theme whip_core started with. A
-- runtime override (themeNow) wins, as everywhere else.
Settings.onChange('Theme', function()
    if themeNow == nil then SendNUIMessage({ action = 'setTheme', resource = Config.Theme }) end
end)

-- ============================================
-- Inventory UI, live (dev)
-- ============================================
--
-- `/whip_inventory_ui <resource>` draws THIS player's inventory with that resource's renderer.js now,
-- `/whip_inventory_ui none` with whip's own, and `/whip_inventory_ui` alone loads the current one again
-- from its files. Until the player rejoins; the server's choice is Config.InventoryRenderer /
-- whip_inventory_renderer. The page closes the inventory first (html/js/renderer-loader.js).
--
-- The UI's resource restarting (`ensure my_inventory_ui` after an edit) reloads it on its own: stopped,
-- its files are gone, so whip's own draws; started again, the new files are loaded.
DevCommand('whip_inventory_ui', function(_, args)
    local pick = args[1]
    if pick == 'none' then
        rendererNow = false
        SendNUIMessage({ action = 'swapInventoryRenderer', resource = nil })
        UI.Notify("Inventory: whip's own", 'success')
        return
    end
    local resource = pick or currentRenderer()
    if not resource then
        UI.Notify("Inventory: whip's own is drawing. /whip_inventory_ui <resource> to try another", 'info')
        return
    end
    if GetResourceState(resource) ~= 'started' then
        UI.Notify(resource .. ' is not running: start it on the server first', 'error')
        return
    end
    rendererNow = resource
    SendNUIMessage({ action = 'swapInventoryRenderer', resource = resource })
    UI.Notify('Inventory: ' .. resource .. ' (F8 shows any error)', 'success')
end)

local rendererStopped = {}   -- UI resources stopped while this client ran, to reload when they start

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() or res ~= currentRenderer() then return end
    rendererStopped[res] = true
    SendNUIMessage({ action = 'swapInventoryRenderer', resource = nil })
end)

AddEventHandler('onResourceStart', function(res)
    if not rendererStopped[res] then return end
    rendererStopped[res] = nil
    if res == currentRenderer() then SendNUIMessage({ action = 'swapInventoryRenderer', resource = res }) end
end)
