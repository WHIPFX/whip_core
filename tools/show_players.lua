-- ============================================
-- Dev Tools — Reveal Players
-- ============================================
--
-- Every player marked: a blue blip on the minimap and the pause map (client/pause.lua reads GTA's blips,
-- and names these through WhipBlipSetLabel), and, over the head of anyone near enough to see, a TAG:
-- their character's name and charId and their account's name (the Steam name when Steam is running).
--
-- THE TAG IS ITS OWN /me BUBBLE. One browser (DUI) paints
-- every tag into its own cell of one texture (html/debug3d/tags.html), in the /me bubble's capsule with
-- its line down to the head. Each frame a cell is drawn as a SCREEN sprite whose bottom centre (the end
-- of the line) sits over the head: it always faces you, and nothing in the world hides it. It shrinks
-- with distance down to half size, so one across the street still reads.
--
-- THE LIST IS THE SERVER'S (server/dev_players.lua), once a second: a player too far away for this game
-- to have them still has a place on the map. One this game DOES have gets a blip on their ped, which
-- moves with them every frame; the rest get one on the server's spot, moved each second.
--
-- Per frame only while on: one ControlBlocks hook (an empty spec, no controls held) drawing the tags.

local on    = false
local rows  = {}   -- [serverId] = the server's row { s, c, n, a, x, y, z, h }
local marks = {}   -- [serverId] = { blip, ped, label }  ped 0: the blip sits on the server's spot

local BLIP_COLOUR = 3        -- GTA's blue
local NAME_RANGE  = 250.0    -- metres: further off, a tag is clutter, and the blip still says where
local HEAD_BONE   = 31086    -- SKEL_Head
local HEAD_LIFT   = 0.3      -- metres above the head bone the line ends

-- ---- The tags' atlas ----

local CELL_W, CELL_H, COLS, CELLS = 768, 256, 2, 16
local TAG_ROWS = CELLS // COLS
local TXD, TEX = 'whip_playertags_txd', 'tags'
local TAG_WIDTH = 0.2                 -- a cell's width close up, in screen widths (the capsule is most of it)
local NEAR, FAR, MIN_SCALE = 5.0, 120.0, 0.5

local tags   = {}   -- [serverId] = { cell, json }
local cellOf = {}   -- [cell] = serverId

--- The tags' browser: made with the first tag (messages wait until it is up), given back with the tool (exit).
local page = DuiPage.new({
    name = 'showplayers', url = ('debug3d/tags.html?w=%d&h=%d&cols=%d&cells=%d'):format(CELL_W, CELL_H, COLS, CELLS),
    width = CELL_W * COLS, height = CELL_H * TAG_ROWS, txd = TXD, tex = TEX, without = 'the name tags will not draw',
})

local function send(msg)
    page:send(msg)
end

local function detach()
    page:release()
    tags, cellOf = {}, {}
end

local function untag(id)
    local t = tags[id]
    if not t then return end
    tags[id] = nil
    cellOf[t.cell] = nil
    send({ cell = t.cell - 1, clear = true })
end

--- Give this player a tag, or update theirs; false when every cell is taken (by nearer players).
local function tag(r)
    local t = tags[r.s]
    if not t then
        local cell
        for i = 1, CELLS do
            if not cellOf[i] then cell = i break end
        end
        if not cell then return false end
        if not page:ensure() then return false end
        t = { cell = cell }
        tags[r.s] = t
        cellOf[cell] = r.s
    end
    local msg = { name = r.n, id = r.c, account = r.a }
    local j = json.encode(msg)
    if j ~= t.json then
        t.json = j
        send({ cell = t.cell - 1, tag = msg })
    end
    return true
end

local function scaleAt(dist)
    if dist <= NEAR then return 1.0 end
    if dist >= FAR then return MIN_SCALE end
    return 1.0 - (1.0 - MIN_SCALE) * ((dist - NEAR) / (FAR - NEAR))
end

--- A name shown as it is: GTA's map label reads ~ as a colour or button code, and a player picks their
--- own name. (The tag is set as text by its page, but takes the same name, so the two always agree.)
local function plain(s)
    return (tostring(s or '?'):gsub('~', ''))
end

local function unmark(id)
    local m = marks[id]
    if not m then return end
    marks[id] = nil
    WhipBlipSetLabel(m.blip, nil)
    if DoesBlipExist(m.blip) then RemoveBlip(m.blip) end
end

--- This game's ped for a server id, or 0 when it does not have them.
local function pedOf(serverId)
    local idx = GetPlayerFromServerId(serverId)
    if idx == -1 then return 0 end
    local ped = GetPlayerPed(idx)
    return (ped ~= 0 and DoesEntityExist(ped)) and ped or 0
end

