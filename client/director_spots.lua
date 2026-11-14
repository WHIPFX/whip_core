-- ============================================
-- DIRECTOR SPOT MARKERS — a spot's marker on the ground, for the run's players
-- ============================================
--
-- A spot with a marker (server/director/spots.lua) is drawn for the players of a run while a card
-- waits at it, and lights while it is set off: a garage bay the garages' own way (GarageBayDrawAt), a
-- circle or a square from one browser of six slots (html/interact3d/zones.html), laid on the ground in
-- patches so a big one follows a slope. A garage bay with another symbol picked takes it from a slot too. The server decides when it goes on; the lit look is this
-- game's, every frame, as the garage bay's is (it can light a moment before the card goes on).
--
-- Lit, by what sets it off: One of them / All of them: I am in it. A vehicle: the car I drive is in
-- it (square to a garage bay, stopped when it must be). A placed thing: that NPC or car is in it.
--
-- The world builder draws a spot's marker too (DirectorSpotMarks.draw, from FurnishBuilder.frame).
--
-- One browser, made when first needed and given back after a minute of drawing nothing. The loop waits
-- half a second while no spot is near, and draws every frame while one is.

DirectorSpotMarks = {}

local PAGE, TXD, TEX = 'zones', 'whip_dzones', 'zones'
local DUI_W, DUI_H = 512, 1536
local SLOTS = 6                   -- zones.html's rows: slot k is v k/6 to (k+1)/6, idle u 0-0.5, lit u 0.5-1
local PATCH_M = 4.0               -- a patch at most this many metres a side, each corner on the ground
local LIFT_M = 0.03               -- over the ground, so it does not fight it for depth
local GROUND_MS = 250             -- a moved shape's ground looked up again at most this often (the builder)
local NEAR_M = 120.0              -- drawn within this many metres
local IDLE_MS = 60000             -- the browser given back after this long drawing nothing
local STILL_MS = 1.0              -- metres a second: a car slower than this is stopped (the server's rule)

local slots = {}                  -- [slot] = { key, used }: the shape each slot holds and when it was last drawn
local heights = {}                -- [key] = { pos, at, dz = { [n] = metres } }: the ground under a shape's corners

local page = DuiPage.new({
    name = 'directorspots', url = ('interact3d/%s.html'):format(PAGE), width = DUI_W, height = DUI_H,
    txd = TXD, tex = TEX, idleMs = IDLE_MS, without = 'spot markers will not draw',
    -- A new browser holds no shapes: each slot is painted again when next wanted.
    onGone = function() slots = {} end,
})

--- A slot's message: waits for the page while it loads, the newest for each slot.
local function send(slot, msg)
    page:send(msg, slot)
end

--- The slot holding this shape: the one it is in, else an empty one, else the one drawn longest ago
--- (repainted).
local function slotFor(look, w, l, icon)
    local key = icon and ('icon|' .. icon) or ('%s|%.1f|%.1f'):format(look, w, l)
    local now, oldest, oldestAt, free = GetGameTimer(), nil, math.huge, nil
    for k = 0, SLOTS - 1 do
        local s = slots[k]
        if s and s.key == key then
            s.used = now
            return k
        end
        if not s then free = free or k
        elseif s.used < oldestAt then oldest, oldestAt = k, s.used end
    end
    local k = free or oldest
    ---@cast k -nil   -- (every slot is free or drawn: one of the two)
    slots[k] = { key = key, used = now }
    send(k, icon and { slot = k, look = 'icon', icon = icon } or { slot = k, look = look, w = w, l = l })
    return k
end

--- The ground's height at (x, y), looked for from a little over `refZ` (under a ceiling, not on its roof).
local function groundAt(x, y, refZ)
    local found, z = GetGroundZFor_3dCoord(x, y, refZ + 1.5, false)
    if found and z > refZ - 6.0 then return z end
    return refZ
end

--- A circle or a square on the ground for one frame: a grid of patches, each corner at the ground's height.
local function drawZone(s, lit, alpha)
    if not page:ensure() or not page:up() then return end
    local k = slotFor(s.look, s.w, s.l)
    local u0 = lit and 0.5 or 0.0
    local v0, v1 = k / SLOTS, (k + 1) / SLOTS
    local na = math.max(1, math.min(8, math.ceil(s.w / PATCH_M)))
    local nb = math.max(1, math.min(8, math.ceil(s.l / PATCH_M)))
    local h = math.rad(s.heading or 0.0)
    local rx, ry = math.cos(h), math.sin(h)       -- across, to its right
    local fx, fy = -math.sin(h), math.cos(h)      -- along, the way it faces
    -- The ground under its corners, looked up when it is new or has moved (never per frame).
    local key = ('%s|%.1f|%.1f|%s'):format(s.look, s.w, s.l, s.id or '')
    local pos = ('%.2f|%.2f|%.2f|%.0f'):format(s.x, s.y, s.z, s.heading or 0.0)
    local g = heights[key]
    local now = GetGameTimer()
    if not g then
        g = { dz = {}, at = -GROUND_MS }
        heights[key] = g
    end
    local refZ = s.z
    local look = g.pos ~= pos and now - g.at >= GROUND_MS
    if look then g.pos, g.at = pos, now end
    local corners = {}
    for j = 0, nb do
        for i = 0, na do
            local n = j * (na + 1) + i
            local a, b = -s.w / 2 + s.w * i / na, s.l / 2 - s.l * j / nb
            local cx, cy = s.x + rx * a + fx * b, s.y + ry * a + fy * b
            if look then g.dz[n] = groundAt(cx, cy, refZ) - refZ end
            corners[n] = vector3(cx, cy, refZ + (g.dz[n] or 0.0) + LIFT_M)
        end
    end
    local a8 = math.floor(alpha * 255.0)
    for j = 0, nb - 1 do
        for i = 0, na - 1 do
            local tl, tr = corners[j * (na + 1) + i], corners[j * (na + 1) + i + 1]
            local bl, br = corners[(j + 1) * (na + 1) + i], corners[(j + 1) * (na + 1) + i + 1]
            WorldQuad.drawCorners(TXD, TEX, tl, tr, bl, br,
                u0 + 0.5 * i / na, v0 + (v1 - v0) * j / nb, u0 + 0.5 * (i + 1) / na, v0 + (v1 - v0) * (j + 1) / nb,
                a8, 255, 255, 255)
        end
    end
end

--- A garage bay's own symbol (s.icon: an icon's key) from this browser: a slot's idle and lit cells.
local function symbolOf(icon)
    if not page:ensure() then return nil end
    local k = slotFor('icon', 0, 0, icon)
    local v0, v1 = k / SLOTS, (k + 1) / SLOTS
    return { txd = TXD, tex = TEX, approach = { 0.0, v0, 0.5, v1 }, parked = { 0.5, v0, 1.0, v1 } }
