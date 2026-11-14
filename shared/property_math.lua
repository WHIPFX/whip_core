-- ============================================
-- PROPERTY MATH — Interior-local to world, shared
-- ============================================
--
-- THE IDEA THE PROPERTIES SYSTEM IS BUILT ON. An MLO's rooms, portals and doors are authored in
-- the interior's OWN space, and every placement of the same interior carries the same data. So a
-- unit — an apartment's space, its doors, its entry sign — is described once, relative to the
-- interior, and every placement of that interior is the same description moved and turned.
--
-- A PLACEMENT is where one copy of an interior stands:
--
--     place = { x, y, z, yaw }      yaw in degrees, GTA heading convention
--
-- and that is ALL the runtime needs. No interior native is called to draw a sign, check a door or
-- bound furniture — this is pure arithmetic, identical on the server and the client, so both agree
-- to the centimetre and neither has to wait for an interior to stream in. The natives are used only
-- where a placement is CAPTURED (the Configurator) or CHECKED (Verify).
--
-- THE CONVENTION, worked once so nothing downstream has to think about it:
--
--     GTA heading h faces (-sin h, cos h): 0 is north (+Y), 90 is west. It grows anticlockwise.
--     A placement turned by yaw carries its local +Y axis to heading `yaw`, and its local +X axis
--     to (cos yaw, sin yaw). So:
--
--         world.x = x + lx*cos(yaw) - ly*sin(yaw)
--         world.y = y + lx*sin(yaw) + ly*cos(yaw)
--         world.z = z + lz
--
--     and a local heading h becomes world heading yaw + h. That is also the zone system's box
--     convention (shared/shapes.lua), so a local box becomes a world box by moving its centre and
--     adding yaw to its heading.
--
-- YAW ONLY. Interiors tilted off the vertical are refused where a placement is captured; nothing
-- here tries to handle pitch or roll.

PropertyMath = {}

local rad, cos, sin, sqrt, floor = math.rad, math.cos, math.sin, math.sqrt, math.floor
local TWO32, TWO31 = 4294967296, 2147483648

--- A model or archetype hash in the SIGNED form GetEntityModel returns.
---
--- WHY THIS MATTERS. Door records match world objects by `door.model == GetEntityModel(entity)`,
--- and GetEntityModel answers signed. The map packs write their door lists unsigned — 2455748208
--- where the game says -1839219088 — so a door created from a pack's number would never match its
--- own object. Everything that stores a hash goes through here first.
---
--- A NAME IS HASHED, a numeric string is read as a number, and anything else is refused.
---@param h number|string|nil
---@return integer|nil
function PropertyMath.signedHash(h)
    if type(h) == 'string' then
        if h:match('^%-?%d+$') then
            h = tonumber(h)
        elseif h ~= '' then
            h = GetHashKey(h)
        else
            return nil
        end
    end
    if type(h) ~= 'number' or h ~= h or h == math.huge or h == -math.huge then return nil end
    h = floor(h) % TWO32
    if h >= TWO31 then h = h - TWO32 end
    return math.tointeger(h) or h
end

--- Local to world.
---@param place table { x, y, z, yaw }
---@return number x, number y, number z
function PropertyMath.toWorld(place, lx, ly, lz)
    local t = rad(place.yaw or 0.0)
    local c, s = cos(t), sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + (lz or 0.0)
end

--- World to local — the exact inverse of toWorld.
---@param place table { x, y, z, yaw }
---@return number lx, number ly, number lz
function PropertyMath.toLocal(place, wx, wy, wz)
    local t = rad(place.yaw or 0.0)
    local c, s = cos(t), sin(t)
    local dx, dy = wx - place.x, wy - place.y
    return dx * c + dy * s, -dx * s + dy * c, (wz or place.z) - place.z
end

--- A local heading as a world heading, 0..360.
function PropertyMath.headingToWorld(place, h)
    return ((place.yaw or 0.0) + (h or 0.0)) % 360.0
end

--- A world heading as a local heading, 0..360.
function PropertyMath.headingToLocal(place, h)
    return ((h or 0.0) - (place.yaw or 0.0)) % 360.0
end

--- The smallest signed difference between two headings, -180..180.
function PropertyMath.angleDelta(a, b)
    local d = (a - b) % 360.0
    if d > 180.0 then d = d - 360.0 end
    return d
end

--- Are two placements the same copy of the same interior?
---
--- Within half a metre and a degree: far finer than two placements ever stand apart, and far
--- coarser than the float noise the same placement reads back with between sessions.
---@param a table { hash?, x, y, z, yaw }
---@param b table
---@param posTol number|nil  default 0.5
---@param yawTol number|nil  default 1.0
---@return boolean, number distance, number yawDelta
function PropertyMath.samePlacement(a, b, posTol, yawTol)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    local d = sqrt(dx * dx + dy * dy + dz * dz)
    local dy_ = math.abs(PropertyMath.angleDelta(a.yaw or 0.0, b.yaw or 0.0))
    local sameHash = (a.hash == nil or b.hash == nil or a.hash == b.hash)
    return sameHash and d <= (posTol or 0.5) and dy_ <= (yawTol or 1.0), d, dy_
