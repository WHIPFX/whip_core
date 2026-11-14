-- The Lua half of the Properties section's wizard (html/js/wp/properties.js): Interior, Space, Doors, Signs, Garage,
-- Name & settings, Review. The same steps, one at a time, edit one part of an existing property.
-- The draft lives here, not in the page: everything taken from the world (placement, rooms, shapes, doors, signs)
-- is held in the interior's own space, so the draft is a unit before it is saved. The page gets a summary
-- (WhipPanelData 'draft') and keeps only its form fields.
-- Nothing is written until Save: it sends the draft once (server/property_admin.lua, propertyAdminSave), the server
-- checks all of it again, and only a success (propertyAdminSaved) ends the draft.
-- The in-world parts are PropertyEditor modes (tools/property_editor.lua); every mode here writes into the draft only.
-- A placement that changes wipes the parts: shapes and doors are local to the interior they were captured in.

PropertyWizard = {}

--- A door that could be the unit's: found by the scan, added by hand (G), or one the unit already has.
---@class PropertyWizardDoor
---@field model number           signed hash
---@field pos table              { x, y, z } in the interior's space
---@field heading number         in the interior's space
---@field world table            { x, y, z }
---@field worldHeading number
---@field body table             DoorLeaf.body's { x, y, z, top, bottom, width }
---@field kind string            'door' | 'garage'
---@field source string          where it came from: the scan's, 'picked', 'saved'
---@field role? string           'entrance' | 'interior' | 'garage'; nil: not this unit's
---@field lock? boolean          an inner door whip locks
---@field key? string
---@field seeded? boolean        a door the property already had: it keeps its key
---@field pairKey? string        the other leaf's key, as saved
---@field pairWith? integer      the other leaf's place in the candidates
---@field conflict? string       whose door it is already, when it is somebody else's
---@field doorId? number         the whip door it already is, ours
---@field adopt? number          a whip door nobody manages, adopted at save
---@field entity? number         its object, once found (DoorLeaf.entity)

--- The property being set up (or the part of one being edited), in the interior's own space.
---@class PropertyDraft
---@field mode string            'new' | 'edit'
---@field part? string           editing: 'interior' (Re-bind) | 'space' | 'doors' | 'garage'
---@field adding? boolean        editing the doors: keep the ones it has (Add doors)
---@field propertyId? number
---@field name? string
---@field unitUses? number
---@field saving? boolean
---@field world boolean          no interior: a house on the open map
---@field place? table           { hash, x, y, z, yaw }
---@field rooms? table[]         the interior's rooms { name, min, max }
---@field fingerprint? table     { rooms, portals }
---@field reading? table         the last Interior.read
---@field readWhy? string
---@field known? table           what whip knows of the interior (adminKnown)
---@field spaceKind string       'interior' | 'rooms' | 'draw'
---@field pickRooms table<string, boolean>
---@field drawn table[]
---@field drawHeight number
---@field visit? table           { x, y, z }
---@field candidates PropertyWizardDoor[]
---@field scanned boolean
---@field sign? table            { pos, heading, post? }
---@field manager? table         { pos, heading }
---@field bays table[]           { pos, heading }

--- nil while no property is being set up. The helpers below only run with one (the page's buttons ask
--- needDraft first), hence their casts; readInterior waits, so it checks again after each wait.
---@type PropertyDraft|nil
local draft = nil

local ROLE_PREFIX = { entrance = 'entrance', interior = 'door', garage = 'garage' }
local MAX_SHAPES = 16          -- PropertyValidate.LIMITS.shapes
local MAX_POINTS = 64          -- PropertyValidate.LIMITS.points
local MAX_BAYS = 8             -- PropertyValidate.LIMITS.bays
local DOOR_NEAR_SPACE = 1.5    -- a door counts for a unit if it is this close to its space
local GARAGE_NEAR_SPACE = 10.0 -- a garage door, this close: a garage can be a building of its own
local NEIGHBOUR_RANGE = 80.0

local function log(msg)
    print('[whip_core:propwizard] ' .. msg)
end

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- ============================================
-- The draft as shapes, doors and world data
-- ============================================

