-- ============================================
-- Dev Tools — Ground Items Debug
-- ============================================
--
-- Two lists from server/dev_ground.lua:
--   NEAR, once a second: every ground item in your cell of the ground grid and the eight around it,
--     in full. The AREA in the debug panel (html/js/ground-debug.js) is these: how many piles, the
--     most common items, who dropped the most, the oldest and newest.
--   FAR, every three seconds: the nearest 1000 within 4 km, to find them by flying round the map.
-- Every item on either list gets:
--   * a BEAM from the item into the sky, its height scaled to how far away you are: a few metres
--     standing over it, a couple of hundred from across a street, a kilometre from kilometres off —
--     and wider with distance, so one 4 km away is still a line on the screen;
--   * a MARK on the minimap and the pause map (the nearest BLIP_MAX), named with what it is.
-- The one you look at — at the pile, or anywhere up its beam — is lit Signal Blue, and the panel
-- says what it is, who dropped it, how long it has lain there and where.
-- And the GRID of squares round you, laid on the ground (below, "The grid").
--
-- Per frame only while on: one ControlBlocks hook (an empty spec, no controls held).

local on       = false
local near     = {}     -- [id] = the near row { id, k, l, a, x, y, z, age, by, bn, at }
local far      = {}     -- [id] = the far row  { id, k, a, x, y, z, age, by, at }
local farNames = {}     -- [charId] = name, for the far rows' droppers
local farInfo  = nil    -- { range, total }
local all      = {}     -- [id] = the row to draw: near's when there is one, else far's
local blips    = {}     -- [id] = { handle, label }
local area     = nil    -- { cell, cellSize }
local aimedId  = nil

local BEAM_PER_M = 1.5       -- metres of beam per metre away
local BEAM_MIN   = 3.0
local BEAM_MAX   = 1000.0
local WIDE_PER_M = 0.01      -- metres of beam width per metre away: 40 m across at 4 km, a line on screen
local WIDE_MIN   = 0.08
local WIDE_MAX   = 40.0
local AIM_RANGE  = 6000.0    -- metres along the view
local BLIP_MAX   = 500

local AMBER = { 251, 191, 36 }    -- the house's warning amber: a thing on the ground
local BLUE  = { 96, 165, 250 }    -- Signal Blue: the one you are looking at

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

--- An item's name from the shared item list, for a far row (which carries only the key).
local function labelOf(it)
    if it.l then return it.l end
    local def = Config.Items and Config.Items[it.k]
    return def and def.name or tostring(it.k or '?')
end

--- What a pile is called: "Bread ×3".
local function nameOf(it)
    return ('%s ×%s'):format(labelOf(it), tostring(it.a or 1))
end

--- How long a pile has lain there now: the server's figure, plus the time since it said so.
local function ageOf(it)
    return (tonumber(it.age) or 0) + math.max(0, (GetGameTimer() - (it.at or GetGameTimer())) / 1000)
end

local function dropBlip(id)
    local b = blips[id]
    if not b then return end
    blips[id] = nil
    WhipBlipSetLabel(b.handle, nil)
    if DoesBlipExist(b.handle) then RemoveBlip(b.handle) end
end

local function markBlip(it)
    local b = blips[it.id]
    if not b then
        local h = AddBlipForCoord(it.x + 0.0, it.y + 0.0, it.z + 0.0)
        SetBlipSprite(h, 1)
        SetBlipColour(h, 5)          -- GTA's yellow
        SetBlipScale(h, 0.55)
        SetBlipAsShortRange(h, false)
        b = { handle = h }
        blips[it.id] = b
    end
    local label = nameOf(it)
    if b.label ~= label then
        b.label = label
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(label)
        EndTextCommandSetBlipName(b.handle)
        WhipBlipSetLabel(b.handle, label)
    end
end

