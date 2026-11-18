-- ============================================
-- Runtime points — interaction points made in code, from the server
-- ============================================
--
-- A point a resource adds while it runs: a Talk prompt on a quest giver, a "Hand over the package"
-- spot, a Start option on a job board. It is the same prompt as AddAction's, pressed with the same E,
-- and:
--
--   * it lives in memory and belongs to the resource that made it: gone when that resource stops,
--     removed with the rest of a run by ReleaseTag(tag);
--   * it says WHO IT IS FOR (an audience, server/audience.lua): only those players' games are sent
--     it, and a press from anyone else is refused;
--   * it can ride an entity by netId (an NPC): each game mounts it while it has that entity, and
--     mounts it again when the entity streams back in;
--   * pressing E runs its onUse HERE, on the server, after distance, audience and requirements have
--     passed: the only place a press can be believed.
--
--   local pointId = exports.whip_core:AddPoint({
--       at       = { netId = npcNetId, offset = vector3(0.0, 0.0, 0.3) },   -- or see AT below
--       label    = 'Talk',
--       icon     = 'chat',
--       options  = { { id = 'work', label = 'Got work?' }, { id = 'bye', label = 'Leave' } },   -- optional; see MENUS
--       require  = { job = 'police' },          -- AddAction's words, optional
--       audience = { people = { source } },     -- who sees it ('everyone' when left out)
--       talk     = true,                        -- a Talk on an NPC (icon 'talk' unless given): see "A Talk that cannot be talked to"
--       quietFor = { people = { source } },     -- with talk: who sees nothing (not "busy") while it is off
--       tag      = 'run:42',                    -- ReleaseTag('run:42') removes it
--       onUse    = function(source, use) end,   -- use = { pointId, option, path, useId, coords, netId }
--   })
--
-- A field a point does not have (AddAction's `onSelect`, a misspelt `lable`) is warned about in the
-- server console with the one it most likely meant, and the warnings come back as a third answer
-- (`local pointId, why, warnings = ...`): shared/interact_spec.lua. A wrong value is refused.
--
-- `at`: one place:
--   { coords = vector3(x, y, z), heading? }    a spot
--   { netId = n, offset?, bone? }              riding a networked entity (an NPC)
--   { vehicle = vehicleRef, offset?, bone? }   on a whip car (an id, { plate }, ...: Vehicles.idFromRef),
--                                              wherever it is out; nothing while it is in a garage
--   { ground = groundItemId, offset? }         over a ground pile (gone when the pile is picked up)
--   { container = containerId, offset? }       over a container
-- A car, a pile and a container get the point a little above them unless an offset says where (their
-- own prompts are on them: two badges on one spot would be one too many).
--
-- MENUS. An option can hold options of its own: choosing it opens them, with a Back, on the same
-- prompt (at most 3 deep, 6 to a level, 40 in all). Only an option with no options is ever pressed:
-- its onUse gets use.option (its id) and use.path, the ids from the top ('tools/hack/firewall'). The
-- menu is walked on the player's game; the press is checked here, the whole path, every option's
-- require on it.
--
-- Ids are above 2^32. On a client the point is the core action 'rpoint:<pointId>'
-- (client/runtime_points.lua). Not saved: a resource adds its points again when it starts.

RuntimePoints = {}

local RUNTIME_BASE = 4294967296   -- 2^32
local MAX_OPTIONS  = 6            -- on one level of a menu
local MAX_DEPTH    = 3            -- levels: the top, and two below it
local MAX_ALL      = 40           -- options in a whole menu
local USE_KEEP_MS  = 10000        -- how long a use is remembered (RuntimePoints.recentUse)

-- Where a point on a car, a pile or a container goes when no offset says: above it, clear of the
-- thing's own prompt (a car's middle is inside its body, where no badge is seen). The Director's menu reads it too.
RuntimePoints.LIFT = { vehicle = 1.1, ground = 0.5, container = 0.6 }
local LIFT = RuntimePoints.LIFT

local points  = {}   -- [pointId] = record
local nextN   = 0
local KEEP    = { pointId = true, owner = true, tag = true, input = true, sentTo = true, gone = true }
local lastUse = {}   -- [source] = { useId, pointId, option, netId, at }
local useSeq  = 0

-- ============================================
-- Small parts
-- ============================================

--- A function, or another resource's (a table that is callable and throws when indexed: only ever
--- read with rawget). The rule interactions.lua's `callable` keeps.
local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

local function glyph(v)
    return type(v) == 'string' and #v <= 40 and v:match('^[%w_]+$') ~= nil
end

--- The furthest a prompt can be seen from: the interaction grid's reach, as the client works it out
--- (interactions.lua seeFromCeiling): whole 25 m cells, at least one.
local function seeFromCeiling()
    return math.max(1, math.ceil((tonumber(Config.InteractVisibleRange) or 5.0) / 25.0)) * 25.0
end

