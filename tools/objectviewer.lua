-- Object Viewer: names the props, vehicles and peds around you in the world, drawn by the game from one DUI texture
-- as billboards that face you. GTA gives only a model hash, so the name is read off the entity with
-- GetEntityArchetypeName (Cfx-only client native). It errors on anything that is not a ped, vehicle or object (the
-- three this tool scans) and can return an empty string, which counts as no name; the tag then falls back to the hash.
-- It shares InteractGetCameraForward and InteractComputeScore with client/interact.lua so the entity it picks is
-- chosen by the same maths that decides which E-prompt wins.

-- Is the object viewer open? tools/core.lua hears about a finished copy through OnClipboardCopied.
local ovActive = false
local duiSend    -- the atlas's messages (below); declared here for the copy's

-- G OPENS THE OPTIONS (tools/ov_panel.lua) for the one picked out; while they are open, or one of them has the
-- screen (Move), the card stays on that one (`lockedOn`) whatever the camera does. Copy details is one of them.
ObjectViewer = {}
local lockedOn = nil

--- Keep the card on `entity` (nil: back to whatever is looked at).
function ObjectViewer.lockOn(entity) lockedOn = entity end

--- The line Copy details puts on the clipboard, from what the card was built with.
function ObjectViewer.copy(p)
    CopyToClipboard(('%s\n%s (%d)\nvector4(%.2f, %.2f, %.2f, %.2f)'):format(
        p.name, p.hex, p.hash, p.x, p.y, p.z, p.heading))
end

OnClipboardCopied(function()
    if ovActive then
        duiSend({ copied = true })
        UI.Notify('Object details copied', 'success')
    end
end)

-- How far out entities are tagged. Deliberately shorter than the pools are wide: every metre of
-- range is more tags on screen, and past about 25m you cannot tell which tag belongs to what.
local OV_RANGE = 20.0

-- How often the entity pools are re-walked. Positions and focus are recomputed EVERY frame
-- (that is just arithmetic on a short list); this is only how often we ask the game for the
-- lists themselves, which is the expensive half.
local OV_RESCAN_MS = 400

-- Hard cap on tags, across all three pools combined. A busy junction holds well over a hundred
-- entities and drawing them all is both slow and unreadable. Nearest wins, whatever kind it is,
-- so standing in traffic will fill this with cars — which is the honest answer to "what is
-- around me" even if you came looking for props.
local OV_MAX_TAGS = 40

-- How the focused entity is chosen. These override the Config weights that E-prompts use, for
-- this tool only — see InteractComputeScore in client/interact.lua.
--
-- WHY THEY DIFFER FROM THE E-PROMPT WEIGHTS (0.6 distance / 0.4 camera). An E-prompt should
-- favour what is CLOSE, because you are standing at a thing and looking around while you use
-- it. A viewer should favour what is CENTRED, because you are pointing at something and asking
-- what it is. With the prompt weights, a bin at your feet beat the pump you were staring at:
-- being 1.5m away outscored being dead centre 8m away.
--
-- Distance is still in the mix, and still decides it when two things are both under the
-- crosshair — the nearer one wins, which is what you want when you are stood in front of a
-- shelf. It just no longer outvotes where you are actually looking.
local OV_DIST_WEIGHT   = 0.2
local OV_CAM_WEIGHT    = 0.8

-- Exponent on the camera term. The weights alone are not enough: the shared remap scores a
-- point 90 degrees off your shoulder at 0.5, so without this the camera term can barely tell
-- centred from vaguely-in-front. See the note in InteractComputeScore.
local OV_CAM_SHARPNESS = 4

-- Pool name -> the kind label the UI colours by. Object blue, ped green, vehicle red.
local OV_POOLS = {
    { pool = 'CObject',  kind = 'object'  },
    { pool = 'CPed',     kind = 'ped'     },
    { pool = 'CVehicle', kind = 'vehicle' },
}

