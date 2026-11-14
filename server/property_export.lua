-- ============================================
-- PROPERTY EXPORT — templates, written out as a pack
-- ============================================
--
-- The Configurator's Export pack: interiors set up here, in game, written as the same
-- whip_properties.lua file an MLO creator would ship (docs/properties.md). Put it in the MLO's
-- resource, add `whip_property_pack 'whip_properties.lua'` to its fxmanifest, and every server that
-- ensures the MLO gets the homes with no admin steps.
--
-- ONE PACK, AS MANY TEMPLATES AS THE MLO HAS. A resource ships one pack, and one resource is often
-- many interiors — the Billabong homes are eleven, Mega Apartments seven — so an export takes a
-- list of templates and writes them all into the one file.
--
-- PLAIN DATA ONLY: tables, quoted strings, numbers, booleans and vec3(...). That is exactly what the
-- pack reader parses without running anything (PropertyPacks.runSource, "1. Plain data, parsed"),
-- and the export is read back through it — and through the validator — before it is handed out, so
-- a file this writes is a file whip accepts.
--
-- WHAT A PACK CANNOT CARRY is said in the file's header rather than silently dropped: a single
-- property's own changes (Move for this one only), its owner, keys and furniture.

PropertyExport = {}

local function num(n)
    n = tonumber(n) or 0
    if math.type(n) == 'integer' then return tostring(n) end
    local s = ('%.3f'):format(n)
    s = (s:gsub('0+$', ''))
    s = (s:gsub('%.$', ''))
    if s == '-0' then s = '0' end
    return s
end

local function str(s)
    s = tostring(s)
    s = (s:gsub('\\', '\\\\'))
    s = (s:gsub("'", "\\'"))
    s = (s:gsub('\n', '\\n'))
    return "'" .. s .. "'"
end

local function vec(p)
    return ('vec3(%s, %s, %s)'):format(num(p.x), num(p.y), num(p.z))
end

--- Text for a comment line: a name with a line break in it would end the comment and turn the
--- rest into code.
local function oneLine(s)
    return (tostring(s):gsub('[\r\n]+', ' '))
end

--- A name made safe for a key: lower case, letters, numbers, _ - and .
local function slug(s, fallback)
    s = tostring(s or ''):lower()
    s = (s:gsub('[^a-z0-9_.-]+', '_'))
    s = (s:gsub('^_+', ''))
    s = (s:gsub('_+$', ''))
    if s == '' then s = fallback end
    return s
end

local function shapeText(s)
    if s.type == 'box' then
        return ("{ type = 'box', center = %s, size = %s, heading = %s }")
            :format(vec(s.center or s.pos), vec(s.size), num(s.heading or 0))
    elseif s.type == 'poly' then
        local pts = {}
        for i, p in ipairs(s.points or {}) do pts[i] = ('{ x = %s, y = %s }'):format(num(p.x or p[1]), num(p.y or p[2])) end
        return ("{ type = 'poly', points = { %s }, minZ = %s, maxZ = %s }")
            :format(table.concat(pts, ', '), num(s.minZ), num(s.maxZ))
    elseif s.type == 'rooms' then
        local names = {}
        for i, n in ipairs(s.rooms or {}) do names[i] = str(n) end
        return ("{ type = 'rooms', rooms = { %s } }"):format(table.concat(names, ', '))
    end
    return "{ type = 'interior' }"
end

local function pointText(p)
    -- The outside sign's post, when it stands on one (Config.PropertySignPosts).
    if p.post then
        return ('{ pos = %s, heading = %s, post = %s }'):format(vec(p.pos), num(p.heading or 0), str(p.post))
    end
    return ('{ pos = %s, heading = %s }'):format(vec(p.pos), num(p.heading or 0))
end

local function doorText(d)
    local out = ('{ key = %s, role = %s, model = %s, pos = %s, heading = %s'):format(
        str(d.key), str(d.role or 'interior'), num(PropertyMath.signedHash(d.model) or d.model), vec(d.pos), num(d.heading or 0))
    if d.lock then out = out .. ', lock = true' end
    if d.pair then out = out .. ', pair = ' .. str(d.pair) end
    return out .. ' }'
end

