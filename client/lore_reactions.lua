-- ============================================
-- Lore characters' reactions: this player's game sees it, the server says the line
-- ============================================
--
-- A lore character with reaction lines (Director > Lore characters > Voice lines; server/director/lore_voice.lua)
-- reacts out loud to what THIS player does to it: walks into it and knocks it over, drives into it, aims a weapon at
-- it, shoots near it, takes the driver's seat of the car it was in. The game that does it tells the server; the server checks the
-- player is near, keeps one reaction from repeating, and says the line through whip_voice for everyone near.
--
-- Only the NPCs that have reaction lines are watched (the server sends the list as it changes), and only while
-- one is within WATCH_M: otherwise this costs a look every second.

local WATCH_M = 40.0
local GUN_M = 30.0              -- shooting this near it counts as gunfire near it
local AGAIN_MS = 4000           -- this game reports the same thing about the same NPC at most this often
local KNOCKED_MS = 2000         -- a walk into it counts as Bumped into only if it is on the floor within this
local reactors = {}             -- [netId] = { bumped = true, ... }
local sent = {}                 -- [netId .. kind] = ms last reported
local touched = {}              -- [netId] = ms this player last walked into it

RegisterNetEvent('whip_core:client:loreReactors', function(list)
    reactors = type(list) == 'table' and list or {}
    sent, touched = {}, {}
end)

local function report(netId, kind, now)
    local k = netId .. kind
    if now - (sent[k] or -1e9) < AGAIN_MS then return end
    sent[k] = now
    TriggerServerEvent('whip_core:server:loreReact', netId, kind)
end

