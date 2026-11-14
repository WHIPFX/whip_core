-- ============================================
-- Property themes — a home's look, from the resource that built its interior
-- ============================================
--
-- An interior resource can say it has looks (walls, trim, floor), whip finds it,
-- and the people who can furnish a home pick its look at the same sign. whip keeps the choice; the
-- interior resource draws it (an MLO entity set each, switched on its own client).
--
-- A RESOURCE DECLARES IT in its fxmanifest, one line, as a pack does (server/property_packs.lua):
--
--     whip_interior_themes 'v1'
--
-- and has these server exports (docs.html, "Interior themes", has the whole contract):
--
--     GetThemes()          { { id = 0, name = 'Original', walls = '#rrggbb', trim = '#rrggbb', floor = '#rrggbb' }, ... }
--     GetHomes()           { { key = 'mp_d01_p05', archetype = '<mlo name>', designArchetype? = '<mlo name>',
--                              position = vector3(<the MLO instance origin>) }, ... }
--     SetAllThemes(t)      { [homeKey] = themeId, ... }, the whole table (a home left out is 0)
--     SetHomeTheme(k, id)  true | false, why
--
-- WHICH PROPERTY IS WHICH HOME: a property's placement is its interior's archetype and origin
-- ({ hash, x, y, z }, read off the interior when it was set up), and a home is the same thing. The
-- same archetype (or the home's `designArchetype`: an older interior of the same design, which a
-- property saved before the home changed still names), within MATCH_M. Nothing to set up, and a
-- property found this way is offered its looks in the wizard and on its admin page.
--
-- WHAT WHIP KEEPS: the property's `theme` column (migration 033), nil for its first look. A sale keeps
-- it. Who changes it: whoever may furnish the home, its owner or an admin.
--
-- WHEN IT IS SENT: the whole table to a theme resource when whip starts and whenever that resource
-- starts, and each change as it is made. Its clients redraw the home; whip's client makes the
-- furniture again after a redraw (client/property_objects.lua, whip_core:interiorRefreshed).

PropertyThemes = {}

local METADATA_KEY = 'whip_interior_themes'
local MATCH_M = 2.0          -- as client/property_objects.lua's PLACE_MATCH_M: same-design flats sit 4-6 m apart
local MAX_THEMES, MAX_HOMES = 64, 4000

local _providers = {}        -- [resource] = { resource, label, themes = {..}, byId = {..}, byHash = { [hash] = { home, .. } } }
local _gen = 0               -- moves whenever a theme resource comes or goes
local _match = {}            -- [propertyId] = { gen, place, provider, home } (provider nil: none)
local _ready = false

local function log(fmt, ...) print(('[whip_core:property_themes] ' .. fmt):format(...)) end

-- ============================================
-- Reading a theme resource
-- ============================================

local function hex(v)
    return type(v) == 'string' and v:match('^#%x%x%x%x%x%x$') and v:lower() or nil
end

local function vecOf(v)
    if v == nil then return nil end
    local x, y, z
    local ok = pcall(function() x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z) end)
    if not ok or not x then
        if type(v) == 'table' then x, y, z = tonumber(v[1]), tonumber(v[2]), tonumber(v[3]) end
    end
    if not (x and y and z) or x ~= x or y ~= y or z ~= z then return nil end
    return x, y, z
end

--- The name an admin sees for a theme resource: its description up to the first colon, or its name.
local function labelOf(resource)
    local d = GetResourceMetadata(resource, 'description', 0)
    if type(d) == 'string' and d ~= '' then
        local head = d:match('^([^:]+)') or d
        head = head:gsub('^%s+', ''):gsub('%s+$', '')
        if head ~= '' then return head:sub(1, 48) end
    end
    return resource
end

local function call(resource, name, ...)
    local args = table.pack(...)
    return pcall(function() return exports[resource][name](exports[resource], table.unpack(args, 1, args.n)) end)
end

