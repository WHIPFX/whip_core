-- ============================================
-- Settings — config.lua's values as changed in /whip → Settings
-- ============================================
--
-- config.lua is the DEFAULTS. An admin changes a setting in the panel; the server saves it (the
-- database is the record: server/settings.lua) and mirrors every saved value into settings.json in
-- this folder. THIS FILE reads settings.json straight after config.lua and the schema, on the
-- server and on every player's game, before any other whip file runs, so a file that reads a
-- setting while it loads sees the changed value on both sides.
--
-- While the server runs, a change arrives by event and goes through Settings.apply, which sets
-- the value IN PLACE (other files hold references to Config's sub-tables) and runs the hooks the
-- owning files registered with Settings.onChange.
--
-- A satellite's settings live here too, under its resource name, in Settings.values; a
-- core setting lives in Config itself.
--
-- THE FILE IS NOT EDITED BY HAND. The server rebuilds it from the database at every start when
-- the two differ (server/settings.lua, Settings.loadAll), so a hand edit is undone.

Settings = {}

local CORE = GetCurrentResourceName()
Settings.CORE = CORE
-- Two files: settings.json goes to every player (files{} in the manifest), server_settings.json
-- holds the settings marked sides = 'server' and is read on the server only (the manifest's glob,
-- 'settings*.json', does not match it). A setting for the server only never reaches a player.
Settings.FILE = 'settings.json'
Settings.SERVER_FILE = 'server_settings.json'

-- AN ITEM'S PAGE: every item has settings of its own under the owner 'item:<key>'
-- (server/item_settings.lua). It is not a resource's page: it never goes with a resource, and it is
-- edited on the Items page, not in Settings.
Settings.ITEM_PREFIX = 'item:'

---@param owner any
---@return boolean
function Settings.isItemPage(owner)
    return type(owner) == 'string' and owner:sub(1, #Settings.ITEM_PREFIX) == Settings.ITEM_PREFIX
end

-- ---- Values that survive JSON: nil, vectors, tables with number keys ----
--
-- JSON has no nil inside a table, no vector, and no number key. A setting can be any of them:
-- "none" (MenuPedTimecycle), a spawn point, door offsets keyed by model hash. So a value goes
-- through encode before json.encode and decode after json.decode. The same form crosses net
-- events, so a nil in a list of changes is not lost on the way.

local function isVector(v)
    local t = type(v)
    return t == 'vector2' or t == 'vector3' or t == 'vector4'
end

--- A value as plain data that JSON keeps exactly.
---@param v any
---@return any
local function encode(v)
    if v == nil then return { ['$nil'] = true } end
    local t = type(v)
    if t == 'vector2' then return { ['$v'] = { v.x, v.y } } end
    if t == 'vector3' then return { ['$v'] = { v.x, v.y, v.z } } end
    if t == 'vector4' then return { ['$v'] = { v.x, v.y, v.z, v.w } } end
    if t ~= 'table' then return v end
    local n, count, stringKeys = #v, 0, true
    for k in pairs(v) do
        count = count + 1
        if type(k) ~= 'string' then stringKeys = false end
    end
    local out = {}
    if count == n then
        for i = 1, n do out[i] = encode(v[i]) end
        return out
    end
    if stringKeys then
        for k, x in pairs(v) do out[k] = encode(x) end
        return out
    end
    local list = {}
    for k, x in pairs(v) do list[#list + 1] = { encode(k), encode(x) } end
    return { ['$map'] = list }
end

--- The value encode made, back.
---@param v any
---@return any
local function decode(v)
    if type(v) ~= 'table' then return v end
    if v['$nil'] == true then return nil end
    local vec = v['$v']
    if type(vec) == 'table' then
        local a, b, c, d = tonumber(vec[1]), tonumber(vec[2]), tonumber(vec[3]), tonumber(vec[4])
        if a and b and c and d then return vector4(a + 0.0, b + 0.0, c + 0.0, d + 0.0) end
        if a and b and c then return vector3(a + 0.0, b + 0.0, c + 0.0) end
        if a and b then return vector2(a + 0.0, b + 0.0) end
        return nil
    end
    local map = v['$map']
    if type(map) == 'table' then
        local out = {}
        for _, kv in ipairs(map) do
            local k = type(kv) == 'table' and decode(kv[1]) or nil
            if k ~= nil then out[k] = decode(kv[2]) end
        end
        return out
    end
    local out = {}
    for k, x in pairs(v) do out[k] = decode(x) end
    return out
end

Settings.encode = encode
Settings.decode = decode

---@param v any
---@return any
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
Settings.copy = copy

--- Are two values the same setting? Tables by content, numbers by value (2 is 2.0).
---@param a any
---@param b any
---@return boolean
local function same(a, b)
    if a == b then return true end
    if isVector(a) or isVector(b) then
        if type(a) ~= type(b) then return false end
        -- The panel shows an axis to 3 places, so a position typed back as it reads is the same.
        return #(a - b) < 0.001
    end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, x in pairs(a) do
        if not same(x, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
Settings.same = same

-- ---- Where a value lives ----
--
-- A core path is a place in Config: 'DefaultCash', or 'Emotes.cancelKey' for a field of a table. A
-- satellite's path is just a name in its own flat list.

Settings.values = {}     -- [owner][path] = { v = value }, satellites only (wrapped: "none" is a value)
local defaults = {}      -- [owner][path] = { v = value }: config.lua's value, kept before its first change
local touched = {}       -- [owner][path] = true: changed from config.lua at some point since start

--- One step of a path into `t`. A step of digits is a place in a list ('CharSelect.slots.1.pos' is
--- slots[1]) when `t` has that place and no key spelled so: 'Items.420' stays the item keyed '420'.
local function step(t, p)
    if p:match('^[1-9]%d*$') and t[p] == nil then
        local n = math.tointeger(tonumber(p))
        if n and t[n] ~= nil then return n end
    end
    return p
end

---@param path string
---@return table|nil parent, string|integer key
local function parentOf(path)
    local t = Config
    local parts = {}
    for p in path:gmatch('[^%.]+') do parts[#parts + 1] = p end
    for i = 1, #parts - 1 do
        t = t[step(t, parts[i])]
        if type(t) ~= 'table' then return nil, parts[#parts] end
    end
    return t, step(t, parts[#parts])
end

--- The value in force: Config for whip_core, the satellite's list for a satellite.
---@param owner string
---@param path string
---@return any
function Settings.read(owner, path)
    if owner == CORE then
        local parent, key = parentOf(path)
        return parent and parent[key]
    end
    -- A satellite's: what is saved, else what it declared. Kept wrapped, so a saved "none" is not
    -- read as "nothing saved".
    local list = Settings.values[owner]
    local rec = list and list[path]
    if rec then return rec.v end
    local entry = Settings.entry(owner, path)
    return entry and entry.default
end

--- config.lua's value (a satellite's: what it declared). Kept the first time a path changes; until
--- then the value in force is still the default.
---@param owner string
---@param path string
---@return any
function Settings.default(owner, path)
    local rec = defaults[owner] and defaults[owner][path]
    if rec then return rec.v end
    if owner ~= CORE then
        local entry = Settings.entry(owner, path)
        return entry and entry.default
    end
    return Settings.read(owner, path)
end

--- Has this path been changed from its default since start (including back again)? What the
--- server tells a joining player about.
---@param owner string
---@return table  { [path] = true }
function Settings.touched(owner)
    return touched[owner] or {}
end

--- Set it, keeping a table's identity: a file that took a reference to Config.Bubbles at load
--- still reads the new numbers. A value that is not a table (or replaces one that is not) is
--- simply assigned.
---@param parent table
---@param key string|integer
---@param value any
local function putInPlace(parent, key, value)
    local old = parent[key]
    if type(old) == 'table' and type(value) == 'table' then
        for k in pairs(old) do old[k] = nil end
        for k, x in pairs(value) do old[k] = copy(x) end
    else
        parent[key] = copy(value)
    end
end

-- ---- Hooks: what the owning files re-run when a setting changes ----

local hooks = {}   -- [owner][path] = { fn, ... }

--- Run fn(value, old, path) after `path` changes on this side, or anything under it ('Bubbles'
--- hears 'Bubbles.range'). Registered at file scope by the file that reads the setting, beside the
--- code it refreshes. A hook may not wait.
---@param path string
---@param fn function
---@param owner string|nil  whip_core when left out
function Settings.onChange(path, fn, owner)
    owner = owner or CORE
    hooks[owner] = hooks[owner] or {}
    local list = hooks[owner][path] or {}
    list[#list + 1] = fn
    hooks[owner][path] = list
end

---@param owner string
---@param path string
---@param value any
---@param old any
local function runHooks(owner, path, value, old)
    local byPath = hooks[owner]
    if not byPath then return end
    local prefix = path
    while prefix do
        for _, fn in ipairs(byPath[prefix] or {}) do
            local ok, err = pcall(fn, value, old, path)
            if not ok then
                print(('^1[whip_core:settings] the hook for %s errored: %s^0'):format(prefix, tostring(err)))
            end
        end
        prefix = prefix:match('^(.*)%.[^%.]+$')
    end
end

--- Put a value in force on this side and run its hooks. The value has been checked already
--- (Settings.check). Answers whether anything changed.
---@param owner string
---@param path string
---@param value any
---@return boolean
function Settings.apply(owner, path, value)
    local inForce = Settings.read(owner, path)
    -- A satellite's value that arrives before its page is declared is kept even when it reads the
    -- same: a saved "none" reads as nil now, but the declared default would be read in its place.
    local list = Settings.values[owner]
    local undeclared = owner ~= CORE and not (list and list[path]) and not Settings.entry(owner, path)
    if same(inForce, value) and not undeclared then return false end
    -- A COPY: a table setting changes in place, so the one in force would already hold the new
    -- contents by the time a hook read it as `old`.
    local old = copy(inForce)
    defaults[owner] = defaults[owner] or {}
    if defaults[owner][path] == nil and owner == CORE then
        defaults[owner][path] = { v = copy(old) }
    end
    if owner == CORE then
        local parent, key = parentOf(path)
        if not parent then
            print(('^1[whip_core:settings] %s has no place in Config^0'):format(path))
            return false
        end
        putInPlace(parent, key, value)
    else
        Settings.values[owner] = Settings.values[owner] or {}
        Settings.values[owner][path] = { v = copy(value) }
    end
    touched[owner] = touched[owner] or {}
    touched[owner][path] = true
    runHooks(owner, path, value, old)
    return true
end

--- Count a value as changed since start, so a joining player is sent it (Settings.touched).
---@param owner string
---@param path string
function Settings.touch(owner, path)
    touched[owner] = touched[owner] or {}
    touched[owner][path] = true
end

--- A satellite's value forgotten on this side: it reads its declared default again. Counted as
--- changed, so a player whose settings.json still holds it is told (Settings.touched).
---@param owner string
---@param path string
function Settings.forget(owner, path)
    local list = Settings.values[owner]
    if list then list[path] = nil end
    touched[owner] = touched[owner] or {}
    touched[owner][path] = true
end

-- ---- The schema: what each setting is, and what it may be set to ----

local pages = {}   -- [owner] = { owner, label, groups = { { id, label, settings = { entry } } } }
local index = {}   -- [owner][path] = entry

--- Declare a page of settings. whip_core's is ConfigSchema (shared/config_schema.lua); a
--- satellite's comes through __RegisterSettings (Whip.configPage). Answers the page.
---@param owner string
---@param label string
---@param groups table
function Settings.definePage(owner, label, groups)
    -- A 'record' (an item, a stat) is declared as one row of fields but KEPT FIELD BY FIELD: each
    -- field is a setting of its own ('Items.food.weight'), so only what an admin changed is saved,
    -- the fields the panel does not show (and those whip works out, like fuel's burn) are never
    -- frozen in a saved copy, and each field has its own default and Reset. `form` tells the panel
    -- to draw them together as one card.
    for _, g in ipairs(groups) do
        local out = {}
        for _, e in ipairs(g.settings or {}) do
            if e.type == 'record' and e.fields then
                for i, f in ipairs(e.fields) do
                    local fe = copy(f)
                    fe.path = e.path .. '.' .. f.key
                    fe.key = nil
                    fe.form, fe.formLabel, fe.formHelp, fe.formFirst = e.path, e.label, e.help, i == 1
                    fe.cross = f.cross or e.cross
                    fe.sides = f.sides or e.sides
                    fe.apply = f.apply or e.apply
                    fe.why = f.why or e.why
                    fe.shownWhen = f.shownWhen or e.shownWhen
                    out[#out + 1] = fe
                end
            else
                out[#out + 1] = e
            end
        end
        g.settings = out
    end
    local byPath = {}
    for _, g in ipairs(groups) do
        for _, e in ipairs(g.settings or {}) do byPath[e.path] = e end
    end
    pages[owner] = { owner = owner, label = label, groups = groups }
    index[owner] = byPath
    return pages[owner]
end

---@param owner string
---@param path string
---@return table|nil
function Settings.entry(owner, path)
    return index[owner] and index[owner][path]
end

---@param owner string
---@return table|nil
function Settings.page(owner)
    return pages[owner]
end

---@return table  { [owner] = page }
function Settings.pages()
    return pages
end

-- ---- Records: rows of fields, in a list ('records') or by name ('map') ----
--
-- A field's `key` may reach inside the record: 'permissions.canHire'. Fields the panel does not
-- show are kept as they are, so nothing config.lua put in a record is lost by editing it.

---@param rec table
---@param key string
local function getField(rec, key)
    local t = rec
    for part in key:gmatch('[^%.]+') do
        if type(t) ~= 'table' then return nil end
        t = t[part]
    end
    return t
end
Settings.getField = getField

---@param rec table
---@param key string
---@param value any
local function setField(rec, key, value)
    local parts = {}
    for part in key:gmatch('[^%.]+') do parts[#parts + 1] = part end
    local t = rec
    for i = 1, #parts - 1 do
        if type(t[parts[i]]) ~= 'table' then t[parts[i]] = {} end
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
end
Settings.setField = setField

---@return boolean, any  true and the record as kept, or false and why
local function checkRecord(fields, rec, where)
    if type(rec) ~= 'table' or isVector(rec) then return false, (where or 'it') .. ' must be a row of fields' end
    local out = copy(rec)
    for _, f in ipairs(fields) do
        local ok, v = Settings.check(f, getField(rec, f.key))
        if not ok then
            if where then return false, ('%s: %s %s'):format(where, f.label or f.key, v) end
            return false, ('%s %s'):format(f.label or f.key, v)
        end
        setField(out, f.key, v)
    end
    return true, out
end

-- ---- 'heroShots': the character screen's shots ----
--
-- One list, a shot per character place, made in the world (Edit in world on the Character screen page) and
-- kept whole. A place may be `false`: not set, its character stands in another shot (client/charselect.lua),
-- so shot 1 must be set. Each shot is checked all the way down and kept as a clean copy of only what it names:
-- one with no `anim` gets none.
local HERO_NAME = '^[%w_]+$'

--- One shot, checked. Raises its reason (the caller pcalls): a shot is a dozen leaves deep.
local function heroShot(entry, s, where)
    local lim = entry.limits or {}
    local function leaf(spec, value, what)
        local ok, v = Settings.check(spec, value)
        if not ok then error(('%s: %s %s'):format(where, what, v), 0) end
        return v
    end
    if type(s) ~= 'table' or isVector(s) then error(where .. ' must be a shot', 0) end
    if type(s.camera) ~= 'table' then error(where .. ' needs a camera', 0) end
    local out = {
        camera = {
            pos = leaf({ type = 'vec3', limits = lim.world }, s.camera.pos, 'its camera place'),
            rot = leaf({ type = 'vec3', limits = lim.turn, axisLabels = { 'Pitch', 'Roll', 'Yaw' } }, s.camera.rot, 'its camera turn'),
            fov = leaf({ type = 'number', min = 10, max = 120 }, s.camera.fov, 'its camera zoom'),
        },
        pos = leaf({ type = 'vec4', limits = lim.world }, s.pos, 'where its character stands'),
        emote = leaf({ type = 'string', maxLen = 32, nullable = true, pattern = HERO_NAME,
            patternWhy = 'must be an emote name (the word after /e)' }, s.emote, 'its emote'),
        scenario = leaf({ type = 'string', maxLen = 64, nullable = true, pattern = HERO_NAME,
            patternWhy = 'must be a scenario name' }, s.scenario, 'its scenario'),
    }
    if s.anim ~= nil then
        if type(s.anim) ~= 'table' then error(where .. ': its animation must be a dictionary and a clip', 0) end
        local A = { type = 'string', maxLen = 100, pattern = '^[%w_@%-/%.]+$', patternWhy = 'must be an animation name' }
        out.anim = { dict = leaf(A, s.anim.dict, 'its animation dictionary'), clip = leaf(A, s.anim.clip, 'its animation clip') }
    end
    if s.look ~= nil then
        if type(s.look) ~= 'table' then error(where .. ': its sky must be a weather and a time', 0) end
        out.look = {
            weather = leaf({ type = 'string', maxLen = 20, nullable = true, pattern = '^[%u%d_]+$',
                patternWhy = 'must be a GTA weather name in capitals' }, s.look.weather, 'its weather'),
            hour = leaf({ type = 'int', min = 0, max = 23 }, s.look.hour or 12, 'its hour'),
            minute = leaf({ type = 'int', min = 0, max = 59 }, s.look.minute or 0, 'its minute'),
            frozen = s.look.frozen ~= false,
            priority = leaf({ type = 'number', min = 0, max = 100000 }, s.look.priority or 1000, 'its sky\'s priority'),
        }
    end
    if s.props ~= nil then
        if type(s.props) ~= 'table' or isVector(s.props) then error(where .. ': its props must be a list', 0) end
        local most = entry.maxProps or 60
        if #s.props > most then error(('%s: at most %d props'):format(where, most), 0) end
        local W = lim.world or {}
        out.props = {}
        for i, p in ipairs(s.props) do
            if type(p) ~= 'table' then error(('%s: prop %d must be a row'):format(where, i), 0) end
            local what = ('prop %d\'s'):format(i)
            local function at(k, l) return leaf({ type = 'number', min = l and l[1] or -100000, max = l and l[2] or 100000 }, p[k], what .. ' ' .. k) end
            local function turn(k) return leaf({ type = 'number', min = -720, max = 720 }, p[k] or 0.0, what .. ' ' .. k) end
            out.props[i] = {
                model = leaf({ type = 'string', maxLen = 64, pattern = HERO_NAME, patternWhy = 'must be a model name' }, p.model, what .. ' model'),
                x = at('x', W.x), y = at('y', W.y), z = at('z', W.z),
                rx = turn('rx'), ry = turn('ry'), rz = turn('rz'),
            }
        end
    end
    return out
end

---@return boolean, any
local function checkHeroShots(entry, value)
    if type(value) ~= 'table' or isVector(value) then return false, 'must be a list of shots' end
    local n = #value
    for k in pairs(value) do
        if math.type(k) ~= 'integer' or k < 1 or k > n then return false, 'must be a list of shots' end
    end
    if n < 1 then return false, 'needs at least one shot' end
    if entry.maxItems and n > entry.maxItems then return false, ('may have at most %d shots'):format(entry.maxItems) end
    if value[1] == false then return false, 'needs shot 1: a place with no shot of its own falls back to one' end
    local out = {}
    for i = 1, n do
        if value[i] == false then
            out[i] = false
        else
            local ok, shot = pcall(heroShot, entry, value[i], ('shot %d'):format(i))
            if not ok then return false, tostring(shot) end
            out[i] = shot
        end
    end
    return true, out
end

--- A map's key as Config keeps it. 'hash' keys (models: door offsets, hinges) take a model name or
--- its number, and are kept as the number GetHashKey gives. 'number' keys keep digits as a whole
--- number (a GTA mod slot, a wheel type) and anything else as a name. Other keys are names.
---@return any|nil key, string|nil why
local function mapKey(entry, k)
    if entry.keyKind == 'number' then
        if type(k) == 'string' and k:match('^%-?%d+$') then k = math.tointeger(tonumber(k)) end
        if math.type(k) == 'float' then k = math.tointeger(k) end
        if math.type(k) == 'integer' then return k end
    end
    if entry.keyKind == 'hash' then
        if type(k) == 'string' and k:match('^%-?%d+$') then k = math.tointeger(tonumber(k)) end
        if type(k) == 'string' then
            if not k:match('^[%w_]+$') then return nil, ('"%s" is not a model name'):format(k) end
            k = GetHashKey(k)
        end
        if math.type(k) ~= 'integer' then return nil, 'each row needs a model name or its number' end
        -- Signed, as GetEntityModel answers: many tools print the same number unsigned.
        if k >= 2147483648 and k < 4294967296 then k = k - 4294967296 end
        if k < -2147483648 or k > 2147483647 then return nil, ('%s is not a model number'):format(tostring(k)) end
        return k
    end
    if type(k) ~= 'string' or k == '' then return nil, 'each row needs a name' end
    if entry.keyPattern and not k:match(entry.keyPattern) then
        return nil, ('"%s" %s'):format(k, entry.keyWhy or 'is not a name it can have')
    end
    return k
end

--- Is `value` allowed for this setting? Answers true and the value as it is kept (a whole number
--- for an int, a float for a number, text cleaned), or false and why, in words.
---@param entry table
---@param value any
---@return boolean, any
function Settings.check(entry, value)
    local t = entry.type
    -- Shown in the panel for what it is, never changed there (PlayerContainers).
    if entry.apply == 'readonly' then return false, 'cannot be changed here' end
    if value == nil then
        if entry.nullable then return true, nil end
        return false, 'needs a value'
    end
    -- "Off" for a number that may be switched off (Sentinel's autoKick = false): an empty box.
    if value == false and entry.offWhenEmpty then return true, false end
    if t == 'bool' then
        if type(value) ~= 'boolean' then return false, 'must be on or off' end
        return true, value
    end
    if t == 'int' or t == 'number' then
        local n = tonumber(value)
        if not n or n ~= n or n == math.huge or n == -math.huge then return false, 'must be a number' end
        if t == 'int' then
            if n % 1 ~= 0 then return false, 'must be a whole number' end
            n = math.tointeger(n)
            if not n then return false, 'is too large' end
        else
            n = n + 0.0
        end
        if entry.min and n < entry.min then return false, ('must be at least %s'):format(entry.min) end
        if entry.max and n > entry.max then return false, ('must be at most %s'):format(entry.max) end
        return true, n
    end
    if t == 'string' then
        if type(value) ~= 'string' then return false, 'must be text' end
        value = value:gsub('%c', ''):match('^%s*(.-)%s*$')
        -- Counted in characters, as the panel counts them: "José" is 4, not 5 bytes.
        local len = utf8.len(value)
        if not len then return false, 'is not valid text' end
        -- Empty is "none" where none is allowed: '' is true in Lua, so `if Config.X then` would
        -- act on an empty name.
        if len == 0 and entry.nullable then return true, nil end
        if len < (entry.minLen or 1) then return false, 'cannot be empty' end
        if entry.maxLen and len > entry.maxLen then
            return false, ('is longer than %d characters'):format(entry.maxLen)
        end
        -- A Lua pattern the whole text must match (a model or resource name), with its own words.
        if entry.pattern and not value:match(entry.pattern) then
            return false, entry.patternWhy or 'has characters it cannot have'
        end
        -- Names it may not be, each with its reason ({ whip_core = 'cannot restart itself' }).
        if entry.forbidden and entry.forbidden[value] then
            return false, ('cannot be "%s": %s'):format(value, entry.forbidden[value])
        end
        return true, value
    end
    if t == 'enum' then
        for _, o in ipairs(entry.options or {}) do
            if o.value == value then return true, value end
        end
        return false, 'is not one of the choices'
    end
    if t == 'vec3' or t == 'vec4' then
        -- `limits` = { x = { min, max }, ... } for the axes that have one (a world position's).
        local want = 'vector3'
        if t == 'vec4' then want = 'vector4' end
        if type(value) ~= want then return false, 'must be a position' end
        local axes = { 'x', 'y', 'z', 'w' }
        local names = { 'x', 'y', 'z', 'heading' }
        for i = 1, (t == 'vec4' and 4 or 3) do
            local a = axes[i]
            local n = value[a]
            if n ~= n or n == math.huge or n == -math.huge then return false, 'must be a position' end
            local lim = entry.limits and entry.limits[a]
            if lim and (n < lim[1] or n > lim[2]) then
                local name = entry.axisLabels and entry.axisLabels[i] or names[i]
                return false, ('%s must be between %s and %s'):format(name:lower(), lim[1], lim[2])
            end
        end
        return true, value
    end
    if t == 'list' then
        -- A plain list, each entry checked as `entry.item` (an entry of its own: type, min, ...).
        if type(value) ~= 'table' then return false, 'must be a list' end
        local n = #value
        for k in pairs(value) do
            if math.type(k) ~= 'integer' or k < 1 or k > n then return false, 'must be a list' end
        end
        if n < (entry.minItems or 0) then
            return false, ('needs at least %d entr%s'):format(entry.minItems, entry.minItems == 1 and 'y' or 'ies')
        end
        if entry.maxItems and n > entry.maxItems then
            return false, ('may have at most %d entr%s'):format(entry.maxItems, entry.maxItems == 1 and 'y' or 'ies')
        end
        local out = {}
        for i = 1, n do
            local ok, v = Settings.check(entry.item, value[i])
            if not ok then return false, ('entry %d %s'):format(i, v) end
            out[i] = v
        end
        return true, out
    end
    if t == 'heroShots' then return checkHeroShots(entry, value) end
    if t == 'records' then
        if type(value) ~= 'table' or isVector(value) then return false, 'must be a list of rows' end
        local n = #value
        for k in pairs(value) do
            if math.type(k) ~= 'integer' or k < 1 or k > n then return false, 'must be a list of rows' end
        end
        if n < (entry.minItems or 0) then return false, ('needs at least %d rows'):format(entry.minItems) end
        if entry.maxItems and n > entry.maxItems then return false, ('may have at most %d rows'):format(entry.maxItems) end
        local out, seen = {}, {}
        for i = 1, n do
            local ok, rec = checkRecord(entry.fields, value[i], ('row %d'):format(i))
            if not ok then return false, rec end
            -- `unique`: a field no two rows may share (a slot number, a key).
            if entry.unique then
                local u = getField(rec, entry.unique)
                if u ~= nil then
                    if seen[u] then return false, ('rows %d and %d have the same %s'):format(seen[u], i, tostring(u)) end
                    seen[u] = i
                end
            end
            out[i] = rec
        end
        return true, out
    end
    if t == 'map' then
        if type(value) ~= 'table' or isVector(value) then return false, 'must be a table of rows' end
        local out, count = {}, 0
        for k, v in pairs(value) do
            count = count + 1
            local key, why = mapKey(entry, k)
            if key == nil then return false, why end
            if out[key] ~= nil then return false, ('"%s" is there twice'):format(tostring(k)) end
            local ok, cv
            if entry.fields then
                ok, cv = checkRecord(entry.fields, v, ('"%s"'):format(tostring(k)))
            else
                -- `each`: what every row's value is, when it is one value rather than a row of fields.
                ok, cv = Settings.check(entry.each, v)
                if not ok then cv = ('"%s" %s'):format(tostring(k), cv) end
            end
            if not ok then return false, cv end
            out[key] = cv
        end
        if entry.maxItems and count > entry.maxItems then return false, ('may have at most %d rows'):format(entry.maxItems) end
        return true, out
    end
    return false, 'cannot be changed here'
end

-- ---- At load: what settings.json says ----

Settings.definePage(CORE, 'Config', ConfigSchema)

-- [owner][path] = { v = value }: what settings.json held when this side loaded. Wrapped, because a
-- saved "none" (nil) must not read as "not in the file".
local fileValues = {}

--- What settings.json held when this side started, for one owner: { [path] = { v = value } }.
---@param owner string
---@return table
function Settings.fileValues(owner)
    return fileValues[owner] or {}
end

--- Every owner settings.json held at start.
---@return table  { [owner] = { [path] = { v = value } } }
function Settings.allFileValues()
    return fileValues
end

--- One settings file into fileValues. A missing file is normal (nothing changed yet).
---@param name string
local function readFile(name)
    local raw = LoadResourceFile(CORE, name)
    if not raw or raw == '' then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.values) ~= 'table' then
        print(('^3[whip_core:settings] %s could not be read; using config.lua as it is^0'):format(name))
        return
    end
    for owner, list in pairs(data.values) do
        if type(owner) == 'string' and type(list) == 'table' then
            fileValues[owner] = fileValues[owner] or {}
            for path, enc in pairs(list) do
                if type(path) == 'string' then fileValues[owner][path] = { v = decode(enc) } end
            end
        end
    end
end

do
    readFile(Settings.FILE)
    if IsDuplicityVersion() then readFile(Settings.SERVER_FILE) end

    -- whip_core's own, now, before any other file reads Config. No hooks are registered yet, so
    -- this only sets values.
    for path, rec in pairs(fileValues[CORE] or {}) do
        local entry = Settings.entry(CORE, path)
        local ok, v = false, nil
        if entry then ok, v = Settings.check(entry, rec.v) end
        if ok then
            Settings.apply(CORE, path, v)
        else
            print(('^3[whip_core:settings] settings.json: %s is %s, kept as in config.lua^0')
                :format(path, entry and ('refused (' .. tostring(v) .. ')') or 'not a setting any more'))
        end
    end

    -- A satellite's, kept until it declares its page and reads them.
    for owner, list in pairs(fileValues) do
        if owner ~= CORE then
            Settings.values[owner] = Settings.values[owner] or {}
            for path, rec in pairs(list) do Settings.values[owner][path] = { v = copy(rec.v) } end
        end
    end
end

-- ============================================
-- A satellite's settings page
-- ============================================
--
-- A resource declares its settings and whip does the rest: the page in /whip → Settings (its own
-- section, beside Config), the checks, saving, sending changes to every player, and calling back.
-- Declared on BOTH sides: the server checks and saves, a player's game needs the defaults and its own
-- callbacks. A satellite does it through Whip.configPage (lib/satellite.lua), which declares the page with
-- __RegisterSettings whenever whip_core is ready, reads values with __GetSetting and hears changes with
-- __OnSettingChanged, writing them into the resource's Config:
--
--     Whip.configPage({
--         label = 'Autos',
--         settings = {
--             { key = 'Tune.price', type = 'int', min = 0, max = 100000, unit = '$',
--               label = 'Tune price', help = 'What a tune costs.' },
--         },
--     })
--
-- An entry is a ConfigSchema entry (shared/config_schema.lua) with `key` in place of `path` and a
-- `default`. Many groups: `groups = { { label = 'Prices', settings = { ... } }, ... }`.
-- A 'record' is one card of fields on the page, each field a setting of its own ('<key>.<field key>'),
-- its default that field of the record's `default` table.

local ENTRY_TYPES = {
    int = true, number = true, bool = true, string = true, enum = true, vec3 = true, vec4 = true,
    list = true, records = true, map = true, record = true,
}
-- The part each kind cannot do without: a list's `item`, a records' `fields`, an enum's `options`.
local ENTRY_PARTS = { list = 'item', records = 'fields', record = 'fields', enum = 'options' }
-- What a list's entries may be: the panel edits a list as one line of text, with commas between.
local LIST_ITEMS = { int = true, number = true, string = true, enum = true }
local NUMBER_FIELDS = { 'min', 'max', 'step', 'maxLen', 'minItems', 'maxItems' }

--- What is wrong with a declared entry, all the way down (a list's item, a row's fields, a map's
--- value), or nil: said when the page is declared, never as an error when an admin saves.
---@param e any
---@param where string  the entry's name, for the answer
---@param depth number
---@return string|nil
local function badEntry(e, where, depth)
    if depth > 6 then return where .. ' is nested too deeply' end
    if type(e) ~= 'table' then return where .. ' is not a table' end
    if not ENTRY_TYPES[e.type] then
        return where .. ': type must be one of int, number, bool, string, enum, vec3, vec4, list, records, map, record'
    end
    local part = ENTRY_PARTS[e.type]
    if part and type(e[part]) ~= 'table' then return ('%s: a %s needs %s'):format(where, e.type, part) end
    for _, f in ipairs(NUMBER_FIELDS) do
        if e[f] ~= nil and type(e[f]) ~= 'number' then return ('%s: %s must be a number'):format(where, f) end
    end
    -- A Lua pattern that does not compile errors on every check; find('') compiles it.
    for _, f in ipairs({ 'pattern', 'keyPattern' }) do
        if e[f] ~= nil and (type(e[f]) ~= 'string' or not pcall(string.find, '', e[f])) then
            return ('%s: %s is not a Lua pattern'):format(where, f)
        end
    end
    if e.type == 'enum' then
        for i, o in ipairs(e.options) do
            if type(o) ~= 'table' or o.value == nil then return ('%s: option %d needs a value'):format(where, i) end
        end
    end
    if e.type == 'list' then
        if type(e.item.type) ~= 'string' or not LIST_ITEMS[e.item.type] then
            return where .. ': a list\'s item is an int, number, string or enum (for positions, use records)'
        end
        return badEntry(e.item, where .. ' item', depth + 1)
    end
    if e.type == 'map' then
        if type(e.each) ~= 'table' and type(e.fields) ~= 'table' then
            return where .. ': a map needs each (one value per row) or fields (a row of them)'
        end
        if type(e.each) == 'table' then
            local why = badEntry(e.each, where .. ' each', depth + 1)
            if why then return why end
        end
    end
    if (e.type == 'records' or e.type == 'map' or e.type == 'record') and type(e.fields) == 'table' then
        for i, f in ipairs(e.fields) do
            if type(f) ~= 'table' or type(f.key) ~= 'string' or not f.key:match('^[%a_][%w_%.]*$') then
                return ('%s: field %d needs a key (a name)'):format(where, i)
            end
            if f.type == 'record' then return ('%s.%s: a record is a card on the page, not a field'):format(where, f.key) end
            local why = badEntry(f, where .. '.' .. f.key, depth + 1)
            if why then return why end
        end
    end
    return nil
end

--- After a page is declared, with (owner, opts): Settings.register's. server/settings.lua fills this in (what was
--- saved for the page goes out to every player); on a player's game there is nothing more to do.
---@diagnostic disable-next-line: duplicate-set-field -- server/settings.lua's replaces it there
function Settings.pageRegistered() end

--- After a satellite's page goes with its resource. server/settings.lua fills this in (an admin
--- looking at the page is told); on a player's game there is nothing more to do.
---@diagnostic disable-next-line: duplicate-set-field -- server/settings.lua's replaces it there
function Settings.pageDropped() end

--- Declare `owner`'s page. Values saved before it existed are checked now: one refused is forgotten
--- (the declared default stands) and said in the console.
---@param owner string
---@param def table { label, settings? | groups? }
---@param opts table|nil  { quiet = true }: an item's page (server/item_settings.lua), which comes two
---                       hundred at a time and holds only values for the server, so the files are
---                       written once for the lot and no player or panel is told of each
---@return boolean ok
---@return string|nil why
function Settings.register(owner, def, opts)
    if type(owner) ~= 'string' or owner == '' or owner == CORE then return false, 'only another resource declares a settings page' end
    -- The record keeps a resource name in 64 characters (whip_settings.owner).
    if #owner > 64 then return false, 'a settings page needs a resource name of 64 characters or fewer' end
    if type(def) ~= 'table' then return false, 'a settings page is { label, settings = { ... } }' end
    -- Not before the server's boot has read what is saved: the page would be checked against
    -- nothing and the settings files written empty. Whip.register only runs once it is ready.
    if IsDuplicityVersion() and CoreReady ~= true then
        return false, 'whip_core is still starting: declare the page inside Whip.register'
    end
    local label = def.label
    if type(label) ~= 'string' or label == '' or #label > 40 then return false, 'label: a name for the page, up to 40 letters' end
    local groups = def.groups
    if groups == nil and type(def.settings) == 'table' then groups = { { label = label, settings = def.settings } } end
    if type(groups) ~= 'table' or #groups == 0 then return false, 'settings: a list of settings (or groups of them)' end

    local seen, built = {}, {}
    for gi, g in ipairs(groups) do
        if type(g) ~= 'table' or type(g.settings) ~= 'table' then return false, ('group %d needs settings'):format(gi) end
        local list = {}
        for i, e in ipairs(g.settings) do
            if type(e) ~= 'table' then return false, ('setting %d of group %d is not a table'):format(i, gi) end
            local key = e.key
            if type(key) ~= 'string' or not key:match('^[%a_][%w_%.]*$') or #key > 64 then
                return false, ('setting %d: key must be a name (letters, digits, _ and .)'):format(i)
            end
            if seen[key] then return false, ('%s is declared twice'):format(key) end
            seen[key] = true
            local bad = badEntry(e, key, 1)
            if bad then return false, bad end
            if e.type == 'record' then
                -- One card, kept field by field as whip_core's own are (definePage): each field is a setting.
                for fi, f in ipairs(e.fields) do
                    local fkey = key .. '.' .. f.key
                    if #fkey > 64 then return false, ('%s: a key is 64 letters or fewer'):format(fkey) end
                    if seen[fkey] then return false, ('%s is declared twice'):format(fkey) end
                    seen[fkey] = true
                    local entry = copy(f)
                    entry.path, entry.key = fkey, nil
                    entry.label = type(f.label) == 'string' and f.label or f.key
                    entry.default = nil
                    if type(e.default) == 'table' then entry.default = getField(e.default, f.key) end
                    entry.form, entry.formHelp, entry.formFirst = key, e.help, fi == 1
                    entry.formLabel = type(e.label) == 'string' and e.label or key
                    entry.cross = f.cross or e.cross
                    entry.sides = f.sides or e.sides
                    entry.apply = f.apply or e.apply
                    entry.why = f.why or e.why
                    entry.shownWhen = f.shownWhen or e.shownWhen
                    list[#list + 1] = entry
                end
            else
                local entry = copy(e)
                entry.path, entry.key = key, nil
                entry.label = type(e.label) == 'string' and e.label or key
                -- A function crossing the export is a callable table; a plain copy would lose the call.
                entry.cross = e.cross
                list[#list + 1] = entry
            end
        end
        built[#built + 1] = { id = type(g.id) == 'string' and g.id or ('g' .. gi), label = type(g.label) == 'string' and g.label or label, settings = list }
    end

    -- Every default must pass its own check. One that doesn't is left off the page with the reason
    -- printed; the rest of the page stands, and the resource keeps reading its config.lua value. A
    -- passing default is kept as the check returns it (a model name key as its hash, 5 as 5.0).
    local pageGroups = {}
    for _, g in ipairs(built) do
        local kept = {}
        for _, e in ipairs(g.settings) do
            local good = true
            if e.apply ~= 'readonly' then
                local called, ok, value = pcall(Settings.check, e, e.default)
                if called and ok then
                    e.default = value
                else
                    good = false
                    print(('^3[whip_core] settings: %s (%s) is left off its page: its default %s^0')
                        :format(e.path, owner, tostring(called and value or ok)))
                end
            end
            if good then kept[#kept + 1] = e end
        end
        if #kept > 0 then
            g.settings = kept
            pageGroups[#pageGroups + 1] = g
        end
    end
    if #pageGroups == 0 then return false, 'none of its settings has a default that passes its own check' end
    built = pageGroups

    Settings.definePage(owner, label, built)

    -- What was saved for it before it declared its page (the file at load; on the server, the
    -- database at start): kept only if it passes.
    local list = Settings.values[owner]
    if list then
        for path, rec in pairs(list) do
            local entry = Settings.entry(owner, path)
            local ok, v = false, nil
            if entry and entry.apply ~= 'readonly' then ok, v = Settings.check(entry, rec.v) end
            if ok then
                list[path] = { v = v }
            else
                list[path] = nil
                print(('^3[whip_core:settings] %s\'s saved %s is %s: its default stands^0')
                    :format(owner, path, entry and ('refused (' .. tostring(v) .. ')') or 'not one of its settings'))
            end
        end
    end

    Settings.pageRegistered(owner, opts)
    return true
end

--- Every value of a satellite's page: { [key] = value }, defaults included.
---@param owner string
---@return table
function Settings.valuesOf(owner)
    local out = {}
    local page = pages[owner]
    for _, g in ipairs(page and page.groups or {}) do
        for _, e in ipairs(g.settings) do out[e.path] = copy(Settings.read(owner, e.path)) end
    end
    return out
end

-- A satellite that stops takes its page and callbacks with it; what was saved for it stays, for
-- when it starts again.
AddEventHandler('onResourceStop', function(res)
    if res == CORE or not pages[res] then return end
    pages[res], index[res], hooks[res] = nil, nil, nil
    Settings.pageDropped()
end)

-- Each settings page in GetRegistrations with the registries. In a thread: this file loads before
-- shared/registry.lua.
CreateThread(function()
    Registry.addLister('settingsPage', function()
        local out = {}
        for owner, p in pairs(pages) do out[#out + 1] = { key = tostring(p.label or owner), owner = owner } end
        return out
    end)
end)

exports('__RegisterSettings', function(def)
    local owner = Registry.caller()   -- first, before anything can yield
    return Settings.register(owner, def)
end)

--- A setting of the calling resource's page: what is saved, else its default.
exports('__GetSetting', function(key)
    return copy(Settings.read(Registry.caller(), key))
end)

--- All of the calling resource's settings: { [key] = value }.
exports('__GetSettings', function()
    return Settings.valuesOf(Registry.caller())
end)

--- fn(value, old, key) after one of the calling resource's settings changes, on this side. ONE per
--- key: calling again replaces it, so a Whip.register that runs again does not stack them.
exports('__OnSettingChanged', function(key, fn)
    local owner = Registry.caller()
    if type(key) ~= 'string' or fn == nil then return false, '__OnSettingChanged(key, function(value, old, key) end)' end
    hooks[owner] = hooks[owner] or {}
    hooks[owner][key] = { fn }
    return true
end)