--- The unit's space, in the interior's own space.
local function localSpace()
    local d = draft --[[@as PropertyDraft]]
    if d.spaceKind == 'interior' then return { { type = 'interior' } } end
    if d.spaceKind == 'rooms' then
        local names = {}
        for _, r in ipairs(d.rooms or {}) do
            if d.pickRooms[tostring(r.name):lower()] then names[#names + 1] = r.name end
        end
        if #names == 0 then return {} end
        return { { type = 'rooms', rooms = names } }
    end
    return d.drawn
end

--- The space in the world, prepared for containment and drawing.
local function worldShapes()
    if not draft or not draft.place then return {}, false end
    local shapes, unresolved = PropertyMath.expandSpace(localSpace(), draft.rooms)
    local out = {}
    for _, s in ipairs(shapes) do
        local w = PropertyMath.shapeToWorld(draft.place, s)
        local p = w and Shapes.prepare(w)
        if p then out[#out + 1] = p end
    end
    return out, unresolved
end

local function areaOf(shapes)
    local a = 0.0
    for _, s in ipairs(shapes) do a = a + Shapes.area(s) end
    return a
end

--- A door's role as the page and the picker name it: 'none', 'entrance', 'lockable' (an inner
--- door whip locks), 'interior' (an inner door whip only lists), 'garage'.
local function uiRole(c)
    if not c.role then return 'none' end
    if c.role == 'interior' then return c.lock and 'lockable' or 'interior' end
    return c.role
end

local function keyTaken(key, except)
    ---@cast draft -nil
    for _, c in ipairs(draft.candidates) do
        if c ~= except and c.role and c.key == key then return true end
    end
    return false
end

local function unpair(c)
    ---@cast draft -nil
    local other = c.pairWith and draft.candidates[c.pairWith]
    if other and other.pairWith and draft.candidates[other.pairWith] == c then other.pairWith = nil end
    c.pairWith = nil
end

--- Give a door a role. A door the property already had keeps its key: the door system knows
--- the door by it, and a new key would release it and adopt it again.
local function setRole(c, role)
    if role == 'none' then
        c.role, c.lock = nil, nil
        unpair(c)
        return
    end
    if role == 'lockable' then c.role, c.lock = 'interior', true
    elseif role == 'interior' then c.role, c.lock = 'interior', nil
    else c.role, c.lock = role, nil end
    if not (c.seeded and c.key) then
        local prefix, n = ROLE_PREFIX[c.role], 1
        while keyTaken(prefix .. n, c) do n = n + 1 end
        c.key = prefix .. n
    end
end

--- The unit's door list: every candidate with a role.
local function unitDoors()
    ---@cast draft -nil
    local out = {}
    for _, c in ipairs(draft.candidates) do
        if c.role then
            local other = c.pairWith and draft.candidates[c.pairWith]
            out[#out + 1] = {
                key = c.key, role = c.role, lock = c.lock or nil,
                pair = (other and other.role) and other.key or nil,
                model = c.model, pos = c.pos, heading = c.heading,
            }
        end
    end
    return out
end

local function firstEntrance()
    ---@cast draft -nil
    for _, c in ipairs(draft.candidates) do
        if c.role == 'entrance' then return c end
    end
    return nil
end

--- A door's middle, top and width in the world, from its model: markers float over the middle,
--- and a sign goes beside it at eye height. (tools/door_leaf.lua: the Door Editor's too.)
local function doorBody(model, world, heading)
    return DoorLeaf.body(model, world.x, world.y, world.z, heading)
end

--- Another property whose space holds this point, from what this client already has (its
--- shapes arrive prepared, as _shapes: client/properties.lua).
local function propertyAt(x, y, z, exceptId)
    for id, p in pairs(GetPropertyDefs and GetPropertyDefs() or {}) do
        if id ~= exceptId and p._shapes and Shapes.containsAny(p._shapes, x, y, z) then return p end
    end
    return nil
end

--- The other properties near the draft, for drawing grey around it.
local function neighbours()
    ---@cast draft -nil
    local out = {}
    local a = draft.place
    if not a then return out end
    for id, p in pairs(GetPropertyDefs and GetPropertyDefs() or {}) do
        if id ~= draft.propertyId and p.anchor and p.shapes and #p.shapes > 0 then
            local dx, dy, dz = p.anchor.x - a.x, p.anchor.y - a.y, p.anchor.z - a.z
            if dx * dx + dy * dy + dz * dz < NEIGHBOUR_RANGE * NEIGHBOUR_RANGE then out[#out + 1] = p end
        end
    end
    return out
end

local function showNeighbours()
    for _, p in ipairs(neighbours()) do
        ZonePreview.set('pe:n:' .. p.id, p.shapes, { name = 'other', label = p.name })
    end
end

-- ============================================
-- What the page is sent
-- ============================================

local function summary()
    local d = draft
    if not d then return { active = false } end
    local s = {
        active = true, mode = d.mode, part = d.part, adding = d.adding == true, propertyId = d.propertyId,
        name = d.name, unitUses = d.unitUses or 1, saving = d.saving == true, world = d.world == true,
    }

    local r = d.reading
    s.interior = {
        read = r ~= nil, why = d.readWhy,
        hash = r and r.hash or (d.place and d.place.hash) or nil,
        yawOnly = r and r.yawOnly, currentRoom = r and r.currentRoom,
        roomCount = r and #r.rooms or #(d.rooms or {}), portalCount = r and r.portalCount or nil,
        place = d.place, known = d.known,
    }
    if d.mode == 'edit' and d.part == 'interior' and r and d.place then
        local same, dist, dyaw = PropertyMath.samePlacement(r.place, d.place, 0.05, 0.1)
        s.interior.moved = { dist = dist, yaw = dyaw, same = same, sameHash = r.hash == d.place.hash }
        -- ITS LAYOUT, against the one its template was made with: an MLO update that
        -- changed its rooms (a garage moved out) is shown here, and Save takes it.
        local was = d.fingerprint
        if was and r.hash == d.place.hash then
            s.interior.layout = {
                changed = was.rooms ~= r.roomCount or was.portals ~= r.portalCount,
                rooms = r.roomCount, portals = r.portalCount, wasRooms = was.rooms, wasPortals = was.portals,
            }
        end
    end

    s.rooms = {}
    for i, room in ipairs(d.rooms or {}) do
        s.rooms[i] = {
            name = room.name,
            w = room.max.x - room.min.x, l = room.max.y - room.min.y, h = room.max.z - room.min.z,
            picked = d.pickRooms[tostring(room.name):lower()] == true,
        }
    end

    local shapes, unresolved = worldShapes()
    local space = {
        kind = d.spaceKind, shapes = #shapes, area = areaOf(shapes), unresolved = unresolved,
        roomsKnown = d.rooms ~= nil and #d.rooms > 0, drawn = {}, visitSet = d.visit ~= nil,
    }
    for i, sh in ipairs(d.drawn) do
        space.drawn[i] = { type = sh.type, area = Shapes.area(sh), points = sh.points and #sh.points or 4 }
    end
    if d.visit and d.place then
        local x, y, z = PropertyMath.toWorld(d.place, d.visit.x, d.visit.y, d.visit.z)
        space.visitInside = Shapes.containsAny(shapes, x, y, z, 0.3)
    end
    -- Somebody else's already? The middle of each shape, against every property this client has.
    for _, sh in ipairs(shapes) do
        local b = sh._bbox
        local other = propertyAt((b.minX + b.maxX) * 0.5, (b.minY + b.maxY) * 0.5, b.minZ + 0.5, d.propertyId)
        if other then space.clash = ('%s (#%d)'):format(other.name or 'Property', other.id) break end
    end
    s.space = space

    local doors = { scanned = d.scanned == true, list = {} }
    local ped = GetEntityCoords(PlayerPedId())
    for i, c in ipairs(d.candidates) do
        local dx, dy, dz = c.body.x - ped.x, c.body.y - ped.y, c.body.z - ped.z
        doors.list[i] = {
            i = i, role = uiRole(c), key = c.role and c.key or nil, kind = c.kind, source = c.source,
            pair = c.pairWith, conflict = c.conflict, doorId = c.doorId, adopt = c.adopt,
            dist = math.sqrt(dx * dx + dy * dy + dz * dz),
        }
    end
    s.doors = doors

    s.sign = d.sign ~= nil
    -- On a sign post: which one, by its label. `posts`: whether there are any to put up (Config.PropertySignPosts).
    local post = d.sign and PropertyMath.signPost(d.sign.post)
    s.signPost = post and (post.label or post.model) or nil
    s.posts = #(Config.PropertySignPosts or {}) > 0
    s.manager = d.manager ~= nil
    s.canSuggest = firstEntrance() ~= nil

    local bays = {}
    for i, b in ipairs(d.bays) do
        local x, y, z = PropertyMath.toWorld(d.place, b.pos.x, b.pos.y, b.pos.z)
        local dx, dy, dz = x - ped.x, y - ped.y, z - ped.z
        bays[i] = { i = i, dist = math.sqrt(dx * dx + dy * dy + dz * dz) }
    end
    s.garage = { bays = bays }
    return s
end

function PropertyWizard.push()
    WhipPanelData('properties', 'draft', summary())
end

local function sayResult(ok, idOrWhy)
    WhipPanelData('properties', 'saved', { ok = ok == true, id = ok and idOrWhy or nil, why = not ok and idOrWhy or nil })
end

-- ============================================
-- Starting, and the interior
-- ============================================

---@param mode string  'new' | 'edit'
---@return PropertyDraft
local function blank(mode)
    return {
        mode = mode, place = nil, rooms = nil, fingerprint = nil, reading = nil, readWhy = nil,
        world = false, spaceKind = 'interior', pickRooms = {}, drawn = {}, drawHeight = 3.0,
        visit = nil, candidates = {}, scanned = false, sign = nil, manager = nil, bays = {},
    }
end

--- Clear everything that was captured against the old placement.
local function resetParts()
    local d = draft --[[@as PropertyDraft]]
    d.spaceKind = d.world and 'draw' or 'interior'
    d.pickRooms, d.drawn, d.visit = {}, {}, nil
    d.candidates, d.scanned = {}, false
    d.sign, d.manager = nil, nil
    d.bays = {}
end

--- RE-BIND READS THE PROPERTY'S OWN INTERIOR, SO IT TAKES THE ADMIN THERE: Verify's tour leaves them
--- where they started, usually outside. Not standing in an interior of the property's own: to its
--- stand-in point (the panel's Go inside), and the interior given the time Verify gives it to load. An interior that moved is still the same archetype, so this stands
--- in it wherever it is now.
local INSIDE_LOAD_MS = 8000

---@param d PropertyDraft
local function goInsideFor(d)
    if d.world or not d.place or not d.propertyId then return end
    local ped = PlayerPedId()
    local id = GetInteriorFromEntity(ped)
    if id ~= 0 and Interior.placementOf(id).hash == d.place.hash then return end
    local p = (GetPropertyDefs and GetPropertyDefs() or {})[d.propertyId]
    local v = p and (p.visit or p.anchor)
    if not v then return end
    RequestCollisionAtCoord(v.x, v.y, v.z)
    SetEntityCoords(ped, v.x, v.y, v.z + 0.1, false, false, false, false)
    local deadline = GetGameTimer() + INSIDE_LOAD_MS
    while GetGameTimer() < deadline do
        id = GetInteriorFromEntity(PlayerPedId())
        if id ~= 0 and IsInteriorReady(id) then break end
        Wait(100)
    end
end

--- What a Re-bind reading found, said in words as it is read: the interior against the saved placement, its rooms against the template's, and what Save will do.
--- Answers the sentence, and true when it is bad news (a different interior).
---@param d PropertyDraft
local function rebindNote(d)
    local r = d.reading
    if not r or not d.place then return nil end
    if r.hash ~= d.place.hash then
        return 'Read the interior here: it is a different interior from the one this property is built on', true
    end
    local same, dist, dyaw = PropertyMath.samePlacement(r.place, d.place, 0.05, 0.1)
    local was = d.fingerprint
    local relaid = was and (was.rooms ~= r.roomCount or was.portals ~= r.portalCount)
    local found = {}
    if not same then found[#found + 1] = ('it has moved %.2f m and %.1f°'):format(dist, dyaw) end
    if relaid and was then
        found[#found + 1] = ('its rooms have changed — %d rooms and %d doorways, it had %d and %d')
            :format(r.roomCount or 0, r.portalCount or 0, was.rooms or 0, was.portals or 0)
    end
    if #found == 0 then
        return ('Read the interior here: %d rooms and %d doorways, exactly as saved — nothing to re-bind')
            :format(r.roomCount or 0, r.portalCount or 0)
    end
    return 'Read the interior here: ' .. table.concat(found, ', and ') .. '. Press Next, then Save, to take it.'
end

--- Read the interior the admin stands in. For a new property it becomes the draft's placement;
--- editing one, it is only compared with the saved placement (Re-bind), which takes them inside first
--- and answers what it found (rebindNote).
---@return string|nil note, boolean|nil bad
local function readInterior()
    ---@cast draft -nil
    local mine = draft
    if draft.mode == 'edit' and draft.part == 'interior' then goInsideFor(draft) end
    local info, why = Interior.read()
    if draft ~= mine then return end   -- cancelled (or started again) while it read
    draft.reading, draft.readWhy = info, why
    if not info then return end
    if draft.mode ~= 'new' then
        if draft.part == 'interior' then return rebindNote(draft) end
        return
    end

    local changed = draft.world or not draft.place
        or not PropertyMath.samePlacement(info.place, draft.place, 0.05, 0.1)
    draft.world = false
    draft.place = info.place
    draft.rooms = info.rooms
    draft.fingerprint = { rooms = info.roomCount, portals = info.portalCount }
    if changed then resetParts() end
    local known = Callback('whip_core:property:adminKnown', info.place) or nil   -- (a refusal is false, why)
    if draft ~= mine then return end
    draft.known = known
end

--- No interior: a house on the open map. The placement is where the admin stands, facing north,
--- so its local space is plain metres from that spot.
local function useWorld()
    ---@cast draft -nil
    local c = GetEntityCoords(PlayerPedId())
    local changed = not draft.world
    draft.world = true
    draft.reading, draft.readWhy = nil, nil
    draft.place = { hash = 0, x = c.x, y = c.y, z = c.z - 1.0, yaw = 0.0 }
    draft.rooms, draft.fingerprint, draft.known = nil, nil, nil
    if changed then resetParts() end
    draft.spaceKind = 'draw'
end

function PropertyWizard.start()
    draft = blank('new')
    readInterior()
    PropertyWizard.push()
end

function PropertyWizard.cancel()
    draft = nil
    ZonePreview.clearPrefix('pe:')
    PropertyWizard.push()
end

function PropertyWizard.active()
    return draft ~= nil
end

-- ============================================
-- Editing one part of a saved property
-- ============================================

--- Make a candidate from a door the unit already has.
local function savedDoor(place, d)
    local wx, wy, wz = PropertyMath.toWorld(place, d.pos.x, d.pos.y, d.pos.z)
    local world = { x = wx, y = wy, z = wz }
    local wh = PropertyMath.headingToWorld(place, d.heading or 0.0)
    return {
        model = d.model, pos = { x = d.pos.x, y = d.pos.y, z = d.pos.z }, heading = d.heading or 0.0,
        world = world, worldHeading = wh, body = doorBody(d.model, world, wh),
        kind = d.role == 'garage' and 'garage' or 'door', source = 'saved',
        role = d.role, lock = d.lock or nil, key = d.key, seeded = true, pairKey = d.pair,
    }
end

--- Load a property's unit into a draft, for editing one part of it.
---@param part string  'interior' (Re-bind) | 'space' | 'doors' | 'garage'
---@param adding boolean|nil  doors only: keep the doors it has and add to them ("Add doors")
---@return boolean ok, string|nil why, boolean|nil bad  opened for Re-bind: what it read (bad: a different interior)
function PropertyWizard.edit(propertyId, part, adding)
    local info = Callback('whip_core:property:adminUnit', propertyId)
    if not info then return false, 'That property is not there any more' end

    draft = blank('edit')
    local d = draft
    d.part, d.propertyId, d.name, d.unitUses = part, info.id, info.name, info.unitUses or 1
    d.adding = part == 'doors' and adding == true
    d.place = info.place
    d.world = (info.archetypeHash or 0) == 0
    d.rooms = info.rooms
    d.fingerprint = info.fingerprint   -- its interior's rooms and doorways when its template was made (Re-bind)

    local u = info.unit or {}
    local space = u.space or {}
    local allRooms = #space > 0
    for _, s in ipairs(space) do if s.type ~= 'rooms' then allRooms = false end end
    if #space == 1 and space[1].type == 'interior' then
        d.spaceKind = 'interior'
    elseif allRooms then
        d.spaceKind = 'rooms'
        for _, s in ipairs(space) do
            for _, n in ipairs(s.rooms or {}) do d.pickRooms[tostring(n):lower()] = true end
        end
    else
        d.spaceKind = 'draw'
        for _, s in ipairs(space) do
            if s.type == 'box' or s.type == 'poly' then d.drawn[#d.drawn + 1] = s end
        end
    end

    -- THE DOORS STEP STARTS FRESH: its doors are set up again because they changed (an MLO update
    -- moved them), so the saved ones are not brought in — their markers would take the aim, and the
    -- scan skips a door within 0.3 m of one already listed. The scan finds what is there now; Save
    -- replaces the old list, and the server lets the old doors go (server/properties.lua syncDoors).
    --
    -- ADDING DOORS KEEPS THEM (for a door missed, or a new one). The doors it has come in as they
    -- are, keys and roles and pairs, as every other part brings them; the scan skips a door already
    -- listed and G says "That is door N already", so only the missing ones are added. Save sends the
    -- whole list again: the saved doors keep their keys, so the door system keeps them, and the new
    -- ones are made. Doors that MOVED want the fresh start above.
    if part ~= 'doors' or d.adding then
        for _, door in ipairs(u.doors or {}) do
            if door.pos then d.candidates[#d.candidates + 1] = savedDoor(d.place, door) end
        end
    end
    for _, c in ipairs(d.candidates) do
        if c.pairKey then
            for j, o in ipairs(d.candidates) do
                if o.key == c.pairKey and o ~= c then c.pairWith = j end
            end
        end
    end
    d.scanned = #d.candidates > 0
    d.sign, d.manager, d.visit = u.sign, u.manager, u.visit
    for i, b in ipairs((u.garage and u.garage.bays) or {}) do
        d.bays[i] = { pos = { x = b.pos.x, y = b.pos.y, z = b.pos.z }, heading = b.heading or 0.0 }
    end

    -- Re-bind reads straight away, and says what it read (the page shows it: pcEditPart).
    local note, bad
    if part == 'interior' then note, bad = readInterior() end
    PropertyWizard.push()
    return true, note, bad
end

-- ============================================
-- Doors: finding them
-- ============================================

--- Whip doors already standing where these candidates are: ours, somebody else's, or nobody's (adopted
--- at save). Asks the server round a point; blocks, so it runs in a thread.
local function checkKnown(list, cx, cy, cz, r)
    local known = Callback('whip_core:property:adminDoorsNear', cx, cy, cz, r) or {}
    for _, c in ipairs(list) do
        c.conflict, c.doorId, c.adopt = nil, nil, nil
        for _, door in ipairs(known) do
            local dx, dy, dz = door.x - c.world.x, door.y - c.world.y, door.z - c.world.z
            if dx * dx + dy * dy + dz * dz <= 0.5 * 0.5 and PropertyMath.signedHash(door.model) == PropertyMath.signedHash(c.model) then
                local mb = door.manager
                if mb and mb.system == 'property' and draft and tonumber(mb.id) == draft.propertyId then
                    c.doorId = door.doorId
                elseif mb then
                    c.conflict = mb.label or ('%s #%s'):format(tostring(mb.system), tostring(mb.id))
                else
                    c.adopt = door.doorId
                end
            end
        end
    end
end

--- Every door that could be the unit's: the interior's portal doors and anything door-shaped
--- near the space, kept only if it stands at the space's edge (a garage door, within
--- GARAGE_NEAR_SPACE). Doors already in the draft keep their roles; a door another property already
--- manages is marked. Any other door is added by hand in the picker (G).
local function scanDoors()
    local d = draft --[[@as PropertyDraft]]
    local shapes = worldShapes()
    local bounds = Shapes.bbox(shapes)
    if not bounds then return false, 'Set the space first — the doors are found around it' end

    local ped = PlayerPedId()
    local interiorId = GetInteriorFromEntity(ped)
    local portals = nil
    if not d.world and interiorId ~= 0 then
        local info = Interior.read()
        if info and info.hash == d.place.hash and PropertyMath.samePlacement(info.place, d.place) then
            portals = info.portals
        else
            interiorId = 0
        end
    end

    local found = Interior.doorCandidates(d.place, portals, bounds, interiorId ~= 0 and interiorId or nil)
    local added = 0
    for _, f in ipairs(found) do
        local wh = PropertyMath.headingToWorld(d.place, f.heading)
        local body = doorBody(f.model, f.world, wh)
        local near = Shapes.containsAny(shapes, body.x, body.y, body.z,
            f.kind == 'garage' and GARAGE_NEAR_SPACE or DOOR_NEAR_SPACE)
        local dup = false
        for _, c in ipairs(d.candidates) do
            local dx, dy, dz = c.world.x - f.world.x, c.world.y - f.world.y, c.world.z - f.world.z
            if dx * dx + dy * dy + dz * dz < 0.3 * 0.3 then dup = true break end
        end
        if near and not dup then
            d.candidates[#d.candidates + 1] = {
                model = f.model, pos = f.pos, heading = f.heading, world = f.world, worldHeading = wh,
                body = body, kind = f.kind, source = f.source,
            }
            added = added + 1
        end
    end

    -- Whip doors already standing there: ours, somebody else's, or nobody's (adopted at save).
    local cx, cy, cz = (bounds.minX + bounds.maxX) * 0.5, (bounds.minY + bounds.maxY) * 0.5, (bounds.minZ + bounds.maxZ) * 0.5
    local hx, hy = (bounds.maxX - bounds.minX) * 0.5, (bounds.maxY - bounds.minY) * 0.5
    -- (Out to the garage doors' reach too.)
    local r = math.min(80.0, math.sqrt(hx * hx + hy * hy) + GARAGE_NEAR_SPACE + 2.0)
    checkKnown(d.candidates, cx, cy, cz, r)
    d.scanned = true
    return true, added
end

-- ============================================
-- Doors: the in-world picker
-- ============================================
--
-- THE DOOR ITSELF LIGHTS UP: every candidate's leaf is washed in its role's colour on both faces, edged in
-- it, and the one aimed at also wears the white outline. Drawn on the door as it stands (open or
-- shut), or where it was found when it is not streamed in. Aim at one (or Tab to it) and E turns its
-- role round — none, entrance, lockable, garage — and L pairs it with the last door L was pressed on
-- (the two leaves of a double door).
--
-- ANY DOOR, ANYWHERE, BY HAND: G adds the door the camera looks at, whatever the scan found: a garage door, a gate, a door
-- out past the space. Nothing is touched in the world: the doors are not opened, locked or made whip
-- doors until Save.

local ROLE_CYCLE = { 'none', 'entrance', 'lockable', 'garage' }
local ROLE_NAME = { none = 'Not this unit\'s', entrance = 'Entrance', lockable = 'Inner door, locked',
                    interior = 'Inner door, not locked', garage = 'Garage door' }
local ROLE_RGB = {
    none     = { 180, 180, 190 },
    entrance = { 74, 222, 128 },
    lockable = { 96, 165, 250 },
    interior = { 148, 163, 184 },
    garage   = { 251, 146, 60 },
    conflict = { 248, 113, 113 },
}

local function drawText3D(x, y, z, text)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, 0.3)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 235)
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

--- The candidate the camera looks at: nearest to the view ray, within 30 m and 0.9 m of it.
local function aimedCandidate()
    ---@cast draft -nil
    local cam = GetFinalRenderedCamCoord()
    local fx, fy, fz = InteractGetCameraForward()
    local best, bestD = nil, 0.9
    for i, c in ipairs(draft.candidates) do
        local p = c.body
        local vx, vy, vz = p.x - cam.x, p.y - cam.y, p.z - cam.z
        local t = vx * fx + vy * fy + vz * fz
        if t > 0 and t < 30.0 then
            local px, py, pz = vx - fx * t, vy - fy * t, vz - fz * t
            local dist = math.sqrt(px * px + py * py + pz * pz)
            if dist < bestD then best, bestD = i, dist end
        end
    end
    return best
end

-- The leaf's box, its object and its light: tools/door_leaf.lua, which the Door Editor (tools/zones.lua) draws
-- with too.

local function modelBox(model)
    return DoorLeaf.box(model)
end

--- The door's own object, to light it up: found by its model where it stood, and kept while it is
--- that door. Looked for again at most once a second while it is not there (not streamed in).
local function entityOf(c)
    return DoorLeaf.entity(c, c.model, c.world.x, c.world.y, c.world.z)
end

--- Light one door's leaf: a wash of `rgb` on each face and an edge round the front. On the object as it
--- stands, else where it was found.
local function drawLeaf(c, ent, rgb, fill, edge)
    DoorLeaf.draw(c.model, ent, c.world.x, c.world.y, c.world.z, c.worldHeading, rgb, fill, edge)
end

--- Add the door a player is looking at to the draft (G in the picker), as a door or, wide, a garage
--- door, and give it the role that kind usually has. Answers its number, and whether it is shaped
--- like a door at all (anything may be picked: whip's door system takes any model).
local function addPicked(ent)
    local d = draft --[[@as PropertyDraft]]
    local model = PropertyMath.signedHash(GetEntityModel(ent))
    local p = GetEntityCoords(ent)
    local wh = GetEntityHeading(ent)
    local shape = Interior.doorShape(model)
    local box = modelBox(model)
    local kind = shape or ((box and (box.mx.x - box.mn.x) > 1.7) and 'garage' or 'door')
    local world = { x = p.x, y = p.y, z = p.z }
    local lx, ly, lz = PropertyMath.toLocal(d.place, p.x, p.y, p.z)
    local c = {
        model = model, world = world, worldHeading = wh,
        pos = { x = lx, y = ly, z = lz }, heading = PropertyMath.headingToLocal(d.place, wh),
        body = doorBody(model, world, wh), kind = kind, source = 'picked', entity = ent,
    }
    d.candidates[#d.candidates + 1] = c
    setRole(c, kind == 'garage' and 'garage' or 'entrance')
    d.scanned = true
    -- Whose door it is already, if anybody's.
    CreateThread(function() checkKnown({ c }, p.x, p.y, p.z, 2.0) end)
    return #d.candidates, shape ~= nil
end

local function pickDoors()
    local d = draft --[[@as PropertyDraft]]
    -- No scan needed: a door can be added by hand here (G).
    if not d.place then return false, 'Choose the interior first' end
    local before = {}
    for i, c in ipairs(d.candidates) do before[i] = { role = c.role, lock = c.lock, key = c.key, pairWith = c.pairWith } end

    ---@type integer|nil, integer, integer|nil
    local focus, tabFocus, pairFrom = nil, 1, nil
    -- What the camera looks at: an asynchronous ray each frame, read the next (objects and the world,
    -- so a door behind a wall is not taken). The object hit, or 0.
    local probe, aimedEnt = nil, 0
    -- The door wearing the white outline (DoorLeaf.outliner: one at a time).
    local outline = DoorLeaf.outliner().set

    --- The candidate this object is, or nil (learning its object, when found by model and place).
    local function candidateOf(ent)
        if not ent or ent == 0 then return nil end
        for i, c in ipairs(d.candidates) do
            if c.entity == ent then return i end
        end
        local m = PropertyMath.signedHash(GetEntityModel(ent))
        local p = GetEntityCoords(ent)
        for i, c in ipairs(d.candidates) do
            local dx, dy, dz = c.world.x - p.x, c.world.y - p.y, c.world.z - p.z
            if PropertyMath.signedHash(c.model) == m and dx * dx + dy * dy + dz * dz < 0.25 then
                c.entity = ent
                return i
            end
        end
        return nil
    end

    -- THE HOUSE CARD: html/js/editor-hud.js `house`.
    -- What the card says: the door aimed at and its role as the chip, the counts, and every key with
    -- its pad button beside it — the house rules: a mode's E is A, its C is B; ☰ is Done, as in the
    -- furnisher. Device-neutral words in the status strip: the card shows the keys.
    local function pickCard()
        local counts = { entrance = 0, lockable = 0, garage = 0, interior = 0 }
        for _, c in ipairs(d.candidates) do
            local r = uiRole(c)
            if counts[r] then counts[r] = counts[r] + 1 end
        end
        local n = #d.candidates
        local f = focus and d.candidates[focus]
        local sub
        if pairFrom then sub = ('Pairing door %d: now its other leaf'):format(pairFrom)
        elseif f then sub = ('Door %d of %d'):format(focus, n)
        elseif n == 0 then sub = 'No doors yet: aim at one and add it'
        else sub = 'Aim at a door' end
        ---@type table|false
        local chip = false   -- false, not nil: an update merges, and a missing chip would keep the last one
        if f then
            local role = uiRole(f)
            chip = { text = f.conflict and 'Taken' or ROLE_NAME[role],
                     tone = f.conflict and 'err' or (role == 'entrance' and 'ok' or nil) }
        end
        local aimedNew = aimedEnt ~= 0 and candidateOf(aimedEnt) == nil
        return {
            house = true, icon = 'door', title = 'Doors', sub = sub, chip = chip,
            rows = {
                { label = 'Property', value = d.name or 'New property' },
                { label = 'Doors', value = n },
                { label = 'Entrances', value = counts.entrance, tone = counts.entrance > 0 and 'ok' or 'warn' },
                { label = 'Locked inner', value = counts.lockable },
                { label = 'Garage', value = counts.garage },
                { label = 'This one', value = f and (f.conflict and ('belongs to ' .. f.conflict)
                    or f.pairWith and ('paired with door %d'):format(f.pairWith) or 'not paired') or '—',
                  tone = f and f.conflict and 'err' or nil },
            },
            hints = {
                { key = Interactions.keyName(), pad = 'a', text = 'Change its role', off = not f },   -- the Interact key (WhipAcceptJustPressed)
                { key = 'G', pad = 'x', text = 'Add the door you aim at', off = not aimedNew },
                { key = 'L', pad = 'y', off = not f or pairFrom == focus,
                  text = f and f.pairWith and 'Unpair' or pairFrom and 'Pair with this leaf' or 'Pair two leaves' },
                { key = 'Tab', pad = 'rb', text = 'Next door', off = n == 0 },
                { key = 'Enter', pad = 'menu', text = 'Done' },
                { key = 'C', pad = 'b', text = 'Undo these changes' },
            },
        }
    end

    -- ON A PAD, held off while it drives: ☰ (199: the block naming it makes the pause menu stand aside,
    -- as the furnisher's does), X's jump (22) and Y's getting into a vehicle (23). A keyboard keeps them.
    local PAD_BLOCK = 'pwPickPad'
    local padHeld = false
    local function holdPad(on)
        if on == padHeld then return end
        padHeld = on
        if on then ControlBlocks.hold(PAD_BLOCK, { controls = { 199, 22, 23 } }) else ControlBlocks.release(PAD_BLOCK) end
    end

    local started = PropertyEditor.start({
        name = 'Pick doors',
        solo = 'pe_doors',
        hud = pickCard(),
        onExit = function()
            holdPad(false)
            outline(nil)
            PropertyWizard.push()
        end,
        -- Held off for the mode by its block. C (26) too, the cancel, or it swings the camera round as
        -- well; read with the disabled reader.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 44, 45, 47, 140, 141, 142, 182, 201, 18, 257, 263, 264 } },
        onFrame = (function()
            local nextHud = 0
            -- THE KEYS, ON THE DEVICE IN HAND ONLY. A pad's buttons are frontend controls (A 201, B 202,
            -- X 203, Y 204, RB 206, ☰ 199) that are keys on a keyboard too (Enter, Space, E...), and the
            -- keyboard's are buttons on a pad (Tab and E are LB, G is D-pad left, C is R3): read
            -- together, LB on a pad changed a role AND stepped to the next door, and A was Done.
            -- LB + anything is LB's (WhipPadModHeld), never the mode's.
            local pad = false
            local pressed = WhipKeyPressed
            return function()
                pad = WhipLastInputIsPad()
                holdPad(pad)

                -- The ray: last frame's answer read, this frame's sent.
                if probe then
                    local status, hit, _, _, ent = GetShapeTestResult(probe)
                    if status ~= 1 then
                        probe = nil
                        aimedEnt = ((hit == 1 or hit == true) and ent and ent ~= 0 and GetEntityType(ent) == 3) and ent or 0
                    end
                end
                if not probe then
                    local cam = GetFinalRenderedCamCoord()
                    local fx, fy, fz = InteractGetCameraForward()
                    probe = StartShapeTestLosProbe(cam.x, cam.y, cam.z, cam.x + fx * 40.0, cam.y + fy * 40.0,
                        cam.z + fz * 40.0, 1 + 16, PlayerPedId(), 7)
                end

                -- The door aimed at: the one the ray hits, else the nearest to the line of sight.
                focus = candidateOf(aimedEnt) or aimedCandidate() or tabFocus
                if pressed(37, 206) and #d.candidates > 0 then
                    tabFocus = (focus or 0) % #d.candidates + 1
                    focus = tabFocus
                end

                -- G (X): the door the camera looks at, added whatever the scan found.
                if pressed(47, 203) then
                    local known = candidateOf(aimedEnt)
                    if aimedEnt == 0 then
                        EditorHud.status('Aim at a door first', 'err')
                    elseif known then
                        focus, tabFocus = known, known
                        EditorHud.status(('That is door %d already'):format(known), 'ok')
                    else
                        local n, doorLike = addPicked(aimedEnt)
                        focus, tabFocus = n, n
                        EditorHud.status(doorLike and ('Added as door %d'):format(n)
                            or ('Added as door %d. It is not shaped like a door: make sure it opens'):format(n),
                            doorLike and 'ok' or 'warn')
                    end
                end

                local c = focus and d.candidates[focus]
                if c and WhipAcceptJustPressed() then
                    local now = uiRole(c)
                    local nextRole = 'entrance'
                    for i, r in ipairs(ROLE_CYCLE) do
                        if r == now then nextRole = ROLE_CYCLE[i % #ROLE_CYCLE + 1] end
                    end
                    setRole(c, nextRole)
                    tabFocus = focus
                end
                if c and pressed(182, 204) then
                    if c.pairWith then
                        unpair(c)
                        pairFrom = nil
                        EditorHud.status('Unpaired', 'ok')
                    elseif pairFrom and pairFrom ~= focus then
                        local o = d.candidates[pairFrom]
                        if o then
                            unpair(o)
                            o.pairWith, c.pairWith = focus, pairFrom
                            if not o.role then setRole(o, uiRole(c) ~= 'none' and uiRole(c) or 'entrance') end
                            if not c.role then setRole(c, uiRole(o)) end
                            EditorHud.status('Paired — the two open and lock together', 'ok')
                        end
                        pairFrom = nil
                    else
                        pairFrom = focus
                        EditorHud.status('Now pair it with the other leaf', 'info')
                    end
                end

                -- Each door lit in its role's colour (a quiet wash when it is not this unit's), the
                -- aimed one brighter and outlined white, the pair lines, and a label on the aimed one.
                local cam = GetFinalRenderedCamCoord()
                local focusEnt = nil
                for i, cand in ipairs(d.candidates) do
                    local b = cand.body
                    local dx, dy, dz = b.x - cam.x, b.y - cam.y, b.z - cam.z
                    if dx * dx + dy * dy + dz * dz < 120.0 * 120.0 then
                        local role = uiRole(cand)
                        local rgb = cand.conflict and ROLE_RGB.conflict or ROLE_RGB[role]
                        local isFocus = i == focus
                        local ent = entityOf(cand)
                        if isFocus then focusEnt = ent end
                        local fill = isFocus and 120 or (role == 'none' and 35 or 70)
                        local edge = isFocus and 255 or (role == 'none' and 90 or 200)
                        drawLeaf(cand, ent, rgb, fill, edge)
                        local o = cand.pairWith and d.candidates[cand.pairWith]
                        if o and cand.pairWith > i then
                            DrawLine(b.x, b.y, b.z, o.body.x, o.body.y, o.body.z, 255, 255, 255, 200)
                        end
                        if isFocus then
                            drawText3D(b.x, b.y, b.top + 0.3, ('%d · %s%s'):format(i, ROLE_NAME[role],
                                cand.conflict and ('  (' .. cand.conflict .. ')') or ''))
                        end
                    end
                end
                outline(focusEnt)

                local now = GetGameTimer()
                if now >= nextHud then
                    nextHud = now + 200
                    EditorHud.update(pickCard())
                end

                -- Done: Enter on a keyboard (201, or 18), ☰ on a pad. Undo: the mode's C, B on a pad.
                if pad then
                    if pressed(nil, 199) then return 'exit' end
                elseif IsDisabledControlJustPressed(0, 201) or IsDisabledControlJustPressed(0, 18) then
                    return 'exit'
                end
                if WhipCancelJustPressed() then
                    -- The doors added by hand this time go again; the rest get their roles back.
                    for i = #d.candidates, #before + 1, -1 do table.remove(d.candidates, i) end
                    for i, b in ipairs(before) do
                        local cand = d.candidates[i]
                        if cand then cand.role, cand.lock, cand.key, cand.pairWith = b.role, b.lock, b.key, b.pairWith end
                    end
                    return 'exit'
                end
            end
        end)(),
    })
    return started
end

-- ============================================
-- Space: drawing it
-- ============================================
--
-- Aim at the floor and press E for each corner. Three ways to draw, R to change:
--
--   rect   two opposite corners, square to the interior (Mega's premium flats)
--   edge   two corners along one wall, then a third click for how deep: a rectangle at any angle
--          (Mega's basic studios are built 20 degrees off their own interior, the probe found)
--   poly   corner by corner, Enter to close it: anything else
--
-- The floor is the lowest corner clicked; the wheel sets how high the space goes.

local DRAW_KINDS = { 'rect', 'edge', 'poly' }
local DRAW_TEXT = { rect = 'Rectangle, square to the interior', edge = 'Rectangle along a wall',
                    poly = 'Outline, corner by corner' }
local DRAW_NEEDS = { rect = 2, edge = 3 }

--- The local shape these world points make, or nil while they do not make one yet.
local function shapeFrom(kind, pts, height)
    ---@cast draft -nil
    local P = draft.place --[[@as table]]   -- drawSpace checked it
    if #pts == 0 then return nil end
    local L, floorZ = {}, math.huge
    for i, p in ipairs(pts) do
        local lx, ly, lz = PropertyMath.toLocal(P, p.x, p.y, p.z)
        L[i] = { x = lx, y = ly }
        if lz < floorZ then floorZ = lz end
    end
    if kind == 'rect' then
        if #L < 2 then return nil end
        local a, b = L[1], L[2]
        local sx, sy = math.abs(b.x - a.x), math.abs(b.y - a.y)
        if sx < 0.2 or sy < 0.2 then return nil end
        return { type = 'box', center = { x = (a.x + b.x) * 0.5, y = (a.y + b.y) * 0.5, z = floorZ + height * 0.5 },
                 size = { x = sx, y = sy, z = height }, heading = 0.0 }
    elseif kind == 'edge' then
        if #L < 3 then return nil end
        local a, b, c = L[1], L[2], L[3]
        local ex, ey = b.x - a.x, b.y - a.y
        local len = math.sqrt(ex * ex + ey * ey)
        if len < 0.2 then return nil end
        local ux, uy = ex / len, ey / len
        local nx, ny = -uy, ux
        local depth = (c.x - a.x) * nx + (c.y - a.y) * ny
        if math.abs(depth) < 0.2 then return nil end
        return {
            type = 'box',
            center = { x = a.x + ex * 0.5 + nx * depth * 0.5, y = a.y + ey * 0.5 + ny * depth * 0.5, z = floorZ + height * 0.5 },
            size = { x = len, y = math.abs(depth), z = height },
            heading = math.deg(math.atan(uy, ux)) % 360.0,
        }
    end
    if #L < 3 then return nil end
    local points = {}
    for i, p in ipairs(L) do points[i] = { x = p.x, y = p.y } end
    return { type = 'poly', points = points, minZ = floorZ, maxZ = floorZ + height }
end

local function previewDrawn()
    ---@cast draft -nil
    ZonePreview.clearPrefix('pe:drawn:')
    for i, s in ipairs(draft.drawn) do
        local w = PropertyMath.shapeToWorld(draft.place, s)
        if w then ZonePreview.set('pe:drawn:' .. i, { w }, { name = 'current', label = i == 1 and (draft.name or 'This property') or nil }) end
    end
end

--- Does a world shape reach into another property? Its corners and middle are tested.
local function overlapsOther(w)
    ---@cast draft -nil
    local p = Shapes.prepare(w)
    if not p then return nil end
    local pts = p.type == 'box' and Shapes.boxCorners(p) or p.points
    local b = p._bbox
    local z = b.minZ + 0.5
    local test = { { x = (b.minX + b.maxX) * 0.5, y = (b.minY + b.maxY) * 0.5 } }
    for _, q in ipairs(pts) do
        -- Pulled a little towards the middle, so a wall shared with the next flat is not an overlap.
        test[#test + 1] = { x = q.x + (test[1].x - q.x) * 0.1, y = q.y + (test[1].y - q.y) * 0.1 }
    end
    for _, q in ipairs(test) do
        local other = propertyAt(q.x, q.y, z, draft.propertyId)
        if other then return other end
    end
    return nil
end

local function drawSpace()
    local d = draft --[[@as PropertyDraft]]
    if not d.place then return false, 'Choose the interior (or no interior) first' end
    local before = {}
    for i, s in ipairs(d.drawn) do before[i] = s end

    local kind, pts = 'rect', {}
    local hit, hx, hy, hz = false, 0.0, 0.0, 0.0
    local reach = 30.0

    local function inProgress()
        if not hit then return shapeFrom(kind, pts, d.drawHeight) end
        local with = copy(pts)
        with[#with + 1] = { x = hx, y = hy, z = hz }
        return shapeFrom(kind, with, d.drawHeight)
    end

    local function rows(overlap)
        local area = 0.0
        for _, s in ipairs(d.drawn) do area = area + Shapes.area(s) end
        return {
            { label = 'Drawing', value = DRAW_TEXT[kind] },
            { label = 'Corners', value = DRAW_NEEDS[kind] and ('%d / %d'):format(#pts, DRAW_NEEDS[kind]) or tostring(#pts) },
            { label = 'Height', value = ('%.2f m'):format(d.drawHeight) },
            { label = 'Shapes', value = ('%d  ·  %.1f m²'):format(#d.drawn, area), tone = #d.drawn > 0 and 'ok' or nil },
            { label = 'Overlaps', value = overlap and (overlap.name or ('#' .. overlap.id)) or 'nothing', tone = overlap and 'warn' or nil },
        }
    end

    local function finishShape()
        local s = shapeFrom(kind, pts, d.drawHeight)
        if not s then EditorHud.status('Those corners do not make a shape yet', 'warn') return end
        if #d.drawn >= MAX_SHAPES then EditorHud.status(('A space has at most %d shapes'):format(MAX_SHAPES), 'err') return end
        d.drawn[#d.drawn + 1] = s
        d.spaceKind = 'draw'
        pts = {}
        previewDrawn()
        EditorHud.status(('Shape %d added'):format(#d.drawn), 'ok')
    end

    local started = PropertyEditor.start({
        name = 'Draw space',
        solo = 'pe_draw',
        hud = {
            title = 'Draw the space', sub = d.name or 'New property',
            rows = rows(nil),
            hints = {
                { key = 'E', text = 'Corner here' },
                { key = 'R', text = 'Rectangle / along a wall / outline' },
                { key = 'Scroll', text = 'Height' },
                { key = 'X', text = 'Undo' },
                { key = 'Enter', text = 'Close the outline, or done' },
                { key = 'C', text = 'Throw away what you drew' },
                { key = 'Esc', text = 'Back' },
            },
        },
        onExit = function() PropertyWizard.push() end,
        -- Held off for the mode by its block. C (26) too.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 44, 45, 73, 140, 141, 142, 201, 18, 257, 263, 264 } },
        onFrame = (function()
            local nextHud, overlap = 0, nil
            return function()
                if IsDisabledControlJustPressed(0, 17) then d.drawHeight = math.min(20.0, d.drawHeight + 0.25)
                elseif IsDisabledControlJustPressed(0, 16) then d.drawHeight = math.max(1.0, d.drawHeight - 0.25) end
                if IsDisabledControlJustPressed(0, 45) then
                    for i, k in ipairs(DRAW_KINDS) do
                        if k == kind then kind = DRAW_KINDS[i % #DRAW_KINDS + 1] break end
                    end
                    pts = {}
                end

                local cam = GetFinalRenderedCamCoord()
                local fx, fy, fz = InteractGetCameraForward()
                local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * reach, cam.y + fy * reach,
                    cam.z + fz * reach, 1 + 16, PlayerPedId(), 0)
                local _, h, coords = GetShapeTestResult(ray)
                hit = h == 1
                if hit then hx, hy, hz = coords.x, coords.y, coords.z end

                if hit and IsControlJustPressed(0, 38) then
                    if #pts >= MAX_POINTS then
                        EditorHud.status(('An outline has at most %d corners'):format(MAX_POINTS), 'err')
                    else
                        pts[#pts + 1] = { x = hx, y = hy, z = hz }
                        if DRAW_NEEDS[kind] and #pts >= DRAW_NEEDS[kind] then finishShape() end
                    end
                end
                if IsDisabledControlJustPressed(0, 73) then
                    if #pts > 0 then
                        pts[#pts] = nil
                    elseif #d.drawn > 0 then
                        d.drawn[#d.drawn] = nil
                        previewDrawn()
                        EditorHud.status('Last shape removed', 'ok')
                    end
                end
                if IsDisabledControlJustPressed(0, 201) or IsDisabledControlJustPressed(0, 18) then
                    if kind == 'poly' and #pts >= 3 then
                        finishShape()
                    elseif #pts == 0 then
                        return 'exit'
                    else
                        EditorHud.status('Finish this shape first (X to undo its corners)', 'warn')
                    end
                end
                if IsDisabledControlJustPressed(0, 26) then
                    d.drawn = before
                    return 'exit'
                end

                -- What is being drawn, live.
                local s = inProgress()
                local w = s and PropertyMath.shapeToWorld(d.place, s)
                if w then ZonePreview.set('pe:draft', { w }, 'draft') else ZonePreview.clear('pe:draft') end
                for i, p in ipairs(pts) do
                    DrawMarker(28, p.x, p.y, p.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12,
                        250, 204, 21, 220, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                    local q = pts[i + 1] or (hit and { x = hx, y = hy, z = hz }) or nil
                    if q then DrawLine(p.x, p.y, p.z + 0.02, q.x, q.y, q.z + 0.02, 250, 204, 21, 220) end
                end
                if hit then
                    DrawMarker(28, hx, hy, hz, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.09, 0.09, 0.09,
                        255, 255, 255, 200, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                end

                local now = GetGameTimer()
                if now >= nextHud then
                    nextHud = now + 250
                    overlap = w and overlapsOther(w) or nil
                    if not overlap then
                        for _, done in ipairs(d.drawn) do
                            local dw = PropertyMath.shapeToWorld(d.place, done)
                            overlap = dw and overlapsOther(dw) or nil
                            if overlap then break end
                        end
                    end
                    EditorHud.update({ rows = rows(overlap) })
                end
            end
        end)(),
    })
    if not started then d.drawn = before return false end
    previewDrawn()
    showNeighbours()
    return true
end

-- ============================================
-- Garage: placing its bays
-- ============================================
--
-- The bays of the property's private garage, set out with the one bay tool every garage uses
-- (PropertyEditor.placeBays, tools/property_editor.lua): aim at the ground and the bay outline sits
-- there; aim at one already set out to move it or take it away. The draft keeps its bays in the
-- property's own space, so they go into the tool in the world and come back out of it. Nothing is
-- written until the property is saved.

local function placeBays()
    local d = draft --[[@as PropertyDraft]]
    if not d.place then return false, 'Choose the interior first' end
    local world = {}
    for i, b in ipairs(d.bays) do
        local bx, by, bz = PropertyMath.toWorld(d.place, b.pos.x, b.pos.y, b.pos.z)
        world[i] = { x = bx, y = by, z = bz, heading = PropertyMath.headingToWorld(d.place, b.heading) % 360.0 }
    end
    return PropertyEditor.placeBays({
        name = (d.name or 'New property') .. ' — private: its owner and keyholders',
        bays = world, max = MAX_BAYS,
        onDone = function(bays, undone)
            if not undone then
                -- A bay the tool did not move comes back exactly as it went in, and keeps the draft's own (a round
                -- trip through the world would nudge it by a rounding error, and Save would see a move).
                local back = {}
                for i, b in ipairs(bays) do
                    for j, w in ipairs(world) do
                        if w.x == b.x and w.y == b.y and w.z == b.z and w.heading == b.heading then back[i] = d.bays[j] break end
                    end
                    if not back[i] then
                        local lx, ly, lz = PropertyMath.toLocal(d.place, b.x, b.y, b.z)
                        back[i] = { pos = { x = lx, y = ly, z = lz }, heading = PropertyMath.headingToLocal(d.place, b.heading) }
                    end
                end
                d.bays = back
            end
            PropertyWizard.push()
        end,
    })
end

-- ============================================
-- Seeing it
-- ============================================

--- The draft in the world: its space blue, its doors as markers, its signs, the neighbours grey;
--- or (what = 'rooms') the interior's room boxes, each labelled. Nothing to edit.
local function showDraft(what)
    local d = draft --[[@as PropertyDraft]]
    if not d.place then return false, 'Choose the interior first' end
    local rooms = what == 'rooms'
    if rooms and not (d.rooms and #d.rooms > 0) then return false, 'No rooms were read from this interior' end

    local started = PropertyEditor.start({
        name = rooms and 'Show rooms' or 'Show draft',
        hud = {
            title = rooms and 'Rooms' or 'Space',
            sub = rooms and 'Every room the interior has — one box each' or (d.name or 'New property') .. ' — blue; its neighbours grey',
            rows = rooms and { { label = 'Rooms', value = #d.rooms } } or {
                { label = 'Doors', value = #unitDoors() },
                { label = 'Outside sign', value = d.sign and (d.sign.post and 'on a sign post' or 'placed') or 'not yet' },
                { label = 'Manager', value = d.manager and 'placed' or 'not yet' },
            },
            hints = { { key = 'Esc', text = 'Back to the panel' } },
        },
        onFrame = function()
            if rooms then return end
            for i, b in ipairs(d.bays) do
                local bx, by, bz = PropertyMath.toWorld(d.place, b.pos.x, b.pos.y, b.pos.z)
                if GarageBayDraw then
                    GarageBayDraw(bx, by, bz, PropertyMath.headingToWorld(d.place, b.heading), 0.8, { 120, 255, 140 })
                end
                drawText3D(bx, by, bz + 0.6, ('Bay %d'):format(i))
            end
            for _, c in ipairs(d.candidates) do
                if c.role then
                    local rgb = ROLE_RGB[uiRole(c)]
                    DrawMarker(0, c.body.x, c.body.y, c.body.top + 0.35, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.28, 0.28, 0.28,
                        rgb[1], rgb[2], rgb[3], 220, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                end
            end
            -- Each sign as a dot, with a line out the way it faces (towards whoever reads it).
            for _, part in ipairs({ 'sign', 'manager' }) do
                local s = d[part]
                if s then
                    local x, y, z = PropertyMath.toWorld(d.place, s.pos.x, s.pos.y, s.pos.z)
                    local h = math.rad(PropertyMath.headingToWorld(d.place, s.heading))
                    local r, g, b = 74, 222, 128
                    if part == 'manager' then r, g, b = 96, 165, 250 end
                    DrawMarker(28, x, y, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12,
                        r, g, b, 220, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                    DrawLine(x, y, z, x - math.sin(h) * 0.6, y + math.cos(h) * 0.6, z, r, g, b, 230)
                    drawText3D(x, y, z + 0.3, part == 'sign' and 'Outside sign' or 'Manager')
                end
            end
        end,
    })
    if not started then return false end

    if rooms then
        for i, r in ipairs(d.rooms) do
            local box = {
                type = 'box',
                center = { x = (r.min.x + r.max.x) * 0.5, y = (r.min.y + r.max.y) * 0.5, z = (r.min.z + r.max.z) * 0.5 },
                size = { x = r.max.x - r.min.x, y = r.max.y - r.min.y, z = r.max.z - r.min.z }, heading = 0.0,
            }
            local w = PropertyMath.shapeToWorld(d.place, box)
            local picked = d.spaceKind == 'rooms' and d.pickRooms[tostring(r.name):lower()]
            if w then ZonePreview.set('pe:room:' .. i, { w }, { name = picked and 'current' or 'other', label = r.name }) end
        end
    else
        local shapes = worldShapes()
        if #shapes > 0 then ZonePreview.set('pe:space', shapes, { name = 'current', label = d.name or 'This property' }) end
        showNeighbours()
    end
    return true
end

-- ============================================
-- Signs
-- ============================================

--- Where the signs would go by the first entrance: the outside one beside the door at eye
--- height, facing out; the manager just inside it, facing in. Which side is out is the side of
--- the door that is not in the space.
local function suggestSign(which)
    local d = draft --[[@as PropertyDraft]]
    local door = firstEntrance()
    if not door then return false, 'Pick an entrance door first — the suggestion goes beside it' end
    local shapes = worldShapes()
    local b = door.body
    local h = math.rad(door.worldHeading or 0.0)
    local fx, fy = -math.sin(h), math.cos(h)
    local inFront = Shapes.containsAny(shapes, b.x + fx, b.y + fy, b.z, 0.0)
    local behind = Shapes.containsAny(shapes, b.x - fx, b.y - fy, b.z, 0.0)
    local ox, oy
    if behind and not inFront then ox, oy = fx, fy
    elseif inFront and not behind then ox, oy = -fx, -fy
    else
        -- Cannot tell from the space: away from its middle.
        local bb = Shapes.bbox(shapes)
        local mx, my = bb and (bb.minX + bb.maxX) * 0.5 or b.x, bb and (bb.minY + bb.maxY) * 0.5 or b.y
        if (b.x - mx) * fx + (b.y - my) * fy >= 0 then ox, oy = fx, fy else ox, oy = -fx, -fy end
    end
    local rx, ry = oy, -ox                     -- to the right, looking out
    local side = (b.width or 1.0) * 0.5 + 0.35
    local eye = b.bottom + 1.55

    local x, y, heading
    if which == 'sign' then
        x, y = b.x + ox * 0.25 + rx * side, b.y + oy * 0.25 + ry * side
        heading = math.deg(math.atan(-ox, oy)) % 360.0            -- read from outside
    else
        x, y = b.x - ox * 0.6 + rx * side, b.y - oy * 0.6 + ry * side
        heading = math.deg(math.atan(ox, -oy)) % 360.0            -- read from inside
    end
    local lx, ly, lz = PropertyMath.toLocal(d.place, x, y, eye)
    d[which] = { pos = { x = lx, y = ly, z = lz }, heading = PropertyMath.headingToLocal(d.place, heading) }
    return true
end

local function placeSign(which)
    local d = draft --[[@as PropertyDraft]]
    if not d.place then return false, 'Choose the interior first' end
    local current = d[which]
    local start = nil
    if current then
        local x, y, z = PropertyMath.toWorld(d.place, current.pos.x, current.pos.y, current.pos.z)
        start = { x = x, y = y, z = z, heading = PropertyMath.headingToWorld(d.place, current.heading) }
    end
    local ok = PropertyEditor.aimSign({
        name = d.name or 'New property',
        what = which == 'sign' and 'Outside sign' or 'Manager',
        forText = d.mode == 'new' and 'the new property' or (d.name or 'this property'),
        start = start,
        onPlaced = function(x, y, z, heading)
            if not draft then return end
            local lx, ly, lz = PropertyMath.toLocal(draft.place, x, y, z)
            draft[which] = { pos = { x = lx, y = ly, z = lz }, heading = PropertyMath.headingToLocal(draft.place, heading) }
        end,
    })
    if not ok then return false, 'Could not start placing' end
    -- aimSign's own mode ends it; the page learns the result when the panel comes back.
    CreateThread(function()
        while PropertyEditor.isActive() do Wait(100) end
        if draft then PropertyWizard.push() end
    end)
    return true
end

--- The outside sign on a sign post (Config.PropertySignPosts; PropertyEditor.placeSignPost): kept as every sign is,
--- the prompt's spot, with the post's model. Put up again, it starts as the one there and turned as it was.
local function placeSignPost()
    local d = draft --[[@as PropertyDraft]]
    if not d.place then return false, 'Choose the interior first' end
    local cur = d.sign
    local post = cur and PropertyMath.signPost(cur.post)
    local heading = cur and post and select(4, PropertyMath.promptToPost(post, 0.0, 0.0, 0.0,
        PropertyMath.headingToWorld(d.place, cur.heading))) or nil
    local ok = PropertyEditor.placeSignPost({
        name = d.name or 'New property',
        forText = d.mode == 'new' and 'the new property' or (d.name or 'this property'),
        model = post and post.model or nil,
        heading = heading,
        -- Its board as far as the draft knows it: the price is the last step's.
        listing = { name = d.name or 'New property', bays = #d.bays },
        onPlaced = function(model, x, y, z, h)
            if not draft then return end
            local lx, ly, lz = PropertyMath.toLocal(draft.place, x, y, z)
            draft.sign = { pos = { x = lx, y = ly, z = lz }, heading = PropertyMath.headingToLocal(draft.place, h),
                           post = model }
        end,
    })
    if not ok then return false, 'Could not start placing' end
    -- The mode ends itself; the page learns the result when the panel comes back.
    CreateThread(function()
        while PropertyEditor.isActive() do Wait(100) end
        if draft then PropertyWizard.push() end
    end)
    return true
end

-- ============================================
-- Save
-- ============================================

local saveTimer = 0

--- The page's form, and the draft, as what the server is sent.
local function save(form)
    local d = draft --[[@as PropertyDraft]]
    if d.saving then return false, 'Saving already' end
    form = type(form) == 'table' and form or {}

    if d.mode == 'new' then
        if not d.place then return false, 'Choose the interior first' end
        local settings = {
            price = tonumber(form.price), maxObjects = tonumber(form.maxObjects),
            autolock = form.autolock == true, autolockDelay = tonumber(form.autolockDelay),
        }
        TriggerServerEvent('whip_core:server:propertyAdminSave', {
            place = d.place, rooms = d.rooms, fingerprint = d.fingerprint,
            space = localSpace(), doors = unitDoors(), sign = d.sign, manager = d.manager, visit = d.visit,
            garage = #d.bays > 0 and { bays = d.bays } or nil,
            name = form.name, label = form.label, building = form.building,
            settings = settings, ownerCharId = tonumber(form.ownerCharId),
            -- Its look, when its interior has looks (draft.known.themes; server/property_themes.lua).
            theme = tonumber(form.theme),
        })
    elseif d.part == 'interior' then
        local r = d.reading
        if not r then return false, 'Stand inside the interior and read it again' end
        -- With its layout as read here: the server takes it for the template when it has changed.
        TriggerServerEvent('whip_core:server:propertyAdminRebind', d.propertyId, r.place,
            { rooms = r.rooms, fingerprint = { rooms = r.roomCount, portals = r.portalCount } })
    else
        -- The doors step starts empty (PropertyWizard.edit): saved before a scan, it would take every
        -- door away.
        if d.part == 'doors' and not d.scanned then return false, 'Scan for the doors first' end
        local scope = form.scope == 'unit' and 'unit' or 'property'
        local value
        if d.part == 'space' then value = localSpace()
        elseif d.part == 'doors' then value = unitDoors()
        -- No bays is "no garage" (false), which also takes an existing one away.
        elseif d.part == 'garage' then value = #d.bays > 0 and { bays = d.bays } or false
        else value = d.visit end
        TriggerServerEvent('whip_core:server:propertyAdminSavePart', d.propertyId, d.part, scope, value)
    end

    d.saving = true
    saveTimer = saveTimer + 1
    local mine = saveTimer
    SetTimeout(10000, function()
        if draft and draft.saving and saveTimer == mine then
            draft.saving = false
            PropertyWizard.push()
            sayResult(false, 'No answer from the server — try again')
        end
    end)
    return true
end

RegisterNetEvent('whip_core:client:propertyAdminSaved', function(ok, idOrWhy)
    if draft then draft.saving = false end
    if ok then
        draft = nil
        ZonePreview.clearPrefix('pe:')
    end
    PropertyWizard.push()
    sayResult(ok, idOrWhy)
end)

-- ============================================
-- The page's buttons
-- ============================================
--
-- Each answers { ok, why? } and then pushes the draft, so the page always shows what the draft
-- is rather than what it asked for.

local function answer(cb, ok, why)
    cb({ ok = ok ~= false, why = why })
    if draft then PropertyWizard.push() end
end

local function needDraft(cb)
    if draft then return true end
    cb({ ok = false, why = 'There is no property being set up' })
    return false
end

RegisterNUICallback('pwStart', function(_, cb)
    PropertyWizard.start()
    cb({ ok = true })
end)

RegisterNUICallback('pwEdit', function(data, cb)
    local id = tonumber(data and data.id)
    local part = data and data.part
    if not id or (part ~= 'interior' and part ~= 'space' and part ~= 'doors' and part ~= 'garage') then
        cb({ ok = false, why = 'Nothing to edit' })
        return
    end
    -- Opened: `why` is then what Re-bind read straight away (bad = a different interior), for the page to say.
    local ok, why, bad = PropertyWizard.edit(id, part, part == 'doors' and data.add == true)
    cb({ ok = ok, why = why, bad = bad == true })
end)

RegisterNUICallback('pwCancel', function(_, cb)
    PropertyWizard.cancel()
    cb({ ok = true })
end)

RegisterNUICallback('pwState', function(_, cb)
    cb(summary())
end)

RegisterNUICallback('pwReadInterior', function(_, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    -- A read that worked says so (Re-bind: what it found, rebindNote); one that did not says why.
    local note, bad = readInterior()
    if not draft then answer(cb, false, 'The wizard was closed') return end
    if not draft.reading then answer(cb, false, draft.readWhy) return end
    answer(cb, not bad, note)
end)

RegisterNUICallback('pwUseWorld', function(_, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    if draft.mode ~= 'new' then answer(cb, false, 'Only a new property can change its interior') return end
    useWorld()
    answer(cb, true)
end)

RegisterNUICallback('pwSpace', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local kind = data and data.kind
    if kind ~= 'interior' and kind ~= 'rooms' and kind ~= 'draw' then answer(cb, false, 'Unknown space') return end
    if kind ~= 'draw' and not (draft.rooms and #draft.rooms > 0) then
        answer(cb, false, 'This interior\'s rooms are not known — draw the area')
        return
    end
    draft.spaceKind = kind
    answer(cb, true)
end)

RegisterNUICallback('pwRoom', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local name = data and tostring(data.name or ''):lower()
    if name == '' then answer(cb, false) return end
    draft.pickRooms[name] = not draft.pickRooms[name] or nil
    draft.spaceKind = 'rooms'
    answer(cb, true)
end)

RegisterNUICallback('pwDraw', function(_, cb)
    if not needDraft(cb) then return end
    local ok, why = drawSpace()
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwDrawRemove', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local i = tonumber(data and data.i)
    if i and draft.drawn[i] then table.remove(draft.drawn, i) end
    answer(cb, true)
end)

RegisterNUICallback('pwVisit', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    if data and data.clear then
        draft.visit = nil
    else
        if not draft.place then answer(cb, false, 'Choose the interior first') return end
        local c = GetEntityCoords(PlayerPedId())
        local lx, ly, lz = PropertyMath.toLocal(draft.place, c.x, c.y, c.z - 0.5)
        draft.visit = { x = lx, y = ly, z = lz }
    end
    answer(cb, true)
end)

RegisterNUICallback('pwShow', function(data, cb)
    if not needDraft(cb) then return end
    local ok, why = showDraft(data and data.what)
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwDoorsScan', function(_, cb)
    if not needDraft(cb) then return end
    local ok, res = scanDoors()
    if not ok then answer(cb, false, res) return end
    answer(cb, true, res == 0 and 'No new doors found' or ('%d door%s found'):format(res, res == 1 and '' or 's'))
end)

RegisterNUICallback('pwDoorSet', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local c = draft.candidates[tonumber(data and data.i) or -1]
    local role = data and data.role
    local valid = { none = true, entrance = true, lockable = true, interior = true, garage = true }
    if not c or not valid[role] then answer(cb, false) return end
    setRole(c, role)
    answer(cb, true)
end)

RegisterNUICallback('pwDoorPair', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local i, j = tonumber(data and data.i), tonumber(data and data.j)
    local a = draft.candidates[i or -1]
    if not a then answer(cb, false) return end
    unpair(a)
    local b = j and draft.candidates[j]
    if b and b ~= a then
        unpair(b)
        a.pairWith, b.pairWith = j, i
        if not b.role and a.role then setRole(b, uiRole(a)) end
    end
    answer(cb, true)
end)

RegisterNUICallback('pwDoorsPick', function(_, cb)
    if not needDraft(cb) then return end
    local ok, why = pickDoors()
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwSignSuggest', function(data, cb)
    if not needDraft(cb) then return end
    local which = data and data.which == 'manager' and 'manager' or 'sign'
    local ok, why = suggestSign(which)
    answer(cb, ok, why)
end)

RegisterNUICallback('pwSignPlace', function(data, cb)
    if not needDraft(cb) then return end
    local which = data and data.which == 'manager' and 'manager' or 'sign'
    local ok, why = placeSign(which)
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwSignPost', function(_, cb)
    if not needDraft(cb) then return end
    local ok, why = placeSignPost()
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwSignClear', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local which = data and data.which == 'manager' and 'manager' or 'sign'
    draft[which] = nil
    answer(cb, true)
end)

RegisterNUICallback('pwBays', function(_, cb)
    if not needDraft(cb) then return end
    local ok, why = placeBays()
    cb({ ok = ok ~= false, why = why })
end)

RegisterNUICallback('pwBayRemove', function(data, cb)
    if not needDraft(cb) then return end
    ---@cast draft -nil
    local i = tonumber(data and data.i)
    if i and draft.bays[i] then table.remove(draft.bays, i) end
    answer(cb, true)
end)

RegisterNUICallback('pwSave', function(data, cb)
    if not needDraft(cb) then return end
    local ok, why = save(data)
    answer(cb, ok, why)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if draft then log('resource stopping with a property half set up; the draft is lost') end
end)
