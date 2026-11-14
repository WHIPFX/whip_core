-- ============================================
-- THE FURNISHER — The world builder's extras
-- What a session of the caller's can do beyond a property's room.
-- ============================================
--
-- One editor, three ways in. A property's sign or /furnish, the Director's World tab and a
-- hero shot all open the same furnisher (client/property_furnish.lua) on a session of their own. A
-- property's room holds props, inside its space. A session opened by Furnisher.open (the Director, a
-- hero shot) has a `page`, and with it what this file adds:
--
--   KINDS        the things it places besides a prop: an NPC, a hero shot's character, a car, a spot,
--                an item spot, a container, a door
--   making them  a ped, a car, the player's own looks; a marker for a kind with no model; a door the
--                world already has, found again
--   the marks    white marks where the marker kinds stand, on doors, and over NPCs, cars and props
--                (none on the selection while it is selected)
--                (client/world_marks.lua), drawn every frame
--   previews     the prompt a run will put on a thing, shown as players will see it
--   doors        More > Door: the next click on the world picks the door under it
--   adopting     opened on one of the scenario's things with nothing to make yet: its first pick is it
--   by name      any model this game has, for one thing, never added to the catalog
--   "in use"     a thing a card uses is warned about before it goes
--
-- Plugged in, not woven in. It loads before the furnisher, which hands it the editor (FurnishBuilder.attach,
-- at the bottom of that file): the working set, the selection and the few helpers below need. The
-- furnisher calls in at its own points (a thing made, a pick, a click, a frame, a removal, a close) and
-- reads only the kind traits it honours itself (see KINDS there).

FurnishBuilder = {}

--- The editor, as the furnisher hands it over (FurnishBuilder.attach):
---   kinds          every kind, the room's own prop among them (this file's join it there)
---   kindOf(it)     a thing's kind ('prop' unless its extra names one of KINDS)
---   session()      the open session, or nil;  items(), unloadable()  the working set and the rows not loaded
---   selected()     the selection's index, or nil;  select(i)  set it (pushState() sends it)
---   padOn()        a controller drives the editor
---   aim(nx, ny)    the camera, and the way into the room through a point on the screen: from, dx, dy, dz
---   isHit(hit)     did a ray hit;  dimsOf(model)  a model's box, for pointing at it
---   placeNew(model, extra, opts)  a pick: into the room in front of the camera, selected (opts.carry: in hand on
---                  the mouse; opts.quiet: no notice when it fails; opts.turn: { x, y, z }), answering whether it is
---   addRow(row)    a row made where it says ({ model, x, y, z, rx, ry, rz, extra }), the selection left alone
---   pushState()    the page's state;  changed()  the set changed (unsaved, the list and the state sent)
---@class FurnishEditor
---@field kinds table<string, table>
---@field kindOf fun(it: table): string
---@field session fun(): table|nil
---@field items fun(): table[]
---@field unloadable fun(): table
---@field selected fun(): integer|nil
---@field select fun(i: integer|nil)
---@field isSelected fun(i: integer): boolean
---@field padOn fun(): boolean
---@field aim fun(nx: number, ny: number): vector3, number, number, number
---@field isHit fun(hit: any): boolean
---@field dimsOf fun(model: any): table|nil
---@field placeNew fun(model: string, extra?: table, opts?: table): boolean
---@field addRow fun(row: table): boolean
---@field pushState fun()
---@field changed fun()
---@field swapModel fun(it: table, model: string)

-- Both set by FurnishBuilder.attach as the furnisher loads, before anything here is called.
---@type FurnishEditor
local ed = nil
---@type table<string, table>
local KINDS = nil   -- ed.kinds

