-- Portrait: the character's face. A headshot of the player's ped is taken a few seconds after every spawn
-- (whip_core:player:spawned, including the creator closing) and after a revive (not while dead). The page draws it
-- into a small picture (html/js/portrait.js) and sends it back here, then to the server (server/portraits.lua),
-- which keeps one per character.
-- The headshot is a TXD the page reads through https://nui-img/ and is freed once read: GTA holds only a few at once.

local TAKE_AFTER_MS = 6000   -- after the spawn: the ped streamed in, dressed and stood still
local READY_MS = 5000        -- how long GTA may take to make the headshot
local HOLD_MS = 4000         -- how long the page may take to read it, before it is freed

local wanted = 0       -- bumped by each spawn: only the newest spawn's headshot is taken
local taking = false  -- one headshot at a time

local function take()
    wanted = wanted + 1
    local mine = wanted
    -- The page's copy may be another character's: until the new one is taken, the page asks the server for the last.
    SendNUIMessage({ action = 'portraitForget' })
    CreateThread(function()
        Wait(TAKE_AFTER_MS)
        -- A quick character switch: the later spawn's take goes on after any still being read.
        while taking and mine == wanted do Wait(200) end
        if mine ~= wanted then return end
        taking = true
        local ped = PlayerPedId()
        -- Dead: the server refuses a dead player's anyway. Taken on revive or respawn (below).
        if not DoesEntityExist(ped) or IsEntityDead(ped) or PlayerIsDead then taking = false return end

        -- Transparent (for a round frame); the plain one if refused.
        local handle = RegisterPedheadshotTransparent(ped)
        if not handle or handle == 0 then handle = RegisterPedheadshot(ped) end
        local deadline = GetGameTimer() + READY_MS
        while not IsPedheadshotReady(handle) and GetGameTimer() < deadline do Wait(100) end

        if IsPedheadshotReady(handle) and IsPedheadshotValid(handle) then
            SendNUIMessage({ action = 'portraitCapture', txd = GetPedheadshotTxdString(handle) })
            Wait(HOLD_MS)
        end
        UnregisterPedheadshot(handle)
        taking = false
    end)
end

AddEventHandler('whip_core:player:spawned', take)
-- A character that loaded dead (or died since) has its face taken once it is back up.
AddEventHandler('whip_core:player:revived', take)

-- A headshot of any ped, handed back (not kept as the character's), e.g. a lore character's face when its look
-- is saved (tools/panel_sections/director.lua). One at a time with the spawn's take.

local shots = {}   -- [id] = the promise waiting for the page's picture
local shotN = 0

--- A headshot of `ped` as a small picture (data: URL, webp or png), or nil on failure. Waits a few seconds at most; call from a thread.
---@param ped number
---@return string|nil image
function TakeHeadshot(ped)
    while taking do Wait(100) end
    if not DoesEntityExist(ped) then return nil end
    taking = true
    local handle = RegisterPedheadshotTransparent(ped)
    if not handle or handle == 0 then handle = RegisterPedheadshot(ped) end
    local deadline = GetGameTimer() + READY_MS
    while not IsPedheadshotReady(handle) and GetGameTimer() < deadline do Wait(100) end
    local image
    if IsPedheadshotReady(handle) and IsPedheadshotValid(handle) then
        shotN = shotN + 1
        local id = shotN
        local p = promise.new()
        shots[id] = p
        SetTimeout(HOLD_MS, function()
            if shots[id] then shots[id] = nil; p:resolve(nil) end
        end)
        SendNUIMessage({ action = 'portraitCapture', txd = GetPedheadshotTxdString(handle), id = id })
        image = Citizen.Await(p)
    end
    UnregisterPedheadshot(handle)
    taking = false
    return image
end

-- The page's picture for a TakeHeadshot (nothing when it could not read the headshot).
RegisterNUICallback('portraitTaken', function(data, cb)
    cb('ok')
    local id = type(data) == 'table' and tonumber(data.id) or nil
    local p = id and shots[id]
    if not (id and p) then return end
    shots[id] = nil
    local image = data.image
    p:resolve(type(image) == 'string' and image:sub(1, 11) == 'data:image/' and image or nil)
end)

-- The page's picture of it, on to the server. Only a string; the server checks the rest.
RegisterNUICallback('portraitSave', function(data, cb)
    if type(data) == 'table' and type(data.image) == 'string' and data.image ~= '' then
        TriggerServerEvent('whip_core:server:portraitSave', data.image)
    end
    cb('ok')
end)

-- The page asks for this character's portrait, kept by the server (html/js/portrait.js myPortrait):
-- { ok = true, image } or { ok = true }; {} when the server did not answer.
RegisterNUICallback('myPortrait', function(_, cb)
    local res = Callback('whip_core:myPortrait')
    cb(type(res) == 'table' and res or {})
end)
