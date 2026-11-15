-- ============================================
-- HELD PROPS — things in a player's hand, made and removed by the server
-- ============================================
--
-- An emote's bottle, a progress bar's wrench. The SERVER makes them, from the emote list or the
-- server code running the bar — the client only ever names an emote, never a model — and the
-- server removes them: when the emote or bar ends, and when the player leaves or crashes.
--
-- THE SERVER CANNOT ATTACH. There is no server-side AttachEntityToEntity, and only the client that
-- OWNS an object can move it. A new server object is handed to a nearby client a moment after it is
-- made — nearly always the holder, since it is made where they stand. So:
--
--   1. give()      makes the object out of sight under the player's feet, and starts a hand-over
--   2. hand-over   on a short server timer (no client waits), looks for the object's owner and
--                  tells that one client "attach this to that player's hand"
--                  (whip_core:client:heldPropAttach, client/ui.lua)
--   3. the owner   attaches it at once and says so (whip_core:server:heldPropAttached)
--
--   No answer, or the object changed hands first? The next tick sends again, to whoever owns it
--   now. The server cannot see an attachment for itself (no server GetEntityAttachedTo), so the
--   owner's word is what ends the hand-over; a lie leaves a bottle unattached, which is cosmetic.
--
-- AND THE OWNER DELETES IT, TOO. A server DeleteEntity on an object a client owns can be undone
-- by that client, which sends it straight back (FiveM issues #3989, #2256) — and the window for it
-- is widest just after the object is made, while it is still being handed over. Spamming emotes
-- hit that window every time, and bottles piled up in the player's hand for everyone to see. So a
-- prop leaving a hand is RETIRED (see retire below): its owner is asked to delete it, and the
-- server deletes it itself only when no client holds it — nobody left to send it back.
--
-- ONE SET PER PLAYER, tagged 'emote', 'bar', 'give' (the item offered in give mode), 'take' (the
-- item just handed to them; both server/events_inventory.lua), 'camera' (the camera item, server/items/camera.lua),
-- or a resource's own (HoldProps: whip_fuel's 'whip_fuel:nozzle', a pump's nozzle in the hand). A new set replaces the old; a drop names its tag,
-- so an emote ending late cannot take away the wrench of the bar that replaced it.
--
-- ONE NEW SET A SECOND (SET_GAP_MS). Asking faster only changes which set comes next: the old set
-- goes at once, the newest ask waits for the gap, and every ask in between is forgotten.

HeldProps = {}

local held    = {}       -- [source] = { tag, props = { p, ... } } in their hand, or on its way there
local pending = {}       -- [source] = { list, tag } a set waiting out SET_GAP_MS
local armed   = {}       -- [source] = true while the timer that makes the pending set is set
local nextAt  = {}       -- [source] = the GetGameTimer() before which no new set is made
local byEnt   = {}       -- [entity] = { src, p } while its hand-over runs
local allowed = {}       -- [model hash] = true: models a CLIENT-run bar may ask for (see allowModel)

local TICK_MS    = 100   -- how often a hand-over or a retire looks
local TICKS      = 30    -- ...for three seconds
local RESEND_MS  = 600   -- the same owner is asked again if it has not done it in this long
local UNOWNED_MS = 500   -- a prop this young with no owner is still being handed out: wait for it
local SET_GAP_MS = 1000  -- at most one new set per player per second
local MAX_PROPS  = 2

local function hashOf(model)
    return type(model) == 'number' and model or GetHashKey(tostring(model))
end

--- Three numbers from { x, y, z } or { 1, 2, 3 } (zeros for anything missing).
local function xyz(t)
    t = type(t) == 'table' and t or {}
    return { (tonumber(t.x or t[1]) or 0.0) + 0.0, (tonumber(t.y or t[2]) or 0.0) + 0.0,
             (tonumber(t.z or t[3]) or 0.0) + 0.0 }
end

--- The client that owns an object, or nil when none does (the server holds it).
local function ownerOf(ent)
    local owner = NetworkGetEntityOwner(ent)
    return (owner and owner > 0) and owner or nil
end

--- One tick of a prop's way out. Its owner deletes it (whip_core:client:heldPropDelete, client/ui.lua);
--- the server deletes it only when no client holds it, or when the owner has not in three seconds.
local function retire(p, tick)
    if not DoesEntityExist(p.ent) then return end
    local owner = ownerOf(p.ent)
    local now = GetGameTimer()
    if tick >= TICKS then
        print(('[whip_core:props] a held prop\'s owner (%s) did not delete it; the server did'):format(tostring(owner)))
        DeleteEntity(p.ent)
        return
    end
    if not owner then
        if now - p.madeAt >= UNOWNED_MS then
            DeleteEntity(p.ent)   -- nobody holds it, so nobody can send it back
            return
        end
    elseif owner ~= p.sentTo or now - p.sentAt >= RESEND_MS then
        p.sentTo, p.sentAt = owner, now
        TriggerClientEvent('whip_core:client:heldPropDelete', owner, NetworkGetNetworkIdFromEntity(p.ent), p.model)
    end
    SetTimeout(TICK_MS, function() retire(p, tick + 1) end)
end

local function startRetire(p)
    byEnt[p.ent] = nil
    p.sentTo, p.sentAt = nil, 0
    retire(p, 0)
end

--- Take a player's props away — the set in their hand and any set still waiting. With `tag`, only
--- if it is that kind. Answers whether anything went.
---@param src number
---@param tag string|nil  'emote' | 'bar' | 'give' | 'take' | 'nozzle'
---@return boolean
function HeldProps.drop(src, tag)
    local went = false
    local waiting = pending[src]
    if waiting and (not tag or waiting.tag == tag) then
        pending[src] = nil
        went = true
    end
    local set = held[src]
    if set and (not tag or set.tag == tag) then
        held[src] = nil
        for _, p in ipairs(set.props) do startRetire(p) end
        went = true
    end
    return went
end

--- One tick of a prop's hand-over. See the top of the file.
local function handOver(src, set, p, tick)
    if held[src] ~= set or p.acked or not DoesEntityExist(p.ent) then return end
    local owner = ownerOf(p.ent)
    local now = GetGameTimer()
    if owner and (owner ~= p.sentTo or now - p.sentAt >= RESEND_MS) then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            p.sentTo, p.sentAt = owner, now
            TriggerClientEvent('whip_core:client:heldPropAttach', owner, NetworkGetNetworkIdFromEntity(p.ent),
                NetworkGetNetworkIdFromEntity(ped), p.bone, p.offset, p.rot, set.tag)
        end
    end
    if tick < TICKS then
        SetTimeout(TICK_MS, function() handOver(src, set, p, tick + 1) end)
    else
        print(('[whip_core:props] a held prop for player %d was never attached (owner %s)'):format(src, tostring(owner)))
    end
end

--- Where an admin once set a resource's prop by eye, kept in whip_item_holds for its tag ('whip_fuel:nozzle', the
--- hand 'right'), or nil: it replaces the offset and turn the resource gave its FIRST prop. Only a resource's own
--- tag ('<resource>:<tag>'), never whip's own sets (an item's is the item's, server/item_holds.lua).
local function savedHold(tag)
    if type(tag) ~= 'string' or not tag:find(':', 1, true) then return nil end
    return ItemHolds.get(tag, 'right')
