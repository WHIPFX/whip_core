-- Actions: the one way to put "the player can do X" into the world (AddAction).
-- One declaration for every place an action can live (a world prompt, a car part, the F1 wheel).
-- `at` says where; everything else reads the same wherever it is:
--
--     exports.whip_core:AddAction({
--         id       = 'bench',                        -- yours; adding it again replaces it
--         at       = { coords = vector3(1, 2, 3) },  -- see AT below
--         label    = 'Weapon Bench',                 -- text, or function(ctx) returning text
--         icon     = 'wrench',
--         require  = { job = 'gunsmith', item = 'toolkit' },   -- see REQUIRE below
--         canInteract = function(ctx) return true end,         -- optional, your own rule
--         onSelect    = function(ctx) ... end,                 -- may wait: it runs in its own thread
--     })
--
-- AT
--   { coords = vec3, heading?, follow? }        a prompt at a point. heading: stands like a sign;
--                                               none: faces you. follow: returns x, y, z, heading
--   { entity = handle, offset? = vec3, bone?, heading? }   a prompt riding on an entity; removed a few
--                                               seconds after it is gone (`onGone` is told). heading: a
--                                               sign at that yaw from the entity's own facing, turning
--                                               with it (180: on its back); none: faces you
--   { netId = n, offset?, bone?, heading? }     the same by network id: off while the entity is not
--                                               streamed in here, back when it is
--   { model = 'prop_x' | { ... }, offset?, heading?, faces?, perModel? }   a prompt on every prop of
--                                               that model near the player. perModel:
--                                               { [model] = { offset, heading } }. onFound / onLost
--                                               hear every one within 50 m
--   { vehiclePart = 'hood' }                    an option on a car part's prompt: 'hood', 'trunk',
--                                               'door_dside_f', ..., 'bike', 'bicycle', 'boat'
--   { radial = true }                           the F1 wheel: the slab shows `icon`, the pill
--                                               shows `description` (text, or function(ctx))
--   { aimBox = 'vehicle'|'object'|'ped'|'world'|{ ... } }   a prompt where the player looks, on the box
--                                               of what they aim at (client/aim_box.lua), offered
--                                               only while the look meets one in reach. ctx.entity is
--                                               the thing, ctx.coords the point. 'world': the map
--                                               itself (ctx.entity nil, ctx.world true, ctx.normal)
--
-- REQUIRE (all optional; every one listed must pass; an unknown word is refused when added)
--   alive = false        also offered while downed (default: alive only)
--   vehicle = 'in'|'out' in a vehicle, or on foot. A prompt is on foot unless it says 'in';
--                        a vehiclePart action is always on foot and alive
--   job = 'police' | { 'police', 'ems' }   has a role at any of these jobs
--   onDuty = true        ...and is on duty there (or anywhere, when no job is named)
--   jobPermission = 'canManage'            ...and that role may do this (no job named: any job that grants it)
--   item = 'toolkit' | { item = 'lockpick', count = 2 } | { 'toolkit', 'gloves' }
--   held = 'jerry_can' | { 'jerry_can', 'weapon_pistol' }   that item in the hand (SetHeldItem)
--   zone = 'zone_id' | { ... }             standing inside one of these zones
--   charId = 12 | { 12, 40 }               one of these characters
--   ace = 'whip.devtools'                  holds this ACE (asked of the server once, then remembered)
--
-- ctx: what canInteract, label functions and onSelect receive
--   ctx.id, ctx.owner          your id, and your resource
--   ctx.option                 which option (see OPTIONS)
--   ctx.entity, ctx.coords     the entity aimed at or ridden (the car of a part), and the point
--   ctx.player                 aiming at a player: { serverId, playerIdx, isDead, activeJob }
--   ctx.typed                  what is typed so far with a blinking caret, or false (world prompts only);
--                              a value, not a function, since functions are repacked on every crossing
-- onSelect's ctx alone has the verbs:
--   ctx.flash(r, g, b)         tint the prompt for a moment (world prompts)
--   ctx.status(text, ms)       say something on the prompt (a toast elsewhere)
--   ctx.refuse(why)            amber flash and the reason (an error toast elsewhere)
--   ctx.beginInput(opts), ctx.cancelInput(), ctx.inputText()   type a number into the prompt
--
-- World prompt look and competition (ignored by the other places):
--   reach = 2.0                how close to use it, metres (0.5-25)
--   seeFrom = 5.0              how far away it shows, metres
--   scale = 1.5                bigger or smaller than every other prompt (0.25-4)
--   sizeRange = 2.0            the distance its size is designed at; default its reach
--   focusMode = 'near'         'aim' (default): what you look at wins; 'near': the closest wins
--   onBlur = function() end    called when it stops being the one E acts on
--   style = 'subtle'           a style's name or table (client/interact_style.lua); SetActionStyle changes it in place
--   holdMs = 1500              hold E (A on a pad) this long to use it; also on an option
--   press = true               the hand goes out towards the point and back (client/interact_press.lua),
--                              only how it looks; onSelect runs at once. true: towards the prompt; a
--                              vector3; or { coords?, offset?, normal? }. Also on a car part and on an option.
--
-- On a car part (at.vehiclePart):
--   first = true               at the top of the part's stack while canInteract says yes (e.g. a pump
--                              nozzle in hand at the filler); also on an option
--
-- Unknown fields are warned about, not refused (shared/interact_spec.lua); the warnings come back as
-- AddAction's third answer. A wrong `require` is refused.
--
-- OPTIONS: several choices on one action. Each takes its own id, label, icon, image, description,
-- require, canInteract and onSelect, falling back to the action's:
--     options = { { id = 'buy', label = 'Buy', onSelect = ... }, { id = 'sell', label = 'Sell', ... } }
-- On a world prompt an option may have `options` of its own: a menu (see Menus below). Leaves take
-- what they leave out from the options above them, then the action; onSelect gets ctx.under.
-- `options = function(ctx) return { ... } end` fills the menu each time it opens (it may wait), and
-- `stay = true` on an option down a menu keeps the prompt there after its onSelect.
--
-- Each action is mounted into the engine its `at` names as an entry called `act:<resource>:<id>`.

Actions = {}

--- What each action is mounted as: [key] = { kind, ids = { engineId, ... }, partKey?, entity? }
local mounted = {}

--- Why the last mount of an action failed, for Actions.add to answer with: [key] = reason
local mountError = {}

--- Prompts riding on an entity, refreshed twice a second: [key] = { pid, at, owner, id, live }
local riding = {}

--- The entity an action rides now: its handle (`at.entity`) or what its `at.netId` names here (nil if not streamed in).
---@return number|nil
local function entityOf(at)
    if at.entity ~= nil then return at.entity end
    local n = at.netId
    if n == nil or not NetworkDoesNetworkIdExist(n) then return nil end
    local ent = NetToEnt(n)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

-- A callback that threw is reported once per action per field.

local reported = {}

local function report(key, what, err)
    local k = tostring(key) .. '|' .. what
    if reported[k] then return end
    reported[k] = true
    print(('[whip_core:actions] %s of "%s" threw (reported once): %s'):format(what, tostring(key), tostring(err)))
end

