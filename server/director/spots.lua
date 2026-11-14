-- ============================================
-- Director — a spot's marker: what the cards waiting there go by
-- ============================================
--
-- A spot (a placed thing of kind 'spot') can carry a MARKER on its page (w.def.marker):
--
--   look      'none' (today's: each card's own radius and who) | 'circle' | 'square' | 'garage'
--   w, l      a circle's width across; a square's width across the way the spot faces, and length along
--             it (1-30 m). A garage bay is the garages' own size (Config.GaragePositionHelper).
--   shown     drawn for the run's players while a card waits there (client/director_spots.lua); off:
--             it works unseen
--   activate  'one' of the run's players in it | 'all' of them | 'vehicle' (a car a run player drives,
--             in it) | 'thing' (a placed thing the run made: an NPC, any of its group, or a car)
--   thing     the placed thing, for 'thing'
--   still     a car (vehicle, thing) must be stopped in it: parked
--
-- A card that waits for PLAYERS at the spot (Go To, Player Arrives, Player Leaves, the area start) takes the
-- whole rule. A card whose subject is set (Deliver the Car, Car Delivered: its car; Bring Item To: who
-- carries the item) takes only the shape: Deliver the Car at a spot set to One of them must not finish when
-- somebody walks there. In a garage bay, a car must stand square to it, either way round.
--
-- The server decides, once a second, from where the server sees things (shared/spot_shape.lua). The
-- marker's lit look is the client's, every frame, as the garage bay's is.

DirectorSpots = {}

local LOOKS = { circle = true, square = true, garage = true }
local ACTIVATE = { one = true, all = true, vehicle = true, thing = true }
local STILL_MS = 1.0   -- metres a second: a car slower than this is stopped

local function num(v, lo, hi, fallback) return DirectorKit.num(v, fallback, lo, hi) end

