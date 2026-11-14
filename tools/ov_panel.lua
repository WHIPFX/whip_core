-- ============================================
-- Dev Tools — the Object Viewer's options
-- ============================================
--
-- G on what the object viewer picked out (tools/objectviewer.lua) opens this: a column down the right of the screen
-- listing what can be done to it, grouped and coloured as the Director's card list is (html/js/ov-panel.js). An
-- option runs at once, flips a switch, or opens a page of its own (a stat, an owner, a model); Back returns to the
-- list. What it is decides the list:
--
--   whip's saved car   garage, condition, seats, in the world, storage, Open in WHIP Admin Menu, Move
--   any other car      Remove, Fix, Explode, make it a player's car, Move
--   a player           health, control, look and moves, character, Kick and Ban
--   an NPC             Remove, Kill, Set on fire, Move (whip's own NPCs: none, their system looks after them)
--   a networked object Move, Turn invisible, Freeze in place, Swap for a Dungeon prop, Remove
--   the map's own prop Make it a Dungeon prop, Change model, Remove for everyone (hidden on every game until a restart)
--   anything           Copy details (what G did before)
--
-- And Dungeon Mode's own (server/director/live.lua), for their maker or a full admin: a Dungeon NPC's fights and
-- switches, a Dungeon car's Key settings, a Dungeon prop's Move, Change model, Solid and Remove.
--
-- Other resources add their own (Whip.objectViewerOption, in
-- @whip_core/lib/satellite.lua): whip_autos' Open Whiplash.
--
-- WHERE THINGS RUN. The server answers what the thing is and does what it can (server/object_viewer.lua); the game
-- that owns an entity does the rest (client/ov_effects.lua). What is the admin's own (a seat, a screen, the
-- clipboard, Move) is done here.

OvPanel = {}

---@class OvPanelState
---@field entity integer
---@field info table
---@field target table
---@field desc table
---@field note string|nil
---@field opts table|nil
---@field options table|nil
---@field rewire table|nil

---@type OvPanelState|nil
local panel = nil       -- the open one: { entity, info, target, desc, options }
local opening = false
local openGen = 0       -- each open's own number: a close while it is still opening moves it on, and it never opens
local away = false      -- an option has the screen (Move, the emote menu): the panel comes back after