end

--- Make a set now. give() decides when.
local function make(src, list, tag)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'no player' end

    local now = GetGameTimer()
    nextAt[src] = now + SET_GAP_MS
    local c = GetEntityCoords(ped)
    local bucket = GetPlayerRoutingBucket(src)
    local set = { tag = tag, props = {}, bucket = bucket }   -- the world it is made in (see worldWatch)
    held[src] = set

    for i = 1, math.min(#list, MAX_PROPS) do
        local prop = list[i]
        if type(prop) == 'table' and prop.model ~= nil then
            -- Under their feet, out of sight until the owner puts it in the hand.
            local hash = hashOf(prop.model)
            local ent = CreateObjectNoOffset(hash, c.x, c.y, c.z - 2.0, true, true, false)
            if ent and ent ~= 0 then
                SetEntityRoutingBucket(ent, bucket)   -- at birth: the player's own world
                SetEntityOrphanMode(ent, 2)           -- KeepEntity: this file decides when it goes
                -- A resource's first prop sits where an admin once set it by eye, when one has (savedHold)
                local set_ = i == 1 and savedHold(tag)
                local p = { ent = ent, model = hash, madeAt = now, bone = math.floor(tonumber(prop.bone) or 18905),
                            offset = set_ and xyz(set_.offset) or xyz(prop.offset),
                            rot = set_ and xyz(set_.rot) or xyz(prop.rot), sentAt = 0 }
                set.props[#set.props + 1] = p
                byEnt[ent] = { src = src, p = p }
                handOver(src, set, p, 0)
            end
        end
    end
    return true
end

--- Put props in a player's hand: a list of { model, bone, offset = {x,y,z}, rot = {x,y,z} } (at most
--- two). Replaces whatever they held — at once, or, within a second of their last set, when the
--- second is up (see SET_GAP_MS). Only server code calls this — the model is trusted here.
---
--- A SET OF ANOTHER TAG IT REPLACES IS SAID (whip_core:heldProps:lost, reason 'replaced'): an emote's cup or
--- an item handed over takes the hand from a resource's own prop (a pump's nozzle), and that resource must
--- hear it is gone, not go on as if it were still held.
---@param src number
---@param list table
---@param tag string  'emote' | 'bar' | 'give' | 'take' | 'nozzle'
---@return boolean ok
---@return string|nil why
function HeldProps.give(src, list, tag)
    if type(list) ~= 'table' then return false, 'no props' end
    local before = HeldProps.tagOf(src)
    HeldProps.drop(src)
    if before and before ~= tag then
        WhipEmit('whip_core:heldProps:lost', { source = src, tag = before, reason = 'replaced', by = tag })
    end

    local wait = (nextAt[src] or 0) - GetGameTimer()
    if wait <= 0 then return make(src, list, tag) end

    pending[src] = { list = list, tag = tag }   -- the newest ask; any older one is forgotten
    if not armed[src] then
        armed[src] = true
        SetTimeout(math.ceil(wait), function()
            armed[src] = nil
            local ask = pending[src]
            pending[src] = nil
            if ask then make(src, ask.list, ask.tag) end
        end)
    end
    return true
