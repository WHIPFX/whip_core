-- ============================================
-- PROPERTY LISTING — a for-sale sign post's board, printed
-- ============================================
--
-- "instead of us browsing it the normal way, what if the information was just fixed points within the safe zone of
-- the sign, so they'd start top left and go down and be visible, with price being last, and on the bottom right,
-- you'd get your normal controls, which would just be "More..." and it would turn into the purchase system instead"
--
-- A sign post's blank panel (Config.PropertySignPosts) shows its property's listing as if printed there: its name,
-- garage bays, rooms and price, top left down, in the sign's own colours. One browser (DUI) paints every listing
-- into its own cell of one texture (html/interact3d/listing.html); each frame a cell is drawn flat on its board
-- (WorldQuad), a few millimetres off the print, so it depth-tests as the board does. A board printed on its back
-- too (`back`) gets the listing there as well. The controls are the outside sign's prompt, at the panel's bottom
-- left, under the listing (PropertyListing.controls; client/properties.lua registers it).
--
--   PropertyListing.set(id, entity, post, sign, listing)   entity: the post (drawn only while it exists); post: its
--                                                          Config.PropertySignPosts entry; sign: the prompt's spot
--                                                          { x, y, z, heading }; listing: { name, bays, rooms, price,
--                                                          closed }
--   PropertyListing.remove(id)
--   PropertyListing.controls(post, sign, row, fit)         where the prompt goes: x, y, z, heading; `fit` filled in
--   PropertyListing.rowFor(index, count)                   which row a list's selected option stands on
--
-- Only the nearest CELLS within RANGE are painted; the browser goes IDLE_MS after the last listing does.

PropertyListing = {}

local CELL_W, CELL_H, COLS, CELLS = 1024, 576, 2, 4
local ROWS = math.ceil(CELLS / COLS)
local TXD, TEX = 'whip_listing_txd', 'listings'

