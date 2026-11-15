-- DirectorKit: helpers every Director file uses (numbers and places from saved data, plain-data copies, text cuts,
-- card definition, positions, entities from network ids). Loaded on both sides before every other Director file.

DirectorKit = {}
local K = DirectorKit
local SERVER = IsDuplicityVersion()

-- ---- numbers and places ----

--- A real number (not NaN, not infinite).
function K.finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

--- `v` when it is a real number, else nil.
function K.number(v) return K.finite(v) and v or nil end

--- `v` as a number between lo and hi, else `default`.
function K.num(v, default, lo, hi)
    local n = tonumber(v)
    if not K.finite(n) then return default end
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

--- A saved point ({ x, y, z }) as a vector3, or nil.
function K.vec3(c)
    if type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (K.finite(x) and K.finite(y) and K.finite(z)) then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

--- A saved place ({ x, y, z, heading }) as a plain table, its heading 0-360 (0 when it has none), or nil.
function K.place(c)
    if type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (K.finite(x) and K.finite(y) and K.finite(z)) then return nil end
    local h = tonumber(c.heading)
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = K.finite(h) and (h % 360.0) or 0.0 }
end

--- Straight-line metres between two points ({ x, y, z } or vectors).
function K.dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---- text ----

--- Spaces off both ends: text, or a number as text ('' for anything else).
function K.trim(s)
    if type(s) == 'number' then s = tostring(s) end
    if type(s) ~= 'string' then return '' end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- At most `n` bytes, never cut in the middle of a character (UTF-8). '' for what is not text.
function K.cut(s, n)
    if type(s) ~= 'string' then return '' end
    if #s <= n then return s end
    -- Back up to a character's first byte (continuation bytes are 10xxxxxx).
    local i = n
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i)
end

--- Text as it may be shown or kept: control characters made spaces, at most `max` bytes (K.cut). nil for not text.
function K.text(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ' ')
    return max and K.cut(v, max) or v
end

--- An item's name as players read it (Config.Items), else its key.
function K.itemName(key)
    local def = type(Config) == 'table' and Config.Items and Config.Items[key]
    return def and def.name or tostring(key)
end

--- An amount of money as players read it: $1,250 (whole dollars; -$40 owed).
function K.money(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local neg = s:sub(1, 1) == '-'
    if neg then s = s:sub(2) end
    s = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return (neg and '-$' or '$') .. s
end

--- A list of ids as a set: { [id] = true } (what is not text left out).
function K.idSet(list)
    local out = {}
    for _, v in ipairs(type(list) == 'table' and list or {}) do
        if type(v) == 'string' and v ~= '' then out[v] = true end
    end
    return out
end

-- ---- plain data ----

--- Is `v` something that can be called (a function, a FiveM function reference, a table with __call)?
function K.callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

--- A copy of `v` that is only data (a vector becomes { x, y, z[, heading] }): nothing callable, no userdata, no cycles.
--- `opts` (optional): depth (8, deeper is nil), keys per table (no cap), text bytes (no cap), clean (control
--- characters become spaces). For what crosses to another resource, a game, or the editor.
function K.plain(v, opts)
    opts = opts or {}
    local maxDepth, maxKeys, maxText, clean = opts.depth or 8, opts.keys, opts.text, opts.clean == true
    local seen = {}
    local function copy(x, depth)
        local t = type(x)
        if t == 'string' then
            if clean then return K.text(x, maxText) end
            return maxText and K.cut(x, maxText) or x
        end
        if t == 'number' then return K.number(x) end
        if t == 'boolean' then return x end
        if t == 'vector3' or t == 'vector4' then return { x = x.x, y = x.y, z = x.z, heading = t == 'vector4' and x.w or nil } end
        if t ~= 'table' or seen[x] or depth > maxDepth or K.callable(x) then return nil end
        seen[x] = true
        local out, n = {}, 0
        for k, val in pairs(x) do
            local kt = type(k)
            if kt == 'string' or kt == 'number' then
                n = n + 1
                if maxKeys and n > maxKeys then break end
                out[k] = copy(val, depth + 1)
            end
        end
        seen[x] = nil
        return out
    end
    return copy(v, 1)
end

-- Server helpers

if SERVER then
    --- Define a card type (DirectorNodes.define), logging in the console when it is refused.
    function K.define(def)
        local ok, why = DirectorNodes.define(def)
        if not ok then print('^1[whip_core:director] card type refused: ' .. tostring(why) .. '^0') end
        return ok, why
    end

    --- A database query that never throws (the store, the packs, the takes): its answer, or nil and why. Waits.
    function K.query(sql, params)
        local ok, res = pcall(MySQL.query.await, sql, params or {})
        if not ok then return nil, tostring(res) end
        return res
    end

    --- Where a player stands now, or nil while they are not in the world (no ped, leaving, in the character creator).
    function K.playerPos(src)
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        local p = Players[src]
        if p and (p.closing or p._inCreator) then return nil end
        return GetEntityCoords(ped)
    end
end

-- Client helpers

if not SERVER then
    --- The entity a network id names on this game, or nil (not here, gone). `kind`: 1 a ped, 2 a car, 3 an object.
    function K.entityOfNet(netId, kind)
        if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return nil end
        local e = NetworkGetEntityFromNetworkId(netId)
        if e == 0 or not DoesEntityExist(e) then return nil end
        if kind and GetEntityType(e) ~= kind then return nil end
        return e
    end

    --- A player's ped on this game, by their server id, while they are here and alive; nil otherwise.
    function K.pedOfServerId(sid)
        if not sid then return nil end
        local pl = GetPlayerFromServerId(sid)
        if pl == -1 then return nil end
        local p = GetPlayerPed(pl)
        if p == 0 or not DoesEntityExist(p) or IsPedDeadOrDying(p, true) then return nil end
        return p
    end

    --- Does this game own the entity (and so run it)?
    function K.mine(e) return e ~= nil and e ~= 0 and NetworkGetEntityOwner(e) == PlayerId() end
end