-- THE CARD NAMES NO KIND IN WORDS: the kind is its disc's glyph and colour (html/interact3d/objview.html), sent as `kind`.

local tracked      = {}     -- [entity] = { kind, cell, name, readyAt }: the set currently tagged
local lastFocus    = nil    -- entity handle of the focused entity, for change detection
local lastScan     = 0
local focusPayload = nil    -- details of the focused entity, kept for the copy key

-- ============================================
-- Drawn by the game, from one DUI texture
-- ============================================
--
-- ON A DUI, NEVER HIDDEN BEHIND OBJECTS. The tags and the card are cells of
-- one texture (html/interact3d/objview.html), drawn every frame as flat sprites on their entity's projected point
-- (DrawSpriteUv: one cell of it). Flat on the screen, so they always face you and nothing in the world covers
-- them; sized as a billboard of a set height in the world would be at that distance (the camera's own field of
-- view), between a minimum — readable out at the 20 m edge — and a maximum, so one right
-- in front of you does not fill the screen. Nearer ones over farther ones; the open card over all of them.
--
-- ONE BROWSER, while the viewer is open: made on enter, given back on exit. DUI is one-way and drops what it is
-- sent before its page has loaded, so the whole state goes again a few times once it is up. A cell's new words
-- take a frame or two to paint, so a cell is drawn only DUI_SETTLE_MS after it was filled, fading in.

local DUI_PAGE, DUI_TXD, DUI_TEX = 'objview', 'whip_objview', 'atlas'
local ATLAS_W, ATLAS_H = 1024, 1568                 -- objview.html says the same: change both together
local TAG_W, TAG_H, TAG_COLS, TAG_CELLS = 512, 56, 2, 40
local TAG_DOT_X, TAG_DOT_Y = 12, 28                 -- the dot's middle in a tag cell: put on the point
local CARD_X, CARD_Y, CARD_W, CARD_H = 0, 1120, 560, 448
local CARD_DOT_X, CARD_DOT_Y = 12, 56               -- the dot's middle in the card cell, level with its disc

-- HOW BIG, as a share of the screen's height (so the same at any resolution), of the CELL drawn. The world height
-- is what shrinks it with distance; the minimum stops it.
local TAG_WORLD_H  = 0.13   -- metres: as tall as a tag would stand in the world
local TAG_MIN_H    = 0.032  -- never smaller: the old screen tag's size
local TAG_MAX_H    = 0.052  -- never bigger: a tag right in front of you
local CARD_WORLD_H = 1.05
local CARD_MIN_H   = 0.26   -- the old screen card's size
local CARD_MAX_H   = 0.36

local TAG_ALPHA     = 0.6   -- a tag at rest; the one you look at is whole
local FADE_MS       = 200   -- a cell fading in
local DUI_SETTLE_MS = 150   -- a cell's new words, painted
local DUI_RESEND_MS = { 400, 1200 }   -- the whole state again, this long after the browser is up (and once as it is)

local page                  -- the atlas's browser (below)
local freeCells = {}        -- tag cells nobody has: a stack
local cardFor, cardReadyAt = nil, 0
local padNow = nil          -- which copy key the card shows: the device in hand
local drawBroken = false

-- A tag cell's corners in the texture.
local CELL_UV = {}
for cell = 1, TAG_CELLS do
    local col, row = (cell - 1) % TAG_COLS, (cell - 1) // TAG_COLS
    CELL_UV[cell] = { col * TAG_W / ATLAS_W, row * TAG_H / ATLAS_H, (col + 1) * TAG_W / ATLAS_W, (row + 1) * TAG_H / ATLAS_H }
end
local CARD_UV = { CARD_X / ATLAS_W, CARD_Y / ATLAS_H, (CARD_X + CARD_W) / ATLAS_W, (CARD_Y + CARD_H) / ATLAS_H }

-- _DRAW_SPRITE_UV (0x95812F9B26074726): DRAW_SPRITE with the texture's corners — one cell of the atlas.
local drawUv = rawget(_G, 'DrawSpriteUv') or function(...) return Citizen.InvokeNative(0x95812F9B26074726, ...) end