local GROUPS = {
    info      = { title = 'Info',         tint = 'slate',  order = 1 },
    live      = { title = 'Dungeon NPC',  tint = 'amber',  order = 1.5 },   -- (Dungeon Mode's: server/director/live.lua)
    liveCar   = { title = 'Dungeon car',  tint = 'amber',  order = 1.5 },
    liveProp  = { title = 'Dungeon prop', tint = 'amber',  order = 1.5 },
    mapProp   = { title = 'Map prop',     tint = 'teal',   order = 1.6 },
    pile      = { title = 'Ground item',  tint = 'violet', order = 1.6 },
    fx        = { title = 'Effects',      tint = 'red',    order = 7 },
    make      = { title = 'Make for them', tint = 'amber', order = 1.5 },
    garage    = { title = 'Garage',       tint = 'amber',  order = 2 },
    health    = { title = 'Health',       tint = 'green',  order = 2 },
    condition = { title = 'Condition',    tint = 'teal',   order = 3 },
    control   = { title = 'Control',      tint = 'blue',   order = 3 },
    seats     = { title = 'Seats',        tint = 'blue',   order = 4 },
    look      = { title = 'Look & moves', tint = 'teal',   order = 4 },
    world     = { title = 'In the world', tint = 'green',  order = 5 },
    character = { title = 'Character',    tint = 'violet', order = 5 },
    storage   = { title = 'Storage',      tint = 'violet', order = 6 },
    server    = { title = 'Server',       tint = 'red',    order = 9 },
}
local TINTS = { blue = true, teal = true, green = true, amber = true, red = true, violet = true, slate = true }

local function savedCar(t, d) return t.kind == 'vehicle' and d.whip == true end
local function otherCar(t, d) return t.kind == 'vehicle' and d.whip ~= true and t.ref ~= nil end
local function aPlayer(t) return t.kind == 'player' and t.ref ~= nil end
-- (A Dungeon Master's NPC is whip's own, made to be changed: server/director/live.lua.)
local function wildNpc(t, d) return t.kind == 'npc' and t.ref ~= nil and (d.whip ~= true or d.live ~= nil) end
local function liveNpc(t, d) return t.kind == 'npc' and t.ref ~= nil and type(d.live) == 'table' and d.live.mayChange == true end
local function liveCar(t, d) return t.kind == 'vehicle' and t.ref ~= nil and type(d.live) == 'table' and d.live.mayChange == true end
-- Objects, by what made them (targetOf): another resource's networked one, a prop made in Dungeon Mode (its maker's or
-- a full admin's), the map's own.
local function netObj(t) return t.prop == 'net' and t.ref ~= nil end
local function liveProp(t, d) return t.prop == 'set' and t.ref ~= nil and type(d.live) == 'table' and d.live.mayChange == true end
local function liveModel(t, d) return liveProp(t, d) and not d.live.weapon end
local function liveSwap(t, d) return liveProp(t, d) and d.live.replaces == true end
local function mapProp(t) return t.prop == 'map' and t.ref ~= nil end
local function aPile(t, d) return t.prop == 'pile' and t.ref ~= nil and type(d.pile) == 'table' end
local function stackPile(t, d) return aPile(t, d) and d.pile.stack == true end
-- Effects go on any prop the server can name (not another script's object only this game has).
local function fxThing(t) return t.kind == 'object' and t.ref ~= nil end
local function anything() return true end
local function lockedCar(_, d) return d.locked == true end

-- What only a full admin may do (the server answers `admin`): what lasts past a restart, and the admin's own tools. A
-- Dungeon Master (director.live) sees them greyed. The server refuses them as well (server/object_viewer.lua PERMANENT;
-- kick, ban, the inventory and the storage are gated where they are sent).
local ADMIN_ONLY = {
    ['veh.garage'] = true, ['veh.stat'] = true, ['veh.delete'] = true, ['veh.owner'] = true, ['veh.own'] = true,
    ['ply.stat'] = true, ['ply.creator'] = true, ['ply.walk'] = true,
    ['pile.move'] = true, ['pile.item'] = true, ['pile.amount'] = true, ['pile.remove'] = true,
    admin = true, trunk = true, glovebox = true, inventory = true, kick = true, ban = true,
}

-- how: 'act' (the server does it), 'toggle' (the server flips it: `hold` names its state), 'page' (a page of its
-- own first: `page` names it, the page's button sends `act`), 'local' (done here: LOCAL below).
---@class OvOption
---@field key string
---@field group string
---@field how 'act'|'toggle'|'page'|'local'
---@field when fun(t: table, d: table): boolean
---@field label string
---@field hint string
---@field page string|nil
---@field hold string|nil
---@field danger boolean|nil
---@field adminWhen (fun(t: table, d: table): boolean)|nil
---@field lockedWhy string|nil

---@type OvOption[]
local OPTIONS = {
    { key = 'copy', group = 'info', how = 'local', when = anything, label = 'Copy details',
      hint = 'The model\'s name, its hash and where it stands, to the clipboard.' },

    -- whip's saved cars
    { key = 'veh.garage', group = 'garage', how = 'act', when = savedCar, label = 'Return to garage',
      hint = 'Out of the world and into its garage, whoever is in it.' },
    { key = 'veh.owner', group = 'garage', how = 'page', page = 'owner', when = savedCar, label = 'Change owner',
      hint = 'Give it to someone else: anyone online, or a character found by name.' },
    { key = 'admin', group = 'garage', how = 'local', when = savedCar, label = 'Open in WHIP Admin Menu',
      hint = 'Its page in /whip → Vehicles.' },
    { key = 'veh.delete', group = 'garage', how = 'page', page = 'confirm', danger = true, when = savedCar,
      label = 'Delete from whip database', hint = 'Gone for good: the car, its record, its trunk and glovebox.' },
    -- (`adminWhen`: a full admin's only on this thing, as ADMIN_ONLY. Fix on a saved car writes its record; drive and
    -- ride on a locked one pass its lock: Josh, 1 Nov.)
    { key = 'veh.fix', group = 'condition', how = 'act', when = savedCar, label = 'Fix', adminWhen = anything,
      hint = 'Engine, body and dirt as new, and its saved damage cleared.' },
    { key = 'veh.stat', group = 'condition', how = 'page', page = 'vstats', when = savedCar, label = 'Set stat',
      hint = 'Fuel, and every stat another resource gives cars.' },
    { key = 'veh.explode', group = 'condition', how = 'act', when = savedCar, label = 'Explode',
      hint = 'Blows it up where it stands.' },
    { key = 'drive', group = 'seats', how = 'local', when = savedCar, label = 'Become driver', adminWhen = lockedCar,
      lockedWhy = 'It is locked: only an admin can get in past its lock', hint = 'Into the driver\'s seat, if nobody is in it.' },
    { key = 'ride', group = 'seats', how = 'local', when = savedCar, label = 'Become passenger', adminWhen = lockedCar,
      lockedWhy = 'It is locked: only an admin can get in past its lock', hint = 'Into the first free passenger seat.' },
    { key = 'veh.eject', group = 'seats', how = 'act', when = savedCar, label = 'Eject all players',
      hint = 'Everyone in it, players and NPCs, out onto the road.' },
    { key = 'veh.hidden', group = 'world', how = 'toggle', hold = 'hidden', when = savedCar, label = 'Turn invisible',
      hint = 'Nobody sees it while this is on. Its tag here still shows where it is.' },
    { key = 'veh.invincible', group = 'world', how = 'toggle', hold = 'invincible', when = savedCar,
      label = 'Set invincibility', hint = 'Nothing damages it while this is on.' },
    { key = 'veh.frozen', group = 'world', how = 'toggle', hold = 'frozen', when = savedCar, label = 'Freeze in place',
      hint = 'It cannot move, driven or pushed, while this is on.' },
    { key = 'move', group = 'world', how = 'local', when = savedCar, label = 'Move',
      hint = 'Drag it and turn it with the furnisher\'s arrows and rings, from where you stand.' },
    { key = 'trunk', group = 'storage', how = 'local', when = savedCar, label = 'Inspect trunk storage',
      hint = 'Its trunk, open from here, past the lock.' },
    { key = 'glovebox', group = 'storage', how = 'local', when = savedCar, label = 'Inspect glovebox storage',
      hint = 'Its glovebox, open from here, past the lock.' },

    -- any other car
    { key = 'veh.remove', group = 'world', how = 'act', when = otherCar, label = 'Remove',
      hint = 'Takes it out of the world.' },
    { key = 'veh.fix', group = 'condition', how = 'act', when = otherCar, label = 'Fix',
      hint = 'Engine, body and dirt as new.' },
    { key = 'veh.explode', group = 'condition', how = 'act', when = otherCar, label = 'Explode',
      hint = 'Blows it up where it stands.' },
    { key = 'veh.own', group = 'garage', how = 'page', page = 'own', when = otherCar,
      label = 'Make vehicle permanently owned by player',
      hint = 'A saved car of theirs from now on, made from this one where it stands, paint and parts kept.' },
    { key = 'move', group = 'world', how = 'local', when = otherCar, label = 'Move',
      hint = 'Drag it and turn it with the furnisher\'s arrows and rings, from where you stand.' },

    -- players: what a Dungeon Master makes for them (theirs, until a restart or Remove)
    { key = 'ply.car', group = 'make', how = 'page', page = 'car', when = aPlayer, label = 'Spawn a car for them',
      hint = 'A temporary car beside them, unlocked, its key in their pocket. It is yours: it lasts until a restart or until you remove it.' },
    { key = 'ply.hunt', group = 'make', how = 'page', page = 'hunt', when = aPlayer, label = 'Send NPCs after them',
      hint = 'Armed NPCs come for them from nearby. They are yours: Remove takes them away, Calm down stops one.' },

    -- players
    { key = 'ply.heal', group = 'health', how = 'act', when = aPlayer, label = 'Restore health',
      hint = 'Health to full.' },
    { key = 'ply.armour', group = 'health', how = 'act', when = aPlayer, label = 'Restore armour',
      hint = 'Armour to full.' },
    { key = 'ply.revive', group = 'health', how = 'act', when = aPlayer, label = 'Revive',
      hint = 'Back on their feet where they lie, at full health.' },
    { key = 'ply.kill', group = 'health', how = 'act', when = aPlayer, label = 'Kill',
      hint = 'Down, as any death: their death screen, revive and respawn.' },
    { key = 'ply.fire', group = 'health', how = 'act', when = aPlayer, label = 'Set on fire',
      hint = 'They burn until it goes out.' },
    { key = 'ply.frozen', group = 'control', how = 'toggle', hold = 'frozen', when = aPlayer, label = 'Freeze in place',
      hint = 'They cannot move while this is on. They are told.' },
    { key = 'ply.escort', group = 'control', how = 'act', when = aPlayer, label = 'Force escort',
      hint = 'Brought to your side and held, as the escort holds anyone (out of a car first).' },
    { key = 'ply.noCombat', group = 'control', how = 'toggle', hold = 'noCombat', when = aPlayer,
      label = 'Disable combat abilities', hint = 'No aiming, shooting, punching or drive-bys while this is on. They are told.' },
    { key = 'move', group = 'control', how = 'local', when = aPlayer, label = 'Move',
      hint = 'Drag them and turn them with the furnisher\'s arrows and ring, from where you stand.' },
    { key = 'ply.model', group = 'look', how = 'page', page = 'model', when = aPlayer, label = 'Change model',
      hint = 'Any ped, from the Director\'s NPC list, until you put their own look back.' },
    { key = 'ply.creator', group = 'look', how = 'act', when = aPlayer, label = 'Force open character editor',
      hint = 'Their character editor opens on their screen.' },
    { key = 'ply.walk', group = 'look', how = 'page', page = 'walk', when = aPlayer, label = 'Force change movement style',
      hint = 'Their walk, kept as if they had picked it.' },
    { key = 'emote', group = 'look', how = 'local', when = aPlayer, label = 'Force emote',
      hint = 'The emote menu: each one you pick, they play. Stop ends it.' },
    { key = 'ply.stat', group = 'character', how = 'page', page = 'pstats', when = aPlayer, label = 'Adjust stats',
      hint = 'Health, armour, hunger, thirst and every stat another resource gives players.' },
    { key = 'inventory', group = 'character', how = 'local', when = aPlayer, label = 'Inspect inventory',
      hint = 'Their pockets, open here.' },
    { key = 'admin', group = 'character', how = 'local', when = aPlayer, label = 'Open in WHIP Admin Menu',
      hint = 'Their page in /whip → Players.' },
    { key = 'kick', group = 'server', how = 'page', page = 'kick', danger = true, when = aPlayer,
      label = 'Kick from server', hint = 'Off the server with a reason. They can join again.' },
    { key = 'ban', group = 'server', how = 'page', page = 'ban', danger = true, when = aPlayer,
      label = 'Ban from server', hint = 'Off the server, and kept off for a time or for good.' },

    -- a Dungeon Master's NPC: its maker's (or a full admin's) to set up
    { key = 'live.attack', group = 'live', how = 'page', page = 'pick', when = liveNpc, label = 'Attack a player',
      hint = 'They go for whoever you pick, until Calm down.' },
    { key = 'live.follow', group = 'live', how = 'page', page = 'pick', when = liveNpc, label = 'Follow a player',
      hint = 'They walk after whoever you pick, until Calm down.' },
    { key = 'live.calm', group = 'live', how = 'act', when = liveNpc, label = 'Calm down',
      hint = 'No more fighting or following: they stand where they are.' },
    { key = 'live.weapon', group = 'live', how = 'page', page = 'weapon', when = liveNpc, label = 'Give a weapon',
      hint = 'In their hands from now on. They are made again with it where they stand, and stop whatever they were doing.' },
    { key = 'live.guard', group = 'live', how = 'toggle', hold = 'guard', when = liveNpc, label = 'On guard',
      hint = 'They guard where they stand, and react to trouble round it, while this is on.' },
    { key = 'live.invincible', group = 'live', how = 'toggle', hold = 'invincible', when = liveNpc, label = 'Invincible',
      hint = 'Nothing hurts them while this is on.' },
    { key = 'live.still', group = 'live', how = 'toggle', hold = 'still', when = liveNpc, label = 'Stay put',
      hint = 'They do not move from where they stand while this is on.' },

    -- a Dungeon Master's car: its maker's (or a full admin's) Key settings
    { key = 'live.key', group = 'liveCar', how = 'page', page = 'carkey', when = liveCar, label = 'Key settings',
      hint = 'Where its key is, whether it is locked, and whether only its key opens it. Its key goes when the car goes.' },

    -- a prop made in Dungeon Mode (server/director/live.lua): its maker's, or a full admin's
    { key = 'move', group = 'liveProp', how = 'local', when = liveProp, label = 'Move',
      hint = 'Drag it and turn it with the furnisher\'s arrows and rings. Everyone sees it where you leave it.' },
    { key = 'live.propModel', group = 'liveProp', how = 'page', page = 'propmodel', when = liveModel, label = 'Change model',
      hint = 'Another prop in its place, turned as it is, for everyone.' },
    { key = 'live.solid', group = 'liveProp', how = 'toggle', hold = 'solid', when = liveProp, label = 'Solid',
      hint = 'Players and cars bump into it while this is on. Off, they pass through it.' },
    { key = 'live.restore', group = 'liveProp', how = 'act', when = liveSwap, label = 'Put the map\'s one back',
      hint = 'This one goes, and the map\'s own prop it took the place of is back for everyone.' },
    { key = 'live.propRemove', group = 'liveProp', how = 'act', danger = true, when = liveProp, label = 'Remove',
      hint = 'Takes it out of the world, for everyone.' },

    -- the map's own prop: each game's own from the map, so a change is made for everyone (server/director/live.lua)
    { key = 'map.take', group = 'mapProp', how = 'act', when = mapProp, label = 'Make it a Dungeon prop',
      hint = 'Hidden for everyone, and a Dungeon prop put exactly where it stood: yours to move, change or remove, until a restart.' },
    { key = 'map.model', group = 'mapProp', how = 'page', page = 'propmodel', when = mapProp, label = 'Change model',
      hint = 'Another prop where it stands, for everyone. It becomes a Dungeon prop of yours.' },
    { key = 'map.hide', group = 'mapProp', how = 'act', danger = true, when = mapProp, label = 'Remove for everyone',
      hint = 'Hidden on every game until a restart, or until you Put it back on the Dungeon Mode page.' },

    -- another resource's networked object (or GTA's)
    { key = 'move', group = 'world', how = 'local', when = netObj, label = 'Move',
      hint = 'Drag it and turn it with the furnisher\'s arrows and rings, from where you stand.' },
    { key = 'obj.hidden', group = 'world', how = 'toggle', hold = 'hidden', when = netObj, label = 'Turn invisible',
      hint = 'Nobody sees it while this is on.' },
    { key = 'obj.frozen', group = 'world', how = 'toggle', hold = 'frozen', when = netObj, label = 'Freeze in place',
      hint = 'It cannot move, pushed or knocked, while this is on.' },
    { key = 'obj.swap', group = 'world', how = 'page', page = 'propmodel', when = netObj, label = 'Swap for a Dungeon prop',
      hint = 'Another prop in its place, turned as it is: a Dungeon prop of yours. This one goes.' },
    { key = 'obj.remove', group = 'world', how = 'act', danger = true, when = netObj, label = 'Remove',
      hint = 'Takes it out of the world. The resource that made it may make it again.' },

    -- a ground item (server/ground.lua): saved as it lies, so a full admin's to change
    { key = 'pile.move', group = 'pile', how = 'local', when = aPile, label = 'Move',
      hint = 'Drag it and turn it with the furnisher\'s arrows and rings. It lies exactly where you leave it, for everyone.' },
    { key = 'pile.item', group = 'pile', how = 'page', page = 'item', when = aPile, label = 'Change item',
      hint = 'Another item where it lies, and how many.' },
    { key = 'pile.amount', group = 'pile', how = 'page', page = 'amount', when = stackPile, label = 'Set how many',
      hint = 'More or fewer on the pile.' },
    { key = 'pile.remove', group = 'pile', how = 'act', danger = true, when = aPile, label = 'Remove',
      hint = 'Takes it off the ground: the item is gone, on the item log.' },

    -- effects, for everyone, until switched off (server/director/live.lua)
    { key = 'fx.smoke', group = 'fx', how = 'toggle', hold = 'fx_smoke', when = fxThing, label = 'Smoke',
      hint = 'Smoke rising off it while this is on.' },
    { key = 'fx.sparks', group = 'fx', how = 'toggle', hold = 'fx_sparks', when = fxThing, label = 'Sparks',
      hint = 'Sparks crackling off it while this is on.' },
    { key = 'fx.flames', group = 'fx', how = 'toggle', hold = 'fx_flames', when = fxThing, label = 'Flames',
      hint = 'Flames on it while this is on, for show: they burn nobody.' },
    { key = 'fx.steam', group = 'fx', how = 'toggle', hold = 'fx_steam', when = fxThing, label = 'Steam',
      hint = 'Steam rising off it while this is on.' },
    { key = 'fx.light', group = 'fx', how = 'toggle', hold = 'fx_light', when = fxThing, label = 'Glow',
      hint = 'A warm light on it while this is on.' },
    { key = 'fx.boom', group = 'fx', how = 'act', danger = true, when = fxThing, label = 'Explode',
      hint = 'A real explosion where it stands: it hurts whoever is near.' },

    -- NPCs
    { key = 'npc.remove', group = 'world', how = 'act', when = wildNpc, label = 'Remove', hint = 'Takes them out of the world.' },
    { key = 'npc.kill', group = 'health', how = 'act', when = wildNpc, label = 'Kill', hint = 'Dead where they stand.' },
    { key = 'npc.fire', group = 'health', how = 'act', when = wildNpc, label = 'Set on fire', hint = 'They burn.' },
    { key = 'move', group = 'world', how = 'local', when = wildNpc, label = 'Move',
      hint = 'Drag them and turn them with the furnisher\'s arrows and ring, from where you stand.' },
}

-- ============================================
-- Other resources' options (Whip.objectViewerOption)
-- ============================================

local Registered = {}   -- [id] = { id, owner, label, hint, group, tint, kinds, whip, entry }
local KINDS = { vehicle = true, player = true, npc = true, object = true }

local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

local function text(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ' ')
    if #v > max then v = v:sub(1, max) end
    return v
end

local refresh   -- the open panel's list again (below)

local OptionReg = Registry.new('objectViewerOption', {
    label = 'object viewer option', store = Registered,
    same = false,   -- (a resource that restarts hands in a new entry: every registration replaces)
    onAdd = function() if refresh then refresh() end end,
    onRemove = function() if refresh then refresh() end end,
})

local function optionOf(owner, id, spec, entry)
    if type(id) ~= 'string' or #id > 64 or not id:match('^[%a][%w_]*%.[%a][%w_]*$') then
        return nil, 'an option\'s id is "<your namespace>.<name>", like autos.whiplash'
    end
    if type(spec) ~= 'table' or callable(spec) or spec.__whipOvOption == nil or not callable(entry) then
        return nil, 'use Whip.objectViewerOption (@whip_core/lib/satellite.lua)'
    end
    local label = text(spec.label, 48)
    if not label or label:match('^%s*$') then return nil, id .. ': it needs a label (48 letters at most)' end
    local o = { id = id, owner = owner, label = label, hint = text(spec.hint, 160), entry = entry,
                group = text(spec.group, 24) or owner, tint = TINTS[spec.tint] and spec.tint or 'slate', kinds = {} }
    if spec.whip ~= nil and type(spec.whip) ~= 'boolean' then return nil, id .. ': whip is true, false or left out' end
    o.whip = spec.whip
    if type(spec.kinds) ~= 'table' or callable(spec.kinds) or #spec.kinds == 0 then
        return nil, id .. ': kinds is a list of: vehicle, player, npc, object'
    end
    for _, k in ipairs(spec.kinds) do
        if not KINDS[k] then return nil, ('%s: "%s" is not a kind (vehicle, player, npc, object)'):format(id, tostring(k)) end
        o.kinds[k] = true
    end
    return o
end

--- __RegisterObjectViewerOption(id, spec, entry) -> true | false, why. Through Whip.objectViewerOption only.
exports('__RegisterObjectViewerOption', function(id, spec, entry)
    local owner = Registry.caller()
    local o, why = optionOf(owner, id, spec, entry)
    if not o then return false, why end
    return OptionReg:add(owner, id, o)
end)

--- __RemoveObjectViewerOption(id) -> true | false, why. Only your own.
exports('__RemoveObjectViewerOption', function(id)
    return OptionReg:remove(Registry.caller(), id)
end)

-- ============================================
-- What it is, and its list
-- ============================================

--- The map's own prop: on this game from the map, made by no script (not networked, not a script's, no resource names it).
local function mapObject(entity)
    if NetworkGetEntityIsNetworked(entity) or IsEntityAMissionEntity(entity) then return false end
    local ok, script = pcall(GetEntityScript, entity)
    return not (ok and type(script) == 'string' and script ~= '')
end

--- The thing as the server is asked about it: kind, and its ref (nil: only this game has it, another script's object).
--- An object is `prop` = 'set' (a prop set's piece: each game makes its own, the server knows it by its wire id), 'net'
--- (networked), 'map' (the map's own: the server is sent what it is and where), or 'local' (no ref).
local function targetOf(entity, info)
    local t = { entity = entity, name = info.name, hex = info.hex, model = info.name }
    local etype = GetEntityType(entity)
    if etype == 1 and IsPedAPlayer(entity) then
        t.kind = 'player'
        local idx = NetworkGetPlayerIndexFromPed(entity)
        local sid = idx and idx ~= -1 and GetPlayerServerId(idx) or nil
        if sid and sid > 0 then t.ref = { sid = sid } t.sid = sid end
    elseif etype == 3 then
        t.kind = 'object'
        local pile = GroundPiles.of(entity)
        local wire, index = PropSets.ofEntity(entity)
        local c = GetEntityCoords(entity)
        if pile then
            t.prop, t.pile, t.ref = 'pile', pile, { ground = pile.id }
        elseif wire then
            t.prop, t.ref = 'set', { wire = wire, i = index, at = { x = c.x, y = c.y, z = c.z } }
        elseif NetworkGetEntityIsNetworked(entity) then
            t.prop, t.netId = 'net', NetworkGetNetworkIdFromEntity(entity)
            t.ref = { net = t.netId }
        elseif mapObject(entity) then
            local r = GetEntityRotation(entity, 2)
            t.prop = 'map'
            t.ref = { map = { model = GetEntityModel(entity), name = info.name ~= info.hex and info.name or nil,
                              x = c.x, y = c.y, z = c.z, rx = r.x, ry = r.y, rz = r.z } }
        else
            t.prop = 'local'
        end
    else
        t.kind = etype == 2 and 'vehicle' or etype == 1 and 'npc' or 'object'
        if NetworkGetEntityIsNetworked(entity) then
            t.netId = NetworkGetNetworkIdFromEntity(entity)
            t.ref = { net = t.netId }
        end
    end
    return t
end

local function subLine(t, d)
    -- One made in Dungeon Mode says whose it is.
    if type(d.live) == 'table' then
        local noun = t.kind == 'vehicle' and 'Dungeon car' or t.kind == 'object' and (d.live.weapon and 'Fixed Weapon' or 'Dungeon prop')
            or 'Dungeon NPC'
        return ('%s · made by %s'):format(noun, d.live.mine and 'you' or tostring(d.live.by))
    end
    if t.kind == 'player' then
        return ('Player %s%s'):format(tostring(t.sid or '?'), d.dead and ' · down' or '')
    elseif t.kind == 'vehicle' then
        if d.whip then
            local who = d.owner and d.owner.name and (d.owner.name .. '\'s') or 'no owner'
            return ('#%s · %s · %s'):format(tostring(d.vehicleId), tostring(d.plate or ''), who)
        end
        return (d.temp and 'Temporary car' or 'Street car') .. (d.plate and (' · ' .. d.plate) or '')
    elseif t.kind == 'npc' then
        return d.whip and 'whip\'s own NPC' or 'NPC'
    end
    if t.prop == 'pile' and type(d.pile) == 'table' then
        return ('Ground item · %d %s%s'):format(d.pile.amount or 1, tostring(d.pile.item), d.pile.by and (' · dropped by ' .. d.pile.by) or '')
    end
    if t.prop == 'set' then return 'A script\'s prop (on every game)' end
    if t.prop == 'net' then return 'Networked object' end
    if t.prop == 'map' then return 'Map prop' end
    return 'Another script\'s object (only on your game)'
end

--- What the page lists for this thing, in order, with each switch's state. `extras`: the opening screen's own options
--- (OvPanel.open opts.extras), done there.
local function listFor(t, d, extras)
    local out, groups, seen = {}, {}, {}
    local function group(key, g)
        if seen[key] then return end
        seen[key] = true
        groups[#groups + 1] = { key = key, title = g.title, tint = g.tint, order = g.order }
    end
    for _, x in ipairs(type(extras) == 'table' and extras or {}) do
        local g = GROUPS[x.group] and x.group or 'live'
        group(g, GROUPS[g])
        out[#out + 1] = { key = 'x:' .. tostring(x.key), group = g, label = x.label, hint = x.hint, how = 'local', danger = x.danger == true }
    end
    for _, o in ipairs(OPTIONS) do
        if o.when(t, d) then
            group(o.group, GROUPS[o.group])
            -- `hold` goes too: a switch's press (ovPanelDo) keeps its state under it. `locked`: a full admin's only.
            out[#out + 1] = { key = o.key, group = o.group, label = o.label, hint = o.hint, how = o.how, page = o.page,
                              danger = o.danger == true, hold = o.hold, on = o.hold and ((d.holds or {})[o.hold] == true),
                              locked = (ADMIN_ONLY[o.key] == true or (o.adminWhen ~= nil and o.adminWhen(t, d)))
                                  and d.admin ~= true or nil, lockedWhy = o.lockedWhy }
        end
    end
    for id, r in pairs(Registered) do
        if r.kinds[t.kind] and (r.whip == nil or r.whip == (d.whip == true)) then
            local gk = 'res:' .. r.group
            group(gk, { title = r.group, tint = r.tint, order = 8 })
            out[#out + 1] = { key = 'reg:' .. id, group = gk, label = r.label, hint = r.hint, how = 'local' }
        end
    end
    table.sort(groups, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.title < b.title
    end)
    return out, groups
end

local function walks()
    local out = {}
    for _, w in ipairs(EmoteList and EmoteList.walks or {}) do out[#out + 1] = { cmd = w.cmd, label = w.label } end
    return out
end

--- Give a weapon's list: the weapons an NPC can carry (shared/weapon_catalog.lua: GTA's, and those other resources add,
--- "Pump Shotgun (gunny)"), those this game has. Again when the catalog changes.
local weaponList, weaponListAt
local function weapons()
    if weaponList and weaponListAt == WeaponCatalog.version then return weaponList end
    weaponList, weaponListAt = {}, WeaponCatalog.version
    for _, w in ipairs(WeaponCatalog.list()) do
        if IsWeaponValid(GetHashKey(w.name)) then
            weaponList[#weaponList + 1] = { name = w.name, label = WeaponCatalog.title(w), group = w.group }
        end
    end
    return weaponList
end

--- Spawn a car for them's list: every car this game has (the world builder's Vehicles: client/director.lua).
local function vehicleList()
    local v = DirectorScreen and DirectorScreen.lists and DirectorScreen.lists() or nil
    local out = {}
    for _, p in ipairs(type(v) == 'table' and v.props or {}) do out[#out + 1] = { model = p.model, name = p.name } end
    return out
end

--- Change item's list: every item whip has (Config.Items), by its name. Once.
local itemsCache
local function itemList()
    if itemsCache then return itemsCache end
    itemsCache = {}
    for key, def in pairs(Config.Items or {}) do
        itemsCache[#itemsCache + 1] = { key = key, name = def.name or key, stack = def.stack == true }
    end
    table.sort(itemsCache, function(a, b) return a.name:lower() < b.name:lower() end)
    return itemsCache
end

--- Send NPCs after them: where they come from, on the ground round the player (25 to 40 m off), `n` of them.
local function huntSpots(ped, n)
    local c = GetEntityCoords(ped)
    local out = {}
    for k = 1, n * 3 do
        if #out >= n then break end
        local a = (k / (n * 3)) * math.pi * 2.0 + math.random() * 0.6
        local d = 25.0 + math.random() * 15.0
        local x, y = c.x + math.cos(a) * d, c.y + math.sin(a) * d
        local found, z = GetGroundZFor_3dCoord(x, y, c.z + 40.0, false)
        if found and math.abs(z - c.z) < 15.0 then out[#out + 1] = { x = x, y = y, z = z } end
    end
    return out
end

local function send()
    ---@cast panel -nil   (refresh and open call it only with the panel there)
    local t, d = panel.target, panel.desc
    local options, groups = listFor(t, d, panel.opts and panel.opts.extras)
    panel.options = {}
    for _, o in ipairs(options) do panel.options[o.key] = o end
    SendNUIMessage({
        action = 'ovPanelOpen',
        head = { name = t.kind == 'player' and d.name or (type(d.pile) == 'table' and d.pile.label) or t.name, kind = t.kind,
                 sub = subLine(t, d),
                 pic = type(panel.info.pic) == 'table' and { dir = panel.info.pic.dir, model = panel.info.pic.model } or nil },
        groups = groups, options = options, note = panel.note,
        data = { stats = d.stats, players = d.players, model = d.model, dead = d.dead,
                 walks = t.kind == 'player' and walks() or nil, name = d.name,
                 weapons = liveNpc(t, d) and weapons() or nil, vehicles = t.kind == 'player' and vehicleList() or nil,
                 carKey = d.carKey, pile = d.pile, items = aPile(t, d) and itemList() or nil },
    })
end

refresh = function()
    if panel and not away then send() end
end

-- ============================================
-- Open and close
-- ============================================

local watching = false
local REWIRE_MS = 3000   -- how long a prop shown again may take to be made again here before its options give up on it

--- While it is open: the thing gone (removed, blown away, out of reach) closes it. A prop whose set was shown again
--- (`rewire`: changed from here) is followed to its new copy instead.
local function watch()
    if watching then return end
    watching = true
    CreateThread(function()
        while panel do
            if not away and not DoesEntityExist(panel.entity) then
                local rw = panel.rewire
                local ent = rw and (PropSets.pieceOf(rw.wire, 1))
                if ent then
                    panel.entity, panel.target.entity, panel.rewire = ent, ent, nil
                    ObjectViewer.lockOn(ent)
                    Highlight.set('ovPanel', { selected = ent })
                elseif not (rw and GetGameTimer() < rw.untilAt) then
                    OvPanel.close()
                    UI.Notify('It is not there any more', 'info')
                    break
                end
            end
            Wait(panel and panel.rewire and 100 or 500)
        end
        watching = false
    end)
end

function OvPanel.busy() return panel ~= nil or opening end

--- Open the options for `entity`; `info` is the object viewer's card (name, hex, hash, x, y, z, heading), or nil: made
--- here (ObjectViewer.cardOf). `opts` (the Dungeon Master's world builder, client/director_live.lua):
---   over     it opens over that screen (no other screen may be up otherwise)
---   move     fn(target, back): Move is that screen's own (its markers on the thing); `back()` returns to the list
---   onClose  fn(): it has closed (not when an option stepped aside)
---   onGone   fn(entity): an option took it out of the world (Remove, Swap, Make it a Dungeon prop)
---   onMade   fn(view): an option made a Dungeon Mode thing (server/director/live.lua's view of it: id, wire, ...)
---   extras   that screen's own options, first in the list: { { key, group, label, hint, danger, run = fn(panel) } }
function OvPanel.open(entity, info, opts)
    if panel or opening or not DoesEntityExist(entity) then return end
    opts = type(opts) == 'table' and opts or nil
    if not (opts and opts.over) and MayOpenScreen and not MayOpenScreen('ovPanel') then return end
    info = type(info) == 'table' and info or ObjectViewer.cardOf(entity)
    if not info then return end
    opening = true
    openGen = openGen + 1
    local mine = openGen
    ObjectViewer.lockOn(entity)
    CreateThread(function()
        local t = targetOf(entity, info)
        local d, note = { kind = t.kind, whip = false }, nil
        if t.ref then
            local answer, why = Callback('whip_core:ov:describe', t.ref)
            -- Not answered: only what this game can do on its own (Copy details).
            if type(answer) == 'table' then d = answer else note, t.ref = why or 'The server did not answer', nil end
        end
        -- Closed while the server was asked (a death, the tool switched off): it stays closed
        if mine ~= openGen then return end
        opening = false
        if not DoesEntityExist(entity) then ObjectViewer.lockOn(nil) return end
        panel = { entity = entity, info = info, target = t, desc = d, note = note, opts = opts }
        t.whip = d.whip == true
        t.vehicleId, t.sid = d.vehicleId, t.sid or d.sid
        Highlight.set('ovPanel', { selected = entity })   -- (blue in the world while its options are open)
        Focus.take('ovPanel', { screen = true })
        send()
        watch()
    end)
end

--- Close it (the object viewer closing, an option done with it, Esc). One still opening (its describe on the way) is
--- called off: it never opens.
function OvPanel.close()
    if opening and not panel then
        openGen, opening = openGen + 1, false
        ObjectViewer.lockOn(nil)
        return
    end
    if not panel then return end
    local wasAway = away
    local onClose = not wasAway and panel.opts and panel.opts.onClose or nil
    panel, away = nil, false
    -- An option that had the screen goes too (the object viewer switched off under Move or the emote menu).
    if wasAway then
        if OvMove.active() then OvMove.stop() end
        if Emotes and Emotes.isPicking and Emotes.isPicking() then Emotes.closeMenu() end
    end
    Focus.release('ovPanel')
    SendNUIMessage({ action = 'ovPanelClose' })
    ObjectViewer.lockOn(nil)
    Highlight.set('ovPanel', nil)
    if onClose then
        local ok, err = pcall(onClose)
        if not ok then print('[whip_core:objectviewer] the options\' close failed: ' .. tostring(err)) end
    end
end

--- Step aside for an option that has the screen; `back()` returns to the list (described afresh).
local function stepAside()
    away = true
    Focus.release('ovPanel')
    SendNUIMessage({ action = 'ovPanelClose' })
    local p = panel
    ---@cast p -nil   (an option runs only from the open panel)
    return function()
        if panel ~= p then return end
        away = false
        if not DoesEntityExist(p.entity) then OvPanel.close() return end
        panel = nil
        OvPanel.open(p.entity, p.info, p.opts)
    end
end

-- ============================================
-- Options done here
-- ============================================

--- Into a seat of the car: the driver's (-1), or the first free passenger seat.
local function takeSeat(veh, driver, admin)
    local ped = PlayerPedId()
    -- Past a player's car's lock is a full admin's (Josh, 1 Nov): getting out of it unlocks it. Read again now.
    if not admin and Vehicles.isLocked(veh) then return false, 'It is locked: only an admin can get in past its lock' end
    local seat
    if driver then
        local d = GetPedInVehicleSeat(veh, -1)
        if d == ped then return false, 'You are driving it' end
        if d ~= 0 then return false, 'Someone is in the driver\'s seat: Eject all players first' end
        seat = -1
    else
        for s = 0, GetVehicleMaxNumberOfPassengers(veh) - 1 do
            if IsVehicleSeatFree(veh, s) then seat = s break end
        end
        if not seat then return false, 'No passenger seat is free' end
    end
    TaskWarpPedIntoVehicle(ped, veh, seat)
    return true
end

local LOCAL = {}

LOCAL.copy = function(p)
    ObjectViewer.copy(p.info)
    return { ok = true, text = 'Copied' }
end

LOCAL.drive = function(p)
    local ok, why = takeSeat(p.entity, true, p.desc.admin == true)
    if not ok then return { ok = false, text = why } end
    OvPanel.close()
    return { ok = true, close = true }
end

LOCAL.ride = function(p)
    local ok, why = takeSeat(p.entity, false, p.desc.admin == true)
    if not ok then return { ok = false, text = why } end
    OvPanel.close()
    return { ok = true, close = true }
end

local function openStorage(p, kind)
    local vid = p.desc.vehicleId
    OvPanel.close()
    TriggerServerEvent('whip_core:server:vmOpenStorage', vid, kind)
    return { ok = true, close = true }
end
LOCAL.trunk = function(p) return openStorage(p, 'trunk') end
LOCAL.glovebox = function(p) return openStorage(p, 'glovebox') end

LOCAL.admin = function(p)
    local d = p.desc
    local section, focus = 'vehicles', { vehicleId = d.vehicleId }
    if p.target.kind == 'player' then section, focus = 'playerManager', { userId = d.userId } end
    OvPanel.close()
    CreateThread(function() WhipPanelOpen(section, focus) end)
    return { ok = true, close = true }
end

LOCAL.inventory = function(p)
    local charId = p.desc.charId
    OvPanel.close()
    TriggerServerEvent('whip_core:server:openPlayerInventory', charId)
    return { ok = true, close = true }
end

LOCAL.emote = function(p)
    if not (Emotes and Emotes.pickFor) then return { ok = false, text = 'The emote menu is not here' } end
    local back = stepAside()
    local ref = p.target.ref
    local ok = Emotes.pickFor(function(cmd)
        CreateThread(function()
            local answer, why = Callback('whip_core:ov:act', ref, 'ply.emote', { cmd = cmd or false })
            if type(answer) ~= 'table' then UI.Notify(why or 'That did not work', 'error') end
        end)
    end, { onClose = back })
    -- (Stepped aside already: the list that comes back is a new one, so the reason is a toast.)
    if not ok then back() UI.Notify('The emote menu is busy', 'error') end
    return { ok = ok == true, close = true }
end

LOCAL.move = function(p)
    local back = stepAside()
    p.target.label = p.desc.name
    -- A prop made in Dungeon Mode: each game has its own copy, so the server hears where it was left (its set is shown
    -- there again, for everyone).
    local live = p.target.prop == 'set' and type(p.desc.live) == 'table' and p.desc.live or nil
    p.target.liveId = live and live.id or nil
    if live then
        p.target.onPlaced = function(x, y, z, rx, ry, rz)
            CreateThread(function()
                local v, w = Callback('whip_core:director:liveMove', live.id, { x = x, y = y, z = z, heading = rz % 360.0 },
                    { x = rx, y = ry })
                if type(v) ~= 'table' then UI.Notify(w or 'Its new place was not kept', 'error') end
            end)
        end
    end
    -- Over the Dungeon Master's world builder: its own markers move it (client/director_live.lua).
    local own = p.opts and p.opts.move
    local ok, why
    if own then ok, why = own(p.target, back) else ok, why = OvMove.start(p.target, back) end
    if not ok then back() UI.Notify(why or 'It cannot be moved', 'error') end
    return { ok = ok == true, close = true }
end

--- A ground item's Move: its object here moved with the markers, and the server told where it was left (it lies there
--- for everyone from then on: a full admin's, ADMIN_ONLY).
LOCAL['pile.move'] = function(p)
    local ref = p.target.ref
    p.target.onPlaced = function(x, y, z, rx, ry, rz)
        CreateThread(function()
            local r, w = Callback('whip_core:ov:act', ref, 'pile.place', { x = x, y = y, z = z, heading = rz % 360.0, rx = rx, ry = ry })
            if type(r) ~= 'table' then UI.Notify(w or 'Its new place was not kept', 'error') end
        end)
    end
    return LOCAL.move(p)
end

LOCAL.kick = function(p, arg)
    local reason = type(arg) == 'table' and text(arg.reason, 200) or nil
    if not reason or reason:match('^%s*$') then reason = 'Kicked by admin' end
    TriggerServerEvent('whip_core:server:pmKick', p.desc.sid, reason)
    OvPanel.close()
    return { ok = true, close = true }
end

LOCAL.ban = function(p, arg)
    arg = type(arg) == 'table' and arg or {}
    local reason = text(arg.reason, 500)
    if not reason or reason:match('^%s*$') then return { ok = false, text = 'Say why: it is kept with the ban' } end
    local permanent = arg.permanent == true
    local seconds = math.floor(tonumber(arg.seconds) or 0)
    if not permanent and seconds <= 0 then return { ok = false, text = 'Pick how long' } end
    TriggerServerEvent('whip_core:server:pmBan', p.desc.userId, reason, permanent and 0 or seconds, permanent)
    OvPanel.close()
    return { ok = true, close = true }
end

--- Make it a player's car: what it looks like now goes with it (its paint and parts), and its model's name.
local function makeOwned(p, arg)
    local sid = type(arg) == 'table' and tonumber(arg.sid)
    if not sid then return { ok = false, text = 'Pick who it is for' } end
    local props = GetVehicleProperties(p.entity)
    return { act = { sid = sid, model = p.target.model, props = props } }
end

--- Someone else's option: the panel closes and theirs runs (in a thread there).
local function runRegistered(p, id)
    local r = Registered[id]
    if not r then return { ok = false, text = 'That option is not here any more' } end
    local t = p.target
    local c = GetEntityCoords(p.entity)
    local payload = { target = {
        kind = t.kind, entity = p.entity, netId = t.netId, whip = t.whip, vehicleId = t.vehicleId, serverId = t.sid,
        model = t.model, name = t.kind == 'player' and p.desc.name or t.name,
        coords = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(p.entity) },
    } }
    OvPanel.close()
    local ok, res = pcall(r.entry, 'select', payload)
    if not ok then
        print(('[whip_core:objectviewer] %s\'s option %s failed: %s'):format(r.owner, id, tostring(res)))
        UI.Notify(('%s did not answer'):format(r.label), 'error')
    elseif type(res) == 'table' and type(res.err) == 'string' then
        UI.Notify(res.err, 'error')
    end
    return { ok = true, close = true }
end

-- ============================================
-- The page
-- ============================================

local MODEL_KEYS = { ['live.propModel'] = true, ['map.model'] = true, ['obj.swap'] = true }
local BOOM_TYPE = 2   -- Explode's: EXP_TAG_STICKYBOMB
local RESHOWS = { ['live.solid'] = true, ['live.propModel'] = true }   -- (a Dungeon prop's set shown again)

--- One press. ovPanelDo answers the page once whatever happens in here: an error must never leave the page waiting on an
--- answer, which holds every press after it (the switches that "only worked once": a missing `hold`, 28 Oct).
local function press(data, cb)
    local p = panel
    ---@type string|nil
    local key = type(data) == 'table' and data.key or nil
    local o = p and p.options and p.options[key]
    if not p or away or not o then cb({ ok = false, text = 'That is not here any more' }) return end
    ---@cast key string   (the options are kept under their string keys)
    if o.locked then cb({ ok = false, text = o.lockedWhy or 'Only an admin can do that: it lasts past a restart' }) return end
    local arg = type(data.arg) == 'table' and data.arg or {}

    if key:sub(1, 4) == 'reg:' then cb(runRegistered(p, key:sub(5))) return end
    -- The opening screen's own (OvPanel.open opts.extras): run(p) answers { ok, text, close } (nil: done).
    if key:sub(1, 2) == 'x:' then
        for _, x in ipairs(p.opts and type(p.opts.extras) == 'table' and p.opts.extras or {}) do
            if 'x:' .. tostring(x.key) == key and type(x.run) == 'function' then
                local r = x.run(p) or { ok = true }
                if r.close then OvPanel.close() end
                cb(r)
                return
            end
        end
        cb({ ok = false, text = 'That is not here any more' })
        return
    end
    if o.how == 'local' or LOCAL[key] then
        local fn = LOCAL[key]
        if not fn then cb({ ok = false, text = 'Nothing does that' }) return end
        cb(fn(p, arg))
        return
    end
    if key == 'veh.own' then
        local made = makeOwned(p, arg)
        if not made.act then cb(made) return end
        arg = made.act
    end
    -- (Where they come from is found here, on the ground this game has round them.)
    if key == 'ply.hunt' then
        arg.spots = huntSpots(p.entity, math.max(1, math.min(6, math.tointeger(tonumber(arg.n)) or 2)))
    end
    -- Another model (Change model, Swap): one this game has, and a prop, not a ped or a car.
    if MODEL_KEYS[key] then
        local m = type(arg.model) == 'string' and arg.model:lower():match('^%s*([%w_]+)%s*$') or nil
        local hash = m and GetHashKey(m)
        if not m or not hash or #m > 64 or not IsModelInCdimage(hash) then
            cb({ ok = false, text = 'That is not a model this game has: check the spelling' })
            return
        end
        if IsModelAPed(hash) or IsModelAVehicle(hash) then cb({ ok = false, text = m .. ' is not a prop' }) return end
        arg.model = m
    end
    if not p.target.ref then cb({ ok = false, text = 'Only your game has this one' }) return end

    -- (A change that shows a Dungeon prop's set again: its copy here may go before the answer comes, which must not
    -- close the options. watch waits for the new one.)
    if RESHOWS[key] then p.rewire = { untilAt = GetGameTimer() + REWIRE_MS } end
    local answer, why = Callback('whip_core:ov:act', p.target.ref, key, arg)
    if panel ~= p then cb({ ok = false }) return end
    if type(answer) ~= 'table' then
        p.rewire = nil
        cb({ ok = false, text = why or 'That did not work' })
        return
    end
    local extra = type(answer.extra) == 'table' and answer.extra or {}
    -- Refused, with how it stands now (Key settings: the page shows the truth, not what was asked)
    if answer.ok == false then
        p.rewire = nil
        if extra.carKey then p.desc.carKey = extra.carKey end
        cb({ ok = false, text = answer.text or 'That did not work', carKey = extra.carKey })
        return
    end
    -- Its set shown again: the options follow it to its new copy (watch).
    if extra.rewire and type(p.target.ref) == 'table' and p.target.ref.wire then
        p.target.ref.wire = extra.rewire
        p.rewire = { wire = extra.rewire, untilAt = GetGameTimer() + REWIRE_MS }
    elseif RESHOWS[key] then
        p.rewire = nil
    end
    -- The screen it opened over hears what went and what was made (Dungeon Mode: its list, and a prop to select).
    local o2 = p.opts or {}
    if extra.gone and type(o2.onGone) == 'function' then pcall(o2.onGone, p.entity) end
    if type(extra.made) == 'table' and type(o2.onMade) == 'function' then pcall(o2.onMade, extra.made) end
    -- Explode: the server said where (and logged it); the explosion is this game's, which every game sees.
    local b = type(extra.boom) == 'table' and extra.boom or nil
    if b and tonumber(b.x) and tonumber(b.y) and tonumber(b.z) then
        AddExplosion(b.x + 0.0, b.y + 0.0, b.z + 0.3, BOOM_TYPE, 1.0, true, false, 1.0)
    end
    if o.how == 'toggle' and o.hold then
        p.desc.holds = p.desc.holds or {}
        p.desc.holds[o.hold] = extra.on == true
    end
    if extra.stats then p.desc.stats = extra.stats end
    if extra.model ~= nil then p.desc.model = extra.model or nil end
    if extra.carKey then p.desc.carKey = extra.carKey end
    local res = { ok = true, text = answer.text, on = extra.on, stats = extra.stats, model = extra.model, carKey = extra.carKey }
    if extra.gone or key == 'ply.creator' then
        OvPanel.close()
        if answer.text then UI.Notify(answer.text, 'success') end
        res.close = true
    end
    cb(res)
end

RegisterNUICallback('ovPanelDo', function(data, cb)
    CreateThread(function()
        local answered = false
        local function once(r)
            if answered then return end
            answered = true
            cb(r)
        end
        local ok, err = pcall(press, data, once)
        if not ok then
            print('[whip_core:objectviewer] an option failed: ' .. tostring(err))
            once({ ok = false, text = 'That went wrong (F8 has the error)' })
        end
    end)
end)

RegisterNUICallback('ovPanelClose', function(_, cb)
    cb('ok')
    OvPanel.close()
end)

--- Change owner's search: characters by name, online or not (the /whip pickers' search).
RegisterNUICallback('ovPanelSearch', function(data, cb)
    CreateThread(function()
        local q = type(data) == 'table' and text(data.q, 60) or nil
        if not q or #q < 2 then cb({ list = {} }) return end
        local list = Callback('whip_core:wpCharSearch', q)
        cb({ list = type(list) == 'table' and list or {} })
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then OvPanel.close() end
end)