--- The world builder's things are of a KIND (its `extra.kind`): what the room makes for it, and how it
--- turns. The traits the furnisher honours are listed with its KINDS; these two are this file's alone:
---   clone   a ped made as a copy of the player's own (a hero shot's character): their
---           looks, and posed by the session (session.onSpawn)
---   noLoad  (the furnisher's) what a pick says when the model will not load
local BUILDER_KINDS = {
    npc        = { make = 'ped', noLoad = 'That ped will not load' },
    hero       = { make = 'ped', clone = true },
    vehicle    = { make = 'vehicle', noLoad = 'That vehicle will not load' },
    spot       = { mark = true, lift = 0.0 },
    point      = { mark = true, lift = 0.0 },   -- a step of a thing's Tasks, a route's point, a group's spot (FurnishBuilder.frame)
    route      = { mark = true, lift = 0.0 },   -- a path NPCs walk: its points are points
    groundItem = { mark = true, lift = 0.1 },
    container  = { make = 'object', mark = true, lift = 0.0 },
    door       = { door = true },
    -- Dungeon Mode's (client/director_live.lua): a thing of the live world itself, a real NPC, car, prop or player,
    -- found (never made, never deleted here) and moved on the game that holds it. A prop tilts.
    live       = { world = true },
    liveProp   = { world = true, tilt = true },
}

--- The world builder's More > Door was picked: the next click on the world picks a door (pickDoorAt).
local doorPicking = false

--- The world builder's thing waiting for its first pick: opened on one of the
--- scenario's that has nothing to make yet (a door not picked, an NPC or a car with no model), the
--- next pick of its kind — a door clicked, a ped or a car picked — IS that one, with its id, not a new
--- thing. Its `extra`, or nil.
local adoptNext = nil

--- [the scenario's thing id] = true: what a card in the Blueprint window names (the card under the pointer,
--- else the ones picked: html/js/director/app.js builderLit). Lit green: its mark, and its outline where it
--- has one (a prop, a door: the furnisher's refreshOutline).
local lit = {}

--- Is this thing lit by a card in the Blueprint window?
function FurnishBuilder.isLit(it)
    local x = it and it.extra
    return type(x) == 'table' and x.id ~= nil and lit[x.id] == true
end

RegisterNUICallback('furnishHighlight', function(d, cb)
    cb('ok')
    if not ed or not ed.session() then return end
    lit = {}
    for _, id in ipairs(type(d) == 'table' and type(d.ids) == 'table' and d.ids or {}) do
        if type(id) == 'string' and #id <= 64 then lit[id] = true end
    end
    ed.pushState()   -- (the outlines follow: client/property_furnish.lua refreshOutline)
end)

-- ============================================
-- Making them
-- ============================================

--- The door the world has here (a scenario's door, found again by its model and spot), or nil.
local function doorAt(it)
    local model = tonumber(it.model)
    if not model then return nil end
    local ent = GetClosestObjectOfType(it.x, it.y, it.z, 1.0, model, false, false, false)
    return (ent and ent ~= 0) and ent or nil
end

--- A door's box, from its model's hash (a door's model is the game's number, not a name), so a click
--- on it in the room selects it as any working copy's box does.
local function doorDims(hash)
    local mn, mx = GetModelDimensions(hash)
    if not mn or not mx then return nil end
    local ex = math.max(math.abs(mn.x), math.abs(mx.x))
    local ey = math.max(math.abs(mn.y), math.abs(mx.y))
    local ez = math.max(math.abs(mn.z), math.abs(mx.z))
    return { mn = mn, mx = mx, r = math.sqrt(ex * ex + ey * ey + ez * ez) }
end

-- AN NPC'S COPY AS A RUN MAKES IT: the look of the lore character it is, made in the character editor (asked for by
-- key, as client/lore_reactions.lua does for a run's NPC: whip_core:loreLook), else its own outfit (its page's
-- Outfit: client/ped_outfit.lua), and the weapon it carries, in hand.
local loreLooks = {}          -- [key] = { look | false, at } once asked ({ asking = true } while asking)
local LORE_LOOK_FRESH = 30000 -- ms: asked for again after this (a look changed in /whip shows on the next copy)

local function dressNpc(ent, x)
    if type(x) ~= 'table' then return end
    if type(x.weapon) == 'string' and x.weapon ~= '' then
        local hash = GetHashKey(x.weapon)
        if IsWeaponValid(hash) then
            GiveWeaponToPed(ent, hash, 1, false, true)
            SetCurrentPedWeapon(ent, hash, true)
        end
    end
    if x.outfit and not x.lore and not x.look then PedOutfit.apply(ent, PedOutfit.read(x.outfit)) end
    -- Its own look from the character editor (its page's Outfit, a freemode ped), as a run's NPC wears it.
    if type(x.look) == 'table' and not x.lore and ApplyAppearance then
        local look = x.look
        CreateThread(function() if DoesEntityExist(ent) then ApplyAppearance(ent, look) end end)
        return
    end
    local key = x.lore
    if type(key) ~= 'string' or key == '' or not ApplyAppearance then return end
    CreateThread(function()
        local got = loreLooks[key]
        if not got or (not got.asking and GetGameTimer() - (got.at or 0) > LORE_LOOK_FRESH) then
            got = { asking = true }
            loreLooks[key] = got
            local r = Callback('whip_core:loreLook', key)
            got.look = type(r) == 'table' and type(r.look) == 'table' and r.look or false
            got.at, got.asking = GetGameTimer(), nil
        end
        local deadline = GetGameTimer() + 10000
        while got.asking and GetGameTimer() < deadline do Wait(50) end
        -- (A GTA ped of their own has no look: as it is.)
        if got.look and DoesEntityExist(ent) then ApplyAppearance(ent, got.look) end
    end)
end

--- Make one of the builder's things, asked first by the furnisher's spawnWorking: a ped or a car made
--- the way the room makes its copies (frozen, no collision, not networked); a marker kind with no model
--- is `mark` (nothing made: drawn by FurnishBuilder.frame); a door is the world's own, found again
--- (`door`: never deleted). A prop, and a container's prop, are the room's to make.
---@return boolean made  this file dealt with it (the entity may still be nil: it would not load)
---@return number|nil entity
function FurnishBuilder.spawn(it)
    local kind = ed.kindOf(it)
    local K = KINDS[kind]
    if K.world then
        -- The world's own, found by Dungeon Mode's session: its box from its model, for clicking it.
        it.world = true
        local session = ed.session()
        local L = session and session.live
        local ent = L and type(L.entityOf) == 'function' and L.entityOf(it) or nil
        if ent and DoesEntityExist(ent) then
            it.dims = doorDims(GetEntityModel(ent))
            return true, ent
        end
        return true, nil
    end
    if K.door then
        it.door = true
        local ent = doorAt(it)
        if ent then it.dims = doorDims(tonumber(it.model)) end
        return true, ent
    end
    -- (A random vehicle with no models yet is a mark too.)
    local random = kind == 'vehicle' and type(it.extra) == 'table' and it.extra.random == true
    if (K.mark or random) and (type(it.model) ~= 'string' or it.model == '' or it.model == kind) then
        it.mark = true
        it.dims = { mn = vector3(-0.35, -0.35, -0.05), mx = vector3(0.35, 0.35, 0.7), r = 0.8 }
        return true, nil
    end
    if K.make ~= 'ped' and K.make ~= 'vehicle' then return false end
    it.mark = nil   -- (a random vehicle's first model, given since)

    local hash = GetHashKey(it.model)
    if not IsModelInCdimage(hash) or LoadModel(hash) == nil then return true, nil end   -- (client/streaming.lua)
    local ent
    if K.clone then
        -- The player's own looks, made where they stand and put in place below.
        ent = ClonePed(PlayerPedId(), false, false, true)
    elseif K.make == 'ped' then
        ent = CreatePed(4, hash, it.x, it.y, it.z, it.rz or 0.0, false, false)
    else
        ent = CreateVehicle(hash, it.x, it.y, it.z, it.rz or 0.0, false, false)
    end
    SetModelAsNoLongerNeeded(hash)
    if not ent or ent == 0 then return true, nil end
    SetEntityCoordsNoOffset(ent, it.x, it.y, it.z, false, false, false)
    SetEntityHeading(ent, it.rz or 0.0)
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, false, false)
    SetEntityInvincible(ent, true)
    SetEntityAsMissionEntity(ent, true, true)
    -- See-through: the builder's copy, told apart from a switched-on scenario's live NPC or car. Not a
    -- clone: it is the shot as it will look. A car (a Vehicle pool's too) a fifth see-through, no more.
    if not K.clone then SetEntityAlpha(ent, K.make == 'vehicle' and 204 or 200, false) end
    if K.make == 'ped' then SetBlockingOfNonTemporaryEvents(ent, true) end
    if K.make == 'ped' and not K.clone then dressNpc(ent, it.extra) end
    it.dims = ed.dimsOf(it.model)
    -- The session dresses what it asked for (a hero shot poses its character).
    local session = ed.session()
    if session and session.onSpawn then
        local ok, err = pcall(session.onSpawn, it, ent)
        if not ok then print('[whip_core:furnish] onSpawn failed: ' .. tostring(err)) end
    end
    return true, ent
end

--- A copy of one of the Director's things was made (ped, car or prop, from the furnisher's spawnWorking): the
--- resources that keep something on it hear, so it can look as a run makes it (whip_autos: a car's Whiplash look).
--- A local event, whip_core:director:builderCopy { id, kind, model, entity, data = { [resource] = what it keeps } };
--- the copy is this game's own (not networked), made again whenever its model or that data changes.
function FurnishBuilder.dress(it, ent)
    local x = it.extra
    if not ent or ent == 0 or type(x) ~= 'table' or type(x.id) ~= 'string' or type(x.ext) ~= 'table' or not next(x.ext) then return end
    TriggerEvent('whip_core:director:builderCopy', { id = x.id, kind = x.kind, model = it.model, entity = ent, data = x.ext })
end

-- ============================================
-- The prompts a run will put up
-- ============================================
--
-- Anything placed as a 3D interaction point is previewed as one. A thing a run puts a prompt on (a spot pressed to drill a safe, an NPC's Talk, a container's Open)
-- comes with `extra.prompt` from the Director's page (html/js/director/app.js promptOf): its words, its
-- glyph, its reach, a menu's top choices, and where it sits (on the NPC or car itself, or at the spot,
-- lifted as the server lifts it). The builder shows the REAL prompt there: registered with the prompt
-- engine in a group of its own and drawn by its renderer, seen from the camera (Interactions.setPreview),
-- so it looks and behaves as a player will see it: its ring from its own range, the white disc and the
-- words once the camera is close and looking at it. Nothing in it can be used: the builder selects with
-- its own click, on the badge as on the thing. Further off than that range, where the engine draws
-- nothing, a mark stands for it: the prompt's idle ring and its words (client/world_marks.lua).
--
-- Level-triggered, from the mode loop, every frame: what is registered follows the items, however they
-- came and went (picked, re-picked, adopted, removed), and a prompt follows its thing as it is dragged.

local PREVIEW_GROUP = 'furnish_preview'
local PROMPT_NAMED  = 30.0   -- metres: a far prompt's mark says its words within this

--- ['fpreview:<thing id>'] = { x, y, z, seen }: the prompts registered, where they were last put.
local previews   = {}
local previewing = false   -- Interactions.setPreview is set (only while some thing has a prompt)
local previewTurn = 0      -- bumped each pass: a registered prompt not seen in it has lost its thing

local function previewKey(it) return 'fpreview:' .. tostring(it.extra.id) end

--- Does this thing have a prompt to preview? (Its selection is marked over the prompt, here.)
local function hasPrompt(it)
    return type(it.extra) == 'table' and type(it.extra.prompt) == 'table' and it.extra.id ~= nil
end
FurnishBuilder.hasPrompt = hasPrompt

--- Where a thing's prompt is now: riding its NPC or car (lifted above its middle), or at its spot.
local function promptPos(it)
    local p = it.extra.prompt
    local lift = tonumber(p.lift) or 0.0
    if p.ride == 'entity' and it.obj and DoesEntityExist(it.obj) then
        local c = GetEntityCoords(it.obj)
        return c.x, c.y, c.z + lift
    end
    return it.x, it.y, it.z + lift
end

--- The camera, which a preview is seen from.
local function previewFrom()
    local c = FreeCam.getCoord()
    return c.x, c.y, c.z
end

--- Register a thing's prompt with the engine (never usable: every callback is empty).
local function previewRegister(key, it, x, y, z)
    local p = it.extra.prompt
    local options = nil
    if type(p.options) == 'table' and #p.options > 0 then
        options = {}
        for i, label in ipairs(p.options) do options[i] = { id = 'o' .. i, label = label, callback = function() end } end
    end
    Interactions.register({
        id = key, group = PREVIEW_GROUP, x = x, y = y, z = z,
        label = p.label, icon = p.icon, activeRange = tonumber(p.reach), options = options,
        callback = function() end,
    })
end

--- [prompt] = the mark that stands for it far off, kept and refilled frame to frame (client/world_marks.lua).
local promptMarks = setmetatable({}, { __mode = 'k' })

--- A prompt out of its own range, as a mark: its idle ring and its words, and under them the thing's
--- name (an NPC's Talk) or what its own mark would say (a container's slots). Selected, the ring fills
--- with its icon, or the key, as the focused prompt does.
local function promptMark(it, x, y, z, selected)
    local p = it.extra.prompt
    local m = promptMarks[p]
    if not m then
        m = { kind = 'prompt', ground = false, nearText = PROMPT_NAMED }
        promptMarks[p] = m
    end
    local label, mk = it.extra.label, type(it.extra.mark) == 'table' and it.extra.mark or nil
    m.key = p
    m.x, m.y, m.z = x, y, z
    m.name = p.label or 'Use'
    m.detail = (type(label) == 'string' and label ~= m.name) and label or (mk and mk.detail) or nil
    m.glyph = p.icon or 'E'
    m.selected = selected
    m.lit = lit[it.extra.id] == true
    return m
end

--- One pass, from the mode loop: register, move or remove the prompts to match the things, mark the far
--- ones and the selected one, and hold the preview while there is anything to show.
local function previewSync()
    previewTurn = previewTurn + 1
    local any = false
    local cx, cy, cz = previewFrom()
    local seeFrom = Config.InteractVisibleRange or 5.0
    local items, selected = ed.items(), ed.selected()
    for i = 1, #items do
        local it = items[i]
        if hasPrompt(it) then
            any = true
            local key = previewKey(it)
            local x, y, z = promptPos(it)
            local pv = previews[key]
            -- (Its words changed in the Director's page, while the builder is open: put up again.)
            if pv and pv.p ~= it.extra.prompt then
                Interactions.remove(key)
                previews[key] = nil
                pv = nil
            end
            if not pv then
                previewRegister(key, it, x, y, z)
                pv = { x = x, y = y, z = z, p = it.extra.prompt }
                previews[key] = pv
            elseif math.abs(pv.x - x) + math.abs(pv.y - y) + math.abs(pv.z - z) > 0.005 then
                Interactions.updatePosition(key, x, y, z)
                pv.x, pv.y, pv.z = x, y, z
            end
            pv.seen = previewTurn
            local dx, dy, dz = x - cx, y - cy, z - cz
            local far = dx * dx + dy * dy + dz * dz > seeFrom * seeFrom
            -- Out of the prompt's own range: the engine draws nothing, so its mark stands for it. Not while
            -- a thing of its own (an NPC, a car) is selected: the selection and its markers say it then.
            if far and not (i == selected and it.obj) then
                WorldMarks.add(promptMark(it, x, y, z, i == selected))
            end
        end
    end
    for key, pv in pairs(previews) do
        if pv.seen ~= previewTurn then
            Interactions.remove(key)
            previews[key] = nil
        end
    end
    if any ~= previewing then
        previewing = any
        if any then Interactions.setPreview(PREVIEW_GROUP, previewFrom) else Interactions.setPreview(nil) end
    end
end

--- How far over a thing's origin the highest thing drawn for it reaches (its prompt, its mark), in
--- metres, or nil when nothing is drawn over it: the page's bubble keeps clear of it (the furnisher's
--- pushView).
---@return number|nil
function FurnishBuilder.topOf(it)
    if hasPrompt(it) then
        return (tonumber(it.extra.prompt.lift) or 0.0) + 0.3
    end
    -- (A thing of its own wears no mark while it is selected, the only time this is asked: its box is its top.)
    if it.mark then return WorldMarks.GROUND_TOP end
    return nil
end

--- Every prompt off, and the preview with them: every way out of the editor.
local function previewStop()
    for key in pairs(previews) do Interactions.remove(key) end
    previews = {}
    if previewing then
        previewing = false
        Interactions.setPreview(nil)
    end
end

--- Where along the segment (0-1) it first meets a sphere round this thing's prompt, or nil: a click on
--- the badge selects its thing, wherever the badge floats (over a car's roof, above a container).
local function previewHit(it, from, to, radius)
    if not hasPrompt(it) then return nil end
    local pv = previews[previewKey(it)]
    if not pv then return nil end
    local sx, sy, sz = to.x - from.x, to.y - from.y, to.z - from.z
    local ox, oy, oz = from.x - pv.x, from.y - pv.y, from.z - pv.z
    local a = sx * sx + sy * sy + sz * sz
    if a <= 0 then return nil end
    local b = 2 * (ox * sx + oy * sy + oz * sz)
    local c = ox * ox + oy * oy + oz * oz - radius * radius
    local disc = b * b - 4 * a * c
    if disc < 0 then return nil end
    local t = (-b - math.sqrt(disc)) / (2 * a)
    if t < 0 or t > 1 then return nil end
    return t
end

--- The nearest prompt badge the segment meets, for a click on the room (the furnisher's selectAt: a
--- badge is part of its thing, and the nearer of it and a box wins): its thing's index and how far
--- along (0-1), or nil.
---@return number|nil index, number|nil fraction
function FurnishBuilder.badgeAt(from, to)
    local items = ed.items()
    local best, bestT = nil, nil
    for k = 1, #items do
        local t = previewHit(items[k], from, to, 0.3)
        if t and (not bestT or t < bestT) then best, bestT = k, t end
    end
    return best, bestT
end

-- ============================================
-- Every frame
-- ============================================

--- What each kind's mark calls it, when the page sent nothing better.
local MARK_TEXT = { spot = 'Spot', groundItem = 'Item spot', container = 'Container', door = 'Door', npc = 'NPC',
                    hero = 'Character', vehicle = 'Car', prop = 'Prop', point = 'Point', route = 'Route' }

--- [item] = its mark, kept and refilled frame to frame (client/world_marks.lua).
local thingMarks = setmetatable({}, { __mode = 'k' })

--- Where a thing is now, and its heading: where its copy has got to while the Director's preview plays it
--- (client/director_preview.lua), else where it is placed.
local function liveAt(it)
    if it.playing and it.obj and DoesEntityExist(it.obj) then
        local c = GetEntityCoords(it.obj)
        return c.x, c.y, c.z, GetEntityHeading(it.obj)
    end
    return it.x, it.y, it.z, it.rz or 0.0
end

--- A thing's mark, or nil when it wears none: a marker kind stands on its spot with a stem and a ring;
--- a door is marked at its middle; an NPC, a car or a prop over its head, roof or top. A thing of its
--- own in the world (a door, an NPC, a car, a prop) wears none while it is selected: the selection and
--- its markers say it then, and the mark is back when it is let go. A marker kind has nothing else to
--- show it, so it stays, selected. In a property's room a prop wears none: its furniture is the room.
local function thingMark(it, selected)
    local kind = ed.kindOf(it)
    local K = KINDS[kind]
    local m = thingMarks[it]
    if selected and not it.mark then return nil end
    if it.mark then
        m = m or {}
        -- On the floor, not at the lift it is placed at (an item spot sits a hand over it).
        m.x, m.y, m.z = it.x, it.y, it.z - (K.lift or 0.0)
        m.ground = true
    elseif it.door then
        if not it.obj then return nil end
        m = m or {}
        -- The middle of its box, turned with it: GTA's right is (cos, sin), its forward (-sin, cos).
        local d = it.dims
        local lx, ly, lz = 0.0, 0.0, 1.0
        if d then lx, ly, lz = (d.mn.x + d.mx.x) * 0.5, (d.mn.y + d.mx.y) * 0.5, (d.mn.z + d.mx.z) * 0.5 end
        local h = math.rad(it.rz or 0.0)
        local s, c = math.sin(h), math.cos(h)
        m.x, m.y, m.z = it.x + lx * c - ly * s, it.y + lx * s + ly * c, it.z + lz
        m.ground = false
    elseif (K.make == 'ped' or K.make == 'vehicle') and it.obj then
        m = m or {}
        local x, y, z = liveAt(it)
        m.x, m.y, m.z = x, y, z + (it.dims and it.dims.mx.z or 1.0) + WorldMarks.FLOAT_LIFT
        m.ground = false
    elseif kind == 'prop' and it.obj then
        local session = ed.session()
        if not (session and session.page) then return nil end
        m = m or {}
        local x, y, z = liveAt(it)
        m.x, m.y, m.z = x, y, z + (it.dims and it.dims.mx.z or 0.5) + WorldMarks.FLOAT_LIFT
        m.ground = false
    else
        return nil
    end
    thingMarks[it] = m
    local x = type(it.extra) == 'table' and it.extra or {}
    local mk = type(x.mark) == 'table' and x.mark or nil
    m.key = it
    -- (A point is a spot's mark, its number in the disc. A route is a spot's mark.)
    m.kind = kind == 'hero' and 'npc' or (kind == 'point' or kind == 'route') and 'spot' or kind
    m.glyph = kind == 'point' and x.glyph or nil
    m.name = (mk and mk.name) or x.label or MARK_TEXT[kind]
    m.detail = (mk and mk.detail) or MARK_TEXT[kind]
    m.pic = mk and mk.pic or nil
    m.selected = selected
    m.lit = x.id ~= nil and lit[x.id] == true
    return m
end

-- ---- task points: shown with their thing, joined to it in order ----

--- The thing whose points show now: the selected thing, or the thing of the selected point.
local function pointsOwner(items, selected)
    local it = selected and items[selected]
    local x = it and type(it.extra) == 'table' and it.extra or nil
    if not x then return nil end
    if x.kind == 'point' then return x.of end
    return x.id
end

--- The line through a thing's points, in their order, a hand over the ground: from the thing itself for its
--- tasks' points, from point 1 for a route's (a route is its points: it has no thing of its own here), and round
--- to it again for a route that loops.
local LINE = { 255, 255, 255, 200 }
-- (Every frame: one list, emptied and filled again, and one way of sorting it. Nothing made each time.)
local pts = {}
local function byNumber(a, b) return (a.extra.n or 0) < (b.extra.n or 0) end
local function drawPointLine(items, owner)
    local from, n = nil, 0
    for i = 1, #items do
        local x = items[i].extra
        if type(x) == 'table' then
            if x.id == owner and x.kind ~= 'point' then from = items[i] end
            if x.kind == 'point' and x.of == owner then n = n + 1; pts[n] = items[i] end
        end
    end
    for i = #pts, n + 1, -1 do pts[i] = nil end
    if n == 0 then return end
    table.sort(pts, byNumber)
    local isRoute = pts[1].extra.list == 'points'
    local px, py, pz
    if from and not isRoute then
        px, py, pz = liveAt(from)
        pz = pz + 0.05
    end
    for _, p in ipairs(pts) do
        if px then DrawLine(px, py, pz, p.x, p.y, p.z + 0.05, LINE[1], LINE[2], LINE[3], LINE[4]) end
        px, py, pz = p.x, p.y, p.z + 0.05
    end
    if isRoute and pts[1].extra.loops and #pts > 2 then
        local p = pts[1]
        DrawLine(px, py, pz, p.x, p.y, p.z + 0.05, LINE[1], LINE[2], LINE[3], 90)
    end
end

--- A selected Fixed Weapon's aim line: red from its muzzle to the first thing its barrel's line hits (250 m at most),
--- with a mark there, read from its copy as Fire Weapon reads the gun (client/director_weapons.lua). Where the line
--- runs is where "where it points" fires.
local function drawAim(it)
    if type(it.extra) ~= 'table' or not it.extra.weapon or not it.obj or not DoesEntityExist(it.obj) then return end
    if not DirectorWeapons then return end
    local m, at, hit = DirectorWeapons.aimHit(it.obj)
    DrawLine(m.x, m.y, m.z, at.x, at.y, at.z, 255, 40, 40, 230)
    if hit then DrawMarker(28, at.x, at.y, at.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12, 255, 40, 40, 200, false, false, 2, false,
        (nil) --[[@as string]], (nil) --[[@as string]], false) end
end

--- A selected guard's cone on the ground (its page's Sees players), as its settings are now: client/vision.lua
--- paints it and lays it over the ground, turned and moved with the guard (as it walks, in a preview).
local function drawCone(it)
    local v = type(it.extra) == 'table' and it.extra.vision or nil
    if type(v) ~= 'table' or not VisionCone then return end
    local x, y, z, h = liveAt(it)
    VisionCone.draw(x, y, z, h, v)
end

--- A task's point from the Director's page: the one with this id selected, or a new one put down in front
--- of the camera. Answers where a new one went ({ x, y, z, heading }), or nil for one selected.
---@param extra table  its extra: { id, kind = 'point', of, n, glyph, label, mark }
function FurnishBuilder.placePoint(extra)
    local items = ed.items()
    for i = 1, #items do
        local x = items[i].extra
        if type(x) == 'table' and x.id == extra.id then
            ed.select(i)
            ed.pushState()
            return nil
        end
    end
    ed.placeNew('', extra)
    local sel = ed.selected()
    local it = sel and ed.items()[sel]
    if not it then return nil end
    return { x = it.x, y = it.y, z = it.z, heading = it.rz or 0.0 }
end

--- A task's point the scenario has placed that the builder has not got (tasks copied from another thing, a
--- duplicate's): made where it is, the selection left alone. Answers whether it is here now.
---@param row table  { model = '', x, y, z, rz, extra = { id, kind = 'point', ... } }
function FurnishBuilder.addPoint(row)
    if not (ed and ed.session()) or type(row) ~= 'table' or type(row.extra) ~= 'table' then return false end
    if FurnishBuilder.itemOf(row.extra.id) then return true end
    return ed.addRow(row)
end

--- A copy of one of the scenario's things (the Director's Duplicate: client/director.lua directorBuilderCopy): made as a
--- pick is, in hand on the pointer until a click puts it down, turned as the one it copies. It is the scenario's
--- already (its extra has its id), so it is not told as placed. Answers whether it was made.
---@param row table  { model, rx, ry, rz, extra = { id, kind, ... } }
function FurnishBuilder.carryCopy(row)
    if not (ed and ed.session()) or type(row) ~= 'table' or type(row.extra) ~= 'table' then return false end
    return ed.placeNew(row.model or '', row.extra, { carry = true, turn = { x = row.rx, y = row.ry, z = row.rz } }) == true
end

--- The row of the scenario's thing `id` (its copy here: `obj`, and where it is placed: x, y, z, rx, ry, rz), or nil.
--- The Director's preview plays its tasks on it (client/director_preview.lua).
function FurnishBuilder.itemOf(id)
    if not ed or id == nil then return nil end
    for _, it in ipairs(ed.items()) do
        if type(it.extra) == 'table' and it.extra.id == id then return it end
    end
    return nil
end

--- Select the scenario's thing `id` and put the camera in front of it, as Go to does (a card's Look at it: a door
--- Lock / Unlock Door holds). Answers whether it is here.
function FurnishBuilder.lookAt(id)
    if not ed or id == nil then return false end
    for i, it in ipairs(ed.items()) do
        if type(it.extra) == 'table' and it.extra.id == id then
            ed.select(i)
            ed.pushState()
            FreeCam.frame(it.x, it.y, it.z, 3.5)
            return true
        end
    end
    return false
end

--- The scenario's id of the thing selected in the builder now, or nil (a take's line shows only while its car is).
function FurnishBuilder.selectedId()
    if not ed then return nil end
    local sel = ed.selected()
    local it = sel and ed.items()[sel]
    local x = it and it.extra
    return type(x) == 'table' and x.id or nil