end

-- ============================================
-- Spaces
-- ============================================

--- Concrete local shapes for a unit's space.
---
--- A space can be SYMBOLIC — "the whole interior", or "these named rooms" — and those need the
--- template's room boxes, which only a client standing in the interior can read. Until the template
--- has them, the space is unresolved: the caller learns that from the second return and treats the
--- unit accordingly (the server refuses to furnish it).
---@param space table   list of local shapes: box | poly | { type='interior' } | { type='rooms', rooms={names} }
---@param rooms table|nil  template rooms: { { name, min={x,y,z}, max={x,y,z} }, ... }
---@return table shapes, boolean unresolved
function PropertyMath.expandSpace(space, rooms)
    local out, unresolved = {}, false

    local function roomBox(r)
        local mn, mx = r.min, r.max
        out[#out + 1] = {
            type = 'box',
            center = { x = (mn.x + mx.x) * 0.5, y = (mn.y + mx.y) * 0.5, z = (mn.z + mx.z) * 0.5 },
            size = { x = mx.x - mn.x, y = mx.y - mn.y, z = mx.z - mn.z },
            heading = 0.0,
        }
    end

    for _, s in ipairs(space or {}) do
        if s.type == 'box' or s.type == 'poly' then
            out[#out + 1] = s
        elseif s.type == 'interior' or s.type == 'rooms' then
            if type(rooms) ~= 'table' or #rooms == 0 then
                unresolved = true
            else
                local want = nil
                if s.type == 'rooms' then
                    want = {}
                    for _, n in ipairs(s.rooms or {}) do want[tostring(n):lower()] = true end
                end
                for _, r in ipairs(rooms) do
                    -- Limbo is the outside world; it is never part of anybody's home.
                    local name = tostring(r.name or ''):lower()
                    if name ~= 'limbo' and r.min and r.max and (not want or want[name]) then
                        roomBox(r)
                    end
                end
            end
        end
    end
    return out, unresolved
end

--- A local box or poly as a world shape (not yet prepared — see Shapes.prepare).
---@return table|nil
function PropertyMath.shapeToWorld(place, shape)
    if shape.type == 'box' then
        local c = shape.center or shape.pos
        local x, y, z = PropertyMath.toWorld(place, c.x, c.y, c.z)
        return {
            type = 'box',
            pos = { x = x, y = y, z = z },
            size = { x = shape.size.x, y = shape.size.y, z = shape.size.z },
            heading = PropertyMath.headingToWorld(place, shape.heading or 0.0),
        }
    end
    if shape.type == 'poly' then
        local pts = {}
        for i, p in ipairs(shape.points) do
            local x, y = PropertyMath.toWorld(place, p.x or p[1], p.y or p[2], 0.0)
            pts[i] = { x = x, y = y }
        end
        return { type = 'poly', points = pts, minZ = place.z + shape.minZ, maxZ = place.z + shape.maxZ }
    end
    return nil
end

-- ============================================
-- Sign posts
-- ============================================
--
-- An outside sign may name a post (Config.PropertySignPosts): a prop on the ground with a board, with the for-sale
-- prompt placed on the board's panel automatically. What is stored is still the prompt's spot, as for every sign,
-- so the buy range and anchor read it unchanged; the post's place is worked back from it. A post this server no
-- longer lists only loses its post: its prompt stays where it was.
--
-- The panel's printed side faces the prop's -Y, the opposite of its forward, so the prompt's heading is the
-- post's plus 180, and it stands POST_PROMPT_OFF in front of the board.

local POST_PROMPT_OFF = 0.02   -- metres off the board: a prompt flush with the print would flicker into it

--- A sign post's entry in Config.PropertySignPosts, by its model name; nil when it is not listed.
---@param model string|nil
---@return table|nil  { model, label, panel = { x, y, z } }
function PropertyMath.signPost(model)
    if type(model) ~= 'string' or model == '' then return nil end
    for _, p in ipairs(Config and Config.PropertySignPosts or {}) do
        if type(p) == 'table' and p.model == model and type(p.panel) == 'table' then return p end
    end
    return nil
end

local function panelOf(post)
    local pn = post.panel
    return tonumber(pn.x) or 0.0, (tonumber(pn.y) or 0.0) - POST_PROMPT_OFF, tonumber(pn.z) or 0.0
end

--- Where the prompt goes on a post standing at x, y, z (its bottom), turned to `heading`.
---@param post table  PropertyMath.signPost's
---@return number x, number y, number z, number heading
function PropertyMath.postToPrompt(post, x, y, z, heading)
    local lx, ly, lz = panelOf(post)
    local px, py, pz = PropertyMath.toWorld({ x = x, y = y, z = z, yaw = heading }, lx, ly, lz)
    return px, py, pz, (heading + 180.0) % 360.0
end

--- And back: where the post stands for a prompt at this spot. The exact inverse of postToPrompt.
---@param post table  PropertyMath.signPost's
---@return number x, number y, number z, number heading
function PropertyMath.promptToPost(post, x, y, z, heading)
    local h = (heading - 180.0) % 360.0
    local lx, ly, lz = panelOf(post)
    local ox, oy = PropertyMath.toWorld({ x = 0.0, y = 0.0, z = 0.0, yaw = h }, lx, ly, 0.0)
    return x - ox, y - oy, z - lz, h
end

-- ============================================
-- A whole unit
-- ============================================

local function pointToWorld(place, p)
    if type(p) ~= 'table' then return nil end
    local x, y, z = PropertyMath.toWorld(place, p.x or 0.0, p.y or 0.0, p.z or 0.0)
    return { x = x, y = y, z = z }
end

--- Everything about one unit, at one placement, in world space.
---
--- The one function both sides use to turn a template unit into something that can be drawn,
--- matched and tested — so a sign the server says is at a spot is at that spot on every client.
---@param place table   { x, y, z, yaw }
---@param unit table    resolved unit: { space, doors, sign, visit, garage }
---@param rooms table|nil  template rooms, for symbolic spaces
---@return table world  { shapes, unresolved, doors, sign, visit, bays, anchor }
function PropertyMath.unitToWorld(place, unit, rooms)
    local out = { shapes = {}, doors = {}, bays = {} }

    local locals, unresolved = PropertyMath.expandSpace(unit.space, rooms)
    out.unresolved = unresolved
    for _, s in ipairs(locals) do
        local w = PropertyMath.shapeToWorld(place, s)
        local prepared = w and Shapes.prepare(w)
        if prepared then out.shapes[#out.shapes + 1] = prepared end
    end

    for _, d in ipairs(unit.doors or {}) do
        local w = pointToWorld(place, d.pos)
        if w then
            out.doors[#out.doors + 1] = {
                key = d.key, role = d.role, lock = d.lock, pair = d.pair,
                model = PropertyMath.signedHash(d.model),
                x = w.x, y = w.y, z = w.z,
                heading = PropertyMath.headingToWorld(place, d.heading or 0.0),
            }
        end
    end

    -- TWO SIGNS. `sign` is the one OUTSIDE, for a property nobody owns yet: its name, that it is for
    -- sale. `manager` is the one INSIDE, for the people who live there: keys, furniture, and
    -- whatever else a home comes to have. Which one a client shows is its business
    -- (client/properties.lua); both are placed the same way. The outside one may stand on a post (`post`, a
    -- model name: Sign posts above), which the client puts up behind it.
    for _, part in ipairs({ 'sign', 'manager' }) do
        local s = unit[part]
        local w = s and pointToWorld(place, s.pos)
        if w then
            out[part] = { x = w.x, y = w.y, z = w.z,
                          heading = PropertyMath.headingToWorld(place, s.heading or 0.0),
                          post = part == 'sign' and s.post or nil }
        end
    end

    if unit.visit then
        out.visit = pointToWorld(place, unit.visit)
    elseif out.shapes[1] then
        -- No visit point given: stand in the middle of the first shape, just above its floor.
        local b = out.shapes[1]._bbox
        out.visit = { x = (b.minX + b.maxX) * 0.5, y = (b.minY + b.maxY) * 0.5, z = b.minZ + 0.1 }
    end

    for _, bay in ipairs((unit.garage and unit.garage.bays) or {}) do
        local w = pointToWorld(place, bay.pos)
        if w then
            out.bays[#out.bays + 1] = { x = w.x, y = w.y, z = w.z,
                                        heading = PropertyMath.headingToWorld(place, bay.heading or 0.0) }
        end
    end

    -- THE ANCHOR: one sphere that holds the unit's space, its doors and its sign — what a client
    -- streams by and what the server's "which property is this" grid indexes. Falls back to the
    -- placement itself for a unit with nothing in it yet.
    local b = Shapes.bbox(out.shapes)
    local minX, minY, minZ, maxX, maxY, maxZ
    if b then
        minX, minY, minZ, maxX, maxY, maxZ = b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ
    else
        minX, minY, minZ, maxX, maxY, maxZ = place.x, place.y, place.z, place.x, place.y, place.z
    end
    local function grow(p)
        if not p then return end
        if p.x < minX then minX = p.x end
        if p.x > maxX then maxX = p.x end
        if p.y < minY then minY = p.y end
        if p.y > maxY then maxY = p.y end
        if p.z < minZ then minZ = p.z end
        if p.z > maxZ then maxZ = p.z end
    end
    for _, d in ipairs(out.doors) do grow(d) end
    grow(out.sign)
    grow(out.manager)

    local cx, cy, cz = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
    local hx, hy, hz = (maxX - minX) * 0.5, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5
    out.anchor = { x = cx, y = cy, z = cz, r = math.max(2.0, sqrt(hx * hx + hy * hy + hz * hz)) }

    return out
end