--- Read and check what a theme resource offers. Answers the provider, or nil and why.
local function readProvider(resource)
    local ok, themes = call(resource, 'GetThemes')
    if not ok then return nil, 'GetThemes failed: ' .. tostring(themes) end
    if type(themes) ~= 'table' then return nil, 'GetThemes did not answer a list' end
    local p = { resource = resource, label = labelOf(resource), themes = {}, byId = {}, byHash = {}, homes = 0 }
    for i, t in ipairs(themes) do
        if i > MAX_THEMES then break end
        local id = type(t) == 'table' and math.tointeger(tonumber(t.id)) or nil
        if id and id >= 0 and id <= 255 and not p.byId[id] then
            local name = type(t.name) == 'string' and t.name:gsub('^%s+', ''):gsub('%s+$', '') or ''
            local theme = {
                id = id, name = name ~= '' and name:sub(1, 40) or ('Theme ' .. id),
                walls = hex(t.walls), trim = hex(t.trim), floor = hex(t.floor),
            }
            p.themes[#p.themes + 1] = theme
            p.byId[id] = theme
        end
    end
    table.sort(p.themes, function(a, b) return a.id < b.id end)
    if #p.themes == 0 then return nil, 'GetThemes answered no themes' end

    local hok, homes = call(resource, 'GetHomes')
    if not hok then return nil, 'GetHomes failed: ' .. tostring(homes) end
    if type(homes) ~= 'table' then return nil, 'GetHomes did not answer a list' end
    for i, h in ipairs(homes) do
        if i > MAX_HOMES then break end
        local key = type(h) == 'table' and type(h.key) == 'string' and h.key or nil
        local x, y, z
        if key then x, y, z = vecOf(h.position) end
        if key and #key <= 64 and key:match('^[%w_%-%.:]+$') and x then
            local home = { key = key, x = x, y = y, z = z }
            local seen = {}
            for _, a in ipairs({ h.archetype, h.designArchetype }) do
                local hash = (type(a) == 'string' or type(a) == 'number') and PropertyMath.signedHash(a) or nil
                if hash and hash ~= 0 and not seen[hash] then
                    seen[hash] = true
                    local list = p.byHash[hash]
                    if not list then list = {}; p.byHash[hash] = list end
                    list[#list + 1] = home
                end
            end
            if next(seen) then p.homes = p.homes + 1 end
        end
    end
    -- None is not wrong (a resource whose homes are all switched off): it is taken, and matches nothing.
    return p
end

-- ============================================
-- Which home a property is
-- ============================================

--- The theme resource and home a property is, or nil.
---@return table|nil provider, table|nil home
function PropertyThemes.homeOf(rec)
    if not rec or not rec.place then return nil end
    local m = _match[rec.propertyId]
    if m and m.gen == _gen and m.place == rec.place then return m.provider, m.home end
    local pl, best, bestP, bestD = rec.place, nil, nil, MATCH_M * MATCH_M
    if pl.hash and pl.hash ~= 0 then
        for _, p in pairs(_providers) do
            for _, h in ipairs(p.byHash[pl.hash] or {}) do
                local dx, dy, dz = h.x - pl.x, h.y - pl.y, h.z - pl.z
                local d = dx * dx + dy * dy + dz * dz
                if d <= bestD then best, bestP, bestD = h, p, d end
            end
        end
    end
    _match[rec.propertyId] = { gen = _gen, place = rec.place, provider = bestP, home = best }
    return bestP, best
end

--- Is this property offered looks? (The client shows its sign's Theme on this.)
function PropertyThemes.offered(rec)
    return (PropertyThemes.homeOf(rec)) ~= nil
end

local function themeList(p)
    local out = {}
    for i, t in ipairs(p.themes) do
        out[i] = { id = t.id, name = t.name, walls = t.walls, trim = t.trim, floor = t.floor }
    end
    return out
end

--- What the theme pickers show: { resource, label, home, current, themes } or nil.
function PropertyThemes.infoOf(rec)
    local p, home = PropertyThemes.homeOf(rec)
    if not p then return nil end
    ---@cast home -nil
    local current = math.tointeger(tonumber(rec.theme)) or 0
    if not p.byId[current] then current = p.themes[1].id end
    return { resource = p.resource, label = p.label, home = home.key, current = current, themes = themeList(p) }
end

--- The same for a placement nobody has made a property on yet (the wizard).
function PropertyThemes.at(place)
    return PropertyThemes.infoOf({ propertyId = -1, place = place })
end

--- A theme resource came or went: a property whose answer changes is sent to every client again. Only
--- one whose wire is built: the rest have told nobody anything yet, and are built fresh when they do.
local function rematch()
    _gen = _gen + 1
    for id, rec in pairs(Properties.getAll()) do
        local now = PropertyThemes.offered(rec) or nil
        if rec._wire ~= nil and rec._wire.themes ~= now then Properties.reannounce(id) end
    end
end

-- ============================================
-- Sending the choices
-- ============================================

--- Every property's look, to one theme resource, whole. The lowest property id wins a home two share.
local function push(resource)
    local p = _providers[resource]
    if not p or GetResourceState(resource) ~= 'started' then return end
    local ids = {}
    for id in pairs(Properties.getAll()) do ids[#ids + 1] = id end
    table.sort(ids)
    local map, n = {}, 0
    for _, id in ipairs(ids) do
        local rec = Properties.get(id) --[[@as table]]   -- (one of getAll's, just above)
        local hp, home = PropertyThemes.homeOf(rec)
        local t = math.tointeger(tonumber(rec.theme))
        if hp == p and home and t and t ~= 0 and p.byId[t] and map[home.key] == nil then
            map[home.key] = t
            n = n + 1
        end
    end
    local ok, res, why = call(resource, 'SetAllThemes', map)
    if not ok or res == false then
        log('%s did not take the themes: %s', resource, tostring(ok and why or res))
    elseif n > 0 then
        log('%d home theme(s) sent to %s', n, resource)
    end
end

--- Read a resource that declares themes; forget one that stopped declaring.
local function scan(resource)
    if (GetNumResourceMetadata(resource, METADATA_KEY) or 0) == 0 then
        if _providers[resource] then _providers[resource] = nil; rematch() end
        return
    end
    local p, why = readProvider(resource)
    if not p then
        log('%s declares %s, but %s — no themes from it', resource, METADATA_KEY, why)
        if _providers[resource] then _providers[resource] = nil; rematch() end
        return
    end
    _providers[resource] = p
    rematch()
    local matched = 0
    for _, rec in pairs(Properties.getAll()) do
        if (PropertyThemes.homeOf(rec)) == p then matched = matched + 1 end
    end
    log('%s: %d theme(s) for %d home(s); %d propert%s here are its homes', resource, #p.themes, p.homes,
        matched, matched == 1 and 'y' or 'ies')
    push(resource)
end

--- At start-up, after the properties: every running resource that declares themes.
function PropertyThemes.scanAll()
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res ~= GetCurrentResourceName() and GetResourceState(res) == 'started' then scan(res) end
    end
    _ready = true
end

AddEventHandler('onResourceStart', function(resource)
    if not _ready or resource == GetCurrentResourceName() then return end
    scan(resource)
end)

AddEventHandler('onResourceStop', function(resource)
    if _providers[resource] then
        _providers[resource] = nil
        rematch()
    end
end)

-- ============================================
-- Changing one
-- ============================================

--- Give a property one of its looks. Saved first; then the theme resource is told.
---@return boolean ok, string|nil why
function PropertyThemes.set(propertyId, themeId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local p, home = PropertyThemes.homeOf(rec)
    if not p then return false, 'This property has no themes' end
    ---@cast home -nil
    themeId = math.tointeger(tonumber(themeId))
    local theme = themeId and p.byId[themeId]
    if not theme then return false, 'That is not one of its themes' end
    if GetResourceState(p.resource) ~= 'started' then return false, 'Its themes are not running right now' end
    local ok, err = Properties.setTheme(rec.propertyId, themeId)
    if not ok then return false, err end
    local cok, res, why = call(p.resource, 'SetHomeTheme', home.key, themeId)
    if not cok or res == false then
        log('%s did not take theme %d for %s: %s', p.resource, themeId, home.key, tostring(cok and why or res))
        return false, 'Saved, but the home did not change: ' .. tostring(cok and why or 'its resource had an error')
    end
    return true
end

-- ============================================
-- Players: the sign's Theme
-- ============================================

local ACE = 'whip.devtools'

--- May this player change the look here? The people who may furnish it (server/property_objects.lua's
--- save): its owner at the property, or an admin from anywhere.
local function mayDecorate(source, player, rec)
    if rec.active == false then return false, 'This property is closed right now' end
    local admin = DevTools.hasAce(source, ACE)   -- developer mode on, too
    local mine = player and rec.ownerCharId and rec.ownerCharId == player.charId
    if not mine and not admin then return false, 'That is not your property' end
    local a = rec.world and rec.world.anchor
    if a and not admin then
        local c = GetEntityCoords(GetPlayerPed(source))
        local reach = (Config.PropertyStreamRange or 60.0) + (a.r or 0) + 40.0
        local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
        if dx * dx + dy * dy + dz * dz > reach * reach then return false, 'You need to be at the property' end
    end
    return true
end

SecureCallback('whip_core:property:themes', {
    rateLimit = 500, burst = 4,
    params = { {'propertyId', 'id'} },
}, function(source, player, propertyId)
    -- `false, why`, whip's refusal
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local ok, why = mayDecorate(source, player, rec)
    if not ok then return false, why end
    local info = PropertyThemes.infoOf(rec)
    if not info then return false, 'This property has no themes' end
    info.name = rec.name
    info.resource = nil
    return info
end)

SecureEvent('whip_core:server:propertySetTheme', {
    -- Each change redraws the home (and its furniture) for everyone near it.
    rateLimit = 1500,
    params = { {'propertyId', 'id'}, {'themeId', 'id', 0} },
}, function(source, player, propertyId, themeId)
    local rec = Properties.get(propertyId)
    local ok, why
    if not rec then
        ok, why = false, 'Unknown property'
    else
        ok, why = mayDecorate(source, player, rec)
        if ok then ok, why = PropertyThemes.set(propertyId, themeId) end
    end
    TriggerClientEvent('whip_core:client:propertyThemeSet', source, propertyId, ok == true, themeId)
    -- Refused: `false, why` — whip shows them the why and the Event Monitor records it
    if not ok then return false, why or 'Could not change the theme' end
    ---@cast rec -nil
    local p = PropertyThemes.homeOf(rec)
    local theme = p and p.byId[themeId]
    ShowSuccess(source, ('%s: %s'):format(rec.name, theme and theme.name or 'theme changed'))
end)

-- ============================================
-- Exports
-- ============================================

--- A property's looks: { label, current, themes = { { id, name, walls, trim, floor } } }, or nil.
exports('GetPropertyThemes', function(propertyId)
    local info = PropertyThemes.infoOf(Properties.get(propertyId))
    if not info then return nil end
    return { label = info.label, current = info.current, themes = info.themes }
end)

--- Give a property one of its looks, as its owner would from the sign (no checks on who).
exports('SetPropertyTheme', function(propertyId, themeId)
    return PropertyThemes.set(propertyId, themeId)
end)

-- ============================================
-- Test seams (whip_test 69). Inert unless Config.EnableTestSeams.
-- ============================================

--- Read a theme resource again (the test's stand-in changes its homes).
exports('__TestThemesRescan', function(resource)
    if Config.EnableTestSeams ~= true then return false end
    scan(resource)
    return _providers[resource] ~= nil
end)
