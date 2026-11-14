-- ============================================
-- VISION — what a guard sees (server)
-- ============================================
--
-- A guard (an NPC whip made: server/npcs.lua) with a watch on it notices players in front of it: within its
-- range, inside its cone (or right beside it, whichever way it faces), with nothing between them. Seen, a
-- meter fills, slower the further away they are: from `spotMs` to fill it right beside the guard, to `farMs` at
-- the edge of its range (in between, in proportion). Out of sight it empties again. Full, the player is
-- SPOTTED, and whoever set the watch hears so (the Director: alert the guard, its group or the NPCs near it;
-- Guard Spots You).
--
-- WHO WORKS OUT WHAT, so every player sees the same thing:
--   the server   range and cone, from its own reading of where the guard and the player are and which way the
--                guard faces; the meter, filled and emptied here and nowhere else; who is spotted
--   the player   whether anything stands between that guard's eyes and them, for the guards the server names
--                (whip_core:client:visionLook, a numbered list): their own game has the walls, the cars and the
--                bushes there (client/vision.lua). It says which of the list it is in sight of, and whether it
--                is sneaking, on every change and once a second (whip_core:server:visionSeen, of that list's
--                number: a report about an older list counts for nothing). No word for 1.5 s is not seen.
--   everyone     near a guard (the watch's own players, within 60 m) is sent its meter: their own, and the
--                highest of anyone else's, and its state (alert, searching), on every change of a twentieth.
--                Their game draws it over the guard's head.
-- A modified game can only ever hide ITS OWN player (it reports for itself alone); it can never have a guard
-- spot someone else. The cone and range are never its to decide.
--
-- The loop runs every quarter second while there is a watch, and not at all otherwise. A watch ends with its
-- NPC (dead or gone), its owner's release (Vision.unwatch), or a run tag (ReleaseTag).

Vision = {}

local TICK_MS       = 250
local STALE_MS      = 1500     -- a player's word older than this is not being seen
local MARK_RANGE    = 60.0     -- the watch's players this near a guard are sent its meter
local NEAR_M        = 2.5      -- this close, a guard notices you whichever way it faces
local MAX_LOOK      = 24       -- guards a player is asked about at once, the nearest
local DRAIN_K       = 0.5      -- the meter empties at half the speed it fills up close
local STEP          = 0.05     -- meters are sent in twentieths

local watches = {}      -- [watchId] = watch
local byNpc   = {}      -- [npcId] = { [watchId] = true }
local players = {}      -- [src] = { ver, key, list = { watchId, ... }, index = { [watchId] = bit }, mask, maskVer, sneak, at, marks }
local nextId  = 0
local looping = false

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

local function readCfg(c)
    c = type(c) == 'table' and c or {}
    local range = tonumber(c.range)
    local cone = tonumber(c.cone)
    local spotMs = tonumber(c.spotMs)
    local farMs = tonumber(c.farMs)
    spotMs = finite(spotMs) and math.max(1000, math.min(10000, spotMs)) or 2000   -- never under a second: time to react
    return {
        range = finite(range) and math.max(3.0, math.min(80.0, range)) or 20.0,
        cone = finite(cone) and math.max(20.0, math.min(360.0, cone)) or 100.0,
        spotMs = spotMs,
        farMs = math.max(spotMs, finite(farMs) and math.min(30000, farMs) or 8000),   -- never quicker than up close
        sneak = c.sneak ~= false,
    }
end

--- How long it takes to spot someone `d` metres away, seen the whole time: `spotMs` up close (within NEAR_M),
--- `farMs` at `range`, in proportion in between.
local function spotTime(cfg, d, range)
    local f = (d - NEAR_M) / math.max(0.1, range - NEAR_M)
    f = math.max(0.0, math.min(1.0, f))
    return cfg.spotMs + (cfg.farMs - cfg.spotMs) * f
end
Vision.spotTime = spotTime   -- (the harness, and anything that wants to say it)

--- A loaded player who is up: the only kind a guard can see.
local function seeable(src)
    local p = Players and Players[src]
    return p ~= nil and p.charId ~= nil and not p.isDead
end

local function stateOf(src)
    local p = players[src]
    if not p then
        p = { ver = 0, key = '', list = {}, index = {}, mask = 0, maskVer = -1, sneak = false, at = 0, marks = '' }
        players[src] = p
    end
    return p
end

local function forget(w)
    watches[w.id] = nil
    local set = byNpc[w.npcId]
    if set then
        set[w.id] = nil
        if next(set) == nil then byNpc[w.npcId] = nil end
    end
end

-- Every watch is a registration of the resource that set it, so a run's go with its tag and a stopping
-- resource's with it.
local reg = Registry.new('vision', {
    label = 'guard watch',
    scoped = true,
    releaseOrder = 19,   -- (before its NPCs: they go at 20)
    same = false,
    onRemove = function(_, w) forget(w) end,
})

-- ============================================
-- The loop
-- ============================================

--- The guard's eyes and the way it faces, from the server's own reading of its ped, or nil.
local function guardAt(w)
    if Npcs.by('netId', w.netId) ~= w.npcId then return nil end   -- (still that NPC's ped: ids are reused)
    local ent = NetworkGetEntityFromNetworkId(w.netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    local c = GetEntityCoords(ent)
    return { x = c.x, y = c.y, z = c.z + 0.6 }, math.rad(GetEntityHeading(ent)), GetEntityRoutingBucket(ent)
end

--- Is a point in front of it (inside its cone), or right beside it?
local function inCone(at, h, cone, px, py, d)
    if d <= NEAR_M or cone >= 360.0 then return true end
    -- GTA's heading 0 is north (+y) and turns anticlockwise: facing (-sin h, cos h).
    local fx, fy = -math.sin(h), math.cos(h)
    local dx, dy = px - at.x, py - at.y
    local flat = math.sqrt(dx * dx + dy * dy)
    if flat < 0.001 then return true end
    local cos = (fx * dx + fy * dy) / flat
    return cos >= math.cos(math.rad(cone * 0.5))
end

local function q(m) return math.floor(m / STEP + 0.5) * STEP end

local function tick()
    local now = GetGameTimer()
    local dt = TICK_MS
    local look = {}     -- [src] = { { id, d } }
    local near = {}     -- [src] = { [watchId] = true }: the watch's players near enough to be told its meter
    for id, w in pairs(watches) do
        local info = Npcs.get(w.npcId)
        if not info or not info.alive then
            reg:remove(w.owner, id)   -- dead or gone: so is what it sees
        else
            local at, h, bucket = guardAt(w)
            local who = w.audience()
            for _, src in ipairs(who) do
                local ped = GetPlayerPed(src)
                if ped and ped ~= 0 and seeable(src) and GetPlayerRoutingBucket(src) == bucket and at then
                    local c = GetEntityCoords(ped)
                    local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= MARK_RANGE then
                        near[src] = near[src] or {}
                        near[src][id] = true
                    end
                    local m = w.meters[src] or 0
                    local candidate = d <= w.cfg.range and inCone(at, h, w.cfg.cone, c.x, c.y, d)
                    if candidate then
                        local list = look[src]
                        if not list then list = {}; look[src] = list end
                        list[#list + 1] = { id = id, d = d }
                    end
                    -- Seen: in its cone and range now, and the player's own game says nothing is in between.
                    local p = players[src]
                    local bit = p and p.index[id]
                    local seen = candidate and p ~= nil and bit ~= nil and p.maskVer == p.ver and now - p.at <= STALE_MS
                        and (p.mask // (1 << bit)) % 2 == 1
                    local range = (w.cfg.sneak and p and p.sneak) and w.cfg.range * 0.5 or w.cfg.range
                    if seen and (d <= range or d <= NEAR_M) then
                        -- Slower the further away (sneaking: against its halved range, so its edge is slow too).
                        m = math.min(1.0, m + dt / spotTime(w.cfg, d, range))
                    elseif not w.spotted[src] then
                        m = math.max(0.0, m - dt / w.cfg.spotMs * DRAIN_K)
                    end
                    w.meters[src] = m > 0 and m or nil
                    if m >= 1.0 and not w.spotted[src] then
                        w.spotted[src] = now
                        local ok, err = pcall(w.onSpotted, src, { x = c.x, y = c.y, z = c.z })
                        if not ok then print(('[whip_core:vision] NPC %d: what a spotted player sets off failed: %s'):format(w.npcId, tostring(err))) end
                    end
                elseif w.meters[src] then
                    w.meters[src] = math.max(0.0, w.meters[src] - dt / w.cfg.spotMs * DRAIN_K)
                    if w.meters[src] <= 0 then w.meters[src] = nil end
                end
            end
        end
    end

    -- Each player's list of guards to look for, the nearest first: sent when it changes.
    for src, p in pairs(players) do
        if not look[src] and p.key ~= '' then
            p.ver, p.key, p.list, p.index = p.ver + 1, '', {}, {}
            TriggerClientEvent('whip_core:client:visionLook', src, p.ver, {})
        end
    end
    for src, list in pairs(look) do
        table.sort(list, function(a, b) return a.d < b.d end)
        local ids, nets = {}, {}
        for i = 1, math.min(#list, MAX_LOOK) do
            local w = watches[list[i].id]
            ids[#ids + 1] = list[i].id
            nets[#nets + 1] = w.netId
        end
        table.sort(ids)
        local key = table.concat(ids, ',')
        local p = stateOf(src)
        if key ~= p.key then
            p.ver, p.key, p.list, p.index = p.ver + 1, key, ids, {}
            local wire = {}
            for i, id in ipairs(ids) do
                p.index[id] = i - 1
                wire[i] = watches[id].netId
            end
            TriggerClientEvent('whip_core:client:visionLook', src, p.ver, wire)
        end
    end

    -- Each nearby player's marks: their own meter, the highest of anyone else's, and the guard's state.
    for src, set in pairs(near) do
        local marks, parts = {}, {}
        for id in pairs(set) do
            local w = watches[id]
            if w then
                local mine, other = w.meters[src] or 0, 0
                for s, m in pairs(w.meters) do if s ~= src and m > other then other = m end end
                if mine > 0 or other > 0 or w.state then
                    local e = { m = q(mine), o = q(other), s = w.state or (w.spotted[src] and 'spotted') or nil }
                    marks[tostring(w.netId)] = e
                    parts[#parts + 1] = ('%d:%.2f:%.2f:%s'):format(w.netId, e.m, e.o, e.s or '')
                end
            end
        end
        table.sort(parts)
        local key = table.concat(parts, '|')
        local p = stateOf(src)
        if key ~= p.marks then
            p.marks = key
            TriggerClientEvent('whip_core:client:visionMarks', src, marks)
        end
    end
    for src, p in pairs(players) do
        if not near[src] and p.marks ~= '' then
            p.marks = ''
            TriggerClientEvent('whip_core:client:visionMarks', src, {})
        end
    end
end

local function loop()
    if next(watches) == nil then
        -- The last one gone: everyone's list and marks emptied once, then nothing runs.
        for src, p in pairs(players) do
            if p.key ~= '' then
                p.ver, p.key, p.list, p.index = p.ver + 1, '', {}, {}
                TriggerClientEvent('whip_core:client:visionLook', src, p.ver, {})
            end
            if p.marks ~= '' then p.marks = '' TriggerClientEvent('whip_core:client:visionMarks', src, {}) end
        end
        looping = false
        return
    end
    local ok, err = pcall(tick)
    if not ok then print('[whip_core:vision] tick failed: ' .. tostring(err)) end
    SetTimeout(TICK_MS, loop)
end

-- ============================================
-- The functions
-- ============================================

--- Watch what an NPC sees. Answers the watch's id, or false and why. Never waits.
---@param owner string   the calling resource (Registry.caller())
---@param npcId number   one of whip's NPCs (server/npcs.lua)
---@param cfg table      { range = metres (20), cone = degrees (100), spotMs = ms to spot someone right beside it (2000),
---                        farMs = ms at the edge of its range (8000), sneak = true (sneaking halves the range) }
---@param opts table     { audience = fn() -> { server ids }: who it can see; onSpotted = fn(src, coords): a player
---                        spotted (once each, until Vision.calm); tag = a run tag }
function Vision.watch(owner, npcId, cfg, opts)
    opts = type(opts) == 'table' and opts or {}
    local info = Npcs.get(npcId)
    if not info then return false, 'no such NPC' end
    if type(opts.audience) ~= 'function' or type(opts.onSpotted) ~= 'function' then
        return false, 'audience and onSpotted are functions'
    end
    nextId = nextId + 1
    local id = nextId
    local w = { id = id, owner = owner, npcId = info.npcId, netId = info.netId, cfg = readCfg(cfg),
                audience = opts.audience, onSpotted = opts.onSpotted, meters = {}, spotted = {}, state = nil }
    local ok, why = reg:add(owner, id, w, opts.tag and { tag = opts.tag } or nil)
    if not ok then return false, why end
    watches[id] = w
    byNpc[w.npcId] = byNpc[w.npcId] or {}
    byNpc[w.npcId][id] = true
    if not looping then
        looping = true
        SetTimeout(0, loop)
    end
    return id
end

--- Stop watching.
function Vision.unwatch(owner, watchId)
    local w = watches[watchId]
    if not w or w.owner ~= owner then return false end
    return reg:remove(owner, watchId)
end

--- What its mark says above the meter: 'alert' (it is after someone), 'search' (it is coming to look), or nil.
function Vision.setState(watchId, state)
    local w = watches[watchId]
    if not w then return false end
    w.state = (state == 'alert' or state == 'search') and state or nil
    return true
end

--- Start again: nobody spotted, every meter empty, its mark calm.
function Vision.calm(watchId)
    local w = watches[watchId]
    if not w then return false end
    w.meters, w.spotted, w.state = {}, {}, nil
    return true
end

--- What a watch knows now, for a debug overlay: { meters = { [src] = 0..1 }, spotted = { [src] = ms }, state }, or nil.
function Vision.of(npcId)
    local set = byNpc[npcId]
    if not set then return nil end
    for id in pairs(set) do
        local w = watches[id]
        if w then return { meters = w.meters, spotted = w.spotted, state = w.state, range = w.cfg.range, cone = w.cfg.cone } end
    end
    return nil
end

-- ============================================
-- From the players' games
-- ============================================

-- In sight of which of its list (a bit each, the list's order), and sneaking: on a change, and once a second.
SecureEvent('whip_core:server:visionSeen', {
    rateLimit = 12, burst = 12,
    params = { {'ver', 'int', 0, 2000000000}, {'mask', 'int', 0, 0x7fffffff}, {'sneak', 'bool', false} },
}, function(source, _, ver, mask, sneak)
    local p = players[source]
    if not p or ver ~= p.ver then return end   -- about a list it no longer has
    p.mask, p.maskVer, p.sneak, p.at = mask, ver, sneak == true, GetGameTimer()
end)

AddEventHandler('playerDropped', function()
    local src = source
    players[src] = nil
    for _, w in pairs(watches) do
        w.meters[src], w.spotted[src] = nil, nil
    end
end)