local LIFT       = 0.005   -- metres off the board: 3–5 mm keeps it out of the print (3D Clanker's handoff)
local PROMPT_OFF = 0.02    -- the prompt's own distance off the board (shared/property_math.lua, POST_PROMPT_OFF)
local RANGE      = 30.0    -- drawn within this many metres; fades out over the last FADE
local FADE       = 5.0
local ASSIGN_MS  = 1000    -- how often the nearest listings are given cells
local IDLE_MS    = 15000   -- the browser is kept this long after the last listing, for the next one

-- THE CONTROLS ARE DRAWN AT CONTROL_SCALE of a prompt's own size. A prompt is sized to be read at arm's length
-- (Config.Interact3D: about 11 cm a circle, 7 cm type), so a choice like "Cash  ($12,345)" runs to some 0.65 m —
-- off a board whose panel is 1.05 m across. At 0.7 it is about 0.45 m, and its circles step 0.10 m apart.
--
-- The controls stand at the left of the panel's safe zone, under the listing, their circle in line with the listing's
-- icons. They never move sideways: words too long for the zone are set smaller (the prompt's `fit`,
-- client/interact_world.lua). CTRL_ROWS rows of options fit under the listing, the bottom one CTRL_IN_Y up from the
-- panel's bottom: "Purchase?" stands on that one. In a list the selected option stands on its own row, so a list that fits
-- holds still and only the selection moves. A longer one scrolls through the rows, and what is outside them fades
-- rather than sit on the listing's words.
PropertyListing.CONTROL_SCALE = 0.7
local SAFE_X    = 56 / 1024   -- of the panel's width: listing.html's padding, its safe zone
local CTRL_IN_Y = 0.06
local CTRL_STEP = 0.10
local CTRL_ROWS = 2

local listings = {}   -- [id] = { entity, post, json, data, cell?, front = {...}, back = {...}|nil, w, h, aspect }
local cellOf = {}     -- [cell] = id
local looping = false

--- Kept while any listing is set (the draw loop uses it every frame), given back IDLE_MS after the last one goes.
local page = DuiPage.new({
    name = 'listing', url = ('interact3d/listing.html?w=%d&h=%d&cols=%d&cells=%d'):format(CELL_W, CELL_H, COLS, CELLS),
    width = CELL_W * COLS, height = CELL_H * ROWS, txd = TXD, tex = TEX, idleMs = IDLE_MS,
    without = 'sign posts will show no listing',
    -- A new browser holds no listings: each is given a cell again.
    onGone = function()
        for cell, id in pairs(cellOf) do
            if listings[id] then listings[id].cell = nil end
            cellOf[cell] = nil
        end
    end,
})

local function send(msg)
    page:send(msg)
end

--- The listing as the page takes it.
local function payload(l)
    local d = l.data or {}
    return { name = d.name, bays = d.bays, rooms = d.rooms, price = d.price, closed = d.closed == true,
             ink = l.post.ink, accent = l.post.accent, aspect = l.aspect }
end

local function giveCell(id, cell)
    local l = listings[id]
    cellOf[cell] = id
    l.cell = cell
    send({ cell = cell - 1, listing = payload(l) })
end

local function takeCell(id)
    local l = listings[id]
    if not (l and l.cell) then return end
    cellOf[l.cell] = nil
    send({ cell = l.cell - 1, clear = true })
    l.cell = nil
end

--- The nearest listings within reach get the cells; the rest give theirs up.
local function assign()
    local cam = GetFinalRenderedCamCoord()
    local order = {}
    for id, l in pairs(listings) do
        local f = l.front
        local dx, dy, dz = f.cx - cam.x, f.cy - cam.y, f.cz - cam.z
        l.distSq = dx * dx + dy * dy + dz * dz
        if l.distSq <= (RANGE + FADE) * (RANGE + FADE) then order[#order + 1] = id end
    end
    table.sort(order, function(a, b) return listings[a].distSq < listings[b].distSq end)
    local keep = {}
    for i = 1, math.min(CELLS, #order) do keep[order[i]] = true end
    for id, l in pairs(listings) do
        if l.cell and not keep[id] then takeCell(id) end
    end
    for id in pairs(keep) do
        if not listings[id].cell then
            for cell = 1, CELLS do
                if not cellOf[cell] then giveCell(id, cell) break end
            end
        end
    end
end

local function drawSide(l, s, a)
    local col, row = (l.cell - 1) % COLS, (l.cell - 1) // COLS
    local u0, v0 = col / COLS, row / ROWS
    local u1 = u0 + 1 / COLS
    -- The panel's own shape: the page filled CELL_W / aspect of the cell's height.
    local v1 = v0 + math.min(CELL_H, CELL_W / l.aspect) / (CELL_H * ROWS)
    WorldQuad.draw(TXD, TEX, s.cx, s.cy, s.cz, s.rx, s.ry, 0.0, 0.0, 0.0, 1.0, l.w, l.h, u0, v0, u1, v1, a, 255, 255, 255)
end

local function drawLoop()
    looping = true
    local nextAssign = 0
    while next(listings) do
        local now = GetGameTimer()
        if now >= nextAssign then
            nextAssign = now + ASSIGN_MS
            page:ensure()
            assign()
        end
        page:used()
        if page:up() then
            local cam = GetFinalRenderedCamCoord()
            for _, l in pairs(listings) do
                if l.cell and l.entity and DoesEntityExist(l.entity) then
                    local f = l.front
                    local dx, dy, dz = f.cx - cam.x, f.cy - cam.y, f.cz - cam.z
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d < RANGE + FADE then
                        local a = d <= RANGE and 255 or math.floor(255 * (RANGE + FADE - d) / FADE)
                        drawSide(l, f, a)
                        if l.back then drawSide(l, l.back, a) end
                    end
                end
            end
        end
        Wait(0)
    end
    looping = false
end

--- Where a post's panel is, for a prompt spot on it: the post's own place (shared/property_math.lua), then the
--- panel's middle on its front (and back), and the way across it as you read it.
local function geometry(post, sign)
    local x, y, z, h = PropertyMath.promptToPost(post, sign.x, sign.y, sign.z, sign.heading or 0.0)
    local place = { x = x, y = y, z = z, yaw = h }
    local pn = post.panel
    local px, py, pz = tonumber(pn.x) or 0.0, tonumber(pn.y) or 0.0, tonumber(pn.z) or 0.0
    -- The post's +x is the reader's right on the front, its -x on the back.
    local t = math.rad(h)
    local rx, ry = math.cos(t), math.sin(t)
    local fx, fy, fz = PropertyMath.toWorld(place, px, py - LIFT, pz)
    local out = { place = place, front = { cx = fx, cy = fy, cz = fz, rx = rx, ry = ry } }
    if post.back then
        local bx, by, bz = PropertyMath.toWorld(place, px, -py + LIFT, pz)
        out.back = { cx = bx, cy = by, cz = bz, rx = -rx, ry = -ry }
    end
    return out
end

--- Show (or update) a property's listing on its post's board. Unchanged words send nothing.
---@param id number|string   a property's id, or the editor's preview
---@param entity number      the post
---@param post table         its Config.PropertySignPosts entry (panel with w and h)
---@param sign table         the outside sign's spot { x, y, z, heading }
---@param listing table      { name, bays, rooms, price, closed }
function PropertyListing.set(id, entity, post, sign, listing)
    local pn = post and post.panel
    local w, h = pn and tonumber(pn.w), pn and tonumber(pn.h)
    if not (w and h and w > 0 and h > 0 and sign) then return end
    local l = listings[id]
    local key = ('%s|%.3f|%.3f|%.3f|%.1f'):format(post.model, sign.x, sign.y, sign.z, sign.heading or 0.0)
    if not l or l.key ~= key then
        local g = geometry(post, sign)
        l = { cell = l and l.cell, key = key, front = g.front, back = g.back, w = w, h = h, aspect = w / h }
        listings[id] = l
    end
    l.entity = entity
    -- The same listing table as last time (the placer's preview, every frame) is the same words: nothing to send.
    if l.data ~= listing or l.post ~= post or not l.json then
        l.post, l.data = post, listing
        local j = json.encode(payload(l))
        if j ~= l.json then
            l.json = j
            if l.cell then send({ cell = l.cell - 1, listing = payload(l) }) end
        end
    end
    -- Marked here, not in the loop: a second set before the thread first runs must not start another.
    if not looping then
        looping = true
        CreateThread(drawLoop)
    end
end

function PropertyListing.remove(id)
    if not listings[id] then return end
    takeCell(id)
    listings[id] = nil
end

--- Which row a list's selected option stands on, counted up from the bottom: the last option on the bottom row.
---@param index number  the selected option's place in the list
---@param count number  how many options the list has
---@return number row
function PropertyListing.rowFor(index, count)
    return math.min(count - index, CTRL_ROWS - 1)
end

--- Where the sign's prompt goes on a post's panel: the left edge of its safe zone, on a row under the listing.
---@param row number|nil  which row, counted up from the bottom from 0; between two while it glides
---@param fit table|nil   filled in with the box it stays inside, for `follow` to hand on as its `fit`
---@return number x, number y, number z, number heading
function PropertyListing.controls(post, sign, row, fit)
    local pn = post.panel
    local w, h = tonumber(pn.w) or 1.0, tonumber(pn.h) or 0.6
    local x, y, z, ph = PropertyMath.promptToPost(post, sign.x, sign.y, sign.z, sign.heading or 0.0)
    local place = { x = x, y = y, z = z, yaw = ph }
    local px, py, pz = tonumber(pn.x) or 0.0, (tonumber(pn.y) or 0.0) - PROMPT_OFF, tonumber(pn.z) or 0.0
    local safe = w * SAFE_X
    row = row or 0.0
    local cx, cy, cz = PropertyMath.toWorld(place, px - w * 0.5 + safe, py, pz - h * 0.5 + CTRL_IN_Y + CTRL_STEP * row)
    if fit then
        fit.width = w - 2.0 * safe
        fit.below = row
        fit.above = CTRL_ROWS - 1 - row
    end
    return cx, cy, cz, sign.heading or 0.0
end
