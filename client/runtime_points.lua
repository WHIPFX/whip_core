-- Runtime points (client): the points resources make from the server (server/runtime_points.lua). The server
-- sends this game only this player's points. Each is mounted as the core action 'rpoint:<pointId>'
-- (client/actions.lua); E asks the server (whip_core:server:useRuntimePoint), which re-checks everything and runs onUse.
--
-- A point on an entity (at = { netId }, or a car's) is mounted only while this game has that entity, and again
-- when it streams back in with a new handle. A point over a ground pile or container is mounted a little above
-- that thing's own prompt and moved with it. One thread, twice a second, while any such point exists.
--
-- A menu (an option with options of its own) is walked here: choosing it puts its options on the same prompt
-- with a Back first; looking away or pressing one folds it back to the top. Only the press goes to the server,
-- as the path of ids from the top ('tools/hack/firewall').

local CORE = GetCurrentResourceName()

local known      = {}   -- [pointId] = what the server sent
local anchored   = {}   -- [pointId] = { ent = the handle it is mounted on, failed = a handle that refused, at = a spot it is mounted at }
local level      = {}   -- [pointId] = { id, id } the menu the prompt shows (nil: the top)
local anchorLoop = false

local BACK_ID  = '<back>'   -- no option's id can be this: theirs are letters, digits, _ and -
local MOVED_M  = 0.75       -- a pile thrown further than this takes its point with it

local function actionId(pointId) return 'rpoint:' .. tostring(pointId) end

local function vec(t)
    if type(t) ~= 'table' then return nil end
    local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
    if not (x and y and z) then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function entityOf(netId)
    if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

--- Where a point over a pile or container goes now: above that thing's prompt, or nil while there is none.
local function spotOver(p)
    local pid = (p.ground and ('ground_' .. tostring(p.ground))) or (p.container and ('container_' .. tostring(p.container)))
    if not pid then return nil end
    local d = Interactions.getAll()[pid]
    if not d or not (tonumber(d.x) and tonumber(d.y) and tonumber(d.z)) then return nil end
    local o = vec(p.offset) or vector3(0.0, 0.0, 0.0)
    return vector3(d.x + o.x, d.y + o.y, d.z + o.z)
end

--- The options of the menu a prompt shows (`path` from the top), or nil when the menu is gone.
local function menuAt(p, path)
    local list = p.options or {}
    for _, id in ipairs(path or {}) do
        local found
        for _, o in ipairs(list) do
            if o.id == id then found = o break end
        end
        if not found or type(found.options) ~= 'table' then return nil end
        list = found.options
    end
    return list
end

--- What the menus a level is under require, merged (the nearer one's words win): each option and Back needs
--- it too. A menu for the downed (alive = false) or seated (vehicle = 'in') stays usable in that state; the
--- server checks every menu on the path anyway. Second: the reach they give (the deepest that says), or nil.
local function inherited(p, path)
    local out, reach, list = nil, nil, p.options or {}
    for _, id in ipairs(path) do
        local found
        for _, o in ipairs(list) do
            if o.id == id then found = o break end
        end
        if not found then break end
        if type(found.requires) == 'table' then
            out = out or {}
            for k, v in pairs(found.requires) do out[k] = v end
        end
        reach = tonumber(found.reach) or reach
        list = type(found.options) == 'table' and found.options or {}
    end
    return out, reach
end

--- An option held to a nearer reach than its prompt: offered only within `r` metres of where the point is (`at`:
--- its spot, or the entity it rides), measured as the server measures the press (server/runtime_points.lua).
--- The engine's condition ctx carries no position, so the point's own is read here.
local function within(r, at)
    return function()
        local c = at.coords
        if at.entity then
            if not DoesEntityExist(at.entity) then return false end
            c = GetEntityCoords(at.entity)
        end
        return c ~= nil and #(GetEntityCoords(PlayerPedId()) - c) <= r
    end
end

local function withUp(up, own)
    if not up then return own end
    local t = {}
    for k, v in pairs(up) do t[k] = v end
    for k, v in pairs(type(own) == 'table' and own or {}) do t[k] = v end
    return t
end

local mount   -- forward: the menu's options mount the prompt again

--- Mount a point again where it is now, at the menu it is on (a step down, a Back, a fold).
local function remount(pointId)
    local p = known[pointId]
    if not p then return end
    local a = anchored[pointId]
    if a then
        if a.ent then mount(pointId, p, a.ent)
        elseif a.at then mount(pointId, p, nil, a.at) end
        return
    end
    mount(pointId, p)
end

--- Back to the top of a point's menu, a moment later: onBlur runs inside the prompt engine's pass, which must not be changed under it.
local function foldUp(pointId)
    if not level[pointId] then return end
    level[pointId] = nil
    CreateThread(function() remount(pointId) end)
end

--- Put a point in the world: at its spot, riding `ent`, or at `spot`. Answers whether it mounted.
function mount(pointId, p, ent, spot)
    local path = level[pointId] or {}
    local list = menuAt(p, path)
    if not list then
        path, list = {}, p.options or {}
        level[pointId] = nil
    end
    local at
    if ent then
        at = { entity = ent, offset = vec(p.offset), bone = p.bone }
    elseif spot then
        at = { coords = spot }
    else
        local c = vec(p)
        if not c then return false end
        at = { coords = c, heading = tonumber(p.heading) }
    end
    local opts = {}
    -- (At the top the path is empty: nothing inherited.)
    local up, menuReach = inherited(p, path)
    -- Per-option reach (server/runtime_points.lua): the prompt reaches as far as its furthest option (p.reach);
    -- an option with a nearer one (its own, a menu's above it, else the point's own, p.pointReach) is held to it.
    local promptReach = tonumber(p.reach) or Config.InteractActiveRange or 2.0
    local levelReach = menuReach or tonumber(p.pointReach)
    if #path > 0 then
        opts[1] = {
            id = BACK_ID, label = 'Back', icon = 'back', require = up,
            onSelect = function()
                local upPath = {}
                for i = 1, #path - 1 do upPath[i] = path[i] end
                level[pointId] = #upPath > 0 and upPath or nil
                remount(pointId)
            end,
        }
    end
    for _, o in ipairs(list) do
        local oid = o.id
        local entry = { id = oid, label = o.label, icon = o.icon, require = withUp(up, o.requires) }
        local r = tonumber(o.reach) or levelReach
        if r and r < promptReach - 0.01 then entry.canInteract = within(r, at) end
        if type(o.options) == 'table' and #o.options > 0 then
            -- A menu: named with a mark that says there is more behind it.
            entry.label = (type(o.label) == 'string' and o.label ~= '' and o.label or oid) .. '  ›'
            entry.onSelect = function()
                local down = {}
                for i, id in ipairs(path) do down[i] = id end
                down[#down + 1] = oid
                level[pointId] = down
                remount(pointId)
            end
        else
            -- The server decides distance, audience, requirements and the outcome.
            local full = {}
            for i, id in ipairs(path) do full[i] = id end
            full[#full + 1] = oid
            local named = table.concat(full, '/')
            entry.onSelect = function()
                TriggerServerEvent('whip_core:server:useRuntimePoint', pointId, named)
                foldUp(pointId)
            end
            -- Held to use (the point's holdMs): only what asks the server is held; Back and a menu entry stay a press.
            entry.holdMs = p.holdMs
        end
        opts[#opts + 1] = entry
    end
    -- A Talk that cannot be talked to (server/runtime_points.lua): it says why and asks the server nothing.
    -- Its one option is no menu, so whoever was in one is at the top when it is itself again (menuAt).
    if type(p.busy) == 'string' then
        local why = p.busy
        opts = { { id = 'busy', label = why, onSelect = function() UI.Notify(why, 'info') end } }
    end
    local ok, why = Actions.add(CORE, {
        id        = actionId(pointId),
        group     = 'runtime_points',
        at        = at,
        label     = (type(p.label) == 'string' and p.label ~= '') and p.label or 'Use',
        icon      = p.icon,
        reach     = p.reach,
        seeFrom   = p.seeFrom,
        focusMode = p.focusMode,
        style     = p.style,
        require   = p.requires,
        enabled   = p.enabled ~= false,
        options   = opts,
        -- Looking away from an open menu folds it back to the top.
        onBlur    = function() foldUp(pointId) end,
    })
    if not ok then
        print(('[whip_core:points] %s\'s point %s not mounted: %s'):format(tostring(p.owner), tostring(pointId), tostring(why)))
    end
    return ok ~= false   -- the id, or false and why
end

local function unmount(pointId)
    Actions.remove(CORE, actionId(pointId))
end

local function far(a, b)
    return #(a - b) > MOVED_M
end

--- Points on entities, piles and containers: mounted while this game has what they are on, again
--- when it has a new handle or has moved.
local function startAnchors()
    if anchorLoop then return end
    anchorLoop = true
    CreateThread(function()
        while next(anchored) do
            for pointId, a in pairs(anchored) do
                local p = known[pointId]
                if p and p.netId ~= nil then
                    local ent = entityOf(p.netId)
                    if ent and ent ~= a.ent and ent ~= a.failed then
                        if mount(pointId, p, ent) then a.ent, a.failed = ent, nil else a.ent, a.failed = nil, ent end
                    elseif not ent and a.ent then
                        -- Gone from this game: no onBlur comes, so reset to the top on return.
                        unmount(pointId)
                        a.ent = nil
                        level[pointId] = nil
                    end
                elseif p then
                    local spot = spotOver(p)
                    if spot and (not a.at or far(spot, a.at)) then
                        if mount(pointId, p, nil, spot) then a.at = spot else a.at = nil end
                    elseif not spot and a.at then
                        unmount(pointId)
                        a.at = nil
                        level[pointId] = nil
                    end
                end
            end
            Wait(500)
        end
        anchorLoop = false
    end)
end

--- A point arrived, changed, or went (false).
local function apply(pointId, p)
    pointId = tonumber(pointId)
    if not pointId then return end
    local had = known[pointId] ~= nil
    anchored[pointId] = nil
    if type(p) ~= 'table' then
        known[pointId] = nil
        level[pointId] = nil
        if had then unmount(pointId) end
        return
    end
    known[pointId] = p
    if p.netId ~= nil then
        local a = {}
        anchored[pointId] = a
        local ent = entityOf(p.netId)
        if ent then
            if mount(pointId, p, ent) then a.ent = ent else a.failed = ent end
        elseif had then
            unmount(pointId)   -- it was mounted somewhere else; it comes back with its entity
            level[pointId] = nil
        end
        startAnchors()
    elseif p.ground ~= nil or p.container ~= nil then
        local a = {}
        anchored[pointId] = a
        local spot = spotOver(p)
        if spot then
            if mount(pointId, p, nil, spot) then a.at = spot end
        elseif had then
            unmount(pointId)
            level[pointId] = nil
        end
        startAnchors()
    elseif p.vehicle ~= nil then
        -- A car with no network id: nothing to ride until the server sends it again.
        if had then unmount(pointId) end
        level[pointId] = nil
    else
        mount(pointId, p)
    end
end

RegisterNetEvent('whip_core:client:runtimePoint', function(pointId, p)
    apply(pointId, p)
end)

--- Everything, when the character loads (an empty list when it logs out).
RegisterNetEvent('whip_core:client:runtimePoints', function(list)
    local seen = {}
    for _, p in ipairs(type(list) == 'table' and list or {}) do
        local id = type(p) == 'table' and tonumber(p.pointId)
        if id then
            seen[id] = true
            apply(id, p)
        end
    end
    for id in pairs(known) do
        if not seen[id] then apply(id, false) end
    end
end)
