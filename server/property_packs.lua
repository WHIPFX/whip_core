-- ============================================
-- Property packs — an MLO that registers itself
-- ============================================
--
-- THE CREATOR'S HALF OF PROPERTIES. An interior designer ships their MLO with one data file, and a
-- server that runs whip gets its homes the moment the resource is ensured: download, ensure, done.
--
--     -- in the MLO's fxmanifest.lua
--     whip_property_pack 'whip_properties.lua'     -- or a .json file
--
-- The file describes templates (one per interior archetype, with its units in the interior's own
-- space) and, if the creator knows where their interior is placed, the properties themselves. The
-- format is in docs/properties.md. A resource can also hand the same table to
-- exports.whip_core:RegisterPropertyPack(data) from its own script.
--
-- WHAT APPLYING A PACK MAY AND MAY NOT TOUCH, because a pack is updated by its author and the
-- server is lived in by its players:
--
--   may      a template, its units' base, and each property's template, unit and placement —
--            and its name, label and building, UNLESS an admin has changed that one since
--   never    an owner, a key, a piece of furniture, an admin's settings or overlay
--
--   UNCHANGED   a pack identical to the one last applied writes nothing at all.
--   DELETED     a property an admin deleted is tombstoned and never made again.
--   DROPPED     a property the pack no longer lists is flagged "orphaned" for an admin, not removed.
--   CONFLICT    a pack changing a unit part an admin had changed flags the properties using it.
--   CLAIMED     a pack property landing on an admin's property (same interior, same placement,
--               same flat) takes that one over, keeping its owner, keys and furniture.
--   STOPPED     a pack whose resource stops leaves its properties in place but closed.
--   ONE OWNER   a pack id belongs to one resource. Another resource sending the same id while the
--               first is running is refused.
--
-- A .lua PACK IS DATA, NOT A SCRIPT — READ, NEVER RUN.
--
--   A file that is `return { ... }` of tables, strings, numbers, booleans and vec3(x, y, z) is read
--   by readLiteral below, which never executes a line of it. That is the bungalow's pack, and what
--   the Configurator's Export writes. A file with code in it (loops, variables) is refused unread,
--   with a message saying to write it as a plain table or JSON, or to build the table in the
--   resource's own script and hand it to RegisterPropertyPack.
--
-- No code packs: a data file never runs code. A sandbox's instruction limit can't stop a mistake
-- inside one C call (a huge ('x'):rep(n), a runaway `s = s .. s`), which could stall the server
-- thread or eat its memory.

PropertyPacks = {}

local _packs    = {}   -- [packId] = { packId, resource, version, label, snapshot, appliedAt }
local _problems = {}   -- [resource .. ':' .. file] = error sentence, for the admin panel
local _ready    = false
local _queue    = {}   -- packs registered by export before the boot scan finished

local METADATA_KEY = 'whip_property_pack'
local SOURCE_CAP = 512 * 1024

local function log(msg, ...) print(('[whip_core:packs] ' .. msg):format(...)) end

-- ============================================
-- Database
-- ============================================