--- A spot's marker rules, ready to test against; nil when it has none (look 'none', not a spot, not placed).
---@param w table|nil  the placed thing (ctx:place's copy, or the graph's)
---@return table|nil r  { id, look, x, y, z, heading, w, l, shown, activate, thing, still }
function DirectorSpots.rules(w)
    if type(w) ~= 'table' or w.kind ~= 'spot' or type(w.def) ~= 'table' then return nil end
    local m, c = w.def.marker, w.def.coords
    if type(m) ~= 'table' or not LOOKS[m.look] or type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) then return nil end
    local r = { id = w.id, look = m.look, x = x, y = y, z = z, heading = tonumber(c.heading) or 0.0,
                shown = m.shown ~= false, still = m.still ~= false }
    if m.look == 'garage' then
        r.w, r.l = SpotShape.garageSize()
    else
        r.w = num(m.w, SpotShape.MIN, SpotShape.MAX, 4)
        r.l = m.look == 'square' and num(m.l, SpotShape.MIN, SpotShape.MAX, r.w) or r.w
    end
    -- The symbol in its middle (an icon's key: html/js/glyphs.js): a garage bay's, when not the garage; a circle's or
    -- a square's, when it has one.
    r.icon = SpotShape.icon(m.icon, m.look)
    r.activate = ACTIVATE[m.activate] and m.activate or (m.look == 'garage' and 'vehicle' or 'one')
    r.thing = r.activate == 'thing' and type(m.thing) == 'string' and m.thing or nil
    return r
end

--- Is a point near the spot: inside its marker, or with none (r = nil), within `radius` of `at` as today.
---@return boolean
function DirectorSpots.near(r, p, at, radius)
    if r then return SpotShape.inside(r, p.x, p.y, p.z) end
    local dx, dy, dz = p.x - at.x, p.y - at.y, p.z - at.z
    return dx * dx + dy * dy + dz * dz <= radius * radius
end

--- Is a car in the spot: inside it, square to a garage bay, and stopped when it must be.
---@return boolean
function DirectorSpots.carIn(r, ent)
    local c = GetEntityCoords(ent)
    if not SpotShape.inside(r, c.x, c.y, c.z) then return false end
    if r.look == 'garage' and not SpotShape.aligned(GetEntityHeading(ent), r.heading) then return false end
    if r.still and (GetEntitySpeed(ent) or 0) > STILL_MS then return false end
    return true
end

local playerPos = DirectorKit.playerPos

--- The car a player drives (they are in its driver's seat), or nil.
local function drivenBy(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    return veh
end

--- Is the run's placed thing in the spot: its car (carIn), or its NPC (the first of a group still up).
local function thingIn(run, r)
    local h = r.thing and Director.handleOf(run, r.thing)
    if type(h) ~= 'table' then return false end
    if h.vehicleId then
        local ent = Vehicles.getDef(h.vehicleId) and Vehicles.getEntity(h.vehicleId)
        return ent ~= nil and DirectorSpots.carIn(r, ent)
    end
    for _, id in ipairs(DirectorNodes.npcIds(h)) do
        local info = id and Npcs.get(id)
        local c = info and info.alive and info.coords
        if c then return SpotShape.inside(r, c.x, c.y, c.z) end
    end
    return false
end

--- Does the spot's rule hold for the run now? Answers true and the player it was (for what follows: the one
--- who drove in, the first one in), or false.
---@return boolean ok
---@return number|nil src
function DirectorSpots.satisfied(ctx, r)
    local players = ctx:players()
    if r.activate == 'thing' then
        if not thingIn(ctx.run, r) then return false end
        return true, players[1]
    end
    if r.activate == 'vehicle' then
        for _, s in ipairs(players) do
            local veh = drivenBy(s)
            if veh and DirectorSpots.carIn(r, veh) then return true, s end
        end
        return false
    end
    local first, inside = nil, 0
    for _, s in ipairs(players) do
        local p = playerPos(s)
        if p and SpotShape.inside(r, p.x, p.y, p.z) then
            inside = inside + 1
            first = first or s
        end
    end
    if inside == 0 or (r.activate == 'all' and inside < #players) then return false end
    return true, first
end

--- HAVE THEY ARRIVED (Player Arrives, Goal: Go To): with a marker, its whole rule (satisfied); with none, one of the
--- run's players (or, `all`, every one) within `radius` of `at`. Answers true and the first one there, or false.
---@return boolean arrived
---@return number|nil src
function DirectorSpots.arrived(ctx, r, at, radius, all)
    if r then return DirectorSpots.satisfied(ctx, r) end
    local inside, first, count = 0, nil, 0
    for _, s in ipairs(ctx:players()) do
        count = count + 1
        local p = playerPos(s)
        if p and DirectorSpots.near(nil, p, at, radius) then
            inside = inside + 1
            first = first or s
        end
    end
    if inside == 0 or (all and inside < count) then return false end
    return true, first
end

--- IS THE CAR DELIVERED (Car Delivered, Goal: Deliver the Car): the run's car (its entity) in the marker (its shape
--- only: the car is the card's), or with none within `radius` of `at`; `driven`, with one of the run's players at its
--- wheel. Answers true and that player (nil when anyone may bring it), or false.
---@return boolean delivered
---@return number|nil src
function DirectorSpots.delivered(ctx, r, ent, at, radius, driven)
    if r then
        if not DirectorSpots.carIn(r, ent) then return false end
    elseif not DirectorSpots.near(nil, GetEntityCoords(ent), at, radius) then
        return false
    end
    if not driven then return true end
    local driver = GetPedInVehicleSeat(ent, -1)
    if not driver or driver == 0 then return false end
    for _, s in ipairs(ctx:players()) do
        if GetPlayerPed(s) == driver then return true, s end
    end
    return false
end

--- Of the players who may start a run (main.lua eligiblePositions: { src, x, y, z }), the ones in an area
--- start's spot: standing in it, or driving a car in it when it activates by a vehicle. (Before a run there is
--- no crew and no thing: All of them reads as One of them, and Check refuses A placed thing.)
---@return table[] { { src } }
function DirectorSpots.startersIn(r, everyone)
    local out = {}
    for _, e in ipairs(everyone) do
        local ok
        if r.activate == 'vehicle' then
            local veh = drivenBy(e.src)
            ok = veh ~= nil and DirectorSpots.carIn(r, veh)
        else
            ok = SpotShape.inside(r, e.x, e.y, e.z)
        end
        if ok then out[#out + 1] = { src = e.src } end
    end
    return out
end

-- ============================================
-- Shown to the run's players while a card waits there
-- ============================================

--- What the run's players are shown now: each spot a card waits at, shown.
local function listOf(run)
    local list = {}
    for _, m in pairs(run.spotMarks or {}) do
        if m.n > 0 then
            local r = m.r
            local net
            if r.activate == 'thing' then
                local h = Director.handleOf(run, r.thing)
                net = type(h) == 'table' and h.netId or nil
            end
            list[#list + 1] = { id = r.id, look = r.look, x = r.x, y = r.y, z = r.z, heading = r.heading, w = r.w, l = r.l,
                                activate = r.activate, still = r.still, net = net, icon = r.icon }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

--- Send the run's shown spots to its players, and nothing to anyone who has left it since.
local function push(run)
    local list = listOf(run)
    local now = {}
    for s in pairs(run.players) do
        now[s] = true
        TriggerClientEvent('whip_core:client:directorSpots', s, run.id, list)
    end
    for s in pairs(run.spotWho or {}) do
        if not now[s] then TriggerClientEvent('whip_core:client:directorSpots', s, run.id, {}) end
    end
    run.spotWho = now
    -- A player put in later sees them too; one taken out stops (Director.crewChanged).
    if not run.spotFollow then
        run.spotFollow = true
        Director.followCrew(run, 'spots', function() push(run) end)
    end
end

--- A card that waits at a placed thing: its marker's rules when it is a spot with one, else nil (the card
--- goes by its own radius and who). Shown, it is drawn for the run's players until the card ends (the run's
--- end ends it too).
---@param w table|nil  the placed thing (ctx:place)
---@return table|nil r
function DirectorSpots.watch(ctx, w)
    local r = DirectorSpots.rules(w)
    if not r or not r.shown then return r end
    local run = ctx.run
    run.spotMarks = run.spotMarks or {}
    local m = run.spotMarks[r.id]
    if not m then
        m = { n = 0, r = r }
        run.spotMarks[r.id] = m
    end
    m.n = m.n + 1
    push(run)
    ctx:onEnd(function()
        m.n = math.max(0, m.n - 1)
        push(run)
    end)
    return r
end
