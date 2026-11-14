-- ============================================
-- Reveal Players — the server half of the /w tool
-- ============================================
--
-- Every player with a character, sent once a second to each admin who has Reveal Players on: where they
-- stand and face, their character's name and charId, and their account's name (GetPlayerName: the Steam
-- name when Steam is running, the FiveM account's otherwise). tools/show_players.lua draws them — a blip
-- on the minimap and the pause map, and blue words over the head of anyone near enough to see.
--
-- BORN WITH THE FIRST VIEWER, ENDED WITH THE LAST: nobody pays for the loop until an admin turns it on.
-- Each push asks again (DevTools.eachViewer), so developer mode going off, or dev tools taken back,
-- drops the viewer at the next second.

local viewers = DevTools.viewers.sp
local PUSH_MS = 1000
local looping = false

--- One decimal is plenty for a blip, and keeps a full server's list small.
local function r1(v) return math.floor(v * 10 + 0.5) / 10 end

--- Every player with a character in the world: { s, c, n, a, x, y, z, h }.
local function snapshot()
    local list = {}
    for src, p in pairs(Players) do
        if not p.phantom then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local at = GetEntityCoords(ped)
                list[#list + 1] = {
                    s = src, c = p.charId, n = p.fullName or '?', a = GetPlayerName(src) or '?',
                    x = r1(at.x), y = r1(at.y), z = r1(at.z), h = math.floor(GetEntityHeading(ped) + 0.5),
                }
            end
        end
    end
    return list
end

local function startLoop()
    if looping then return end
    looping = true
    CreateThread(function()
        while next(viewers) do
            local ok, list = pcall(snapshot)
            if ok then
                DevTools.eachViewer(viewers, function(src)
                    TriggerClientEvent('whip_core:client:showPlayers', src, list)
                end)
            else
                print(('[whip_core:dev] Reveal Players could not read the players: %s'):format(tostring(list)))
            end
            Wait(PUSH_MS)
        end
        looping = false
    end)
end

--- On or off. NO ACE: turning it off is never refused (the menu's exit, developer mode going off).
--- Turning it on asks DevTools.isAllowed itself, so an admin with developer mode off is told why.
SecureEvent('whip_core:server:devShowPlayers', {
    rateLimit = 500,
    whileDead = true,
    requirePlayer = false,
    params = { {'on', 'bool'} },
}, function(source, _, on)
    if not on then
        viewers[source] = nil
        return
    end
    if not DevTools.isAllowed(source) then
        if DevTools.isEligible(source) then
            DevTools.sayOff(source)
            return false
        end
        return false, 'Not permitted'
    end
    viewers[source] = true
    startLoop()
end)