--- x, y, z (and a heading, for a vector4 or a table's w / heading) from what a caller gave.
local function readXYZ(c)
    local t = type(c)
    local x, y, z, h
    if t == 'vector3' or t == 'vector4' then
        x, y, z = c.x, c.y, c.z
        if t == 'vector4' then h = c.w end
    elseif t == 'table' and not callable(c) then
        x, y, z = rawget(c, 'x') or rawget(c, 1), rawget(c, 'y') or rawget(c, 2), rawget(c, 'z') or rawget(c, 3)
        h = rawget(c, 'w') or rawget(c, 'heading')
    end
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0, finite(h) and (h % 360.0) or nil
end

local AT_HELP = 'at says where the point is: { coords = vector3(...) }, { netId = n }, { vehicle = id }, { ground = id } or { container = id }'

--- An `at`'s offset and bone onto `out`. Answers out, or false and why.
local function readRide(at, out, bones)
    if at.offset ~= nil then
        local ox, oy, oz = readXYZ(at.offset)
        if not (ox and oy and oz) or math.abs(ox) > 10 or math.abs(oy) > 10 or math.abs(oz) > 10 then
            return false, 'at.offset is a vector3 within 10 m of what it is on'
        end
        out.offset = { x = ox, y = oy, z = oz }
    end
    if at.bone ~= nil then
        if not bones then return false, 'at.bone is for a point on an entity (netId or vehicle)' end
        if type(at.bone) ~= 'string' or #at.bone > 40 or not at.bone:match('^[%w_]+$') then
            return false, "at.bone is a bone name, like 'SKEL_Head'"
        end
        out.bone = at.bone
    end
    return out
end

--- Where a point is: { x, y, z, heading }, { netId, offset, bone }, { vehicleId, offset, bone },
--- { groundId, offset } or { containerId, offset }.
local function readAt(at)
    if type(at) ~= 'table' or callable(at) then return false, AT_HELP end
    local named = {}
    for _, k in ipairs({ 'coords', 'netId', 'vehicle', 'ground', 'container' }) do
        if at[k] ~= nil then named[#named + 1] = k end
    end
    if #named > 1 then return false, ('at is one place, not %s'):format(table.concat(named, ' and ')) end
    if at.netId ~= nil then
        local n = Sanitize.id(at.netId, 1, 65535)
        if not n then return false, 'at.netId is a network id' end
        local ent = NetworkGetEntityFromNetworkId(n)
        if not ent or ent == 0 or not DoesEntityExist(ent) then return false, 'at.netId names nothing in the world' end
        return readRide(at, { netId = n }, true)
    end
    if at.vehicle ~= nil then
        local id = Vehicles.idFromRef(at.vehicle)
        if not id or not Vehicles.getDef(id) then return false, 'at.vehicle names no car whip knows' end
        return readRide(at, { vehicleId = id, offset = { x = 0.0, y = 0.0, z = LIFT.vehicle } }, true)
    end
    if at.ground ~= nil then
        local id = Sanitize.id(at.ground)
        if not id or not GroundItems.getById(id) then return false, 'at.ground names no ground pile' end
        return readRide(at, { groundId = id, offset = { x = 0.0, y = 0.0, z = LIFT.ground } }, false)
    end
    if at.container ~= nil then
        local id = Sanitize.id(at.container)
        if not id or not Containers.getDef(id) then return false, 'at.container names no container' end
        return readRide(at, { containerId = id, offset = { x = 0.0, y = 0.0, z = LIFT.container } }, false)
    end
    if at.coords ~= nil then
        local x, y, z, h = readXYZ(at.coords)
        if not x or x < -10000 or x > 10000 or y < -10000 or y > 10000 or z < -500 or z > 3000 then
            return false, 'at.coords must be a position on the map (a vector3)'
        end
        if at.heading ~= nil then
            if not finite(at.heading) then return false, 'at.heading must be a number' end
            h = at.heading % 360.0
        end
        return { x = x, y = y, z = z, heading = h }
    end
    return false, AT_HELP
end

--- A `require`, read by the requirement reader (requirements.lua), and an unknown word is refused: a
--- caller in code should hear about a typo. The words are AddAction's, from one list
--- (shared/interact_spec.lua), which also says what a door's `jobs` should have been.
local function readRequire(raw, where)
    if raw == nil or raw == false then return nil end
    if type(raw) ~= 'table' or callable(raw) then return false, where .. ' must be a table' end
    for k in pairs(raw) do
        if not InteractSpec.REQUIRE[k] then return false, InteractSpec.notARequirement(where, k) end
    end
    local req = Requirements.clean(raw)
    local lost = Requirements.lost(raw, req)
    if lost then return false, ('%s.%s could not be read (see AddAction\'s require)'):format(where, lost) end
    -- A zone both sides know: the client shows the prompt by its own zones and the server allows
    -- the press by trusted ones.
    if type(req) == 'table' and req.zone then
        for _, z in ipairs(req.zone) do
            if not Zones.isSaved(z) then
                return false, ('zone "%s" is not a saved zone: a point can only require one of those'):format(z)
            end
        end
    end
    return req
end

--- One level of options: each { id, label, icon, require, options? }; an option with options of its
--- own opens them (MENUS above). `count` is shared by every level, for the whole menu's cap. A field
--- an option does not have goes into `warn` (shared/interact_spec.lua).
local function readLevel(raw, depth, count, under, warn)
    if type(raw) ~= 'table' or callable(raw) or #raw == 0 then
        return false, (under and ('option "%s": options is a list of { id, label }'):format(under) or 'options is a list of { id, label }')
    end
    if depth > MAX_DEPTH then return false, ('a menu goes at most %d deep (option "%s" is one too many)'):format(MAX_DEPTH, under) end
    if #raw > MAX_OPTIONS then
        return false, (under and ('option "%s" has more than %d options'):format(under, MAX_OPTIONS)
            or ('a point has at most %d options'):format(MAX_OPTIONS))
    end
    local out, seen = {}, {}
    for i, o in ipairs(raw) do
        if type(o) ~= 'table' or callable(o) then return false, ('option %d is a table: { id, label }'):format(i) end
        local id = o.id
        if type(id) == 'number' then id = tostring(id) end
        if type(id) ~= 'string' or #id > 40 or not id:match('^[%w_%-]+$') then
            return false, ('option %d needs an id: letters, digits, _ and - (at most 40)'):format(i)
        end
        if seen[id] then return false, ('two options have the id "%s"'):format(id) end
        seen[id] = true
        InteractSpec.unknown(o, InteractSpec.POINT_OPTION, ('option "%s"'):format(id), warn, InteractSpec.HINT.POINT_OPTION)
        count.n = count.n + 1
        if count.n > MAX_ALL then return false, ('a menu has at most %d options in all'):format(MAX_ALL) end
        if o.label ~= nil and type(o.label) ~= 'string' then return false, ('option "%s": label is text'):format(id) end
        if o.icon ~= nil and not glyph(o.icon) then return false, ('option "%s": icon is a glyph name'):format(id) end
        local req, why = readRequire(o.require, ('option "%s" require'):format(id))
        if req == false then return false, why end
        local kids
        if o.options ~= nil then
            kids, why = readLevel(o.options, depth + 1, count, id, warn)
            if not kids then return false, why end
        end
        -- Its own reach (on foot 2.5 m, from a car 7 m, on one point): held to the point's own range, as the point's
        -- is. A menu's reach is its options' unless they give their own.
        local reach
        if o.reach ~= nil and o.reach ~= false then
            reach = InteractSpec.number(o.reach, ('option "%s" reach'):format(id), 0.5, 25, warn) or nil
        end
        out[#out + 1] = { id = id, label = o.label and Sanitize.string(o.label, 80, '') or nil, icon = o.icon, requires = req,
                          options = kids, reach = reach }
    end
    return out
end

--- The furthest any option in `list` (any level) reaches by its own `reach`, or nil when none has one.
local function furthestOption(list)
    local far
    for _, o in ipairs(list or {}) do
        if o.reach and (not far or o.reach > far) then far = o.reach end
        local deeper = o.options and furthestOption(o.options)
        if deeper and (not far or deeper > far) then far = deeper end
    end
    return far
end

--- The options. None given is one option that IS the point.
local function readOptions(raw, warn)
    if raw == nil then return { { id = 'default' } } end
    return readLevel(raw, 1, { n = 0 }, nil, warn)
end

--- The option a press names, by its path ('a/b/c'), and every option on the way to it (the top
--- first). Only an option with no options of its own can be pressed. nil when there is none.
---@return table|nil option
---@return table|nil chain
local function optionAt(options, path)
    if path == '' then
        -- The flat point's one option (an old client, or a point with no options).
        if #options == 1 and not options[1].options then return options[1], { options[1] } end
        return nil
    end
    local chain, level = {}, options
    local n = 0
    for id in (path .. '/'):gmatch('([^/]*)/') do
        n = n + 1
        if n > MAX_DEPTH or not level then return nil end
        local found
        for _, o in ipairs(level) do
            if o.id == id then found = o break end
        end
        if not found then return nil end
        chain[#chain + 1] = found
        level = found.options
    end
    if level then return nil end   -- a menu, not something to press
    return chain[#chain], chain
end

--- Everything a point is, from what a caller gave: the record's fields, or false and why.
---
--- A field a point does not have is warned about, into `warn` (shared/interact_spec.lua): `onSelect`
--- (AddAction's) on a point would otherwise do nothing and say nothing. Warned, not refused, as
--- AddAction's are; a wrong VALUE is refused below.
local function readDef(def, warn)
    if type(def) ~= 'table' or callable(def) then return false, 'a point is a table: { at, label, onUse, ... }' end
    InteractSpec.unknown(def, InteractSpec.POINT, '', warn, InteractSpec.HINT.POINT)
    if not callable(def.onUse) then
        -- AddAction's word is the likeliest one to have been used instead: say so here too.
        if def.onSelect ~= nil then return false, "a point needs onUse, a function(source, use) — onSelect is AddAction's" end
        return false, 'a point needs onUse, a function(source, use)'
    end
    if type(def.at) == 'table' and not callable(def.at) then
        InteractSpec.unknown(def.at, InteractSpec.POINT_AT, 'at', warn, InteractSpec.HINT.POINT_AT)
    end
    local at, why = readAt(def.at)
    if not at then return false, why end
    if def.label ~= nil and type(def.label) ~= 'string' then return false, 'label is text' end
    -- false clears a field (UpdatePoint); nil leaves it out.
    local icon = def.icon
    if icon == false then icon = nil end
    if icon ~= nil and not glyph(icon) then return false, 'icon is a glyph name (letters, digits and _)' end
    -- A Talk on an NPC shows the speech bubbles, not the plain E, unless it names its own (or false: none).
    if def.icon == nil and def.talk == true then icon = 'talk' end
    if def.focusMode ~= nil and def.focusMode ~= false and def.focusMode ~= 'aim' and def.focusMode ~= 'near' then
        return false, "focusMode is 'aim' (point at it) or 'near' (the closest wins)"
    end
    local requires
    requires, why = readRequire(def.require, 'require')
    if requires == false then return false, why end
    local options
    options, why = readOptions(def.options, warn)
    if not options then return false, why end
    local audience
    -- (A job's people too, followed as they clock on and off: below.)
    audience, why = Audience.read(def.audience, true, true)
    if audience == false then return false, why end
    if def.talk ~= nil and type(def.talk) ~= 'boolean' then
        return false, 'talk is true or false: a Talk on an NPC, shown as busy while it cannot be talked to'
    end
    local quietFor
    quietFor, why = Audience.read(def.quietFor, false)
    if quietFor == false then return false, 'quietFor: ' .. tostring(why) end
    -- Held to their ranges as before, and now said (the default when it is no number at all).
    local reach, seeFrom
    if def.reach ~= nil and def.reach ~= false then reach = InteractSpec.number(def.reach, 'reach', 0.5, 25, warn) or 2.0 end
    if def.seeFrom ~= nil and def.seeFrom ~= false then
        seeFrom = InteractSpec.number(def.seeFrom, 'seeFrom', 1, seeFromCeiling(), warn) or 5.0
    end
    -- How it looks and moves on every game it is sent to (client/interact_style.lua): a style's name
    -- or table, checked the way AddAction checks one — a wrong field is warned about and left out.
    -- false clears it (UpdatePoint).
    local style = nil
    if def.style ~= false then style = InteractSpec.style(def.style, 'style', warn) end
    -- Held to use (the player's game runs the hold and its ring; the press still comes here and is
    -- checked as any other — a hold is a way of asking, not a check). false clears it.
    local holdMs = nil
    if def.holdMs ~= nil and def.holdMs ~= false then holdMs = InteractSpec.number(def.holdMs, 'holdMs', 0, 10000, warn) end
    local out = {
        label = Sanitize.string(def.label or '', 80, ''), icon = icon, reach = reach, seeFrom = seeFrom,
        focusMode = def.focusMode or nil, requires = requires, options = options,
        audience = audience or 'everyone', enabled = def.enabled ~= false, onUse = def.onUse,
        talk = def.talk == true, quietFor = quietFor, style = style, holdMs = holdMs,
    }
    -- An option that reaches further than the point (or the default) widens the prompt to it; each nearer option
    -- is then held to its own on the player's game (client/runtime_points.lua) and here (useRuntimePoint).
    local far = furthestOption(options)
    if far and far > (reach or Config.InteractActiveRange or 2.0) then
        out.promptReach = far
        out.seeFrom = math.max(seeFrom or Config.InteractVisibleRange or 5.0, far)   -- seen as far as it reaches
    end
    for k, v in pairs(at) do out[k] = v end
    return out
end

-- ============================================
-- What each player's game is sent
-- ============================================

--- Does a `require` leave this player out for the whole session (its characters, its ACE)? Those
--- two are decided here and never sent.
local function hiddenBy(req, src, player)
    if type(req) ~= 'table' then return false end
    if req.charId ~= nil then
        local mine = false
        for _, c in ipairs(req.charId) do
            if player and c == player.charId then mine = true break end
        end
        if not mine then return true end
    end
    if req.ace ~= nil and not DevTools.hasAce(src, req.ace) then return true end   -- developer mode for whip.devtools
    return false
end

local function shownRequire(req)
    if type(req) ~= 'table' then return nil end
    if req.charId == nil and req.ace == nil then return req end
    local shown = {}
    for k, v in pairs(req) do
        if k ~= 'charId' and k ~= 'ace' then shown[k] = v end
    end
    return next(shown) ~= nil and shown or nil
end

--- One level of options as this player's game is sent it: what their characters and ACE leave out
--- is not there, and a menu with nothing left in it is not there either.
local function wireOptions(list, src, player)
    local out = {}
    for _, o in ipairs(list) do
        if not hiddenBy(o.requires, src, player) then
            local kids
            if o.options then kids = wireOptions(o.options, src, player) end
            if not kids or #kids > 0 then
                out[#out + 1] = { id = o.id, label = o.label, icon = o.icon, requires = shownRequire(o.requires), options = kids,
                                  reach = o.reach }
            end
        end
    end
    return out
end

--- The network id of a whip car's entity now, or nil (in a garage, not out yet).
local function vehicleNetId(vehicleId)
    local ent = Vehicles.getEntity(vehicleId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    local n = NetworkGetNetworkIdFromEntity(ent)
    return n ~= 0 and n or nil
end

--- Where a point is, as a game is sent it: its spot, the entity it rides, or the pile or container it
--- is over (each game finds those itself, by their prompts).
local function wirePlace(rec, w)
    w.x, w.y, w.z, w.heading = rec.x, rec.y, rec.z, rec.heading
    w.netId = rec.netId or (rec.vehicleId and vehicleNetId(rec.vehicleId)) or nil
    w.vehicle, w.ground, w.container = rec.vehicleId, rec.groundId, rec.containerId
    w.offset, w.bone = rec.offset, rec.bone
    return w
end

-- A Talk that cannot be talked to: a point made with `talk = true` rides an NPC
-- and opens a conversation with it. Rather than vanish when it cannot be used, it says why, and
-- pressing it only says so again:
--   someone else is talking to that NPC     Config.Conversations.speakingText, to everyone but them
--   the point is switched off (enabled =    Config.Conversations.busyText: a job is under way — except
--   false), and nobody is talking to it     to `quietFor`, who see nothing (the run's own
--                                           players, who have their own Talk on it)
-- It turns back into itself when the NPC is free (Conversations calls RuntimePoints.entityTalking).

local CONV_CFG = Config.Conversations or {}

--- Why this player cannot use a talk point now: the text to show, 'hide' (nothing at all), or nil.
---@return string|nil
local function busyFor(rec, src)
    if not rec.talk then return nil end
    local talkers = rec.netId and Conversations and Conversations.talkers(rec.netId) or nil
    local mine, other = false, false
    for s in pairs(talkers or {}) do
        if s == src then mine = true else other = true end
    end
    -- Switched off, those it is quiet for see nothing even while someone talks to the NPC: they have
    -- their own Talk on it, and that one already says so (one prompt, not two saying the same).
    if rec.enabled == false and (mine or (rec.quietFor and Audience.has(rec.quietFor, src))) then return 'hide' end
    if other and not mine then return CONV_CFG.speakingText or 'Someone is speaking with this person.' end
    if rec.enabled == false then return CONV_CFG.busyText or "They're busy right now." end
    return nil
end

--- What ONE player's game is sent, or nil when the point is not for them.
local function wireFor(rec, src, player)
    if not Audience.has(rec.audience, src) or hiddenBy(rec.requires, src, player) then return nil end
    local busy = busyFor(rec, src)
    if busy == 'hide' then return nil end
    if busy then
        -- Shown, and only saying why: the client's one option tells them again and asks nothing. Only
        -- to those who would see the point itself (its requires, and at least one option of theirs).
        local any = false
        for _, o in ipairs(rec.options) do
            if not hiddenBy(o.requires, src, player) then any = true break end
        end
        if not any then return nil end
        return wirePlace(rec, {
            pointId = rec.pointId, owner = rec.owner, label = busy, icon = rec.icon,
            reach = rec.promptReach or rec.reach, seeFrom = rec.seeFrom, focusMode = rec.focusMode, enabled = true, busy = busy,
            requires = shownRequire(rec.requires), options = { { id = 'busy', label = busy } },
            style = rec.style,
        })
    end
    local opts = wireOptions(rec.options, src, player)
    if #opts == 0 then return nil end
    return wirePlace(rec, {
        pointId = rec.pointId, owner = rec.owner, label = rec.label, icon = rec.icon,
        reach = rec.promptReach or rec.reach, pointReach = rec.promptReach and (rec.reach or Config.InteractActiveRange or 2.0) or nil,
        seeFrom = rec.seeFrom, focusMode = rec.focusMode, enabled = rec.enabled,
        requires = shownRequire(rec.requires), options = opts, style = rec.style, holdMs = rec.holdMs,
    })
end

--- A point as one game is sent it, as one string: the same for the same content (keys in order, strings
--- quoted). What each player was last sent is kept as this.
local function wireKey(v, depth)
    local t = type(v)
    if t == 'string' then return ('%q'):format(v) end
    if t == 'number' then return ('%q'):format(v) end
    if t ~= 'table' then return t .. ':' .. tostring(v) end
    depth = (depth or 0) + 1
    if depth > 16 then return tostring(v) end   -- its address: never equal to another, so it is sent
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == 'number' or ta == 'string' then return a < b end
        return tostring(a) < tostring(b)
    end)
    local out = {}
    for i, k in ipairs(keys) do out[i] = wireKey(k, depth) .. '=' .. wireKey(v[k], depth) end
    return '{' .. table.concat(out, ',') .. '}'
end

--- Tell every loaded player's game what changed: the point as they are to see it, or that it went.
--- Only the games whose copy changed are sent it: a job's start point is announced at each run's start
--- and end, and an NPC's Talk at each conversation, while for nearly everyone it reads the same. (A
--- resend would also put back a menu they had open on it.)
local function announce(rec, gone)
    local sent = rec.sentTo
    for src, player in pairs(Players) do
        -- Not one logging out: its conversation ending as it goes would send them a point at the
        -- character screen, after the logout below has cleared them.
        if not player.phantom and not player.closing then
            local w = (not gone) and wireFor(rec, src, player) or nil
            if w then
                local key = wireKey(w)
                if sent[src] ~= key then
                    sent[src] = key
                    TriggerClientEvent('whip_core:client:runtimePoint', src, rec.pointId, w)
                end
            elseif sent[src] then
                sent[src] = nil
                TriggerClientEvent('whip_core:client:runtimePoint', src, rec.pointId, false)
            end
        end
    end
    for src in pairs(sent) do
        if not Players[src] then sent[src] = nil end
    end
end

--- Does this point, or one of its options, name an ACE?
local function namesAce(rec)
    if type(rec.requires) == 'table' and rec.requires.ace ~= nil then return true end
    for _, o in ipairs(rec.options or {}) do
        if type(o.requires) == 'table' and o.requires.ace ~= nil then return true end
    end
    return false
end

-- Developer mode decides an ACE requirement (whip.devtools): a point that names one is decided again.
-- announce sends only the games whose copy changed, so this costs the admin who switched and nobody else.
DevTools.onModeChange(function()
    for _, rec in pairs(points) do
        if namesAce(rec) then announce(rec) end
    end
end)

--- A character coming in is sent every point for them (and nothing it had before).
Character.onLife('loaded', function(e)
    local src = e and e.source
    local player = src and Players[src]
    if not player then return end
    local list = {}
    for _, rec in pairs(points) do
        local w = wireFor(rec, src, player)
        if w then
            list[#list + 1] = w
            rec.sentTo[src] = wireKey(w)
        else
            rec.sentTo[src] = nil
        end
    end
    TriggerClientEvent('whip_core:client:runtimePoints', src, list)
end)

--- ...and one going out is sent none: at the character screen, nothing of the last one is offered.
Character.onLife('logout', function(e)
    local src = e and e.source
    if not src then return end
    for _, rec in pairs(points) do rec.sentTo[src] = nil end
    lastUse[src] = nil
    if e.why ~= 'disconnect' then TriggerClientEvent('whip_core:client:runtimePoints', src, {}) end
end)

-- A job's people as they are now: a point for { job = 'police', onDuty = true }
-- comes up for an officer who clocks on, and goes for one who clocks off or is fired. whip_core's own
-- hook, never the public job events.
local function jobMoved(e)
    for _, rec in pairs(points) do
        if Audience.isJob(rec.audience) and (type(e) ~= 'table' or e.key == nil or e.key == rec.audience.job) then announce(rec) end
    end
end
for _, kind in ipairs({ 'clockedOn', 'clockedOff', 'hired', 'fired', 'deleted' }) do Jobs.onLife(kind, jobMoved) end

-- ============================================
-- The registry: yours, swept when you stop, released with your run's tag
-- ============================================

local reg = Registry.new('runtimePoint', {
    label = 'point',
    scoped = true,
    releaseOrder = 10,   -- before NPCs and the rest: what a player can press goes first
    same = false,
    onRemove = function(_, rec)
        if rec.gone then return end
        rec.gone = true
        points[rec.pointId] = nil
        announce(rec, true)
    end,
})

-- ============================================
-- Making, changing, removing
-- ============================================

--- The warnings of one reading, said in the server console once each (InteractSpec.say), and what
--- the export hands back as its third answer: the list, or nil when there were none.
local function warned(owner, thing, warn)
    if #warn == 0 then return nil end
    InteractSpec.say('points', owner, thing, warn)
    return warn
end

--- Add a point for `owner`. Answers the pointId, or false and why — and, either way, a third answer:
--- the warnings (readDef), or nil when there were none. Never waits.
---@param owner string  Registry.caller(), read before anything else
---@param def table
---@return number|false
---@return string|false|nil
---@return string[]|nil warnings
function RuntimePoints.add(owner, def)
    local warn = {}
    local f, why = readDef(def, warn)
    local warnings = warned(owner, 'AddPoint', warn)
    if not f then return false, why, warnings end
    local tag = def.tag
    nextN = nextN + 1
    local id = RUNTIME_BASE + nextN
    f.pointId, f.owner, f.tag, f.input, f.sentTo = id, owner, tag, def, {}
    local ok, err = reg:add(owner, id, f, tag ~= nil and { tag = tag } or nil)
    if not ok then return false, err --[[@as string]], warnings end
    points[id] = f
    announce(f)
    -- `false`, not nil, in the middle: across an export a nil cuts off every answer after it (the
    -- warnings).
    return id, false, warnings
end

--- Change one of `owner`'s points: `patch` holds the fields to change (at, label, icon, options,
--- require, audience, reach, seeFrom, focusMode, enabled, onUse); everything else stays. The third
--- answer is the warnings, as RuntimePoints.add's.
---@return boolean ok
---@return string|false|nil why
---@return string[]|nil warnings
function RuntimePoints.update(owner, pointId, patch)
    local id = Sanitize.id(pointId)
    local rec = id and points[id]
    if not rec or rec.owner ~= owner then return false, 'no such point of yours' end
    if type(patch) ~= 'table' or callable(patch) then return false, 'a change is a table of the fields to change' end
    if patch.tag ~= nil then return false, "a point's tag cannot change" end
    local merged = {}
    for k, v in pairs(rec.input) do merged[k] = v end
    for k, v in pairs(patch) do merged[k] = v end
    local warn = {}
    local f, why = readDef(merged, warn)
    local warnings = warned(owner, ('point %s'):format(tostring(id)), warn)
    if not f then return false, why, warnings end
    -- In place, so the registry's entry and every reference to the point stay the same table; what
    -- the new reading leaves out (a cleared icon, a point moved off its entity) goes.
    for k in pairs(rec) do
        if not KEEP[k] then rec[k] = nil end
    end
    for k, v in pairs(f) do rec[k] = v end
    rec.input = merged
    announce(rec)
    return true, false, warnings   -- false, not nil: see RuntimePoints.add
end

---@return boolean ok
---@return string|nil why
function RuntimePoints.remove(owner, pointId)
    local id = Sanitize.id(pointId)
    local rec = id and points[id]
    if not id or not rec or rec.owner ~= owner then return false, 'no such point of yours' end
    return reg:remove(owner, id)
end

--- A point as anyone may read it (no onUse).
local function viewOptions(list)
    local out = {}
    for _, o in ipairs(list) do
        out[#out + 1] = { id = o.id, label = o.label, icon = o.icon, reach = o.reach, options = o.options and viewOptions(o.options) or nil }
    end
    return out
end

local function view(rec)
    return {
        pointId = rec.pointId, owner = rec.owner, tag = rec.tag, label = rec.label, icon = rec.icon,
        coords = rec.x and { x = rec.x, y = rec.y, z = rec.z } or nil, heading = rec.heading,
        netId = rec.netId, vehicleId = rec.vehicleId, groundId = rec.groundId, containerId = rec.containerId,
        enabled = rec.enabled, options = viewOptions(rec.options),
    }
end

--- `owner`'s points, or those under one of their tags.
---@return table[]
function RuntimePoints.list(owner, filter)
    filter = type(filter) == 'table' and filter or {}
    local out = {}
    for _, rec in pairs(points) do
        if rec.owner == owner and (filter.tag == nil or rec.tag == filter.tag) then out[#out + 1] = view(rec) end
    end
    table.sort(out, function(a, b) return a.pointId < b.pointId end)
    return out
end

--- An NPC began or stopped talking to someone (server/conversations.lua): its talk points are sent
--- again, so each game shows them as it now should.
---@param netId number
function RuntimePoints.entityTalking(netId)
    for _, rec in pairs(points) do
        if rec.talk and rec.netId == netId and not rec.gone then announce(rec) end
    end
end

-- A POINT ON A CAR rides whatever entity the car has now: a car put away and taken out again is a
-- new entity with a new network id, so its points are sent again each time (with none while it is
-- in). Core's hook, not the public event, which any resource can fire (the Vehicles.onLife rule).
local function carChanged(e)
    local id = type(e) == 'table' and e.vehicleId
    if not id then return end
    for _, rec in pairs(points) do
        if rec.vehicleId == id and not rec.gone then announce(rec) end
    end
end
for _, kind in ipairs({ 'spawned', 'despawned', 'deleted', 'released' }) do Vehicles.onLife(kind, carChanged) end

-- A CLAIMED car (ClaimVehicle, vehicle_claim.lua) is a new car with a new id: its points move to it.
Vehicles.onLife('claimed', function(e)
    local from, to = type(e) == 'table' and e.from, type(e) == 'table' and e.vehicleId
    if not from or not to then return end
    for _, rec in pairs(points) do
        if rec.vehicleId == from and not rec.gone then
            rec.vehicleId = to
            -- What UpdatePoint reads the point again from: the same car, by its new id.
            local at = {}
            for k, v in pairs(type(rec.input.at) == 'table' and rec.input.at or {}) do at[k] = v end
            at.vehicle = to
            rec.input.at = at
            announce(rec)
        end
    end
end)

--- This player's last press of a runtime point, if it is the one named and recent. For core code
--- that must only act on a real press: a conversation opens only from one (the Director plan, §6).
---@param source number
---@param useId number
---@param maxAgeMs number|nil  default 10 s
---@return table|nil use  { useId, pointId, option, path, netId, at }
function RuntimePoints.recentUse(source, useId, maxAgeMs)
    local u = lastUse[source]
    if not u or u.useId ~= useId then return nil end
    if GetGameTimer() - u.at > math.min(tonumber(maxAgeMs) or USE_KEEP_MS, USE_KEEP_MS) then return nil end
    return u
end

-- ============================================
-- Pressing E
-- ============================================

--- Where a point is right now, on the server: its spot, its entity's, its car's, or its pile's or
--- container's. nil when that has gone (the car put away, the pile picked up).
local function position(rec)
    local ent
    if rec.netId then
        ent = NetworkGetEntityFromNetworkId(rec.netId)
    elseif rec.vehicleId then
        ent = Vehicles.getEntity(rec.vehicleId)
    elseif rec.groundId then
        local g = GroundItems.getById(rec.groundId)
        if not g then return nil end
        return GroundItems.where(g)
    elseif rec.containerId then
        local c = Containers.getDef(rec.containerId)
        if not c or not c.x then return nil end
        return c.x, c.y, c.z
    else
        return rec.x, rec.y, rec.z
    end
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    local c = GetEntityCoords(ent)
    return c.x, c.y, c.z
end

--- The requirement with `alive` already settled (the option's own, else the point's: the client's
--- rule in client/actions.lua), so Requirements.met asks only the rest.
local function aliveSettled(req)
    local t = {}
    for k, v in pairs(req or {}) do t[k] = v end
    t.alive = false
    return t
end

SecureEvent('whip_core:server:useRuntimePoint', {
    -- A point can be for the downed (require.alive = false): decided below, not by the gate.
    whileDead = true,
    rateLimit = 500,
    -- The option's path: up to MAX_DEPTH ids of 40, with a / between.
    params    = { {'pointId', 'id'}, {'optionId', 'string', 40 * MAX_DEPTH + MAX_DEPTH - 1, ''} },
    near      = {
        at = function(_, _, pointId)
            local rec = points[pointId]
            if rec then return position(rec) end
        end,
        range = 27.0,          -- the widest any point may reach (25) and some slack
        allowUnknown = true,   -- removed as they pressed E: the handler says so
    },
}, function(source, player, pointId, optionId)
    local rec = points[pointId]
    if not rec then return false, 'That is not available' end
    local busy = busyFor(rec, source)
    if busy then return false, busy ~= 'hide' and busy or 'That is not available' end
    if not rec.enabled then return false, 'That is not available' end
    if not Audience.has(rec.audience, source) then return false, 'That is not for you' end
    local x, y, z = position(rec)
    if not (x and y and z) then return false, 'That is not available' end

    -- The whole way down: a menu the player could not have opened (its own require) opens nothing.
    local opt, chain = optionAt(rec.options, optionId)
    if not opt then return false, 'That is not available' end
    ---@cast chain -nil   -- optionAt answers an option and its chain together

    -- How close: the option's own reach, the deepest on its way down that gives one, else the point's.
    local reach
    for i = #chain, 1, -1 do
        if chain[i].reach then reach = chain[i].reach break end
    end
    reach = (reach or rec.reach or Config.InteractActiveRange or 2.0) + 2.0
    if not IsPlayerNear(source, x, y, z, reach) then return false, 'Too far away' end

    -- `alive` from the nearest that says (the option, the menus above it, the point): the client's
    -- rule for one option and its action, in client/actions.lua, carried down a menu.
    local alive
    for i = #chain, 1, -1 do
        local r = chain[i].requires
        if r and r.alive ~= nil then alive = r.alive break end
    end
    if alive == nil then alive = rec.requires and rec.requires.alive end
    if alive ~= false and player.isDead then return false, 'Not while downed' end
    local ok, why = Requirements.met(source, player, aliveSettled(rec.requires))
    if not ok then return false, why end
    local ids = {}
    for _, o in ipairs(chain) do
        ok, why = Requirements.met(source, player, aliveSettled(o.requires))
        if not ok then return false, why end
        ids[#ids + 1] = o.id
    end
    local path = table.concat(ids, '/')

    useSeq = useSeq + 1
    local netId = rec.netId or (rec.vehicleId and vehicleNetId(rec.vehicleId)) or nil
    lastUse[source] = { useId = useSeq, pointId = pointId, option = opt.id, path = path, netId = netId, at = GetGameTimer() }
    local use = { pointId = pointId, option = opt.id, path = path, useId = useSeq, netId = netId, coords = { x = x, y = y, z = z } }
    -- Actions.call (secure.lua): what onUse saves through whip lands with this press, as one.
    local good, res, reason = Actions.call(rec.owner, rec.onUse, source, use)
    if not good then
        print(('[whip_core:points] %s\'s point %d threw in onUse: %s'):format(tostring(rec.owner), pointId, tostring(res)))
        return false, 'Something went wrong'
    end
    if res == false then return false, reason end
end)

AddEventHandler('playerDropped', function() lastUse[source] = nil end)

-- ============================================
-- Exports
-- ============================================

--- Add a point: AddPoint(def) -> pointId | false, why — and the warnings, third.
exports('AddPoint', function(def)
    local owner = Registry.caller()
    return RuntimePoints.add(owner, def)
end)

--- Change one of your points: UpdatePoint(pointId, patch) -> true | false, why — and the warnings, third.
exports('UpdatePoint', function(pointId, patch)
    local owner = Registry.caller()
    return RuntimePoints.update(owner, pointId, patch)
end)

--- Remove one of your points: RemovePoint(pointId) -> true | false, why.
exports('RemovePoint', function(pointId)
    local owner = Registry.caller()
    return RuntimePoints.remove(owner, pointId)
end)

--- Your points, or those under one of your tags: GetPoints({ tag }) -> table[].
exports('GetPoints', function(filter)
    local owner = Registry.caller()
    local f = {}
    if type(filter) == 'table' and type(filter.tag) == 'string' then f.tag = filter.tag end
    return RuntimePoints.list(owner, f)
end)
