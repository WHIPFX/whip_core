-- ============================================
-- WORLD MARKS — the world builder's marks, white, in the world
-- ============================================
--
-- What the world builder places with no model of its own (a spot, an item spot, a container with no
-- prop), and the doors it picks off the world, wear a MARK from the 3D prompts' family: a white disc
-- with the hard black edge, the kind's glyph in it (an item spot shows the item's picture), its name
-- and what it is beside it in the prompts' label type, and a stem down to a white ring on the ground
-- at the exact spot. An NPC, a car or a prop wears one over its head, roof or top. A prompt a run will
-- put up, seen from further than its own range, is its idle ring and its words.
--
--   far off      the disc alone, smaller and dimmer: there is something there
--   near         the full mark: disc, name, what it is, stem, ring
--   selected     the disc filled white with the glyph dark, the ring heavier and doubled
--   highlighted  green: a card the blueprint window has lit names it (furnish_builder.lua)
--
-- ONE BROWSER, an atlas (html/interact3d/marks.html), as the prompts' badge and label atlases are: a
-- DUI is a whole browser, so the count never grows with the marks. The nearest SLOTS marks are named,
-- each slot repainted only when what it shows changes; the rest draw their kind's disc from a row
-- every kind has. Drawn with WorldQuad (client/world_quad.lua), so they depth-test and sit in the
-- same frame as the camera.
--
-- Made when the builder first draws a mark, given back when it closes (WorldMarks.stop): a DUI renders
-- whether or not anything samples it.
--
-- Per frame, from client/furnish_builder.lua: WorldMarks.begin(), WorldMarks.add(m) for each mark,
-- WorldMarks.finish(). A mark `m` is the caller's own table, kept and refilled frame to frame:
--   key            who it is, stable while it is there
--   x, y, z        the spot on the ground (`ground`), else the disc's middle
--   kind           'spot' | 'groundItem' | 'container' | 'door' | 'npc' | 'vehicle' | 'prop' | 'prompt'
--   ground         the stem and the ring under it; the disc stands GROUND_TOP over the spot
--   name, detail   its words; glyph (a prompt's icon), pic (an item's picture)
--   selected       the selection's look
--   lit            green (a card in the blueprint window names it)
--   nearText       named within this many metres (NEAR when nil)

WorldMarks = {}

-- ---- the atlas, agreed with html/interact3d/marks.html (it lays itself out from setupMessage) ----
local CELL, TEXT_W, SLOTS = 128, 640, 12
local ATLAS_W, ATLAS_H = CELL * 2 + TEXT_W, CELL * (SLOTS + 3)
local DISC_FRAC = 0.78        -- marks.html .disc: the disc's share of its cell
local RING_FRAC = 0.88        -- marks.html .groundring
local STEM_PX   = 16          -- marks.html .stem, in the middle of the parts row's third cell
local TXD, TEX  = 'whip_world_marks_txd', 'marks'

--- The kinds' row, in column order: each kind's glyph (a name in html/js/glyphs.js, or marks.html's
--- own), and the prompt's idle ring.
local KINDS = {
    { key = 'spot',       glyph = 'pin' },
    { key = 'groundItem', glyph = 'object' },
    { key = 'container',  glyph = 'chest' },
    { key = 'door',       glyph = 'door' },
    { key = 'npc',        glyph = 'ped' },
    { key = 'vehicle',    glyph = 'car' },
    { key = 'prompt',     ring = true },
}
local KIND_COL, KIND_GLYPH = {}, {}
for i, k in ipairs(KINDS) do
    KIND_COL[k.key] = i - 1
    KIND_GLYPH[k.key] = k.glyph
end
KIND_COL.hero, KIND_GLYPH.hero = KIND_COL.npc, KIND_GLYPH.npc
-- (A prop wears the box an item spot does.)
KIND_COL.prop, KIND_GLYPH.prop = KIND_COL.groundItem, KIND_GLYPH.groundItem

-- ---- sizes, metres, and ranges ----
local DISC_M      = 0.30      -- the disc, across
local MIN_PX      = 30        -- ...never smaller than this on a 1440p screen, however far
local STEM_M      = 0.9       -- the spot to the disc's middle
local RING_M      = 0.6       -- the ring on the ground, across
local NEAR        = 12.0      -- named within this
local FAR         = 150.0     -- drawn within this
local FAR_SCALE   = 0.8       -- an unnamed disc, smaller...
local FAR_ALPHA   = 200       -- ...and dimmer
local SETTLE_MS   = 150       -- a slot just repainted is drawn after this (the browser is a frame behind)
local LIT_R, LIT_G, LIT_B = 74, 222, 128   -- a lit mark's green (the furnisher's lit outline is the same)
local BOOT_MS     = 700       -- the atlas, after it is made, before anything is sent to it
local RESEND_MS   = 600       -- and everything once more after that, in case the page was not listening

