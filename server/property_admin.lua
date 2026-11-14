-- ============================================
-- PROPERTY ADMIN — the /whip Properties section, Server
-- ============================================
--
-- What an admin sees and does from the panel: every property with what is wrong with it, one
-- property in detail, the templates and packs they come from, the changes an admin makes by hand
-- (owner, keys, names, settings, delete, clear furniture, settling a pack conflict), and setting a
-- property up with the wizard (at the end of the file).
--
-- ACE-GATED, every read and every write, on whip.devtools. The panel is an admin tool and the
-- lists here carry keyholders and door ids, which the ordinary property wire deliberately does not.
--
-- LIVE. An admin with the section open is a VIEWER, and every change to a property — theirs,
-- another admin's, a pack's, a player's key — reaches them as an updated row. Changes are gathered
-- for a quarter of a second and sent together, because a pack update can touch every property it
-- has at once.

PropertyAdmin = {}

local ACE = 'whip.devtools'
local viewers = {}   -- [source] = true
local dirty, flushing = {}, false

-- ============================================
-- Rows
-- ============================================

local function packIdOf(rec)
    return rec.source and rec.source:match('^pack:(.+)$') or nil
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--- One property as the list shows it.
local function row(rec, names)
    local t = Properties.getTemplate(rec.templateId)
    local u = t and t.units[rec.unitKey]
    local w = rec.world or {}
    return {
        id          = rec.propertyId,
        name        = rec.name,
        label       = rec.label,
        building    = rec.building,
        ownerCharId = rec.ownerCharId,
        ownerName   = rec.ownerCharId and names[rec.ownerCharId] or nil,
        status      = rec.status,
        statusReason = rec.statusReason,
        packIssue   = rec.packIssue,
        packId      = packIdOf(rec),
        active      = rec.active ~= false,
        template    = t and t.label or ('#' .. tostring(rec.templateId)),
        unit        = u and u.label or rec.unitKey,
        keys        = #Properties.keysFor(rec.propertyId),
        objects     = PropertyObjects.count(rec.propertyId),
        maxObjects  = rec.effective and rec.effective.maxObjects or nil,
        shapes      = #(w.shapes or {}),
        unresolved  = w.unresolved == true,
        doors       = countKeys(rec.doorIds),
        hasSign     = w.sign ~= nil,
        -- The post it stands on, by its label (Config.PropertySignPosts); nil for a prompt on its own.
        signPost    = w.sign and w.sign.post and ((PropertyMath.signPost(w.sign.post) or {}).label or w.sign.post) or nil,
        hasManager  = w.manager ~= nil,
    }
end

