-- The Furnisher: fly around a property and place furniture, bounded by the property's space.
-- Right mouse held: mouse looks, WASD flies. Released: the cursor clicks, drags the page's X / Y / Z markers
-- (R swaps them for rings), and the wheel scrolls the catalog. G cycles snapping.
-- The editor holds NUI focus with KeepInput, so the page reports text focus (furnishTyping) and key reads stand down.
-- Ways out: Backspace (key mapping at the bottom), the Exit button, or /furnish again.
-- Saves are wholesale: the server replaces the property's whole object list in one transaction.

-- Read by client/interact.lua the same way PlacingModeActive is: while this owns the E key, the
-- wheel and the camera, prompts and aim targeting stand down.
FurnishModeActive = false

local startModeLoop   -- the mode's frame loop, started on entry; defined with the loop below
local beginSession    -- the open shared by every session; defined with enterFurnish below

local propertyId   = nil   -- the property being furnished
local opening      = false -- an open is asking the server (its lock, the room's rows): one at a time

--- How much give the space has, matching the server's (server/property_objects.lua).
local SPACE_SLACK = 0.3

--- The open session: what the working set belongs to, and its rules. Either a property's room (enterFurnish)
--- or a caller's session (Furnisher.open): anywhere, no limit, and Done hands the set back instead of saving.
---   title        the card's name for it
---   max          how many things it may hold; nil: no limit
---   mayBeAt      fn(x, y, z): may a thing stand there; nil: anywhere
---   refusedPick  what a pick outside it says; refusedMove: a drag outside it
---   leash        the camera's sphere (FreeCam's leash); nil: none
---   save         fn(payload): the Save (or Done) button, with the whole working set
---   release      fn(): as it closes, before the camera goes
---   resume       fn(): once the camera has gone
---   noun         what the goodbye calls it ('Furnishing')
---   page         the page's options, with the world builder's extras (client/furnish_builder.lua)
---   camera       { pos, rot, fov }: where the camera starts; nil: at the player
---   onSpawn      fn(item, entity): one of its peds made; onAction fn(id): its button
---@type table|nil
local session = nil

--- May a thing stand here, in the open session?
local function insideSpace(x, y, z)
    if not session then return false end
    return session.mayBeAt == nil or session.mayBeAt(x, y, z) == true
end

--- Is the right mouse button down — is the player turning the room rather than using the cursor?
local looking = false

--- Is the pointer over one of the page's panels (furnishOverUi), and was the right button pressed there? Such a press is the panel's.
local overUi = false
local uiPress = false

--- Is a text field in the NUI focused? Pushed by the browser.
local typing = false

--- Is a screen of the session's over the editor (Furnisher.pause)? Keys stand down as for typing.
local paused = false