--- One template's entry in `templates = { ... }`.
local function writeTemplate(w, t, tkey)
    w('        {')
    w(('            key       = %s,'):format(str(tkey)))
    w(('            label     = %s,'):format(str(t.label or 'Interior')))
    w(('            archetype = %s,'):format(t.archetype and str(t.archetype) or num(t.archetypeHash)))
    if t.fingerprint and (t.fingerprint.rooms or t.fingerprint.portals) then
        w(('            fingerprint = { rooms = %s, portals = %s },'):format(
            num(t.fingerprint.rooms or 0), num(t.fingerprint.portals or 0)))
    end
    if t.settings and next(t.settings) then
        local s = {}
        for _, k in ipairs({ 'price', 'maxObjects', 'autolock', 'autolockDelay' }) do
            local v = t.settings[k]
            if v ~= nil then s[#s + 1] = ('%s = %s'):format(k, type(v) == 'boolean' and tostring(v) or num(v)) end
        end
        if #s > 0 then w(('            settings = { %s },'):format(table.concat(s, ', '))) end
    end
    if t.rooms and #t.rooms > 0 then
        w('            rooms = {')
        for _, r in ipairs(t.rooms) do
            w(('                { name = %s, min = %s, max = %s },'):format(str(r.name), vec(r.min), vec(r.max)))
        end
        w('            },')
    end

    local units = {}
    for key, u in pairs(t.units) do units[#units + 1] = { key = key, u = u } end
    table.sort(units, function(a, b) return (a.u.sortOrder or 0) < (b.u.sortOrder or 0) end)

    w('            units = {')
    for _, e in ipairs(units) do
        local u = Properties.resolvedUnit(t.templateId, e.key) or {}
        w('                {')
        w(('                    key   = %s,'):format(str(e.key)))
        w(('                    label = %s,'):format(str(e.u.label or e.key)))
        w('                    space = {')
        for _, s in ipairs(u.space or {}) do w('                        ' .. shapeText(s) .. ',') end
        w('                    },')
        if u.doors and #u.doors > 0 then
            w('                    doors = {')
            for _, d in ipairs(u.doors) do w('                        ' .. doorText(d) .. ',') end
            w('                    },')
        end
        if u.sign then w('                    sign    = ' .. pointText(u.sign) .. ',') end
        if u.manager then w('                    manager = ' .. pointText(u.manager) .. ',') end
        if u.visit then w('                    visit   = ' .. vec(u.visit) .. ',') end
        if u.garage and u.garage.bays and #u.garage.bays > 0 then
            w('                    garage  = { bays = {')
            for _, b in ipairs(u.garage.bays) do w('                        ' .. pointText(b) .. ',') end
            w('                    } },')
        end
        w('                },')
    end
    w('            },')
    w('        },')
    return #units
end

--- The pack text for some templates, and (with `placements`) every property built on them.
---
---   templateIds   one id, or a list: every interior the MLO has, into one pack
---   opts          { placements = boolean, id = 'yourname.mlo' | nil, label = string | nil }
---@return table|nil result  { id, text, fileName, templates, units, properties, warnings }
---@return string|nil err
function PropertyExport.build(templateIds, opts)
    opts = opts or {}
    if type(templateIds) ~= 'table' then templateIds = { templateIds } end

    local list, seen = {}, {}
    for _, id in ipairs(templateIds) do
        local t = Properties.getTemplate(id)
        if not t then return nil, ('There is no template #%s'):format(tostring(id)) end
        if (t.archetypeHash or 0) == 0 then
            return nil, ('"%s" is an open-world property: it has no interior to ship with'):format(t.label or ('#' .. id))
        end
        if not seen[t.templateId] then
            seen[t.templateId] = true
            list[#list + 1] = t
        end
    end
    if #list == 0 then return nil, 'Pick a template to export' end
    if #list > PropertyValidate.LIMITS.templates then return nil, 'Too many templates for one pack' end
    table.sort(list, function(a, b) return a.templateId < b.templateId end)

    local first = list[1]
    local packId = opts.id
    if type(packId) ~= 'string' or not packId:match('^[a-z0-9_.-]+$') or #packId < 3 or #packId > 48 then
        packId = ('export.' .. slug(first.archetype or first.label, 'interior')):sub(1, 48)
    end
    local label = type(opts.label) == 'string' and opts.label ~= '' and opts.label:sub(1, 100)
        or (#list == 1 and first.label) or ((first.label or 'Interior') .. ' and more')

    -- Template keys: from each label, unique in the pack.
    local tkeys, usedT = {}, {}
    for _, t in ipairs(list) do
        local k = slug(t.label, 'interior'):sub(1, 60)
        if usedT[k] then k = (k .. '_' .. t.templateId):sub(1, 64) end
        usedT[k] = true
        tkeys[t.templateId] = k
    end

    local props = {}
    if opts.placements then
        for _, rec in pairs(Properties.getAll()) do
            if seen[rec.templateId] then props[#props + 1] = rec end
        end
        table.sort(props, function(a, b) return a.propertyId < b.propertyId end)
    end

    local L = {}
    local function w(line) L[#L + 1] = line end
    local warnings = {}

    -- ---- header ----
    w(('-- %s — a whip property pack, exported %s.'):format(oneLine(label), os.date('%Y-%m-%d')))
    w('--')
    w('-- Put this file in your MLO\'s resource and add one line to its fxmanifest.lua:')
    w("--     whip_property_pack 'whip_properties.lua'")
    w('-- It is plain data: whip reads it without running it. See whip_core/docs/properties.md.')
    for _, rec in ipairs(props) do
        local own = {}
        for part in pairs(rec.overrides or {}) do own[#own + 1] = part end
        if #own > 0 then
            table.sort(own)
            warnings[#warnings + 1] = ('%s (#%d) has its own %s, which a pack cannot carry — it gets the unit\'s')
                :format(rec.name, rec.propertyId, table.concat(own, ', '))
        end
    end
    if #warnings > 0 then
        w('--')
        w('-- NOT IN THIS FILE:')
        for _, line in ipairs(warnings) do w('--   ' .. oneLine(line)) end
    end
    w('')

    -- ---- the pack ----
    w('return {')
    w('    format  = 1,')
    w(('    id      = %s,'):format(str(packId)))
    w("    version = '1.0.0',")
    w(('    label   = %s,'):format(str(label)))
    w('')
    w('    templates = {')
    local unitCount = 0
    for _, t in ipairs(list) do unitCount = unitCount + writeTemplate(w, t, tkeys[t.templateId]) end
    w('    },')

    if #props > 0 then
        w('')
        w('    properties = {')
        local used = {}
        for _, rec in ipairs(props) do
            local key = slug(rec.name, 'p' .. rec.propertyId):sub(1, 60)
            if used[key] then key = (key .. '_' .. rec.propertyId):sub(1, 64) end
            used[key] = true
            local p = rec.place
            local fields = {
                ('key = %s'):format(str(key)), ('template = %s'):format(str(tkeys[rec.templateId])),
                ('unit = %s'):format(str(rec.unitKey)), ('name = %s'):format(str(rec.name or 'Property')),
            }
            if rec.label then fields[#fields + 1] = ('label = %s'):format(str(rec.label)) end
            if rec.building then fields[#fields + 1] = ('building = %s'):format(str(rec.building)) end
            w('        { ' .. table.concat(fields, ', ') .. ',')
            w(('          placement = { pos = %s, heading = %s } },'):format(vec(p), num(p.yaw or 0)))
        end
        w('    },')
    end
    w('}')

    local text = table.concat(L, '\n') .. '\n'

    -- READ BACK, the way a server will read it: a file whip would refuse is not handed out.
    local data, rerr = PropertyPacks.runSource(text, '=export')
    if not data then return nil, 'the export could not be read back: ' .. tostring(rerr) end
    local pack, verr = PropertyValidate.pack(data)
    if not pack then return nil, 'the export did not pass the checker: ' .. tostring(verr) end

    return {
        id = packId, text = text, fileName = packId .. '.lua',
        templates = #list, units = unitCount, properties = #props, warnings = warnings,
    }
end

--- For whip_test: an export, without writing a file. Inert unless Config.EnableTestSeams.
exports('__TestPropertyExport', function(templateIds, opts)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    local res, err = PropertyExport.build(templateIds, opts)
    if not res then return false, err end
    return res
end)
