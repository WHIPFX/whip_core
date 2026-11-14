-- Dungeon Mode: the live world is the scenario. A Dungeon Master (director.live, server/permissions.lua) opens the
-- Director's world builder with no scenario (client/director_live.lua). What they put down (an NPC, a car, a prop, a
-- Fixed Weapon) is made in the world at once, for everyone. A click on anything in the world opens the Object Viewer's
-- options for it (tools/ov_panel.lua, server/object_viewer.lua).
-- Nothing they do lasts: what they make stays until the server restarts or they remove it (an admin may remove anyone's),
-- and is theirs by account, so it stays when they log off. What would last (a car made someone's, a stat or walk saved,
-- an owned car put away, deleted or repaired, a kick or a ban) is a full admin's only (whip.devtools): greyed in the
-- Object Viewer and refused on the server. Heal and Armour stay open. A car's key left on the ground is stamped (dlive)
-- and goes at the next start.
-- Everything is logged (server/activity_log.lua): each thing made, moved and removed, and each option used, on the
-- Dungeon Master's timeline, and the player's when used on a player.
--
-- A thing: { id, kind = 'npc' | 'vehicle' | 'prop' | 'hide', userId, by (the maker's character name), model, label,
-- weapon, coords = { x, y, z, heading }, rot = { x, y } (a prop's tilt), made (os.time), and what made it: npcId
-- (Npcs), vehicleId (a temporary car, unlocked, never idle-despawned; `key`: the key its Key settings cut) or set (a
-- prop set of its own, client-made: a move or a change shows it again; `solid`, `replaces`: the map prop it took the
-- place of). A 'hide' is one of the map's own props hidden on every game (`hash`). Gone from the world (an NPC's body
-- cleared, a car released) is gone from here. Effects on props and ground items are kept here too (below).

DirectorLive = {}

local CORE = GetCurrentResourceName()
local LIVE = 'director.live'
local ADMIN_ACE = 'whip.devtools'
local MAX_EACH = 150      -- things one account may have up at once (what one person can flood the world with)
local MAX_ALL = 600       -- and everyone's together

local things = {}         -- [id] = the thing
local byNpc, byVehicle = {}, {}   -- [npcId] / [vehicleId] = id
local nextId = 0

local KIND_WORD = { npc = 'NPC', vehicle = 'car', prop = 'prop' }   -- (what the builder makes: liveMake)
local NOUN = { npc = 'NPC', vehicle = 'car', prop = 'prop', hide = 'hidden map prop' }

--- A full admin: what lasts is theirs alone.
function DirectorLive.isAdmin(src)
    return DevTools.hasAce(src, ADMIN_ACE) == true
end

local finite = DirectorKit.finite

--- { x, y, z, heading } from a page's coords (DirectorKit.place), kept to the map, or nil.
local function readCoords(c)
    local p = DirectorKit.place(c)
    if not p or math.abs(p.x) > 20000 or math.abs(p.y) > 20000 or p.z < -500 or p.z > 3000 then return nil end
    return p
end

local function readRot(r)
    if type(r) ~= 'table' then return { x = 0.0, y = 0.0 } end
    local x, y = tonumber(r.x) or 0.0, tonumber(r.y) or 0.0
    if not (finite(x) and finite(y)) then return { x = 0.0, y = 0.0 } end
    return { x = x % 360.0, y = y % 360.0 }
end

local function modelName(m)
    if type(m) ~= 'string' then return nil end
    m = m:lower()
    if #m == 0 or #m > 64 or not m:match('^[%w_]+$') then return nil end
    return m
end

-- ============================================
-- The log
-- ============================================

--- On the Dungeon Master's timeline (their character's), and on `alsoChar`'s when it was done to a player.
---@param src number
---@param what string   a line: "made an NPC (a_m_y_hipster_01)"
---@param at table|nil  { x, y, z }
---@param alsoChar number|nil
function DirectorLive.log(src, what, at, alsoChar)
    local p = Players[src]
    local who = p and p.fullName or ('player ' .. tostring(src))
    local opts = { detail = DirectorKit.cut(('Dungeon Master %s %s'):format(who, what), 191),
                   x = at and at.x, y = at and at.y, z = at and at.z }
    if Log and Log.write then
        Log.write(p and p.charId or nil, 'dungeon_mode', opts)
        if alsoChar and alsoChar ~= (p and p.charId) then Log.write(alsoChar, 'dungeon_mode', opts) end
    end
end

-- ============================================
-- What there is
-- ============================================

--- Is this thing `src`'s to change (theirs, or they are a full admin)?
local function mayChange(src, t)
    local p = Players[src]
    return (p and p.userId == t.userId) or DirectorLive.isAdmin(src)
end

--- A thing as a page or a game sees it: what it is, whose, and how this game finds it (netId: an NPC or a car;
--- wire: a prop's set as each game knows it).
local function view(t, src)
    local p = Players[src]
    local v = { id = t.id, kind = t.kind, model = t.model, label = t.label, weapon = t.weapon, by = t.by, made = t.made,
                coords = t.coords, rot = t.rot, mine = p ~= nil and p.userId == t.userId }
    if t.kind == 'npc' then
        local n = Npcs.get(t.npcId)
        v.netId = n and n.netId or nil
        v.alive = n and n.alive or nil
        if n and n.coords then v.coords = { x = n.coords.x, y = n.coords.y, z = n.coords.z, heading = t.coords.heading } end
    elseif t.kind == 'vehicle' then
        local e = Vehicles.getEntity(t.vehicleId)
        if e and DoesEntityExist(e) then
            v.netId = NetworkGetNetworkIdFromEntity(e)
            local c = GetEntityCoords(e)
            v.coords = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(e) }
        end
    elseif t.kind == 'prop' then
        v.wire = PropSets.wireOf(CORE, t.set)
        v.solid = t.solid ~= false
    end
    return v
end

local function countOf(userId)
    local mine, all = 0, 0
    for _, t in pairs(things) do
        all = all + 1
        if t.userId == userId then mine = mine + 1 end
    end
    return mine, all
end

--- The thing an entity is, or nil (an NPC or a car a Dungeon Master made: whip's own, yet theirs to change).
function DirectorLive.byEntity(entity)
    if not entity or entity == 0 then return nil end
    local etype = GetEntityType(entity)
    if etype == 1 then
        local npcId = Npcs.by('entity', entity)
        local id = npcId and byNpc[npcId]
        return id and things[id] or nil
    elseif etype == 2 then
        local vid = Vehicles.getEntityVehicleId(entity)
        local id = vid and byVehicle[vid]
        return id and things[id] or nil
    end
    return nil
end

function DirectorLive.get(id) return things[id] end

--- What `src` may see of a thing on the Object Viewer's card: { id, by, mine, mayChange }, or nil.
function DirectorLive.cardOf(src, entity)
    local t = DirectorLive.byEntity(entity)
    if not t then return nil end
    local p = Players[src]
    return { id = t.id, by = t.by, mine = p ~= nil and p.userId == t.userId, mayChange = mayChange(src, t) }
end

local dropKey   -- (below: a car's key goes with it)
local fxMoved   -- (below: a prop with an effect on it moved, changed or went: every game is told)

local function forget(t)
    if things[t.id] ~= t then return end
    things[t.id] = nil
    if t.npcId then byNpc[t.npcId] = nil end
    if t.vehicleId then byVehicle[t.vehicleId] = nil end
    if t.key then CreateThread(function() dropKey(t) end) end
end

-- Gone from the world, gone from here: an NPC's record ending (its body cleared, whip_core stopping), a car released.
Npcs.onLife('despawned', function(e)
    local id = type(e) == 'table' and e.npcId and byNpc[e.npcId]
    if id and things[id] then forget(things[id]) end
end)
Vehicles.onLife('released', function(e)
    local id = type(e) == 'table' and e.vehicleId and byVehicle[e.vehicleId]
    if id and things[id] then forget(things[id]) end
end)

-- ============================================
-- Making, moving and removing
-- ============================================

local function propSpec(t)
    local p = { model = t.model, coords = vector3(t.coords.x, t.coords.y, t.coords.z),
                rot = vector3(t.rot.x, t.rot.y, t.coords.heading), weapon = t.weapon }
    if t.solid == false then p.collision = false end
    return { props = { p } }
end

--- An NPC's own settings, kept so a new gun (it is made again with one) keeps them: { behaviour, conditions }.
local function npcDef(t, at)
    return { model = t.model, coords = at, weapon = t.gun, behaviour = t.guard and 'guard' or 'stand',
             conditions = { invincible = t.invincible == true, canMove = t.still ~= true } }
end

--- Make one, where it was put down. Answers the thing's view, or false and why.
---@param spec table { kind, model, coords = { x, y, z, heading }, rot = { x, y }, weapon, label }
---@param opts table|nil  for a car: forSource (who gets its key); for an NPC: gun (its weapon), hostileTo, because
function DirectorLive.make(src, spec, opts)
    opts = type(opts) == 'table' and opts or {}
    local p = Players[src]
    if not p or not p.userId then return false, 'Load a character first' end
    if type(spec) ~= 'table' or not KIND_WORD[spec.kind] then return false, 'An NPC, a car or a prop' end
    local model = modelName(spec.model)
    if not model then return false, 'That is not a model name' end
    local at = readCoords(spec.coords)
    if not at then return false, 'That is not a place in the world' end
    local mine, all = countOf(p.userId)
    if mine >= MAX_EACH then return false, ('You have %d things up: remove some first'):format(mine) end
    if all >= MAX_ALL then return false, ('There are %d live things up: some must go first'):format(all) end

    local id = nextId + 1
    local t = { id = id, kind = spec.kind, userId = p.userId, by = p.fullName or ('player ' .. src), model = model,
                label = type(spec.label) == 'string' and Sanitize.string(spec.label, 60) or nil,
                coords = at, rot = readRot(spec.rot), made = os.time() }
    if t.kind == 'npc' then
        t.gun = type(opts.gun) == 'string' and opts.gun or nil
        local npcId, why = Npcs.spawn(CORE, npcDef(t, at), { bucket = 0, hostileTo = opts.hostileTo, because = opts.because })
        if not npcId then return false, why or 'The NPC could not be made' end
        t.npcId = npcId
    elseif t.kind == 'vehicle' then
        -- (For someone: made only where there is room, their key in their pocket.)
        local vid, why = Vehicles.spawnTempFor(model, vector4(at.x, at.y, at.z, at.heading),
            { locked = false, idleDespawn = false, force = opts.forSource == nil, forSource = opts.forSource }, CORE)
        if not vid then return false, why or 'The car could not be made' end
        t.vehicleId = vid
        -- (Its key in their pocket: its Key settings show it, and take it back when it changes.)
        if opts.forSource and Players[opts.forSource] then t.key = { where = 'player', charId = Players[opts.forSource].charId } end
    else
        if spec.weapon ~= nil then
            local w = type(spec.weapon) == 'string' and spec.weapon:upper() or nil
            if not w or WeaponCatalog.modelOf(w) ~= model then return false, 'That gun is not that model' end
            t.weapon = w
        end
        t.set = 'live:' .. id
        local ok, why = PropSets.show(CORE, t.set, propSpec(t))
        if not ok then return false, why or 'The prop could not be made' end
    end
    nextId = id
    things[id] = t
    if t.npcId then byNpc[t.npcId] = id end
    if t.vehicleId then byVehicle[t.vehicleId] = id end
    DirectorLive.log(src, ('made %s %s (%s)'):format(t.kind == 'npc' and 'an' or 'a', t.weapon and 'Fixed Weapon' or KIND_WORD[t.kind],
        t.weapon or model), at)
    return view(t, src)
end

--- Put down somewhere else (the builder's markers, let go). An NPC stands there from now on; a car was moved by the
--- game that holds it (only its place is kept); a prop is shown again there, on every game. Answers its view.
function DirectorLive.move(src, id, coords, rot)
    local t = things[id]
    if not t then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    local at = readCoords(coords)
    if not at then return false, 'That is not a place in the world' end
    t.coords = at
    if t.kind == 'npc' then
        local ok, why = Npcs.setState(CORE, t.npcId, { post = at })
        if not ok then return false, why end
    elseif t.kind == 'prop' then
        t.rot = readRot(rot)
        local ok, why = PropSets.show(CORE, t.set, propSpec(t))
        if not ok then return false, why end
        fxMoved(t.id)
    end
    DirectorLive.log(src, ('moved %s (%s)'):format(KIND_WORD[t.kind], t.weapon or t.model), at)
    return view(t, src)
end

local pushHides   -- (below: the map props hidden, to every game)

--- Out of the world, whatever it is (it is forgotten first). `quiet`: every game is told once by the caller instead
--- (Clear: one list, not one per thing).
local function unmake(t, quiet)
    forget(t)
    if t.kind == 'npc' then Npcs.despawn(CORE, t.npcId)
    elseif t.kind == 'vehicle' then Vehicles.despawnByRef(t.vehicleId)
    elseif t.kind == 'hide' then if not quiet then pushHides() end
    else
        PropSets.hide(CORE, t.set)
        if not quiet then fxMoved(t.id) end
    end
end

--- Take one out of the world (a map prop hidden: back for everyone). Answers true, or false and why.
function DirectorLive.remove(src, id)
    local t = things[id]
    if not t then return false, 'It is not there any more' end
    if src and not mayChange(src, t) then return false, 'That is someone else\'s' end
    unmake(t)
    if src then
        DirectorLive.log(src, ('%s %s (%s), made by %s'):format(t.kind == 'hide' and 'put back' or 'removed', NOUN[t.kind],
            t.weapon or t.label or t.model, t.by), t.coords)
    end
    return true
end

-- ============================================
-- A live NPC's own settings (the Object Viewer's Dungeon NPC options: server/object_viewer.lua)
-- ============================================

--- Change one of its NPCs (Npcs.setState's patch: behaviour, conditions, hostileTo, follow, ...). `keep`: what of it is
--- remembered for a remake ({ guard, invincible, still }). Answers true, or false and why.
function DirectorLive.setNpc(src, t, patch, because, keep)
    if not (t and t.kind == 'npc' and things[t.id] == t) then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    local ok, why = Npcs.setState(CORE, t.npcId, patch, because)
    if not ok then return false, why end
    for k, v in pairs(type(keep) == 'table' and keep or {}) do t[k] = v end
    return true
end

--- A new gun for one of its NPCs (none: `weapon` false): it is made again with it where it stands, its settings kept
--- (whoever it was fighting or following is let go). Answers true, or false and why.
function DirectorLive.rearm(src, t, weapon)
    if not (t and t.kind == 'npc' and things[t.id] == t) then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    local n = Npcs.get(t.npcId)
    local c = n and n.coords or t.coords
    local h = n and n.post and n.post.heading or t.coords.heading
    local at = { x = c.x, y = c.y, z = c.z, heading = h }
    local was = t.gun
    t.gun = weapon or nil
    local newId, why = Npcs.spawn(CORE, npcDef(t, at), { bucket = 0 })
    if not newId then t.gun = was return false, why or 'It could not be made again' end
    local old = t.npcId
    byNpc[old] = nil
    t.npcId, t.coords = newId, at
    byNpc[newId] = t.id
    Npcs.despawn(CORE, old)
    return true
end

--- Its settings' switches, as the Object Viewer shows them.
function DirectorLive.holdsOf(t)
    return { guard = t.guard == true, invincible = t.invincible == true, still = t.still == true }
end

-- ============================================
-- A live car's key (the Object Viewer's Dungeon car options: server/object_viewer.lua)
-- ============================================
--
-- The Director's Key settings, for a car made here: no key, or its key in someone's pocket, in its ignition, its
-- glovebox or its boot, or on the ground beside it; locked or not; and "only its key opens it" (no lockpicking, no
-- hotwiring). The key it cut is remembered (t.key = { where, charId, groundId }), so a change takes that one back first:
-- one key out at a time. When the car goes its key goes too: from the pocket it was given to (while they are online),
-- off the ground; the ignition, glovebox and boot go with the car. A key a player has moved since (out of the glovebox
-- into a pocket) is theirs until the car goes: only where it was put is looked in.

local KEY_PLACES = { none = true, player = true, ignition = true, glovebox = true, trunk = true, ground = true }
local KEY_SUB = { ignition = 'key', glovebox = 'glovebox', trunk = 'trunk' }
local KEY_REASON = 'Dungeon Mode car key'

--- Every key of this car in one of its own storages, taken out (the ignition, the glovebox, the boot).
local function takeFromCar(vid, sub)
    local store = Stores.fromAddr({ kind = 'vehicle', id = vid, sub = sub }, { slotOptional = true })
    if not store then return end
    for slot, it in pairs(Stores.read(store).items) do
        if it.item == 'vehicle_key' and Vehicles.keyFits(it.metadata, vid) then
            Stores.takeAt({ kind = 'vehicle', id = vid, sub = sub, slot = slot }, nil, { reason = KEY_REASON })
        end
    end
end

--- The key this car's settings cut, taken back from where it was put. It may wait (a pocket is saved).
dropKey = function(t)
    local k = t.key
    t.key = nil
    if type(k) ~= 'table' then return end
    local vid = t.vehicleId
    if k.where == 'player' then
        local p = k.charId and PlayersByCharId[k.charId]
        if p and p.source then Vehicles.removeKey(p.source, p, vid) end
    elseif k.where == 'ground' then
        local g = k.groundId and GroundItems.getById(k.groundId)
        if g and g.item == 'vehicle_key' then GroundItems.deleteItem(k.groundId) end
    elseif KEY_SUB[k.where] and Vehicles.getDef(vid) then
        takeFromCar(vid, KEY_SUB[k.where])
    end
end

-- (A key into or out of its ignition tells whoever sits in it: the vehicle store's afterWrite, Vehicles.tellIgnition.)

--- Somewhere on the ground beside a car: off its left side, a metre and a half out (each game lays the pile on the
--- ground it has there).
local function besideCar(ent)
    local c, h = GetEntityCoords(ent), math.rad(GetEntityHeading(ent))
    local rx, ry = math.cos(h), math.sin(h)   -- GTA's right is (cos, sin)
    return vector3(c.x - rx * 1.8, c.y - ry * 1.8, c.z)
end

--- Cut its key and put it `where` (`to`: the server id of the one who gets it). Answers true, or false and why.
local function cutKey(t, where, to)
    local vid = t.vehicleId
    if where == 'none' then return true end
    if where == 'player' then
        local p = Players[to]
        local ok, why = Vehicles.giveKey(to, p, vid)
        if not ok and not Vehicles.playerHasKey(p, vid) then return false, why end
        t.key = { where = 'player', charId = p.charId }
        return true
    end
    local md = Vehicles.keyMetadata(vid)
    if not md then return false, 'It is not there any more' end
    if where == 'ground' then
        local ent = Vehicles.getEntity(vid)
        if not ent then return false, 'The car is not in the world' end
        -- Stamped: a ground item is saved as it lies, and this car is gone at a restart. The Director's boot sweep
        -- (server/director/main.lua) takes a stamped key away with the run piles left behind.
        md.dlive = true
        local g, why = GroundItems.createItem({ item = 'vehicle_key', amount = 1, coords = besideCar(ent), metadata = md,
                                                reason = 'Director: Dungeon Mode, a car\'s key' })
        if not g then return false, why or 'The key could not be put down' end
        t.key = { where = 'ground', groundId = g.id }
        return true
    end
    local slot, why = Stores.giveAt({ kind = 'vehicle', id = vid, sub = KEY_SUB[where] }, 'vehicle_key', 1, md, { reason = KEY_REASON })
    if not slot then return false, why or 'There is no room for it there' end
    t.key = { where = where }
    return true
end

--- Is there room for its key at `where` once its old key is taken back (from t.key's place)? true, or false and why.
--- `to`: who gets it, for 'A player' (their pockets: Vehicles.canTakeKey).
local function roomFor(t, where, to)
    if where == 'player' then
        local p = Players[to]
        if Vehicles.playerHasKey(p, t.vehicleId) then return true end
        return Vehicles.canTakeKey(p)
    end
    local sub = KEY_SUB[where]
    if not sub or (type(t.key) == 'table' and t.key.where == where) then return true end
    local store = Stores.fromAddr({ kind = 'vehicle', id = t.vehicleId, sub = sub }, { slotOptional = true })
    if not store then return false, 'The car is not there any more' end
    -- A free slot (a key never stacks: each is its own). Weight is no question for a key.
    local used = 0
    for _ in pairs(Stores.read(store).items or {}) do used = used + 1 end
    if used < (tonumber(store.kind.slots(store.handle)) or 0) then return true end
    if where == 'ignition' then return false, 'There is a key in its ignition already' end
    return false, ('There is no room for its key in the %s'):format(where == 'trunk' and 'boot' or where)
end

--- Its Key settings, as the Object Viewer's page shows them: { where, who, locked, secure }.
function DirectorLive.keyOf(t)
    local k = type(t.key) == 'table' and t.key or nil
    local who = nil
    if k and k.where == 'player' then
        who = (PlayersByCharId[k.charId] and PlayersByCharId[k.charId].fullName)
            or (ResolveCharNames({ k.charId }) or {})[k.charId] or ('character #' .. tostring(k.charId))
    end
    local def = Vehicles.getDef(t.vehicleId)
    return { where = k and k.where or 'none', who = who, sid = k and k.charId and PlayersByCharId[k.charId] and PlayersByCharId[k.charId].source or nil,
             locked = Vehicles.isLocked(t.vehicleId), secure = def ~= nil and def.secure == true }
end

--- Set one of its cars' Key settings: `spec` { where, sid (where = 'player'), locked, secure }. Its key from before is
--- taken back first, and a new one cut; a place with no room for it is refused before anything changes. Answers true
--- and what it says now, or false, why and what it says now (a cut that failed after all: the page shows the truth).
function DirectorLive.setKey(src, t, spec)
    if not (t and t.kind == 'vehicle' and things[t.id] == t) then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    local vid = t.vehicleId
    if not Vehicles.getDef(vid) then return false, 'It is not there any more' end
    spec = type(spec) == 'table' and spec or {}
    local where = KEY_PLACES[spec.where] and spec.where or 'none'
    local to = nil
    if where == 'player' then
        to = Sanitize.id(spec.sid)
        if not (to and Players[to] and Players[to].charId) then return false, 'Pick who has its key' end
    end
    if where == 'ground' and not Vehicles.getEntity(vid) then return false, 'The car is not in the world' end
    local room, noRoom = roomFor(t, where, to)
    if not room then return false, noRoom end
    -- The key from before goes while it still fits (a new token below would make it any key).
    dropKey(t)
    local secure = spec.secure == true
    local def = Vehicles.getDef(vid)
    -- (dropKey may wait: the car can have gone meanwhile)
    if not def then return false, 'It is not there any more', DirectorLive.keyOf(t) end
    if (def.secure == true) ~= secure then
        local ok, why = Vehicles.setSecure(vid, secure)
        if not ok then return false, why, DirectorLive.keyOf(t) end
    end
    local ok, why = cutKey(t, where, to)
    if not ok then return false, why, DirectorLive.keyOf(t) end
    if spec.locked ~= nil then Vehicles.setLocked(vid, spec.locked == true, src) end
    return true, DirectorLive.keyOf(t)
end

-- ============================================
-- A live prop's own settings, and the map's props (the Object Viewer's Dungeon prop and map prop options)
-- ============================================
--
-- A prop made here has no entity on the server (each game makes its own copy from its set), so a game says which one
-- it means by its set's wire id (PropSets.byWire). Its options change the set and show it again: its model (its place
-- and turn kept), and whether it is solid.
--
-- THE MAP'S OWN PROPS are each game's own too, from the map. Removed for everyone, one is hidden on every game where it
-- stands (a model hide: client/live_world.lua) until a restart, or until it is put back (its row on the Dungeon Mode
-- page). Taken over (Make it a Dungeon prop, Change model), it is hidden the same way and a prop of this file's, of its
-- model or the new one, goes up exactly where it stood: from then on it is a prop made here, its maker's to move,
-- change or remove, and Put the map's one back ends both.

local function unsignedHash(h)
    h = math.tointeger(tonumber(h))
    if not h or h < -0x80000000 or h > 0xFFFFFFFF then return nil end
    if h < 0 then h = h + 0x100000000 end
    return h
end

--- The map prop a game sent ({ model = its hash, name, x, y, z, rx, ry, rz }): { hash, name, coords, rot }, or nil and why.
local function readMap(m)
    if type(m) ~= 'table' then return nil, 'Which prop?' end
    local hash = unsignedHash(m.model)
    if not hash or hash == 0 then return nil, 'That is not a model' end
    local coords = readCoords({ x = m.x, y = m.y, z = m.z, heading = m.rz })
    if not coords then return nil, 'That is not a place in the world' end
    return { hash = hash, name = modelName(m.name), coords = coords, rot = readRot({ x = m.rx, y = m.ry }) }
end

--- The live prop a set's wire id is (one of this file's sets), or nil.
function DirectorLive.byWire(wireId)
    local owner, id = PropSets.byWire(wireId)
    if owner ~= CORE or type(id) ~= 'string' then return nil end
    local t = things[tonumber(id:match('^live:(%d+)$') or '')]
    return t and t.kind == 'prop' and t or nil
end

--- A thing as `src`'s page or game sees it now (its wire is a prop's set as shown now: new after every change).
function DirectorLive.viewOf(src, t) return view(t, src) end

--- What `src` may see of a live prop on the Object Viewer's card: { id, by, mine, mayChange, solid, weapon, replaces },
--- or nil.
function DirectorLive.cardOfWire(src, wireId)
    local t = DirectorLive.byWire(wireId)
    if not t then return nil end
    local p = Players[src]
    return { id = t.id, by = t.by, mine = p ~= nil and p.userId == t.userId, mayChange = mayChange(src, t),
             solid = t.solid ~= false, weapon = t.weapon, replaces = t.replaces ~= nil and things[t.replaces] ~= nil }
end

--- Change one of its props: `patch` { model, label, solid }. It is shown again so, on every game. Answers true, or false
--- and why.
function DirectorLive.setProp(src, t, patch)
    if not (t and t.kind == 'prop' and things[t.id] == t) then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    patch = type(patch) == 'table' and patch or {}
    local was = { model = t.model, label = t.label, solid = t.solid }
    if patch.model ~= nil then
        if t.weapon then return false, 'A Fixed Weapon is its gun: put another one down' end
        local m = modelName(patch.model)
        if not m then return false, 'That is not a model name' end
        t.model = m
        t.label = type(patch.label) == 'string' and Sanitize.string(patch.label, 60) or m
    end
    if patch.solid ~= nil then t.solid = patch.solid == true end
    local ok, why = PropSets.show(CORE, t.set, propSpec(t))
    if not ok then
        t.model, t.label, t.solid = was.model, was.label, was.solid
        return false, why or 'It could not be shown again'
    end
    fxMoved(t.id)
    DirectorLive.log(src, patch.model ~= nil and ('changed a prop (%s) to %s'):format(was.model, t.model)
        or ('made a prop (%s) %s'):format(t.model, t.solid == false and 'not solid' or 'solid'), t.coords)
    return true
end

local function hideList()
    local out = {}
    for _, t in pairs(things) do
        if t.kind == 'hide' then out[#out + 1] = { id = t.id, model = t.hash, x = t.coords.x, y = t.coords.y, z = t.coords.z } end
    end
    return out
end

pushHides = function() TriggerClientEvent('whip_core:client:liveHides', -1, hideList()) end

-- A character coming on: the map props hidden now.
Character.onLife('loaded', function(e)
    if e and e.source then TriggerClientEvent('whip_core:client:liveHides', e.source, hideList()) end
end)

--- Hide one of the map's props on every game (Remove for everyone). Answers the thing, or false and why.
function DirectorLive.hideMap(src, m)
    local p = Players[src]
    if not p or not p.userId then return false, 'Load a character first' end
    local spec, why = readMap(m)
    if not spec then return false, why end
    -- (The same one again is the one hidden already.)
    for _, t in pairs(things) do
        if t.kind == 'hide' and t.hash == spec.hash and #(vector3(t.coords.x, t.coords.y, t.coords.z)
            - vector3(spec.coords.x, spec.coords.y, spec.coords.z)) < 0.05 then return t end
    end
    local mine, all = countOf(p.userId)
    if mine >= MAX_EACH then return false, ('You have %d things up: remove some first'):format(mine) end
    if all >= MAX_ALL then return false, ('There are %d live things up: some must go first'):format(all) end
    local id = nextId + 1
    nextId = id
    local t = { id = id, kind = 'hide', userId = p.userId, by = p.fullName or ('player ' .. src),
                model = spec.name or tostring(spec.hash), label = spec.name, hash = spec.hash,
                coords = spec.coords, rot = spec.rot, made = os.time() }
    things[id] = t
    pushHides()
    DirectorLive.log(src, ('hid a map prop (%s) for everyone'):format(t.model), t.coords)
    return t
end

--- Take one of the map's props over: hidden for everyone, and a prop of this file's in its place (`model`: another model
--- there instead). Answers the new prop's view, or false and why.
function DirectorLive.takeOver(src, m, model, label)
    local spec, why = readMap(m)
    if not spec then return false, why end
    local name = spec.name or tostring(spec.hash)
    if model ~= nil then
        name = modelName(model)
        if not name then return false, 'That is not a model name' end
    end
    local h, hwhy = DirectorLive.hideMap(src, m)
    if not h then return false, hwhy end
    local v, vwhy = DirectorLive.make(src, { kind = 'prop', model = name, coords = spec.coords, rot = spec.rot,
        label = model ~= nil and (type(label) == 'string' and label or name) or spec.name })
    if not v then
        DirectorLive.remove(nil, h.id)
        return false, vwhy
    end
    things[v.id].replaces = h.id
    return v
end

--- Put the map's own prop back where one of its props took its place: that prop and the hide both go. Answers true, or
--- false and why.
function DirectorLive.restore(src, t)
    if not (t and t.kind == 'prop' and things[t.id] == t) then return false, 'It is not there any more' end
    if not mayChange(src, t) then return false, 'That is someone else\'s' end
    local h = t.replaces and things[t.replaces]
    DirectorLive.remove(src, t.id)
    if h then DirectorLive.remove(src, h.id) end
    return true
end

-- ============================================
-- Effects (the Object Viewer's Effects, on a prop or a ground item)
-- ============================================
--
-- Smoke, sparks, flames, steam or a glow on something, for everyone, until it is switched off, the thing goes, or the
-- server restarts. Each game draws them itself (client/live_world.lua), on its own copy of the thing, so the server
-- sends the whole list when it changes and when a character loads. A target is what the Object Viewer names
-- (server/object_viewer.lua): { live = a prop made here } (followed through its moves), { wire, i } (another set's
-- piece), { ground = id }, { net = netId }, or { at } alone (the map's own prop, which never moves).
--
-- An effect is its maker's, by account, as a thing is: only they (or a full admin) turn it off, Clear takes theirs
-- with their things, the Dungeon Mode page lists them, and one account has at most MAX_FX_EACH on.

local FX_KINDS = { smoke = true, sparks = true, flames = true, steam = true, light = true }
local MAX_FX = 80
local MAX_FX_EACH = 20
local effects = {}   -- [key .. ':' .. kind] = { kind, key, target, at = { x, y, z }, userId, by, what }

--- Is the effect's thing still there? (Gone: the effect goes too.)
local function fxAlive(e)
    local t = e.target
    if t.live then return things[t.live] ~= nil end
    if t.ground then return GroundItems.getById(t.ground) ~= nil end
    if t.wire then return PropSets.byWire(t.wire) ~= nil end
    if t.net then
        local ent = NetworkGetEntityFromNetworkId(t.net)
        return ent ~= nil and ent ~= 0 and DoesEntityExist(ent)
    end
    return true
end

--- What each game is sent: { kind, wire, i, ground, net, x, y, z } (not one whose thing has gone).
local function fxList()
    local out = {}
    for _, e in pairs(effects) do
        if fxAlive(e) then
            local t, at = e.target, e.at
            local v = { kind = e.kind, ground = t.ground, net = t.net, wire = t.wire, i = t.i, x = at.x, y = at.y, z = at.z }
            if t.live then
                local th = things[t.live]
                v.wire, v.i, at = PropSets.wireOf(CORE, th.set), 1, th.coords
                v.x, v.y, v.z = at.x, at.y, at.z
            end
            out[#out + 1] = v
        end
    end
    return out
end

local function pushFx() TriggerClientEvent('whip_core:client:liveEffects', -1, fxList()) end

fxMoved = function(id)
    for _, e in pairs(effects) do
        if e.target.live == id then pushFx() return end
    end
end

Character.onLife('loaded', function(e)
    if e and e.source then TriggerClientEvent('whip_core:client:liveEffects', e.source, fxList()) end
end)

-- What has gone takes its effects with it (and a live prop moved is sent again where it went: its set is new).
Every('dungeon effects', 5000, function()
    if next(effects) == nil then return 15000 end
    local dropped = false
    for k, e in pairs(effects) do
        if not fxAlive(e) then effects[k] = nil dropped = true end
    end
    if dropped then pushFx() end
end)

--- Which effects are on a target now: { smoke = true, ... } (its switches on the Object Viewer).
function DirectorLive.effectsOn(key)
    local on = {}
    for kind in pairs(FX_KINDS) do on[kind] = effects[key .. ':' .. kind] ~= nil end
    return on
end

--- Turn one on or off: `ft` { key, target, at }. Answers whether it is on now, or false and why.
function DirectorLive.toggleEffect(src, ft, kind)
    if not FX_KINDS[kind] then return nil, 'No such effect' end
    if type(ft) ~= 'table' or type(ft.key) ~= 'string' or type(ft.at) ~= 'table' then return nil, 'On what?' end
    local k = ft.key .. ':' .. kind
    local p = Players[src]
    if effects[k] then
        local e = effects[k]
        if not mayChange(src, e) then return nil, ('That %s is %s\'s'):format(kind, tostring(e.by)) end
        effects[k] = nil
        pushFx()
        DirectorLive.log(src, ('turned %s off on %s'):format(kind, ft.what or 'something'), ft.at)
        return false
    end
    if not p or not p.userId then return nil, 'Load a character first' end
    local n, mine = 0, 0
    for _, e in pairs(effects) do
        n = n + 1
        if e.userId == p.userId then mine = mine + 1 end
    end
    if mine >= MAX_FX_EACH then return nil, ('You have %d effects on: turn some off first'):format(mine) end
    if n >= MAX_FX then return nil, ('There are %d effects on already: turn some off first'):format(n) end
    effects[k] = { kind = kind, key = ft.key, target = ft.target or {}, at = ft.at, userId = p.userId,
                   by = p.fullName or ('player ' .. src), what = type(ft.what) == 'string' and DirectorKit.cut(ft.what, 80) or nil }
    pushFx()
    DirectorLive.log(src, ('turned %s on on %s'):format(kind, ft.what or 'something'), ft.at)
    return true
end

--- An effect as the Dungeon Mode page lists it.
local function fxView(k, e, src)
    local p = Players[src]
    return { key = k, kind = e.kind, what = e.what, by = e.by, at = e.at, mine = p ~= nil and p.userId == e.userId }
end

-- ============================================
-- The page and the builder (client/director_live.lua, html/js/wp/director.js Dungeon Mode)
-- ============================================

local function cb(name, params, handler, rate)
    SecureCallback('whip_core:director:' .. name, {
        permission = LIVE,
        rateLimit = rate or 200,
        burst = 6,
        params = params,
    }, handler)
end

cb('liveMake', { { 'spec', 'any' } }, function(source, _, spec)
    return DirectorLive.make(source, spec)
end, 250)

cb('liveMove', { { 'id', 'id' }, { 'coords', 'any' }, { 'rot', 'any' } }, function(source, _, id, coords, rot)
    return DirectorLive.move(source, id, coords, rot)
end, 150)

cb('liveRemove', { { 'id', 'id' } }, function(source, _, id)
    local ok, why = DirectorLive.remove(source, id)
    if not ok then return false, why end
    return { ok = true }
end, 150)

--- A Fixed Weapon of theirs fired from their game (its Fire, client/director_live.lua): only logged here.
SecureEvent('whip_core:server:liveFired', {
    permission = LIVE,
    rateLimit = 300,
    burst = 5,
    params = { { 'id', 'id' }, { 'shots', 'int', 1, 20 } },
}, function(source, _, id, shots)
    local t = things[id]
    if not t or t.kind ~= 'prop' or not t.weapon then return end
    DirectorLive.log(source, ('fired a Fixed Weapon (%s, %d %s)'):format(t.weapon, shots, shots == 1 and 'shot' or 'shots'), t.coords)
end)

--- Everything I made (`all`: an admin's, everyone's). Answers how many went.
cb('liveClear', { { 'all', 'bool' } }, function(source, _, all)
    if all and not DirectorLive.isAdmin(source) then return false, 'Only an admin can clear everyone\'s' end
    local p = Players[source]
    local ids = {}
    for id, t in pairs(things) do
        if all or (p and t.userId == p.userId) then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do
        local t = things[id]
        if t then unmake(t, true) end
    end
    -- Their effects go with their things
    local fx = 0
    for k, e in pairs(effects) do
        if all or (p and e.userId == p.userId) then effects[k] = nil fx = fx + 1 end
    end
    -- Every game told once (unmake was quiet)
    pushHides()
    pushFx()
    DirectorLive.log(source, ('cleared %s (%d, and %d effects)'):format(all and 'every live thing' or 'everything they made', #ids, fx))
    return { removed = #ids, effects = fx }
end, 1000)

--- One effect off, from the Dungeon Mode page (its maker's, or a full admin's).
cb('liveFxOff', { { 'key', 'string', 160 } }, function(source, _, key)
    local e = effects[key]
    if not e then return false, 'It is off already' end
    if not mayChange(source, e) then return false, ('That %s is %s\'s'):format(e.kind, tostring(e.by)) end
    effects[key] = nil
    pushFx()
    DirectorLive.log(source, ('turned %s off on %s'):format(e.kind, e.what or 'something'), e.at)
    return { ok = true }
end, 200)

--- What is up: mine, and (an admin's) everyone else's. { mine, others, admin, max }
cb('liveList', {}, function(source)
    local p = Players[source]
    local admin = DirectorLive.isAdmin(source)
    local mine, others = {}, {}
    for _, t in pairs(things) do
        if p and t.userId == p.userId then mine[#mine + 1] = view(t, source)
        elseif admin then others[#others + 1] = view(t, source) end
    end
    local function newest(a, b) return a.id > b.id end
    table.sort(mine, newest)
    table.sort(others, newest)
    -- Effects on: theirs, and (an admin's) everyone's
    local fx = {}
    for k, e in pairs(effects) do
        if (p and e.userId == p.userId) or admin then fx[#fx + 1] = fxView(k, e, source) end
    end
    table.sort(fx, function(a, b) return a.key < b.key end)
    return { mine = mine, others = others, admin = admin, max = MAX_EACH, effects = fx, maxEffects = MAX_FX_EACH }
end, 300)
