-- ============================================
-- Director — the card types (node registry)
-- ============================================
--
-- Every card the blueprint editor offers is ONE entry here, and that entry is the single source of
-- truth for it: the server checks a scenario against it, runs the card with it, and sends the editor
-- its title, pins and fields to draw. Nothing about a card type lives anywhere else.
--
-- A card type:
--
--   {
--     type     = 'flow.wait',            -- stable id; never renamed (a resource renames its own: `renamed`)
--     v        = 1,                      -- bumped when its props change shape, with `upgrade` beside it
--     upgrade  = fn(props, fromV) -> props, -- an older version's fields read as this one's: run once, as the
--                                        -- document is read (doc.lua), so nothing else reads an old shape
--     category = 'flow',                 -- the palette group
--     title    = 'Wait',
--     desc     = 'Waits, then carries on.',   -- the palette's one line, in plain English
--     labels   = { done = 'Done' },      -- what the editor writes beside a pin (default: its name)
--     inputs   = { 'in' },               -- exec pins in (named, never numbered)
--     outputs  = { 'done' },             -- exec pins out: one per outcome (Done, Failed, Timeout...)
--     props    = { { key = 'seconds', kind = 'number', label = 'Seconds', default = 5, min = 0 } },
--     latent   = true,                   -- it can wait (a timer, an event, a call): Check allows
--                                        -- loops only through a latent card
--     event    = { name = 'npc.killed', filter = fn(ctx, payload) -> pin|nil, once = false }
--                                        -- an EVENT card: no inputs; it listens for the whole run
--     condition = true,                  -- a FAIL CONDITION: no pins, wired to nothing; it watches the whole
--                                        -- run and never keeps it going. Its rule broken: ctx:broken
--     watch    = fn(ctx),                -- a condition's look at the run, every `every` ms (default 1000,
--     every    = 1000,                   -- 250 to 60000): runtime.lua. (Or its `event`, for another
--                                        -- resource's rule: cards_api.lua)
--     run      = fn(ctx) -> pin | { pins } | nil, data?
--                                        -- instant: answer the output pin(s) (data = the trigger for
--                                        -- what follows); latent: register waits through ctx and
--                                        -- answer nil. It must not WAIT itself: ctx:call does that.
--                                        -- An outcome now while it goes on waiting: ctx:emit
--     retrigger = 'restart' | 'ignore',  -- a latent card pulsed again while it waits (default restart;
--                                        -- a call already under way is never run twice)
--     yields   = true,                   -- it calls something that waits (the world, a player):
--                                        -- it MUST have a 'timeout' output
--     giveUp   = 15,                     -- seconds: its 'timeout' (Took too long) armed by the runtime
--                                        -- whenever the card is left waiting (runtime.lua exec), not by its run
--     heavy    = true,                   -- costly (world cards): the pass checks its time after it
--     branch   = true,                   -- like If: Check warns when one of its outcomes goes nowhere
--     pinWhen  = { pin = when },         -- an outcome that is one only while its `when` holds (No answer
--                                        -- only with a time limit; a Dialog Line's answer only when written:
--                                        -- server/director/fields.lua's language); the editor draws it then
--     unusedPin = fn(props, pin, wiredIn) -> bool, -- what pinWhen cannot say: an outcome this card can
--                                        -- never take given its wired inputs (wiredIn = { [inputPin] = true }:
--                                        -- a Countdown no wire stops) or the world (a skill game).
--                                        -- Either way Check does not ask for it to be wired, and warns if it is
--     talks    = true,                   -- it talks with its `npc` field's NPC (Dialog Line, Haggle): through
--                                        -- DirectorTalk (talk.lua), an answer wired straight to another for the
--                                        -- same NPC carrying the conversation on; the NPC's page and the hub's
--                                        -- lists of who talks say so
--     saysAbove = true,                  -- a line above its `npc` field's NPC (NPC /me): a talking card's outcome
--                                        -- wired straight to it says that, not its own parting line
--     givesItems = true,                 -- its `item` field (or `loot` slots) put an item in the run's hands
--                                        -- or world: a goal for the scenario's own items picks from these
--     handsOut = true,                   -- it hands out something else that lasts (money, a car, a key): Check warns
--                                        -- of it, as of givesItems, before Scenario Run Started By Player
--     repeats  = { { keys = { 'opt%d', 'opt%dRule' }, from = 1, to = 4, min = 1, add = 'Add an answer' } },
--                                        -- fields that come in numbered sets: the editor shows the sets
--                                        -- written (at least `min`) and an Add button for one more
--     pinText  = { pin = { key, empty, after } }, -- an outcome called by a field's words (an answer's text;
--                                        -- `empty` while it has none, `after` added: " (failed)")
--     bad      = { pin, ... },           -- outcomes that mean it did not happen: the editor draws them red
--     ui       = { face, wide, page },   -- how the editor draws it beyond its fields: its card's face
--                                        -- ('quote', 'menu'), a wide card, its page's own part ('loot',
--                                        -- 'skillTry', ...): html/js/director canvas.js FACES, panels.js PAGES.
--                                        -- A field's own `ui` ('answer', 'menuUnder', 'hearLink'): panels.js FIELD_UI
--     prompt   = { at, menu, lift, rides }, -- it puts a prompt on what its `at` field names (the world builder shows
--                                        -- it there): `lift` above it by kind, riding the kinds in `rides`, else at
--                                        -- the spot; `menu`, its choices are a menu (the Interaction Menu's rules)
--     haggle   = { key, toPlayer, unit }, -- a Haggle can agree its `key` (money, or a count): nodes_talk.lua
--     pinName  = fn(props, pin) -> text, -- how Check names an outcome in a message (an answer's text)
--     together = true,                   -- all its outcomes go at once (Do in Order): Check's dead ends
--     goesOn   = 'out',                  -- this outcome goes at once while it still waits (Start Tasks'
--                                        -- ctx:emit): Check's dead ends
--     makes    = fn(props, doc) -> { [worldId] = true }, -- the placed things it makes (Spawn NPC, Spawn Car,
--                                        -- Play Take, Show Prop): Check and Start Tasks ask it (DirectorNodes.makesOf)
--     startsTasks = fn(props) -> bool,   -- it starts the tasks of what it makes itself (its Start their tasks)
--     startsTasksFor = fn(props) -> { worldId }, -- the things whose tasks it starts (Start Tasks): Check warns when
--                                        -- it follows a card that already starts them
--     check    = fn(props, doc) -> message|nil, severity?, -- what no one field can know: how they fit
--                                        -- together (an Interaction Menu's shape); a message is an
--                                        -- error, or a warning with 'warning' (a fixed plate)
--     quietPins = { pin = true },        -- outcomes Check does not ask to be wired (another
--                                        -- resource's Didn't Work: unwired, the run faults with why)
--     once     = false,                  -- never offer Only Once (below); true offers it where the
--                                        -- rule would not (default: the rule decides)
--     onceOut  = 'sent',                 -- the outcome a skipped Only Once card goes on through
--                                        -- (default its first)
--   }
--
-- ONLY ONCE. A card a run can reach again (round a retry, after a failed skill check) may be set to do
-- its work the first time only: every time after, in the same run, it is skipped and the run goes
-- straight on through its onceOut, as a pass-through would (runtime.lua exec). It is a field of its own,
-- `onlyOnce` (a switch, "Only once", added here), offered on a card that does something and goes on: not on
-- an event, a flow card or a goal, nor on one the run waits at for a player (a prompt, a skill check, a
-- conversation: those say once = false), nor on one with no outcome to go on through.
--
-- Whose a card is: every type is an entry in ONE registry
-- (shared/registry.lua), owned by whoever registered it: whip_core's own, defined below at load, and
-- other resources' cards (server/director/cards_api.lua: __RegisterDirectorCard, through Whip.card).
-- A type is '<namespace>.<name>'; a namespace belongs to the first running resource to use it, for
-- its cards and its events alike (SendDirectorEvent), and whip_core's (every group its own cards use,
-- and a few more) are nobody else's. A stopped resource's cards go with it: a scenario that uses one
-- keeps it, drawn as unknown until it is back.
--
-- Prop kinds the checker knows: text, number, bool, select (options), world (a placed thing, by
-- worldKind), var (a run variable), duration (seconds), item (a whip item's key: the editor offers
-- the server's items, Check refuses any other), rule (a Dialog Line answer's rules: a table its
-- card's own check reads, never a variable), lore (a lore character's key: empty is the scenario's own,
-- server/director/lore.lua). A field may add check = fn(value, doc) ->
-- message|nil for what a kind cannot know (an item name that must exist). Unknown keys on a saved
-- card are KEPT, so a newer editor's field never breaks an older server's load.

DirectorNodes = {
    _types = {},
    --- The catalogue's revision: it moves whenever a card is added, changed or taken away (the editor
    --- asks again when it has moved).
    rev = 0,
}