end

--- What a player's hands hold, or are about to: the set's tag ('emote' | 'bar' | 'give' | 'take' |
--- 'nozzle'), or nil.
---@param src number
---@return string|nil
function HeldProps.tagOf(src)
    local set = held[src] or pending[src]
    return set and set.tag or nil
end

--- Let client-run bars hold this model. Server bars (TimedAction.progress) and every emote prop are
--- allowed already; a client-run bar may only ask for a model the server has vouched for.
---@param model string|number
function HeldProps.allowModel(model)
    if model ~= nil then allowed[hashOf(model)] = true end
end

for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
    for _, p in ipairs(e.props or {}) do HeldProps.allowModel(p.model) end
end

-- ============================================
-- From the clients
-- ============================================

--- The owner put it in the hand. Only the object's owner is believed.
SecureEvent('whip_core:server:heldPropAttached', {
    rateLimit = 100,
    burst     = 10,
    whileDead = true,
    params    = { {'netId', 'id', 1, 65535} },
}, function(source, _, netId)
    local ent = NetworkGetEntityFromNetworkId(netId)
    local rec = ent and byEnt[ent]
    if rec and NetworkGetEntityOwner(ent) == source then
        rec.p.acked = true
        byEnt[ent] = nil
    end
end)

--- The emote, bar or give mode ended on the client. NEVER REFUSED: it only ever takes the sender's own
--- props away, and a refused one — a /e c at the end of a burst of emotes — left the bottle in their hand.
SecureEvent('whip_core:server:heldPropsDrop', {
    rateLimit = false,
    whileDead = true,   -- dying ends an emote; its props must still go
    params    = { {'tag', 'enum', { 'emote', 'bar', 'give' }} },
}, function(source, _, tag)
    HeldProps.drop(source, tag)
end)

--- A bar the CLIENT runs (the client Progress export) wants a prop. The model must be one the
--- server has vouched for (see allowModel) — a client cannot spawn whatever it names.
SecureEvent('whip_core:server:barProp', {
    rateLimit = 250,
    burst     = 3,
    params    = {
        {'model',  'key', 80},
        {'bone',   'int', 0, 65535},
        {'offset', 'list', {'v', 'number', -2.0, 2.0}, 3},
        {'rot',    'list', {'v', 'number', -360.0, 360.0}, 3},
    },
}, function(source, _, model, bone, offset, rot)
    if not allowed[hashOf(model:lower())] then return false, 'That prop cannot be held' end
    HeldProps.give(source, { { model = model, bone = bone, offset = offset, rot = rot } }, 'bar')
end)

-- ============================================
-- For every resource
-- ============================================
--
-- Any resource puts props in a player's hand the same way whip does (a job's tool, a sign, a pump's nozzle):
-- server side, by model, everyone seeing it, gone when the player leaves. Its tags are its own, named
-- '<resource>:<tag>': its drop can never take away an emote's bottle, a bar's wrench or another resource's props,
-- and its props go when it stops. The model is the calling resource's word (server code, as whip's own give is).
-- The hand holds one set: any new one (an emote's, a bar's, an item handed over) replaces a resource's, and says so
-- (whip_core:heldProps:lost, reason 'replaced': HeldProps.give); so does a move to another world (reason 'world').

--- The caller's own name for a tag ('<resource>:<tag>'), and the caller.
local function ownTag(tag)
    local res = GetInvokingResource() or GetCurrentResourceName()
    tag = (type(tag) == 'string' and tag ~= '') and tag:sub(1, 40) or 'held'
    return res .. ':' .. tag, res
end

