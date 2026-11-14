-- ============================================
-- Systems — NPCs a system makes: the NPC Creator (server/npcs.lua) as cards
-- ============================================
--
-- A system's NPCs are whip_core's, under the system's tag, so switching it off (or a Test ending)
-- takes them away; 16 a system at once. Every card that moves, arms or calms one acts only on an NPC
-- THIS system made (its tag), never the Director's or another system's. An NPC attacks only this
-- pulse's player (a guard turning on whoever walked in), never someone wired in from elsewhere.
-- In a Test the NPC is real, as the Director's are (a ped is in everyone's world), and gone with the Test.

local C = SystemCards
local CORE = 'whip_core'
--- At most this many NPCs per system at once (server load).
local MAX_NPCS = 16

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

--- This system's NPC, by the npc pin: its id, or nil and why.
local function ownNpc(ctx)
    local id = ctx:need('npc')
    local v = Npcs.get(id)
    if not v then return nil, ('NPC %s is gone'):format(tostring(id)) end
    if v.owner ~= CORE or v.tag ~= ctx:tag() then return nil, ('NPC %s is not one this system made'):format(tostring(id)) end
    return id, v
end

--- A change to this system's NPC: 'out', or 'failed' with why in the log.
local function change(ctx, patch)
    local id, why = ownNpc(ctx)
    if not id then ctx:log('%s', why) return 'failed' end
    local ok, swhy = Npcs.setState(CORE, id, patch)
    if not ok then ctx:log('NPC %s: %s', tostring(id), tostring(swhy)) return 'failed' end
    return 'out'
end

local NPC_OUTS = { 'out', 'failed' }
local NPC_LABELS = { failed = 'Could not' }

define({
    type = 'npc.spawn', category = 'npcs', kind = 'action', title = 'Make NPC', api = 'SpawnNpc', makes = 'npc',
    desc = 'Makes an NPC at a place: a guard, a shopkeeper, a fence. It stands (or guards) there until moved; it goes when the system is switched off. Its group\'s NPCs defend each other.',
    props = { { key = 'model', kind = 'text', label = 'Ped model', required = true, default = 's_m_y_dealer_01', maxLength = 64 },
              { key = 'behaviour', kind = 'select', label = 'It', options = { 'stand', 'guard' }, default = 'stand' },
              { key = 'weapon', kind = 'text', label = 'Weapon (WEAPON_PISTOL, empty: none)', maxLength = 64 },
              { key = 'armour', kind = 'number', label = 'Armour', default = 0, min = 0, max = 100 },
              { key = 'invincible', kind = 'bool', label = 'Cannot be hurt', default = false },
              { key = 'canMove', kind = 'bool', label = 'Can move', default = true },
              { key = 'reacts', kind = 'bool', label = 'Reacts to the world', default = false },
              { key = 'flees', kind = 'bool', label = 'Runs from danger', default = false },
              { key = 'group', kind = 'text', label = 'Group (empty: none)', maxLength = 24 },
              { key = 'range', kind = 'number', label = 'Guards within (m, 0: anywhere)', default = 0, min = 0, max = 500 } },
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'heading', type = 'number', label = 'Facing (degrees)', default = 0 } },
               outputs = { { key = 'npc', type = 'npc', label = 'NPC' } } },
    run = function(ctx)
        local tag = ctx:tag()
        if C.liveUnder(tag, 'npc') >= MAX_NPCS then
            ctx:log('this system has %d NPCs already, the most it may', MAX_NPCS)
            return 'failed'
        end
        local at, heading = ctx:need('place'), ctx:need('heading')
        local weapon = ctx:prop('weapon')
        local group = ctx:prop('group')
        local range = tonumber(ctx:prop('range')) or 0
        local id, why = Npcs.spawn(CORE, {
            model = ctx:prop('model'), coords = { x = at.x, y = at.y, z = at.z, heading = heading },
            behaviour = ctx:prop('behaviour'), weapon = (type(weapon) == 'string' and weapon ~= '') and weapon or nil,
            armour = ctx:prop('armour'),
            conditions = { invincible = ctx:prop('invincible') == true, canMove = ctx:prop('canMove') ~= false,
                           reacts = ctx:prop('reacts') == true, flees = ctx:prop('flees') == true },
        }, { tag = tag, range = range >= 1 and range or nil,
             -- A group is per owner (every system is whip_core), so it carries the system's name.
             group = (type(group) == 'string' and group ~= '') and C.nameFor(ctx, group) or nil })
        if not id then ctx:log('the NPC could not be made: %s', tostring(why)) return 'failed' end
        return 'out', { npc = id }
    end,
})

define({
    type = 'npc.remove', category = 'npcs', kind = 'action', title = 'Remove NPC', api = 'DespawnNpc',
    desc = 'Takes away an NPC this system made.',
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' } } },
    run = function(ctx)
        local id, why = ownNpc(ctx)
        if not id then ctx:log('%s', why) return 'failed' end
        Npcs.despawn(CORE, id)
        return 'out'
    end,
})

