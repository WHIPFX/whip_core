-- Dungeon Mode in the world: what it changed, on every game. Map props a Dungeon Master removed
-- (server/director/live.lua) are hidden here too, as a model hide where each stood; only the map's own, never a
-- script's, so a Dungeon prop of the same model still shows. The server sends the whole list on change and on
-- character load; one that left the list is shown again.

local HIDE_RADIUS = 0.5
local hidden = {}   -- [id] = { model, x, y, z }

RegisterNetEvent('whip_core:client:liveHides', function(list)
    local want = {}
    for _, h in ipairs(type(list) == 'table' and list or {}) do
        local id, model = tonumber(h.id), math.tointeger(tonumber(h.model))
        local x, y, z = tonumber(h.x), tonumber(h.y), tonumber(h.z)
        if id and model and x and y and z then
            if model > 0x7FFFFFFF then model = model - 0x100000000 end
            want[id] = { model = model, x = x, y = y, z = z }
        end
    end
    for id, h in pairs(hidden) do
        if not want[id] then
            RemoveModelHide(h.x, h.y, h.z, HIDE_RADIUS, h.model, false)
            hidden[id] = nil
        end
    end
    for id, h in pairs(want) do
        if not hidden[id] then
            CreateModelHideExcludingScriptObjects(h.x, h.y, h.z, HIDE_RADIUS, h.model, true)
            hidden[id] = h
        end
    end
end)

-- Effects: smoke, sparks, flames, steam and a glow on a prop or ground item. The server's list
-- (server/director/live.lua) is sent whole on change. Each effect is drawn on this game's own copy of its thing
-- over its top once within FX_RANGE (on the map's own prop, where it stands), and restarted if the thing is made
-- again. Checked every FX_MS, only while the list has any; a glow is a light, drawn every frame while near.

local FX_RANGE, FX_MS = 120.0, 500
-- GTA's looped effects, in its core set.
local FX = {
    smoke  = { asset = 'core', name = 'ent_amb_smoke_foundry', scale = 0.4 },
    sparks = { asset = 'core', name = 'ent_amb_sparking_wires', scale = 1.0 },
    flames = { asset = 'core', name = 'ent_amb_barrel_fire', scale = 0.8 },
    steam  = { asset = 'core', name = 'ent_amb_steam', scale = 1.0 },
}
local GLOW = { r = 255, g = 196, b = 128, range = 7.0, intensity = 4.0 }

local fxList = {}   -- the server's: { kind, wire, i, ground, net, x, y, z }
local running = {}  -- [n] = { handle, ent }: the effects started, by their place in the list
local glows = {}    -- the glows near now: { x, y, z } (drawn every frame)
local fxOn, glowOn = false, false

--- Its thing's object on this game (nil: not here), or nil and its spot (the map's own prop).
local function placeOf(e)
    if e.wire then return (PropSets.pieceOf(e.wire, e.i or 1)) end
    if e.ground then return GroundPiles.prop(e.ground) end
    if e.net then
        if not NetworkDoesNetworkIdExist(e.net) then return nil end
        local ent = NetworkGetEntityFromNetworkId(e.net)
        return ent ~= 0 and DoesEntityExist(ent) and ent or nil
    end
    return nil, vector3(e.x, e.y, e.z)
end

--- How high its top is over its origin.
local function topOf(ent)
    local _, mx = GetModelDimensions(GetEntityModel(ent))
    return mx and mx.z or 0.5
end

local function stop(n)
    local r = running[n]
    if r and r.handle then StopParticleFxLooped(r.handle, false) end
    running[n] = nil
end

local function startGlowLoop()
    if glowOn then return end
    glowOn = true
    CreateThread(function()
        while next(glows) do
            for _, g in pairs(glows) do
                DrawLightWithRange(g.x, g.y, g.z, GLOW.r, GLOW.g, GLOW.b, GLOW.range, GLOW.intensity)
            end
            Wait(0)
        end
        glowOn = false
    end)
end

--- One look: every nearby effect runs on its thing as it is now; every other is stopped.
local function fxPass()
    local me = GetEntityCoords(PlayerPedId())
    local nextGlows = {}
    for n, e in ipairs(fxList) do
        local ent, spot = placeOf(e)
        local at = ent and GetEntityCoords(ent) or spot
        local near = at ~= nil and #(at - me) <= FX_RANGE
        ---@cast at -nil   -- read below only when near
        if e.kind == 'light' then
            if near then
                local z = ent and (at.z + topOf(ent) + 0.3) or (at.z + 0.6)
                nextGlows[n] = { x = at.x, y = at.y, z = z }
            end
        else
            local fx = FX[e.kind]
            local r = running[n]
            if not near or not fx then
                if r then stop(n) end
            elseif not r or r.ent ~= ent or r.kind ~= e.kind then
                if r then stop(n) end
                if LoadPtfxAsset(fx.asset, 3000) then
                    UseParticleFxAsset(fx.asset)
                    local handle
                    if ent then
                        handle = StartParticleFxLoopedOnEntity(fx.name, ent, 0.0, 0.0, topOf(ent), 0.0, 0.0, 0.0, fx.scale, false, false, false)
                    else
                        handle = StartParticleFxLoopedAtCoord(fx.name, at.x, at.y, at.z + 0.3, 0.0, 0.0, 0.0, fx.scale, false, false, false, false)
                    end
                    running[n] = { handle = handle, ent = ent, kind = e.kind }
                end
            end
        end
    end
    glows = nextGlows
    if next(glows) then startGlowLoop() end
end

local function startFx()
    if fxOn then return end
    fxOn = true
    CreateThread(function()
        while #fxList > 0 do
            fxPass()
            Wait(FX_MS)
        end
        fxOn = false
    end)
end

RegisterNetEvent('whip_core:client:liveEffects', function(list)
    -- New list: everything stops; the next look starts what is near.
    for n in pairs(running) do stop(n) end
    fxList, glows = {}, {}
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if type(e) == 'table' and (FX[e.kind] or e.kind == 'light') and tonumber(e.x) and tonumber(e.y) and tonumber(e.z) then
            fxList[#fxList + 1] = { kind = e.kind, wire = tonumber(e.wire), i = tonumber(e.i), ground = tonumber(e.ground),
                                    net = tonumber(e.net), x = tonumber(e.x), y = tonumber(e.y), z = tonumber(e.z) }
        end
    end
    if #fxList > 0 then startFx() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, h in pairs(hidden) do RemoveModelHide(h.x, h.y, h.z, HIDE_RADIUS, h.model, false) end
    hidden = {}
    for n in pairs(running) do stop(n) end
    fxList, glows = {}, {}
end)
