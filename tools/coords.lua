-- ============================================
-- Dev Tools — Coords Display
-- ============================================
--
-- A coordinate read and a comparison ten times a second while the tool is open, and an NUI message
-- only when a number the display shows has changed: flooding the NUI channel every frame backs its
-- queue up, so the readout lags further behind, not less.
--
-- The G key is a binding (free, and movable in Settings), not a per-frame control read. The loop is
-- born on open, like /radardebug, the /w dev menu and /paddebug.

-- Coords state. tools/core.lua hears about a finished copy through OnClipboardCopied, just below.
local coordsActive = false

OnClipboardCopied(function()
    if coordsActive then
        SendNUIMessage({ action = 'coordsCopied' })
    end
end)

--- How often the readout is refreshed while the tool is open.
---
--- TEN A SECOND IS FASTER THAN ANYONE CAN READ FOUR CHANGING NUMBERS. The reason to go no slower
--- is that walking to a spot and watching the value settle is how this tool is actually used, and
--- a slower rate makes that feel disconnected from the footsteps.
local COORDS_TICK_MS = 100

--- How much a value must move before the page is told.
---
--- MATCHED TO WHAT THE DISPLAY SHOWS. The readout is formatted to two decimal places, so anything
--- smaller than 0.01 is a message that repaints the same characters. A ped standing still still
--- drifts in the far decimals — breathing animation moves the entity — which is precisely the
--- noise this sits under.
local COORDS_EPSILON = 0.01

--- The payload, allocated once and refilled. Same reasoning as the vehicle dials in
--- client/vehicle_hud.lua: SendNUIMessage serialises before it returns, so reuse is safe, and a
--- table per message on a fixed cadence is garbage produced forever.
local _coordsMsg = { action = 'coordsUpdate', x = 0.0, y = 0.0, z = 0.0, h = 0.0 }

--- What the page was last told. nil means "nothing sent yet", which must always send.
local lastX, lastY, lastZ, lastH = nil, nil, nil, nil

--- True while the readout thread is alive, so opening twice cannot start two of them.
local coordsThreadRunning = false

--- Read the ped once and hand back all four values, so the thread and the copy command cannot
--- disagree about what "here" means.
---@return number, number, number, number
local function ReadHere()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    return c.x, c.y, c.z, GetEntityHeading(ped)
end

local function StartCoordsThread()
    if coordsThreadRunning then return end
    coordsThreadRunning = true

    CreateThread(function()
        while coordsActive do
            local x, y, z, h = ReadHere()

            if lastX == nil
                or math.abs(x - lastX) >= COORDS_EPSILON
                or math.abs(y - lastY) >= COORDS_EPSILON
                or math.abs(z - lastZ) >= COORDS_EPSILON
                or math.abs(h - lastH) >= COORDS_EPSILON then
                lastX, lastY, lastZ, lastH = x, y, z, h

                _coordsMsg.x = x
                _coordsMsg.y = y
                _coordsMsg.z = z
                _coordsMsg.h = h
                SendNUIMessage(_coordsMsg)
            end

            Wait(COORDS_TICK_MS)
        end

        coordsThreadRunning = false
    end)
end

-- ============================================
-- Copying
-- ============================================

--- Where the player stands, as config text: 'vector2', 'vector3', 'vector4' or 'heading'. The one format for the G key
--- below and the /vector2, /vector3, /vector4 and /heading commands (server/commands.lua).
---
--- READS THE PED RATHER THAN THE LAST SENT VALUE. What is on screen may be up to COORDS_EPSILON
--- and one tick behind; what gets pasted into a config should be where the developer is standing
--- at the moment they press the key, not what the readout happened to be showing.
---@param kind string
---@return string
local function coordsText(kind)
    local x, y, z, h = ReadHere()
    if kind == 'vector2' then return ('vector2(%.2f, %.2f)'):format(x, y) end
    if kind == 'vector3' then return ('vector3(%.2f, %.2f, %.2f)'):format(x, y, z) end
    if kind == 'heading' then return ('%.2f'):format(h) end
    return ('vector4(%.2f, %.2f, %.2f, %.2f)'):format(x, y, z, h)
end

--- Put the current position on the clipboard as a vector4.
RegisterCommand('whip_coords_copy', function()
    -- The tool being open is the whole gate. Without it this would quietly claim G for every
    -- player on the server.
    if not coordsActive then return end

    -- tools/core.lua takes the focus the page needs for the clipboard, and gives back only that.
    CopyToClipboard(coordsText('vector4'))
end, false)

--- /vector2, /vector3, /vector4, /heading: the server has checked whip.devtools and developer mode
--- (server/commands.lua devCommand). The text also goes to F8, to type out if the copy could not happen.
local COPY_KINDS = { vector2 = true, vector3 = true, vector4 = true, heading = true }
RegisterNetEvent('whip_core:client:copyCoords', function(kind)
    if not COPY_KINDS[kind] then return end
    local text = coordsText(kind)
    print('[whip_core] ' .. text)
    CopyToClipboard(text, function(ok)
        UI.Notify(ok and ('Copied ' .. text) or ('Could not copy; it is in F8: ' .. text), ok and 'success' or 'error')
    end)
end)

--- G, as it always was — but bound rather than polled, so it costs nothing when the tool is shut
--- and can be moved by anyone who wants G for something else.
RegisterKeyMapping('whip_coords_copy', 'Dev: Copy Coords', 'keyboard', 'g')

--- The key the copy binding is on, for the readout's keycap: 'G' unless it was moved. Asked as GTA's
--- help text names it ('t_G'), as Interactions.keyLabel does for Interact; a key with no short name
--- (a mouse button) shows as 'G'.
---@return string
local function CopyKeyLabel()
    local s = GetControlInstructionalButton(0, GetHashKey('whip_coords_copy') | 0x80000000, true)
    local key = type(s) == 'string' and s:match('^t_(.+)$') or nil
    return (key and #key <= 6) and key:upper() or 'G'
end

-- ============================================
-- Register with tool system
-- ============================================

ToolHandlers['Coords'] = {
    enter = function()
        coordsActive = true
        -- Forgotten on every open, so re-opening always paints once rather than waiting for the
        -- developer to move before the panel shows anything.
        lastX, lastY, lastZ, lastH = nil, nil, nil, nil

        SendNUIMessage({ action = 'coordsShow', key = CopyKeyLabel() })
        -- AFTER coordsActive is set: the thread's loop condition is that flag, so starting it any
        -- earlier would have it read false and exit immediately.
        StartCoordsThread()
    end,
    exit = function()
        -- Clearing the flag is also how the thread stops — it exits on its next wake and clears
        -- coordsThreadRunning on the way out.
        coordsActive = false
        SendNUIMessage({ action = 'coordsHide' })
    end,
}