--- How far over its spot a ground mark reaches (its disc's top), for the page's bubble to keep clear.
WorldMarks.GROUND_TOP = STEM_M + DISC_M * 0.5
--- A floating mark (an NPC, a car, selected up close) stands this far over the top of the thing.
WorldMarks.FLOAT_LIFT = 0.45

-- [i] = { key, turn, readyAt, name, detail, glyph, pic, ring }
local slots = {}
for i = 1, SLOTS do slots[i] = {} end
local slotOf = {}             -- [key] = slot index
local turn = 0

local list, count = {}, 0     -- this frame's marks
local wanting = {}            -- reused: the marks after a slot, nearest first

local sqrt, max, tan, rad = math.sqrt, math.max, math.tan, math.rad

local function setupMessage()
    local kinds = {}
    for i, k in ipairs(KINDS) do kinds[i] = { glyph = k.glyph, ring = k.ring == true } end
    return json.encode({ setup = { cell = CELL, text = TEXT_W, slots = SLOTS, kinds = kinds } })
end

--- Forget what every slot shows, so the next frame paints them all again.
local function forgetSlots()
    for i = 1, SLOTS do
        local s = slots[i]
        s.name, s.detail, s.glyph, s.pic, s.ring = nil, nil, nil, nil, nil
        s.readyAt = math.huge
    end
end

--- The browser, made the first time a mark is drawn and given back when the builder closes (WorldMarks.stop). Nothing
--- is sent to it until BOOT_MS after it is made; then its layout, and once more RESEND_MS later with every slot
--- painted again, in case it was not listening yet (a missed setup is a blank atlas).
local page = DuiPage.new({
    name = 'worldmarks', url = 'interact3d/marks.html', width = ATLAS_W, height = ATLAS_H, txd = TXD, tex = TEX,
    bootMs = BOOT_MS, setup = setupMessage, again = { RESEND_MS }, onAgain = forgetSlots,
    without = 'the world builder draws no marks',
})

--- One cell's texture coordinates: x, y and size in atlas pixels, pulled in half a texel so the edge
--- never samples the next cell.
local function uvOf(x, y, w, h)
    return (x + 0.5) / ATLAS_W, (y + 0.5) / ATLAS_H, (x + w - 0.5) / ATLAS_W, (y + h - 0.5) / ATLAS_H
end

-- ============================================
-- Slots
-- ============================================

local function nearerFirst(a, b)
    if a.selected ~= b.selected then return a.selected == true end
    return a._d < b._d
end

--- Which marks are named this frame: those that still want a slot keep theirs, the freed slots go to the
--- nearest of the rest (the selection first), and a slot is repainted when what it shows changed.
local function assignSlots(now)
    turn = turn + 1
    for i = 1, count do
        local m = list[i]
        local s = m._wants and slotOf[m.key] or nil
        if s then slots[s].turn = turn end
        m._slot = s
    end
    for s = 1, SLOTS do
        local sl = slots[s]
        if sl.key ~= nil and sl.turn ~= turn then
            slotOf[sl.key] = nil
            sl.key = nil
        end
    end

    local n = 0
    for i = 1, count do
        local m = list[i]
        if m._wants and not m._slot then
            n = n + 1
            wanting[n] = m
        end
    end
    for i = #wanting, n + 1, -1 do wanting[i] = nil end
    if n > 1 then table.sort(wanting, nearerFirst) end
    local s = 1
    for i = 1, n do
        while s <= SLOTS and slots[s].key ~= nil do s = s + 1 end
        if s > SLOTS then break end
        local m = wanting[i]
        slots[s].key, slots[s].turn = m.key, turn
        slotOf[m.key] = s
        m._slot = s
    end

    for i = 1, count do
        local m = list[i]
        local slot = m._slot
        if slot then
            local sl = slots[slot]
            local ring = m.kind == 'prompt'
            -- (A thing's disc wears its kind's glyph; a prompt's, its own icon or key.)
            local glyph = m.glyph or KIND_GLYPH[m.kind]
            if sl.name ~= m.name or sl.detail ~= m.detail or sl.glyph ~= glyph or sl.pic ~= m.pic or sl.ring ~= ring then
                sl.name, sl.detail, sl.glyph, sl.pic, sl.ring = m.name, m.detail, glyph, m.pic, ring
                sl.readyAt = now + SETTLE_MS
                page:send({ slot = slot - 1, name = m.name or '', detail = m.detail or '',
                    glyph = glyph, pic = m.pic, ring = ring })
            end
        end
    end
end

-- ============================================
-- Drawing
-- ============================================

local draw = WorldQuad.draw

--- One mark: the ring and the stem (a ground mark, named), the disc, and the words beside it.
local function drawMark(m, now, perM, rx, ry, rz, ux, uy, uz)
    local s = m._slot
    local named = s ~= nil and now >= (slots[s].readyAt or math.huge)
    local near = m._near or m.selected
    local discM = max(DISC_M, m._d * perM)
    if not named and not near then discM = discM * FAR_SCALE end
    local quad = discM / DISC_FRAC
    local alpha = (named or near) and 255 or FAR_ALPHA

    local cx, cy, cz = m.x, m.y, m.z
    if m.ground then cz = cz + STEM_M end
    -- Lit by a card in the blueprint window: the white goes green (the tint multiplies the texture).
    local tr, tg, tb = 255, 255, 255
    if m.lit then tr, tg, tb = LIT_R, LIT_G, LIT_B end

    if m.ground and near then
        -- The ring, flat on the ground at the exact spot (a hair above it, so the floor does not cut it).
        local ring = RING_M / RING_FRAC
        local u0, v0, u1, v1 = uvOf(m.selected and CELL or 0, (SLOTS + 2) * CELL, CELL, CELL)
        local gx, gy, gz, hx, hy, hz = WorldQuad.groundBasis(0.0)
        draw(TXD, TEX, m.x, m.y, m.z + 0.02, gx, gy, gz, hx, hy, hz, ring, ring, u0, v0, u1, v1, 255, tr, tg, tb)
        -- The stem: upright, turned to the camera, from the ground to the disc's foot.
        local h = STEM_M - discM * 0.5
        if h > 0.05 then
            local w = quad * STEM_PX / CELL
            local su0, sv0, su1, sv1 = uvOf(2 * CELL + CELL / 2 - STEM_PX / 2, (SLOTS + 2) * CELL, STEM_PX, CELL)
            draw(TXD, TEX, m.x, m.y, m.z + h * 0.5, rx, ry, 0.0, 0.0, 0.0, 1.0, w, h, su0, sv0, su1, sv1, 255, tr, tg, tb)
        end
    end

    -- The disc: the slot's own (its picture, a prompt's icon), else its kind's.
    local u0, v0, u1, v1
    if named then
        u0, v0, u1, v1 = uvOf(m.selected and (CELL + TEXT_W) or 0, (s - 1) * CELL, CELL, CELL)
    else
        local col = KIND_COL[m.kind] or 0
        u0, v0, u1, v1 = uvOf(col * CELL, (m.selected and SLOTS + 1 or SLOTS) * CELL, CELL, CELL)
    end
    draw(TXD, TEX, cx, cy, cz, rx, ry, rz, ux, uy, uz, quad, quad, u0, v0, u1, v1, alpha, tr, tg, tb)

    -- The words, a cell's height, to the disc's right.
    if named then
        local w = quad * TEXT_W / CELL
        local off = (quad + w) * 0.5
        local tu0, tv0, tu1, tv1 = uvOf(CELL, (s - 1) * CELL, TEXT_W, CELL)
        draw(TXD, TEX, cx + rx * off, cy + ry * off, cz + rz * off, rx, ry, rz, ux, uy, uz, w, quad,
             tu0, tv0, tu1, tv1, 255, 255, 255, 255)
    end
end

-- ============================================
-- Per frame
-- ============================================

function WorldMarks.begin()
    count = 0
end

---@param m table  see the header
function WorldMarks.add(m)
    count = count + 1
    list[count] = m
end

function WorldMarks.finish()
    for i = #list, count + 1, -1 do list[i] = nil end
    if count == 0 then return end
    if not page:ensure() or not page:up() then return end
    local now = GetGameTimer()

    local cam = GetFinalRenderedCamCoord()
    local camX, camY, camZ = cam.x, cam.y, cam.z
    -- Metres per metre away for MIN_PX on a 1440p screen (client/interact_world.lua's pxToMetres).
    local fov = GetFinalRenderedCamFov()
    local perM = (MIN_PX / 1440.0) * 2.0 * tan(rad((fov and fov > 0) and fov or 50.0) * 0.5)

    for i = 1, count do
        local m = list[i]
        local dz = (m.ground and m.z + STEM_M or m.z) - camZ
        local dx, dy = m.x - camX, m.y - camY
        m._d = sqrt(dx * dx + dy * dy + dz * dz)
        m._near = m._d <= (m.nearText or NEAR)
        m._show = m._d <= FAR
        m._wants = m._show and (m._near or m.selected)
    end
    assignSlots(now)

    local rx, ry, rz, ux, uy, uz = WorldQuad.billboardBasis()
    for i = 1, count do
        local m = list[i]
        if m._show then drawMark(m, now, perM, rx, ry, rz, ux, uy, uz) end
    end
end

--- The builder closing: the browser goes, and every slot with it.
function WorldMarks.stop()
    page:release()
    for i = 1, SLOTS do slots[i] = {} end
    slotOf = {}
    for i = #list, 1, -1 do list[i] = nil end
    for i = #wanting, 1, -1 do wanting[i] = nil end
    count = 0
end