define({
    type = 'npc.info', category = 'npcs', kind = 'value', title = 'About the NPC', api = 'GetNpc',
    desc = 'An NPC as the server sees it: alive or not, its health, where it is, and who killed it.',
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' } },
               outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'alive', type = 'bool', label = 'Alive' },
                           { key = 'health', type = 'number', label = 'Health' }, { key = 'place', type = 'vector', label = 'Place' },
                           { key = 'killer', type = 'player', label = 'Killer' } } },
    value = function(ctx)
        local v = Npcs.get(ctx:need('npc'))
        if not v then return { found = false, alive = false, health = 0 } end
        return { found = true, alive = v.alive == true, health = tonumber(v.health) or 0, place = v.coords,
                 killer = v.killer and Systems.playerValue(v.killer) or nil }
    end,
})

define({
    type = 'npc.goTo', category = 'npcs', kind = 'action', title = 'NPC Goes To', api = 'SetNpcState',
    desc = 'Sends an NPC this system made to a place, walking or running; it stands (or guards) there from then on.',
    props = { { key = 'pace', kind = 'select', label = 'It', options = { 'walk', 'run' }, default = 'walk' } },
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' }, { key = 'place', type = 'vector', label = 'Place' } } },
    run = function(ctx)
        local at = ctx:need('place')
        return change(ctx, { post = { x = at.x, y = at.y, z = at.z }, pace = ctx:prop('pace'), follow = false, flee = false })
    end,
})

define({
    type = 'npc.follow', category = 'npcs', kind = 'action', title = 'NPC Follows', api = 'SetNpcState',
    desc = 'An NPC this system made walks after a player (an escort, a pet). No player wired in: it stops and stays where it is.',
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' }, { key = 'player', type = 'player', label = 'Player (empty: stop)', optional = true } } },
    run = function(ctx)
        local who = ctx:input('player')
        local src = who and ctx:source(who)
        if who and not src then return 'failed' end
        return change(ctx, { follow = src or false, flee = false })
    end,
})

define({
    type = 'npc.flee', category = 'npcs', kind = 'action', title = 'NPC Runs From', api = 'SetNpcState',
    desc = 'An NPC this system made runs from a player, and fights nobody meanwhile. No player wired in: it stops running.',
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' }, { key = 'player', type = 'player', label = 'Player (empty: stop)', optional = true } } },
    run = function(ctx)
        local who = ctx:input('player')
        local src = who and ctx:source(who)
        if who and not src then return 'failed' end
        return change(ctx, { flee = src or false, follow = false })
    end,
})

define({
    type = 'npc.attack', category = 'npcs', kind = 'action', title = 'NPC Attacks', api = 'SetNpcState',
    desc = 'An NPC this system made turns on THIS pulse\'s player (a guard and whoever walked into the yard), or with Calm Down, fights nobody and forgets who hit it.',
    props = { { key = 'action', kind = 'select', label = 'Do', options = { 'attack them', 'calm down' }, default = 'attack them' } },
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' } } },
    run = function(ctx)
        if ctx:prop('action') == 'calm down' then return change(ctx, { hostileTo = false }) end
        local src = ctx:source(ctx:player())
        if not src then ctx:log('this pulse has no player of its own to attack') return 'failed' end
        return change(ctx, { hostileTo = { people = { src } }, flee = false })
    end,
})

define({
    type = 'npc.anim', category = 'npcs', kind = 'action', title = 'NPC Plays Emote', api = 'SetNpcState',
    desc = 'What an NPC this system made does where it stands: an emote by its /e name (smoke, clipboard), or, left empty, nothing.',
    props = { { key = 'emote', kind = 'text', label = 'Emote (/e name, empty: none)', maxLength = 40 } },
    outputs = NPC_OUTS, labels = NPC_LABELS,
    values = { inputs = { { key = 'npc', type = 'npc', label = 'NPC' } } },
    run = function(ctx)
        local name = ctx:prop('emote')
        if type(name) ~= 'string' or name == '' then return change(ctx, { anim = false }) end
        local anim = C.emoteAnim(name)
        if not anim then ctx:log('"%s" is not an emote with an animation (see /e)', name) return 'failed' end
        return change(ctx, { anim = anim })
    end,
})

-- ============================================
-- Triggers: this system's NPCs (Npcs.onLife, through systems/main.lua)
-- ============================================

local function npcMatch(ctx, p)
    if type(p) ~= 'table' or not p.npc or p.tag ~= ctx:tag() then return nil end
    return { npc = p.npc, player = p.player }, { player = p.player }
end

define({
    type = 'when.npcKilled', category = 'when', kind = 'trigger', title = 'When an NPC Is Killed',
    desc = 'An NPC this system made is killed. Player is who did it, when the server found it was one.',
    trigger = { name = 'npc.killed', match = npcMatch },
    values = { outputs = { { key = 'npc', type = 'npc', label = 'NPC' }, { key = 'player', type = 'player', label = 'Killer' } } },
})

define({
    type = 'when.npcHurt', category = 'when', kind = 'trigger', title = 'When an NPC Is Hurt',
    desc = 'An NPC this system made is hurt. Player is who hurt it, when it was one.',
    trigger = { name = 'npc.damaged', match = npcMatch },
    values = { outputs = { { key = 'npc', type = 'npc', label = 'NPC' }, { key = 'player', type = 'player', label = 'By' } } },
})