--- Put props in a player's hand, for everyone: { { model, bone?, offset? = {x,y,z}, rot? = {x,y,z} } } (at most two;
--- bone defaults to SKEL_L_Hand 18905, as whip's own), replacing whatever they held. `tag` names the set: the caller's
--- own, which a drop names.
---@return boolean ok, string|nil why
exports('HoldProps', function(source, props, tag)
    local src = tonumber(source)
    local ped = src and GetPlayerPed(src)
    if not src or not ped or ped == 0 then return false, 'no such player' end
    if type(props) ~= 'table' or #props == 0 then return false, 'props is a list of { model, bone, offset, rot }' end
    return HeldProps.give(src, props, (ownTag(tag)))
end)

--- Take a player's props of the caller's `tag` away; with no tag, whatever of the caller's they hold. Never anybody
--- else's. true when anything went, or false and why.
---@return boolean dropped, string|nil why
exports('DropHeldProps', function(source, tag)
    local src = tonumber(source)
    if not src then return false, 'source is a server id' end
    local full, res = ownTag(tag)
    if tag ~= nil then
        if HeldProps.drop(src, full) then return true end
        return false, ('they hold none of your props tagged %q'):format(tostring(tag))
    end
    local current = HeldProps.tagOf(src)
    if current and current:sub(1, #res + 1) == res .. ':' and HeldProps.drop(src, current) then return true end
    return false, 'they hold none of your props'
end)

--- What a player's hands hold, or are about to: its tag (a resource's '<resource>:<tag>', or whip's own 'emote',
--- 'bar', 'give', 'take'), or nil.
---@return string|nil
exports('GetHeldPropsTag', function(source)
    local src = tonumber(source)
    return src and HeldProps.tagOf(src) or nil
end)

-- A resource stopping takes its props out of every hand.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    local prefix = res .. ':'
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local tag = src and HeldProps.tagOf(src)
        if src and tag and tag:sub(1, #prefix) == prefix then HeldProps.drop(src, tag) end
    end
end)

-- In GetRegistrations with the registries (Registry.addLister): who holds what, tagged '<resource>:<tag>'.
Registry.addLister('heldProps', function()
    local out = {}
    for src, set in pairs(held) do
        local owner = type(set.tag) == 'string' and set.tag:match('^([^:]+):') or nil
        if owner then out[#out + 1] = { key = ('%s %s'):format(tostring(src), set.tag), owner = owner } end
    end
    return out
end)

-- ============================================
-- Leaving, and whip_core stopping
-- ============================================

AddEventHandler('playerDropped', function()
    local src = source
    HeldProps.drop(src)   -- retired: the owner (someone else now, or nobody) deletes, or the server does
    nextAt[src] = nil
end)

--- A LOGOUT DROPS THEM ON THE SERVER, not only when the client says so. Logging out moves the player
--- to character select's routing bucket first (WhipPlayer:logout), and an attached prop does not
--- follow a bucket move (FiveM #912): it floated where their hand was, for everyone left behind,
--- until the client's own drop arrived. Core's hook, not the public event, which any resource can fire.
Character.onLife('logout', function(e)
    HeldProps.drop(e.source)
end)

--- ANY OTHER MOVE TO ANOTHER WORLD DROPS THEM TOO, whatever made it (the Director's own-world test, any
--- resource's SetPlayerRoutingBucket): the prop cannot follow (FiveM #912), and it would hang where the
--- hand was for everyone left behind while its owner went on counting it as held. There is no event for a
--- bucket move, so the players holding props are looked at; whose world changed is dropped and said
--- (whip_core:heldProps:lost, reason 'world'). Nothing to look at, nothing done.
local WORLD_LOOK_MS = 1000
Every('held props: world moves', WORLD_LOOK_MS, function()
    local moved = nil
    for src, set in pairs(held) do
        if set.bucket and GetPlayerRoutingBucket(src) ~= set.bucket then
            moved = moved or {}
            moved[#moved + 1] = { src = src, tag = set.tag }
        end
    end
    for _, m in ipairs(moved or {}) do
        if HeldProps.drop(m.src, m.tag) then
            WhipEmit('whip_core:heldProps:lost', { source = m.src, tag = m.tag, reason = 'world' })
        end
    end
end)

--- Stopping: no timers run after this, so no retiring. Each owner is told and the server deletes
--- too, both at once — the best that can be done with no second look.
CoreStop.add(15, 'held props: delete', function()
    for _, set in pairs(held) do
        for _, p in ipairs(set.props) do
            if DoesEntityExist(p.ent) then
                local owner = ownerOf(p.ent)
                if owner then
                    TriggerClientEvent('whip_core:client:heldPropDelete', owner, NetworkGetNetworkIdFromEntity(p.ent), p.model)
                end
                DeleteEntity(p.ent)
            end
        end
    end
    held, pending = {}, {}
end)