--- One NPC, this beat: what this player is doing to it.
local function look(netId, kinds, npc, me, now)
    local myCoords = GetEntityCoords(me)
    local d = #(myCoords - GetEntityCoords(npc))
    local veh = GetVehiclePedIsIn(me, false)
    local driving = veh ~= 0 and GetPedInVehicleSeat(veh, -1) == me
    -- Bumped into: this player walks or runs into it (on foot, moving, touching) AND it goes over (ragdolls) within
    -- KNOCKED_MS. A brush that leaves it standing says nothing (Josh, 27 Oct).
    if kinds.bumped then
        if veh == 0 and d < 2.0 and GetEntitySpeed(me) > 0.8 and IsEntityTouchingEntity(me, npc) then touched[netId] = now end
        local t = touched[netId]
        if t and now - t > KNOCKED_MS then touched[netId] = nil
        elseif t and IsPedRagdoll(npc) then
            touched[netId] = nil
            report(netId, 'bumped', now)
        end
    end
    -- Hit by a car: the car this player drives touching it at speed.
    if kinds.hitByCar and driving and d < 8.0 and GetEntitySpeed(veh) > 2.5 and IsEntityTouchingEntity(veh, npc) then
        report(netId, 'hitByCar', now)
    end
    -- A gun aimed at it.
    if kinds.aimedAt and IsPlayerFreeAimingAtEntity(PlayerId(), npc) then
        report(netId, 'aimedAt', now)
    end
    -- Gunfire near it (this player's shot).
    if kinds.gunfire and d < GUN_M and IsPedShooting(me) then
        report(netId, 'gunfire', now)
    end
    -- Its car stolen: this player in the driver's seat of the car it was last in, without it.
    if kinds.carStolen and driving then
        local its = GetVehiclePedIsIn(npc, true)
        if its == veh and not IsPedInVehicle(npc, veh, false) then report(netId, 'carStolen', now) end
    end
end

CreateThread(function()
    -- Asked here only with a character already in the world: a join asks when the character loads (below), and asking
    -- before that is refused (no player session) for nothing.
    if PlayerLoaded then TriggerServerEvent('whip_core:server:loreReactorsAsk') end
    while true do
        local near, armed = false, false
        if next(reactors) then
            local me = PlayerPedId()
            local now = GetGameTimer()
            local myCoords = GetEntityCoords(me)
            armed = IsPedArmed(me, 4)   -- a gun: shots last a frame, so it looks every frame
            for netId, kinds in pairs(reactors) do
                local npc = DirectorKit.entityOfNet(netId)
                if npc and not IsEntityDead(npc) and #(myCoords - GetEntityCoords(npc)) < WATCH_M then
                    near = true
                    look(netId, kinds, npc, me, now)
                end
            end
        end
        Wait(near and (armed and 0 or 100) or 1000)
    end
end)

-- ============================================
-- How lore NPCs look: a GTA ped's hat, or a whole look made in the character editor
-- ============================================
--
-- A GTA PED'S HAT (Director > Lore characters > Details > Hat): GTA puts no prop on a ped by itself, and only the
-- game that OWNS a networked ped can change what it wears (the others see what that game sends). So every game looks
-- once a second at the lore NPCs it owns, and puts back any prop that is not as the lore character has it. A new
-- owner does the same, so it lasts as the NPC changes hands.
--
-- A LOOK MADE IN THE CHARACTER EDITOR (a freemode ped's face, hair, clothes, tattoos): EVERY game that has the NPC
-- puts it on its own copy, owner or not, as a player's own look is put on (ApplyAppearance). What of it a game sends
-- the others comes from the owner's copy; what it does not (the face, the tattoos), each game puts on itself. Put on
-- once for each copy (a new one when it streams in again), again when this game becomes its owner, and when the look
-- changes. The look is asked for by key, once for each version (whip_core:loreLook).
--
-- ANY OTHER NPC WITH A LOOK OF ITS OWN (server/npcs.lua def.look: a Director NPC's, made on its page) is put on the
-- same way, asked for by the NPC's id (whip_core:npcLook; its version is its id, so a new NPC is a new look).
--
-- Only while some NPC has a hat or a look.

local looks = {}       -- [netId] = { props = { { anchor, drawable, texture }, ... } }, { look = key, v } or { npc = id, v }
local looking = false
local lookCache = {}   -- [key] = { v, look } once asked ({ v, asking } while asking; { v, retryAt } for none); an NPC's
                       -- own under 'npc:<id>'
local worn = {}        -- [netId] = { ped, v, owned }: the look this game last put on that copy
local NONE_RETRY_MS = 10000

local function hat(ped, list)
    for _, p in ipairs(list) do
        if GetPedPropIndex(ped, p.anchor) ~= p.drawable or GetPedPropTextureIndex(ped, p.anchor) ~= p.texture then
            SetPedPropIndex(ped, p.anchor, p.drawable, p.texture, true)
        end
    end
end

local function wear(ped, netId, e, owned)
    local w = worn[netId]
    if w and w.ped == ped and w.v == e.v and (w.owned or not owned) then return end
    local key = e.npc and ('npc:' .. tostring(e.npc)) or e.look
    local got = lookCache[key]
    if not got or got.v ~= e.v or (got.retryAt and GetGameTimer() >= got.retryAt) then
        lookCache[key] = { v = e.v, asking = true }
        CreateThread(function()
            local r = e.npc and Callback('whip_core:npcLook', e.npc) or Callback('whip_core:loreLook', e.look)
            if type(r) == 'table' and type(r.look) == 'table' then lookCache[key] = { v = r.v, look = r.look }
            else lookCache[key] = { v = e.v, retryAt = GetGameTimer() + NONE_RETRY_MS } end
        end)
        return
    end
    if not got.look then return end   -- still asking, or none for now
    worn[netId] = { ped = ped, v = e.v, owned = owned }
    local appearance = got.look
    CreateThread(function() ApplyAppearance(ped, appearance) end)   -- (waits out the face's bake)
end

local function dress()
    for netId, e in pairs(looks) do
        local ped = DirectorKit.entityOfNet(netId)
        if ped then
            local owned = DirectorKit.mine(ped)
            if e.look or e.npc then wear(ped, netId, e, owned)
            elseif e.props and owned then hat(ped, e.props) end
        end
    end
end

RegisterNetEvent('whip_core:client:loreLooks', function(list)
    looks = type(list) == 'table' and list or {}
    -- What was put on stays put on while it is still the same look: a new list (another NPC came) changes nothing.
    for netId, w in pairs(worn) do
        local e = looks[netId]
        if not (e and (e.look or e.npc) and e.v == w.v) then worn[netId] = nil end
    end
    -- An NPC's own look is kept only while it is listed (each run's NPCs are new ones: they would pile up).
    local listed = {}
    for _, e in pairs(looks) do if e.npc then listed['npc:' .. tostring(e.npc)] = true end end
    for key in pairs(lookCache) do
        if key:sub(1, 4) == 'npc:' and not listed[key] then lookCache[key] = nil end
    end
    if looking or not next(looks) then return end
    looking = true
    CreateThread(function()
        while next(looks) do
            dress()
            Wait(1000)
        end
        looking = false
    end)
end)

-- ============================================
-- Gestures while a lore character talks: GTA's talking hands, without GTA's voice
-- ============================================
--
-- GTA's peds wave their hands about as they talk because its speech plays a gesture with each line. Ours are
-- recordings, so the server tells the game that OWNS the NPC when a line starts and how long it is
-- (whip_core:client:loreTalk), and that game plays GTA's own standing gestures on it, upper body only, over
-- whatever it is doing: one that suits the line first (a wave for Hello), then ordinary talking ones until the
-- line ends. Played by the owner, so every game sees them. Not in a car, on the floor or in a scenario.

local GESTURES = { m = 'gestures@m@standing@casual', f = 'gestures@f@standing@casual' }
local TALKING = { 'gesture_you_soft', 'gesture_what_soft', 'gesture_hand_right', 'gesture_hand_left', 'gesture_easy_now',
                  'gesture_shrug_soft', 'gesture_me', 'gesture_why', 'gesture_i_will', 'gesture_nod_yes_soft', 'gesture_hand_down' }
local FIRST = { hello = 'gesture_hello', goodbye = 'gesture_bye_soft', positive = 'gesture_pleased', negative = 'gesture_displeased',
                bumped = 'gesture_what_hard', hitByCar = 'gesture_damn', aimedAt = 'gesture_easy_now', gunfire = 'gesture_no_way',
                carStolen = 'gesture_what_hard' }
local UPPER_ONLY = 16 + 32      -- upper body, over its own task (it keeps standing, walking or guarding)
local talkGen = {}              -- [netId] = n: a newer line stops the older one's gestures

--- The NPC, if this game owns it and it can gesture now; else nil.
local function gesturable(netId)
    local ped = DirectorKit.entityOfNet(netId)
    if not DirectorKit.mine(ped) then return nil end
    if IsPedDeadOrDying(ped, true) or IsPedRagdoll(ped) or IsPedInAnyVehicle(ped, false) or IsPedUsingAnyScenario(ped) then return nil end
    return ped
end

RegisterNetEvent('whip_core:client:loreTalk', function(netId, line, ms)
    netId, ms = tonumber(netId), tonumber(ms)
    if not netId or not ms or ms <= 0 then return end
    local gen = (talkGen[netId] or 0) + 1
    talkGen[netId] = gen
    local ped = gesturable(netId)
    if not ped then return end
    CreateThread(function()
        local ends = GetGameTimer() + math.min(ms, 60000)
        local dict = IsPedMale(ped) and GESTURES.m or GESTURES.f
        if not LoadAnimDict(dict) then return end
        local clip = type(line) == 'string' and FIRST[line] or TALKING[math.random(#TALKING)]
        while talkGen[netId] == gen and GetGameTimer() < ends - 400 do
            ped = gesturable(netId)
            if not ped then break end
            TaskPlayAnim(ped, dict, clip, 3.0, 2.0, -1, UPPER_ONLY, 0.0, false, false, false)
            local len = math.floor((GetAnimDuration(dict, clip) or 1.5) * 1000)
            clip = TALKING[math.random(#TALKING)]
            Wait(math.max(700, len) + math.random(150, 700))
        end
        if talkGen[netId] == gen then talkGen[netId] = nil end
    end)
end)

-- whip_core's player loading in (a new character): the list again, in case it was missed.
AddEventHandler('whip_core:player:loaded', function() TriggerServerEvent('whip_core:server:loreReactorsAsk') end)