local function mark(r)
    local ped = pedOf(r.s)
    local m = marks[r.s]
    -- Streamed in or out, or a new ped (a respawn): the blip is made again on the right thing.
    if m and (m.ped ~= ped or not DoesBlipExist(m.blip)) then unmark(r.s); m = nil end
    if not m then
        local blip = ped ~= 0 and AddBlipForEntity(ped) or AddBlipForCoord(r.x, r.y, r.z)
        SetBlipSprite(blip, 1)
        SetBlipColour(blip, BLIP_COLOUR)
        SetBlipScale(blip, 0.85)
        SetBlipCategory(blip, 7)   -- "Other Players", in GTA's own map legend
        SetBlipAsShortRange(blip, false)
        ShowHeadingIndicatorOnBlip(blip, true)
        m = { blip = blip, ped = ped }
        marks[r.s] = m
    end
    if ped == 0 then
        SetBlipCoords(m.blip, r.x + 0.0, r.y + 0.0, r.z + 0.0)
        SetBlipRotation(m.blip, math.floor(tonumber(r.h) or 0))
    end
    local label = ('%s #%s (%s)'):format(r.n, tostring(r.c or '?'), r.a)
    if m.label ~= label then
        m.label = label
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(label)
        EndTextCommandSetBlipName(m.blip)
        WhipBlipSetLabel(m.blip, label)
    end
end

--- Each frame: the tags over the heads this game can see, each cell's bottom centre on its head.
local function frame()
    if not page:up() then return end
    local cam = GetFinalRenderedCamCoord()
    local aspect = GetAspectRatio(false)
    for id, t in pairs(tags) do
        local m = marks[id]
        local ped = m and m.ped or 0
        if ped ~= 0 and DoesEntityExist(ped) then
            local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
            local ax, ay, az = head.x, head.y, head.z + HEAD_LIFT
            local dx, dy, dz = ax - cam.x, ay - cam.y, az - cam.z
            local w = TAG_WIDTH * scaleAt(math.sqrt(dx * dx + dy * dy + dz * dz))
            local h = w * (CELL_H / CELL_W) * aspect
            local col, row = (t.cell - 1) % COLS, (t.cell - 1) // COLS
            local u0, v0 = col / COLS, row / TAG_ROWS
            SetDrawOrigin(ax, ay, az, 0)
            -- Centred half its height up: its bottom edge, where the line ends, is on the anchor.
            DrawSpriteUv(TXD, TEX, 0.0, -h * 0.5, w, h, u0, v0, u0 + 1 / COLS, v0 + 1 / TAG_ROWS,
                0.0, 255, 255, 255, 255)
            ClearDrawOrigin()
        end
    end
end

RegisterNetEvent('whip_core:client:showPlayers', function(list)
    if not on or type(list) ~= 'table' then return end
    local me = GetPlayerServerId(PlayerId())
    local seen = {}
    for _, r in ipairs(list) do
        -- Not yourself: you have your own arrow, and no head above you to read.
        if type(r) == 'table' and tonumber(r.s) and r.s ~= me and tonumber(r.x) then
            r.n, r.a = plain(r.n), plain(r.a)
            rows[r.s] = r
            seen[r.s] = true
            mark(r)
        end
    end
    for id in pairs(rows) do
        if not seen[id] then
            rows[id] = nil
            unmark(id)
        end
    end

    -- Tags for the players this game can see within NAME_RANGE, the nearest first while cells last.
    local myPos = GetEntityCoords(PlayerPedId())
    local near = {}
    for id, r in pairs(rows) do
        local m = marks[id]
        if m and m.ped ~= 0 and DoesEntityExist(m.ped) then
            local p = GetEntityCoords(m.ped)
            local dx, dy, dz = p.x - myPos.x, p.y - myPos.y, p.z - myPos.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= NAME_RANGE * NAME_RANGE then near[#near + 1] = { r = r, d2 = d2 } end
        end
    end
    table.sort(near, function(a, b) return a.d2 < b.d2 end)
    local want = {}
    for i = 1, math.min(#near, CELLS) do want[near[i].r.s] = near[i].r end
    -- The ones leaving first, so a nearer player is never kept waiting for a farther one's cell.
    for id in pairs(tags) do
        if not want[id] then untag(id) end
    end
    for _, n in ipairs(near) do
        if want[n.r.s] then tag(n.r) end
    end
end)

ToolHandlers['Reveal Players'] = {
    enter = function()
        on = true
        TriggerServerEvent('whip_core:server:devShowPlayers', true)
        ControlBlocks.hold('devShowPlayers', {}, frame)
    end,
    exit = function()
        on = false
        TriggerServerEvent('whip_core:server:devShowPlayers', false)
        ControlBlocks.release('devShowPlayers')
        for id in pairs(marks) do unmark(id) end
        rows = {}
        detach()   -- the tags' browser goes with the tool
    end,
}