-- Before the page is up a message is dropped: the whole state goes to it as it comes up.
duiSend = function(msg)
    if page:up() then page:send(msg) end
end

local function cardMsg(p)
    return { name = p.name, kind = p.kind, rows = p.rows, pic = p.pic or false }
end

--- Every tag, its cell, name and kind: the whole set, each time (the page empties a cell not named).
local function tagList()
    local list = {}
    for _, t in pairs(tracked) do list[#list + 1] = { cell = t.cell, name = t.name, kind = t.kind } end
    return list
end

--- The whole state: every tag, the card, the pad switch.
local function wholeState()
    return { tags = tagList(), card = focusPayload and cardMsg(focusPayload) or false, pad = padNow == true }
end

--- Made with the tool and given back with it. Up once IsDuiAvailable says so, then sent the whole state, and again
--- a few times after (a message sent before its page has loaded is lost).
page = DuiPage.new({
    name = 'objectviewer', url = ('interact3d/%s.html'):format(DUI_PAGE), width = ATLAS_W, height = ATLAS_H,
    txd = DUI_TXD, tex = DUI_TEX, setup = wholeState, again = DUI_RESEND_MS,
    without = 'the object viewer will draw nothing',
})

local function ensureDui() return page:ensure() end
local function releaseDui() page:release() end

--- How tall a cell is drawn, as a share of the screen's height: a billboard `worldH` metres tall at this depth,
--- held between the minimum and the maximum.
local function sizeAt(depth, worldH, minH, maxH, tanHalf)
    local h = worldH / (2.0 * depth * tanHalf)
    if h < minH then return minH elseif h > maxH then return maxH end
    return h
end

--- One cell, its dot on the point (sx, sy): `h` of the screen's height tall, as wide as the cell's shape makes it.
local function drawCell(uv, cellW, cellH, dotX, dotY, sx, sy, h, aspect, alpha)
    local w = h * (cellW / cellH) / aspect
    local cx = sx + (cellW * 0.5 - dotX) / cellW * w
    local cy = sy + (cellH * 0.5 - dotY) / cellH * h
    drawUv(DUI_TXD, DUI_TEX, cx, cy, w, h, uv[1], uv[2], uv[3], uv[4], 0.0, 255, 255, 255,
        math.floor(alpha * 255.0 + 0.5))
end

-- ============================================
-- Model name, hash and origin
-- ============================================

-- Resolved once at load. On builds where the native is exposed as a plain Lua global we call it
-- directly; otherwise we go through InvokeNative. rawget avoids a nil-global warning under
-- strict-global setups.
local archetypeFn = rawget(_G, 'GetEntityArchetypeName')

local function unsigned(h)
    h = math.tointeger(h) or math.floor(h + 0.5)
    if h < 0 then h = h + 0x100000000 end
    return h
end

-- WHAT THE GAME WILL NOT NAME, WHIP CAN. GTA V Enhanced answers GetEntityArchetypeName for some models only (a map's
-- own props) and nothing for the rest, so they showed as their hash. The media packs have a picture of every prop, car and
-- ped the Director places, each named by its model, and html/js/picture-bounds.js lists them all with the box round
-- what is drawn in each: read once, that list names a hash, and gives the card its picture (fitted as the Director
-- fits it, utils.js fitPicture). Read on first use and kept.
local known = nil   -- [unsigned hash] = { name, dir, box }
local PIC_DIRS = { p = 'props', v = 'vehicles', n = 'peds' }

local function knownModels()
    if known then return known end
    known = {}
    local src = LoadResourceFile(GetCurrentResourceName(), 'html/js/picture-bounds.js')
    if not src then
        print('[whip_core:objectviewer] html/js/picture-bounds.js would not load: no names or pictures beyond the game\'s own')
        return known
    end
    local dir
    for line in src:gmatch('[^\n]+') do
        local sec = line:match('^%s*(%a):%s*{')
        if sec then
            dir = PIC_DIRS[sec]
        elseif dir then
            local name, l, t, r, b = line:match("^%s*'([%w_]+)':%s*%[(%d+),%s*(%d+),%s*(%d+),%s*(%d+)%]")
            if name then
                known[unsigned(GetHashKey(name))] = { name = name, dir = dir,
                    box = { tonumber(l), tonumber(t), tonumber(r), tonumber(b) } }
            end
        end
    end
    return known
end

--- A name for a model the game would not name: whip's list, or a car's own display name when that is its model.
local function knownName(entity)
    local hash = unsigned(GetEntityModel(entity))
    local k = knownModels()[hash]
    if k then return k.name end
    if GetEntityType(entity) == 2 then
        local shown = GetDisplayNameFromVehicleModel(hash)
        if type(shown) == 'string' and shown ~= '' and shown ~= 'CARNOTFOUND' then
            shown = shown:lower()
            if unsigned(GetHashKey(shown)) == hash then return shown end
        end
    end
    return nil
end

--- The card's picture: a media pack's own of this model (a car, an NPC, a prop), or nil (the kind's glyph then).
--- Never for a player: their model's picture is not what they look like.
local function pictureOf(entity, kind)
    if kind == 'ped' and IsPedAPlayer(entity) then return nil end
    local k = knownModels()[unsigned(GetEntityModel(entity))]
    local want = kind == 'vehicle' and 'vehicles' or kind == 'ped' and 'peds' or 'props'
    if not k or k.dir ~= want then return nil end
    local url = WhipAssets.url(('img/%s/%s.webp'):format(k.dir, k.name))
    if not url then return nil end
    -- (dir and model for the options panel's head, html/js/ov-panel.js, which asks utils.js for the picture.)
    return { url = url, box = k.box, head = kind == 'ped', dir = k.dir, model = k.name }
end

--- Model name for an entity, or nil if neither the game nor whip can name it.
---@param entity number
---@return string|nil
local function EntityName(entity)
    -- The citizenfx bug is specifically about entity types outside ped/vehicle/object, so the
    -- type check is the actual guard here. The pcall underneath is for the case where the
    -- native is missing entirely on an older artifact.
    local etype = GetEntityType(entity)
    if etype ~= 1 and etype ~= 2 and etype ~= 3 then return nil end

    local ok, name
    if archetypeFn then
        ok, name = pcall(archetypeFn, entity)
    else
        ok, name = pcall(Citizen.InvokeNative, 0x47B870F5, entity, Citizen.ResultAsString())
    end

    if ok and type(name) == 'string' and name ~= '' then return name end
    return knownName(entity)
end

--- Model hash as an unsigned 32-bit integer, plus its hex form.
---
--- GetEntityModel hands back a SIGNED value on some builds, so hashes above 0x7FFFFFFF arrive
--- negative and print as '-1234567890' — which matches nothing you would search for. Wrapping
--- into unsigned range is what makes the hex agree with every hash list online.
---@param entity number
---@return integer hash
---@return string hex
local function EntityHash(entity)
    local raw = GetEntityModel(entity)
    local h = math.tointeger(raw) or math.floor(raw + 0.5)
    if h < 0 then h = h + 0x100000000 end
    return h, ('0x%08X'):format(h)
end

--- The resource that created this entity, if the game will say.
---
--- GetEntityScript is a base-GTA native that reports the script owning an entity, and under
--- FiveM that is normally the RESOURCE NAME — which is what makes "who spawned this" answerable
--- at all. It is called behind a pcall because the documented signature carries an out-param
--- that not every binding exposes the same way, and because entities owned by nothing at all
--- are a normal case rather than an error.
---
--- Returns nil rather than guessing. A nil here is not a failure — map props genuinely have no
--- owning script, and the caller falls back to classifying the entity instead.
---@param entity number
---@return string|nil
local function EntityResource(entity)
    local ok, name = pcall(GetEntityScript, entity)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return nil
end

-- GTA's own kinds of spawn (GetEntityPopulationType), for what no script made.
local POPULATION = {
    [1] = 'GTA (kept)', [2] = 'GTA (parked car)', [3] = 'GTA (patrol)', [4] = 'GTA (scenario)',
    [5] = 'GTA (traffic, passer-by)', [6] = 'GTA (kept)',
}

-- What the server said made a networked thing (server/object_viewer.lua whip_core:ov:origin: whose NPC, a temporary
-- car's resource), asked once the card has stayed on it a moment: [entity] = text, or false (asked).
local origins = {}

--- One line describing where an entity came from.
---
--- In order: a player; a whip car (its id bag says which, saved or not); what the server said for it; the resource the
--- game names (GetEntityScript, often nothing for what the server made); then GTA's own kind of spawn. "Script
--- (unnamed)" used to cover every whip car and NPC: the server made them, so no script on this game owns them.
---@return string
local function EntityOrigin(entity, kind)
    if kind == 'ped' and IsPedAPlayer(entity) then
        return ('Player %d'):format(GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity)))
    end
    if type(origins[entity]) == 'string' then return origins[entity] end
    if kind == 'vehicle' then
        local ok, vehicleId = pcall(Vehicles.idByEntity, entity)
        if ok and vehicleId then
            if Entity(entity).state[VEHICLE_SESSION_KEY] then return ('whip_core (street or temporary car #%s)'):format(vehicleId) end
            return ('whip_core (saved car #%s)'):format(vehicleId)
        end
    end
    local res = EntityResource(entity)
    if res then return res end
    local pop = GetEntityPopulationType(entity)
    if POPULATION[pop] then return POPULATION[pop] end
    if IsEntityAMissionEntity(entity) or pop == 7 then
        return NetworkGetEntityIsNetworked(entity) and 'A script (made on the server)' or 'A script (on this game)'
    end
    if NetworkGetEntityIsNetworked(entity) then return 'Networked' end
    return 'Map prop'
end

--- What whip itself knows about this entity, if anything (a car is said in Source).
---@return string|nil
local function WhipInfo(entity)
    local ok, door = pcall(GetDoorByEntity, entity)
    if ok and type(door) == 'table' and door.doorId then
        return ('Door #%s (%s)'):format(door.doorId, door.locked and 'locked' or 'unlocked')
    end

    return nil
end

-- ============================================
-- Scan + render thread
-- ============================================

--- Re-walk every pool and keep the nearest OV_MAX_TAGS within range.
---@return table [entity] = kind
local function RescanEntities(px, py, pz)
    local found = {}
    local playerPed = PlayerPedId()

    for _, src in ipairs(OV_POOLS) do
        for _, entity in ipairs(GetGamePool(src.pool)) do
            -- Your own ped is never interesting and would sit permanently under the crosshair.
            if entity ~= playerPed and DoesEntityExist(entity) then
                local c = GetEntityCoords(entity)
                local dx, dy, dz = c.x - px, c.y - py, c.z - pz
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist <= OV_RANGE then
                    found[#found + 1] = { entity = entity, dist = dist, kind = src.kind }
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.dist < b.dist end)

    local newTracked = {}
    for i = 1, math.min(#found, OV_MAX_TAGS) do
        newTracked[found[i].entity] = found[i].kind
    end
    return newTracked
end

--- Build the rows shown on the focused card.
---
--- Assembled here rather than in the NUI so that every decision about what is worth showing
--- lives in one place, and so a row that only sometimes applies — the whip one — can simply be
--- absent instead of rendering as an empty field.
local function BuildRows(entity, kind)
    local hash, hex = EntityHash(entity)
    local c = GetEntityCoords(entity)

    -- The kind is the card's glyph and colour, so not a row here.
    local rows = {
        { k = 'Hash',     v = hex },
        { k = 'Decimal',  v = tostring(hash) },
        { k = 'Entity',   v = tostring(entity) },
        { k = 'Position', v = ('%.2f, %.2f, %.2f'):format(c.x, c.y, c.z) },
        { k = 'Heading',  v = ('%.2f'):format(GetEntityHeading(entity)) .. '\u{00B0}' },
        { k = 'Source',   v = EntityOrigin(entity, kind) },
    }

    local whip = WhipInfo(entity)
    if whip then
        rows[#rows + 1] = { k = 'Whip', v = whip }
    end

    return rows, hex, hash, c
end

--- The card for any entity, as G hands it to its options (tools/ov_panel.lua OvPanel.open), without the viewer on:
--- Dungeon Mode's click on a thing in the world builder (client/director_live.lua). nil: not a ped, a car or an object.
function ObjectViewer.cardOf(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    local etype = GetEntityType(entity)
    local kind = etype == 1 and 'ped' or etype == 2 and 'vehicle' or etype == 3 and 'object' or nil
    if not kind then return nil end
    local rows, hex, hash, c = BuildRows(entity, kind)
    return { name = EntityName(entity) or hex, kind = kind, rows = rows, pic = pictureOf(entity, kind),
             hex = hex, hash = hash, x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(entity) }
end

--- Where an entity's tag sits, and the point that is aimed at: a ped's head. A ped seated in a car has its root at
--- the car's, so a passenger and the car were one point and only one of them could ever be picked.
local PED_HEAD = 31086   -- SKEL_Head
local function pointOf(entity, kind)
    if kind == 'ped' then return GetPedBoneCoords(entity, PED_HEAD, 0.0, 0.0, 0.0) end
    return GetEntityCoords(entity)
end

-- The server is asked who made a networked thing once the card has stayed on it this long: looking round asks nothing.
local ORIGIN_SETTLE_MS = 300
local originAsk = nil   -- { entity, at }

--- Ask the server what made it; its answer goes on the card's Source line if the card is still on it.
local function askOrigin(entity)
    origins[entity] = false
    local net = NetworkGetNetworkIdFromEntity(entity)
    CreateThread(function()
        local text = Callback('whip_core:ov:origin', net)
        if type(text) ~= 'string' or not ovActive then return end
        origins[entity] = text
        if lastFocus ~= entity or not focusPayload then return end
        for _, r in ipairs(focusPayload.rows) do
            if r.k == 'Source' then r.v = text end
        end
        duiSend({ card = cardMsg(focusPayload) })
    end)
end

--- Started on enter, ended on exit.
local loopRunning = false

local function loop()
    while true do
        if not ovActive then
            break
        else
            local ped = PlayerPedId()
            local pc  = GetEntityCoords(ped)
            local px, py, pz = pc.x, pc.y, pc.z
            local cfx, cfy, cfz = InteractGetCameraForward()

            -- Where "centred on screen" is measured from. GetFinalRenderedCamCoord is the
            -- matching pair to the GetFinalRenderedCamRot that InteractGetCameraForward reads,
            -- so position and direction always describe the SAME camera — including whenever
            -- something else has taken the view over.
            --
            -- Hoisted out of the entity loop: it is one native call per frame rather than one
            -- per tagged entity, and every entity in a frame must be judged against the same
            -- camera anyway.
            local camCoord = GetFinalRenderedCamCoord()

            local now = GetGameTimer()

            -- Which copy key the card shows: the device in hand.
            local pad = WhipLastInputIsPad()
            if pad ~= padNow then
                padNow = pad
                duiSend({ pad = pad })
            end

            -- Refresh the tracked set on its own slower clock.
            if now - lastScan >= OV_RESCAN_MS then
                lastScan = now
                local newTracked = RescanEntities(px, py, pz)

                -- Arrivals take a free cell, departures give theirs back. Names are only ever read here,
                -- not every frame — resolving a string per entity per frame is the one thing in this loop
                -- that would actually cost something.
                local changed = false
                for entity in pairs(tracked) do
                    if not newTracked[entity] then
                        freeCells[#freeCells + 1] = tracked[entity].cell
                        tracked[entity] = nil
                        changed = true
                    end
                end
                for entity, kind in pairs(newTracked) do
                    if not tracked[entity] and #freeCells > 0 then
                        -- Only the hex is wanted here: it is the fallback shown on the tag when the game
                        -- will not give up a name.
                        local _, hex = EntityHash(entity)
                        local cell = table.remove(freeCells)
                        tracked[entity] = { kind = kind, cell = cell, name = EntityName(entity) or hex,
                                            readyAt = now + DUI_SETTLE_MS }
                        changed = true
                    end
                end
                if changed then duiSend({ tags = tagList() }) end
            end

            -- Every frame: project each tracked entity, measure how far in front of the camera it is, and
            -- score it for focus.
            local vis = {}
            local bestScore, bestEntity = -1, nil

            for entity, t in pairs(tracked) do
                if DoesEntityExist(entity) then
                    local c = pointOf(entity, t.kind)
                    local score = InteractComputeScore(
                        px, py, pz, cfx, cfy, cfz, c.x, c.y, c.z, OV_RANGE,
                        OV_DIST_WEIGHT, OV_CAM_WEIGHT, OV_CAM_SHARPNESS, camCoord)

                    if score >= 0 then
                        local onScreen, sx, sy = World3dToScreen2d(c.x, c.y, c.z)
                        local depth = (c.x - camCoord.x) * cfx + (c.y - camCoord.y) * cfy + (c.z - camCoord.z) * cfz
                        if onScreen and depth > 0.05 then
                            vis[#vis + 1] = { entity = entity, sx = sx, sy = sy, depth = depth }
                            if score > bestScore then
                                bestScore, bestEntity = score, entity
                            end
                        end
                    end
                end
            end

            -- Its options open: the card stays on that one while it is on screen.
            if lockedOn then
                bestEntity = nil
                for i = 1, #vis do
                    if vis[i].entity == lockedOn then bestEntity = lockedOn break end
                end
            end

            -- Full details only when the focused entity actually changes. The card is static while you hold
            -- still on one thing, so re-sending it every frame would be pure noise on the message channel.
            if bestEntity ~= lastFocus then
                lastFocus = bestEntity
                if bestEntity then
                    local kind = tracked[bestEntity].kind
                    local rows, hex, hash, c = BuildRows(bestEntity, kind)
                    focusPayload = {
                        name    = EntityName(bestEntity) or hex,
                        kind    = kind,
                        rows    = rows,
                        pic     = pictureOf(bestEntity, kind),
                        -- Kept flat as well as in rows, purely for the clipboard line.
                        hex     = hex,
                        hash    = hash,
                        x       = c.x, y = c.y, z = c.z,
                        heading = GetEntityHeading(bestEntity),
                    }
                    duiSend({ card = cardMsg(focusPayload) })
                    cardFor, cardReadyAt = bestEntity, now + DUI_SETTLE_MS
                    -- Who made it, from the server, once the card has stayed on it (not for a player: said here).
                    if origins[bestEntity] == nil and NetworkGetEntityIsNetworked(bestEntity)
                        and not (kind == 'ped' and IsPedAPlayer(bestEntity)) then
                        originAsk = { entity = bestEntity, at = now + ORIGIN_SETTLE_MS }
                    end
                else
                    focusPayload, cardFor = nil, nil
                end
                -- White on it in the world: G opens its options (client/highlight.lua; theirs, open, is blue).
                Highlight.set('objectViewer', { hover = bestEntity })
            end

            if originAsk and now >= originAsk.at then
                local e = originAsk.entity
                originAsk = nil
                if e == lastFocus and origins[e] == nil and DoesEntityExist(e) then askOrigin(e) end
            end

            -- Draw: farthest first, so a nearer tag lies over a farther one; the card last, over them all. The
            -- tag you look at stays under its card while the card fades in, so it never blinks out.
            if page:exists() and not drawBroken and not IsPauseMenuActive() and #vis > 0 then
                table.sort(vis, function(a, b) return a.depth > b.depth end)
                local tanHalf = math.tan(math.rad(GetFinalRenderedCamFov()) * 0.5)
                local rw, rh = GetActiveScreenResolution()
                local aspect = (rh and rh > 0) and rw / rh or (16 / 9)
                local cardAlpha = (cardFor and now >= cardReadyAt) and math.min(1.0, (now - cardReadyAt) / FADE_MS) or 0.0
                local cardAt = nil

                local ok, err = pcall(function()
                    for i = 1, #vis do
                        local v = vis[i]
                        local t = tracked[v.entity]
                        local focused = v.entity == bestEntity
                        if focused and cardFor == v.entity then cardAt = v end
                        if now >= t.readyAt then
                            local a = (focused and (1.0 - cardAlpha) or TAG_ALPHA) * math.min(1.0, (now - t.readyAt) / FADE_MS)
                            if a > 0.004 then
                                drawCell(CELL_UV[t.cell], TAG_W, TAG_H, TAG_DOT_X, TAG_DOT_Y, v.sx, v.sy,
                                    sizeAt(v.depth, TAG_WORLD_H, TAG_MIN_H, TAG_MAX_H, tanHalf), aspect, a)
                            end
                        end
                    end
                    if cardAt and cardAlpha > 0.0 then
                        drawCell(CARD_UV, CARD_W, CARD_H, CARD_DOT_X, CARD_DOT_Y, cardAt.sx, cardAt.sy,
                            sizeAt(cardAt.depth, CARD_WORLD_H, CARD_MIN_H, CARD_MAX_H, tanHalf), aspect, cardAlpha)
                    end
                end)
                -- A game build without _DRAW_SPRITE_UV: said once, and nothing drawn, rather than an error a frame.
                if not ok then
                    drawBroken = true
                    print('[whip_core:objectviewer] drawing failed (does this game build have DrawSpriteUv?): ' .. tostring(err))
                    UI.Notify('The object viewer cannot draw on this game build', 'error')
                end
            end

            -- G opens its options (tools/ov_panel.lua). Guarded on actually having something focused so it stays
            -- quiet otherwise, and on no options already open (Move keeps the game's keys).
            -- ON A PAD THE SAME CONTROL IS D-PAD LEFT (47 is G and D-left both), so the card shows that
            -- button there (`pad`, above); on foot D-left's own action, the engine, does nothing.
            -- LB + D-left is LB's (a combo), never the options.
            if focusPayload and lastFocus and not lockedOn and IsControlJustPressed(0, 47)
                and not (WhipPadModHeld and WhipLastInputIsPad())
                and not OvPanel.busy() then
                OvPanel.open(lastFocus, focusPayload)
            end

            Wait(0)
        end
    end
    loopRunning = false
end

-- ============================================
-- Register with tool system
-- ============================================

--- Everything back to closed: no tags, every cell free, no card.
local function reset()
    tracked      = {}
    lastFocus    = nil
    focusPayload = nil
    cardFor      = nil
    padNow       = nil
    origins      = {}
    originAsk    = nil
    freeCells    = {}
    for cell = TAG_CELLS, 1, -1 do freeCells[#freeCells + 1] = cell end   -- a stack: cell 1 first
end

ToolHandlers['Object Viewer'] = {
    enter = function()
        ovActive   = true
        lastScan   = 0      -- force a scan on the very next frame rather than after 400ms
        drawBroken = false
        reset()
        ensureDui()
        if not loopRunning then
            loopRunning = true
            CreateThread(loop)
        end
    end,
    exit = function()
        ovActive = false
        OvPanel.close()
        lockedOn = nil
        Highlight.set('objectViewer', nil)
        reset()
        releaseDui()
    end,
}