end

--- Is the world builder open on a session of the Director's (its page's)?
function FurnishBuilder.open()
    local session = ed and ed.session()
    return session ~= nil and session.page ~= nil
end

--- A new route's marker, now its point 1 (the Director made the route: directorRoutePlaced): the same row, the
--- point's extra. Only while it is still that unnamed route marker (a row moved since is another thing's).
---@param index number
---@param extra table  the point's (client/director.lua extraOf)
function FurnishBuilder.convert(index, extra)
    local it = ed.items()[index]
    local x = it and it.extra
    if type(x) ~= 'table' or x.kind ~= 'route' or x.id ~= nil then return false end
    it.extra = extra
    ed.changed()
    return true
end

--- One of the Director's points moved (a drag, a nudge, a turn): its page hears where it is now once it stops
--- (MOVED_MS after its last move), so what plays it (Play Tasks, a run) goes there without a Save first.
local MOVED_MS = 250
local movedAt = setmetatable({}, { __mode = 'k' })   -- [item] = when it last moved
function FurnishBuilder.moved(it)
    local x = type(it) == 'table' and it.extra or nil
    local session = ed and ed.session()
    if not (session and session.page) or type(x) ~= 'table' or x.kind ~= 'point' or type(x.id) ~= 'string' then return end
    local waiting = movedAt[it] ~= nil
    movedAt[it] = GetGameTimer()
    if waiting then return end
    CreateThread(function()
        while movedAt[it] and GetGameTimer() - movedAt[it] < MOVED_MS do Wait(50) end
        movedAt[it] = nil
        local now = it.extra
        if type(now) ~= 'table' or now.id ~= x.id or not FurnishBuilder.open() then return end
        SendNUIMessage({ action = 'directorPointMoved', id = x.id,
                         coords = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0 } })
    end)