end

--- A circle's or a square's symbol, flat in its middle and turned with it, over the shape: half its smaller side across,
--- 3 m at most; the ground under its middle looked up as the shape's corners are (never per frame).
local SYMBOL_MAX = 3.0
local function drawSymbol(s, lit, alpha)
    local sym = symbolOf(s.icon)
    if not sym or not page:up() then return end
    local cell = lit and sym.parked or sym.approach
    local key = ('sym|%s'):format(s.id or '')
    local pos = ('%.2f|%.2f|%.2f'):format(s.x, s.y, s.z)
    local g = heights[key]
    local now = GetGameTimer()
    if not g then
        g = { at = -GROUND_MS }
        heights[key] = g
    end
    if g.pos ~= pos and now - g.at >= GROUND_MS then g.pos, g.at, g.z = pos, now, groundAt(s.x, s.y, s.z) end
    local z = (g.z or s.z) + LIFT_M * 2
    local half = math.min(SYMBOL_MAX, math.min(s.w, s.l) * 0.5) / 2
    local h = math.rad(s.heading or 0.0)
    local rx, ry = math.cos(h) * half, math.sin(h) * half      -- across, to its right
    local fx, fy = -math.sin(h) * half, math.cos(h) * half     -- along, the way it faces
    local tl = vector3(s.x - rx + fx, s.y - ry + fy, z)
    local tr = vector3(s.x + rx + fx, s.y + ry + fy, z)
    local bl = vector3(s.x - rx - fx, s.y - ry - fy, z)
    local br = vector3(s.x + rx - fx, s.y + ry - fy, z)
    WorldQuad.drawCorners(TXD, TEX, tl, tr, bl, br, cell[1], cell[2], cell[3], cell[4], math.floor(alpha * 255.0), 255, 255, 255)
end

--- A marker for one frame: s = { look, x, y, z, heading, w, l, id?, icon? }; `lit` set off; `alpha` 0..1.
function DirectorSpotMarks.draw(s, lit, alpha)
    if s.look == 'garage' then
        local sym = s.icon and symbolOf(s.icon) or nil
        if GarageBayDrawAt(s.x, s.y, s.z, s.heading, alpha or 1.0, lit, sym) then page:used() end
        return
    end
    if s.look == 'circle' or s.look == 'square' then
        drawZone(s, lit, alpha or 1.0)
        if s.icon then drawSymbol(s, lit, alpha or 1.0) end
    end
