-- ============================================
-- Director — Goal cards: one card, one thing to do
-- ============================================
--
-- "Go to the warehouse" took four cards (Show Objective, Show Blip, Player Arrives, Clear Objective).
-- A GOAL CARD is all of them in one, so a scenario reads like a mission list:
--
--   Goal: Go To            reach a placed thing (any of them, or all)
--   Goal: Deliver the Car  drive the run's car to a placed thing     Car lost: gone, blown up or sunk
--   Goal: Kill Them All    every NPC made for a placed thing down     each one marked red
--   Goal: Collect          N of an item between the run's players    counted from when it starts
--   Goal: Bring Item To    carry an item to a place or an NPC        taken off them there (unless not)
--   Goal: Steal the Car    get in the run's car (its driver's seat)  Car lost: gone, blown up or sunk first
--   Goal: Search           open the run's container
--   Goal: Speak To         finish talking with an NPC (a Dialog Line's last answer)   NPC lost: dead or gone
--   Goal: Survive          stay up for a time (and in an area)       Failed: all down, or all gone
--
-- While it waits, each shows its objective on every run player's band (server/director/band.lua) and
-- marks where to go on their maps; an optional time limit counts down beside the objective and goes
-- out of "Out of time". When the goal ends, whichever way, what it showed goes: its objective (only if
-- it is still the one on screen), its clock and its marks.

local CORE = GetCurrentResourceName()

local define = DirectorKit.define
local vec = DirectorKit.vec3

local function within(a, b, r)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz <= r * r
end

local playerPos = DirectorKit.playerPos

local itemName = DirectorKit.itemName

--- The NPCs a card made for a placed thing (all of a group, or the one; a standing one too).
local function npcsOf(ctx, worldId) return DirectorNodes.npcIds(Director.handleOf(ctx.run, worldId)) end

-- Where a placed thing is NOW (an NPC where it stands, the run's car where it is), and who a mark is for: nodes.lua.
local whereNow = DirectorNodes.whereNow
local charsOf = DirectorNodes.peopleOf

-- (The run's car, lost or not: DirectorNodes.carLook, nodes.lua. Arrived, delivered: DirectorSpots, spots.lua, as
-- Player Arrives and Car Delivered ask them.)

-- ============================================
-- What every goal does: objective, clock, marks
-- ============================================

local serial = 0

--- Start a goal for the run's players: its objective on their band and, with a time limit, its clock
--- (going out of 'timeout'; `untimed`: a card with no time limit field). Answers the goal: g.say(text)
--- changes the objective, g.mark(name, coords, spec) puts or moves a mark on their maps, g.unmark(name)
--- takes one off. All of it goes when the card ends.
local function goal(ctx, text, untimed)
    local run = ctx.run
    serial = serial + 1
    local g = { key = ('goal:%s:%d'):format(ctx.node.id, serial), who = ctx:players(), marks = {} }

    -- New words where its objective stands (a count), never above an objective put up since.
    function g.say(t)
        g.text = t
        for _, s in ipairs(g.who) do DirectorBand.reword(run, s, g.key, t) end
    end

    -- A mark on the maps of those of the goal still in the run: one who left was taken off its marks
    -- (main.lua's leave), and a mark that moves must not put them back.
    local function show(id, b)
        local still = {}
        for _, s in ipairs(g.who) do if ctx:isPlayer(s) then still[#still + 1] = s end end
        local people = charsOf(still)
        local ok, why = Blips.show(CORE, { people = people }, id, b)
        -- Kept, so a player leaving the run is taken off it (main.lua's leave).
        if ok and run.blips then run.blips[id] = { spec = b, people = people } end
        return ok, why
    end

    function g.mark(name, at, spec)
        if not at then return end
        local m = g.marks[name]
        if m and within(m.at, at, 3.0) then return end   -- moved too little to send again
        local id = ('%s:%s:%s'):format(ctx:tag(), g.key, name)
        local b = { coords = vector3(at.x, at.y, at.z), label = spec.label, color = spec.color or 5,
                    route = spec.route == true, radius = spec.radius, tag = ctx:tag() }
        local ok, why = show(id, b)
        if not ok then
            ctx:log('mark %s: %s', tostring(name), tostring(why))
            return
        end
        g.marks[name] = { id = id, at = at, spec = b }
    end

    function g.unmark(name)
        local m = g.marks[name]
        if not m then return end
        g.marks[name] = nil
        Blips.remove(CORE, m.id)
        if run.blips then run.blips[m.id] = nil end
    end

    -- Its clock on their band (`seconds` from now); the card says what it goes out of.
    local endsAt, clockLabel
    function g.clock(seconds, label)
        for _, s in ipairs(g.who) do DirectorBand.clock(run, s, g.key, seconds, label) end
        endsAt, clockLabel = GetGameTimer() + math.floor(seconds * 1000), label
    end

    g.text = text
    for _, s in ipairs(g.who) do DirectorBand.objective(run, s, text, g.key) end
    local seconds = not untimed and tonumber(ctx:prop('seconds')) or nil
    if seconds then
        -- Its words as the clock's own: shown with it should another card's objective come and go.
        g.clock(seconds, text)
        ctx:after(seconds * 1000, 'timeout')
    end
    -- THE GOAL IS THE CREW'S AS IT IS (the Director API): one a script puts in gets its objective, what
    -- is left of its clock and its marks; one taken out is off them (their band went with them).
    Director.followCrew(run, g.key, function(players)
        local had = {}
        for _, s in ipairs(g.who) do had[s] = true end
        local now = {}
        for _, s in ipairs(players) do
            now[#now + 1] = s
            if not had[s] then
                DirectorBand.objective(run, s, g.text, g.key)
                local left = endsAt and (endsAt - GetGameTimer()) / 1000.0
                if left and left > 0 then DirectorBand.clock(run, s, g.key, left, clockLabel) end
            end
        end
        g.who = now
        local names = {}
        for name in pairs(g.marks) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local m = g.marks[name]
            local ok, why = show(m.id, m.spec)
            if not ok then ctx:log('mark %s: %s', tostring(name), tostring(why)) end
        end
    end)
    ctx:onEnd(function()
        Director.followCrew(run, g.key, nil)
        for _, s in ipairs(g.who) do
            DirectorBand.clearObjective(run, s, g.key)
            DirectorBand.stopClock(run, s, g.key)
        end
        local names = {}
        for name in pairs(g.marks) do names[#names + 1] = name end
        for _, name in ipairs(names) do g.unmark(name) end
    end)
    return g
end

--- With no time limit there is no "Out of time" (a card's pinWhen: server/director/fields.lua).
local NO_LIMIT = DirectorFields.TIMES_OUT

--- A GOAL CARD, said once: what every goal has is added here, never written on each card.
---   objective    the words its Objective field starts with ('' for words of the card's own, objectiveOf(ctx), when
---                the field is left empty)
---   props        its own fields, between the Objective and the goal's Mark it and Time limit
---   outputs      its own outcomes; Out of time is added (an outcome only with a time limit)
---   run(ctx, up, words)  up(text?) brings the goal up when the card is ready to: its objective (`words`, the field's
---                or its own) on the run's band with its clock, answering the goal (goal() above)
---   untimed      no Time limit (Survive keeps a clock of its own); markLabel: its Mark field's words
local function goalCard(def)
    -- The card's own run(ctx, up, words): def.run becomes the wrapper below.
    local own, untimed = def.run --[[@as fun(ctx: table, up: function, words: any): ...]], def.untimed == true
    def.category, def.latent = 'goals', true
    def.labels = def.labels or {}
    local props = { { key = 'text', kind = 'text', label = 'Objective (on screen)', default = def.objective, maxLength = 120 } }
    for _, f in ipairs(def.props or {}) do props[#props + 1] = f end
    props[#props + 1] = { key = 'mark', kind = 'bool', label = def.markLabel or 'Mark it on the map', default = true }
    if not untimed then
        props[#props + 1] = { key = 'seconds', kind = 'duration', label = 'Time limit (seconds; empty: none)', min = 5, max = 86400 }
        def.outputs[#def.outputs + 1] = 'timeout'
        def.labels.timeout = 'Out of time'
        def.pinWhen = NO_LIMIT
    end
    def.props = props
    def.run = function(ctx)
        local said = ctx:prop('text')
        local words = (type(said) == 'string' and said ~= '') and said
            or (def.objectiveOf and def.objectiveOf(ctx)) or def.objective
        return own(ctx, function(text) return goal(ctx, text or words, untimed) end, words)
    end
    return define(def)
end

-- ============================================
-- Go To
-- ============================================

goalCard({
    type = 'goal.goTo', v = 1, title = 'Goal: Go To', objective = 'Go to the marked spot',
    desc = 'Tells the players to go somewhere, marks it on their map, and goes on when they get there.',
    outputs = { 'done' },
    labels = { done = 'Arrived' },
    props = {
        { key = 'at', kind = 'world', label = 'Where (a placed thing)', required = true },
        -- (A spot with a marker says how near and who: server/director/spots.lua.)
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 10, min = 1, max = 500, bySpot = 'at' },
        DirectorNodes.anyAllField('Who must get there', nil, { bySpot = 'at' }),
    },
    run = function(ctx, up)
        local atW = ctx.node.props.at
        local w = ctx:place(atW)
        local at = vec(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
        if not at then
            ctx:log('%s has no spot', tostring(atW))
            return nil
        end
        local radius = tonumber(ctx:prop('radius')) or 10
        local all = DirectorNodes.wantsAll(ctx)
        local g = up()
        if ctx:prop('mark') ~= false then g.mark('at', at, { label = w.label, route = true }) end
        local spot = DirectorSpots.watch(ctx, w)
        ctx:poll(1000, function()
            local ok, src = DirectorSpots.arrived(ctx, spot, at, radius, all)
            if not ok then return nil end
            Director.event(ctx.run, ctx.node.id, 'arrived', src)
            return 'done', { source = src }
        end)
        return nil
    end,
})

-- ============================================
-- Deliver the Car
-- ============================================

goalCard({
    type = 'goal.deliverCar', v = 1, title = 'Goal: Deliver the Car', objective = 'Deliver the car to the marked spot',
    desc = 'Tells the players to drive the scenario\'s car to a placed thing, and marks it. Car lost: destroyed or gone.',
    outputs = { 'done', 'lost' },
    labels = { done = 'Delivered', lost = 'Car lost' },
    props = {
        { key = 'car', kind = 'world', worldKind = 'vehicle', label = 'Car', required = true },
        { key = 'at', kind = 'world', label = 'Drop-off (a placed thing)', required = true },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 8, min = 1, max = 100, bySpot = 'at' },
        { key = 'driven', kind = 'bool', label = 'Only a player in the scenario can complete this goal', default = true },
    },
    run = function(ctx, up)
        local carW, atW = ctx.node.props.car, ctx.node.props.at
        local w = ctx:place(atW)
        local at = vec(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
        if not at then
            ctx:log('%s has no spot', tostring(atW))
            return 'lost'
        end
        local radius = tonumber(ctx:prop('radius')) or 8
        local driven = ctx:prop('driven') ~= false
        local g = up()
        if ctx:prop('mark') ~= false then g.mark('at', at, { label = w.label, route = true }) end
        -- (A marker's shape only: its car is this card's.)
        local spot = DirectorSpots.watch(ctx, w)
        local look = DirectorNodes.carLook(ctx, carW)
        ctx:poll(1000, function()
            local ent, lost = look()
            if not ent then return lost and 'lost' or nil end
            local ok, src = DirectorSpots.delivered(ctx, spot, ent, at, radius, driven)
            if not ok then return nil end
            if not src then return 'done' end
            Director.event(ctx.run, ctx.node.id, 'delivered', src)
            return 'done', { source = src }
        end)
        return nil
    end,
})

-- ============================================
-- Kill Them All
-- ============================================

goalCard({
    type = 'goal.killAll', v = 2, title = 'Goal: Kill Them All', objective = 'Take them out',
    desc = 'Tells the players to take out every NPC picked (and every one in the groups picked), marks each one red, and goes on when the last is down.',
    outputs = { 'done' },
    labels = { done = 'All down' },
    upgrade = function(props) return DirectorNodes.toList(props, 'npc') end,
    props = {
        DirectorNodes.thingsField('npc', 'npc', 'NPCs (or groups)'),
    },
    run = function(ctx, up, text)
        local mark = ctx:prop('mark') ~= false
        local g = up()
        local lastLeft
        local madeAny = false   -- (none made yet: a card before their Spawn NPC waits, never "all down")
        -- Every NPC made for each of them, once.
        local function all()
            local out, seen = {}, {}
            for _, wid in ipairs(DirectorNodes.things(ctx, 'npc')) do
                for _, id in ipairs(npcsOf(ctx, wid)) do
                    if not seen[id] then seen[id] = true; out[#out + 1] = id end
                end
            end
            return out
        end
        local function look(first)
            local left = 0
            local ids = all()
            if #ids > 0 then madeAny = true end
            for _, id in ipairs(ids) do
                local info = Npcs.get(id)
                local name = 'npc' .. tostring(id)
                if info and info.alive then
                    left = left + 1
                    if mark then g.mark(name, vec(info.coords), { label = 'Target', color = 1 }) end
                else
                    g.unmark(name)
                end
            end
            if left ~= lastLeft and left > 1 then g.say(('%s (%d left)'):format(text, left)) end
            if left == 1 and lastLeft ~= 1 then g.say(text) end
            lastLeft = left
            if left > 0 or first or not madeAny then return nil end
            Director.event(ctx.run, ctx.node.id, 'all down')
            return 'done'
        end
        ctx:poll(1000, function() return look(false) end)
        look(true)   -- the marks at once; whether they are all down is the poll's to answer
        return nil
    end,
})

-- ============================================
-- Collect
-- ============================================

goalCard({
    type = 'goal.collect', v = 1, title = 'Goal: Collect', objective = '',
    objectiveOf = function(ctx) return ('Collect %s'):format(itemName(ctx:prop('item'))) end,
    desc = 'Tells the players to collect a number of one of the scenario\'s items, counted across the whole team.',
    outputs = { 'done' },
    labels = { done = 'Collected' },
    props = {
        -- (One the scenario places or gives: only those stacks count, never the player's own of it.)
        { key = 'item', kind = 'runItem', label = 'Item (one the scenario places or gives)', required = true },
        { key = 'count', kind = 'number', label = 'How many', default = 5, min = 1, max = 1000 },
        { key = 'at', kind = 'world', label = 'Where to look (optional, marked as an area)' },
        { key = 'radius', kind = 'number', label = 'Area size (metres)', default = 50, min = 5, max = 2000 },
    },
    run = function(ctx, up, text)
        local item = ctx:prop('item')
        local want = math.max(1, math.floor(tonumber(ctx:prop('count')) or 5))
        -- What each already carried does not count: only what they pick up from now.
        local base = {}
        for _, s in ipairs(ctx:players()) do base[s] = Director.carried(s, item, ctx.run, true) end
        local g = up(want > 1 and ('%s (0/%d)'):format(text, want) or text)
        if ctx:prop('mark') ~= false and ctx.node.props.at then
            local at = whereNow(ctx, ctx.node.props.at)
            g.mark('area', at, { label = text, radius = tonumber(ctx:prop('radius')) or 50, route = false })
        end
        local shown = 0
        ctx:poll(1000, function()
            local got = 0
            for _, s in ipairs(ctx:players()) do
                got = got + math.max(0, Director.carried(s, item, ctx.run, true) - (base[s] or 0))
            end
            got = math.min(got, want)
            if got ~= shown and want > 1 then g.say(('%s (%d/%d)'):format(text, got, want)) end
            shown = got
            if got < want then return nil end
            Director.event(ctx.run, ctx.node.id, 'collected', nil, ('%s x%d'):format(item, want))
            return 'done'
        end)
        return nil
    end,
})

-- ============================================
-- Bring Item To
-- ============================================

goalCard({
    type = 'goal.bring', v = 1, title = 'Goal: Bring Item To', objective = 'Bring it to the marked spot',
    desc = 'Tells the players to bring one of the scenario\'s items to a placed thing or an NPC. Done when a player gets there with it.',
    outputs = { 'done' },
    labels = { done = 'Brought' },
    props = {
        -- (One the scenario places or gives: only those stacks count and are taken, never the player's own of it.)
        { key = 'item', kind = 'runItem', label = 'Item (one the scenario places or gives)', required = true },
        { key = 'count', kind = 'number', label = 'How many', default = 1, min = 1, max = 1000 },
        { key = 'at', kind = 'world', label = 'To (a placed thing, or an NPC)', required = true },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 3, min = 1, max = 50, bySpot = 'at' },
        { key = 'take', kind = 'bool', label = 'Take it off the player there', default = true },
    },
    run = function(ctx, up)
        local run, atW = ctx.run, ctx.node.props.at
        local item = ctx:prop('item')
        local want = math.max(1, math.floor(tonumber(ctx:prop('count')) or 1))
        local radius = tonumber(ctx:prop('radius')) or 3
        local take = ctx:prop('take') ~= false
        local w = ctx:place(atW)
        local g = up()
        local mark = ctx:prop('mark') ~= false
        -- (A marker's shape only: who carries the item is this card's. An NPC has none.)
        local spot = DirectorSpots.watch(ctx, w)
        -- Looked for a second at a time. Taking it off them can wait (their pockets are saved), so only the
        -- take is a call of its own, one at a time; one it misses (they dropped it that moment) answers
        -- nothing, and the looking goes on.
        local taking = false
        ctx:poll(1000, function()
            if taking then return nil end
            local at = whereNow(ctx, atW)
            if not at then return nil end
            if mark then g.mark('at', at, { label = type(w) == 'table' and w.label or nil, route = true }) end
            for _, s in ipairs(ctx:players()) do
                local p = playerPos(s)
                if p and DirectorSpots.near(spot, p, at, radius) and Director.carried(s, item, run, true) >= want then
                    if not take then
                        Director.event(run, ctx.node.id, 'brought', s, item)
                        return 'done', { source = s }
                    end
                    -- A test takes nothing (as Sell to NPC and an answer's cost): it says what it would take.
                    if run.test then
                        NotifyPlayer(s, ('Test: this would take %d× %s'):format(want, itemName(item)), 'info')
                        Director.event(run, ctx.node.id, 'brought (test)', s, item)
                        return 'done', { source = s }
                    end
                    taking = true
                    ctx:call(function()
                        -- What it counted: this run's own, never theirs or another's.
                        local ok = Inventory.take(s, item, want, Director.reason(run) .. ' (handed over)', Director.onlyOwn(run))
                        taking = false
                        if not ok then return nil end
                        Director.event(run, ctx.node.id, 'handed over', s, ('%s x%d'):format(item, want))
                        return 'done', { source = s }
                    end)
                    return nil
                end
            end
            return nil
        end)
        return nil
    end,
})

-- ============================================
-- Steal the Car
-- ============================================

goalCard({
    type = 'goal.stealCar', v = 1, title = 'Goal: Steal the Car', objective = 'Steal the car',
    desc = 'Tells the players to steal the scenario\'s car, and marks it. Done when one of them is in the driver\'s seat. Car lost: destroyed or gone.',
    outputs = { 'done', 'lost' },
    labels = { done = 'In the car', lost = 'Car lost' },
    props = {
        { key = 'car', kind = 'world', worldKind = 'vehicle', label = 'Car', required = true },
        { key = 'driver', kind = 'bool', label = 'Only the driver\'s seat', default = true },
    },
    run = function(ctx, up)
        local carW = ctx.node.props.car
        local driverOnly = ctx:prop('driver') ~= false
        local mark = ctx:prop('mark') ~= false
        local g = up()
        local w = ctx:place(carW)
        local look = DirectorNodes.carLook(ctx, carW)
        ctx:poll(1000, function()
            local ent, lost = look()
            if not ent then return lost and 'lost' or nil end
            if mark then g.mark('car', GetEntityCoords(ent), { label = type(w) == 'table' and w.label or 'Car', color = 3 }) end
            local driver = GetPedInVehicleSeat(ent, -1)
            for _, s in ipairs(ctx:players()) do
                local ped = GetPlayerPed(s)
                if ped and ped ~= 0 and (driver == ped or (not driverOnly and GetVehiclePedIsIn(ped, false) == ent)) then
                    Director.event(ctx.run, ctx.node.id, 'got in', s)
                    return 'done', { source = s }
                end
            end
            return nil
        end)
        return nil
    end,
})

-- ============================================
-- Search
-- ============================================

goalCard({
    type = 'goal.search', v = 1, title = 'Goal: Search', objective = 'Search the marked spot',
    desc = 'Tells the players to search the scenario\'s container (Create Container first), marks it, and goes on when one of them opens it.',
    outputs = { 'done' },
    labels = { done = 'Opened' },
    props = {
        { key = 'container', kind = 'world', worldKind = 'container', label = 'Container', required = true },
    },
    run = function(ctx, up)
        local cW = ctx.node.props.container
        local w = ctx:place(cW)
        local g = up()
        if ctx:prop('mark') ~= false then
            g.mark('at', vec(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil),
                { label = type(w) == 'table' and w.label or nil, route = true })
        end
        ctx:on('container.opened', function(p)
            if type(p) ~= 'table' or not ctx:isPlayer(p.source) then return nil end
            local h = ctx:handle(cW)
            if type(h) ~= 'table' or h.containerId ~= p.containerId then return nil end
            -- The server's own word that they have it open now (any resource could fire the event).
            if not Stores.isViewer(p.source, 'container:' .. tostring(p.containerId)) then return nil end
            Director.event(ctx.run, ctx.node.id, 'searched', p.source)
            return 'done', { source = p.source }
        end)
        return nil
    end,
})

-- ============================================
-- Speak To
-- ============================================
--
-- Done when one of the run's players has finished talking with the NPC: answered a Dialog Line of theirs with an
-- answer that leads on to no more of their lines (DirectorTalk.continuesTo). Not "any talk with them ended": walking
-- away, giving no answer and a chance answer all end a talk too. The Dialog Line gives the Talk prompt, so it is
-- wired beside this (or before it).

--- An NPC's name as players know it: its lore character's as it is now, else its own.
local function npcName(run, npcW)
    local w = run.graph.world[npcW]
    if type(w) ~= 'table' then return nil end
    local lore = type(w.def) == 'table' and w.def.lore and DirectorLore and DirectorLore.get(w.def.lore) or nil
    return (lore and lore.name) or w.label
end

--- A Dialog Line's own objective (its page: As a goal), so "talk to Lester" is one card: the objective on the run's
--- band while it waits, its clock when the card has a time limit, and (unless `mark` is false) a mark on their maps
--- that follows the NPC. All of it goes when the card ends, as every goal's does.
function DirectorNodes.talkGoal(ctx, npcW, text, seconds, mark)
    local g = goal(ctx, text, true)
    if seconds then g.clock(seconds, text) end
    if mark == false then return g end
    local name = npcName(ctx.run, npcW)
    local function look()
        for _, id in ipairs(npcsOf(ctx, npcW)) do
            local i = Npcs.get(id)
            if i and i.alive and i.coords then
                g.mark('npc', vec(i.coords), { label = name, route = true })
                return nil
            end
        end
        return nil
    end
    ctx:poll(1000, look)
    look()
    return g
end

goalCard({
    type = 'goal.speakTo', v = 1, title = 'Goal: Speak To', objective = '',
    objectiveOf = function(ctx) return ('Speak to %s'):format(npcName(ctx.run, ctx.node.props.npc) or 'them') end,
    desc = 'Tells the players to talk to an NPC, and marks them. Wire their Dialog Line beside this. NPC lost: dead or gone.',
    outputs = { 'done', 'lost' },
    labels = { done = 'Spoke', lost = 'NPC lost' },
    props = { { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who', required = true } },
    check = function(props, doc)
        for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
            local d = type(n) == 'table' and DirectorNodes.get(n.type)
            if d and d.talks and type(n.props) == 'table' and n.props.npc == props.npc then
                return nil
            end
        end
        return 'no talking card (a Dialog Line, a Haggle) has this NPC as Who: there is nothing to finish talking about', 'warning'
    end,
    run = function(ctx, up)
        local run, npcW = ctx.run, ctx.node.props.npc
        local name = npcName(run, npcW) or 'them'
        local g = up()
        local mark = ctx:prop('mark') ~= false
        ctx:on('conversation.choice', function(p)
            if type(p) ~= 'table' or p.runId ~= run.id or not ctx:isPlayer(p.source) then return nil end
            local n = run.graph.nodes[p.nodeId]
            if not n or not n.def.talks or n.props.npc ~= npcW then return nil end
            if DirectorTalk.continuesTo(run.graph, n, p.option) then return nil end   -- (the talk goes on: a talking card next)
            Director.event(run, ctx.node.id, 'spoke to', p.source, name)
            return 'done', { source = p.source }
        end)
        -- The mark follows them; three looks in a row with none of them up is lost (not made yet is not).
        local goneFor = 0
        local function look()
            local ids, alive = npcsOf(ctx, npcW), nil
            for _, id in ipairs(ids) do
                local i = Npcs.get(id)
                if i and i.alive then alive = i break end
            end
            if alive then
                goneFor = 0
                if mark and alive.coords then g.mark('npc', vec(alive.coords), { label = name, route = true }) end
                return nil
            end
            if #ids == 0 then return nil end
            goneFor = goneFor + 1
            if goneFor < 3 then return nil end
            Director.event(run, ctx.node.id, 'NPC lost', nil, name)
            return 'lost'
        end
        ctx:poll(1000, look)
        look()
        return nil
    end,
})

-- ============================================
-- Survive
-- ============================================

goalCard({
    type = 'goal.survive', v = 1, title = 'Goal: Survive', objective = 'Survive',
    untimed = true, markLabel = 'Mark the area on the map',
    desc = 'Tells the players to hold out for a time, and stay in an area if set. Failed: all down, or all left the area.',
    outputs = { 'done', 'failed' },
    labels = { done = 'Survived', failed = 'Failed' },
    props = {
        { key = 'length', kind = 'duration', label = 'For (seconds)', default = 120, min = 5, max = 86400 },
        { key = 'at', kind = 'world', label = 'Stay near (optional)' },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 50, min = 5, max = 2000 },
    },
    run = function(ctx, up)
        local run = ctx.run
        local length = math.max(5, math.min(86400, tonumber(ctx:prop('length')) or 120))
        local g = up()
        -- Its length is the clock: on screen, going out of Survived.
        g.clock(length, g.text)
        ctx:after(length * 1000, 'done')
        local at = ctx.node.props.at and whereNow(ctx, ctx.node.props.at) or nil
        local radius = tonumber(ctx:prop('radius')) or 50
        if at and ctx:prop('mark') ~= false then g.mark('area', at, { label = 'Stay here', radius = radius }) end
        local outFor = 0
        ctx:poll(1000, function()
            local standing, inside, n = 0, 0, 0
            for _, s in ipairs(ctx:players()) do
                n = n + 1
                local me = Players[s]
                if me and not me.isDead then
                    standing = standing + 1
                    local p = playerPos(s)
                    if at and p and within(p, at, radius) then inside = inside + 1 end
                end
            end
            if n > 0 and standing == 0 then
                Director.event(run, ctx.node.id, 'all went down')
                return 'failed'
            end
            -- All of them out of the area for a few seconds running (not one step over its edge).
            if at and inside == 0 then outFor = outFor + 1 else outFor = 0 end
            if outFor >= 3 then
                Director.event(run, ctx.node.id, 'left the area')
                return 'failed'
            end
            return nil
        end)
        return nil
    end,
})