local CORE = GetCurrentResourceName()

local Cards = Registry.new('directorCard', {
    label = 'Director card', store = DirectorNodes._types,
    -- Every registration replaces: a definition carries fresh functions each time.
    same = false,
    onAdd = function() DirectorNodes.rev = DirectorNodes.rev + 1 end,
    onRemove = function() DirectorNodes.rev = DirectorNodes.rev + 1 end,
})

-- ============================================
-- Namespaces: the first part of a card type, or of an event a script sends
-- ============================================

local Spaces = Registry.new('directorNamespace', { label = 'Director namespace' })

--- whip_core's: every group its own cards use (filled as they are defined), and these.
local coreSpaces = { flow = true, scenario = true, player = true, world = true, npc = true, item = true, vehicle = true,
                     goal = true, dialog = true, map = true, point = true, door = true, container = true, area = true,
                     prop = true, flag = true, var = true, script = true, run = true, job = true, zone = true,
                     conversation = true, whip = true, whip_core = true }

--- Is this namespace whip_core's (nobody else may name a card or an event in it)?
---@param ns string
---@return boolean
function DirectorNodes.reservedSpace(ns)
    return coreSpaces[ns] == true
end

--- Claim a namespace for `owner` (a card's, or an event's). The first running resource has it; whip_core's
--- are refused. Answers true, or false and why (with the holder's name).
---@return boolean ok
---@return string|nil why
function DirectorNodes.claimSpace(owner, ns)
    if type(ns) ~= 'string' or not ns:match('^[%a][%w_]*$') then return false, 'a namespace is one word' end
    if owner ~= CORE and coreSpaces[ns] then
        return false, ('"%s." is whip_core\'s: name yours after your resource'):format(ns)
    end
    local ok, why = Spaces:add(owner, ns, true)
    if not ok then return false, why --[[@as string]] end
    return true
end

-- (A prop's kind is one of server/director/fields.lua's that a card may have: DirectorFields.)

--- A `players` field's choices: who a card acts on, resolved to server ids for it.
DirectorNodes.PLAYERS = { 'this player', 'everyone in the run', 'the starter' }
--- ...as the editor says them (the values above are what scenarios keep).
DirectorNodes.PLAYER_LABELS = { ['everyone in the run'] = 'everyone in the scenario' }

--- The card types a Haggle can agree a price for: each of whip_core's with a `haggle`, added as it is defined (this
--- one list is a Haggle's Haggling for choices: nodes_talk.lua).
DirectorNodes.HAGGLED = {}

--- A card's "any of them or all of them" (a goal for the run's players, an NPC's group): its `who` field, and whether a
--- card's says all (wantsAll). `of` 'npcs' words it for NPCs; `extra`: more of the field's own (bySpot).
DirectorNodes.ANY_ALL = { 'any', 'all' }
function DirectorNodes.anyAllField(label, of, extra)
    local f = { key = 'who', kind = 'select', label = label, options = DirectorNodes.ANY_ALL, default = 'any',
                optionLabels = of == 'npcs' and { any = 'Any of them', all = 'All of them' }
                    or { any = 'Any player in the scenario', all = 'All players in the scenario' } }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end
function DirectorNodes.wantsAll(ctx) return ctx:prop('who') == 'all' end

-- ---- several placed things on one card, and groups ----
--
-- A 'worlds' field with `groups` holds placed things and named groups ('group:<name>'): a group is every placed thing
-- of the field's kind whose page puts it in that group (its Group: def.group). A card reads the things it names with
-- DirectorNodes.things; an older card that held one thing (a 'world' field, a string) reads the same way.

DirectorNodes.GROUP = 'group:'

--- A group entry's name, or nil (a placed thing's id).
function DirectorNodes.groupName(v)
    local G = DirectorNodes.GROUP
    if type(v) ~= 'string' or v:sub(1, #G) ~= G then return nil end
    local name = v:sub(#G + 1):match('^%s*(.-)%s*$')
    return name ~= '' and name or nil
end

--- A placed thing's group, trimmed, or nil.
function DirectorNodes.groupOf(w)
    local g = type(w) == 'table' and type(w.def) == 'table' and w.def.group or nil
    g = type(g) == 'string' and g:match('^%s*(.-)%s*$') or ''
    return g ~= '' and g or nil
end

--- The placed things `v` names (a list, or one id), each once, in order; a group as its members of `kind` (nil: any),
--- by id. `world`: the scenario's things, a list (a document's) or [id] = thing (a run's graph).
function DirectorNodes.expandThings(world, v, kind)
    local list = type(v) == 'table' and v or (type(v) == 'string' and v ~= '' and { v } or {})
    local out, seen = {}, {}
    local function add(id)
        if not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    for _, x in ipairs(list) do
        local g = DirectorNodes.groupName(x)
        if g then
            local members = {}
            for k, w in pairs(type(world) == 'table' and world or {}) do
                if type(w) == 'table' and (not kind or w.kind == kind) and DirectorNodes.groupOf(w) == g then
                    members[#members + 1] = type(w.id) == 'string' and w.id or k
                end
            end
            table.sort(members)
            for _, id in ipairs(members) do add(id) end
        elseif type(x) == 'string' and x ~= '' then
            add(x)
        end
    end
    return out
end

--- The placed things this card's field `key` names, for its run: its things, and its groups' members of its kind.
function DirectorNodes.things(ctx, key)
    local f = ctx.node.def and ctx.node.def._fields and ctx.node.def._fields[key]
    local world = ctx.run and ctx.run.graph and ctx.run.graph.world or {}
    return DirectorNodes.expandThings(world, ctx.node.props[key], f and f.worldKind or nil)
end

--- A card's field of placed things and groups (several, any kind of `worldKind`), as the event and action cards have it.
function DirectorNodes.thingsField(key, worldKind, label, extra)
    local f = { key = key, kind = 'worlds', worldKind = worldKind, label = label, groups = true, required = true }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

--- A card's upgrade from one placed thing (`key` a string) to a list of them (its `thingsField`).
function DirectorNodes.toList(props, key)
    if type(props[key]) == 'string' then props[key] = props[key] ~= '' and { props[key] } or nil end
    return props
end

--- THE NPCs A HANDLE HOLDS (what a card made for a placed thing, or the standing one): every one of its group, or the
--- one; {} for none. Every card asks here, never h.group or h.npcId by hand. (The list itself: read it, never change it.)
---@return integer[]
function DirectorNodes.npcIds(h)
    if type(h) ~= 'table' then return {} end
    if type(h.group) == 'table' then return h.group end
    return h.npcId and { h.npcId } or {}
end

--- Where a placed car is made as `model`: its wheels on the ground it was placed on (def.coords.ground, the world
--- builder's) at that model's own height over them (def.lifts: the editor's game measured each of its models, as the
--- server cannot), so every car of a random vehicle's pool, a trailer or a hatchback, stands on the ground there, not
--- in it nor over it. A car placed before there was a ground, or a model with no height: where it was placed.
---@return vector3|nil
function DirectorNodes.carAt(def, model)
    local c = type(def) == 'table' and def.coords or nil
    local at = DirectorKit.vec3(c)
    if not c or not at then return nil end
    local ground = tonumber(c.ground)
    local lift = type(def.lifts) == 'table' and type(model) == 'string' and tonumber(def.lifts[model]) or nil
    if ground and lift and DirectorKit.finite(ground) and DirectorKit.finite(lift) and lift >= 0 and lift < 20 then
        return vector3(at.x, at.y, ground + lift)
    end
    return at
end

--- WHERE A PLACED THING IS NOW, the one answer: an NPC where it stands (the one the trigger names when it is one of
--- them: the guard who just died; else the first still alive, else the first), the run's car where it is, anything else
--- the run made with a network id (a physics prop) where that is, the rest where it was placed. Its network id too when
--- it has one there.
---@return vector3|nil at
---@return integer|nil netId
function DirectorNodes.whereNow(ctx, worldId)
    local w = ctx:place(worldId)
    if type(w) ~= 'table' then return nil end
    local h = Director.handleOf(ctx.run, worldId)
    if w.kind == 'npc' then
        local t = type(ctx.trigger) == 'table' and ctx.trigger or {}
        local named, alive, first
        for _, id in ipairs(DirectorNodes.npcIds(h)) do
            local info = Npcs.get(id)
            if info then
                if id == t.npcId then named = info end
                if not alive and info.alive then alive = info end
                first = first or info
            end
        end
        local info = named or alive or first
        local at = info and DirectorKit.vec3(info.coords)
        if at then return at, info.netId end
    elseif w.kind == 'vehicle' then
        local id = DirectorNodes.runCarId(ctx, worldId)
        local ent = id and Vehicles.getEntity(id)
        if ent then return GetEntityCoords(ent), NetworkGetNetworkIdFromEntity(ent) end
    elseif type(h) == 'table' and h.netId then
        local e = NetworkGetEntityFromNetworkId(h.netId)
        if e and e ~= 0 and DoesEntityExist(e) then return GetEntityCoords(e), h.netId end
    end
    return DirectorKit.vec3(type(w.def) == 'table' and w.def.coords or nil)
end

--- The people a mark or a point is for, from server ids: { { charId }, ... } (Blips' and RuntimePoints' audiences).
function DirectorNodes.peopleOf(sources)
    local people = {}
    for _, s in ipairs(sources) do
        local p = Players[s]
        if p and p.charId then people[#people + 1] = { charId = p.charId } end
    end
    return people
end

--- An emote's animation (EmoteList, by its /e name): { dict, clip } or { scenario }, or nil.
function DirectorNodes.emoteAnim(cmd)
    if type(cmd) ~= 'string' or cmd == '' then return nil end
    for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
        if e.cmd == cmd then
            if e.scenario then return { scenario = e.scenario } end
            if e.dict and e.anim then return { dict = e.dict, clip = e.anim } end
            return nil
        end
    end
    return nil
end

--- THE RUN'S CAR for a placed thing, as every car card reads it: its vehicleId while whip has it (made, or claimed),
--- else nil.
function DirectorNodes.runCarId(ctx, worldId)
    local h = ctx:handle(worldId)
    local id = type(h) == 'table' and h.vehicleId or nil
    if not id or not Vehicles.getDef(id) then return nil end
    return id
end

--- Its entity while it is in the world; `gone`: no car, and no claim of it under way (the run's record of a claimed car
--- goes a moment before the owned one is out); `made`: a card of the run has made it (before that, nothing to lose).
---@return integer|nil ent
---@return boolean gone
---@return boolean made
function DirectorNodes.runCar(ctx, worldId)
    local h = ctx:handle(worldId)
    local vid = type(h) == 'table' and h.vehicleId or nil
    if not vid then return nil, true, false end
    local ent = Vehicles.getDef(vid) and Vehicles.getEntity(vid) or nil
    if ent then return ent, false, true end
    return nil, not (Vehicles.claimUnderWay and Vehicles.claimUnderWay(vid)), true
end

--- A card's look at the run's car, once a poll (Car Destroyed, Car Delivered, Deliver the Car, Steal the Car): answers
--- its entity while it is there and whole, and `lost` once it is gone (no claim of it under way) or has read wrecked
--- three looks in a row (a game taking the car over reads it as wrecked for a moment). Not made yet (a card started
--- before its Spawn Car): nothing to lose, it waits; once this look has seen it made, it can be lost (a Remove taking
--- it away too). One per card activation: it counts the looks.
---@return fun(): integer|nil, boolean
function DirectorNodes.carLook(ctx, worldId)
    local wreckedFor, seen = 0, false
    return function()
        local ent, gone, made = DirectorNodes.runCar(ctx, worldId)
        seen = seen or made
        if not ent then return nil, gone and seen end
        if VehicleDamage.isWrecked(ent) then
            wreckedFor = wreckedFor + 1
            return nil, wreckedFor >= 3
        end
        wreckedFor = 0
        return ent, false
    end
end

--- How damaged a car reads, 0 (new) to 100 (wrecked): the worse of its body and its engine. nil while no player's game
--- runs it: the server reads what a game last sent, and 0 before one has (FiveM: no health node yet).
function DirectorNodes.carDamage(ent)
    local owner = NetworkGetEntityOwner(ent)
    if not owner or owner <= 0 then return nil end
    if GetEntityHealth(ent) <= 0 or VehicleDamage.isWrecked(ent) then return 100 end
    local worst = math.min(GetVehicleBodyHealth(ent), GetVehicleEngineHealth(ent))
    return math.max(0, math.min(100, (1000 - worst) / 10))
end

local function isName(s) return type(s) == 'string' and s:match('^[%a][%w_]*$') ~= nil end

--- The groups whose cards never offer Only Once: they are how a run decides and waits, not things it does.
local NO_ONCE = { flow = true, goals = true, events = true }

local validate

--- Add one of whip_core's own card types (its server files, at load).
---@param def table
---@return boolean ok
---@return string|nil why
function DirectorNodes.define(def)
    local ok, why = validate(def)
    if not ok then return false, why end
    coreSpaces[def.type:match('^([^.]+)')] = true
    Cards:seed(def.type, def)
    if def.haggle then DirectorNodes.HAGGLED[#DirectorNodes.HAGGLED + 1] = def.type end
    return true
end

--- Add, or change, another resource's card type (server/director/cards_api.lua builds `def`). Refused when
--- the type is someone else's: whip_core's own, or a running resource's.
---@param owner string  Registry.caller() of __RegisterDirectorCard
---@param def table
---@return boolean ok
---@return string|nil why
function DirectorNodes.defineFor(owner, def)
    local ok, why = validate(def)
    if not ok then return false, why end
    def.owner = owner
    local added, addWhy = Cards:add(owner, def.type, def)
    return added, addWhy --[[@as string|nil]]
end

--- Take one of `owner`'s card types away (never anyone else's).
function DirectorNodes.remove(owner, t) return Cards:remove(owner, t) end

--- Who a card type is: 'whip_core', another resource, or nil (not registered).
function DirectorNodes.ownerOf(t) return Cards:ownerOf(t) end

---@param def table
---@return boolean ok
---@return string|nil why
validate = function(def)
    if type(def) ~= 'table' or type(def.type) ~= 'string' or not def.type:match('^[%a][%w_]*%.[%a][%w_.]*$') then
        return false, 'a card type needs type = "group.name"'
    end
    if math.type(def.v) ~= 'integer' or def.v < 1 then return false, def.type .. ': v must be a whole number of 1 or more' end
    def.inputs = def.inputs or (def.event and {} or { 'in' })
    def.outputs = def.outputs or {}
    for _, list in ipairs({ def.inputs, def.outputs }) do
        local seen = {}
        for _, p in ipairs(list) do
            if not isName(p) then return false, def.type .. ': pin names are words, not "' .. tostring(p) .. '"' end
            if seen[p] then return false, def.type .. ': pin "' .. p .. '" twice' end
            seen[p] = true
        end
    end
    if def.condition then
        if #def.inputs > 0 or #def.outputs > 0 then return false, def.type .. ': a fail condition has no pins' end
        if (def.watch == nil) == (def.event == nil) then return false, def.type .. ': a fail condition has a watch or an event' end
    elseif def.watch ~= nil then
        return false, def.type .. ': only a fail condition (condition = true) watches'
    end
    if def.watch ~= nil then
        if type(def.watch) ~= 'function' then return false, def.type .. ': watch is a function' end
        def.every = def.every or 1000
        if not (DirectorKit.finite(def.every) and def.every >= 250 and def.every <= 60000) then
            return false, def.type .. ': every is 250 to 60000 ms'
        end
    elseif def.event then
        if #def.inputs > 0 then return false, def.type .. ': an event card has no inputs' end
        if type(def.event.name) ~= 'string' then return false, def.type .. ': event.name is missing' end
    elseif def.run == nil then
        return false, def.type .. ': run is missing'
    end
    def.props = def.props or {}
    def._fields = {}
    for _, f in ipairs(def.props) do
        if not isName(f.key) then return false, def.type .. ': a prop needs a key' end
        if not DirectorFields.usable(f.kind, 'card') then
            return false, ('%s: prop %s has kind %s, not one a card has (%s)'):format(def.type, f.key, tostring(f.kind), DirectorFields.namesFor('card'))
        end
        if f.kind == 'select' then
            if type(f.options) ~= 'table' or #f.options == 0 then
                return false, ('%s: prop %s is a choice with no options'):format(def.type, f.key)
            end
            if f.default ~= nil then
                local found = false
                for _, o in ipairs(f.options) do if o == f.default then found = true end end
                if not found then return false, ('%s: prop %s defaults to something that is not a choice'):format(def.type, f.key) end
            end
        end
        if f.check ~= nil and type(f.check) ~= 'function' then
            return false, ('%s: prop %s check must be a function'):format(def.type, f.key)
        end
        if f.when ~= nil then
            local why = DirectorFields.whenProblem(f.when)
            if why then return false, ('%s: prop %s: %s'):format(def.type, f.key, why) end
        end
        def._fields[f.key] = f
    end
    if def.check ~= nil and type(def.check) ~= 'function' then return false, def.type .. ': check must be a function' end
    def._outputs = {}
    for _, p in ipairs(def.outputs) do def._outputs[p] = true end
    for pin, c in pairs(def.pinWhen or {}) do
        if not def._outputs[pin] then return false, ('%s: pinWhen names %s, which is not one of its outcomes'):format(def.type, tostring(pin)) end
        local why = DirectorFields.whenProblem(c)
        if why then return false, ('%s: pinWhen %s: %s'):format(def.type, pin, why) end
    end
    for pin, t in pairs(def.pinText or {}) do
        if not def._outputs[pin] then return false, ('%s: pinText names %s, which is not one of its outcomes'):format(def.type, tostring(pin)) end
        if type(t) ~= 'table' or not def._fields[t.key] then return false, ('%s: pinText %s names a field it has not got'):format(def.type, pin) end
    end
    for _, pin in ipairs(def.bad or {}) do
        if not def._outputs[pin] then return false, ('%s: bad names %s, which is not one of its outcomes'):format(def.type, tostring(pin)) end
    end
    -- A card that waits on the server (the database, a spawn) and gives up says so in a builder's
    -- words: "Took too long", not "Timeout". A card
    -- waiting on a PLAYER names its own ("Too late", "No answer").
    if def._outputs.timeout then
        def.labels = def.labels or {}
        if def.labels.timeout == nil then def.labels.timeout = 'Took too long' end
    end
    if def.yields then
        if not def.latent then return false, def.type .. ': a card that waits on the world must be latent' end
        if not def._outputs.timeout then return false, def.type .. ': a card that waits on the world needs a timeout outcome' end
    end
    if def.giveUp ~= nil then
        if not (DirectorKit.finite(def.giveUp) and def.giveUp > 0) then return false, def.type .. ': giveUp is a number of seconds' end
        if not (def.latent and def._outputs.timeout) then return false, def.type .. ': giveUp is for a latent card with a timeout outcome' end
    end
    if def.quietPins ~= nil then
        if type(def.quietPins) ~= 'table' then return false, def.type .. ': quietPins is { pin = true }' end
        for p in pairs(def.quietPins) do
            if not def._outputs[p] then return false, ('%s: quiet pin %s is not one of its outcomes'):format(def.type, tostring(p)) end
        end
    end
    def.retrigger = def.retrigger or 'restart'
    -- Only Once (see the top of the file): offered by the rule unless the card says, its switch added once.
    if def.once == nil then
        def.once = not def.event and #def.inputs > 0 and #def.outputs > 0 and not NO_ONCE[def.category]
    end
    if def.once then
        local out = def.onceOut or def.outputs[1]
        if not def._outputs[out] then return false, ('%s: onceOut "%s" is not one of its outcomes'):format(def.type, tostring(out)) end
        def.onceOut = out
        if not def._fields.onlyOnce then
            local said = def.labels and def.labels[out] or (out ~= 'out' and out:sub(1, 1):upper() .. out:sub(2)) or nil
            local f = { key = 'onlyOnce', kind = 'bool', label = 'Only once', default = false, group = 'Played again',
                        hint = said and ('If the scenario comes back to it, it is skipped: straight on through ' .. said)
                            or 'If the scenario comes back to it, it is skipped: it goes straight on' }
            def.props[#def.props + 1] = f
            def._fields.onlyOnce = f
        end
    end
    return true
end

---@param t string
---@return table|nil
function DirectorNodes.get(t) return DirectorNodes._types[t] end

--- What a card of a document makes, as its definition says (`makes`): { [worldId] = true }; empty for a card that
--- makes nothing (or one whose `makes` throws: never Check's stop).
function DirectorNodes.makesOf(node, doc)
    local def = type(node) == 'table' and DirectorNodes._types[node.type]
    if not def or type(def.makes) ~= 'function' then return {} end
    local ok, set = pcall(def.makes, type(node.props) == 'table' and node.props or {}, doc)
    return (ok and type(set) == 'table') and set or {}
end

--- The placed things whose tasks a card starts (its definition's `startsTasksFor`: Start Tasks), as a list of ids.
function DirectorNodes.startsTasksForOf(node)
    local def = type(node) == 'table' and DirectorNodes._types[node.type]
    if not def or type(def.startsTasksFor) ~= 'function' then return {} end
    local ok, list = pcall(def.startsTasksFor, type(node.props) == 'table' and node.props or {})
    return (ok and type(list) == 'table') and list or {}
end

--- Does a card start the tasks of what it makes, itself (its definition's `startsTasks`, with its fields)?
function DirectorNodes.startsTasksOf(node)
    local def = type(node) == 'table' and DirectorNodes._types[node.type]
    if not def or type(def.startsTasks) ~= 'function' then return false end
    local ok, yes = pcall(def.startsTasks, type(node.props) == 'table' and node.props or {})
    return ok and yes == true
end

--- Is this an outcome the card can never take, with these fields and wired inputs (its pinWhen, then its unusedPin)?
--- `outs`: its own wired outcomes (unusedPin's 4th). A card whose unusedPin throws: false (never Check's stop).
function DirectorNodes.pinUnused(def, props, pin, wiredIn, outs)
    local c = def.pinWhen and def.pinWhen[pin]
    if c ~= nil and not DirectorFields.holds(c, props, def.props) then return true end
    if not def.unusedPin then return false end
    local ok, u = pcall(def.unusedPin, props, pin, wiredIn or {}, outs or {})
    return ok and u == true
end

-- ============================================
-- Renamed cards
-- ============================================
--
-- Another resource renames a card of its own, or one of its outcomes, by saying so on the new card:
-- renamed = { ['police.alert'] = { pins = { sent = 'dispatched' } } }. A scenario that still names the
-- old one is READ as the new one, in memory only (a saved revision is never rewritten), before every
-- Check and compile. Never for a type something running still provides itself.

local renameIndex, renameRev = {}, -1

local function renames()
    if renameRev == DirectorNodes.rev then return renameIndex end
    renameIndex, renameRev = {}, DirectorNodes.rev
    for t, d in pairs(DirectorNodes._types) do
        if type(d.renamed) == 'table' then
            for old, r in pairs(d.renamed) do renameIndex[old] = { type = t, pins = type(r) == 'table' and r.pins or nil } end
        end
    end
    return renameIndex
end

--- The document as the cards it names are called now: itself when nothing was renamed, otherwise a copy
--- with the renamed cards' types and their wires' pins changed.
---@param doc table
---@return table
function DirectorNodes.applyRenames(doc)
    if type(doc) ~= 'table' or type(doc.nodes) ~= 'table' then return doc end
    local idx = renames()
    if next(idx) == nil then return doc end
    local moved, nodes = {}, nil
    for i, n in ipairs(doc.nodes) do
        local r = type(n) == 'table' and type(n.type) == 'string' and idx[n.type] or nil
        if r and DirectorNodes._types[n.type] == nil then
            nodes = nodes or table.move(doc.nodes, 1, #doc.nodes, 1, {})
            local copy = {}
            for k, v in pairs(n) do copy[k] = v end
            copy.type = r.type
            nodes[i] = copy
            if type(n.id) == 'string' then moved[n.id] = r end
        end
    end
    if not nodes then return doc end
    local out = {}
    for k, v in pairs(doc) do out[k] = v end
    out.nodes = nodes
    if type(doc.links) == 'table' then
        local links = {}
        for i, l in ipairs(doc.links) do
            local from = type(l) == 'table' and l.from or nil
            local r = type(from) == 'table' and moved[from.node] or nil
            local pin = r and type(from) == 'table' and r.pins and type(from.pin) == 'string' and r.pins[from.pin] or nil
            if pin and type(from) == 'table' then
                local cl = {}
                for k, v in pairs(l) do cl[k] = v end
                cl.from = { node = from.node, pin = pin }
                links[i] = cl
            else
                links[i] = l
            end
        end
        out.links = links
    end
    return out
end

--- What the editor needs to draw every card: no functions, nothing server-only.
---@return table
function DirectorNodes.wire()
    local out = {}
    for t, d in pairs(DirectorNodes._types) do
        local props = {}
        for i, f in ipairs(d.props) do
            props[i] = { key = f.key, kind = f.kind, label = f.label, default = f.default, required = f.required,
                         options = f.kind == 'players' and DirectorNodes.PLAYERS or f.options,
                         optionLabels = f.optionLabels or (f.kind == 'players' and DirectorNodes.PLAYER_LABELS or nil),
                         worldKind = f.worldKind, weaponsOnly = f.weaponsOnly == true or nil, withTasks = f.withTasks == true or nil,
                         groups = f.groups == true or nil,   -- (a 'worlds' field that takes named groups too)
                         slider = f.slider == true or nil,   -- (a number drawn as a slider: panels.js fieldHtml)
                         min = f.min, max = f.max, maxLength = f.maxLength,
                         hint = f.hint, unit = f.unit, lines = f.lines, group = f.group, of = f.of, bySpot = f.bySpot,
                         -- (Shown only while its `when` holds: html/js/director/when.js. A list another resource's
                         -- button fills: cards_api.lua. Its own widget on the page: its ui, panels.js FIELD_UI.)
                         when = f.when, button = f.button, add = f.add, ui = f.ui }
        end
        local owner = Cards:ownerOf(t) or CORE
        out[#out + 1] = { type = t, v = d.v, category = d.category, title = d.title, desc = d.desc, labels = d.labels,
                          inputs = d.inputs, outputs = d.outputs, props = props, latent = d.latent == true,
                          event = d.event ~= nil, owner = owner, help = d.help, categoryTitle = d.categoryTitle,
                          color = d.color, icon = d.icon, bad = d.bad, permission = d.permission,
                          -- (A Fail Condition: wired to nothing, it watches the whole run: nodes_conditions.lua.)
                          condition = d.condition == true or nil,
                          pinWhen = d.pinWhen, repeats = d.repeats, talks = d.talks == true or nil,
                          givesItems = d.givesItems == true or nil,
                          -- (How the editor draws it: its face, width and page extras; outcomes called by a field;
                          -- the prompt it puts up, for the world builder; what a Haggle can agree of it.)
                          ui = d.ui, pinText = d.pinText, prompt = d.prompt,
                          haggle = d.haggle and { key = d.haggle.key, unit = d.haggle.unit } or nil }
    end
    table.sort(out, function(a, b) return a.type < b.type end)
    return out
end