end

--- A marker's shape as the world builder has it (a spot's extra `zone`: { look, w, l, icon }) at a placed spot;
--- `id` keeps its ground heights its own. `into`: a table to fill rather than a new one (the builder draws each spot
--- every frame, the same table each time).
function DirectorSpotMarks.at(zone, x, y, z, heading, id, into)
    local look = zone.look
    local w, l
    if look == 'garage' then
        w, l = SpotShape.garageSize()
    else
        w = math.max(SpotShape.MIN, math.min(SpotShape.MAX, tonumber(zone.w) or 4))
        l = look == 'square' and math.max(SpotShape.MIN, math.min(SpotShape.MAX, tonumber(zone.l) or w)) or w
    end
    local s = into or {}
    s.look, s.x, s.y, s.z, s.heading, s.w, s.l = look, x, y, z, heading or 0.0, w, l
    s.icon = SpotShape.icon(zone.icon, look)
    if s.of ~= id then s.of, s.id = id, id and ('b' .. tostring(id)) or nil end
    return s
end

-- ============================================
-- A run's shown spots (server/director/spots.lua push)
-- ============================================

local runs = {}   -- [runId] = { spot, ... }: { id, look, x, y, z, heading, w, l, activate, still, net, icon }

RegisterNetEvent('whip_core:client:directorSpots', function(runId, list)
    if type(runId) ~= 'number' then return end
    local out = {}
    for _, s in ipairs(type(list) == 'table' and list or {}) do
        if type(s) == 'table' and (s.look == 'circle' or s.look == 'square' or s.look == 'garage')
           and tonumber(s.x) and tonumber(s.y) and tonumber(s.z) then
            out[#out + 1] = { id = tostring(s.id), look = s.look, x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0,
                              heading = tonumber(s.heading) or 0.0,
                              w = math.max(SpotShape.MIN, math.min(SpotShape.MAX, tonumber(s.w) or 4)),
                              l = math.max(SpotShape.MIN, math.min(SpotShape.MAX, tonumber(s.l) or 4)),
                              activate = s.activate, still = s.still ~= false, net = tonumber(s.net),
                              icon = SpotShape.icon(s.icon, s.look) }
        end
    end
    runs[runId] = #out > 0 and out or nil
end)

--- Is a car in the spot: inside it, square to a garage bay, stopped when it must be (the server's rule).
local function carIn(s, veh)
    local c = GetEntityCoords(veh)
    if not SpotShape.inside(s, c.x, c.y, c.z) then return false end
    if s.look == 'garage' and not SpotShape.aligned(GetEntityHeading(veh), s.heading) then return false end
    if s.still and GetEntitySpeed(veh) > STILL_MS then return false end
    return true
end

--- Is the spot set off, as this game sees it?
local function litNow(s, ped)
    if s.activate == 'vehicle' then
        local veh = GetVehiclePedIsIn(ped, false)
        return veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and carIn(s, veh)
    end
    if s.activate == 'thing' then
        local ent = DirectorKit.entityOfNet(s.net)
        if not ent then return false end
        if IsEntityAVehicle(ent) then return carIn(s, ent) end
        local c = GetEntityCoords(ent)
        return SpotShape.inside(s, c.x, c.y, c.z)
    end
    local c = GetEntityCoords(ped)
    return SpotShape.inside(s, c.x, c.y, c.z)
end

CreateThread(function()
    while true do
        local drew = false
        if next(runs) then
            local cost = WhipCost.start()
            local ped = PlayerPedId()
            local me = GetEntityCoords(ped)
            for _, list in pairs(runs) do
                for _, s in ipairs(list) do
                    local dx, dy = s.x - me.x, s.y - me.y
                    if dx * dx + dy * dy <= NEAR_M * NEAR_M then
                        DirectorSpotMarks.draw(s, litNow(s, ped), 1.0)
                        drew = true
                    end
                end
            end
            WhipCost.stop(drew and 'director spot markers: drawing (every frame near one)' or 'director spot markers: none near', cost)
        end
        -- (The world builder draws through DirectorSpotMarks.draw too: its frames keep the browser. DuiPage gives it
        -- back IDLE_MS after the last.)
        Wait(drew and 0 or 500)
    end
end)