local function ownerNames(recs)
    local want, seen = {}, {}
    for _, rec in ipairs(recs) do
        if rec.ownerCharId and not seen[rec.ownerCharId] then
            seen[rec.ownerCharId] = true
            want[#want + 1] = rec.ownerCharId
        end
    end
    return #want > 0 and (ResolveCharNames(want) or {}) or {}
end

--- Everything about one property, for the detail pane.
local function detail(rec)
    local base = row(rec, ownerNames({ rec }))
    local t = Properties.getTemplate(rec.templateId)
    local u = t and t.units[rec.unitKey]

    local holderIds = Properties.keysFor(rec.propertyId)
    local names = #holderIds > 0 and (ResolveCharNames(holderIds) or {}) or {}
    local holders = {}
    for _, c in ipairs(holderIds) do holders[#holders + 1] = { charId = c, name = names[c] or ('Character #' .. c) } end
    table.sort(holders, function(a, b) return a.charId < b.charId end)

    -- Every door the unit lists, whether whip locks it or leaves it alone.
    local doors = {}
    for _, d in ipairs((rec.unit and rec.unit.doors) or {}) do
        local doorId = rec.doorIds and rec.doorIds[d.key]
        local door = doorId and Doors.getDef(doorId)
        doors[#doors + 1] = {
            key = d.key, role = d.role, lock = d.lock == true, pair = d.pair,
            doorId = doorId, locked = door and door.locked or nil,
        }
    end

    local area = 0.0
    for _, s in ipairs((rec.world and rec.world.shapes) or {}) do area = area + Shapes.area(s) end

    local function parts(layer)
        local out = {}
        for k, v in pairs(layer or {}) do
            if k:sub(1, 1) ~= '_' and v ~= nil then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end

    local conflicts = {}
    for k in pairs((u and u.overlay and u.overlay._conflicts) or {}) do conflicts[#conflicts + 1] = k end
    table.sort(conflicts)

    local packId = packIdOf(rec)
    local pack = nil
    if packId then
        for _, p in ipairs(PropertyPacks.list().packs) do
            if p.id == packId then pack = p break end
        end
        pack = pack or { id = packId, running = false }
    end

    base.place       = rec.place
    base.keyholders  = holders
    base.doorList    = doors
    base.area        = area
    base.settings    = rec.settings or {}
    base.effective   = rec.effective
    base.templateId  = rec.templateId
    base.templateKey = t and t.templateKey
    base.archetype   = t and t.archetype
    base.archetypeHash = t and t.archetypeHash or 0
    base.unitKey     = rec.unitKey
    base.hasVisit    = rec.world and rec.world.visit ~= nil
    -- Whether there are sign posts to put its outside sign on (Config.PropertySignPosts).
    base.signPosts   = #(Config.PropertySignPosts or {}) > 0
    -- How many properties share its unit: an edit to a sign asks "this one, or all of them".
    base.unitUses    = Properties.unitUses(rec.templateId, rec.unitKey)
    -- Whose version of each sign is in force: 'property' (placed for this one), 'unit' (placed for
    -- every property on the unit), or 'pack' / nil (as its pack or first setup said).
    local function layerOf(part)
        if rec.overrides and rec.overrides[part] ~= nil then return 'property' end
        if u and u.overlay and u.overlay[part] ~= nil then return 'unit' end
        return u and u.base and u.base[part] ~= nil and 'base' or nil
    end
    base.signLayer    = layerOf('sign')
    base.managerLayer = layerOf('manager')
    base.bays        = #((rec.world and rec.world.bays) or {})
    base.garageCars  = rec.garageKey and #Garages.getGarageVehicles(rec.garageKey) or 0
    base.overlay     = parts(u and u.overlay)
    base.overrides   = parts(rec.overrides)
    base.conflicts   = conflicts
    base.pack        = pack
    -- Its looks, when the resource that built its interior offers some (server/property_themes.lua).
    base.themes      = PropertyThemes.infoOf(rec)
    -- Its stashes: the furniture that holds things (server/property_stashes.lua), for Inspect storage.
    -- `used` is the slots filled, only when the stash is in memory: a detail does not read every
    -- stash off the database.
    local stashes = {}
    for id, def in pairs(PropertyStashes.of(rec.propertyId)) do
        local inv, used = Containers.invCache[id], nil
        if inv then
            used = 0
            for _, s in pairs(inv) do if type(s) == 'table' and s.item then used = used + 1 end end
        end
        stashes[#stashes + 1] = { containerId = id, name = def.name, slots = def.slots,
                                  maxWeight = def.maxWeight, used = used }
    end
    table.sort(stashes, function(a, b) return a.containerId < b.containerId end)
    base.stashes     = stashes
    return base
end

-- ============================================
-- Viewers
-- ============================================

local function flush()
    flushing = false
    if next(viewers) == nil then dirty = {} return end
    local recs, removed = {}, {}
    for id in pairs(dirty) do
        local rec = Properties.get(id)
        if rec then recs[#recs + 1] = rec else removed[#removed + 1] = id end
    end
    dirty = {}
    local names = ownerNames(recs)
    local rows = {}
    for i, rec in ipairs(recs) do rows[i] = row(rec, names) end
    DevTools.eachViewer(viewers, function(src)   -- still allowed
        TriggerClientEvent('whip_core:client:propertyAdminRows', src, rows, removed)
    end, ACE)
end

--- A property changed (or went). Called from Properties' announce.
function PropertyAdmin.changed(propertyId)
    if next(viewers) == nil then return end
    dirty[propertyId] = true
    if not flushing then
        flushing = true
        SetTimeout(250, flush)
    end
end

-- Bursts: flicking the panel shut and open again is ordinary, and a refused open or close leaves
-- the viewer list wrong.
SecureEvent('whip_core:server:propertyAdminOpen', { ace = ACE, rateLimit = 500, burst = 3 }, function(source)
    viewers[source] = true
end)

-- No ACE on the close: leaving is never refused, dead or at the character screen too (devtools.lua plmClosed).
SecureEvent('whip_core:server:propertyAdminClosed', {
    requirePlayer = false, whileDead = true, rateLimit = 250, burst = 3,
}, function(source)
    viewers[source] = nil
end)

AddEventHandler('playerDropped', function() viewers[source] = nil end)

-- ============================================
-- Reads
-- ============================================

SecureCallback('whip_core:property:adminList', { ace = ACE, rateLimit = 500 }, function()
    local recs = {}
    for _, rec in pairs(Properties.getAll()) do recs[#recs + 1] = rec end
    table.sort(recs, function(a, b) return a.propertyId < b.propertyId end)
    local names = ownerNames(recs)
    local rows = {}
    for i, rec in ipairs(recs) do rows[i] = row(rec, names) end
    return rows
end)

SecureCallback('whip_core:property:adminDetail', {
    ace = ACE, rateLimit = 100, burst = 10,
    params = { {'propertyId', 'id'} },
}, function(_, _, propertyId)
    local rec = Properties.get(propertyId)
    return rec and detail(rec) or nil
end)

--- The templates, their units, and the packs they came from.
SecureCallback('whip_core:property:adminTemplates', { ace = ACE, rateLimit = 500 }, function()
    local useCount = {}
    for _, rec in pairs(Properties.getAll()) do
        local k = rec.templateId .. ':' .. rec.unitKey
        useCount[k] = (useCount[k] or 0) + 1
        useCount[rec.templateId] = (useCount[rec.templateId] or 0) + 1
    end
    local out = {}
    for id, t in pairs(Properties.getTemplates()) do
        local units = {}
        for key, u in pairs(t.units) do
            units[#units + 1] = {
                key = key, label = u.label, sortOrder = u.sortOrder,
                properties = useCount[id .. ':' .. key] or 0,
                conflict = u.overlay and u.overlay._conflicts and next(u.overlay._conflicts) ~= nil or false,
                edited = u.overlay ~= nil,
            }
        end
        table.sort(units, function(a, b) return (a.sortOrder or 0) < (b.sortOrder or 0) end)
        out[#out + 1] = {
            templateId = id, templateKey = t.templateKey, label = t.label, source = t.source,
            archetype = t.archetype, archetypeHash = t.archetypeHash, packVersion = t.packVersion,
            rooms = #(t.rooms or {}), properties = useCount[id] or 0, units = units,
        }
    end
    table.sort(out, function(a, b) return a.templateId < b.templateId end)
    return { templates = out, packs = PropertyPacks.list() }
end)

-- ============================================
-- Writes
-- ============================================

local function reply(source, ok, done, err)
    if ok then
        ShowSuccess(source, done)
    else
        ShowError(source, err or 'That did not work')
    end
end

--- Is this a character that exists (and has not been deleted)? Properties.characterLive — the check
--- setOwner and grantKey make themselves; asked here first for the panel's
--- own wording.
local function characterExists(charId)
    return Properties.characterLive(charId)
end

-- The handlers below refuse with `return false, 'why'`: the player sees the why, and the Event
-- Monitor records a refusal.
local GONE = 'That property no longer exists'

SecureEvent('whip_core:server:propertyAdminSetOwner', {
    ace = ACE, rateLimit = 250,
    -- 0 makes it unowned: a nil cannot travel through a validated param.
    params = { {'propertyId', 'id'}, {'charId', 'id', 0} },
}, function(source, player, propertyId, charId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    if charId > 0 and not characterExists(charId) then
        return false, ('There is no character #%d'):format(charId)
    end
    local ok, err = Properties.setOwner(propertyId, charId > 0 and charId or nil, player and player.charId)
    reply(source, ok, charId > 0 and ('%s now belongs to character #%d'):format(rec.name, charId)
        or ('%s is now unowned'):format(rec.name), err)
end)

--- Admins give and take keys WITHOUT the face-to-face rule players have: the panel is where an
--- admin fixes access for somebody who is not there.
SecureEvent('whip_core:server:propertyAdminGrantKey', {
    ace = ACE, rateLimit = 250,
    params = { {'propertyId', 'id'}, {'charId', 'id'} },
}, function(source, player, propertyId, charId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    if not characterExists(charId) then
        return false, ('There is no character #%d'):format(charId)
    end
    local ok, err = Properties.grantKey(propertyId, charId, player and player.charId)
    reply(source, ok, ('Character #%d has a key to %s'):format(charId, rec.name), err)
end)

SecureEvent('whip_core:server:propertyAdminRevokeKey', {
    ace = ACE, rateLimit = 250,
    params = { {'propertyId', 'id'}, {'charId', 'id'} },
}, function(source, _, propertyId, charId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    local ok, err = Properties.revokeKey(propertyId, charId)
    reply(source, ok, ('Character #%d\'s key to %s is taken back'):format(charId, rec.name), err)
end)

--- Name, unit label, building and settings. An empty label or building clears it.
SecureEvent('whip_core:server:propertyAdminUpdate', {
    ace = ACE, rateLimit = 500,
    params = { {'propertyId', 'id'}, {'fields', 'any'} },
}, function(source, _, propertyId, fields)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    if type(fields) ~= 'table' then return end

    local out = {}
    if fields.name ~= nil then
        if type(fields.name) ~= 'string' or fields.name:match('^%s*$') or #fields.name > 100 then
            return false, 'A name is 1 to 100 characters'
        end
        out.name = fields.name
    end
    for _, f in ipairs({ { 'label', 60 }, { 'building', 100 } }) do
        local v = fields[f[1]]
        if v ~= nil then
            if type(v) ~= 'string' or #v > f[2] then
                return false, ('The %s is at most %d characters'):format(f[1], f[2])
            end
            -- Blank clears it (false). Written out: `blank and false or v` is always `v`.
            if v:match('^%s*$') then out[f[1]] = false else out[f[1]] = v end
        end
    end
    if fields.settings ~= nil then
        local s, err = PropertyValidate.settingsOf(fields.settings)
        if not s then return false, err end
        out.settings = s
    end
    if next(out) == nil then return end

    local ok, err = Properties.update(propertyId, out)
    reply(source, ok, ('%s saved'):format(out.name or rec.name), err)
end)

SecureEvent('whip_core:server:propertyAdminDelete', {
    ace = ACE, rateLimit = 500,
    params = { {'propertyId', 'id'} },
}, function(source, _, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    local name = rec.name
    local ok, err = Properties.delete(propertyId)
    reply(source, ok, ('%s deleted'):format(name), err)
end)

SecureEvent('whip_core:server:propertyAdminClearFurniture', {
    ace = ACE, rateLimit = 1000,
    params = { {'propertyId', 'id'} },
}, function(source, player, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    -- Refused while one of its stashes holds anything (server/property_stashes.lua).
    local ok, err = PropertyObjects.clear(propertyId, player and player.charId)
    reply(source, ok, ('The furniture in %s is gone'):format(rec.name), err)
end)

--- A pack changed a unit part an admin had changed: keep the admin's, or use the pack's.
SecureEvent('whip_core:server:propertyAdminResolve', {
    ace = ACE, rateLimit = 500,
    params = { {'propertyId', 'id'}, {'mode', 'string', 8} },
}, function(source, _, propertyId, mode)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    if mode ~= 'keep' and mode ~= 'pack' then return end
    local ok, err = Properties.resolveConflict(rec.templateId, rec.unitKey, mode)
    reply(source, ok, mode == 'keep' and 'Your version stays' or 'The pack\'s version applies', err)
end)

--- Put one of a property's signs where the admin aimed it.
---
--- A coordinate from the client, which the rest of whip avoids: a sign goes on a wall, and only the
--- aimed ray knows where the wall is. What holds
--- the line: the ACE; the point must be within reach of the admin's own ped (the ray starts at the
--- camera, so a little slack); and it must be near the property it is for. It is stored in the
--- interior's own space, so it moves with the interior and with every placement sharing the unit.
---
--- `post`: the outside sign on a sign post (Config.PropertySignPosts, by its model; '' for none). The spot is still
--- the prompt's, on the post's board (shared/property_math.lua, Sign posts).
SecureEvent('whip_core:server:propertyAdminSetSign', {
    ace = ACE, rateLimit = 500,
    params = {
        {'propertyId', 'id'},
        {'which', 'string', 8},
        {'scope', 'string', 8},
        {'x', 'number', -100000.0, 100000.0},
        {'y', 'number', -100000.0, 100000.0},
        {'z', 'number', -5000.0, 10000.0},
        {'heading', 'number', 0.0, 360.0, 0.0},
        {'post', 'string', 64, ''},
    },
}, function(source, _, propertyId, which, scope, x, y, z, heading, post)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    if which ~= 'sign' and which ~= 'manager' then return end
    if scope ~= 'unit' and scope ~= 'property' then return end
    if post ~= '' and (which ~= 'sign' or not PropertyMath.signPost(post)) then
        return false, 'That sign post is not one this server has'
    end

    local c = GetEntityCoords(GetPlayerPed(source))
    local reach = (Config.PropertySignPlaceRange or 12.0) + 10.0
    local dx, dy, dz = x - c.x, y - c.y, z - c.z
    if dx * dx + dy * dy + dz * dz > reach * reach then
        return false, 'That is too far from you to place'
    end
    local a = rec.world and rec.world.anchor
    if a then
        local ax, ay, az = x - a.x, y - a.y, z - a.z
        local near = (a.r or 0) + 30.0
        if ax * ax + ay * ay + az * az > near * near then
            return false, ('That is not near %s'):format(rec.name)
        end
    end

    local lx, ly, lz = PropertyMath.toLocal(rec.place, x, y, z)
    local value, err = PropertyValidate.signOf({ pos = { x = lx, y = ly, z = lz },
                                                 heading = PropertyMath.headingToLocal(rec.place, heading),
                                                 post = post ~= '' and post or nil }, which == 'sign')
    if not value then return false, err end

    local ok, serr = Properties.setPart(propertyId, which, value, scope)
    local uses = Properties.unitUses(rec.templateId, rec.unitKey)
    reply(source, ok, ('%s placed for %s'):format(which == 'sign' and (value.post and 'Sign post' or 'Outside sign') or 'Manager',
        scope == 'unit' and uses > 1 and ('all %d properties on this unit'):format(uses) or rec.name), serr)
end)

--- A property its pack no longer lists becomes an admin's own.
SecureEvent('whip_core:server:propertyAdminAdopt', {
    ace = ACE, rateLimit = 500,
    params = { {'propertyId', 'id'} },
}, function(source, _, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, GONE end
    local ok, err = Properties.adopt(propertyId)
    reply(source, ok, ('%s is now looked after here, not by its pack'):format(rec.name), err)
end)

-- ============================================
-- The wizard: setting a property up
-- ============================================
--
-- The draft arrives whole, once, at Save (tools/property_wizard.lua builds it). It is in the
-- interior's own space, as a pack's units are, and it goes through the same checker a pack does:
-- an admin's draft is trusted no more than a download.
--
-- What holds the line, besides the ACE:
--   the admin stands within TETHER of the placement they send. The placement is read from the
--     interior they are standing in, so it is where they are.
--   two properties cannot be the same place: the new one's stand-in point may not be inside
--     another's space, nor another's inside the new one's.
--   a first save that fails half-way takes back what it made (the unit, and a template it made).
--
-- Every answer goes back as whip_core:client:propertyAdminSaved (ok, propertyId | why), which the
-- wizard waits for: a refusal keeps the draft and says why, success closes it.

local TETHER = 150.0

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- A placement from the client, checked, or nil.
local function placeOf(p)
    if type(p) ~= 'table' then return nil end
    local x, y, z, yaw = tonumber(p.x), tonumber(p.y), tonumber(p.z), tonumber(p.yaw or 0)
    if not (finite(x) and finite(y) and finite(z) and finite(yaw)) then return nil end
    if math.abs(x --[[@as number]]) > 100000 or math.abs(y --[[@as number]]) > 100000 or z < -5000 or z > 10000 then return nil end
    return { hash = PropertyMath.signedHash(p.hash or 0) or 0, x = x, y = y, z = z, yaw = yaw % 360.0 }
end

local function within(source, x, y, z, r)
    local c = GetEntityCoords(GetPlayerPed(source))
    local dx, dy, dz = x - c.x, y - c.y, z - c.z
    return dx * dx + dy * dy + dz * dz <= r * r
end

--- Optional text: nil when empty, or an error when it is not text or too long.
---@return string|nil value, string|nil err
local function textField(v, max, what)
    if v == nil or v == false then return nil end
    if type(v) ~= 'string' or #v > max then return nil, ('The %s is at most %d characters'):format(what, max) end
    if v:match('^%s*$') then return nil end
    return v
end

local function count(n)
    n = tonumber(n)
    if not finite(n) or n < 0 or n > 5000 then return nil end
    return math.floor(n --[[@as number]])
end

--- Would a property with this world data be one that already exists? Its stand-in point inside
--- another's space, or another's inside its own.
---@return table|nil other
local function clashWith(world, exceptId)
    local v = world.visit
    for id, rec in pairs(Properties.getAll()) do
        if id ~= exceptId and rec.world then
            if v and Shapes.containsAny(rec.world.shapes or {}, v.x, v.y, v.z) then return rec end
            local ov = rec.world.visit
            if ov and Shapes.containsAny(world.shapes, ov.x, ov.y, ov.z) then return rec end
        end
    end
    return nil
end

--- The admin template for this interior, if there is one yet. An open-world property (hash 0)
--- always gets its own: two houses on the map share nothing.
local function existingAdminTemplate(hash)
    if hash == 0 then return nil end
    for _, t in ipairs(Properties.templatesFor(hash)) do
        if t.source == 'admin' then return t end
    end
    return nil
end

--- The first free unit key of a template ('u1', 'u2', ...) and its place in the order.
local function freeUnitKey(t)
    local n = 1
    while t.units['u' .. n] do n = n + 1 end
    return 'u' .. n, n
end

local function saved(source, ok, idOrWhy)
    TriggerClientEvent('whip_core:client:propertyAdminSaved', source, ok, idOrWhy)
end

--- A new property from the wizard.
---
---   draft = { place = { hash, x, y, z, yaw }, rooms?, fingerprint = { rooms, portals }?,
---             space, doors, sign?, manager?, visit?,           -- the unit, interior-local
---             name, label?, building?, settings?, ownerCharId?, theme? }
SecureEvent('whip_core:server:propertyAdminSave', {
    ace = ACE, rateLimit = 2000,
    params = { {'draft', 'any'} },
}, function(source, player, d)
    if type(d) ~= 'table' then return saved(source, false, 'Nothing to save') end

    local place = placeOf(d.place)
    if not place then return saved(source, false, 'The placement is not a position') end
    if not within(source, place.x, place.y, place.z, TETHER) then
        return saved(source, false, 'You are too far from where you set this up — go back to it and save again')
    end

    local name, err = textField(d.name, 100, 'name')
    if err then return saved(source, false, err) end
    if not name then return saved(source, false, 'A property needs a name') end
    local label, lerr = textField(d.label, 60, 'unit label')
    if lerr then return saved(source, false, lerr) end
    local building, berr = textField(d.building, 100, 'building')
    if berr then return saved(source, false, berr) end
    local settings, serr = PropertyValidate.settingsOf(d.settings)
    if not settings then return saved(source, false, serr) end

    local owner = tonumber(d.ownerCharId)
    if owner and owner > 0 then
        if owner % 1 ~= 0 or not characterExists(owner) then
            return saved(source, false, ('There is no character #%s'):format(tostring(owner)))
        end
    else
        owner = nil
    end

    local unit, uerr = PropertyValidate.unitOf({
        key = 'new', label = label, space = d.space, doors = d.doors,
        sign = d.sign, manager = d.manager, visit = d.visit, garage = d.garage,
    })
    if not unit then return saved(source, false, uerr) end
    if unit.sign and unit.sign.post and not PropertyMath.signPost(unit.sign.post) then
        return saved(source, false, 'That sign post is not one this server has')
    end

    local rooms = nil
    if d.rooms ~= nil then
        local rerr
        rooms, rerr = PropertyValidate.roomsOf(d.rooms)
        if rerr then return saved(source, false, rerr) end
    end
    local fingerprint = type(d.fingerprint) == 'table'
        and { rooms = count(d.fingerprint.rooms), portals = count(d.fingerprint.portals) } or nil

    -- WHAT IT WOULD BE, worked out before anything is written.
    local existing = existingAdminTemplate(place.hash)
    local useRooms = rooms or (existing and existing.rooms)
    local world = PropertyMath.unitToWorld(place, unit, useRooms)
    if #world.shapes == 0 then
        return saved(source, false, world.unresolved
            and 'Its space is the interior\'s rooms, and none were read — read the interior again'
            or 'A property needs a space')
    end
    if unit.visit then
        local v = world.visit
        if not Shapes.containsAny(world.shapes, v.x, v.y, v.z, 0.3) then
            return saved(source, false, 'The stand-in point is outside its own space — stand inside it and set it again')
        end
    end
    local other = clashWith(world)
    if other then
        return saved(source, false, ('That space is %s (#%d) already'):format(other.name, other.propertyId))
    end

    -- The template: this interior's, made the first time, and given its rooms the first time they
    -- are read (a template made from a world property's rooms, or a pack's, keeps its own).
    local t, created = existing, false
    if not t then
        local terr
        t, terr = Properties.saveTemplate({
            source = 'admin', label = building or name, archetypeHash = place.hash,
            rooms = rooms, fingerprint = fingerprint,
        })
        if not t then return saved(source, false, terr) end
        created = true
    elseif rooms and not (t.rooms and #t.rooms > 0) then
        Properties.saveTemplate({
            templateKey = t.templateKey, source = t.source, label = t.label, archetype = t.archetype,
            archetypeHash = t.archetypeHash, fingerprint = fingerprint or t.fingerprint, rooms = rooms,
            settings = t.settings, packVersion = t.packVersion,
        })
    end

    local unitKey, order = freeUnitKey(t)
    local u, sverr = Properties.saveUnit(t.templateId, unitKey,
        { label = label or name, sortOrder = order, base = PropertyValidate.unitBase(unit) })
    if not u then
        if created then Properties.deleteTemplate(t.templateId) end
        return saved(source, false, sverr)
    end

    local rec, cerr = Properties.create({
        templateId = t.templateId, unitKey = unitKey, place = place,
        name = name, label = label, building = building, settings = settings, ownerCharId = owner,
    }, player and player.charId)
    if not rec then
        Properties.deleteUnit(t.templateId, unitKey)
        if created then Properties.deleteTemplate(t.templateId) end
        return saved(source, false, cerr)
    end

    saved(source, true, rec.propertyId)
    ShowSuccess(source, ('%s is set up (#%d)'):format(rec.name, rec.propertyId))
    -- The look picked in the wizard, when its interior has looks. The property stands either way.
    local theme = math.tointeger(tonumber(d.theme))
    if theme and theme ~= 0 and PropertyThemes.offered(rec) then
        local tok, terr = PropertyThemes.set(rec.propertyId, theme)
        if not tok then ShowError(source, 'Its theme: ' .. tostring(terr)) end
    end
end)

--- The parts the wizard edits one at a time. The signs have their own event (they are aimed, and
--- stored from the aimed point: propertyAdminSetSign above). `garage = false` takes the garage away.
local EDIT_PARTS = { space = true, doors = true, visit = true, garage = true }

--- One part of an existing property, for it alone ('property') or its whole unit ('unit').
SecureEvent('whip_core:server:propertyAdminSavePart', {
    ace = ACE, rateLimit = 1000,
    params = { {'propertyId', 'id'}, {'part', 'string', 16}, {'scope', 'string', 8}, {'value', 'any'} },
}, function(source, _, propertyId, part, scope, value)
    local rec = Properties.get(propertyId)
    if not rec then return saved(source, false, 'That property no longer exists') end
    if not EDIT_PARTS[part] then return saved(source, false, 'That part cannot be changed here') end
    if scope ~= 'unit' and scope ~= 'property' then return saved(source, false, 'Say which properties it is for') end
    local a = (rec.world and rec.world.anchor) or rec.place
    if not within(source, a.x, a.y, a.z, TETHER + (a.r or 0)) then
        return saved(source, false, ('Go to %s to change it'):format(rec.name))
    end

    local v, err
    if part == 'garage' and value == false then
        v = false   -- no garage: the property's garage goes, its cars moved to a public one
    else
        v, err = PropertyValidate.partOf(part, value)
        if err then return saved(source, false, err) end
        if v == nil then return saved(source, false, 'Nothing to save') end
    end

    -- The property as it would be.
    local t = Properties.getTemplate(rec.templateId)
    local u = {}
    for k, x in pairs(rec.unit or {}) do u[k] = x end
    u[part] = v
    local world = PropertyMath.unitToWorld(rec.place, u, t and t.rooms)
    if #world.shapes == 0 then
        return saved(source, false, world.unresolved
            and 'That space is the interior\'s rooms, and this interior\'s rooms are not known yet'
            or 'A property needs a space')
    end
    if part == 'visit' and not Shapes.containsAny(world.shapes, world.visit.x, world.visit.y, world.visit.z, 0.3) then
        return saved(source, false, 'That is outside its space — stand inside it')
    end
    if part ~= 'doors' then
        local other = clashWith(world, rec.propertyId)
        if other then
            return saved(source, false, ('That would overlap %s (#%d)'):format(other.name, other.propertyId))
        end
    end

    local ok, serr = Properties.setPart(rec.propertyId, part, v, scope)
    if not ok then return saved(source, false, serr) end
    local uses = Properties.unitUses(rec.templateId, rec.unitKey)
    saved(source, true, rec.propertyId)
    local what = ({ space = 'Space', doors = 'Doors', garage = 'Garage', visit = 'Stand-in point' })[part]
    ShowSuccess(source, ('%s saved for %s'):format(what,
        scope == 'unit' and uses > 1 and ('all %d properties on this unit'):format(uses) or rec.name))
end)

--- Move a property onto the interior as it stands now: an MLO that was moved, or re-exported with
--- a new origin. Everything it has is interior-local, so it all follows.
---
--- And take its layout as it is now (an MLO update can change its rooms). `layout` is what the admin's
--- game read standing in it ({ rooms, fingerprint = { rooms, portals } }); rooms and counts that differ
--- from the template's go to the TEMPLATE, since the MLO changed for every property built on it, and
--- each of them is checked again (Properties.setTemplateLayout).
SecureEvent('whip_core:server:propertyAdminRebind', {
    ace = ACE, rateLimit = 1000,
    params = { {'propertyId', 'id'}, {'place', 'any'}, {'layout', 'any'} },
}, function(source, _, propertyId, p, layout)
    local rec = Properties.get(propertyId)
    if not rec then return saved(source, false, 'That property no longer exists') end
    local t = Properties.getTemplate(rec.templateId)
    if not t or t.archetypeHash == 0 then
        return saved(source, false, 'An open-world property has no interior to re-bind to')
    end
    local place = placeOf(p)
    if not place then return saved(source, false, 'The placement is not a position') end
    if place.hash ~= t.archetypeHash then
        return saved(source, false, 'That is a different interior from the one this property is built on')
    end
    if not within(source, place.x, place.y, place.z, TETHER) then
        return saved(source, false, 'You are too far from that interior')
    end

    local newRooms, newFp
    if type(layout) == 'table' then
        local rooms = PropertyValidate.roomsOf(layout.rooms)
        local f = type(layout.fingerprint) == 'table' and layout.fingerprint or {}
        local fp = { rooms = count(f.rooms), portals = count(f.portals) }
        local was = t.fingerprint or {}
        if rooms and #rooms > 0 and fp.rooms and fp.portals and (was.rooms ~= fp.rooms or was.portals ~= fp.portals) then
            newRooms, newFp = rooms, fp
        end
    end
    local moved = not PropertyMath.samePlacement(place, rec.place, 0.05, 0.1)
    if not moved and not newRooms then
        return saved(source, false, 'It has not moved and its rooms are as saved — there is nothing to re-bind')
    end

    local world = PropertyMath.unitToWorld(place, rec.unit or {}, newRooms or t.rooms)
    local other = clashWith(world, rec.propertyId)
    if other then
        return saved(source, false, ('%s (#%d) is already there'):format(other.name, other.propertyId))
    end
    local others = 0
    if newRooms then
        local ok, err, n = Properties.setTemplateLayout(t.templateId, newRooms, newFp)
        if not ok then return saved(source, false, err) end
        others = (n or 1) - 1
    end
    if moved then
        local ok, err = Properties.update(rec.propertyId, { place = place })
        if not ok then return saved(source, false, err) end
    end
    saved(source, true, rec.propertyId)
    if newRooms then
        ShowSuccess(source, ('%s takes its interior as it is now: %d rooms and %d doorways%s')
            :format(rec.name, newFp.rooms, newFp.portals,
                others > 0 and (' (and the %d other propert%s on it; Verify them again)')
                    :format(others, others == 1 and 'y' or 'ies') or ''))
    else
        ShowSuccess(source, ('%s is re-bound to the interior here'):format(rec.name))
    end
end)

--- What whip knows about the interior an admin is standing in: its templates, and the properties
--- already at this placement of it.
SecureCallback('whip_core:property:adminKnown', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = { {'place', 'any'} },
}, function(_, _, p)
    local place = placeOf(p)
    if not place then return false, 'That is not a place' end   -- `false, why`, not a bare nil
    local templates = {}
    if place.hash ~= 0 then
        for _, t in ipairs(Properties.templatesFor(place.hash)) do
            templates[#templates + 1] = {
                templateId = t.templateId, label = t.label, source = t.source,
                units = countKeys(t.units), rooms = #(t.rooms or {}),
            }
        end
    end
    local here = {}
    for _, rec in pairs(Properties.getAll()) do
        if PropertyMath.samePlacement(rec.place, place) then
            local t = Properties.getTemplate(rec.templateId)
            local u = t and t.units[rec.unitKey]
            here[#here + 1] = { id = rec.propertyId, name = rec.name, unit = u and u.label or rec.unitKey }
        end
    end
    table.sort(here, function(a, b) return a.id < b.id end)
    -- And the looks a resource offers this home, for the wizard's settings step.
    return { templates = templates, here = here, themes = PropertyThemes.at(place) }
end)

--- The whip doors near a point, and who manages each: the door step marks the ones another
--- property (or resource) already holds, and the ones that will be adopted.
SecureCallback('whip_core:property:adminDoorsNear', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = {
        {'x', 'number', -100000.0, 100000.0},
        {'y', 'number', -100000.0, 100000.0},
        {'z', 'number', -5000.0, 10000.0},
        {'r', 'number', 1.0, 80.0},
    },
}, function(_, _, x, y, z, r)
    local out = {}
    for _, door in ipairs(Doors.getNearby(x, y, z, r)) do
        if math.abs(door.z - z) <= r then
            local mb = Doors.managerOf(door)
            out[#out + 1] = {
                doorId = door.doorId, x = door.x, y = door.y, z = door.z, model = door.model, label = door.label,
                manager = mb and { system = mb.system, id = mb.id, label = mb.label } or nil,
            }
            if #out >= 200 then break end
        end
    end
    return out
end)

--- One property's unit as it stands, in its interior's own space: what the wizard edits a part of.
SecureCallback('whip_core:property:adminUnit', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = { {'propertyId', 'id'} },
}, function(_, _, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local t = Properties.getTemplate(rec.templateId)
    return {
        id = rec.propertyId, name = rec.name, place = rec.place,
        archetypeHash = t and t.archetypeHash or 0,
        rooms = t and t.rooms or nil,
        -- What its interior was when its template was made (rooms and doorways): Re-bind shows a
        -- layout that has changed since, and takes it.
        fingerprint = t and t.fingerprint or nil,
        unit = rec.unit or {},
        unitUses = Properties.unitUses(rec.templateId, rec.unitKey),
    }
end)

-- ============================================
-- Scale: Register here, Stamp mode, Verify, Export
-- ============================================
--
-- The tools for two hundred flats rather than one. An interior set up once is a TEMPLATE, so every
-- other copy of it is a placement away from being homes too:
--
--   Register here   stand in a copy of a known interior; its units become properties
--   Stamp mode      fly through a tower doing that floor after floor (tools/property_scale.lua)
--   Verify          stand in each property and check the world still matches it
--   Export pack     write a template out as the file an MLO ships (server/property_export.lua)
--
-- The same rules as the wizard's Save hold: the admin is within TETHER of any placement they send,
-- and no new property may be one that already exists.

--- A template's units, and what each is at this placement: already a property, in the way of
--- another one, or free to register.
local function unitsHere(t, place)
    local here = {}
    for _, rec in pairs(Properties.getAll()) do
        if rec.templateId == t.templateId and PropertyMath.samePlacement(rec.place, place) then here[rec.unitKey] = rec end
    end
    local list = {}
    for key, u in pairs(t.units) do
        local entry = { key = key, label = u.label or key, sortOrder = u.sortOrder or 0 }
        local rec = here[key]
        if rec then
            entry.registered = { id = rec.propertyId, name = rec.name }
        else
            local unit = Properties.resolvedUnit(t.templateId, key)
            local world = unit and PropertyMath.unitToWorld(place, unit, t.rooms)
            if world and #world.shapes > 0 then
                local other = clashWith(world)
                if other then entry.clash = ('%s (#%d)'):format(other.name, other.propertyId) end
            end
            entry.unresolved = world and world.unresolved or nil
        end
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b) return a.sortOrder < b.sortOrder end)
    return list
end

--- What Register here shows: every template for the interior at this placement, and its units.
SecureCallback('whip_core:property:adminRegisterInfo', {
    ace = ACE, rateLimit = 250, burst = 5,
    params = { {'place', 'any'} },
}, function(_, _, p)
    local place = placeOf(p)
    if not place or place.hash == 0 then return false, 'That is not an interior' end
    local out = {}
    for _, t in ipairs(Properties.templatesFor(place.hash)) do
        out[#out + 1] = {
            templateId = t.templateId, label = t.label, source = t.source,
            roomsKnown = t.rooms ~= nil and #t.rooms > 0, units = unitsHere(t, place),
        }
    end
    return { templates = out }
end)

--- Make some units of a template into properties, at the placement the admin is standing in.
---
---   req = { place, templateId, building?, units = { { key, name, label? }, ... } }
---
--- Each unit on its own: one already registered, or overlapping another property, is skipped and
--- said, and the rest are made. The answer is propertyAdminRegistered { ok, created, skipped }.
SecureEvent('whip_core:server:propertyAdminRegister', {
    ace = ACE, rateLimit = 1000,
    params = { {'req', 'any'} },
    -- A gate refusal answers too: the stamp waits for propertyAdminRegistered (`busy`), so a refused
    -- event (the rate limit: E pressed twice inside a second) must still answer.
    onReject = function(src, reason)
        TriggerClientEvent('whip_core:client:propertyAdminRegistered', src, { ok = false, why = tostring(reason) })
    end,
}, function(source, player, req)
    local function done(res) TriggerClientEvent('whip_core:client:propertyAdminRegistered', source, res) end
    if type(req) ~= 'table' then return done({ ok = false, why = 'Nothing to register' }) end

    local place = placeOf(req.place)
    if not place or place.hash == 0 then return done({ ok = false, why = 'Stand inside the interior to register it' }) end
    if not within(source, place.x, place.y, place.z, TETHER) then
        return done({ ok = false, why = 'You are too far from that interior' })
    end
    local t = Properties.getTemplate(tonumber(req.templateId))
    if not t or t.archetypeHash ~= place.hash then
        return done({ ok = false, why = 'That template is for a different interior' })
    end
    local building, berr = textField(req.building, 100, 'building')
    if berr then return done({ ok = false, why = berr }) end
    if type(req.units) ~= 'table' or #req.units == 0 or #req.units > PropertyValidate.LIMITS.units then
        return done({ ok = false, why = 'Pick the units to register' })
    end

    local created, skipped = {}, {}
    for _, u in ipairs(req.units) do
        local key = type(u) == 'table' and u.key or nil
        local unit = type(key) == 'string' and t.units[key] and Properties.resolvedUnit(t.templateId, key) or nil
        local why = nil
        if not unit then
            why = 'no such unit'
        else
            local name, nerr = textField(u.name, 100, 'name')
            local label, lerr = textField(u.label, 60, 'unit label')
            if nerr or lerr then
                why = nerr or lerr
            elseif not name then
                why = 'it needs a name'
            else
                for _, rec in pairs(Properties.getAll()) do
                    if rec.templateId == t.templateId and rec.unitKey == key and PropertyMath.samePlacement(rec.place, place) then
                        why = ('already %s (#%d)'):format(rec.name, rec.propertyId)
                        break
                    end
                end
                if not why then
                    local world = PropertyMath.unitToWorld(place, unit, t.rooms)
                    local other = #world.shapes > 0 and clashWith(world) or nil
                    if other then
                        why = ('it overlaps %s (#%d)'):format(other.name, other.propertyId)
                    else
                        local rec, cerr = Properties.create({
                            templateId = t.templateId, unitKey = key, place = place,
                            name = name, label = label, building = building,
                        }, player and player.charId)
                        if rec then created[#created + 1] = rec.propertyId else why = cerr end
                    end
                end
            end
        end
        if why then skipped[#skipped + 1] = { unit = tostring(key), why = why } end
    end

    done({ ok = #created > 0, created = created, skipped = skipped, templateId = t.templateId })
    if #created > 0 then
        ShowSuccess(source,
            ('%d propert%s registered'):format(#created, #created == 1 and 'y' or 'ies'))
    end
end)

--- Every interior template with its units' spaces, for Stamp mode: it recognises the interior the
--- admin flies into and draws the units it would register there.
SecureCallback('whip_core:property:adminStampTemplates', {
    ace = ACE, rateLimit = 1000,
}, function()
    local out = {}
    for id, t in pairs(Properties.getTemplates()) do
        if (t.archetypeHash or 0) ~= 0 then
            local units = {}
            for key, u in pairs(t.units) do
                local r = Properties.resolvedUnit(id, key) or {}
                units[#units + 1] = { key = key, label = u.label or key, sortOrder = u.sortOrder or 0, space = r.space or {} }
            end
            table.sort(units, function(a, b) return a.sortOrder < b.sortOrder end)
            out[#out + 1] = { templateId = id, label = t.label, hash = t.archetypeHash, rooms = t.rooms, units = units }
        end
    end
    table.sort(out, function(a, b) return a.templateId < b.templateId end)
    return out
end)

--- What Verify needs to check one property in the world: where to stand, which doors should be
--- there, and what its interior should look like.
SecureCallback('whip_core:property:adminVerifyInfo', {
    ace = ACE, rateLimit = 100, burst = 20,
    params = { {'propertyId', 'id'} },
}, function(_, _, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local t = Properties.getTemplate(rec.templateId)
    local w = rec.world or {}
    local doors = {}
    for _, d in ipairs(w.doors or {}) do
        doors[#doors + 1] = { key = d.key, model = d.model, x = d.x, y = d.y, z = d.z }
    end
    local symbolic = false
    for _, s in ipairs((rec.unit and rec.unit.space) or {}) do
        if s.type == 'interior' or s.type == 'rooms' then symbolic = true end
    end
    return {
        id = rec.propertyId, name = rec.name, place = rec.place,
        visit = w.visit, anchor = w.anchor, doors = doors,
        fingerprint = t and t.fingerprint or nil,
        roomsKnown = t ~= nil and t.rooms ~= nil and #t.rooms > 0,
        symbolic = symbolic,
    }
end)

--- What Verify found, standing in one property. The client's checks (the interior, where it
--- stands, its doors) are an admin's word; the stand-in point is checked here as well, against the
--- property as the server has it. Rooms read from an interior whose template had none are kept:
--- they are what "the whole interior" and "these rooms" spaces are made of.
SecureEvent('whip_core:server:propertyAdminVerified', {
    ace = ACE, rateLimit = 100, burst = 10,
    params = { {'propertyId', 'id'}, {'result', 'any'} },
}, function(source, _, propertyId, res)
    local rec = Properties.get(propertyId)
    if not rec or type(res) ~= 'table' then return end
    local a = (rec.world and rec.world.anchor) or rec.place
    if not within(source, a.x, a.y, a.z, TETHER + (a.r or 0)) then return end

    local problems = {}
    for i, p in ipairs(type(res.problems) == 'table' and res.problems or {}) do
        if i > 20 then break end
        if type(p) == 'string' and p ~= '' then problems[#problems + 1] = p:sub(1, 160) end
    end

    local t = Properties.getTemplate(rec.templateId)
    if res.rooms ~= nil and t and t.archetypeHash ~= 0 and t.archetypeHash == rec.place.hash
        and not (t.rooms and #t.rooms > 0) then
        local rooms = PropertyValidate.roomsOf(res.rooms)
        if rooms and #rooms > 0 then
            local fp = type(res.fingerprint) == 'table'
                and { rooms = count(res.fingerprint.rooms), portals = count(res.fingerprint.portals) } or nil
            Properties.setTemplateRooms(t.templateId, rooms, fp)
            rec = Properties.get(propertyId)
            if not rec then return end   -- removed while the rooms were written
        end
    end

    local w = rec.world or {}
    if #(w.shapes or {}) == 0 then
        problems[#problems + 1] = w.unresolved and 'its space is the interior\'s rooms, and none could be read'
            or 'it has no space'
    elseif w.visit and not Shapes.containsAny(w.shapes, w.visit.x, w.visit.y, w.visit.z, 0.3) then
        problems[#problems + 1] = 'its stand-in point is outside its space'
    end
    Properties.setVerified(propertyId, problems)
end)

--- The instant check, from the server alone: every property in the list re-resolved and its
--- doors and garage put in step (as a boot does), and what is still wrong with each said.
SecureCallback('whip_core:property:adminQuickCheck', {
    ace = ACE, rateLimit = 2000,
    params = { {'ids', 'list', {'id', 'id'}, PropertyValidate.LIMITS.properties} },
}, function(_, _, ids)
    local checked, bad = 0, {}
    for _, id in ipairs(ids) do
        local rec = Properties.get(id)
        if rec then
            checked = checked + 1
            local problems = Properties.resync(id)
            local w = rec.world or {}
            if #(w.shapes or {}) == 0 then
                problems[#problems + 1] = w.unresolved and 'its space needs the interior\'s rooms (Verify reads them)'
                    or 'it has no space'
            elseif w.visit and not Shapes.containsAny(w.shapes, w.visit.x, w.visit.y, w.visit.z, 0.3) then
                problems[#problems + 1] = 'its stand-in point is outside its space'
            end
            if #problems > 0 then bad[#bad + 1] = { id = id, name = rec.name, problems = problems } end
        end
    end
    return { checked = checked, problems = bad }
end)

--- Write templates out as one pack (server/property_export.lua) — every interior an MLO has, in
--- the one file it ships: into whip_core/pack_exports/, and back to the panel to copy.
SecureCallback('whip_core:property:adminExport', {
    ace = ACE, rateLimit = 1000,
    params = {
        {'templateIds', 'list', {'id', 'id'}, PropertyValidate.LIMITS.templates},
        {'placements', 'bool', false},
        {'packId', 'string', 48, ''},
        {'label', 'string', 100, ''},
    },
}, function(_, _, templateIds, placements, packId, label)
    local res, err = PropertyExport.build(templateIds, {
        placements = placements, id = packId ~= '' and packId or nil, label = label ~= '' and label or nil,
    })
    -- `false, why`, whip's one refusal shape; the panel's Lua turns it into its page's form.
    if not res then return false, err or 'It did not export' end
    local path = 'pack_exports/' .. res.fileName
    local wrote = SaveResourceFile(GetCurrentResourceName(), path, res.text, -1)
    return {
        ok = true, id = res.id, text = res.text, templates = res.templates, units = res.units,
        properties = res.properties, warnings = res.warnings,
        path = wrote and (GetCurrentResourceName() .. '/' .. path) or nil,
    }
end)