--- `all` again from the two lists, and the map marks on the nearest BLIP_MAX of it.
local function rebuild()
    all = {}
    for id, it in pairs(far) do all[id] = it end
    for id, it in pairs(near) do all[id] = it end
    if aimedId and not all[aimedId] then aimedId = nil end

    local me = GetEntityCoords(PlayerPedId())
    local order = {}
    for _, it in pairs(all) do
        local dx, dy = it.x - me.x, it.y - me.y
        order[#order + 1] = { it = it, d2 = dx * dx + dy * dy }
    end
    table.sort(order, function(a, b) return a.d2 < b.d2 end)
    local keep = {}
    for i = 1, math.min(#order, BLIP_MAX) do
        local it = order[i].it
        keep[it.id] = true
        markBlip(it)
    end
    for id in pairs(blips) do
        if not keep[id] then dropBlip(id) end
    end
end

--- The area's figures and the looked-at pile, to the debug panel.
local function sendPanel()
    if not on then return end
    local piles, total = 0, 0
    local kinds, who = {}, {}
    local oldest, newest
    for _, it in pairs(near) do
        piles = piles + 1
        total = total + (tonumber(it.a) or 0)
        local k = kinds[it.k]
        if not k then k = { label = labelOf(it), piles = 0, amount = 0 }; kinds[it.k] = k end
        k.piles, k.amount = k.piles + 1, k.amount + (tonumber(it.a) or 0)
        local wkey = it.by or 0
        local w = who[wkey]
        if not w then w = { name = it.bn, charId = it.by, piles = 0 }; who[wkey] = w end
        w.piles = w.piles + 1
        if not oldest or it.age > oldest.age then oldest = it end
        if not newest or it.age < newest.age then newest = it end
    end

    local function top(map, n)
        local list = {}
        for _, v in pairs(map) do list[#list + 1] = v end
        table.sort(list, function(a, b)
            if a.piles ~= b.piles then return a.piles > b.piles end
            return (a.amount or 0) > (b.amount or 0)
        end)
        for i = #list, n + 1, -1 do list[i] = nil end
        return list
    end

    local nkinds, marked = 0, 0
    for _ in pairs(kinds) do nkinds = nkinds + 1 end
    for _ in pairs(all) do marked = marked + 1 end
    local a = aimedId and all[aimedId] or nil
    SendNUIMessage({ action = 'groundDebug', data = {
        cell = area and area.cell, span = area and (area.cellSize * 3) or nil,
        piles = piles, total = total, kinds = nkinds,
        common = top(kinds, 3), droppers = top(who, 3),
        oldest = oldest and { label = nameOf(oldest), age = ageOf(oldest) } or nil,
        newest = newest and { label = nameOf(newest), age = ageOf(newest) } or nil,
        marked = marked, range = farInfo and farInfo.range or nil, beyond = farInfo and farInfo.total or nil,
        aimed = a and { id = a.id, key = a.k, label = labelOf(a), amount = a.a, by = a.by,
                        byName = a.bn or (a.by and farNames[a.by]) or nil,
                        age = ageOf(a), x = a.x, y = a.y, z = a.z } or nil,
    } })
end

--- A row the server sent, checked, with when it arrived.
local function take(it, now)
    if type(it) ~= 'table' or not it.id or not tonumber(it.x) or not tonumber(it.y) or not tonumber(it.z) then
        return nil
    end
    it.age, it.at = tonumber(it.age) or 0, now
    return it
end

RegisterNetEvent('whip_core:client:groundDebug', function(data)
    if not on or type(data) ~= 'table' or type(data.items) ~= 'table' then return end
    area = { cell = data.cell, cellSize = tonumber(data.cellSize) or 50 }
    local now = GetGameTimer()
    near = {}
    for _, row in ipairs(data.items) do
        local it = take(row, now)
        if it then near[it.id] = it end
    end
    rebuild()
    sendPanel()
end)

RegisterNetEvent('whip_core:client:groundDebugFar', function(data)
    if not on or type(data) ~= 'table' or type(data.items) ~= 'table' then return end
    local now = GetGameTimer()
    far = {}
    for _, row in ipairs(data.items) do
        local it = take(row, now)
        if it then far[it.id] = it end
    end
    farNames = type(data.names) == 'table' and data.names or {}
    farInfo = { range = tonumber(data.range), total = tonumber(data.total) }
    rebuild()
    sendPanel()
end)

-- ============================================
-- The grid
-- ============================================
--
-- The ground-item grid (the squares the server streams piles by, Config.GroundItemCellSize) for
-- GRID_R squares every way round the one you stand in: 11 by 11. Each is a tile laid ON THE GROUND
-- with a gap round it, so the gaps read as the grid's lines: blue for a square with nothing in it,
-- amber for one with piles. Counted from the two lists above, so a square this client is not sent
-- piles for still shows them. Yours has a low wall round it, to read at eye level; it and the
-- nearest squares with piles have a debug card (tools/debug_cards.lua): how many, which square,
-- what lies there.
--
-- THE GROUND, NOT YOU: each tile lies on the terrain under it, so noclipping up leaves the grid
-- where the piles are. The ground is asked once per point and kept; a point it cannot find yet
-- (collision not loaded) lies at the ground under you, and is asked again on the next refresh.
--
-- COST: the 3 x 3 round you are four pieces a tile, to follow the ground closely; the rest one
-- piece. About 600 DrawPoly a frame, shown in /whipcost. Worked out every GRID_REFRESH_MS; a frame
-- only draws.

local GRID_R          = 5       -- squares each way round yours
local GRID_GAP        = 1.5     -- metres between tiles: the grid's lines
local GRID_LIFT       = 0.06    -- above the ground, so a tile does not flicker into it
local GRID_WALL       = 1.6     -- the wall round your square
local GRID_SEEK_UP    = 100.0   -- the ground is looked for from this far above the ground under you
local GRID_LABELS     = 6       -- squares with a card (the debug cards are shared: 8 places)
local GRID_REFRESH_MS = 500

local gridAnchorZ  = nil       -- the ground under you, last found: where a point's ground is not
local groundAt     = {}        -- ['x,y'] = ground z, once found
local gridDrawn    = {}        -- { { quads, col, alpha } }: what a frame draws
local gridNextAt   = 0

--- The ground under (x, y), found once and kept; the ground under you while it cannot be found yet.
local function groundZ(x, y)
    local k = x .. ',' .. y
    local z = groundAt[k]
    if z then return z end
    -- A BOOL native: 1 or false, never true.
    local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, gridAnchorZ + GRID_SEEK_UP, false)
    if found and found ~= 0 then
        groundAt[k] = gz
        return gz
    end
    return gridAnchorZ
end

--- A quad from both sides (DrawPoly draws one face of a triangle).
local function quad(q, r, g, b, a)
    local p1, p2, p3, p4 = q[1], q[2], q[3], q[4]
    DrawPoly(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, p3.x, p3.y, p3.z, r, g, b, a)
    DrawPoly(p1.x, p1.y, p1.z, p3.x, p3.y, p3.z, p4.x, p4.y, p4.z, r, g, b, a)
    DrawPoly(p3.x, p3.y, p3.z, p2.x, p2.y, p2.z, p1.x, p1.y, p1.z, r, g, b, a)
    DrawPoly(p4.x, p4.y, p4.z, p3.x, p3.y, p3.z, p1.x, p1.y, p1.z, r, g, b, a)
end

--- One tile's quads on the ground: `n` x `n` pieces, inset by the gap; with `wall`, the wall round it.
local function tileQuads(x1, y1, size, n, wall)
    local a, span = GRID_GAP * 0.5, size - GRID_GAP
    local pts = {}
    for i = 0, n do
        pts[i] = {}
        for j = 0, n do
            local x, y = x1 + a + span * i / n, y1 + a + span * j / n
            pts[i][j] = vector3(x, y, groundZ(x, y) + GRID_LIFT)
        end
    end
    local quads, walls = {}, wall and {} or nil
    for i = 0, n - 1 do
        for j = 0, n - 1 do
            quads[#quads + 1] = { pts[i][j], pts[i + 1][j], pts[i + 1][j + 1], pts[i][j + 1] }
        end
    end
    if walls then
        local edge = {}
        for i = 0, n - 1 do edge[#edge + 1] = pts[i][0] end
        for j = 0, n - 1 do edge[#edge + 1] = pts[n][j] end
        for i = n, 1, -1 do edge[#edge + 1] = pts[i][n] end
        for j = n, 1, -1 do edge[#edge + 1] = pts[0][j] end
        for k = 1, #edge do
            local p, q = edge[k], edge[k % #edge + 1]
            walls[#walls + 1] = { p, q, vector3(q.x, q.y, q.z + GRID_WALL), vector3(p.x, p.y, p.z + GRID_WALL) }
        end
    end
    return quads, walls
end

--- The squares round you, their ground and their cards.
local function refreshGrid()
    local size = (area and area.cellSize) or tonumber(Config.GroundItemCellSize) or 50
    local me = GetEntityCoords(PlayerPedId())
    local found, gz = GetGroundZFor_3dCoord(me.x, me.y, me.z + 2.0, false)
    if found and found ~= 0 then gridAnchorZ = gz elseif not gridAnchorZ then gridAnchorZ = me.z - 1.0 end

    -- What lies in each square: [cellKey] = { piles, items = { [itemKey] = piles } }.
    local cells = {}
    for _, it in pairs(all) do
        local key = math.floor(it.x / size) .. '_' .. math.floor(it.y / size)
        local c = cells[key]
        if not c then c = { piles = 0, items = {} }; cells[key] = c end
        c.piles = c.piles + 1
        if it.k then c.items[it.k] = (c.items[it.k] or 0) + 1 end
    end

    local hx, hy = math.floor(me.x / size), math.floor(me.y / size)
    local drawn, labelled = {}, {}
    for cx = hx - GRID_R, hx + GRID_R do
        for cy = hy - GRID_R, hy + GRID_R do
            local key = cx .. '_' .. cy
            local c = cells[key]
            local piles = c and c.piles or 0
            local here = cx == hx and cy == hy
            local close = math.abs(cx - hx) <= 1 and math.abs(cy - hy) <= 1
            local quads, walls = tileQuads(cx * size, cy * size, size, close and 2 or 1, here)
            local col = piles > 0 and AMBER or BLUE
            drawn[#drawn + 1] = { quads = quads, col = col, alpha = piles > 0 and 95 or 55 }
            if walls then drawn[#drawn + 1] = { quads = walls, col = col, alpha = 60 } end
            if here or piles > 0 then
                local mx, my = (cx + 0.5) * size, (cy + 0.5) * size
                labelled[#labelled + 1] = { key = key, cx = cx, cy = cy, here = here, piles = piles,
                    items = c and c.items, d2 = (mx - me.x) ^ 2 + (my - me.y) ^ 2,
                    at = vector3(mx, my, groundZ(mx, my) + 2.2) }
            end
        end
    end
    gridDrawn = drawn

    -- Cards: yours first, then the nearest with piles.
    table.sort(labelled, function(a, b)
        if a.here ~= b.here then return a.here end
        return a.d2 < b.d2
    end)
    local keep = {}
    for i = 1, math.min(GRID_LABELS, #labelled) do
        local l = labelled[i]
        local rows = {}
        for itemKey, n in pairs(l.items or {}) do
            local def = Config.Items and Config.Items[itemKey]
            rows[#rows + 1] = { n = def and def.name or itemKey, v = tostring(n),
                                p = math.floor(100 * n / math.max(1, l.piles)), c = '#fbbf24' }
        end
        table.sort(rows, function(a, b)
            if a.v ~= b.v then return tonumber(a.v) > tonumber(b.v) end
            return a.n < b.n
        end)
        while #rows > 5 do table.remove(rows) end
        local key = 'g:' .. l.key
        keep[key] = true
        DebugCards.set(key, l.at, {
            title = l.piles == 0 and 'Nothing here' or (l.piles == 1 and '1 pile' or (l.piles .. ' piles')),
            sub = ('Square %d, %d%s'):format(l.cx, l.cy, l.here and '  ·  you are here' or ''),
            rows = rows,
        })
    end
    DebugCards.keep('g:', keep)
end

--- This frame's grid, worked out again every GRID_REFRESH_MS.
local function drawGrid()
    local cost = WhipCost.start()
    local now = GetGameTimer()
    if now >= gridNextAt then
        gridNextAt = now + GRID_REFRESH_MS
        refreshGrid()
    end
    for i = 1, #gridDrawn do
        local d = gridDrawn[i]
        local col = d.col
        for j = 1, #d.quads do quad(d.quads[j], col[1], col[2], col[3], d.alpha) end
    end
    WhipCost.stop('ground items debug: the grid (every frame while on)', cost)
end

--- Each frame: every pile's beam, and which one the camera is pointed at — at the pile, or anywhere up
--- its beam, which is what you can see of one kilometres away.
local function frame()
    drawGrid()
    local cam = GetFinalRenderedCamCoord()
    local fx, fy, fz = InteractGetCameraForward()
    local flat = fx * fx + fy * fy
    local best, bestScore = nil, nil
    for id, it in pairs(all) do
        local dx, dy, dz = it.x - cam.x, it.y - cam.y, it.z - cam.z
        -- Behind the camera: nothing of it can be seen (a short way back still is, for one underfoot).
        if dx * fx + dy * fy + dz * fz > -20.0 then
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            local h = clamp(dist * BEAM_PER_M, BEAM_MIN, BEAM_MAX)
            local w = clamp(dist * WIDE_PER_M, WIDE_MIN, WIDE_MAX)
            local lit = id == aimedId
            local c = lit and BLUE or AMBER
            DrawMarker(1, it.x, it.y, it.z - 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, w, w, h,
                c[1], c[2], c[3], lit and 200 or 120, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            if lit then
                -- A ring on the ground round the one you are looking at.
                local r = math.max(0.9, w * 2.5)
                DrawMarker(25, it.x, it.y, it.z + 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r, r, r,
                    BLUE[1], BLUE[2], BLUE[3], 220, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            end

            -- The point of the view's line nearest the beam (in plan; straight down, nearest the pile),
            -- and how far off it is, against a cone that widens with distance.
            local t = flat > 0.0001 and (dx * fx + dy * fy) / flat or (dx * fx + dy * fy + dz * fz)
            if t > 0 and t < AIM_RANGE then
                local ox, oy = dx - fx * t, dy - fy * t
                local pz = cam.z + fz * t
                local off = math.sqrt(ox * ox + oy * oy)
                local allow = math.max(0.5, t * 0.02, w)
                if off <= allow and pz >= it.z - allow and pz <= it.z + h then
                    local score = off / allow
                    if not bestScore or score < bestScore then best, bestScore = id, score end
                end
            end
        end
    end
    if best ~= aimedId then
        aimedId = best
        sendPanel()
    end
end

ToolHandlers['Ground Items Debug'] = {
    enter = function()
        on = true
        TriggerServerEvent('whip_core:server:groundDebug', true)
        SendNUIMessage({ action = 'groundDebugShow' })
        ControlBlocks.hold('devGroundDebug', {}, frame)
    end,
    exit = function()
        on = false
        TriggerServerEvent('whip_core:server:groundDebug', false)
        ControlBlocks.release('devGroundDebug')
        for id in pairs(blips) do dropBlip(id) end
        near, far, farNames, farInfo, all, area, aimedId = {}, {}, {}, nil, {}, nil, nil
        gridDrawn, gridNextAt, gridAnchorZ = {}, 0, nil
        DebugCards.keep('g:', {})
        SendNUIMessage({ action = 'groundDebugHide' })
    end,
}
