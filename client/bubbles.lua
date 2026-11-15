-- ============================================
-- /me bubbles — the capsule above a player's head (client)
-- ============================================
-- "/me eats an apple" goes to server/bubbles.lua, which sends the cleaned text to everyone within
-- Config.Bubbles.range. Each of them draws it here: one browser (DUI) paints every bubble on screen
-- into its own cell of one texture (html/bubble3d/bubble.html), and each cell is drawn as a
-- camera-facing quad (WorldQuad) whose bottom-centre sits above that player's head. The page does
-- the look and the animations; this file places the quad, frees the cell when the bubbles are gone, and
-- says whether the owner sits in a vehicle (a line under the capsule, down through the roof) or not (a dot).
--
-- One browser however many bubbles, the same rule as interact_world.lua.

local CFG = Config.Bubbles or {}

local CELL_W, CELL_H = 1024, 512
local CELLS     = math.max(1, math.floor(CFG.maxPlayers or 6))
local MAX_STACK = math.max(1, math.floor(CFG.maxStack or 3))
local STALK_PX  = 64
local FOLD_MS   = 1200            -- the page's fold (about 800 ms) and the line going away, with margin
local HEAD_BONE = 31086           -- SKEL_Head

-- Metres per texel: a fixed size in the world, so it is big up close and small far
-- away, like the player it sits on. A one-line capsule is about 0.17 m tall; Config.Bubbles.size scales it.
local MPP = 0.0026