--- On a controller the page says when a pad drives the editor (furnishPad) and when its menu has the pad.
--- In the room the sticks fly the camera and work happens at the centre dot: A selects, X picks up (it rides the
--- dot), A puts down, B puts back. D-pad nudges a step, triggers raise and lower, RB is Move / Rotate.
--- The page forwards presses (furnishPadPress); the triggers are read here every frame (padFrame).
local padOn   = false   -- a controller drives the editor (the page's pad scope is up)
local padMenu = false   -- ... and its menu has the pad
--- The selection riding the dot: { index, from = { x, y, z, rx, ry, rz } }, `from` nil for a thing just
--- picked from the catalog (B then takes it back out), or nil.
local carrying = nil
local padTrigWas = false   -- a trigger was in last frame (the readout catches up when it is let go)
local PAD_RAISE = 0.6      -- metres a second, a trigger all the way in
local PAD_TURN  = 90.0     -- degrees a second, a trigger all the way in while carrying (read: WhipPadTrigger)
--- Save and exit on a pad: Menu (INPUT_FRONTEND_PAUSE) and View (INPUT_FRONTEND_SELECT). Read here and handed to
--- the page, which presses its own Save and Exit, so Exit asks "Discard?" over unsaved work as a click does.
--- The pause menu stands aside (client/pause.lua) while a pad drives.
local PAD_SAVE, PAD_EXIT = 199, 217
local PAD_BLOCK = 'furnishPad'
local padBlockHeld = false

--- Hold Menu and View for the editor while a pad drives it, or give them back (see PAD_SAVE).
local function holdPadButtons(on)
    on = on == true
    if on == padBlockHeld then return end
    padBlockHeld = on
    if on then
        ControlBlocks.hold(PAD_BLOCK, { controls = { PAD_SAVE, PAD_EXIT } })
    else
        ControlBlocks.release(PAD_BLOCK)
    end
end

--- The timestamp of the first Backspace while there was unsaved work, or nil.
--- One press warns, a second within the window leaves; with nothing unsaved the first leaves.
local quitArmedAt = nil
local QUIT_ARM_MS = 3000

--- The working set. [i] = { model, x, y, z, rx, ry, rz, obj }
--- A working copy: the streamed set is paused for this property on entry. Nothing is saved until Save.
local items = {}

--- Rows whose model would not load on this client. Not editable, but sent back unchanged on Save.
local unloadable = {}

local selected = nil    -- index into `items`, or nil

--- Several selected together (Ctrl+click): the things in pick order, the primary (`selected`) among them.
--- Kept by the thing, not its row, so a renumbering removal cannot point it at another.
local picked = {}
--- Their heading on the rings while several are selected: 0 each time the set changes.
local groupTurn = 0.0
--- [row] = true for every row selected now (the primary alone, or the set), as pushState last worked it out.
local selectedRows = {}

--- The things selected together now, in pick order. Nil with one or none selected.
local function pickedNow()
    if #picked < 2 then return nil end
    local prim = selected and items[selected]
    -- Asked several times a frame: returns the same list while nothing changed.
    local whole, hasPrim0 = true, false
    for _, it in ipairs(picked) do
        if it == prim then hasPrim0 = true end
        local found = false
        for i = 1, #items do if items[i] == it then found = true break end end
        if not found then whole = false break end
    end
    if whole and hasPrim0 then return picked end
    local here = {}
    for i = 1, #items do here[items[i]] = true end
    local out, hasPrim = {}, false
    for _, it in ipairs(picked) do
        if here[it] then
            out[#out + 1] = it
            if it == prim then hasPrim = true end
        end
    end
    -- (The primary not among them: something else was selected on its own since, which ends the set.)
    if not hasPrim or #out < 2 then picked = {} return nil end
    picked = out
    return out
end

--- Its row in the set now, or nil.
local function rowOf(it)
    for i = 1, #items do
        if items[i] == it then return i end
    end
    return nil
end

--- The world builder is opening (its models loading): a close asked for meanwhile is kept for after.
local closeAsked = false

--- Has anything changed since the last successful save?
---
--- Exiting discards unsaved work, with an unsaved marker and a goodbye toast.
local dirty = false

--- A Save that stays open clears `dirty` only when nothing changed meanwhile (Furnisher.markSaved).
local edits, savedAt = 0, 0

--- The version of the room this editor opened on, sent with every Save. The server refuses any other version;
--- a successful save hands back the new one.
local baseVersion = nil

--- What the markers on the selection do: 'move' (arrows) or 'rotate' (rings). R swaps them.
local mode = 'move'

--- The heading a newly picked prop starts at: that of the last one placed or turned.
local lastRz = 0.0

-- Snap: G goes off, first step, next step, ..., off (cycleSnap). On: every drag snaps. Off: a drag is free,
-- and Shift snaps that drag. Indices into the config lists. A pad's nudge is always one step.
local snapOn = false
local moveStep = 1
local turnStep = 1

--- Was the last move the page asked for refused (outside the space)? Sent with the view; cleared when the drag ends.
local blocked = false
local blockedToldAt = -math.huge   -- when the "outside the property" notice last went out

-- The prop catalog, as the server last sent it.
local catalog = { categories = {}, props = {} }

--- May this player dress a property they do not own?
--- Reads the client's copy of developer mode (DevToolsOn) because the access callback blocks. It only decides whether
--- an option appears; the server re-decides on save.
local function devAllowed()
    return DevToolsOn ~= nil and DevToolsOn()
end

-- ---- controls ----
-- Disabled controls are read with IsDisabledControl*. Freecam disables 37 (Tab) and 24 (attack, also every left click);
-- the editor's block holds the rest. Other resources' key mappings still fire under KeepInput and stand down via IsGameInputFree.
local KEY_LOOK    = 25    -- right mouse — held, the camera listens; see the top of the file
local KEY_MODE    = 45    -- R  — the markers: move / rotate
local KEY_SNAP    = 47    -- G  — cycle the snap step
local KEY_DELETE  = 73    -- X  — remove the selection

--- Silenced, never read: disabled so none does its game job under the editor (E enters a vehicle, the wheel switches weapon).
local SILENCED = {
    38,               -- E          (INPUT_CONTEXT: get in that car)
    26,               -- C          (look behind)
    19,               -- left alt   (character wheel)
    14, 15, 16, 17,   -- the wheel: all its weapon-switching pairs on a keyboard
    140,              -- melee
    257,              -- attack 2
}

--- R, G, X and the silenced set, held off while the editor is up (ControlBlocks). The editor reads them with the disabled readers.
local KEYS_BLOCK = 'furnishKeys'

local function keysSpec()
    local list = { KEY_MODE, KEY_SNAP, KEY_DELETE }
    for i = 1, #SILENCED do list[#list + 1] = SILENCED[i] end
    return { controls = list }
end

-- No control id for Backspace: 177 is bound to Backspace and the right mouse button (the look control), so the
-- key mapping at the bottom asks for the key.

-- ---- Catalog ----
-- The whole catalog arrives at login (propCatalogSync, latent); after that only changed rows (propCatalogChanged).
-- Only the game can say a model name is wrong (IsModelInCdimage): names this client lacks are never offered, and an
-- admin's client reports them so the server marks them unavailable.

local missing = {}    -- [model] = true for catalog models this client cannot spawn
local reported = {}   -- [model] = true once sent, so a resync does not send them again

local function inGame(model)
    local hash = GetHashKey(model)
    return IsModelInCdimage(hash) and IsModelValid(hash)
end

--- Is a model a lamp (the catalog's lighting category)? Lamps are filed in the interior's limbo, not a room,
--- or they light nothing (client/interior_rooms.lua). Rebuilt whenever the catalog's list is replaced.
local lightSet, lightSetFor = {}, nil
local function isLightModel(model)
    local props = catalog.props
    if lightSetFor ~= props then
        lightSet, lightSetFor = {}, props
        for _, p in ipairs(props or {}) do
            if p.category == 'lighting' and type(p.model) == 'string' then lightSet[p.model:lower()] = true end
        end
    end
    return type(model) == 'string' and lightSet[model:lower()] == true
end

local function checkCatalog()
    missing = {}
    for _, p in ipairs(catalog.props or {}) do
        if not inGame(p.model) then missing[p.model] = true end
    end
end

--- The catalog as the furnisher shows it: without the props this game does not have.
local function shownCatalog()
    if next(missing) == nil then return catalog end
    local props = {}
    for _, p in ipairs(catalog.props or {}) do
        if not missing[p.model] then props[#props + 1] = p end
    end
    return { clusters = catalog.clusters, categories = catalog.categories, props = props }
end

local function reportMissing()
    if not devAllowed() then return end
    local list = {}
    for model in pairs(missing) do
        if not reported[model] and #list < 500 then
            list[#list + 1] = model
            reported[model] = true
        end
    end
    if #list > 0 then TriggerServerEvent('whip_core:server:propCatalogMissing', list) end
end

-- The full catalog is a latent event, so a change can arrive before it. Each change carries the server's push
-- number: one the catalog already includes is skipped, and one that beat it waits and is applied after.
local catalogVersion = nil   -- the push the catalog held here includes; nil until the full one lands
local earlyChanges = {}      -- changes that arrived before it, newest kept (only the last moment's matter)

--- Merge one push of changed rows into the catalog held here.
local function applyChange(delta)
    local rows = {}
    for _, p in ipairs(catalog.props or {}) do rows[p.model] = p end
    for _, model in ipairs(delta.removed or {}) do
        rows[model] = nil
        missing[model] = nil
    end
    for _, p in ipairs(delta.props or {}) do
        if type(p) == 'table' and type(p.model) == 'string' then
            rows[p.model] = p
            missing[p.model] = not inGame(p.model) or nil
        end
    end

    local props = {}
    for _, p in pairs(rows) do props[#props + 1] = p end
    table.sort(props, function(a, b) return a.model < b.model end)
    catalog.props = props
end

RegisterNetEvent('whip_core:client:propCatalogSync', function(data)
    if type(data) ~= 'table' then return end
    catalog = data
    catalogVersion = tonumber(data.version) or 0
    local early = earlyChanges
    earlyChanges = {}
    for _, delta in ipairs(early) do
        local v = tonumber(delta.version) or 0
        if v > catalogVersion then
            applyChange(delta)
            catalogVersion = v
        end
    end
    checkCatalog()
    if FurnishModeActive then
        SendNUIMessage({ action = 'furnishCatalog', catalog = shownCatalog() })
    end
    -- Reported by a developer with developer mode on (the server checks again); nobody else.
    reportMissing()
end)

--- Rows added, renamed, re-pictured or taken away since the full sync.
RegisterNetEvent('whip_core:client:propCatalogChanged', function(delta)
    if type(delta) ~= 'table' then return end
    if catalogVersion == nil then
        -- Before the full catalog: kept for it (only the last few can be newer, so a cap applies).
        if #earlyChanges >= 20 then table.remove(earlyChanges, 1) end
        earlyChanges[#earlyChanges + 1] = delta
        return
    end
    local v = tonumber(delta.version) or 0
    if v <= catalogVersion then return end   -- already in the catalog held here
    catalogVersion = v
    applyChange(delta)

    if FurnishModeActive then
        SendNUIMessage({ action = 'furnishCatalog', catalog = shownCatalog() })
    end
    reportMissing()
end)

-- ============================================
-- Helpers
-- ============================================

local function loadModel(hash)
    return LoadModel(hash) ~= nil   -- client/streaming.lua
end

--- Config step lists, read at the point of use so a config reload means something.
local function moveSteps() return Config.FurnishMoveSteps or { 0.05, 0.25, 1.0 } end
local function turnSteps() return Config.FurnishTurnSteps or { 15.0, 45.0, 1.0 } end

local function moveAmount() local s = moveSteps() return s[moveStep] or s[1] or 0.25 end
local function turnAmount() local s = turnSteps() return s[turnStep] or s[1] or 15.0 end

--- G, or the bar's snap chip: snap on at the first step, the next step, and past the last, off again.
local function cycleSnap()
    if not snapOn then
        snapOn, moveStep, turnStep = true, 1, 1
    elseif moveStep < #moveSteps() then
        moveStep = moveStep + 1
        turnStep = math.min(turnStep + 1, #turnSteps())
    else
        snapOn, moveStep, turnStep = false, 1, 1
    end
end

--- Did a ray hit? FiveM hands `hit` back as 1 on some builds and true on others.
local function isHit(hit) return hit == 1 or hit == true end

-- ---- What a thing is (its kind) ----
-- A property's room holds props only. The world builder's things have other kinds (`extra.kind`), added by
-- client/furnish_builder.lua (FurnishBuilder.attach). What this file honours of a kind:
--   make    'object' (a prop), 'ped' (an NPC), 'vehicle' (a car)
--   mark    no model: a marker drawn where it is
--   lift    a marker's height above the floor it is put on
--   tilt    turns all three ways (a prop); every other kind only by heading
--   door    a door the world already has: never made, moved or deleted here
--   noLoad  what a pick says when its model will not load
-- The ped, car, marker and door are made by FurnishBuilder.spawn.
local KINDS = {
    prop       = { make = 'object', tilt = true },
}

local function kindOf(it) return type(it.extra) == 'table' and KINDS[it.extra.kind] and it.extra.kind or 'prop' end

-- ---- Pointing at the working copies ----
-- They have no collision, so a shape test cannot see them: the camera segment is carried into each object's frame
-- and tested against the model's dimensions, with a bounding-sphere check in front.

--- [model] = { mn, mx, r }: a model's box and the distance from its origin to its furthest corner.
local dimsCache = {}

local function dimsOf(model)
    local d = dimsCache[model]
    if d then return d end
    local mn, mx = GetModelDimensions(GetHashKey(model))
    if not mn or not mx then return nil end
    -- Per axis, not per corner vector: the furthest corner can take x from mn and y from mx.
    local ex = math.max(math.abs(mn.x), math.abs(mx.x))
    local ey = math.max(math.abs(mn.y), math.abs(mx.y))
    local ez = math.max(math.abs(mn.z), math.abs(mx.z))
    d = { mn = mn, mx = mx, r = math.sqrt(ex * ex + ey * ey + ez * ez) }
    dimsCache[model] = d
    return d
end

--- The three axes, for the box tests below.
local AXES = { 'x', 'y', 'z' }

--- Where the segment from→to first enters this working object's box: the fraction along the
--- segment, and the world-space normal of the face it came in through. Nil when it misses, or when
--- it starts inside the box.
local function segmentHitsItem(it, from, to)
    -- A marker has nothing in the world to ask: its box stands upright round its spot. Never a surface to stand on.
    if it.mark then
        local d = it.dims
        if not d then return nil end
        local tmin, tmax = 0.0, 1.0
        for _, k in ipairs(AXES) do
            local o, dir = from[k] - it[k], to[k] - from[k]
            local lo, hi = d.mn[k], d.mx[k]
            if math.abs(dir) < 1e-9 then
                if o < lo or o > hi then return nil end
            else
                local t1, t2 = (lo - o) / dir, (hi - o) / dir
                if t1 > t2 then t1, t2 = t2, t1 end
                if t1 > tmin then tmin = t1 end
                if t2 < tmax then tmax = t2 end
                if tmin > tmax then return nil end
            end
        end
        return tmin, vector3(0.0, 0.0, 0.0)
    end
    local obj, d = it.obj, it.dims
    if not obj or not d or not DoesEntityExist(obj) then return nil end

    -- A segment further from the object than its furthest corner cannot touch it.
    local at = it.playing and GetEntityCoords(obj) or it
    local sx, sy, sz = to.x - from.x, to.y - from.y, to.z - from.z
    local len2 = sx * sx + sy * sy + sz * sz
    local px, py, pz = at.x - from.x, at.y - from.y, at.z - from.z
    local u = len2 > 0 and math.max(0.0, math.min(1.0, (px * sx + py * sy + pz * sz) / len2)) or 0.0
    local cx, cy, cz = px - sx * u, py - sy * u, pz - sz * u
    if cx * cx + cy * cy + cz * cz > d.r * d.r then return nil end

    local a = GetOffsetFromEntityGivenWorldCoords(obj, from.x, from.y, from.z)
    local b = GetOffsetFromEntityGivenWorldCoords(obj, to.x, to.y, to.z)
    local tmin, tmax, face, sign = 0.0, 1.0, nil, 0
    for _, k in ipairs(AXES) do
        local o, dir = a[k], b[k] - a[k]
        local lo, hi = d.mn[k], d.mx[k]
        if math.abs(dir) < 1e-9 then
            if o < lo or o > hi then return nil end
        else
            local t1, t2, s = (lo - o) / dir, (hi - o) / dir, -1
            if t1 > t2 then t1, t2, s = t2, t1, 1 end
            if t1 > tmin then tmin, face, sign = t1, k, s end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    if not face then return nil end

    local ln = { x = 0.0, y = 0.0, z = 0.0 }
    ln[face] = sign
    local wo = GetEntityCoords(obj)
    local wn = GetOffsetFromEntityInWorldCoords(obj, ln.x, ln.y, ln.z)
    return tmin, vector3(wn.x - wo.x, wn.y - wo.y, wn.z - wo.z)
end

--- The first working object the segment meets. With `onTop`, only an upward-facing face counts (what a thing can stand on).
---@param skip number|nil  an index never counted (the one being dragged: it cannot stand on itself)
---@return number|nil index, number|nil fraction
local function firstItemHit(from, to, onTop, skip)
    local best, bestT = nil, math.huge
    for i = 1, #items do
        -- (Only what has a top stands things: not a marker, nor a car or a person.)
        local tops = i ~= skip and (not onTop or (not items[i].mark and kindOf(items[i]) == 'prop'))
        local t, n = nil, nil
        if tops then t, n = segmentHitsItem(items[i], from, to) end
        ---@cast n vector3   -- answered with t: there whenever t is
        if t and t < bestT and (not onTop or n.z > 0.7) then best, bestT = i, t end
    end
    return best, best and bestT or nil
end

--- Spawn one working copy, collision off (it would block the placement ray). Clicks and table tops use their boxes.
--- The stream re-spawns them with collision on Save and Exit.
--- The world builder's other kinds are made by client/furnish_builder.lua, asked first.
---@return number|nil entity
local function spawnWorking(it)
    local made, ent = FurnishBuilder.spawn(it)
    if made then
        -- (Dressed by the resources that keep something on it: a car's Whiplash look.)
        if ent and not it.door then FurnishBuilder.dress(it, ent) end
        return ent
    end
    local hash = GetHashKey(it.model)
    if not IsModelInCdimage(hash) or not loadModel(hash) then return nil end

    -- No offset, as the room's own copies: CreateObject lifts some models on Z.
    local obj = CreateObjectNoOffset(hash, it.x, it.y, it.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 then return nil end

    SetEntityRotation(obj, it.rx or 0.0, it.ry or 0.0, it.rz or 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    SetEntityAsMissionEntity(obj, true, true)
    -- Read while the model is loaded, for pointing at it later.
    it.dims = dimsOf(it.model)
    -- Filed in its room (a lamp in the limbo), or the game culls it with the wrong room. Filed again when a drag changes room.
    it.room = InteriorRooms.fileFurniture(obj, isLightModel(it.model))
    FurnishBuilder.dress(it, obj)
    return obj
end

--- A working copy made again as another `model` where it stands, its base kept (not its origin), so models of other sizes sit on the floor.
local function remakeAs(it, model)
    local base = it.dims and not it.mark and it.z + it.dims.mn.z or nil
    if it.obj and DoesEntityExist(it.obj) then DeleteEntity(it.obj) end
    it.obj = nil
    it.model = model
    it.obj = spawnWorking(it)   -- (its dims are the new model's once it is made: read while it is loaded)
    if base and it.dims then
        it.z = base - it.dims.mn.z
        if it.obj and DoesEntityExist(it.obj) then SetEntityCoordsNoOffset(it.obj, it.x, it.y, it.z, false, false, false) end
    end
end

local function despawnWorking()
    for i = 1, #items do
        local obj = items[i].obj
        -- (A picked door is the world's own, and so is a Dungeon Mode thing: only let go of, never deleted.)
        if obj and not items[i].door and not items[i].world and DoesEntityExist(obj) then DeleteEntity(obj) end
        items[i].obj = nil
    end
end

-- ---- Dungeon Mode's session (client/director_live.lua) ----
-- The world builder on the live world: a pick put down is made for real, and its things are the world's own
-- (`world`: a real NPC, car, prop or player), moved where they live and never deleted here. Nothing is unsaved.

--- Its handlers (Furnisher.open's spec.live), or nil.
local function liveOf() return session and session.live or nil end

--- One of its handlers, answered (nil when there is none, or it failed: said in the console).
local function liveCall(name, ...)
    local L = liveOf()
    local fn = L and L[name]
    if type(fn) ~= 'function' then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        print('[whip_core:furnish] Dungeon Mode\'s ' .. name .. ' failed: ' .. tostring(a))
        return nil
    end
    return a, b
end

-- ---- marking the selection in the room ----
-- The selection is marked (client/highlight.lua): blue, an outline on an object, corners round a ped or a car.
-- What is under the pointer is marked white, and what a Blueprint card names green. A selection with no entity wears a chevron.

--- Does this build have the outline natives? Resolved once, at entry (Highlight.outlines).
local outlineOk = false

--- What the pointer is over now that a click would pick, or nil: hoverFrame keeps it.
local hoverEnt = nil

--- Is this one outlined in green when a card names it? A prop and a picked door; a ped or car has its own mark.
local function outlines(it)
    return it ~= nil and (it.door == true or KINDS[kindOf(it)].make == 'object')
end

--- The marks on the things a card names, the selection, and what is under the pointer.
local function refreshOutline()
    local lit = {}
    for i = 1, #items do
        local it = items[i]
        if it.obj and outlines(it) and FurnishBuilder.isLit(it) then lit[#lit + 1] = it.obj end
    end
    local set = pickedNow()
    local marked
    if set then
        marked = {}
        for _, it in ipairs(set) do
            if it.obj then marked[#marked + 1] = it.obj end
        end
    else
        local sel = selected and items[selected] or nil
        marked = sel and sel.obj or nil
    end
    Highlight.set('furnish', { hover = hoverEnt, selected = marked, lit = lit })
end

--- Everything the HUD and the panel need to draw one frame, pushed on change. Every path that changes the selection
--- calls this (it refreshes the outline too). The object list goes out separately (pushItems).
local function pushState()
    refreshOutline()

    local sel = selected and items[selected] or nil
    -- Several selected: their rows, in the order they were picked (the primary, `selectedIndex`, last of them).
    local set = pickedNow()
    local rows = nil
    selectedRows = {}
    if set then
        rows = {}
        for _, it in ipairs(set) do
            local i = rowOf(it) --[[@as integer]]   -- pickedNow answers only rows still in `items`
            rows[#rows + 1] = i
            selectedRows[i] = true
        end
    elseif selected then
        selectedRows[selected] = true
    end
    SendNUIMessage({
        action   = 'furnishState',
        -- `house` is the page's name for the title field (html/js/furnisher.js).
        house    = session and session.title or nil,
        count    = #items,
        -- (No limit: the world builder. The page then shows the count alone.)
        max      = session and session.max or nil,
        -- What the markers do: 'move' (arrows) or 'rotate' (rings).
        mode     = mode,
        -- Snap on or off, the step a drag snaps to, and the whole lists.
        snap      = snapOn,
        move      = moveAmount(),
        turn      = turnAmount(),
        moveSteps = moveSteps(),
        turnSteps = turnSteps(),
        moveStep  = moveStep,
        turnStep  = turnStep,
        -- Whether the right button is down: the page stops the pointer doing anything while the room
        -- is being turned (the cursor is put away).
        looking  = looking,
        -- (In Dungeon Mode the work is made as it goes: never unsaved.)
        dirty    = dirty and liveOf() == nil,
        -- On a pad: the selection rides the dot (X); the world builder's next A picks a door.
        carrying = carrying ~= nil,
        picking  = FurnishBuilder.picking(),
        selected = sel and {
            model = sel.model,
            x = sel.x, y = sel.y, z = sel.z,
            rx = sel.rx, ry = sel.ry, rz = sel.rz,
        } or nil,
        -- Which row of the object list is selected (nine identical chairs share a model name).
        selectedIndex = selected,
        selectedIndexes = rows,
    })
end

--- The object list, for the panel's Placed tab. Its own message, sent only when the set changes.
local function pushItems()
    local out = {}
    for i = 1, #items do
        -- The world builder's things carry a name and a kind (a property's rows do not).
        local x = items[i].extra
        -- (A Dungeon Mode thing is listed as what it is: `shows`, an NPC, a car or a prop.)
        out[i] = { index = i, model = items[i].model,
                   label = type(x) == 'table' and x.label or nil, kind = type(x) == 'table' and (x.shows or x.kind) or nil,
                   -- (Which Director thing it is. `lore`: an NPC picked as a lore character; `random`: a random vehicle.)
                   id = type(x) == 'table' and x.id or nil, lore = type(x) == 'table' and x.lore or nil,
                   random = type(x) == 'table' and x.random == true or nil }
    end
    SendNUIMessage({ action = 'furnishItems', items = out })
end

-- ---- the camera, for the page's markers ----
-- The page draws the markers, so it needs the camera and field of view (the numbers a click is aimed with, FurnishView).
-- Sent every frame one of them moves, and only while something is selected.

local viewK   = nil            -- { kx, ky } read off the engine (FurnishView.calibrate), or nil
local viewKAt = -math.huge     -- when the engine was last asked
local VIEW_CALIBRATE_MS = 500
local lastCam = nil            -- the camera last frame { x, y, z, pitch, yaw }, to tell it is still
local sentView = nil           -- what the page was last sent (its numbers, `n` of them), or nil while it has no markers up
local viewNow = {}             -- this frame's numbers, written over each frame (pushView: nothing made to compare them)

local function near(a, b) return math.abs(a - b) < 1e-4 end

--- Has anything in `viewNow`'s first `n` moved since the page was last sent them?
local function viewMoved(n)
    local s = sentView
    if not s or s.n ~= n then return true end
    for i = 1, n do
        if not near(viewNow[i], s[i]) then return true end
    end
    return false
end

--- `viewNow`'s first `n`, as sent.
local function keepView(n)
    local s = sentView or {}
    for i = 1, n do s[i] = viewNow[i] end
    s.n = n
    sentView = s
end

--- How wide and tall the view is: the engine's answer once asked (client/furnish_view.lua), the camera's FOV until then.
local function viewKs()
    if viewK then return viewK[1], viewK[2] end
    local cam = FreeCam.getCam()
    return FurnishView.kFromFov(cam and GetCamFov(cam) or 60.0, GetAspectRatio(false))
end

--- The camera, and the ray into the room through a point on the screen (0-1 across and down).
---@return vector3 from, number dx, number dy, number dz
local function aimAt(nx, ny)
    local from = FreeCam.getCoord()
    local rot = FreeCam.getRot()
    local kx, ky = viewKs()
    local dx, dy, dz = FurnishView.rayAt(nx, ny, rot.x, rot.z, kx, ky)
    return from, dx, dy, dz
end

--- Several selected, to the markers: their middle (of those that move), the ones that move, and every one's place
--- round the middle for the shape the page draws through them. `fixed` when none moves.
local function groupOf(set)
    local movers, sx, sy, sz = {}, 0.0, 0.0, 0.0
    for _, it in ipairs(set) do
        if not it.door and not it.playing then
            movers[#movers + 1] = it
            sx, sy, sz = sx + it.x, sy + it.y, sz + it.z
        end
    end
    local g = { movers = movers, fixed = #movers == 0 }
    local from = g.fixed and set or movers
    if g.fixed then
        for _, it in ipairs(set) do sx, sy, sz = sx + it.x, sy + it.y, sz + it.z end
    end
    g.x, g.y, g.z = sx / #from, sy / #from, sz / #from
    local round = {}
    for _, it in ipairs(set) do
        round[#round + 1] = { it.x, it.y, it.z, math.atan(it.y - g.y, it.x - g.x) }
    end
    table.sort(round, function(a, b) return a[4] < b[4] end)
    for _, p in ipairs(round) do p[4] = nil end
    g.shape = round
    return g
end

--- The camera and the selection, to the page when either has moved. Called every frame from the mode thread.
local function pushView()
    local c, rot = FreeCam.getCoord(), FreeCam.getRot()
    local now = GetGameTimer()

    -- Asked of the engine only while the camera holds still: it projects with the last drawn frame.
    local still = lastCam ~= nil and near(lastCam[1], c.x) and near(lastCam[2], c.y)
        and near(lastCam[3], c.z) and near(lastCam[4], rot.x) and near(lastCam[5], rot.z)
    local lc = lastCam or {}
    lc[1], lc[2], lc[3], lc[4], lc[5] = c.x, c.y, c.z, rot.x, rot.z
    lastCam = lc
    if still and now - viewKAt >= VIEW_CALIBRATE_MS then
        viewKAt = now
        local kx, ky = FurnishView.calibrate(c.x, c.y, c.z, rot.x, rot.z, GetScreenCoordFromWorldCoord)
        if kx and ky then viewK = { kx, ky } end
    end

    local it = selected and items[selected]
    if not it then
        if sentView then
            sentView = nil
            SendNUIMessage({ action = 'furnishView', o = false })
        end
        return
    end

    local kx, ky = viewKs()

    -- Several selected: the markers in their middle, turning by heading alone, and `g` the shape through them.
    local set = pickedNow()
    if set then
        -- (Nothing moved since the last send: no group worked out, nothing sent.)
        local v = viewNow
        v[1], v[2], v[3], v[4], v[5], v[6], v[7] = c.x, c.y, c.z, rot.x, rot.z, kx, ky
        v[8], v[9], v[10], v[11] = groupTurn, blocked and 1 or 0, selected, #set
        local n = 11
        for _, m in ipairs(set) do
            v[n + 1], v[n + 2], v[n + 3], v[n + 4] = m.x, m.y, m.z, (m.door or m.playing) and 1 or 0
            n = n + 4
        end
        if not viewMoved(n) then return end
        keepView(n)
        local g = groupOf(set)
        SendNUIMessage({
            action = 'furnishView',
            c = { c.x, c.y, c.z },
            r = { rot.x, rot.z },
            k = { kx, ky },
            o = { g.x, g.y, g.z, 0.0, 0.0, groupTurn },
            i = selected,
            b = blocked,
            t = false,
            h = 0.0,
            n = g.fixed,
            g = g.shape,
        })
        return
    end

    -- `t`: may it tilt (a prop); other kinds turn by heading alone (one ring).
    local tilt = KINDS[kindOf(it)].tilt == true
    -- `h`: how far its top is over its origin, so the page's bubble sits clear of it and of what is drawn over it.
    local h = it.dims and it.dims.mx.z or 0.0
    local over = FurnishBuilder.topOf(it)
    if over and over > h then h = over end
    -- `n`: no markers (a picked door cannot be moved). Its place still goes, so the bubble stands by it.
    local fixed = it.door == true
    local x, y, z, rx, ry, rz = it.x, it.y, it.z, it.rx or 0.0, it.ry or 0.0, it.rz or 0.0
    -- One the Director's preview is playing (client/director_preview.lua): the bubble follows it, no markers.
    if it.playing and it.obj and DoesEntityExist(it.obj) then
        local p, r = GetEntityCoords(it.obj), GetEntityRotation(it.obj, 2)
        x, y, z, rx, ry, rz = p.x, p.y, p.z, r.x, r.y, r.z
        fixed = true
    end
    local v = viewNow
    v[1], v[2], v[3], v[4], v[5], v[6], v[7] = c.x, c.y, c.z, rot.x, rot.z, kx, ky
    v[8], v[9], v[10], v[11], v[12], v[13] = x, y, z, rx, ry, rz
    v[14], v[15], v[16], v[17], v[18] = blocked and 1 or 0, selected, tilt and 1 or 0, h, fixed and 1 or 0
    if not viewMoved(18) then return end
    keepView(18)
    SendNUIMessage({
        action = 'furnishView',
        c = { c.x, c.y, c.z },
        r = { rot.x, rot.z },
        k = { kx, ky },
        o = { x, y, z, rx, ry, rz },
        i = selected,
        b = blocked,
        t = tilt,
        h = h,
        n = fixed,
    })
end

--- Right mouse went down or came up. The cursor is put away while the room turns; dropping only the cursor keeps
--- the page focused. Called only on a transition.
local function setLooking(on)
    if looking == on then return end
    looking = on
    Focus.mouseLook('furnish', on)   -- the cursor goes while the room turns (client/focus.lua: Enhanced differs)
    FreeCam.setInputEnabled(on)
    pushState()
end

-- ---- Enter / exit ----

local function exitFurnish(quiet)
    if not FurnishModeActive then return end

    -- The flag drops first: FreeCam.stop waits up to two seconds, and the mode thread would send a deleted selection.
    FurnishModeActive = false
    ControlBlocks.release(KEYS_BLOCK)

    -- Read before the state is torn down, so the goodbye can say what happened to it.
    local lost = dirty and liveOf() == nil

    -- The marks come off before the entity goes (the engine may reissue the handle).
    selected, hoverEnt = nil, nil
    picked, selectedRows = {}, {}
    Highlight.set('furnish', nil)

    -- The previewed prompts and the preview go with the things they stood for.
    FurnishBuilder.stop()

    despawnWorking()
    items, unloadable = {}, {}
    selected = nil
    dirty = false
    quitArmedAt = nil
    typing, paused = false, false
    looking = false
    overUi, uiPress = false, false
    blocked = false
    sentView, lastCam = nil, nil
    padOn, padMenu, carrying, padTrigWas = false, false, nil, false
    holdPadButtons(false)   -- ☰ is the pause menu's again

    -- The focus goes back unconditionally, not through setLooking. Its own hold only (client/focus.lua).
    Focus.release('furnish')
    SendNUIMessage({ action = 'furnishClose' })

    -- Taken before the wait below: the editor can be reopened inside it.
    local closing = session
    session = nil
    propertyId = nil
    baseVersion = nil
    -- A property's lock goes: every way out of the editor comes through here.
    if closing and closing.release then closing.release() end

    FreeCam.stop({ movePed = false })

    -- The stream takes its room back, and with it the collision the working copies never had.
    if closing and closing.resume then closing.resume() end

    if not quiet then
        local noun = closing and closing.noun or 'Furnishing'
        if lost then
            UI.Notify(noun .. ' closed — unsaved changes were discarded', 'error', 6000)
        else
            UI.Notify(noun .. ' closed', 'info')
        end
    end
end

--- Open the furnisher on a property. Blocks while the room's rows are fetched; call from a thread.
---@param p table  a property, as client/properties.lua holds it
local function enterFurnish(p)
    if FurnishModeActive then return end
    if not p then return end

    -- One furnisher per property: the server's lock first. Someone else in it: refused, with who.
    local lock, gateWhy = Callback('whip_core:property:furnishLock', p.id)
    if type(lock) ~= 'table' or lock.ok ~= true then
        -- No answer may still have taken it (a timeout): given back, which is nothing if it did not.
        if type(lock) ~= 'table' then TriggerServerEvent('whip_core:server:propertyFurnishClosed', p.id) end
        UI.Notify(type(lock) == 'table' and lock.why or ('Could not open the furnisher: ' .. tostring(gateWhy or 'no answer')),
            'error', 6000)
        return
    end

    propertyId = p.id

    -- The rows come before the pause, from the server with the room's version. No answer: do not open, or the
    -- first Save would delete the real furniture.
    local rows, version, why = GetPropertyFurnitureRows(propertyId, true)
    if not rows then
        TriggerServerEvent('whip_core:server:propertyFurnishClosed', propertyId)   -- not opened: its lock goes
        propertyId = nil
        -- The server's reason when it refused (a try again would not help); "try again" only when it did not answer
        UI.Notify(why or 'Could not load this room\'s furniture — try again in a moment', 'error', 6000)
        return
    end
    baseVersion = version

    -- The streamed copies go first, or every chair is on screen twice.
    PropertyPauseFurniture(propertyId)

    -- `pedFollows = false` and the leash: the player stays put and the camera stays around the property. A ped that
    -- followed the camera could be flown into a locked interior.
    local id, shapes = p.id, p._shapes
    local a = p.anchor or { x = p.x, y = p.y, z = p.z, r = 10.0 }
    session = {
        title       = p.name or ('Property #' .. tostring(p.id)),
        max         = p.maxObjects or Config.PropertyMaxObjects or 150,
        mayBeAt     = function(x, y, z) return shapes ~= nil and Shapes.containsAny(shapes, x, y, z, SPACE_SLACK) end,
        refusedPick = 'Look at a spot inside the property, then pick it again',
        refusedMove = 'That would put it outside the property',
        leash       = { x = a.x, y = a.y, z = a.z, radius = (a.r or 10.0) + 5.0 },
        save        = function(payload)
            TriggerServerEvent('whip_core:server:propertyObjectsSave', id, payload, baseVersion or 0)
        end,
        release     = function() TriggerServerEvent('whip_core:server:propertyFurnishClosed', id) end,
        resume      = function() PropertyResumeFurniture(id) end,
        noun        = 'Furnishing',
    }
    beginSession(rows)
end

--- Open the editor on the session just set (`session`) with its rows: working copies made, state fresh, camera off the player.
---@param rows table  { { model, x, y, z, rx, ry, rz, ... }, ... }
beginSession = function(rows)
    items, unloadable = {}, {}
    for _, row in ipairs(rows) do
        local it = {
            model = row.model,
            x = row.x, y = row.y, z = row.z,
            rx = row.rx or 0.0, ry = row.ry or 0.0, rz = row.rz or 0.0,
        }
        -- What the world builder keeps with each thing (which of the scenario's it is), untouched here.
        if row.extra ~= nil then it.extra = row.extra end
        it.obj = spawnWorking(it)
        -- A model that will not load here is kept out of the editable set but not dropped: Save sends the whole list.
        if it.obj or it.mark then
            items[#items + 1] = it
        else
            unloadable[#unloadable + 1] = it
        end
    end
    if #unloadable > 0 then
        UI.Notify(('%d item(s) could not be loaded here and will be kept exactly as they are'):format(#unloadable),
            'warning', 6000)
    end

    selected, picked, groupTurn = nil, {}, 0.0
    FurnishBuilder.reset()   -- (no door pick waiting, nothing to adopt)
    mode, snapOn, moveStep, turnStep = 'move', false, 1, 1
    lastRz = 0.0
    blocked = false
    quitArmedAt = nil
    typing, paused = false, false
    looking = false
    overUi, uiPress = false, false
    -- (The page says again whether a pad drives it, as it opens.)
    padOn, padMenu, carrying, padTrigWas = false, false, nil, false
    holdPadButtons(false)
    -- The page has no markers up yet, and the camera about to be made is not the last session's.
    sentView, lastCam = nil, nil
    viewK, viewKAt = nil, -math.huge

    FurnishModeActive = true
    ControlBlocks.hold(KEYS_BLOCK, keysSpec())
    startModeLoop()
    -- The wheel as noclip has it (plain zooms, Shift+wheel the fly speed), heard only while the right button is
    -- held; released, it scrolls the catalog. A session with its own camera starts there.
    ---@cast session -nil   -- set by the caller just before (enterFurnish, Furnisher.open)
    local cam = session.camera
    FreeCam.start({
        scroll     = 'fov',
        pedFollows = false,
        leash      = session.leash,
        coords     = cam and cam.pos or nil,
        rot        = cam and cam.rot or nil,
        fov        = cam and tonumber(cam.fov) or nil,
    })
    -- Deaf until the right button is held. FreeCam.start turns listening on, so this comes after it.
    FreeCam.setInputEnabled(false)

    -- Focus for the whole session, cursor and all, with KeepInput (client/focus.lua).
    Focus.take('furnish', { keepInput = true, screen = true })

    -- Whether this build has outlines (client/highlight.lua: corners stand in where it has not).
    outlineOk = Highlight.outlines()
    hoverEnt = nil
    if not outlineOk then
        print('[whip_core:furnish] SetEntityDrawOutline is not available on this build: '
            .. 'the furnisher marks the selected object with corners instead')
    end

    -- `builder`: the world builder's page options (its tabs, Done for Save); a property's room has none.
    SendNUIMessage({ action = 'furnishOpen', builder = session.page })
    SendNUIMessage({ action = 'furnishCatalog', catalog = shownCatalog() })
    pushItems()
    pushState()
end

--- Which property may this player furnish from where they are standing?
--- Ownership or the dev ace, as the server enforces on save. The property is the one named, or the one the player is
--- in; either way they must be within its sphere plus a doorstep.
---@param id number|nil
---@return table|nil property, string|nil why
local function furnishable(id)
    local p
    if id then
        p = GetPropertyDefs and GetPropertyDefs()[id]
    else
        p = GetCurrentProperty and GetCurrentProperty()
    end
    if not p then return nil, 'You are not at a property' end

    local a = p.anchor
    if a then
        local c = GetEntityCoords(PlayerPedId())
        local reach = (a.r or 0) + 10.0
        local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
        if dx * dx + dy * dy + dz * dz > reach * reach then return nil, 'You are not at that property' end
    end
    if p.active == false then return nil, 'This property is closed right now' end
    if not p._shapes or #p._shapes == 0 then
        return nil, 'This property\'s space is not set up yet'
    end

    local me = PlayerData and PlayerData.charId
    if p.ownerCharId and me and p.ownerCharId == me then return p end
    -- Not a security check: the server re-decides on save. This only avoids an editor whose Save is refused.
    if devAllowed() then return p end

    return nil, 'That is not your property'
end

-- ---- Placing ----

--- Where a newly picked prop starts: the surface in the middle of the view.
--- The world and glass are asked (1+16+64 = 81; not cars or people), and so are the tops of what is already placed,
--- which the ray cannot see. With nothing within reach it goes three metres ahead, dropped onto what is under that.
---@return vector3
local function spotAhead()
    local from = FreeCam.getCoord()
    local f = FreeCam.forward()
    local reach = Config.FurnishPlaceRange or 8.0
    local to = from + f * reach

    local ray = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 81, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    local tWorld = isHit(hit) and (#(coords - from) / reach) or nil
    local _, tTop = firstItemHit(from, to, true)
    if tTop and (not tWorld or tTop < tWorld) then return from + (to - from) * tTop end
    if tWorld then return coords end

    local p = from + f * 3.0
    local down = StartShapeTestRay(p.x, p.y, p.z, p.x, p.y, p.z - 10.0, 1 + 16, PlayerPedId(), 0)
    local _, dHit, dCoords = GetShapeTestResult(down)
    if isHit(dHit) then return dCoords end
    return p
end

--- A prop picked from the catalog: into the room at once, selected, with the markers on it. Answers whether it is.
---@param extra table|nil  the world builder's record of the thing (its kind)
---@param opts table|nil  { carry = true: arrives in hand until a left click puts it down (Esc takes it back);
---                       quiet = true: a failure is the caller's to say; turn = { x, y, z }: how it is turned }
---@return boolean placed
local function placeNew(model, extra, opts)
    opts = type(opts) == 'table' and opts or {}
    local max = session and session.max   -- nil: no limit (the world builder)
    if max and #items >= max then
        UI.Notify(('This property is full — %d objects is the limit'):format(max), 'error')
        return false
    end

    -- The world builder's kind (a prop unless it says): a marker needs no model; a door is picked off the world,
    -- never put down (client/furnish_builder.lua).
    local kind = type(extra) == 'table' and KINDS[extra.kind] and extra.kind or 'prop'
    local K = KINDS[kind]
    if K.door then return false end
    local pool = kind == 'vehicle' and type(extra) == 'table' and extra.random == true
    local hasModel = type(model) == 'string' and model ~= '' and model ~= kind
    local hash, minZ = nil, 0.0
    if hasModel then
        hash = GetHashKey(model)
        if not IsModelInCdimage(hash) or not loadModel(hash) then
            if not opts.quiet then UI.Notify(K.noLoad or 'That prop will not load', 'error') end
            return false
        end
        -- Pivot-space offset as placing.lua computes: -minDim.z puts the model's base on the surface.
        local minDim = GetModelDimensions(hash)
        minZ = minDim and minDim.z or 0.0
    elseif not K.mark and not pool then
        return false
    end
    local spot = spotAhead()
    local x, y, z = spot.x, spot.y, spot.z - minZ + (hash and 0.0 or (K.lift or 0.0))

    -- Outside the space is refused here, not at Save.
    if not insideSpace(x, y, z) then
        if hash then SetModelAsNoLongerNeeded(hash) end
        UI.Notify(session and session.refusedPick or 'That cannot go there', 'error')
        return false
    end

    -- The heading of the last one placed or turned (a copy: as the one it copies).
    local turn = type(opts.turn) == 'table' and opts.turn or {}
    local it = { model = hasModel and model or '', x = x, y = y, z = z, rx = tonumber(turn.x) or 0.0, ry = tonumber(turn.y) or 0.0,
                 rz = tonumber(turn.z) or lastRz, extra = extra }
    it.obj = spawnWorking(it)
    if not it.obj and not it.mark then
        if not opts.quiet then UI.Notify('Could not place that', 'error') end
        return false
    end

    -- `fresh`: not put down yet (Esc takes a carry back out).
    it.fresh = opts.carry == true or nil
    items[#items + 1] = it
    -- Selected, so the markers are on it. On a pad it arrives carried: it rides the dot until A puts it down.
    selected = #items
    carrying = padOn and { index = selected } or nil
    dirty, edits = true, edits + 1
    pushItems()
    pushState()
    FurnishBuilder.placed(it, selected)   -- (the Director's builder: the scenario has it at once, for every card's picker)
    -- With the mouse a pick is in hand: it rides the pointer until a left click puts it down.
    if opts.carry and not padOn then SendNUIMessage({ action = 'furnishCarry', i = selected, fresh = true }) end
    return true
end

-- ---- Editing the selection ----

local function applyItem(it)
    -- (A marker is drawn where it is every frame; a door is the world's, never moved.)
    if not it or it.door or not it.obj or not DoesEntityExist(it.obj) then return end
    -- A Dungeon Mode thing is moved on the game that holds it, and the server told once it stops.
    if it.world then liveCall('move', it) return end
    SetEntityCoordsNoOffset(it.obj, it.x, it.y, it.z, false, false, false)
    SetEntityRotation(it.obj, it.rx, it.ry, it.rz, 2, true)
    -- Dragged through a wall into another room: filed there. Not a lamp (stays in limbo) nor a ped or car.
    if KINDS[kindOf(it)].make == 'object' and InteriorRooms.fileByRoom(isLightModel(it.model)) then
        local key = InteriorRooms.keyAt(it.obj)
        if key and not InteriorRooms.sameKey(key, it.room) then it.room = InteriorRooms.put(it.obj) or it.room end
    end
end

local function applySelected() applyItem(selected and items[selected]) end

--- A move or a turn from the page's markers, one per frame of a drag. Whether it is allowed (inside the property's
--- space) is decided here: a refused move leaves the object where it last was allowed and marks `blocked`.
--- Addressed by the index the drag started on, so a selection changed mid-drag moves nothing else.
local BLOCKED_TELL_MS = 2000

local function sayBlocked()
    blocked = true
    local now = GetGameTimer()
    if now - blockedToldAt >= BLOCKED_TELL_MS then
        blockedToldAt = now
        UI.Notify(session and session.refusedMove or 'That cannot go there', 'error', 1500)
    end
end

--- Several selected, moved together: each `by` the same, or none of them when one would leave the space. `turn`:
--- degrees round their middle (`g`, groupOf), each turned by it too.
local function moveGroup(g, by, turn)
    local c, s = 1.0, 0.0
    if turn then c, s = math.cos(math.rad(turn)), math.sin(math.rad(turn)) end
    local to = {}
    for n, it in ipairs(g.movers) do
        local ox, oy = it.x - g.x, it.y - g.y
        local x, y, z = g.x + ox * c - oy * s, g.y + ox * s + oy * c, it.z
        if by then x, y, z = x + by[1], y + by[2], z + by[3] end
        if not insideSpace(x, y, z) then sayBlocked() return end
        to[n] = { x, y, z }
    end
    blocked = false
    for n, it in ipairs(g.movers) do
        it.x, it.y, it.z = to[n][1], to[n][2], to[n][3]
        if turn then it.rz = ((it.rz or 0.0) + turn) % 360.0 end
        applyItem(it)
        FurnishBuilder.moved(it)
    end
    dirty, edits = true, edits + 1
end

local function moveSelected(data)
    local it = selected and items[selected]
    if not it or tonumber(data.i) ~= selected then return end
    -- Several: the markers are their middle's, so a place is where the middle goes and a heading is the group's ring.
    local set = pickedNow()
    if set then
        local g = groupOf(set)
        if g.fixed then return end
        local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
        if x and y and z then moveGroup(g, { x - g.x, y - g.y, z - g.z }) end
        local rz = tonumber(data.rz)
        if rz then
            local turn = (rz - groupTurn + 180.0) % 360.0 - 180.0
            groupTurn = rz % 360.0
            moveGroup(g, nil, turn)
        end
        return
    end
    if it.door then return end   -- the world's own door: picked, not moved

    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if x and y and z then
        if insideSpace(x, y, z) then
            it.x, it.y, it.z = x, y, z
            blocked = false
        else
            sayBlocked()
        end
    end
    -- Only a prop tilts: the world builder's other kinds stand upright, turning by heading alone.
    if KINDS[kindOf(it)].tilt then
        if tonumber(data.rx) then it.rx = tonumber(data.rx) % 360.0 end
        if tonumber(data.ry) then it.ry = tonumber(data.ry) % 360.0 end
    end
    if tonumber(data.rz) then
        it.rz = tonumber(data.rz) % 360.0
        lastRz = it.rz
    end

    dirty, edits = true, edits + 1
    applySelected()
    FurnishBuilder.moved(it)   -- (a Director's point: its page hears where, once it stops)
end

--- The centre dot, dragged: the thing follows the pointer, its base on whatever the camera ray meets (floor, road,
--- a placed table top). A steep face is not stood on: the thing goes in front of it and drops to the floor below.
--- Sky or nothing in reach leaves it. The rest is moveSelected's: inside the space or refused, snapping to the step.
local DRAG_REACH = 300.0
local DROP_REACH = 50.0

--- The base of a thing on the floor at z: a model by its lowest point, a marker by its kind's height.
local function liftOf(it)
    local K = KINDS[kindOf(it)]
    return it.mark and (K.lift or 0.0) or (it.dims and -it.dims.mn.z or 0.0)
end

--- Several selected, their middle dragged to `at` (the surface under the pointer): each keeps its place round the
--- middle and stands on the ground there (nothing there: at `at`'s height).
local function dragGroupTo(g, at, snapping)
    local x, y = at.x, at.y
    if snapping then
        local step = moveAmount()
        if step > 0 then x, y = math.floor(x / step + 0.5) * step, math.floor(y / step + 0.5) * step end
    end
    local to = {}
    for n, it in ipairs(g.movers) do
        local px, py = x + (it.x - g.x), y + (it.y - g.y)
        local down = StartShapeTestRay(px, py, at.z + 2.0, px, py, at.z - DROP_REACH, 1 + 16, PlayerPedId(), 0)
        local _, hit, coords = GetShapeTestResult(down)
        local z = (isHit(hit) and coords.z or at.z) + liftOf(it)
        if not insideSpace(px, py, z) then sayBlocked() return end
        to[n] = { px, py, z }
    end
    blocked = false
    for n, it in ipairs(g.movers) do
        it.x, it.y, it.z = to[n][1], to[n][2], to[n][3]
        applyItem(it)
        FurnishBuilder.moved(it)
    end
    dirty, edits = true, edits + 1
end

local function dragSelectedTo(data)
    local it = selected and items[selected]
    if not it or tonumber(data.i) ~= selected then return end
    local set = pickedNow()
    local g = set and groupOf(set) or nil
    if (g and g.fixed) or (not g and it.door) then return end
    local nx, ny = tonumber(data.x), tonumber(data.y)
    if not nx or not ny or nx < 0 or nx > 1 or ny < 0 or ny > 1 then return end

    local from, dx, dy, dz = aimAt(nx, ny)
    local to = vector3(from.x + dx * DRAG_REACH, from.y + dy * DRAG_REACH, from.z + dz * DRAG_REACH)

    -- The world (the working copies have no collision), then the tops of what is placed; the nearer wins.
    -- Several dragged: the world only.
    local ray = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 81, PlayerPedId(), 0)
    local _, hit, coords, normal = GetShapeTestResult(ray)
    local tWorld = isHit(hit) and (#(coords - from) / DRAG_REACH) or nil
    if g then
        if tWorld then dragGroupTo(g, coords, snapOn or data.snap == true) end
        return
    end
    local _, tTop = firstItemHit(from, to, true, selected)
    local at
    if tTop and (not tWorld or tTop < tWorld) then
        at = from + (to - from) * tTop
    elseif tWorld then
        at = coords
        if normal and normal.z < 0.7 then
            -- Steep: out from the face by the thing's footprint, then down to the floor beneath.
            local d = it.dims
            local foot = d and math.max(math.abs(d.mn.x), math.abs(d.mx.x), math.abs(d.mn.y), math.abs(d.mx.y)) or 0.35
            local nl = math.sqrt(normal.x * normal.x + normal.y * normal.y)
            local p = nl > 1e-3 and vector3(coords.x + normal.x / nl * foot, coords.y + normal.y / nl * foot, coords.z) or coords
            local down = StartShapeTestRay(p.x, p.y, p.z + 0.05, p.x, p.y, p.z - DROP_REACH, 1 + 16, PlayerPedId(), 0)
            local _, dHit, dCoords = GetShapeTestResult(down)
            at = isHit(dHit) and dCoords or p
        end
    else
        return
    end

    -- Its base on the surface.
    local lift = liftOf(it)
    local x, y = at.x, at.y
    if snapOn or data.snap == true then
        local step = moveAmount()
        if step > 0 then x, y = math.floor(x / step + 0.5) * step, math.floor(y / step + 0.5) * step end
    end
    moveSelected({ i = selected, x = x, y = y, z = at.z + lift })
end

---@param force boolean|nil  the world builder's Remove, confirmed
---@param index number|nil   which one the confirmation was for
local function deleteSelected(force, index)
    if not selected then return end
    local it = items[selected]
    if not it then return end
    if index ~= nil and index ~= selected then return end
    -- Several: asked first, always (FurnishBuilder.confirmRemoveMany), then all of them go.
    local set = pickedNow()
    if set then
        if not force then FurnishBuilder.confirmRemoveMany(set, selected) return end
        for _, x in ipairs(set) do
            local i = rowOf(x)
            if i then
                if x.obj and not x.door and DoesEntityExist(x.obj) then DeleteEntity(x.obj) end
                table.remove(items, i)
                FurnishBuilder.removed(x)
            end
        end
        selected, picked = nil, {}
        dirty, edits = true, edits + 1
        pushItems()
        pushState()
        return
    end
    -- A thing a card uses: the page asks first, and its Remove comes back forced (client/furnish_builder.lua).
    if not force and FurnishBuilder.confirmRemove(it, selected) then return end
    -- (A picked door leaves the list, the door stays. A Dungeon Mode thing is its maker's to remove: client/director_live.lua.)
    if it.world then liveCall('remove', it)
    elseif it.obj and not it.door and DoesEntityExist(it.obj) then DeleteEntity(it.obj) end
    table.remove(items, selected)
    FurnishBuilder.removed(it)   -- (the world builder's: a route's point renumbers the rest at once)
    -- Every index after this one has just moved, so the object list (addressed by index) is resent.
    selected = nil
    dirty, edits = true, edits + 1
    pushItems()
    pushState()
end

--- A thing just picked, taken back out as if it never was (Esc while it rides the mouse, B on the dot). One a card
--- uses (adopted by this pick) stays where it is.
local function dropFresh(index)
    local it = items[index]
    if not it or index ~= selected then return end
    carrying, blocked = nil, false
    if FurnishBuilder.usedBy(it) then
        it.fresh = nil
        pushState()
        return
    end
    deleteSelected(true, index)
end

--- A fresh pick put down (a left click, A on a pad). In a Dungeon Mode session it is made in the world for real and
--- this copy goes (client/director_live.lua). True when it was theirs.
local function putDownLive(index)
    local it = items[index]
    if not (it and it.fresh and liveOf()) then return false end
    it.fresh = nil
    liveCall('putDown', it)
    if it.obj and DoesEntityExist(it.obj) then DeleteEntity(it.obj) end
    table.remove(items, index)
    if selected == index then selected = nil elseif selected and selected > index then selected = selected - 1 end
    carrying, blocked = nil, false
    pushItems()
    pushState()
    return true
end

--- Select what was clicked in the room, or nothing. The click is a point on the screen (0-1 across and down), aimed
--- with FurnishView and tested against object boxes; the world is asked too, so nothing is picked through a wall.
---@return number|nil index  the thing a click there picks
local function itemAt(nx, ny)
    local from, dx, dy, dz = aimAt(nx, ny)
    local reach = 30.0
    local to = vector3(from.x + dx * reach, from.y + dy * reach, from.z + dz * reach)

    local limit = 1.0
    local ray = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 1, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    if isHit(hit) then limit = #(coords - from) / reach end

    local i, t = firstItemHit(from, to, false)
    -- A previewed prompt's badge is part of its thing: a click on it selects it (nearer wins).
    local bi, bt = FurnishBuilder.badgeAt(from, to)
    if bt and (not t or bt < t) then i, t = bi, bt end
    if i and t <= limit + 0.001 then return i end
    return nil
end

--- May several be selected at once? Only in the world builder, with the mouse.
local function multiOk() return session ~= nil and session.page ~= nil and liveOf() == nil and not padOn end

--- Left Ctrl as the game reads it (INPUT_DUCK), or the page's `ctrl` on a click: either counts. Not on a pad.
local KEY_ADD = 36
local function ctrlHeld()
    return not WhipPadActive and (IsControlPressed(0, KEY_ADD) or IsDisabledControlPressed(0, KEY_ADD))
end

--- Ctrl+click on row `i`: into the selection, or out of it again. The primary is the one added, or the last one left.
local function togglePick(i)
    local it = items[i]
    if not it then return end
    groupTurn = 0.0
    local set = pickedNow()
    if not set then
        local prim = selected and items[selected]
        if not prim then selected = i return end
        if prim == it then selected = nil return end   -- (the only one selected: none now)
        set = { prim }
    end
    for n = 1, #set do
        if set[n] == it then
            table.remove(set, n)
            selected = rowOf(set[#set])
            picked = #set > 1 and set or {}
            return
        end
    end
    set[#set + 1] = it
    picked = set
    selected = i
end

--- One selected on its own (a plain click, a row): the set ends.
local function selectOne(i)
    picked, groupTurn = {}, 0.0
    selected = i
end

local function selectAt(nx, ny, add)
    local i = itemAt(nx, ny)
    if add and multiOk() then
        -- (Ctrl+click on nothing leaves the selection as it is.)
        if i then togglePick(i) end
    else
        selectOne(i)
    end
    pushState()
end

-- ---- under the pointer ----
--
-- What a click there would pick is marked white (refreshOutline). Asked HOVER_MS apart while the pointer or camera
-- moves (HOVER_STILL_MS while both hold still), and not over a panel, while the room turns, a pick is in hand or a
-- field has the keys. On a pad the pointer is the centre dot.
local HOVER_MS, HOVER_STILL_MS = 100, 500
local hoverAt, hoverStillAt, hoverWas = 0, 0, nil
local hoverKeep = {}   -- (hoverWas when set: the one table, written over)

local function hoverFrame()
    local now = GetGameTimer()
    if now < hoverAt then return end
    hoverAt = now + HOVER_MS
    local ent = nil
    local sel = selected and items[selected]
    if not (looking or paused or typing or overUi or carrying or (sel and sel.fresh)) then
        local nx, ny = 0.5, 0.5
        if not (padOn and WhipPadActive) then
            local w, h = GetActiveScreenResolution()
            local cx, cy = GetNuiCursorPosition()
            nx, ny = (w and w > 0 and cx) and cx / w or -1, (h and h > 0 and cy) and cy / h or -1
        end
        local c, r = FreeCam.getCoord(), FreeCam.getRot()
        local w = hoverWas
        local same = w ~= nil and math.abs(w[1] - nx) < 0.0005 and math.abs(w[2] - ny) < 0.0005
            and math.abs(w[3] - c.x) < 0.005 and math.abs(w[4] - c.y) < 0.005 and math.abs(w[5] - c.z) < 0.005
            and math.abs(w[6] - r.x) < 0.05 and math.abs(w[7] - r.z) < 0.05
        if same and now < hoverStillAt then return end
        w = hoverKeep
        w[1], w[2], w[3], w[4], w[5], w[6], w[7] = nx, ny, c.x, c.y, c.z, r.x, r.z
        hoverWas, hoverStillAt = w, now + HOVER_STILL_MS
        if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
            local i = itemAt(nx, ny)
            ent = i and items[i].obj or nil
            if not i and liveOf() then ent = liveCall('hover', aimAt(nx, ny)) end
        end
    else
        hoverWas = nil
    end
    if ent ~= hoverEnt then
        hoverEnt = ent
        refreshOutline()
    end
end

-- ---- On a controller (see `padOn`) ----

--- One frame in the room on a pad: the carried thing rides the dot, and the triggers raise and lower the selection
--- (turn it, while carried). With nothing to hold they are the camera's.
local function padFrame()
    local it = selected and items[selected]
    -- A carried thing that is no longer the selection is carried no more.
    if carrying and (not it or carrying.index ~= selected) then carrying = nil; pushState() end
    local holds = it ~= nil and not it.door
    FreeCam.setPad(true, not holds)
    if not holds then padTrigWas = false return end
    ---@cast it -nil   -- holds says it is there

    local t = WhipPadTrigger('rt') - WhipPadTrigger('lt')
    local dt = GetFrameTime()
    if carrying then
        dragSelectedTo({ i = selected, x = 0.5, y = 0.5 })
        if t ~= 0 then moveSelected({ i = selected, rz = it.rz - t * PAD_TURN * dt }) end
    elseif t ~= 0 then
        moveSelected({ i = selected, x = it.x, y = it.y, z = it.z + t * PAD_RAISE * dt })
    end
    -- The readout catches up once the trigger is let go.
    if t == 0 and padTrigWas then blocked = false; pushState() end
    padTrigWas = t ~= 0
end

--- A D-pad press on the selection: a step along the floor (Move), or a turn (Rotate: left and right the heading,
--- up and down the tilt). Along the floor it goes the camera's way, snapped to the nearer world axis: up is away.
local function padNudge(nav)
    local it = selected and items[selected]
    if carrying or not it or it.door then return end
    local h = nav == 'right' and 1 or nav == 'left' and -1 or 0
    local v = nav == 'up' and 1 or nav == 'down' and -1 or 0
    if mode == 'rotate' then
        local step = turnAmount()
        if h ~= 0 then moveSelected({ i = selected, rz = it.rz - h * step }) end
        if v ~= 0 and KINDS[kindOf(it)].tilt then moveSelected({ i = selected, rx = it.rx + v * step }) end
    else
        local yaw = math.rad(FreeCam.getRot().z)
        local dx = -math.sin(yaw) * v + math.cos(yaw) * h
        local dy = math.cos(yaw) * v + math.sin(yaw) * h
        if math.abs(dx) >= math.abs(dy) then dx, dy = dx > 0 and 1 or -1, 0 else dx, dy = 0, dy > 0 and 1 or -1 end
        local step = moveAmount()
        moveSelected({ i = selected, x = it.x + dx * step, y = it.y + dy * step, z = it.z })
    end
    blocked = false
    pushState()
end

--- A press in the room, from the page (its menu takes its own).
local function padPress(nav)
    local it = selected and items[selected]
    if nav == 'select' then
        if carrying then
            if putDownLive(carrying.index) then return end   -- (a Dungeon Mode pick: made for real)
            carrying = nil; blocked = false; pushState() return
        end
        if FurnishBuilder.click(0.5, 0.5) then return end   -- (the world builder's door pick, at the dot)
        selectAt(0.5, 0.5)
        if not selected and liveOf() then liveCall('click', aimAt(0.5, 0.5)) end
    elseif nav == 'buttonX' then
        if carrying or not it or it.door then return end
        carrying = { index = selected, from = { it.x, it.y, it.z, it.rx, it.ry, it.rz } }
        pushState()
    elseif nav == 'back' then
        if carrying then
            local from, index = carrying.from, carrying.index
            carrying = nil
            blocked = false
            -- `from` is set only on a carry of the selection (buttonX). padFrame drops a stale carry (nothing selected,
            -- or another selection) on its next frame; one that went stale since then is only let go of.
            if from and it and index == selected then
                -- Back where it was picked up.
                it.x, it.y, it.z, it.rx, it.ry, it.rz = from[1], from[2], from[3], from[4], from[5], from[6]
                applySelected()
                pushState()
            elseif from then
                pushState()
            else
                dropFresh(selected)   -- just picked: B takes it back out, as if it never was
            end
            return
        end
        if FurnishBuilder.cancelPick() then pushState() return end   -- (a waiting door pick put away)
        if selected then selected = nil; pushState() end
    elseif nav == 'tabNext' then
        mode = (mode == 'move') and 'rotate' or 'move'
        pushState()
    elseif nav == 'up' or nav == 'down' or nav == 'left' or nav == 'right' then
        padNudge(nav)
    end
end

-- ---- Saving ----

-- Each saved thing carries a tag so the answer can say which new stash is which piece's:
-- [tag] = the item, for the things the last Save sent. Session-only.
local sentTags, nextTag = {}, 0

--- Everything in the room as Save sends it.
local function payloadOf()
    local payload = {}
    sentTags = {}
    local function row(it)
        local tag = nil
        if propertyId then   -- (the world builder's things have no stashes)
            if not it.tag then nextTag = nextTag + 1; it.tag = nextTag end
            tag = it.tag
            sentTags[tag] = it
        end
        return {
            model = it.model,
            x = it.x, y = it.y, z = it.z,
            rx = it.rx, ry = it.ry, rz = it.rz,
            extra = it.extra,
            tag = tag,
        }
    end
    for i = 1, #items do payload[i] = row(items[i]) end
    -- And the rows that never loaded here, exactly as they came (see `unloadable`).
    for _, it in ipairs(unloadable) do payload[#payload + 1] = row(it) end
    return payload
end

--- `auto`: the world builder's timed save (html/js/furnisher.js), not a press of Save.
local function save(auto)
    if not session or not session.save then return end
    local payload = payloadOf()
    savedAt = edits
    session.save(payload, auto == true)
end

--- The server's answer. The editor stays open either way; only a success clears `dirty`.
--- `stashes`, with a success: { { tag, containerId or 0 }, ... }. Each piece learns its stash so the next Save keeps it.
RegisterNetEvent('whip_core:client:propertyFurnishSaved', function(ok, version, stashes)
    if not propertyId then return end   -- (a property's answer: the world builder never asked)
    if ok then
        if edits == savedAt then dirty = false end   -- (a change made while it was saving is still to save)
        baseVersion = tonumber(version) or baseVersion   -- the next Save is over this one
        for _, pair in ipairs(type(stashes) == 'table' and stashes or {}) do
            local it = type(pair) == 'table' and sentTags[pair[1]] or nil
            local id = it and math.tointeger(tonumber(pair[2])) or nil
            if it and id then
                if id > 0 then
                    it.extra = type(it.extra) == 'table' and it.extra or {}
                    it.extra.stash = id
                elseif type(it.extra) == 'table' then
                    it.extra.stash = nil
                    if next(it.extra) == nil then it.extra = nil end
                end
            end
        end
        pushState()
    end
    SendNUIMessage({ action = 'furnishSaved', ok = ok == true })
end)

-- ---- The mode thread: started on entry, ended with the mode ----

local modeLoopRunning = false

--- A selected thing with no entity of its own to mark: a white chevron a metre over its place (see the mode thread).
local function chevron(it)
    if not (it.obj and DoesEntityExist(it.obj)) and not FurnishBuilder.marksSelection(it)
        and not FurnishBuilder.hasPrompt(it) then
        DrawMarker(2, it.x, it.y, it.z + 1.0, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0,
                   0.18, 0.18, 0.18, 255, 255, 255, 220,
                   false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
    end
end

local function modeLoop()
    while true do
        if not FurnishModeActive then
            break
        else
            -- Death and logout end it (character select must not open under the free camera and focus).
            if PlayerIsDead or not PlayerLoaded then
                exitFurnish(true)
            else
                -- The keys read here are held off by the KEYS_BLOCK control block, so they are disabled reads.

                -- ---- right mouse: the camera ----
                -- Outside the typing guard so the camera stays grabbable while the search box has focus. Control 25
                -- is disabled by Freecam (a disabled read); not on a pad, where it is LT. A press that began over a
                -- panel is the panel's until released (furnishOverUi).
                local held = not WhipPadActive and IsDisabledControlPressed(0, KEY_LOOK)
                if not held then uiPress = false
                elseif not looking and overUi then uiPress = true end
                setLooking(held and not uiPress)

                -- ---- a controller, in the room (its menu has the pad otherwise) ----
                -- Menu saves and View exits: the page presses its own buttons (furnishPadButton).
                if padOn and WhipPadActive then
                    if IsDisabledControlJustPressed(0, PAD_SAVE) then
                        SendNUIMessage({ action = 'furnishPadButton', button = 'save' })
                    elseif IsDisabledControlJustPressed(0, PAD_EXIT) then
                        SendNUIMessage({ action = 'furnishPadButton', button = 'exit' })
                    end
                end

                -- The sticks fly the camera, so it listens; the room's work is padFrame's.
                if padOn and not padMenu and WhipPadActive then
                    FreeCam.setInputEnabled(true)
                    padFrame()
                else
                    FreeCam.setPad(false)
                    FreeCam.setInputEnabled(looking)
                end

                -- ---- the selection marker, when it has no entity to mark ----
                -- Things with an entity are marked by client/highlight.lua. One with none wears a white chevron a metre
                -- over its place (over its prompt, if it has one; over each when several are selected).
                local sel = selected and items[selected]
                if sel then
                    local set = pickedNow()
                    if set then
                        for _, it in ipairs(set) do chevron(it) end
                    else
                        chevron(sel)
                    end
                end
                hoverFrame()

                -- ---- the world builder's marker things and prompts (client/furnish_builder.lua) ----
                FurnishBuilder.frame()
                -- (Dungeon Mode's things of the world, where they have gone: client/director_live.lua.)
                if liveOf() then liveCall('frame', items, selected) end

                -- ---- the camera and the selection, for the markers ----
                -- Outside the typing guard (not a key read): the markers follow the camera while the search box has focus.
                pushView()

                -- Every key below is dead while a text field has focus (KeepInput), and on a pad, where these controls
                -- are its buttons. The pad's presses come from the page.
                if not typing and not paused and not WhipPadActive then
                    -- ---- the markers, the step, removing ----
                    if IsDisabledControlJustPressed(0, KEY_MODE) then
                        mode = (mode == 'move') and 'rotate' or 'move'
                        pushState()
                    end
                    if IsDisabledControlJustPressed(0, KEY_SNAP) then
                        cycleSnap()
                        pushState()
                    end
                    if IsDisabledControlJustPressed(0, KEY_DELETE) then
                        deleteSelected()
                    end
                end
            end
            Wait(0)
        end
    end
    modeLoopRunning = false
end

startModeLoop = function()
    if modeLoopRunning then return end
    modeLoopRunning = true
    CreateThread(modeLoop)
end

-- ---- NUI ----

RegisterNUICallback('furnishPick', function(data, cb)
    cb('ok')
    if not FurnishModeActive then return end
    FurnishBuilder.cancelPick()   -- (a pick: a waiting door pick is not what the next click means)
    -- One still in hand, never put down: this pick takes its place.
    local swap = type(data) == 'table' and tonumber(data.replace) or nil
    if swap and swap == selected and items[swap] and items[swap].fresh then dropFresh(swap) end
    -- A caller's session picks by kind (NPC, car, spot, door) and by name (client/furnish_builder.lua).
    if session and session.page then
        FurnishBuilder.pick(data)
        return
    end
    -- A property's room places only what the catalog offers, never a model by name.
    local model = data and data.model
    if type(model) ~= 'string' or model == '' or data.byName == true then return end
    placeNew(model, nil, { carry = true })
end)

--- A left click on the room (not on a marker — the page keeps those): select what is under it.
RegisterNUICallback('furnishClick', function(data, cb)
    cb('ok')
    if not FurnishModeActive or looking or type(data) ~= 'table' then return end
    local nx, ny = tonumber(data.x), tonumber(data.y)
    if not nx or not ny or nx < 0 or nx > 1 or ny < 0 or ny > 1 then return end
    -- (Dungeon Mode's options are open: a click elsewhere puts them away.)
    if paused then liveCall('away') return end
    -- (The world builder's More > Door: this click picks the door under the pointer.)
    if FurnishBuilder.click(nx, ny) then return end
    -- Ctrl held: adds to the selection, or takes away.
    selectAt(nx, ny, data.ctrl == true or ctrlHeld())
    -- (In Dungeon Mode, a click on nothing of the builder's is on the world's thing there.)
    if not selected and liveOf() then liveCall('click', aimAt(nx, ny)) end
end)

--- One frame of a drag on a marker: { i, x, y, z } for an arrow, { i, rx | ry | rz } for a ring.
RegisterNUICallback('furnishMove', function(data, cb)
    cb('ok')
    if not FurnishModeActive or type(data) ~= 'table' then return end
    moveSelected(data)
end)

--- One frame of a drag on the centre dot: { i, x, y } the pointer (0-1 across and down), `snap` Shift.
RegisterNUICallback('furnishDragTo', function(data, cb)
    cb('ok')
    if not FurnishModeActive or looking or type(data) ~= 'table' then return end
    dragSelectedTo(data)
end)

--- The drag let go. The readout catches up once.
RegisterNUICallback('furnishMoveEnd', function(_, cb)
    cb('ok')
    if not FurnishModeActive then return end
    blocked = false
    -- (A pick carried on the mouse is put down by this. Dungeon Mode's is made.)
    if selected and putDownLive(selected) then return end
    local it = selected and items[selected]
    if it then it.fresh = nil end
    pushState()
end)

--- Esc while a pick rides the mouse (cancelCarry): it goes, as if never picked.
RegisterNUICallback('furnishCarryCancel', function(data, cb)
    cb('ok')
    local i = FurnishModeActive and type(data) == 'table' and tonumber(data.i) or nil
    if i and i == selected and items[i] and items[i].fresh then dropFresh(i) end
end)

RegisterNUICallback('furnishSave', function(data, cb)
    cb('ok')
    if FurnishModeActive then save(type(data) == 'table' and data.auto == true) end
end)

RegisterNUICallback('furnishExit', function(_, cb)
    cb('ok')
    exitFurnish()
end)

-- One of the session's own buttons (page.actions: a hero shot's "Use this view").
RegisterNUICallback('furnishAction', function(data, cb)
    cb('ok')
    if not FurnishModeActive or not session or not session.onAction then return end
    local id = type(data) == 'table' and data.id or nil
    if type(id) ~= 'string' then return end
    local ok, err = pcall(session.onAction, id)
    if not ok then print('[whip_core:furnish] the session\'s ' .. id .. ' failed: ' .. tostring(err)) end
end)

RegisterNUICallback('furnishDelete', function(data, cb)
    cb('ok')
    -- (`force`: the world builder's warning answered Remove, for `index`.)
    if FurnishModeActive then
        deleteSelected(type(data) == 'table' and data.force == true, type(data) == 'table' and tonumber(data.index) or nil)
    end
end)

--- Select one of the placed objects by its row in the object list (the same selection a click makes).
RegisterNUICallback('furnishSelectIndex', function(data, cb)
    cb('ok')
    if not FurnishModeActive then return end
    FurnishBuilder.cancelPick()   -- (a row picked: a waiting door pick is not what the next click means)

    local i = tonumber(data and data.index)
    -- Validated against the live table: the panel's list is a snapshot.
    if not i or not items[i] then return end

    if (data.ctrl == true or ctrlHeld()) and multiOk() and data.goTo ~= true then togglePick(i) else selectOne(i) end
    pushState()
    -- (`goTo`: a pad's menu selects and goes to it in one ask.)
    if data.goTo == true then FreeCam.frame(items[i].x, items[i].y, items[i].z, 3.5) end
end)

--- Put the camera in front of the selected object: it keeps its orientation and moves so the object sits a few
--- metres dead ahead.
RegisterNUICallback('furnishGoTo', function(_, cb)
    cb('ok')
    if not FurnishModeActive then return end
    local it = selected and items[selected]
    if not it then return end
    -- Several: their middle, far enough back for all of them.
    local set = pickedNow()
    if set then
        local g = groupOf(set)
        local far = 0.0
        for _, x in ipairs(set) do far = math.max(far, math.sqrt((x.x - g.x) ^ 2 + (x.y - g.y) ^ 2 + (x.z - g.z) ^ 2)) end
        FreeCam.frame(g.x, g.y, g.z, 3.5 + far * 1.6)
        return
    end
    FreeCam.frame(it.x, it.y, it.z, 3.5)
end)

--- The page's choice of what is selected: these rows, the last the primary. Rows no longer in the set are left out.
RegisterNUICallback('furnishSelectRows', function(data, cb)
    cb('ok')
    if not FurnishModeActive or type(data) ~= 'table' or type(data.rows) ~= 'table' then return end
    local set = {}
    for _, r in ipairs(data.rows) do
        local i = tonumber(r)
        if i and items[i] then set[#set + 1] = items[i] end
    end
    if #set == 0 then return end
    groupTurn = 0.0
    picked = (#set > 1 and multiOk()) and set or {}
    selected = rowOf(set[#set])
    pushState()
end)

--- The world builder's Map window: where each thing in the set is now, and the camera. Read only; asked twice a second.
RegisterNUICallback('furnishWhere', function(_, cb)
    if not FurnishModeActive then cb({ items = {} }) return end
    local out = {}
    for i = 1, #items do
        local it = items[i]
        local x = type(it.extra) == 'table' and it.extra or nil
        out[i] = { index = i, id = x and x.id or nil, kind = kindOf(it), model = it.model,
                   label = x and x.label or nil, x = it.x, y = it.y }
    end
    local c, rot = FreeCam.getCoord(), FreeCam.getRot()
    cb({ items = out, selected = selected,
         cam = c and rot and { x = c.x, y = c.y, heading = rot.z } or nil })
end)

--- A text field in the editor gained or lost focus. With KeepInput every typed letter is also a control press,
--- so the page says true while any text field has focus.
RegisterNUICallback('furnishTyping', function(data, cb)
    cb('ok')
    if not FurnishModeActive then return end
    typing = data and data.on == true
end)

--- The page: the pointer is over one of its panels now, or not. A right press there is the panel's (see `uiPress`).
RegisterNUICallback('furnishOverUi', function(data, cb)
    cb('ok')
    if not FurnishModeActive then return end
    overUi = type(data) == 'table' and data.on == true
end)

--- The page: a pad drives the editor now, or not; and whether its menu has the pad.
--- The mouse picking up mid-carry leaves the thing where it is.
RegisterNUICallback('furnishPad', function(data, cb)
    cb('ok')
    if not FurnishModeActive or type(data) ~= 'table' then return end
    padOn = data.on == true
    padMenu = padOn and data.menu == true
    if not padOn and carrying then carrying = nil; blocked = false end
    if padOn then picked = {} end   -- (a pad works on one at a time: the primary stays selected)
    holdPadButtons(padOn)   -- ☰ Save and ⧉ Exit are the editor's while a pad drives it (PAD_SAVE)
    pushState()
end)

--- A pad press in the room (A, B, X, RB, the D-pad), forwarded by the page: see padPress.
RegisterNUICallback('furnishPadPress', function(data, cb)
    cb('ok')
    if not FurnishModeActive or not padOn or padMenu or type(data) ~= 'table' or type(data.nav) ~= 'string' then return end
    padPress(data.nav)
end)

--- What the markers do: the card's Move / Rotate switch, the same swap R makes.
RegisterNUICallback('furnishSetMode', function(data, cb)
    cb('ok')
    if not FurnishModeActive then return end
    FurnishBuilder.cancelPick()
    local m = data and data.mode
    if m == 'move' or m == 'rotate' then
        mode = m
        pushState()
    end
end)

--- The snap: `cycle` goes round as G does; or the steps by index into the config lists (outside them: ignored).
RegisterNUICallback('furnishSetStep', function(data, cb)
    cb('ok')
    if not FurnishModeActive or type(data) ~= 'table' then return end

    if data.cycle == true then
        cycleSnap()
        pushState()
        return
    end

    local m = tonumber(data.moveStep)
    if m and moveSteps()[m] then moveStep = m end

    local t = tonumber(data.turnStep)
    if t and turnSteps()[t] then turnStep = t end

    pushState()
end)

-- ---- Entry ----

--- Open the furnisher, from a property sign's Furnish option or from /furnish (the property you are in).
--- Global so client/properties.lua's sign can reach it regardless of load order.
---@param id number|nil
function OpenFurnisher(id)
    -- The world builder open (or opening) is the Director's: /furnish does not close it or open over it.
    if (FurnishModeActive or opening) and session and session.page then
        UI.Notify('The world builder is open: Done or Exit there first', 'error')
        return
    end
    if FurnishModeActive then
        exitFurnish()
        return
    end
    -- An in-world property editor (the Configurator) already owns E and the camera ray.
    if PropertyEditorActive then
        UI.Notify('Finish the property editor first', 'error')
        return
    end
    local p, why = furnishable(tonumber(id))
    if not p then
        UI.Notify(why or 'You cannot furnish here', 'error')
        return
    end
    -- In a thread: opening takes round trips for the lock and rows. One open at a time; one that errors gives its lock back.
    if opening then return end
    opening = true
    CreateThread(function()
        local ok, err = pcall(enterFurnish, p)
        opening = false
        if not ok then
            print('[whip_core:furnish] opening failed: ' .. tostring(err))
            if not FurnishModeActive then TriggerServerEvent('whip_core:server:propertyFurnishClosed', p.id) end
        end
    end)
end

-- The server let go of the lock (the holder left, or the property closed or was removed): the editor closes, saying why.
RegisterNetEvent('whip_core:client:propertyFurnishLost', function(id, why)
    if not FurnishModeActive or id ~= propertyId then return end
    local lost = dirty
    exitFurnish(true)
    UI.Notify(('Furnishing closed: %s%s'):format(tostring(why or 'the server closed it'),
        lost and ' — unsaved changes were discarded' or ''), 'error', 8000)
end)

--- Could the player furnish this property from where they are? Asked by the property's sign.
---@param id number
---@return boolean
function CanFurnishProperty(id)
    if FurnishModeActive then return false end
    return furnishable(tonumber(id)) ~= nil
end

RegisterCommand('furnish', function() OpenFurnisher() end, false)

--- Backspace: leave the editor. A key mapping, not a control id (INPUT_CELLPHONE_CANCEL is also the right mouse
--- button). The only reader of this key.
RegisterCommand('whip_furnish_exit', function()
    if not FurnishModeActive then return end
    -- The search box has the keyboard: Backspace there must not also close the editor.
    if typing or paused then return end

    local now = GetGameTimer()
    if not dirty or liveOf() then
        exitFurnish()
    elseif quitArmedAt and (now - quitArmedAt) < QUIT_ARM_MS then
        exitFurnish()
    else
        quitArmedAt = now
        UI.Notify('Unsaved changes — press Backspace again to discard them', 'warning', QUIT_ARM_MS)
    end
end, false)

-- 'BACK' is Backspace. Registered at file scope, so the handler above checks whether the editor is open.
RegisterKeyMapping('whip_furnish_exit', 'Furnisher: Leave Editor', 'keyboard', 'BACK')

-- ---- The world builder (the Director's World tab; a hero shot) ----
-- The same editor on a caller's session with none of a property's rules: anywhere, no limit, no leash. Nothing is
-- saved here: Done hands the whole set back (spec.onDone). What it adds beyond a room is client/furnish_builder.lua's,
-- plugged in at FurnishBuilder.* hook points; its kinds join KINDS.
FurnishBuilder.attach({
    kinds      = KINDS,
    kindOf     = kindOf,
    session    = function() return session end,
    items      = function() return items end,
    unloadable = function() return unloadable end,
    selected   = function() return selected end,
    select     = function(i) selected, picked = i, {} end,
    -- (Is row `i` selected: the one, or one of several.)
    isSelected = function(i) return selectedRows[i] == true end,
    padOn      = function() return padOn end,
    aim        = aimAt,
    isHit      = isHit,
    dimsOf     = dimsOf,
    placeNew   = placeNew,
    -- A row made where it says, the selection left as it is (a point the scenario has that the builder has not).
    addRow     = function(row)
        local it = { model = row.model or '', x = row.x, y = row.y, z = row.z, rx = row.rx or 0.0, ry = row.ry or 0.0,
                     rz = row.rz or 0.0, extra = row.extra }
        it.obj = spawnWorking(it)
        if not it.obj and not it.mark then return false end
        items[#items + 1] = it
        dirty, edits = true, edits + 1
        pushItems()
        pushState()
        return true
    end,
    pushState  = pushState,
    changed    = function() dirty, edits = true, edits + 1; pushItems(); pushState() end,
    -- A copy made again as another model where it stands, its base kept, the set unchanged (a random vehicle going
    -- through its models).
    swapModel  = function(it, model)
        if it.door then return end
        remakeAs(it, model)
    end,
})

Furnisher = {}

--- Open the world builder.
---@param spec table
---   title    the card's name ("World: Bank job")
---   rows     what is placed already: { model, x, y, z, rx, ry, rz, extra = { id, label, kind, ... } }
---   focus    an extra.id to open with selected and the camera framed on it
---   pick     { model, extra }: one not placed yet, put in front of the camera at once, selected
---   adopt    { kind, id, label, ... }: one with nothing to make yet: the next pick of its kind is it
---   page     the page's options (`tabs`, `done`, `byName`, `actions` = { { id, label } }: buttons beside Exit)
---   camera   { pos, rot, fov }: where the free camera starts (default the player); `focus` is not framed then
---   onSpawn  fn(item, entity): a thing was made (a hero shot poses its character)
---   onAction fn(id): one of `page.actions` was pressed
---   onDone   fn(payload): Done was pressed, with the whole set (as Save sends it); it closes after
---   onSave   fn(payload, auto): instead of Done, a Save that stays open; Unsaved until the caller calls
---            Furnisher.markSaved. `auto`: the page's timed save
---   onClose  fn(done): it has closed and the camera is back; done = true after Done
---   live     Dungeon Mode's handlers (client/director_live.lua): putDown(it), click(from, dx, dy, dz),
---            entityOf(it), move(it), remove(it), frame(items, selected) once a frame, away() (Furnisher.pause)
---@return boolean ok
---@return string|nil why
function Furnisher.open(spec)
    if FurnishModeActive or opening then return false, 'The furnisher is already open' end
    if PropertyEditorActive then return false, 'Finish the property editor first' end
    -- Someone else's free camera (noclip): taking it over would run on its settings.
    if FreeCam.isActive and FreeCam.isActive() then return false, 'Another free camera is on (noclip?): turn it off first' end
    if type(spec) ~= 'table' or type(spec.onDone) ~= 'function' then return false, 'no session' end
    local done = false
    session = {
        title  = type(spec.title) == 'string' and spec.title or 'World',
        page   = type(spec.page) == 'table' and spec.page or {},
        noun   = type(spec.noun) == 'string' and spec.noun or 'The world builder',
        camera = type(spec.camera) == 'table' and spec.camera or nil,
        onSpawn = type(spec.onSpawn) == 'function' and spec.onSpawn or nil,
        onAction = type(spec.onAction) == 'function' and spec.onAction or nil,
        live   = type(spec.live) == 'table' and spec.live or nil,
        save   = function(payload, auto)
            if type(spec.onSave) == 'function' then
                -- Saved where it stays open: the caller writes it, and says how it went (Furnisher.markSaved).
                local ok, err = pcall(spec.onSave, payload, auto)
                if not ok then
                    print('[whip_core:furnish] the world builder\'s Save failed: ' .. tostring(err))
                    SendNUIMessage({ action = 'furnishSaved', ok = false })
                end
                return
            end
            ---@cast session -nil   -- save is called only on the open session (save, above)
            session.finish(payload)
        end,
        -- Done: everything handed back (spec.onDone), and it closes. Save is this unless spec.onSave exists;
        -- Furnisher.finish asks for it whatever Save does.
        finish = function(payload)
            done = true
            dirty = false   -- handed back: nothing is lost by closing now
            local ok, err = pcall(spec.onDone, payload)
            if not ok then print('[whip_core:furnish] the world builder\'s Done failed: ' .. tostring(err)) end
            exitFurnish(true)
        end,
        resume = function()
            if spec.onClose then
                local ok, err = pcall(spec.onClose, done)
                if not ok then print('[whip_core:furnish] the world builder\'s close failed: ' .. tostring(err)) end
            end
        end,
    }
    -- While its models load, /furnish or a second open is refused, and a close asked for meanwhile happens once open.
    opening, closeAsked = true, false
    local okOpen, openErr = pcall(beginSession, type(spec.rows) == 'table' and spec.rows or {})
    opening = false
    if not okOpen then
        print('[whip_core:furnish] the world builder could not open: ' .. tostring(openErr))
        if FurnishModeActive then exitFurnish(true) else despawnWorking() session = nil end
        return false, 'The world builder could not open'
    end
    if closeAsked then
        closeAsked = false
        exitFurnish(true)
        return true
    end
    -- One with nothing to make yet: the next pick of its kind is it. A door's pick waits for the click at once.
    if type(spec.adopt) == 'table' then FurnishBuilder.adopt(spec.adopt) end
    -- Opened on one thing: selected, the camera in front of it (unless the session has its own camera). Or one not placed yet: put down now.
    if spec.focus ~= nil then
        for i = 1, #items do
            local x = items[i].extra
            if type(x) == 'table' and x.id == spec.focus then
                selected = i
                if not session.camera then FreeCam.frame(items[i].x, items[i].y, items[i].z, 3.5) end
                pushState()
                break
            end
        end
    end
    if type(spec.pick) == 'table' and type(spec.pick.model) == 'string' then
        placeNew(spec.pick.model, spec.pick.extra, { carry = true })
    end
    return true
end

--- Close the world builder, dropping what it had not handed back. A property's room is not the caller's to close.
function Furnisher.close()
    if not (session and session.page) then return end
    if opening then closeAsked = true return end   -- (still opening: closed the moment it is open)
    if FurnishModeActive then exitFurnish(true) end
end

-- ---- Dungeon Mode's (client/director_live.lua: see liveOf) ----

--- A thing of the world into the builder: `row` { model, x, y, z, rx, ry, rz, extra = { kind = 'live' | 'liveProp',
--- shows, label, ... } }, its entity found by live.entityOf. `select`: select it now. Answers the row, or nil.
function Furnisher.hold(row, select)
    if not (FurnishModeActive and liveOf()) or type(row) ~= 'table' then return nil end
    local it = { model = row.model or '', x = row.x, y = row.y, z = row.z, rx = row.rx or 0.0, ry = row.ry or 0.0,
                 rz = row.rz or 0.0, extra = row.extra }
    it.obj = spawnWorking(it)
    if not it.obj then return nil end
    items[#items + 1] = it
    if select then selected = #items end
    pushItems()
    pushState()
    return it
end

--- Let go of one of the world's things the builder holds, where it is (gone from the world, or a held one done with).
function Furnisher.letGo(it)
    if not FurnishModeActive then return end
    for i = 1, #items do
        if items[i] == it then
            table.remove(items, i)
            if selected == i then selected = nil elseif selected and selected > i then selected = selected - 1 end
            pushItems()
            pushState()
            return
        end
    end
end

--- Select one the builder holds (nil: nothing), and frame it when `look` (Go to).
function Furnisher.select(it, look)
    if not FurnishModeActive then return end
    selected, picked = nil, {}
    for i = 1, #items do
        if items[i] == it then selected = i break end
    end
    if selected and look then FreeCam.frame(it.x, it.y, it.z, 4.0) end
    pushState()
end

--- A screen of the session's over the editor: keys stand down, and a room click is the session's (live.away).
function Furnisher.pause(on)
    paused = FurnishModeActive and on == true or false
end

-- The bubble's Options (Dungeon Mode's): the selection's Object Viewer options.
RegisterNUICallback('furnishLiveOptions', function(data, cb)
    cb('ok')
    local i = FurnishModeActive and type(data) == 'table' and tonumber(data.i) or nil
    if i and items[i] and items[i].world then liveCall('options', items[i]) end
end)

--- The catalog's name for a model, or nil (the world builder names a new thing after it).
function Furnisher.nameOf(model)
    for _, p in ipairs(catalog.props or {}) do
        if p.model == model then return p.name end
    end
    return nil
end

--- Is this model a lamp (the catalog's Lighting)? A lamp in an interior is filed so its light reaches
--- the room (client/interior_rooms.lua).
function Furnisher.isLight(model) return isLightModel(model) end

--- The catalog as the furnisher shows it, for the /whip panel's prop pictures, so a picker offers what spawns.
--- { clusters, categories, props = { { model, name, category, hasImage } } }; empty before it lands.
function Furnisher.catalog() return shownCatalog() end

-- ---- the Director changing its things while the world builder is open ----
-- client/director.lua hands each scenario change here, and the builder's copies follow it.

--- The same table, by what is in it (a prompt, a mark: small tables of words, numbers and lists of words).
local function sameAs(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not sameAs(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- One of the builder's copies made again with another model (a lore character's ped picked), where it stands.
local function remodel(it, model)
    if it.door then return end
    remakeAs(it, model)
    dirty, edits = true, edits + 1
end

--- What else of a thing the Director keeps up to date (client/director.lua extraOf), as sent. One not sent is gone.
local SYNCED = { 'vision', 'loops', 'of', 'n', 'glyph', 'list', 'zone', 'random', 'models', 'lore', 'weapon', 'outfit', 'look' }

--- The scenario's thing `id` as the Director has it now (directorBuilderSync): name, cards that use it, prompt, mark,
--- the synced rest; and its model, made again when it changed. An unchanged prompt or mark keeps its table.
---@param id string
---@param extra table  { label, uses, prompt, mark, vision, loops, of, n, glyph, list } (client/director.lua extraOf)
---@param model string|number|nil
function Furnisher.setExtra(id, extra, model)
    if not (FurnishModeActive and session and session.page) or type(extra) ~= 'table' then return end
    local named, any = false, false
    for i = 1, #items do
        local it = items[i]
        local x = it.extra
        if type(x) == 'table' and x.id == id then
            any = true
            if x.label ~= extra.label then named = true end
            x.label, x.uses = extra.label, extra.uses
            if not sameAs(x.prompt, extra.prompt) then x.prompt = extra.prompt end
            if not sameAs(x.mark, extra.mark) then x.mark = extra.mark end
            -- What other resources keep on it, or an NPC's look or weapon: changed, its copy is made again, dressed
            -- (FurnishBuilder.dress). An outfit change is put on the copy as it is; taken off, the copy is made again.
            local reoutfit = not sameAs(x.outfit, extra.outfit)
            local redress = not sameAs(x.ext, extra.ext) or x.lore ~= extra.lore or x.weapon ~= extra.weapon
                or (reoutfit and extra.outfit == nil) or not sameAs(x.look, extra.look)
            x.ext = extra.ext
            for _, k in ipairs(SYNCED) do x[k] = extra[k] end
            local make = KINDS[kindOf(it)].make
            local remade = false
            if x.random == true then
                -- A random vehicle shows any of its models: made again only when the shown one is no longer among them.
                local among = false
                for _, m in ipairs(type(x.models) == 'table' and x.models or {}) do if m == it.model then among = true end end
                local want = type(model) == 'string' and model or ''
                if not among and want ~= (it.model or '') then
                    remodel(it, want)
                    named, remade = true, true
                end
            elseif type(model) == 'string' and model ~= '' and model ~= it.model and (make == 'ped' or make == 'vehicle' or kindOf(it) == 'prop') then
                remodel(it, model)
                named, remade = true, true
            end
            -- (Nothing in the set changed: no unsaved mark for it.)
            if redress and not remade and not it.door and it.obj and DoesEntityExist(it.obj) then
                DeleteEntity(it.obj)
                it.obj = spawnWorking(it)
            elseif reoutfit and not remade and make == 'ped' and it.obj and DoesEntityExist(it.obj) then
                PedOutfit.apply(it.obj, PedOutfit.read(x.outfit))
            end
        end
    end
    if not any then return end
    if named then pushItems() end
    pushState()
end

--- One the builder placed that the scenario had not got (client/director.lua directorBuilderId): this copy is that thing from now on.
---@param index number  its row in the builder
---@param id string     its id in the scenario
function Furnisher.setId(index, id)
    if not (FurnishModeActive and session and session.page) then return end
    local it = items[index]
    if not it then return end
    if type(it.extra) ~= 'table' then it.extra = { kind = 'prop' } end
    if it.extra.id ~= nil and it.extra.id ~= id then return end   -- (another thing's row by now: not this one's)
    it.extra.id = id
    pushItems()
end

--- The Director's points its scenario no longer has: gone from the builder at once. `keep`: [id] = true for every point it has now.
---@param keep table
function Furnisher.prunePoints(keep)
    if not (FurnishModeActive and session and session.page) or type(keep) ~= 'table' then return end
    local gone = false
    for i = #items, 1, -1 do
        local x = items[i].extra
        if type(x) == 'table' and x.kind == 'point' and type(x.id) == 'string' and not keep[x.id] then
            local it = items[i]
            if it.obj and not it.door and DoesEntityExist(it.obj) then DeleteEntity(it.obj) end
            table.remove(items, i)
            if selected == i then selected = nil elseif selected and selected > i then selected = selected - 1 end
            gone = true
        end
    end
    if gone then
        dirty, edits = true, edits + 1
        pushItems()
        pushState()
    end
end

--- The selection carried on the pointer until a left click puts it down. False with nothing selected.
function Furnisher.carry()
    if not (FurnishModeActive and selected and items[selected]) or items[selected].door then return false end
    SendNUIMessage({ action = 'furnishCarry', i = selected })
    return true
end

--- Done, whatever Save does: everything handed back (spec.onDone), and the world builder closes. False when not open.
function Furnisher.finish()
    if not (FurnishModeActive and session and session.finish) then return false end
    session.finish(payloadOf())
    return true
end

--- How a Save that stays open went: saved, it is not Unsaved any more. The page shows `text` (or Saved / Could not save).
---@param ok boolean
---@param text string|nil
function Furnisher.markSaved(ok, text)
    if not (FurnishModeActive and session) then return end
    if ok and edits == savedAt then   -- (a change made while it was saving is still to save)
        dirty = false
        pushState()
    end
    SendNUIMessage({ action = 'furnishSaved', ok = ok == true, text = type(text) == 'string' and text:sub(1, 120) or nil })
end

-- A restart mid-edit must not orphan props: the working copies are mission entities the game will not clean up.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    despawnWorking()
    -- The NUI goes with the resource but the focus does not: this lets go of the furnisher's own hold (client/focus.lua).
    Focus.release('furnish')
end)