function PropertyPacks.ensureTable()
    local ok, err = pcall(MySQL.query.await, WithTableCollation [[
        CREATE TABLE IF NOT EXISTS `property_packs` (
            `packId`    VARCHAR(48)  NOT NULL,
            `resource`  VARCHAR(64)  NOT NULL,
            `version`   VARCHAR(32)  NULL,
            `label`     VARCHAR(100) NULL,
            `snapshot`  MEDIUMTEXT   NULL,
            `appliedAt` TIMESTAMP    NULL,
            PRIMARY KEY (`packId`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]], {})
    if not ok then log('ERROR creating property_packs: %s', tostring(err)) end
    return ok
end

--- Forward-declared: loadAll, above it, compares with it.
local canonical

--- The pack as last applied is stored whole (`snapshot`, JSON). It is what "has it changed" is
--- asked of, and what "did the admin change this name since the pack set it" is answered from.
function PropertyPacks.loadAll()
    PropertyPacks.ensureTable()
    _packs = {}
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `property_packs`', {})
    if not ok then log('ERROR loading packs: %s', tostring(rows)); return false end
    for _, r in ipairs(rows or {}) do
        local dok, pack = pcall(json.decode, r.snapshot or '')
        r.pack = dok and type(pack) == 'table' and pack or nil
        r.canon = r.pack and canonical(r.pack) or nil
        _packs[r.packId] = r
    end
end

-- ============================================
-- Reading a pack file
-- ============================================

--- Copy only plain data out of a pack (a JSON file, or a table a resource hands RegisterPropertyPack):
--- tables, strings, numbers, booleans, and vectors (as { x, y, z }). A function, or anything else, is
--- refused with where it was.
local function plain(v, path, depth)
    local t = type(v)
    if t == 'string' or t == 'number' or t == 'boolean' then return v end
    if t == 'vector3' or t == 'vector4' then return { x = v.x, y = v.y, z = v.z } end
    if t == 'table' then
        if depth > 16 then error(('%s: nested too deeply'):format(path), 0) end
        local out = {}
        for k, val in pairs(v) do
            if type(k) ~= 'string' and type(k) ~= 'number' then error(('%s: a key must be a name or a number'):format(path), 0) end
            local kp = type(k) == 'number' and ('%s[%d]'):format(path, k) or (path == '' and k or path .. '.' .. k)
            out[k] = plain(val, kp, depth + 1)
        end
        return out
    end
    error(('%s: a %s cannot be part of a pack (only data)'):format(path == '' and 'the pack' or path, t), 0)
end
PropertyPacks.plain = function(v) return plain(v, '', 0) end

-- ============================================
-- Plain data, parsed — never run
-- ============================================

--- Read `return { ... }` as data: tables (with name = value, [key] = value, or positional
--- entries), strings (quoted or [[long]]), numbers (with a leading minus), true, false, nil and
--- vec3(x, y, z) / vector3(...). Comments are skipped. Anything else — a variable, a loop, a call —
--- is not data, and is reported as `{ code = true }` so the caller can decide what to do with it.
---
--- A PARSER, NOT A LOADER: it walks the text once, left to right, and every loop in it consumes at
--- least one character, so it finishes on any input.
---@return any data  the file's value (runSource checks it is a table)
local function readLiteral(src)
    local pos, len = 1, #src

    local function lineAt(p)
        local n = 1
        for _ in src:sub(1, p):gmatch('\n') do n = n + 1 end
        return n
    end
    local function bad(msg) error({ msg = ('line %d: %s'):format(lineAt(pos), msg) }, 0) end
    local function code(what) error({ code = true, msg = ('line %d: %s'):format(lineAt(pos), what) }, 0) end

    local function skip()
        while pos <= len do
            local ws = src:match('^%s+', pos)
            if ws then pos = pos + #ws end
            if src:sub(pos, pos + 1) ~= '--' then return end
            local eqs = src:match('^%-%-%[(=*)%[', pos)
            if eqs then
                local close = ']' .. eqs .. ']'
                local e = src:find(close, pos + 4 + #eqs, true)
                if not e then bad('a --[[ comment that never ends') end
                pos = e + #close
            else
                local e = src:find('\n', pos, true)
                pos = e and (e + 1) or (len + 1)
            end
        end
    end

    local function expect(ch)
        skip()
        if src:sub(pos, pos) ~= ch then bad(('a "%s" was expected here'):format(ch)) end
        pos = pos + 1
    end

    local function readString()
        local q = src:sub(pos, pos)
        if q == '"' or q == "'" then
            local out = {}
            pos = pos + 1
            while true do
                local c = src:sub(pos, pos)
                if c == '' or c == '\n' then bad('a string that never ends') end
                if c == q then pos = pos + 1 break end
                if c == '\\' then
                    local n = src:sub(pos + 1, pos + 1)
                    local map = { n = '\n', t = '\t', r = '\r', ['\\'] = '\\', ['"'] = '"', ["'"] = "'" }
                    if map[n] then
                        out[#out + 1] = map[n]
                        pos = pos + 2
                    else
                        bad('a \\ escape a pack cannot use: \\' .. n)
                    end
                else
                    out[#out + 1] = c
                    pos = pos + 1
                end
            end
            return table.concat(out)
        end
        local eqs = src:match('^%[(=*)%[', pos)
        if eqs then
            local close = ']' .. eqs .. ']'
            local s = pos + 2 + #eqs
            if src:sub(s, s) == '\n' then s = s + 1 end
            local e = src:find(close, s, true)
            if not e then bad('a [[ string that never ends') end
            pos = e + #close
            return src:sub(s, e - 1)
        end
        return nil
    end

    local function readNumber()
        local s = src:match('^0[xX]%x+', pos)
            or src:match('^%d+%.?%d*[eE][%+%-]?%d+', pos)
            or src:match('^%.%d+[eE][%+%-]?%d+', pos)
            or src:match('^%d+%.?%d*', pos)
            or src:match('^%.%d+', pos)
        if not s then return nil end
        pos = pos + #s
        return tonumber(s)
    end

    local readValue

    local function readTable(depth)
        pos = pos + 1   -- the {
        local t, n = {}, 0
        while true do
            skip()
            if pos > len then bad('a { that is never closed') end
            local c = src:sub(pos, pos)
            if c == '}' then pos = pos + 1 return t end

            -- `name = value`: a name, spaces, one '=' (two would be a comparison, which is code).
            local name, after = src:match('^([%a_][%w_]*)%s*()', pos)
            if name and src:sub(after, after) == '=' and src:sub(after + 1, after + 1) ~= '=' then
                pos = after + 1
                t[name] = readValue(depth + 1)
            elseif c == '[' and not src:match('^%[=*%[', pos) then
                pos = pos + 1
                local k = readValue(depth + 1)
                if type(k) ~= 'string' and type(k) ~= 'number' then bad('a [key] must be text or a number') end
                expect(']')
                expect('=')
                t[k] = readValue(depth + 1)
            else
                n = n + 1
                t[n] = readValue(depth + 1)
            end

            skip()
            local sep = src:sub(pos, pos)
            if sep == ',' or sep == ';' then
                pos = pos + 1
            elseif sep ~= '}' then
                bad('a , or } was expected here')
            end
        end
    end

    function readValue(depth)
        if depth > 20 then bad('nested too deeply') end
        skip()
        local c = src:sub(pos, pos)
        if c == '{' then return readTable(depth) end
        if c == '-' then
            pos = pos + 1
            skip()
            local v = readNumber()
            if not v then code('a minus that is not in front of a number') end
            return -v
        end
        local s = readString()
        if s ~= nil then return s end
        local v = readNumber()
        if v ~= nil then return v end

        local word = src:match('^[%a_][%w_]*', pos)
        if word == 'true' then pos = pos + 4 return true end
        if word == 'false' then pos = pos + 5 return false end
        if word == 'nil' then pos = pos + 3 return nil end
        if word == 'vec3' or word == 'vector3' then
            pos = pos + #word
            expect('(')
            local x = readValue(depth + 1); expect(',')
            local y = readValue(depth + 1); expect(',')
            local z = readValue(depth + 1); expect(')')
            if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
                code(word .. '(...) with something other than three numbers in it')
            end
            return { x = x, y = y, z = z }
        end
        if word then code(('"%s" — a name, a call or a keyword, which is code rather than data'):format(word)) end
        if c == '' then bad('the file ends in the middle of a value') end
        code(('"%s" — not part of plain data'):format(c))
    end

    skip()
    if not src:match('^return[^%w_]', pos) then code('the file does not start with `return {`') end
    pos = pos + 6
    local v = readValue(0)
    skip()
    if pos <= len then code('something after the table') end
    return v
end

--- A .lua pack's text as a table: parsed if it is plain data, refused otherwise. Never run.
---@param _ string|nil  unused since code packs went; kept so callers need not change
---@return table|nil data, string|nil err
function PropertyPacks.runSource(src, _)
    if type(src) ~= 'string' then return nil, 'no file' end
    if #src > SOURCE_CAP then return nil, ('the file is %d KB; a pack can be at most %d KB'):format(#src // 1024, SOURCE_CAP // 1024) end
    if src:byte(1) == 27 then return nil, 'compiled Lua is not accepted — ship the .lua text' end
    -- Not text at all: most likely encrypted by FiveM's asset escrow, which encrypts every .lua it is not told to
    -- leave alone. Said as that, not as "this file uses code".
    if src:sub(1, 4) == 'FXAP' or src:find('\0', 1, true) then
        return nil, 'this file is not text (encrypted by the asset escrow?): list it in escrow_ignore in your '
            .. 'fxmanifest, or ship the pack as .json'
    end

    local lok, literal = pcall(readLiteral, src)
    if lok then
        if type(literal) ~= 'table' then return nil, 'the file must be `return { ... }`' end
        return literal
    end
    local why = type(literal) == 'table' and literal.msg or tostring(literal)
    if type(literal) == 'table' and not literal.code then
        return nil, 'the file is not valid: ' .. why
    end
    return nil, ('this file uses code (%s), and a pack file is data — write it as a plain '
        .. '`return { ... }` table or as JSON, or build the table in your resource\'s own script and '
        .. 'hand it to RegisterPropertyPack'):format(why)
end

--- A pack file of a resource, as a table.
---@return table|nil data, string|nil err
local function readPackFile(resource, file)
    local src = LoadResourceFile(resource, file)
    if not src then return nil, ('%s does not have the file %s'):format(resource, file) end
    if file:lower():match('%.json$') then
        local ok, data = pcall(json.decode, src)
        if not ok or type(data) ~= 'table' then return nil, 'the file is not valid JSON' end
        local copied, res = pcall(plain, data, '', 0)
        if not copied then return nil, tostring(res) end
        return res
    end
    return PropertyPacks.runSource(src, ('@%s/%s'):format(resource, file))
end

-- ============================================
-- The snapshot
-- ============================================

--- A pack written out the same way every time, whatever order its tables were built in — so
--- "has this pack changed since it was last applied" is one string comparison.
function canonical(v)
    local t = type(v)
    if t == 'table' then
        local n = #v
        local isList = n > 0 or next(v) == nil
        if isList then
            for k in pairs(v) do if type(k) ~= 'number' then isList = false break end end
        end
        local parts = {}
        if isList then
            for i = 1, n do parts[i] = canonical(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for i, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            parts[i] = ('%q:%s'):format(k, canonical(val))
        end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif t == 'number' then
        -- ONE FORM FOR EVERY NUMBER. A pack read back from its stored JSON can come back with 1.0
        -- where it went in as 1, and the two must compare equal or an unchanged pack would be
        -- re-applied at every start.
        if v % 1 == 0 and math.abs(v) < 1e15 then return ('%d'):format(v) end
        return ('%.6f'):format(v)
    elseif t == 'string' then
        return ('%q'):format(v)
    end
    return tostring(v)
end

-- ============================================
-- Applying a pack
-- ============================================

local function samePlace(a, b)
    return a and b and PropertyMath.samePlacement(a, b, 0.05, 0.05)
end

--- An admin's property this pack property would land on: same interior, same placement, and the
--- pack unit's own visit point inside the admin property's space (so the right flat of four).
local function findClaim(template, unitKey, place)
    local unit = template.units[unitKey]
    if not unit then return nil end
    local w = PropertyMath.unitToWorld(place, unit.base or {}, template.rooms)
    local probe = w.visit or w.anchor
    if not probe then return nil end
    for _, rec in pairs(Properties.getAll()) do
        if rec.source == 'admin' and rec.place.hash == place.hash
            and PropertyMath.samePlacement(rec.place, place)
            and rec.world and Shapes.containsAny(rec.world.shapes, probe.x, probe.y, probe.z, 0.5) then
            return rec
        end
    end
    return nil
end

--- Write a normalised pack into the templates and properties. The "may and may not" of the header
--- is enforced here. Returns what changed, for the log.
local function writePack(pack, _, previous)
    local source = 'pack:' .. pack.id
    local counts = { templates = 0, created = 0, updated = 0, claimed = 0, tombstoned = 0 }
    local templates = {}

    for _, t in ipairs(pack.templates) do
        local key = pack.id .. ':' .. t.key
        local existing = Properties.getTemplateByKey(key)
        local saved, err = Properties.saveTemplate({
            templateKey = key, source = source, label = t.label or t.key,
            archetype = t.archetype, archetypeHash = t.archetypeHash,
            fingerprint = t.fingerprint,
            -- Rooms a Verify tour found are kept when the pack does not bring its own.
            rooms = t.rooms or (existing and existing.rooms),
            settings = t.settings, packVersion = pack.version,
        }, { quiet = true })
        if not saved then return nil, ('template "%s": %s'):format(t.key, tostring(err)) end
        counts.templates = counts.templates + 1

        local inPack = {}
        for _, u in ipairs(t.units) do
            inPack[u.key] = true
            local base = PropertyValidate.unitBase(u)
            local prev = saved.units[u.key]
            local overlay = prev and prev.overlay
            -- A PART THE ADMIN CHANGED, THAT THE PACK HAS NOW CHANGED TOO. Neither wins silently:
            -- the admin's stays in force, and the properties using it are flagged to choose.
            if overlay and prev then
                for part, v in pairs(overlay) do
                    if part:sub(1, 1) ~= '_' and v ~= nil
                        and not Registry.deepEquals(prev.base and prev.base[part], base[part]) then
                        overlay._conflicts = overlay._conflicts or {}
                        overlay._conflicts[part] = true
                    end
                end
            end
            local ok, uerr = Properties.saveUnit(saved.templateId, u.key,
                { label = u.label or u.key, sortOrder = u.sortOrder, base = base, overlay = overlay or false },
                { quiet = true })
            if not ok then return nil, ('template "%s" unit "%s": %s'):format(t.key, u.key, tostring(uerr)) end
        end
        -- Units the pack has stopped describing go, unless a property still uses one (that
        -- property is then flagged orphaned below, and keeps working as it was).
        for unitKey in pairs(saved.units) do
            if not inPack[unitKey] then Properties.deleteUnit(saved.templateId, unitKey) end
        end
        templates[t.key] = saved
    end

    local tombstoned = Properties.tombstonedKeys(source)
    local prevProps = {}
    for _, p in ipairs((previous and previous.properties) or {}) do prevProps[p.key] = p end

    for _, p in ipairs(pack.properties) do
        local pkey = pack.id .. ':' .. p.key
        local t = templates[p.template]
        local place = { hash = t.archetypeHash, x = p.place.x, y = p.place.y, z = p.place.z, yaw = p.place.yaw }

        if tombstoned[pkey] then
            counts.tombstoned = counts.tombstoned + 1
        else
            local rec = Properties.getByKey(pkey)
            if rec then
                -- CHANGE ONLY WHAT STILL SAYS WHAT THE PACK SAID LAST TIME. A name an admin has
                -- changed since is theirs; a name nobody touched follows the pack.
                local was = prevProps[p.key]
                local fields = {}
                if rec.templateId ~= t.templateId or rec.unitKey ~= p.unit then
                    fields.unit = { templateId = t.templateId, unitKey = p.unit }
                end
                for _, f in ipairs({ 'name', 'label', 'building' }) do
                    local mine = rec[f]
                    local packNow = p[f]
                    local packThen = was and was[f]
                    if packNow ~= mine and (was == nil or mine == packThen) then fields[f] = packNow or false end
                end
                local wasPlace = was and { hash = place.hash, x = was.place.x, y = was.place.y, z = was.place.z, yaw = was.place.yaw }
                if not samePlace(rec.place, place) and (wasPlace == nil or samePlace(rec.place, wasPlace)) then
                    fields.place = place
                end
                if next(fields) then
                    local ok, uerr = Properties.update(rec.propertyId, fields)
                    if not ok then log('%s: could not update %s: %s', pack.id, p.key, tostring(uerr)) end
                    counts.updated = counts.updated + 1
                end
            else
                local claim = findClaim(t, p.unit, place)
                if claim then
                    local ok, cerr = Properties.claim(claim.propertyId, pkey, source, t.templateId, p.unit, place)
                    if ok then
                        counts.claimed = counts.claimed + 1
                    else
                        log('%s: could not take over property #%d for %s: %s', pack.id, claim.propertyId, p.key, tostring(cerr))
                    end
                else
                    local created, cerr = Properties.create({
                        propertyKey = pkey, source = source, templateId = t.templateId, unitKey = p.unit,
                        place = place, name = p.name, label = p.label, building = p.building, settings = p.settings,
                    })
                    if created then
                        counts.created = counts.created + 1
                    else
                        log('%s: could not create %s: %s', pack.id, p.key, tostring(cerr))
                    end
                end
            end
        end
    end

    -- Every property built on these templates takes the new units, once, now.
    for id, rec in pairs(Properties.getAll()) do
        if rec.source == source then Properties.resync(id) end
    end
    return counts
end

--- The in-memory pass, every time: this pack's properties are open, and each is flagged if the
--- pack dropped it or changed a part its admin had changed. No writes.
local function flagPack(pack)
    local source = 'pack:' .. pack.id
    local listed = {}
    for _, p in ipairs(pack.properties) do listed[pack.id .. ':' .. p.key] = true end
    for id, rec in pairs(Properties.getAll()) do
        if rec.source == source then
            local issue = nil
            if not listed[rec.propertyKey] then
                issue = 'orphaned: the pack no longer lists it — adopt it or delete it'
            else
                local t = Properties.getTemplate(rec.templateId)
                local u = t and t.units[rec.unitKey]
                local c = u and u.overlay and u.overlay._conflicts
                if c and next(c) then
                    local parts = {}
                    for part in pairs(c) do parts[#parts + 1] = part end
                    table.sort(parts)
                    issue = ('conflict: the pack changed %s, which an admin had changed — keep yours or use the pack\'s')
                        :format(table.concat(parts, ', '))
                end
            end
            Properties.setPackState(id, true, issue)
        end
    end
end

--- Validate and apply one pack from `resource`.
---@return boolean ok, string howOrErr  'applied' | 'unchanged', or why not
function PropertyPacks.apply(data, resource)
    local pack, err = PropertyValidate.pack(data)
    if not pack then return false, err --[[@as string]] end

    local row = _packs[pack.id]
    if row and row.resource ~= resource and GetResourceState(row.resource) == 'started' then
        return false, ('the pack id "%s" already belongs to %s, which is running'):format(pack.id, row.resource)
    end

    local canon = canonical(pack)
    if row and row.canon == canon and row.resource == resource then
        flagPack(pack)
        return true, 'unchanged'
    end

    local counts, werr = writePack(pack, resource, row and row.pack)
    if not counts then return false, werr --[[@as string]] end

    local ok, dberr = pcall(MySQL.query.await,
        'INSERT INTO `property_packs` (`packId`,`resource`,`version`,`label`,`snapshot`,`appliedAt`) '
        .. 'VALUES (?,?,?,?,?,CURRENT_TIMESTAMP) ON DUPLICATE KEY UPDATE `resource`=VALUES(`resource`), '
        .. '`version`=VALUES(`version`), `label`=VALUES(`label`), `snapshot`=VALUES(`snapshot`), '
        .. '`appliedAt`=CURRENT_TIMESTAMP',
        { pack.id, resource, pack.version, pack.label, json.encode(pack) })
    if not ok then return false, 'the pack applied, but its record did not save: ' .. tostring(dberr) end

    _packs[pack.id] = { packId = pack.id, resource = resource, version = pack.version, label = pack.label,
                        pack = pack, canon = canon }
    flagPack(pack)
    log('%s %s (from %s): %d template(s); %d propert%s made, %d updated, %d taken over, %d deleted by an admin',
        pack.id, pack.version, resource, counts.templates, counts.created, counts.created == 1 and 'y' or 'ies',
        counts.updated, counts.claimed, counts.tombstoned)
    return true, 'applied'
end

--- A pack's properties close: its resource has stopped. They stay, owned, with their furniture.
local function closePack(packId)
    Properties.setPackStateBySource('pack:' .. packId, false)
end

-- ============================================
-- Discovery
-- ============================================

--- Every pack file a resource declares, applied.
local function scanResource(resource)
    local n = GetNumResourceMetadata(resource, METADATA_KEY) or 0
    for i = 0, n - 1 do
        local file = GetResourceMetadata(resource, METADATA_KEY, i)
        if file and file ~= '' then
            local where = resource .. ':' .. file
            local data, err = readPackFile(resource, file)
            local ok, how = false, err
            if data then ok, how = PropertyPacks.apply(data, resource) end
            if ok then
                _problems[where] = nil
            else
                _problems[where] = how
                log('REFUSED %s/%s — %s', resource, file, tostring(how))
            end
        end
    end
end

--- At boot, after the properties are loaded: every running resource's packs, then everything
--- no running pack answered for is closed.
function PropertyPacks.scanAll()
    local applied = {}
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and GetResourceState(res) == 'started' then scanResource(res) end
    end
    _ready = true
    -- A pack queued before boot is answered here, and a refusal is said: its caller was told
    -- `true, 'queued'`, so a refusal is recorded the way a manifest line's is (scanResource, above).
    for _, item in ipairs(_queue) do
        local where = tostring(item.resource) .. ':export'
        local ok, how = PropertyPacks.apply(item.data, item.resource)
        if ok then
            _problems[where] = nil
        else
            _problems[where] = how
            log('REFUSED %s (RegisterPropertyPack, queued before whip_core was ready) — %s',
                tostring(item.resource), tostring(how))
        end
    end
    _queue = {}

    for packId, row in pairs(_packs) do
        if GetResourceState(row.resource) ~= 'started' then closePack(packId) end
        applied[packId] = true
    end
    -- A pack property whose pack record has gone entirely.
    for id, rec in pairs(Properties.getAll()) do
        local packId = rec.source and rec.source:match('^pack:(.+)$')
        if packId and not applied[packId] then Properties.setPackState(id, false, 'its pack is not installed') end
    end
end

AddEventHandler('onResourceStart', function(resource)
    if not _ready or resource == GetCurrentResourceName() then return end
    scanResource(resource)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end
    for packId, row in pairs(_packs) do
        if row.resource == resource then closePack(packId) end
    end
    for where in pairs(_problems) do
        if where:sub(1, #resource + 1) == resource .. ':' then _problems[where] = nil end
    end
end)

--- The packs and the files that were refused, for the admin panel.
function PropertyPacks.list()
    local out = { packs = {}, problems = {} }
    for id, row in pairs(_packs) do
        out.packs[#out.packs + 1] = { id = id, resource = row.resource, version = row.version, label = row.label,
                                      running = GetResourceState(row.resource) == 'started' }
    end
    table.sort(out.packs, function(a, b) return a.id < b.id end)
    for where, err in pairs(_problems) do out.problems[#out.problems + 1] = { file = where, error = err } end
    table.sort(out.problems, function(a, b) return a.file < b.file end)
    return out
end

-- ============================================
-- Exports
-- ============================================

--- Register a pack from a script instead of the manifest line. The pack belongs to the resource
--- that calls this.
---@return boolean ok, string howOrErr
exports('RegisterPropertyPack', function(data)
    local resource = Registry.caller()   -- first, before anything can yield
    local copied, res = pcall(plain, data, '', 0)
    if not copied then return false, tostring(res) end
    if not _ready then
        _queue[#_queue + 1] = { data = res, resource = resource }
        return true, 'queued'
    end
    return PropertyPacks.apply(res, resource)
end)

exports('GetPropertyPacks', function() return PropertyPacks.list() end)

-- ============================================
-- Test seams
-- ============================================

exports('__TestPackSource', function(src)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    local data, err = PropertyPacks.runSource(src, '=test')
    if not data then return false, err end
    return true, data
end)

--- Take a test pack away entirely: its properties, templates and record. Only a pack whose id
--- starts with "_test".
exports('__TestPackRemove', function(packId)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    if type(packId) ~= 'string' or packId:sub(1, 5) ~= '_test' then return false, 'only _test packs' end
    local source = 'pack:' .. packId
    for id, rec in pairs(Properties.getAll()) do
        if rec.source == source then Properties.delete(id) end
    end
    pcall(MySQL.query.await, 'DELETE FROM `properties` WHERE `source`=?', { source })
    Properties.dropTemplatesBySource(source)
    pcall(MySQL.query.await, 'DELETE FROM `property_packs` WHERE `packId`=?', { packId })
    _packs[packId] = nil
    return true
end)