end

--- A row removed (the furnisher's Remove): a route's point or a group's spot goes from its list at once, so the
--- rest are numbered again as they stand (the Director: directorPointRemoved).
function FurnishBuilder.removed(it)
    local x = type(it) == 'table' and it.extra or nil
    local session = ed.session()
    if not (session and session.page) or type(x) ~= 'table' or type(x.id) ~= 'string' then return end
    if x.kind == 'point' then
        SendNUIMessage({ action = 'directorPointRemoved', id = x.id })
    elseif session.page.director then
        -- (app.js: one the scenario took since the last Save goes from it at once; one from before waits for Save.)
        SendNUIMessage({ action = 'directorThingRemoved', id = x.id })
    end
end

--- A thing just put down that the scenario has not got yet (the Director's builder): made in it at once
--- (directorThingPlaced), so every card's picker has it before a Save; the page answers with its id
--- (directorBuilderId). A route is the page's already (directorRoutePlaced), a point its thing's. Once a thing.
local told = setmetatable({}, { __mode = 'k' })
function FurnishBuilder.placed(it, index)
    local session = ed and ed.session()
    if not (session and session.page and session.page.director) or type(it) ~= 'table' or told[it] then return end
    local x = it.extra
    if type(x) == 'table' and (x.id ~= nil or x.kind == 'route' or x.kind == 'point') then return end
    told[it] = true
    SendNUIMessage({ action = 'directorThingPlaced', index = index, kind = type(x) == 'table' and x.kind or 'prop',
                     model = it.model, label = type(x) == 'table' and x.label or nil,
                     lore = type(x) == 'table' and x.lore or nil,
                     random = type(x) == 'table' and x.random == true or nil,
                     weapon = type(x) == 'table' and x.weapon or nil,   -- (a Fixed Weapon: the gun it is)
                     coords = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0 } })
end

-- ---- a random vehicle's copy, going through its models ----

local CYCLE_MS = 3000   -- each model shown this long

--- A random vehicle's copy shows its next model every few seconds, so the builder sees what a run may make. Held
--- while it is selected (being moved), and while it has fewer than two. The next one is asked for and shown once it
--- has loaded (never a wait in this frame); one this game has not got is passed over.
local function cycleRandom(items, selected)
    local now = GetGameTimer()
    for i = 1, #items do
        local it = items[i]
        local x = it.extra
        local models = type(x) == 'table' and x.random == true and type(x.models) == 'table' and x.models or nil
        if models and #models >= 2 and i ~= selected and it.obj then
            if not it.cycleAt then
                it.cycleAt = now + CYCLE_MS
            elseif now >= it.cycleAt then
                if not it.cycleK then
                    local at = 1
                    for k, m in ipairs(models) do if m == it.model then at = k end end
                    it.cycleK = at % #models + 1
                end
                local want = models[(it.cycleK - 1) % #models + 1]
                local hash = GetHashKey(want)
                if want == it.model or not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
                    it.cycleK = it.cycleK % #models + 1
                elseif HasModelLoaded(hash) then
                    ed.swapModel(it, want)
                    it.cycleK, it.cycleAt = it.cycleK % #models + 1, now + CYCLE_MS
                else
                    RequestModel(hash)
                end
            end
        end
    end
end

--- Does the builder mark this thing itself while it is selected (so the furnisher puts no chevron over it)?
function FurnishBuilder.marksSelection(it)
    if it.mark or it.door then return true end
    local K = KINDS[ed.kindOf(it)]
    return K.make == 'ped' or K.make == 'vehicle'
end

--- One frame of the editor, from its mode loop: the things' marks, then the prompts.
---
--- A spot, an item spot and a container with no prop have nothing to make, so each wears a mark where it
--- is; a door, an NPC, a car and a prop wear one too (thingMark). A property's room has none. One a run
--- puts a prompt on is shown AS that prompt instead (previewSync).
local routes = {}                                  -- (this frame's routes: emptied each frame, not made again)
local spotMarks = setmetatable({}, { __mode = 'k' })   -- [thing] = its spot's marker, filled in place each frame

function FurnishBuilder.frame()
    WorldMarks.begin()
    local items, selected = ed.items(), ed.selected()
    cycleRandom(items, selected)
    -- A thing's task points only while it (or one of them) is selected, with the line through them. A route's points
    -- always, with theirs: a route is only its points.
    local owner = pointsOwner(items, selected)
    for k in pairs(routes) do routes[k] = nil end
    for i = 1, #items do
        local it = items[i]
        local x = it.extra
        local isPoint = type(x) == 'table' and x.kind == 'point'
        local routePoint = isPoint and x.list == 'points'
        if routePoint and x.of ~= nil then routes[x.of] = true end
        if not hasPrompt(it) and (not isPoint or routePoint or (owner ~= nil and x.of == owner)) then
            local m = thingMark(it, ed.isSelected(i))
            if m then WorldMarks.add(m) end
        end
    end
    if owner then drawPointLine(items, owner) end
    for route in pairs(routes) do
        if route ~= owner then drawPointLine(items, route) end
    end
    if selected and items[selected] then
        drawCone(items[selected])
        drawAim(items[selected])
    end
    -- A spot's marker where it stands: lit (set off) while selected or named by a card in the Blueprint window.
    for i = 1, #items do
        local it = items[i]
        local z = type(it.extra) == 'table' and it.extra.zone or nil
        if type(z) == 'table' and DirectorSpotMarks then
            local s = DirectorSpotMarks.at(z, it.x, it.y, it.z, it.rz, it.extra.id, spotMarks[it])
            spotMarks[it] = s
            DirectorSpotMarks.draw(s, ed.isSelected(i) or FurnishBuilder.isLit(it), 0.9)
        end
    end

    -- ---- the prompts a run will put up, as players will see them ----
    previewSync()
    WorldMarks.finish()
end

-- ============================================
-- Doors
-- ============================================

--- The world builder's door (More > Door): the next click on the world picks the door under it — the
--- world's own (in the Door Editor or not), as the Director's aim picked one: an object the ray from
--- the camera through the pointer meets. It cannot be moved; it can be picked again or removed.
local function pickDoorAt(nx, ny)
    doorPicking = false
    local from, dx, dy, dz = ed.aim(nx, ny)
    local reach = 40.0
    local ray = StartShapeTestRay(from.x, from.y, from.z, from.x + dx * reach, from.y + dy * reach, from.z + dz * reach,
        16, PlayerPedId(), 0)
    local _, hit, _, _, ent = GetShapeTestResult(ray)
    if not ed.isHit(hit) or not ent or ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 3 then
        UI.Notify('No door there: pick Door again and click on one', 'error')
        ed.pushState()   -- (the page's hint line stops asking for a door)
        return
    end
    local items, unloadable, selected = ed.items(), ed.unloadable(), ed.selected()
    for i = 1, #items do
        if items[i].obj == ent then
            ed.select(i)
            ed.pushState()
            UI.Notify('That door is here already', 'info')
            return
        end
    end
    local p = GetEntityCoords(ent)
    local model = GetEntityModel(ent)
    local it = { model = model, x = p.x, y = p.y, z = p.z, rx = 0.0, ry = 0.0, rz = GetEntityHeading(ent),
                 obj = ent, door = true, dims = doorDims(model), extra = { kind = 'door', label = 'Door' } }
    -- Which door this is: the scenario's door waiting to be picked (opened on it);
    -- the selected door, picked again (its id kept: the cards naming it still do); or one of the
    -- scenario's doors that was not streamed in when the builder opened (found by its model and spot).
    -- Otherwise a new door.
    local replace = nil
    if adoptNext and adoptNext.kind == 'door' then
        it.extra, adoptNext = adoptNext, nil
    elseif selected and items[selected] and items[selected].door then
        replace = selected
        it.extra = items[selected].extra
    else
        for i = #unloadable, 1, -1 do
            local u = unloadable[i]
            if ed.kindOf(u) == 'door' and tonumber(u.model) == model and math.abs(u.x - p.x) < 1.0 and math.abs(u.y - p.y) < 1.0
                and math.abs(u.z - p.z) < 1.0 then
                it.extra = u.extra
                table.remove(unloadable, i)
                break
            end
        end
    end
    if replace then
        items[replace] = it   -- (the old door is the world's: nothing to delete)
        ed.select(replace)
    else
        items[#items + 1] = it
        ed.select(#items)
    end
    ed.changed()
    if not replace then FurnishBuilder.placed(it, #items) end
end

--- A click on the room (or A, on a pad, at the dot), asked before it selects: while a door pick waits,
--- this click picks the door under it. True when it was this file's.
function FurnishBuilder.click(nx, ny)
    if not doorPicking then return false end
    pickDoorAt(nx, ny)
    return true
end

--- Is a door pick waiting (the page says so: on a pad, A picks a door)?
function FurnishBuilder.picking() return doorPicking end

--- A waiting door pick put away (a row picked, Move / Rotate, another pick, B). True when one was waiting.
function FurnishBuilder.cancelPick()
    local was = doorPicking
    doorPicking = false
    return was
end

-- ============================================
-- Picking from the page
-- ============================================

--- A pick arrives in hand: it rides the mouse until a left click puts it down (client/property_furnish.lua placeNew).
local PICKED = { carry = true }

--- The thing waiting for its first pick of `kind` (opened on it), or the new one `x`. A lore character picked for it
--- makes it that character.
local function takeAdopt(kind, x)
    if adoptNext and adoptNext.kind == kind then
        local a = adoptNext
        adoptNext = nil
        if x and x.lore then a.lore = x.lore end
        return a
    end
    return x
end

--- A pick from the page of a session of the caller's (the furnisher's furnishPick: a property's room
--- picks from the catalog alone). The world builder's kinds: a tab says what it places (a
--- prop, an NPC, a car, a spot, an item spot, a container, a door), and the thing carries it, with the
--- name it was picked by.
---@param data table  { model, kind, name, byName, lore }
function FurnishBuilder.pick(data)
    local model = data and data.model
    local kind = type(data.kind) == 'string' and KINDS[data.kind] and data.kind or nil
    if kind == 'door' then
        doorPicking = true
        local items, selected = ed.items(), ed.selected()
        local sel = selected and items[selected]
        -- (On a pad the dot in the middle is the pointer, and A the click.)
        local replacing = sel and sel.door and not (adoptNext and adoptNext.kind == 'door')
        UI.Notify(ed.padOn() and (replacing and 'Put the dot on the door that takes this one\'s place, and press A'
                or 'Put the dot on the door, in the world, and press A')
            or replacing and 'Click the door that takes this one\'s place' or 'Click the door, in the world', 'info')
        ed.pushState()   -- (the page's hint line asks for a door)
        return
    end
    local function extraFor(x) return takeAdopt(kind, x) end
    -- Vehicle pool (the Vehicles' first tile): one spot, the models a run picks from by their odds on its page. A mark
    -- until it has some.
    if kind == 'vehicle' and data.random == true then
        ed.placeNew('', { kind = 'vehicle', random = true, label = 'Vehicle pool' }, PICKED)
        return
    end
    if kind and KINDS[kind].mark and data.byName ~= true and (type(model) ~= 'string' or model == '' or model == kind) then
        -- A spot, an item spot, a container: a marker in front of the camera (a container's prop is
        -- chosen in the World tab).
        ed.placeNew('', { kind = kind, label = type(data.name) == 'string' and data.name:sub(1, 60) or nil }, PICKED)
        -- A route is its points: the Director makes the route, and this marker becomes its point 1
        -- (client/director.lua directorBuilderConvert).
        if kind == 'route' then
            local sel = ed.selected()
            local it = sel and ed.items()[sel]
            if it then
                SendNUIMessage({ action = 'directorRoutePlaced', index = sel,
                                 coords = { x = it.x, y = it.y, z = it.z, heading = it.rz or 0.0 } })
            end
        end
        return
    end
    if type(model) ~= 'string' or model == '' then return end
    -- The world builder's "by name": any model this game has, for this one thing —
    -- never added to the catalog. A property's room places only what the catalog offers.
    if data.byName == true then
        kind = kind or 'prop'
        model = model:lower():match('^%s*([%w_]+)%s*$')
        if not model or #model > 64 then
            UI.Notify('A model name is letters, digits and _ (prop_box_wood02a)', 'error')
            return
        end
        local hash = GetHashKey(model)
        if not IsModelInCdimage(hash) then
            UI.Notify(('%s is not a model this game has: check the spelling'):format(model), 'error')
            return
        end
        local isPed, isCar = IsModelAPed(hash), IsModelAVehicle(hash)
        local is = isPed and 'ped' or isCar and 'vehicle' or 'prop'
        local wants = kind == 'npc' and 'ped' or kind == 'vehicle' and 'vehicle' or 'prop'
        if is ~= wants then
            UI.Notify(('%s is a %s, not a %s'):format(model, is, wants), 'error')
            return
        end
        ed.placeNew(model, extraFor({ kind = kind, custom = true, label = model }), PICKED)
        return
    end
    if kind then
        local x = { kind = kind, label = type(data.name) == 'string' and data.name:sub(1, 60) or nil }
        -- A lore character, picked from the NPCs' Lore characters (html/js/furnisher.js): the NPC is them.
        if kind == 'npc' and type(data.lore) == 'string' and #data.lore <= 64 and data.lore:match('^[%w_%-]+$') then
            x.lore = data.lore
        end
        -- A Fixed Weapon (More, Weapons): a prop that is that gun, its model the gun's own.
        if kind == 'prop' and WeaponCatalog.modelOf(data.weapon) == model then x.weapon = data.weapon:upper() end
        ed.placeNew(model, extraFor(x), PICKED)
        return
    end
    ed.placeNew(model, nil, PICKED)
end

--- Input ped name (html/js/furnisher.js): a ped by its exact name, put in hand as a pick is. nil when it is; else
--- 'missing' (no ped of that name in this game) or 'failed' (there is one, but it would not load or be made).
local function placePed(name)
    local model = type(name) == 'string' and name:lower():match('^%s*([%w_]+)%s*$') or nil
    if not model or #model > 64 then return 'missing' end
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) or not IsModelAPed(hash) then return 'missing' end
    local x = { kind = 'npc', custom = true, label = model }
    local a = takeAdopt('npc', x)
    if ed.placeNew(model, a, { carry = true, quiet = true }) then return nil end
    if a ~= x then adoptNext = a end   -- (still waiting for its first pick)
    return 'failed'
end

RegisterNUICallback('furnishPedName', function(d, cb)
    local s = ed and ed.session()
    if not (FurnishModeActive and s and s.page) then cb({ ok = false, why = 'failed' }) return end
    FurnishBuilder.cancelPick()
    local why = placePed(type(d) == 'table' and d.name or nil)
    cb({ ok = why == nil, why = why })
end)

--- Opened on one of the scenario's with nothing to make yet (a door not picked, an NPC or a car with no
--- model; Furnisher.open's spec.adopt): the next pick of its kind is it. A door's pick waits for the
--- click at once.
---@param a table  the thing's extra: { kind, id, label, ... }
function FurnishBuilder.adopt(a)
    if not KINDS[a.kind] then return end
    adoptNext = a
    if a.kind == 'door' then
        doorPicking = true
        UI.Notify(('Click the door for %s, in the world'):format(tostring(a.label or 'it')), 'info', 6000)
    else
        UI.Notify(('Pick what %s is, from its tab'):format(tostring(a.label or 'it')), 'info', 6000)
    end
end

-- ============================================
-- Removing what a card uses
-- ============================================

--- The cards that use this thing (its extra.uses: their names), or nil when none does.
local function usedBy(it)
    local uses = type(it.extra) == 'table' and it.extra.uses or nil
    if type(uses) == 'table' and #uses > 0 then return uses end
    return nil
end
FurnishBuilder.usedBy = usedBy

--- A thing a card uses (the world builder): warned, with Remove and Keep, before it goes. The page
--- asks; its Remove
--- comes back forced, for this one. True when the page was asked (the removal waits for its answer).
---@param index number  the selection's index, which the answer names
function FurnishBuilder.confirmRemove(it, index)
    local session = ed.session()
    local uses = usedBy(it)
    if not (session and session.page and uses) then return false end
    SendNUIMessage({ action = 'furnishConfirmRemove', index = index, uses = uses })
    return true
end

--- Several selected, removed together: always asked first (`many` of them), naming the cards that use any of them.
---@param list table   the things
---@param index number the primary's row, which the answer names
function FurnishBuilder.confirmRemoveMany(list, index)
    local uses, seen = {}, {}
    for _, it in ipairs(list) do
        for _, u in ipairs(usedBy(it) or {}) do
            if not seen[u] then seen[u] = true; uses[#uses + 1] = u end
        end
    end
    SendNUIMessage({ action = 'furnishConfirmRemove', index = index, many = #list, uses = uses })
end

-- ============================================
-- Turn To's copy
-- ============================================

local GHOST_ALPHA = 120
local GHOST_HOLD_MS, GHOST_DONE_MS = 4000, 1500   -- gone this long after the slider last moved / was let go
---@type { ent: integer, id: any, untilAt: integer? }|nil
local ghost = nil                                 -- { ent, id, untilAt }

local function ghostGone()
    if ghost and ghost.ent and DoesEntityExist(ghost.ent) then DeleteEntity(ghost.ent) end
    ghost = nil
end

--- A Turn To step's heading as its slider moves (the Director's page): a see-through copy of the scenario's prop `id`
--- where it stands, turned to `heading`. It goes a moment after the slider stops (sooner once it is let go), when
--- another prop's is shown, or when the builder closes.
function FurnishBuilder.turnGhost(id, heading, done)
    local it = FurnishBuilder.itemOf(id)
    local obj = it and it.obj
    if not obj or obj == 0 or not DoesEntityExist(obj) then return end
    if ghost and ghost.id ~= id then ghostGone() end
    local fresh = ghost == nil
    if fresh then
        local p = GetEntityCoords(obj)
        local ent = CreateObjectNoOffset(GetEntityModel(obj), p.x, p.y, p.z, false, false, false)
        if not ent or ent == 0 then return end
        FreezeEntityPosition(ent, true)
        SetEntityCollision(ent, false, false)
        SetEntityAlpha(ent, GHOST_ALPHA, false)
        ghost = { ent = ent, id = id }
    end
    ---@cast ghost -nil   -- (made just now when there was none)
    local r = GetEntityRotation(obj, 2)
    SetEntityRotation(ghost.ent, r.x, r.y, heading, 2, false)
    ghost.untilAt = GetGameTimer() + (done and GHOST_DONE_MS or GHOST_HOLD_MS)
    if not fresh then return end
    local me = ghost
    CreateThread(function()
        while ghost == me and GetGameTimer() < me.untilAt and FurnishBuilder.open() do Wait(100) end
        if ghost == me then ghostGone() end
    end)
end

-- ============================================
-- Opening and closing
-- ============================================

--- A session opening: no door pick waiting, nothing to adopt.
function FurnishBuilder.reset()
    doorPicking = false
    adoptNext = nil
    lit = {}
end

--- The editor closing: the previewed prompts, and the preview, go with the things they stood for, and
--- the marks' browser with them.
function FurnishBuilder.stop()
    previewStop()
    ghostGone()
    WorldMarks.stop()
    FurnishBuilder.reset()
end

--- The furnisher hands over the editor as it loads (see `ed` at the top), and this file's kinds join its.
---@param editor FurnishEditor
function FurnishBuilder.attach(editor)
    ed, KINDS = editor, editor.kinds
    for name, K in pairs(BUILDER_KINDS) do KINDS[name] = K end
end