-- A bubble seen from further (its `far`: a lore line's Bonus range, server/bubbles.lua) grows past GROW_FROM metres
-- from the camera, so it is never smaller on screen than it is from there: readable across a street or a chase.
-- One with a range of its own (the Director's NPC /me card's Seen from) keeps its size out to that range: small far
-- off, as the NPC is, and as big as anything else there through a camera zoomed in on it.
local GROW_FROM = 8.0

local TXD, TEX = 'whip_bubble_txd', 'bubbles'

--- [owner] = { cell, untilMs }: whose bubbles are up, in which cell, until when (fold included). An
--- owner is a player's server id, or 'n:<netId>' for an NPC (a conversation, for the players
--- watching it, and the Director's NPC /me card).
local owners = {}
--- [cell] = owner
local cellOwner = {}
local looping = false

--- The browser: made at login and kept until whip_core stops (no idleMs), so the first bubble is not waiting on a
--- page load. Messages wait until it is up.
local page = DuiPage.new({
    name = 'bubbles',
    url = ('bubble3d/bubble.html?w=%d&h=%d&cells=%d&stack=%d&stalk=%d'):format(CELL_W, CELL_H, CELLS, MAX_STACK, STALK_PX),
    width = CELL_W, height = CELL_H * CELLS, txd = TXD, tex = TEX, without = '/me bubbles will not draw',
})

local function send(msg)
    page:send(msg)
end

local function attach()
    return page:ensure()
end

local function release(serverId)
    local o = owners[serverId]
    if not o then return end
    owners[serverId] = nil
    cellOwner[o.cell] = nil
    send({ cell = o.cell - 1, clear = true })
end

--- A free cell, or the one whose bubbles end soonest (its owner loses them early).
local function claimCell()
    for i = 1, CELLS do
        if not cellOwner[i] then return i end
    end
    local soonest, soonestId = nil, nil
    for id, o in pairs(owners) do
        if not soonest or o.untilMs < soonest then soonest, soonestId = o.untilMs, id end
    end
    local cell = owners[soonestId].cell
    release(soonestId)
    return cell
end

local function pedOf(owner, myId)
    if type(owner) == 'string' then
        local netId = tonumber(owner:match('^n:(%d+)$'))
        if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
        local ent = NetworkGetEntityFromNetworkId(netId)
        return (ent ~= 0 and IsEntityAPed(ent)) and ent or nil
    end
    if owner == myId then return PlayerPedId() end
    local player = GetPlayerFromServerId(owner)
    if player == -1 then return nil end
    return GetPlayerPed(player)
end

--- Sat in a vehicle (not getting in): the bubble's line reaches down through the roof. On foot it is a dot.
local function inVehicle(ped)
    return ped ~= nil and ped ~= 0 and DoesEntityExist(ped) and IsPedInAnyVehicle(ped, false) and true or false
end

--- Every frame while any bubble is up; ends when the last one has folded away.
local function drawLoop()
    looping = true
    while next(owners) do
        local now = GetGameTimer()
        local cam = GetFinalRenderedCamCoord()
        local rx, ry, rz, ux, uy, uz = WorldQuad.billboardBasis()
        local myId = GetPlayerServerId(PlayerId())
        local size = CFG.size or 1.0
        local height = CFG.height or 0.3
        local drawRange = CFG.range or 20.0

        for id, o in pairs(owners) do
            if now >= o.untilMs then
                release(id)
            elseif page:up() then
                local ped = pedOf(id, myId)
                -- Not drawn for a ped this client cannot see, or one hidden on purpose (an admin in noclip).
                if ped and ped ~= 0 and DoesEntityExist(ped) and IsEntityVisible(ped) then
                    -- Got in or out: the capsule rises on its line through the roof, or comes down onto the dot.
                    local long = inVehicle(ped)
                    if long ~= o.long then
                        o.long = long
                        send({ cell = o.cell - 1, long = long })
                    end
                    local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
                    local ax, ay, az = head.x, head.y, head.z + height
                    local dx, dy, dz = ax - cam.x, ay - cam.y, az - cam.z
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    local far = o.far or 0
                    if dist <= (o.range or drawRange) + 10.0 + far then
                        local grow = (far > 0 and dist > GROW_FROM) and dist / GROW_FROM or 1.0
                        local w, h = CELL_W * MPP * size * grow, CELL_H * MPP * size * grow
                        -- The cell's bottom-centre (the end of the line) sits on the anchor.
                        local half = h * 0.5
                        WorldQuad.draw(TXD, TEX,
                            ax + ux * half, ay + uy * half, az + uz * half,
                            rx, ry, rz, ux, uy, uz, w, h,
                            0.0, (o.cell - 1) / CELLS, 1.0, o.cell / CELLS,
                            255, 255, 255, 255)
                    end
                end
            end
        end
        Wait(0)
    end
    looping = false
end

--- Shows `text` above this owner's head (the server has already cleaned it). `lines`: how many it may
--- wrap to (two for a /me, the page's default). `far`: metres it is seen further out, growing (GROW_FROM). `range`:
--- metres it is seen from instead of Config.Bubbles.range, at its own size.
local function show(owner, text, lines, far, range)
    if not attach() then return end
    local o = owners[owner]
    if not o then
        local cell = claimCell()
        o = { cell = cell, untilMs = 0, long = inVehicle(pedOf(owner, GetPlayerServerId(PlayerId()))) }
        owners[owner] = o
        cellOwner[cell] = owner
    end
    o.far = math.max(0, math.min(250, tonumber(far) or 0))
    o.range = tonumber(range) and math.max(1, math.min(250, tonumber(range))) or nil
    local ms = CFG.duration or 5000
    -- All bubbles last the same time, so the newest is always the last to go.
    o.untilMs = GetGameTimer() + ms + FOLD_MS
    -- `long` first, so a bubble that starts in a vehicle starts as the line.
    send({ cell = o.cell - 1, long = o.long, add = { text = text, ms = ms, lines = tonumber(lines) } })
    -- Marked here, not in the loop: two bubbles in one tick started two loops (audit 20, ARC-2)
    if not looping then looping = true; CreateThread(drawLoop) end
end

RegisterNetEvent('whip_core:client:bubble', function(serverId, text, lines, far, range)
    if type(serverId) ~= 'number' or type(text) ~= 'string' or text == '' then return end
    show(serverId, text, lines, far, range)
end)

-- A SUBTITLE WAITS FOR ITS LINE (`voice`: a lore character's, server/director/lore_voice.lua). The server sends it
-- as it asks for the line, and the sound reaches this game a little later (the voice server, the network, the page's
-- buffer), so on a game that hears that NPC's voice it is held until whip_voice says sound is coming out
-- (whip_voice:entityTalking), or VOICE_WAIT_MS at most. A game that does not hear it (further than the voice carries,
-- or no whip_voice) shows it at once.
local VOICE_WAIT_MS = 2000
local waiting = {}   -- [netId] = { text, lines, far, range }

local function heardHere(netId)
    if GetResourceState('whip_voice') ~= 'started' then return false, false end
    local ok, hears, talking = pcall(function() return exports.whip_voice:HearsEntity(netId) end)
    if not ok then return false, false end
    return hears == true, talking == true
end

--- Above an NPC (any networked ped), by its netId.
RegisterNetEvent('whip_core:client:bubbleEntity', function(netId, text, lines, far, voice, range)
    if type(netId) ~= 'number' or type(text) ~= 'string' or text == '' then return end
    if voice then
        local hears, talking = heardHere(netId)
        if hears and not talking then
            local w = { text = text, lines = lines, far = far, range = range }
            waiting[netId] = w
            SetTimeout(VOICE_WAIT_MS, function()
                if waiting[netId] ~= w then return end
                waiting[netId] = nil
                show(('n:%d'):format(netId), w.text, w.lines, w.far, w.range)
            end)
            return
        end
    end
    show(('n:%d'):format(netId), text, lines, far, range)
end)

AddEventHandler('whip_voice:entityTalking', function(netId, on)
    local w = on and waiting[netId]
    if not w then return end
    waiting[netId] = nil
    show(('n:%d'):format(netId), w.text, w.lines, w.far, w.range)
end)

-- ============================================
-- /me
-- ============================================

RegisterCommand('me', function(_, _, raw)
    local max = CFG.maxLength or 120
    local text, cut = BubbleText.clean((raw or ''):match('^%S+%s+(.+)$') or '', max)
    if text == '' then
        UI.Notify('Say what your character does: /me eats an apple', 'error')
        return
    end
    if cut then UI.Notify(('Your /me was cut to %d characters'):format(max), 'warning') end
    TriggerServerEvent('whip_core:server:me', text)
end, false)

-- Chat help, on load: whip_chat starts after whip_core and would miss it at file scope.
AddEventHandler('whip_core:player:loaded', function()
    TriggerEvent('chat:addSuggestion', '/me', 'Show what your character does, above your head', {
        { name = 'action', help = 'e.g. eats an apple' },
    })
    attach()   -- ready before anyone nearby uses /me
end)