local function forgetReports(key)
    local prefix = tostring(key) .. '|'
    for k in pairs(reported) do
        if k:sub(1, #prefix) == prefix then reported[k] = nil end
    end
end

--- A condition's answer, FiveM-truthy: false, nil and 0 are no (a native answering 0 means no).
local function yes(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- Requirements

-- ACE answers, asked of the server once each and remembered. A condition cannot wait for a round trip,
-- so the first ask answers "no". Only a real answer is remembered; a refusal or lost request is asked again.
local aceCache, acePending, aceRetryAt = {}, {}, {}
local ACE_RETRY_MS = 2000

-- The current ask per ACE: an answer to an older ask is dropped.
local aceAsk = {}

local function hasAce(ace)
    local v = aceCache[ace]
    if v ~= nil then return v end
    if not acePending[ace] and GetGameTimer() >= (aceRetryAt[ace] or 0) then
        acePending[ace] = true
        local ask = (aceAsk[ace] or 0) + 1
        aceAsk[ace] = ask
        CreateThread(function()
            local ok, why = Callback('whip_core:checkAcePermission', tostring(ace))
            if aceAsk[ace] ~= ask then return end
            if why == nil then
                aceCache[ace] = yes(ok)
                aceRetryAt[ace] = nil
            else
                aceRetryAt[ace] = GetGameTimer() + ACE_RETRY_MS
            end
            acePending[ace] = nil
        end)
    end
    return false
end

--- Forget what the server said about `ace` and ask again now, e.g. after dev tools are given or taken.
---@param ace string
function Actions.refreshAce(ace)
    ace = tostring(ace)
    aceCache[ace], aceRetryAt[ace], acePending[ace] = nil, nil, nil
    aceAsk[ace] = (aceAsk[ace] or 0) + 1
    hasAce(ace)
end

-- Dev tools given or taken mid-session: ask again.
RegisterNetEvent('whip_core:client:devtoolsGranted', function() Actions.refreshAce('whip.devtools') end)
RegisterNetEvent('whip_core:client:devtoolsRevoked', function() Actions.refreshAce('whip.devtools') end)

local function list(v)
    if type(v) == 'table' then return v end
    return { v }
end

--- `item` alone may be a list of items or one { item, count }, told apart by the `item` field.
local function itemList(v)
    if type(v) ~= 'table' or v.item ~= nil then return { v } end
    return v
end

--- Does the player meet a `require` table? Answers true, or false and a short reason.
---@param req table|nil
---@param aliveDecided boolean|nil  the caller has already settled `alive`; every other requirement is still asked
---@return boolean
---@return string|nil why
function Actions.requirementsMet(req, aliveDecided)
    if type(req) ~= 'table' then
        if aliveDecided then return true end
        return not PlayerIsDead, PlayerIsDead and 'downed' or nil
    end

    if not aliveDecided and req.alive ~= false and PlayerIsDead then return false, 'downed' end

    if req.vehicle == 'in' or req.vehicle == 'out' then
        local inVeh = IsPedInAnyVehicle(PlayerPedId(), false)
        if req.vehicle == 'in' and not inVeh then return false, 'not in a vehicle' end
        if req.vehicle == 'out' and inVeh then return false, 'in a vehicle' end
    end

    if req.job ~= nil then
        local any = false
        for _, job in ipairs(list(req.job)) do
            if PlayerHasJob(job)
                and (not req.onDuty or PlayerIsClockedOn(job))
                and (req.jobPermission == nil or JobHasPermission(job, req.jobPermission)) then
                any = true
                break
            end
        end
        if not any then return false, 'job' end
    elseif req.jobPermission ~= nil then
        -- A permission with no job named: any job whose role grants it.
        if not PlayerHasJobPermission(req.jobPermission, req.onDuty == true) then return false, 'job permission' end
    elseif req.onDuty and not PlayerIsClockedOn() then
        return false, 'off duty'
    end

    if req.item ~= nil then
        for _, it in ipairs(itemList(req.item)) do
            local key, count = it, 1
            if type(it) == 'table' then key, count = it.item, tonumber(it.count) or 1 end
            if (Inventory.getItemCount(key) or 0) < count then return false, 'item ' .. tostring(key) end
        end
    end

    -- The item in the hand (Inventory.heldItem), asked before any canInteract so it costs nothing otherwise.
    if req.held ~= nil then
        local h = Inventory.heldItem()
        local item = h and h.item
        local ok = false
        if type(req.held) == 'table' then
            for _, key in ipairs(req.held) do
                if key == item then ok = true break end
            end
        else
            ok = item ~= nil and req.held == item
        end
        if not ok then return false, 'held' end
    end

    if req.zone ~= nil then
        local inside = false
        for _, z in ipairs(list(req.zone)) do
            if IsInsideZone(z) then inside = true break end
        end
        if not inside then return false, 'zone' end
    end

    if req.charId ~= nil then
        local me = PlayerData and PlayerData.charId
        local ok = false
        for _, c in ipairs(list(req.charId)) do
            if tonumber(c) == me then ok = true break end
        end
        if not ok then return false, 'character' end
    end

    if req.ace ~= nil and not hasAce(req.ace) then return false, 'permission' end

    return true
end

--- Is this a `require` table whip can read? nil when it is, or why not. Checked when the action is added,
--- since an unknown key would otherwise require nothing (words shared via shared/interact_spec.lua).
---@param req any
---@param kind string  the engine it is going to: 'prompt' | 'part' | 'radial'
---@return string|nil why
local function checkRequire(req, kind)
    local why = InteractSpec.checkRequire(req, 'require')
    if why or req == nil then return why end
    -- Refuse a requirement an engine can never pass (a car part is used standing at the car).
    if kind == 'part' and (req.alive == false or req.vehicle == 'in') then
        return "a vehiclePart action is used standing at the car, alive — drop alive = false / vehicle = 'in'"
    end
    return nil
end

--- The requirement `field` as given: the option's own, else the action's, else nil. (Not `a and b or nil`,
--- which would turn an option's own `false` into the action's value.)
local function requireField(def, o, field)
    local v = nil
    if o.require ~= nil then v = o.require[field] end
    if v == nil and def.require ~= nil then v = def.require[field] end
    return v
end

--- Does any option of this action ask to be offered in this state? Tells the engine (allowDowned /
--- allowSeated); check() still decides each option.
local function anyOption(entry, field, value)
    for _, o in ipairs(entry.opts) do
        if requireField(entry.def, o, field) == value then return true end
    end
    return false
end

-- Reading an action

--- A text field (label, icon, image, description) of an option, falling back to the action's: a string
--- is the value, anything else is called with ctx.
local function resolveText(entry, o, field, ctx)
    -- The option's own, else the menus it is under (nearest first), else the action's.
    local v = o[field]
    local up = o._up
    while v == nil and up do
        v = up[field]
        up = up._up
    end
    if v == nil then v = entry.def[field] end
    if v == nil then return nil end
    if type(v) == 'string' then return v end
    local ok, res = pcall(v, ctx)
    if not ok then
        report(entry.key, field, res)
        return nil
    end
    if res == nil then return nil end
    return tostring(res)
end

--- May this option be offered right now? Answers true, or false and why.
---@return boolean
---@return string|nil why
local function check(entry, o, ctx)
    local def = entry.def
    if def.enabled == false or o.enabled == false then return false, 'switched off' end
    -- An option down a menu must pass the one it is under too.
    if o._up then
        local ok, why = check(entry, o._up, ctx)
        if not ok then return false, why end
    end
    if def.at.entity ~= nil and not DoesEntityExist(def.at.entity) then return false, 'entity gone' end
    if def.at.netId ~= nil and not entityOf(def.at) then return false, 'its entity is not streamed in here' end

    -- Downed: the option's own `alive` if it says, else the action's.
    if PlayerIsDead and requireField(def, o, 'alive') ~= false then return false, 'downed' end

    local ok, why = Actions.requirementsMet(def.require, true)
    if not ok then return false, why end
    if o.require ~= nil then
        ok, why = Actions.requirementsMet(o.require, true)
        if not ok then return false, why end
    end

    -- On foot unless it says otherwise (the wheel is open in a car anyway), asked per option.
    if entry.kind ~= 'radial' and IsPedInAnyVehicle(PlayerPedId(), false)
        and requireField(def, o, 'vehicle') ~= 'in' then
        return false, 'in a vehicle'
    end

    -- The action's rule, then the option's (a numeric loop: a nil first slot must not end it).
    for i = 1, 2 do
        local fn
        if i == 1 then fn = def.canInteract else fn = o.canInteract end
        if fn ~= nil then
            local good, res, reason = pcall(fn, ctx)
            if not good then
                report(entry.key, 'canInteract', res)
                return false, 'canInteract threw'
            end
            if not yes(res) then return false, reason or 'canInteract said no' end
        end
    end
    return true
end

--- A ctx for conditions and label functions: made once per option and reused. It carries no functions,
--- since CfxLua packs a function as a new reference on every crossing.
local function condCtx(entry, o)
    -- `typed` starts false (nothing being typed); mountPrompt keeps it current.
    o._ctx = o._ctx or { id = entry.id, owner = entry.owner, option = o.id, typed = false }
    return o._ctx
end

--- Give a fresh ctx the verbs that speak through a world prompt.
local function promptVerbs(ctx, pid)
    ctx.flash = function(r, g, b) if pid then Interactions.flash(pid, r, g, b) end end
    ctx.status = function(text, ms) if pid then Interactions.setStatus(pid, tostring(text or ''), ms) end end
    ctx.refuse = function(why)
        if not pid then return end
        Interactions.flash(pid, 255, 170, 60)
        if why then Interactions.setStatus(pid, tostring(why), 2500) end
    end
    ctx.beginInput = function(opts) if pid then return Interactions.beginInput(pid, opts) end return false end
    ctx.cancelInput = function() if pid then Interactions.cancelInput(pid) end end
    ctx.inputText = function() if pid then return Interactions.inputText(pid) end return nil end
    ctx.typed = pid and Interactions.inputDisplay(pid) or false   -- a value, as in condCtx
end

--- ...and the ones for the wheel, which has no circle to flash.
local function menuVerbs(ctx)
    ctx.flash = function() end
    ctx.status = function(text, ms) if text then UI.Notify(tostring(text), 'info', ms or 2500) end end
    ctx.refuse = function(why) if why then UI.Notify(tostring(why), 'error', 3000) end end
    ctx.beginInput = function() return false end
    ctx.cancelInput = function() end
    ctx.inputText = function() return nil end
    ctx.typed = false
end

--- x, y, z of a vector3, a vector4 or a table ({ x, y, z } or { 1, 2, 3 }); nil when it is none of them.
local function point3(v)
    if v == nil then return nil end
    local x, y, z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
    if not (x and y and z) then return nil end
    return x, y, z
end

--- Where a `press` presses (client/interact_press.lua) and the way that surface faces; nil when `press` is none of its forms.
---@param ctx table  onSelect's: coords (the prompt's point now), entity (what it is on)
---@param at table   the action's `at`
---@param here vector3|nil  the prompt's own point when ctx.coords is something else (a car part: the car)
---@param faceH number|nil  the way the prompt's circle faces now, when known
local function pressTarget(press, ctx, at, here, faceH)
    local where = here or ctx.coords
    if press == true then
        if not where then return nil end
        local h = faceH or (type(at) == 'table' and at.model == nil and (tonumber(at.heading)
            or (type(at.coords) == 'vector4' and at.coords.w)) or nil)
        if h then
            local r = math.rad(h)
            return where, vector3(-math.sin(r), math.cos(r), 0.0)
        end
        return where, nil
    end
    if type(press) == 'vector3' or type(press) == 'vector4' then
        return vector3(press.x, press.y, press.z), nil
    end
    if type(press) ~= 'table' then return nil end

    local nx, ny, nz = point3(press.normal)
    local normal = nx and vector3(nx, ny, nz) or nil
    local cx, cy, cz = point3(press.coords)
    if cx then return vector3(cx, cy, cz), normal end

    local ox, oy, oz = point3(press.offset)
    if ox then
        local ent = ctx.entity
        if ent and DoesEntityExist(ent) then
            -- In the entity's frame, the normal too.
            -- (point3 answers all three or none.)
            local p = GetOffsetFromEntityInWorldCoords(ent, ox, oy --[[@as number]], oz --[[@as number]])
            if normal then
                normal = GetOffsetFromEntityInWorldCoords(ent, nx --[[@as number]], ny --[[@as number]], nz --[[@as number]])
                    - GetEntityCoords(ent)
            end
            return p, normal
        end
        if not where then return nil end
        return where + vector3(ox, oy, oz), normal
    end

    -- { normal } alone: the prompt's point, facing that way.
    if normal and where then return where, normal end
    return nil
end

--- The player chose this option. Checked again (what drew a moment ago may have changed), then
--- onSelect runs IN ITS OWN THREAD: it may wait for the server or a progress bar without holding up
--- the prompt loop or the wheel that called it.
---@param pid string|nil  the prompt it was chosen on, for the verbs
---@param extra table|nil entity, coords, player
---@param here vector3|nil  where a `press` presses when that is not ctx.coords (a car part's prompt)
---@param handless boolean|nil  the F1 wheel: `press` is not read there (shared/interact_spec.lua)
---@param after function|nil  called once onSelect has finished (a `stay` option's menu filled again)
local function fire(entry, o, pid, extra, here, handless, after)
    local ctx = { id = entry.id, owner = entry.owner, option = o.id }
    if extra then for k, v in pairs(extra) do ctx[k] = v end end
    if pid then promptVerbs(ctx, pid) else menuVerbs(ctx) end

    if not check(entry, o, ctx) then return end

    -- The option's own, else the menus it is under (nearest first), else the action's. ctx.under: the menu it is in.
    local fn = o.onSelect
    local up = o._up
    ctx.under = up and up.id or nil
    while fn == nil and up do
        fn = up.onSelect
        up = up._up
    end
    if fn == nil then fn = entry.def.onSelect end
    if fn == nil then return end

    -- `press`: the option's, else the menus it is under, else the action's.
    local press = o.press
    up = o._up
    while press == nil and up do
        press = up.press
        up = up._up
    end
    if press == nil then press = entry.def.press end

    -- The hand press plays alongside and never holds up onSelect. World prompts and car parts only, not the wheel.
    if not handless and press ~= nil and press ~= false then
        local reg = pid and Interactions.getAll()[pid]
        if not here and reg and reg.x then here = vector3(reg.x, reg.y, reg.z) end
        local target, normal = pressTarget(press, ctx, entry.def.at, here, reg and reg.heading)
        if target then
            InteractPress.play(target, { normal = normal })
        else
            report(entry.key, 'press', 'no point to press here (press takes true, a point, or { coords, offset, normal }): no press')
        end
    end

    CreateThread(function()
        local ok, err = pcall(fn, ctx)
        if not ok then report(entry.key, 'onSelect', err) end
        if after then after() end
    end)
end

-- Mounting into the engines

local function engineId(entry, o)
    if #entry.opts > 1 then return ('act:%s#%s'):format(entry.key, tostring(o.id)) end
    return 'act:' .. entry.key
end

local function xyz(v)
    if v == nil then return nil end
    local x = tonumber(v.x or v[1])
    local y = tonumber(v.y or v[2])
    local z = tonumber(v.z or v[3])
    if not (x and y and z) then return nil end
    return x, y, z
end

--- Where a prompt riding on an entity is now: its bone, else its offset, else its origin. nil if the entity is gone or not streamed in.
local function ridePoint(at)
    local ent = entityOf(at)
    if not ent or not DoesEntityExist(ent) then return nil end
    if at.bone then
        local idx = GetEntityBoneIndexByName(ent, tostring(at.bone))
        if idx ~= -1 then
            local p = GetWorldPositionOfEntityBone(ent, idx)
            return p.x, p.y, p.z
        end
    end
    local ox, oy, oz = xyz(at.offset)
    local p = GetOffsetFromEntityInWorldCoords(ent, ox or 0.0, oy or 0.0, oz or 0.0)
    return p.x, p.y, p.z
end

--- Ticks (of 500ms) an entity may be missing before its action is removed.
local RIDE_GONE_TICKS = 6
local ridingRunning = false

local function startRiding()
    -- One thread, however quickly the set empties and refills.
    if ridingRunning then return end
    ridingRunning = true
    CreateThread(function()
        -- The engine calls `follow` only once the registered position is in range, so that position is kept fresh here.
        -- An action by handle is removed a few seconds after its entity is gone (a handle never returns as the same
        -- entity); by netId it is suspended while streamed out and put back when it streams in.
        while next(riding) do
            local gone = {}
            for key, r in pairs(riding) do
                local x, y, z = ridePoint(r.at)   -- (all three, or nil)
                if r.at.netId ~= nil then
                    if x then
                        if r.live then
                            Interactions.updatePosition(r.pid, x, y --[[@as number]], z --[[@as number]])
                        else
                            -- Back in: re-registered from what it was mounted with.
                            local m = mounted[key]
                            if m and m.reg then
                                m.reg.x, m.reg.y, m.reg.z = x, y, z
                                if Interactions.register(m.reg) ~= false then r.live = true end
                            end
                        end
                    elseif r.live then
                        Interactions.remove(r.pid)
                        r.live = false
                    end
                elseif x then
                    r.missing = 0
                    Interactions.updatePosition(r.pid, x, y --[[@as number]], z --[[@as number]])
                else
                    r.missing = (r.missing or 0) + 1
                    if r.missing >= RIDE_GONE_TICKS then gone[#gone + 1] = r end
                end
            end
            for _, r in ipairs(gone) do
                -- Said once per action, or an action with `onGone` is told after it is removed.
                local onGone = r.def and r.def.onGone
                if onGone == nil then
                    print(('[whip_core:actions] %s\'s action "%s" was removed: its entity is gone (a networked entity that streamed out counts). Add it again when the entity is back, or ride it by at = { netId = ... }, which follows it as it comes and goes.')
                        :format(tostring(r.owner), tostring(r.id)))
                end
                Actions.remove(r.owner, r.id)
                if onGone ~= nil then
                    local key, owner, id = r.key, r.owner, r.id
                    CreateThread(function()
                        local ok, err = pcall(onGone, { id = id, owner = owner })
                        if not ok then report(key, 'onGone', err) end
                    end)
                end
            end
            Wait(500)
        end
        ridingRunning = false
    end)
end

-- Menus: an option with options of its own (world prompts). Choosing it puts its options on the same
-- prompt with a Back first; pressing one, or looking away, folds the prompt back to the top. An option
-- down there must also pass the ones it is under and takes what it leaves out from them, then the action.
--
-- A FILLED menu: `options` is a function(ctx) returning the list, called each time the menu opens, in a
-- thread of its own (it may wait: a server callback for what this player has). "One moment…" shows meanwhile,
-- "Nothing here" for an empty list. An option with `stay = true` keeps the prompt on its menu after its
-- onSelect, and a filled menu is filled again then (a count it shows is current).

local menuAt = {}     -- [prompt id] = the option whose menu the prompt shows (nil: the top)
local filledAt = {}   -- [prompt id] = { [a filled menu's option] = its options as last filled } (per prompt)
local fillGen = {}    -- [prompt id] = the last fill asked, so an older one that answers late is dropped

local readOptions     -- (defined with tidy below; a filled menu's list is read with it)

--- Does this option's menu fill when it opens (a function)?
local function fills(o) return InteractSpec.callable(o.options) end

local function isMenu(o) return fills(o) or (type(o.options) == 'table' and #o.options > 0) end

--- The prompt back at the top of its menus, the filled ones forgotten.
local function atTop(pid)
    menuAt[pid] = nil
    filledAt[pid] = nil
    fillGen[pid] = (fillGen[pid] or 0) + 1
end

--- Has an option a picture to show: its own, a menu's it is under, or the action's (as resolveText reads them)?
local function givesImage(o, def)
    local up = o
    while up do
        if up.image ~= nil then return true end
        up = up._up
    end
    return def.image ~= nil
end

--- A row of a filled menu that does nothing when pressed ("One moment…", "Nothing here").
local function quietRow(o, id, label, icon)
    return { id = id, label = label, icon = icon, _up = o, _quiet = true }
end

--- A menu option's own options: a filled one's as last filled for this prompt ("One moment…" until then), else
--- copies made once, with ids, each knowing the option it is under (`_up`).
local function optionsUnder(o, pid)
    if fills(o) then
        return (filledAt[pid] and filledAt[pid][o]) or { quietRow(o, '<wait>', 'One moment…', 'timer') }
    end
    if o._kids then return o._kids end
    local kids = {}
    for i, c in ipairs(o.options) do
        if type(c) == 'table' then
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            copy.id = copy.id ~= nil and tostring(copy.id) or ('opt' .. i)
            copy._up = o
            kids[#kids + 1] = copy
        end
    end
    o._kids = kids
    return kids
end

--- ctx.player for a prompt on a person: { serverId, playerIdx, isDead, activeJob }, or nil when the entity is not a real player.
local function playerOfPed(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) or not IsPedAPlayer(ped) then return nil end
    local idx = NetworkGetPlayerIndexFromPed(ped)
    if not idx or idx < 0 then return nil end
    local sid = GetPlayerServerId(idx)
    local st = Player(sid).state
    return { serverId = sid, playerIdx = idx, isDead = st[PLAYER_DEAD_KEY], activeJob = st[PLAYER_JOB_KEY] }
end

--- A filled menu's answer as kept: read like any option list (a misspelt field warned about, once), a bad
--- `require` or a second option with one id left out, each knowing the menu it is under.
---@return table kids
local function readFilled(entry, o, list)
    local where = ('options of "%s"'):format(tostring(o.id))
    local warn = {}
    if type(list) ~= 'table' or InteractSpec.callable(list) then
        if list ~= nil then warn[#warn + 1] = where .. ' answered ' .. type(list) .. ', not a list of options' end
        list = {}
    end
    local read = readOptions(list, where, warn, true)
    local kids, seen = {}, {}
    for i, c in ipairs(read) do
        local oid = c.id ~= nil and tostring(c.id) or ('opt' .. i)
        local rWhy = checkRequire(c.require, entry.kind)
        if seen[oid] then
            warn[#warn + 1] = ('%s: two options have the id "%s". The second was left out'):format(where, oid)
        elseif rWhy then
            warn[#warn + 1] = ('%s, option "%s": %s. It was left out'):format(where, oid, rWhy)
        else
            seen[oid] = true
            c.id = oid
            c._up = o
            kids[#kids + 1] = c
        end
    end
    if #warn > 0 then InteractSpec.say('actions', entry.owner, ('action "%s"'):format(tostring(entry.id)), warn) end
    if #kids == 0 then kids[1] = quietRow(o, '<empty>', 'Nothing here', 'info') end
    return kids
end

--- Fill menu option `o` on prompt `pid`: its function is called in a thread of its own with the ctx onSelect gets
--- (bar the verbs), and the prompt shows the answer if it is still on that menu and no newer fill was asked.
--- `keep`: the list it shows now stays up until the answer (filled again after a `stay` press), else "One moment…".
local function fill(entry, pid, o, extra, show, keep)
    fillGen[pid] = (fillGen[pid] or 0) + 1
    local gen = fillGen[pid]
    if not keep and filledAt[pid] then filledAt[pid][o] = nil end
    CreateThread(function()
        local ctx = { id = entry.id, owner = entry.owner, option = o.id, under = o._up and o._up.id or nil }
        for k, v in pairs(extra or {}) do ctx[k] = v end
        local ok, list = pcall(o.options, ctx)
        if fillGen[pid] ~= gen or menuAt[pid] ~= o then return end
        local kids
        if ok then
            kids = readFilled(entry, o, list)
        else
            report(entry.key, ('options of "%s"'):format(tostring(o.id)), list)
            kids = { quietRow(o, '<failed>', 'Not available', 'warning') }
        end
        filledAt[pid] = filledAt[pid] or setmetatable({}, { __mode = 'k' })
        filledAt[pid][o] = kids
        show()
    end)
end

--- A world prompt's options at the menu it is on, for prompt `pid`. `entityNow` answers the entity it is on
--- (nil at a spot), `whereNow` where it is. `about`: what a model action adds to ctx (prop model, face, id).
--- `gate`: asked before every option of every level (an aimBox prompt: only while the look meets something).
local function promptOptions(entry, pid, entityNow, whereNow, about, gate)
    local def = entry.def
    local down = menuAt[pid]
    local level = down and optionsUnder(down, pid) or entry.opts
    local options = {}
    local function open() return gate == nil or gate() == true end

    -- The prompt again, at the menu it is on now
    local function show()
        Interactions.setOptions(pid, promptOptions(entry, pid, entityNow, whereNow, about, gate))
    end

    -- What onSelect and a filled menu's function are told: where the prompt is now (one riding on something has
    -- moved), what it is on, and a model action's prop details.
    local function extraNow()
        local cx, cy, cz = whereNow()
        local extra = { entity = entityNow(), coords = vector3(cx or 0.0, cy or 0.0, cz or 0.0) }
        extra.player = playerOfPed(extra.entity)
        if about then
            for k, v in pairs(about) do extra[k] = v end
        end
        return extra
    end

    if down then
        options[1] = {
            id = '<back>', label = 'Back', icon = 'back',
            condition = function() return open() end,
            callback  = function()
                -- Back up to a filled menu: the list it showed, not asked again.
                menuAt[pid] = down._up
                fillGen[pid] = (fillGen[pid] or 0) + 1
                show()
            end,
        }
    end

    for _, o in ipairs(level) do
        local c = condCtx(entry, o)
        -- Refresh the shared ctx right before each check: what is being typed (a value), the entity (by
        -- netId it can change handle), and a model action's prop details.
        local function current()
            c.typed = Interactions.inputDisplay(pid) or false
            c.entity = entityNow()
            c.player = playerOfPed(c.entity)
            if about then
                for k, v in pairs(about) do c[k] = v end
            end
            return c
        end
        local menu = isMenu(o)
        options[#options + 1] = {
            id        = o.id,
            -- Hold to use: the option's own, else the action's. A menu entry is always a press.
            holdMs    = not menu and not o._quiet and (o.holdMs or def.holdMs) or nil,
            label     = function()
                local text = resolveText(entry, o, 'label', current())
                if menu then return (text or o.id) .. '  ›' end
                return text
            end,
            icon      = function() return resolveText(entry, o, 'icon', current()) end,
            -- A picture of its own, a menu's above it (a car's page shows the car), or the action's.
            image     = givesImage(o, def) and function() return resolveText(entry, o, 'image', current()) end or nil,
            condition = function() return open() and (check(entry, o, current())) end,
            callback  = function()
                if menu then
                    menuAt[pid] = o
                    if fills(o) then fill(entry, pid, o, extraNow(), show) end
                    return show()
                end
                if o._quiet then return end
                -- `stay`: still on this menu after it (filled again once onSelect is done); else back to the top.
                local stay = o.stay == true and menuAt[pid] ~= nil
                local extra = extraNow()
                fire(entry, o, pid, extra, nil, nil, stay and function()
                    local m = menuAt[pid]
                    if m == nil or m ~= o._up then return end
                    if fills(m) then fill(entry, pid, m, extra, show, true) else show() end
                end or nil)
                if menuAt[pid] and not stay then
                    atTop(pid)
                    show()
                end
            end,
        }
    end
    return options
end

--- A world prompt's onBlur: back to the top of its menu (deferred, not inside the engine's pass), then the action's own.
local function foldOnBlur(entry, pid, entityNow, whereNow, about, gate)
    local own = entry.def.onBlur
    return function()
        if menuAt[pid] then
            atTop(pid)
            CreateThread(function()
                Interactions.setOptions(pid, promptOptions(entry, pid, entityNow, whereNow, about, gate))
            end)
        end
        if own then
            local ok, err = pcall(own)
            if not ok then report(entry.key, 'onBlur', err) end
        end
    end
end

--- How an action's world prompt looks and behaves, apart from where it is and what it offers.
local function promptLook(entry)
    local def = entry.def
    return {
        label        = type(def.label) == 'string' and def.label or '',
        icon         = type(def.icon) == 'string' and def.icon or 'E',
        visibleRange = def.seeFrom,
        activeRange  = def.reach,
        sizeRange    = def.sizeRange,
        scale        = def.scale,
        focusMode    = def.focusMode,
        onBlur       = def.onBlur,
        style        = def.style,
        group        = 'actions',
        allowDowned  = anyOption(entry, 'alive', false),
        allowSeated  = anyOption(entry, 'vehicle', 'in'),
    }
end

local function mountPrompt(entry)
    local def, at = entry.def, entry.def.at
    local pid = 'act:' .. entry.key

    local x, y, z, follow
    local rides = at.entity ~= nil or at.netId ~= nil
    -- A riding prompt with a heading is a sign at that yaw FROM THE ENTITY'S OWN FACING, turning with it (a speaker's
    -- back on a car going round a corner); one without faces the player.
    local turn = rides and tonumber(at.heading) or nil
    if rides then
        x, y, z = ridePoint(at)
        if turn then
            follow = function()
                local px, py, pz = ridePoint(at)
                if not px then return nil end
                return px, py, pz, (GetEntityHeading(entityOf(at)) + turn) % 360.0
            end
        else
            follow = function() return ridePoint(at) end
        end
    else
        x, y, z = xyz(at.coords)
        follow = at.follow
    end
    -- (A netId not streamed in yet is mounted suspended and goes on when the entity comes.)
    if not x and at.netId == nil then return false, 'no position' end

    local function entityNow() return entityOf(at) end
    local function whereNow()
        if rides then
            local rx, ry, rz = ridePoint(at)
            if rx then return rx, ry, rz end
        end
        return x, y, z
    end
    atTop(pid)
    local options = promptOptions(entry, pid, entityNow, whereNow)

    -- Kept, so a netId prompt can be put back on its entity as mounted.
    local reg = promptLook(entry)
    reg.onBlur = foldOnBlur(entry, pid, entityNow, whereNow)
    reg.id = pid
    reg.x, reg.y, reg.z = x, y, z
    -- A vector4's w is the heading, or a table's `w`, `heading` or [4]. (A riding prompt's: from its entity's facing.)
    local ent = turn and entityOf(at) or nil
    reg.heading = (turn and ent and DoesEntityExist(ent) and (GetEntityHeading(ent) + turn) % 360.0)
        or tonumber(at.heading) or (function()
        local c = at.coords
        if type(c) == 'vector4' then return c.w end
        if type(c) == 'table' then return tonumber(c.w or c.heading or c[4]) end
        return nil
    end)()
    reg.follow = follow
    reg.options = options
    local live = false
    if x then
        local ok, why = Interactions.register(reg)
        if ok == false then return false, why end
        live = true
    end

    mounted[entry.key] = { kind = 'prompt', ids = { pid }, reg = reg }
    if rides then
        riding[entry.key] = { key = entry.key, pid = pid, at = at, owner = entry.owner, id = entry.id,
                              def = def, live = live }
        startRiding()
    end
    return true
end

--- `at = { aimBox = 'vehicle' }` (or 'object', 'ped', 'world', or a list): a prompt where the player looks,
--- on the box of what they aim at (client/aim_box.lua). `follow` places it every frame while it shows; the
--- engine only follows a prompt it already shows, so a driver keeps its registered spot on whatever is aimed at.
local aimBoxes = {}   -- [key] = { pid, kinds, flags, maxT, out, on, about }
local aimDriverRunning = false

local function aimBoxLook(a)
    a.on = AimBox.aim(a.kinds, a.flags, a.maxT, a.on and a.out.entity or nil, a.out)
    -- With 'world' among the kinds: is it the map itself (ctx.world), and its facing (ctx.normal)
    local about = a.about
    if about then
        local o = a.out
        about.world = a.on and o.entity == nil
        about.normal = about.world and o.nx and vector3(o.nx, o.ny, o.nz) or false
    end
    return a.on
end

local function startAimDriver()
    if aimDriverRunning then return end
    aimDriverRunning = true
    CreateThread(function()
        while next(aimBoxes) do
            for _, a in pairs(aimBoxes) do
                if aimBoxLook(a) then
                    local o = a.out
                    Interactions.updatePosition(a.pid, o.px, o.py, o.pz)
                end
            end
            Wait(100)
        end
        aimDriverRunning = false
    end)
end

local function mountAimBox(entry)
    local def, at = entry.def, entry.def.at
    local kinds, flags = AimBox.kinds(at.aimBox)
    if not kinds then return false, "at.aimBox is 'vehicle', 'object', 'ped' or 'world' (or a list of them)" end
    local pid = 'act:' .. entry.key
    -- Looked along from the camera; the reach is measured from the player.
    local reach = tonumber(def.reach) or Config.InteractActiveRange or 2.0
    local a = { pid = pid, kinds = kinds, flags = flags, maxT = reach + 6.0, out = {}, on = false,
                about = kinds.world and { world = false, normal = false } or nil }

    local function entityNow() return a.on and a.out.entity or nil end
    local function whereNow()
        if a.on then return a.out.x, a.out.y, a.out.z end
        return nil
    end
    -- Offered only while the look meets something (the gate); looking away folds a menu back.
    local function gate() return a.on end
    atTop(pid)
    local options = promptOptions(entry, pid, entityNow, whereNow, a.about, gate)

    local reg = promptLook(entry)
    reg.id = pid
    reg.onBlur = foldOnBlur(entry, pid, entityNow, whereNow, a.about, gate)
    local me = GetEntityCoords(PlayerPedId())
    reg.x, reg.y, reg.z = me.x, me.y, me.z
    -- A side's sign sits on the box, wrapped round its corners, with its circle on the point itself.
    reg.follow = function()
        if not aimBoxLook(a) then return nil end
        local o = a.out
        if o.heading == nil then return o.px, o.py, o.pz end
        return o.px, o.py, o.pz, o.heading, 0.0, o.wrap, false
    end
    reg.options = options
    local ok, why = Interactions.register(reg)
    if ok == false then return false, why end

    mounted[entry.key] = { kind = 'aimbox', ids = { pid }, reg = reg }
    aimBoxes[entry.key] = a
    startAimDriver()
    return true
end

--- `at = { model = 'prop_vend_soda_01' }` (or a list): the action on every prop of that model near the
--- player, found by client/prop_prompts.lua. `offset` is in the prop's own space (x across, y out of its
--- face, z up); `heading` makes the badge a sign at that yaw from the prop's facing (without one it faces
--- the player); `faces = 2` for a prop used from both sides; `perModel` places one model differently.
--- `onFound(ctx)` / `onLost(ctx)` are told as each prop comes within 50 m and goes (60 m, or gone), seated
--- or on foot, with ctx = { id, owner, entity, model, prop, coords }. Every option's ctx also has `model`,
--- `face` and `prop`.
local function mountProps(entry)
    local def, at = entry.def, entry.def.at
    local propKind = 'act:' .. entry.key
    local ox, oy, oz = xyz(at.offset)
    -- Each model's own placing over the one `offset` for all; what an entry leaves out is the action's own.
    local offsets = {}
    if type(at.perModel) == 'table' then
        for model, p in pairs(at.perModel) do
            if type(p) == 'table' then
                local px, py, pz = xyz(p.offset)
                offsets[tostring(model)] = { side = px or ox or 0.0, out = py or oy or 0.0, up = pz or oz or 0.0,
                                             yaw = tonumber(p.heading) or tonumber(at.heading) }
            end
        end
    end
    local found = {}   -- [prop id] = the ctx onFound was given, while the prop is tracked

    --- onFound / onLost, in their own thread (they may wait)
    local function tell(field, ctx)
        local fn = def[field]
        if fn == nil then return end
        CreateThread(function()
            local ok, err = pcall(fn, ctx)
            if not ok then report(entry.key, field, err) end
        end)
    end

    PropPrompts.define({
        kind      = propKind,
        faces     = (tonumber(at.faces) == 2) and 2 or 1,
        models    = type(at.model) == 'table' and at.model or { at.model },
        offset    = { side = ox or 0.0, out = oy or 0.0, up = oz or 0.0, yaw = tonumber(at.heading) },
        offsets   = offsets,
        -- A model with no heading of its own turns to face the player.
        billboard = true,
        group     = 'actions',
        -- Asked as each prop is found; the look is read then, so a style set since is worn by a new prop.
        prompt    = function(rec)
            local about = { model = rec.model, face = rec.face, prop = rec.baseId }
            local function entityNow() return rec.entity end
            local function whereNow() return rec.x, rec.y, rec.z end
            atTop(rec.id)
            local reg = promptLook(entry)
            reg.options = promptOptions(entry, rec.id, entityNow, whereNow, about)
            reg.onBlur = foldOnBlur(entry, rec.id, entityNow, whereNow, about)
            return reg
        end,
        -- A prop's prompt gone: its menus forgotten.
        onRemove  = function(rec) atTop(rec.id) end,
    })
    -- onFound / onLost follow a watch of their own (PropPrompts.watch): every prop of the models within
    -- 50 m, seated or not, whereas the prompts' sweep finds only the nearest of each model.
    local watched = def.onFound ~= nil or def.onLost ~= nil
    if watched then
        PropPrompts.watch(propKind, {
            models = type(at.model) == 'table' and at.model or { at.model },
            found = function(p)
                local ctx = { id = entry.id, owner = entry.owner, entity = p.entity, model = p.model, prop = p.prop,
                              coords = p.coords }
                found[p.prop] = ctx
                tell('onFound', ctx)
            end,
            lost = function(p)
                local ctx = found[p.prop]
                if not ctx then return end
                found[p.prop] = nil
                tell('onLost', ctx)
            end,
        })
    end
    -- Prompts are per prop and come and go: no engine ids to list.
    mounted[entry.key] = { kind = 'props', ids = {}, propKind = propKind, watched = watched }
    return true
end

local function mountPart(entry)
    local partKey = entry.def.at.vehiclePart
    local ids = {}
    for _, o in ipairs(entry.opts) do
        local oid = engineId(entry, o)
        local c = condCtx(entry, o)
        local first = o.first
        if first == nil then first = entry.def.first end
        local ok, why = VehiclePartOptions.add(entry.owner, partKey, {
            id    = oid,
            first = first == true or nil,
            label = function(veh) c.entity = veh return resolveText(entry, o, 'label', c) end,
            icon  = function(veh) c.entity = veh return resolveText(entry, o, 'icon', c) end,
            image = (o.image ~= nil or entry.def.image ~= nil)
                and function(veh) c.entity = veh return resolveText(entry, o, 'image', c) end or nil,
            can   = function(veh) c.entity = veh return (check(entry, o, c)) end,
            act   = function(veh)
                -- The prompt this was chosen on, read now since onSelect runs later; a press presses its point.
                local pid = Interactions.getFocusedId()
                local reg = pid and Interactions.getAll()[pid]
                local here = reg and reg.x and vector3(reg.x, reg.y, reg.z) or nil
                fire(entry, o, pid, { entity = veh, coords = GetEntityCoords(veh) }, here)
            end,
        })
        if not ok then
            for _, done in ipairs(ids) do VehiclePartOptions.remove(entry.owner, partKey, done) end
            return false, why
        end
        ids[#ids + 1] = oid
    end
    mounted[entry.key] = { kind = 'part', partKey = partKey, ids = ids, owner = entry.owner }
    return true
end

local function mountRadial(entry)
    local ids = {}
    for _, o in ipairs(entry.opts) do
        local rid = engineId(entry, o)
        local c = condCtx(entry, o)
        local handle = WhipRadialAddOption({
            id        = rid,
            group     = 'actions',
            label     = function() return resolveText(entry, o, 'label', c) end,
            -- Only when the option or the action gives one: no pointless cross-resource calls.
            icon       = (o.icon ~= nil or entry.def.icon ~= nil)
                and function() return resolveText(entry, o, 'icon', c) end or nil,
            description = (o.description ~= nil or entry.def.description ~= nil)
                and function() return resolveText(entry, o, 'description', c) end or nil,
            condition = function() return (check(entry, o, c)) end,
            callback  = function() fire(entry, o, nil, nil, nil, true) end,
            allowDowned = requireField(entry.def, o, 'alive') == false,
        })
        if not handle then
            for _, done in ipairs(ids) do WhipRadialRemove(done) end
            return false, 'the wheel refused it (a label is required)'
        end
        ids[#ids + 1] = rid
    end
    mounted[entry.key] = { kind = 'radial', ids = ids }
    return true
end

local function unmount(key)
    local m = mounted[key]
    if not m then return end
    if m.kind == 'prompt' then
        for _, id in ipairs(m.ids) do Interactions.remove(id) end
        riding[key] = nil
    elseif m.kind == 'aimbox' then
        for _, id in ipairs(m.ids) do Interactions.remove(id) end
        aimBoxes[key] = nil
    elseif m.kind == 'part' then
        for _, id in ipairs(m.ids) do VehiclePartOptions.remove(m.owner, m.partKey, id) end
    elseif m.kind == 'radial' then
        for _, id in ipairs(m.ids) do WhipRadialRemove(id) end
    elseif m.kind == 'props' then
        -- Every prop's prompt goes with its kind, and its watch (onLost is told for each found prop)
        PropPrompts.undefine(m.propKind)
        if m.watched then PropPrompts.unwatch(m.propKind) end
    end
    mounted[key] = nil
    forgetReports(key)
end

--- Which engine an `at` belongs to, or nil and why.
---@return string|nil kind
---@return string|nil why
local function kindOf(at)
    if type(at) ~= 'table' then
        return nil, 'at says where the action is: { coords }, { entity }, { netId }, { model }, { vehiclePart }, { aimBox }, or { radial = true }'
    end
    -- One place only: two is refused rather than guessed.
    local named = {}
    for _, k in ipairs({ 'coords', 'entity', 'netId', 'vehiclePart', 'aimBox', 'model' }) do
        if at[k] ~= nil then named[#named + 1] = k end
    end
    if at.radial then named[#named + 1] = 'radial' end
    if #named > 1 then
        return nil, ('at names %d places (%s) — an action is in one: pick coords, entity, netId, model, vehiclePart, aimBox or radial')
            :format(#named, table.concat(named, ', '))
    end
    if at.aimBox ~= nil then
        if not AimBox.kinds(at.aimBox) then return nil, "at.aimBox is 'vehicle', 'object', 'ped' or 'world' (or a list of them)" end
        return 'aimbox'
    end
    if at.coords ~= nil then
        if not xyz(at.coords) then return nil, 'at.coords must be a vector3 (or { x, y, z })' end
        return 'prompt'
    end
    if at.entity ~= nil then
        if not DoesEntityExist(at.entity) then return nil, 'at.entity does not exist' end
        return 'prompt'
    end
    -- A network id need not be streamed in yet: the prompt waits for it.
    if at.netId ~= nil then
        local n = tonumber(at.netId)
        if not n or n <= 0 or n ~= math.floor(n) then
            return nil, 'at.netId is a network id (NetworkGetNetworkIdFromEntity, on either side)'
        end
        return 'prompt'
    end
    -- Every prop of a model, or of any of a list.
    if at.model ~= nil then
        local models = type(at.model) == 'table' and at.model or { at.model }
        local bad = #models == 0
        for _, m in ipairs(models) do
            if type(m) ~= 'string' or m == '' then bad = true end
        end
        if bad then return nil, "at.model is a prop's model name ('prop_vend_soda_01'), or a list of them" end
        return 'props'
    end
    if at.vehiclePart ~= nil then return 'part' end
    if at.radial then return 'radial' end
    -- A place spelt wrong (`coord`, `pos`) is the likeliest reason none was found: say which.
    for k in pairs(at) do
        local meant = InteractSpec.ACTION_AT[k] == nil
            and InteractSpec.didYouMean(k, InteractSpec.ACTION_AT, InteractSpec.HINT.ACTION_AT)
        if meant then
            return nil, ('at says where the action is: { coords }, { entity }, { netId }, { model }, { vehiclePart }, { aimBox }, or { radial = true } — at.%s is not one: use %s')
                :format(tostring(k), meant)
        end
    end
    return nil, 'at says where the action is: { coords }, { entity }, { netId }, { model }, { vehiclePart }, { aimBox }, or { radial = true }'
end

--- What each place is called in a warning.
local PLACE_NAME = { prompt = 'a world prompt', part = 'a car part', radial = 'the F1 wheel',
                     props = 'the props of a model', aimbox = 'a prompt where the player aims' }

--- The places whose options may be menus: the world prompts.
local MENU_KINDS = { prompt = true, props = true, aimbox = true }

--- A menu: a list of options, or a function filling it when it opens.
local function isMenuDef(o)
    if type(o) ~= 'table' then return false end
    if InteractSpec.callable(o.options) then return true end
    return type(o.options) == 'table' and #o.options > 0
end

--- An option list read field by field (InteractSpec), every menu down; a misspelt field is warned about at its
--- path. `menus`: false on a place that has none, where a menu is warned about and dropped. A filled menu's
--- function is kept as it is: what it answers is read the same way when it is called (readFilled).
readOptions = function(opts, path, warn, menus)
    local out = {}
    for i, o in ipairs(opts) do
        local at = ('%s[%d]'):format(path, i)
        if type(o) == 'table' and not InteractSpec.callable(o) then
            local r = InteractSpec.read(o, InteractSpec.ACTION_OPTION, at, warn, InteractSpec.HINT.ACTION_OPTION)
            if r.options ~= nil then
                if not menus then
                    warn[#warn + 1] = ('%s.options (a menu) is read only on a world prompt. It was ignored'):format(at)
                    r.options = nil
                elseif InteractSpec.callable(r.options) then
                    -- A filled menu: called each time it opens.
                elseif type(r.options) ~= 'table' or #r.options == 0 then
                    warn[#warn + 1] = ('%s.options is a list of options, or a function returning one. It was ignored'):format(at)
                    r.options = nil
                else
                    r.options = readOptions(r.options, at .. '.options', warn, menus)
                end
            end
            out[#out + 1] = r
        else
            warn[#warn + 1] = ('%s is a table: { id = ..., label = ..., onSelect = ... }. It was left out'):format(at)
        end
    end
    return out
end

--- Warn about an option that does nothing when pressed (a menu's own entry needs no onSelect).
local function warnLeaves(opts, inherited, path, warn)
    for i, o in ipairs(opts) do
        local fn = o.onSelect ~= nil and o.onSelect or inherited
        if isMenuDef(o) then
            -- (A filled menu's options are not known until it opens.)
            if not InteractSpec.callable(o.options) then
                warnLeaves(o.options, fn, ('%s[%d].options'):format(path, i), warn)
            end
        elseif fn == nil then
            warn[#warn + 1] = ('%s[%d] has no onSelect (on it, on an option above it, or on the action): pressing it does nothing')
                :format(path, i)
        end
    end
end

--- Has anything in the action something to do? Its own onSelect, or any option's at any depth (a filled menu
--- is taken to have: what it fills with is not known until it opens).
local function anySelect(opts)
    for _, o in ipairs(type(opts) == 'table' and not InteractSpec.callable(opts) and opts or {}) do
        if type(o) == 'table' and (o.onSelect ~= nil or InteractSpec.callable(o.options)
            or (isMenuDef(o) and anySelect(o.options))) then return true end
    end
    return false
end

--- The action as kept: only the fields AddAction knows, each checked against shared/interact_spec.lua.
--- Problems go into `warn` (a misspelt field is left out, an out-of-range number is held to range);
--- `at` and `require` are still refused when wrong. Menus are read the same way, every level down.
---@param def table  Actions.add's copy
---@param warn table  the list to add to
---@return table
local function tidy(def, warn)
    -- `distance` (as other target resources spell it) is read as `reach`, and said once.
    if def.distance ~= nil then
        if def.reach == nil then
            def.reach = def.distance
            warn[#warn + 1] = "distance: read as 'reach' (whip's word for it)"
        end
        def.distance = nil
    end
    local out = InteractSpec.read(def, InteractSpec.ACTION, '', warn, InteractSpec.HINT.ACTION)
    local at = out.at
    if type(at) ~= 'table' then return out end

    InteractSpec.unknown(at, InteractSpec.ACTION_AT, 'at', warn, InteractSpec.HINT.ACTION_AT)
    -- A key that goes with another place does nothing here (`offset` at coords).
    for k in pairs(at) do
        local spec = InteractSpec.ACTION_AT[k]
        if spec and spec.with then
            local found = false
            for _, p in ipairs(spec.with) do
                if at[p] ~= nil then found = true break end
            end
            if not found then
                warn[#warn + 1] = ('at.%s is read only with at.%s. It was ignored')
                    :format(tostring(k), table.concat(spec.with, ' or at.'))
            end
        end
    end

    -- Where it is decides what is read: `scale` on the F1 wheel does nothing.
    local kind = kindOf(at)
    if kind then
        -- Props of a model and aimBox prompts are world prompts too.
        local reads = (kind == 'props' or kind == 'aimbox') and 'prompt' or kind
        for k, spec in pairs(InteractSpec.ACTION) do
            if spec.on and out[k] ~= nil and not spec.on[reads] then
                warn[#warn + 1] = ('%s is not read on %s. It was ignored'):format(k, PLACE_NAME[kind])
            end
        end
    end

    if out.options ~= nil then
        if next(out.options) ~= nil and #out.options == 0 then
            warn[#warn + 1] = 'options is a list: { { id = ..., label = ..., onSelect = ... }, ... }. It was ignored'
        end
        out.options = readOptions(out.options, 'options', warn, kind == nil or MENU_KINDS[kind] == true)
        warnLeaves(out.options, out.onSelect, 'options', warn)
    end
    return out
end

--- The option list: the action's own, or one implicit option that inherits everything.
local function optionsOf(def)
    local out = {}
    if type(def.options) == 'table' and #def.options > 0 then
        for i, o in ipairs(def.options) do
            if type(o) == 'table' then
                local copy = {}
                for k, v in pairs(o) do copy[k] = v end
                copy.id = copy.id ~= nil and tostring(copy.id) or ('opt' .. i)
                out[#out + 1] = copy
            end
        end
    end
    if #out == 0 then out[1] = { id = 'default' } end
    return out
end

local function mount(key, def, owner)
    local kind = kindOf(def.at)
    local entry = { key = key, id = def.id, owner = owner, def = def, opts = optionsOf(def), kind = kind }
    local ok, why
    if kind == 'prompt' then ok, why = mountPrompt(entry)
    elseif kind == 'aimbox' then ok, why = mountAimBox(entry)
    elseif kind == 'part' then ok, why = mountPart(entry)
    elseif kind == 'radial' then ok, why = mountRadial(entry)
    elseif kind == 'props' then ok, why = mountProps(entry) end
    if not ok then
        mountError[key] = tostring(why or 'the engine refused it')
        print(('[whip_core:actions] "%s" could not be put in the world: %s'):format(key, mountError[key]))
    else
        mountError[key] = nil
    end
end

-- The registry: yours by id, adding again replaces, gone when you stop.

local reg = Registry.new('action', {
    label  = 'action',
    scoped = true,   -- ids are per resource: two resources may both have a 'bench'
    validate = function(id, def)
        local kind, why = kindOf(def.at)
        if not kind then return false, ('action "%s": %s'):format(tostring(id), why) end
        -- Something to do: its own onSelect, or an option's at any depth.
        if def.onSelect == nil and not anySelect(def.options) then
            return false, ('action "%s": onSelect is required'):format(tostring(id))
        end
        if kind == 'radial' and def.label == nil then
            return false, ('action "%s": the wheel needs a label'):format(tostring(id))
        end
        -- One id per option in each menu (a repeat would silently replace the first), and every option's
        -- require, every level down.
        local function checkLevel(opts, under)
            local seen = {}
            for i, o in ipairs(opts) do
                if type(o) == 'table' then
                    local oid = o.id ~= nil and tostring(o.id) or ('opt' .. i)
                    if seen[oid] then
                        return ('action "%s": two options%s have the id "%s" — give each its own'):format(tostring(id), under, oid)
                    end
                    seen[oid] = true
                    local rWhy = checkRequire(o.require, kind)
                    if rWhy then return ('action "%s", option "%s": %s'):format(tostring(id), oid, rWhy) end
                    -- (A filled menu's options are checked as it fills: readFilled.)
                    if MENU_KINDS[kind] and isMenuDef(o) and not InteractSpec.callable(o.options) then
                        local w = checkLevel(o.options, (' under "%s"'):format(oid))
                        if w then return w end
                    end
                end
            end
            return nil
        end
        local lWhy = checkLevel(optionsOf(def), '')
        if lWhy then return false, lWhy end
        local rWhy = checkRequire(def.require, kind)
        if rWhy then return false, ('action "%s": %s'):format(tostring(id), rWhy) end
        return true
    end,
    onAdd = function(key, def, owner, old)
        if old ~= nil then unmount(key) end
        mount(key, def, owner)
    end,
    onRemove = function(key)
        unmount(key)
    end,
})
Actions.registry = reg

--- The id an action gets when it names none: derived from what and where it is, so a re-run from onReady
--- replaces itself. Function labels cannot be told apart: such an action should name its own id.
local function autoId(def)
    local at = type(def.at) == 'table' and def.at or {}
    local x, y, z = xyz(at.coords)
    -- Never index a function reference: it throws.
    local ox, oy, oz
    if not (type(at.offset) == 'table' and rawget(at.offset, '__cfx_functionReference') ~= nil) then
        ox, oy, oz = xyz(at.offset)
    end
    local opts = {}
    if type(def.options) == 'table' then
        for i, o in ipairs(def.options) do
            if type(o) == 'table' then
                opts[#opts + 1] = tostring(o.id or (type(o.label) == 'string' and o.label) or i)
            end
        end
    end
    local label = type(def.label) == 'string' and def.label or (def.label ~= nil and '<function>' or '')
    -- An entity handle is a number (a function reference is new every registration); a network id shares the slot.
    local entity = type(at.entity) == 'number' and at.entity
        or (at.netId ~= nil and ('net' .. tostring(at.netId))) or ''
    -- A list of models by its names (a table's address changes every registration).
    local model = at.model
    if type(model) == 'table' then
        local names = {}
        for i, m in ipairs(model) do names[i] = tostring(m) end
        model = table.concat(names, '+')
    end
    local seed = ('%s|%s|%s|%s|%s|%s|%s|%s|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f|%s'):format(tostring(def.group or ''),
        label, tostring(at.vehiclePart or ''), tostring(at.aim or ''),
        tostring(model or ''), tostring(at.bone or ''), tostring(at.radial or ''), tostring(entity),
        x or 0, y or 0, z or 0, ox or 0, oy or 0, oz or 0, table.concat(opts, ','))
    return ('auto:%08x'):format(GetHashKey(seed) & 0xFFFFFFFF)
end

--- Add (or replace) an action for `owner`. Answers the id, or false and why, and a third answer: the
--- warnings, or nil. The second answer is `false`, not nil, because a nil cuts off later answers across an export.
---@param owner string
---@param def table
---@return string|false id
---@return string|false why
---@return string[]|nil warnings
function Actions.add(owner, def)
    if type(def) ~= 'table' then return false, 'an action is a table: { id, at, label, onSelect, ... }' end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    if type(def.at) == 'table' then
        copy.at = {}
        for k, v in pairs(def.at) do copy.at[k] = v end
    end
    local warn = {}
    copy = tidy(copy, warn)
    if copy.id == nil then copy.id = autoId(copy) end
    copy.id = tostring(copy.id)
    -- Said in F8 once each, and handed back to the caller.
    local warnings = nil
    if #warn > 0 then
        InteractSpec.say('actions', owner, ('action "%s"'):format(copy.id), warn)
        warnings = warn
    end
    local ok, why = reg:add(owner, copy.id, copy)
    if not ok then return false, why --[[@as string]], warnings end

    -- An engine can still refuse (unknown car part, entity gone): the action is not kept and the caller hears why.
    local key = reg:keyOf(owner, copy.id)
    if not mounted[key] then
        local reason = mountError[key] or 'it could not be put in the world'
        mountError[key] = nil
        reg:remove(owner, copy.id)
        return false, ('action "%s": %s'):format(copy.id, reason), warnings
    end
    return copy.id, false, warnings
end

--- Change how one of `owner`'s actions looks and moves in place (no fade out and back in). A style's
--- name, a style table, or nil for 'default'. The third answer is the warnings, as Actions.add's.
---@return boolean ok
---@return string|false reason
---@return string[]|nil warnings
function Actions.setStyle(owner, id, style)
    local key = reg:keyOf(owner, tostring(id))
    local cur = reg:get(key)
    if cur == nil then return false, ('no action "%s" of yours'):format(tostring(id)) end
    local warn = {}
    local s = InteractSpec.style(style, 'style', warn)
    local m = mounted[key]
    if m and m.kind ~= 'prompt' and m.kind ~= 'props' and m.kind ~= 'aimbox' and style ~= nil then
        warn[#warn + 1] = ('style is not read on %s. It was ignored'):format(PLACE_NAME[m.kind] or m.kind)
    end
    local warnings = nil
    if #warn > 0 then
        InteractSpec.say('actions', owner, ('action "%s"'):format(cur.id), warn)
        warnings = warn
    end
    -- Kept on the action, so a remount uses this style.
    cur.style = s
    if m and m.reg then m.reg.style = s end
    if m and (m.kind == 'prompt' or m.kind == 'aimbox') then
        for _, pid in ipairs(m.ids) do Interactions.setStyle(pid, s) end
    elseif m and m.kind == 'props' then
        -- Every prop's prompt found so far; one found later reads the action's style.
        PropPrompts.each(m.propKind, function(rec) Interactions.setStyle(rec.id, s) end)
    end
    -- `false`, not nil: a nil cuts off later answers across an export.
    return true, false, warnings
end

--- Change some of an action's fields. `patch` is merged over what it has; `at` is replaced whole.
--- The third answer is the warnings, as Actions.add's.
---@return boolean ok
---@return string|false reason
---@return string[]|nil warnings
function Actions.update(owner, id, patch)
    if type(patch) ~= 'table' then return false, 'a patch is a table of the fields to change' end
    local cur = reg:get(reg:keyOf(owner, tostring(id)))
    if cur == nil then return false, ('no action "%s" of yours'):format(tostring(id)) end
    -- Only the style: changed in place (Actions.setStyle).
    if next(patch) == 'style' and next(patch, 'style') == nil then
        return Actions.setStyle(owner, id, patch.style)
    end
    local merged = {}
    for k, v in pairs(cur) do merged[k] = v end
    for k, v in pairs(patch) do merged[k] = v end
    merged.id = cur.id
    local added, why, warnings = Actions.add(owner, merged)
    if not added then
        -- A refused change leaves the action as it was; an engine refusal needs the old one put back.
        if reg:get(reg:keyOf(owner, tostring(id))) == nil then Actions.add(owner, cur) end
        return false, why, warnings
    end
    return true, false, warnings   -- false, not nil: see Actions.setStyle
end

---@return boolean ok
---@return string|nil reason
function Actions.remove(owner, id)
    return reg:remove(owner, tostring(id))
end

--- Remove every one of `owner`'s actions in a group.
---@return boolean ok
---@return number|string countOrReason
function Actions.removeGroup(owner, group)
    if type(group) ~= 'string' or group == '' then return false, 'a group name is required' end
    local ids = {}
    for _, key in ipairs(reg:keysOf(owner)) do
        local def = reg:get(key)
        if def and def.group == group then ids[#ids + 1] = def.id end
    end
    for _, id in ipairs(ids) do reg:remove(owner, id) end
    return true, #ids
end

--- A plain copy of one action: its value fields, where it is mounted, and whether each option could be offered now (and why not).
---@return table|nil
function Actions.get(owner, id)
    local key = reg:keyOf(owner, tostring(id))
    local def = reg:get(key)
    if def == nil then return nil end
    local out = { id = def.id, owner = owner, key = key, group = def.group, reach = def.reach,
                  seeFrom = def.seeFrom, enabled = def.enabled ~= false, at = {} }
    for k, v in pairs(def.at or {}) do
        local t = type(v)
        if t == 'number' or t == 'string' or t == 'boolean' then out.at[k] = v
        elseif t == 'vector3' then out.at[k] = { x = v.x, y = v.y, z = v.z }
        elseif t == 'vector4' then out.at[k] = { x = v.x, y = v.y, z = v.z, w = v.w }
        elseif t == 'table' and rawget(v, '__cfx_functionReference') == nil then
            local x, y, z = xyz(v)
            if x then out.at[k] = { x = x, y = y, z = z, w = tonumber(v.w or v.heading or v[4]) } end
        end
    end
    if type(def.label) == 'string' then out.label = def.label end
    if type(def.icon) == 'string' then out.icon = def.icon end
    -- Its style as checked: a name, or a table of plain values.
    out.style = def.style
    local m = mounted[key]
    out.mounted = m and m.kind or false
    out.engineIds = m and m.ids or {}
    out.options = {}
    local entry = { key = key, id = def.id, owner = owner, def = def, opts = optionsOf(def) }
    for _, o in ipairs(entry.opts) do
        local c = condCtx(entry, o)
        c.entity = def.at and entityOf(def.at) or nil
        local ok, why = check(entry, o, c)
        out.options[#out.options + 1] = { id = o.id, label = resolveText(entry, o, 'label', c),
                                          offered = ok, why = why }
    end
    return out
end

-- The API for other resources: each reads its caller first (Registry.caller), before anything can yield,
-- so a resource names only its own actions.

exports('AddAction', function(def) return Actions.add(Registry.caller(), def) end)
exports('UpdateAction', function(id, patch) return Actions.update(Registry.caller(), id, patch) end)
exports('SetActionStyle', function(id, style) return Actions.setStyle(Registry.caller(), id, style) end)
exports('RemoveAction', function(id) return Actions.remove(Registry.caller(), id) end)
exports('RemoveActionGroup', function(group) return Actions.removeGroup(Registry.caller(), group) end)
exports('GetAction', function(id) return Actions.get(Registry.caller(), id) end)
