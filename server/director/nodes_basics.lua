-- ============================================
-- Director — everyday cards
-- ============================================
--
--   Give Item           straight into their pockets (at their feet when it does not fit)
--   Player Has Item?    a branch: yes or no
--   Player Has Money?   a branch: cash, bank, or either
--   Charge Player       take money: Paid, or Could not pay
--   Player Downed       when one of the run's players goes down (or all of them have)
--   Random Chance       yes some of the time, otherwise no
--   Countdown           a clock on screen (the run's band: server/director/band.lua); Time's up
--   Remove              takes away what the run made for a placed thing, mid-run
--   Car Destroyed       the run's car blown up or gone
--   Car Damaged         the run's car damaged past a share, from when the card started
--
-- What a run hands out, pays and charges goes the run's way (server/director/effects.lua): stamped and taken back at
-- its end unless the card says it is theirs to keep; a test keeps nothing and charges nothing.

local CORE = GetCurrentResourceName()

local define = DirectorKit.define

local WHO_HAS = { 'this player', 'anyone in the run', 'everyone in the run' }

local function itemDef(key)
    return type(key) == 'string' and type(Config) == 'table' and Config.Items and Config.Items[key] or nil
end

local money = DirectorKit.money

--- The players a card is for (its `players` field: server/director/fields.lua).
local playersFor = DirectorFields.playersOf

-- ============================================
-- Give Item
-- ============================================

define({
    type = 'player.giveItem', v = 1, category = 'player', title = 'Give Item', givesItems = true, giveUp = 15,
    haggle = { key = 'amount', toPlayer = true, unit = 'count' },   -- (a Haggle can agree how many: nodes_talk.lua)
    desc = 'Puts an item straight into the player\'s pockets (at their feet if it does not fit). Theirs to keep; in a test, taken back when it ends.',
    outputs = { 'given', 'failed', 'timeout' },
    latent = true, yields = true,
    props = {
        { key = 'item', kind = 'item', label = 'Item', required = true },
        { key = 'amount', kind = 'number', label = 'How many', default = 1, min = 1, max = 100 },
        { key = 'who', kind = 'players', label = 'To', default = 'this player' },
    },
    run = function(ctx)
        local run = ctx.run
        local item = ctx:prop('item')
        if not itemDef(item) then
            ctx:log('%s is not an item on this server', tostring(item))
            return 'failed'
        end
        local to = playersFor(ctx, ctx:prop('who'))
        if #to == 0 then return 'failed' end
        local amount = math.max(1, math.min(100, math.floor(tonumber(ctx:prop('amount')) or 1)))
        local data = { source = to[1] }
        ctx:call(function()
            -- (The run's way: real in a live run, stamped and taken back in a test: effects.lua.)
            local gave = 0
            for _, s in ipairs(to) do
                if run.status ~= 'running' then break end   -- its end has swept: no more
                if ctx:isPlayer(s) then
                    local n, why = DirectorEffects.give(run, ctx.node.id, s, item, amount)
                    if n > 0 then gave = gave + 1 else ctx:log('could not give %s to %s: %s', item, tostring(s), tostring(why)) end
                end
            end
            return gave > 0 and 'given' or 'failed', data
        end)        return nil
    end,
})

-- ============================================
-- Has Item? / Has Money?
-- ============================================

define({
    type = 'player.hasItem', v = 1, category = 'flow', title = 'Player Has Item?',
    desc = 'Goes Yes when the player carries the item (how many), otherwise No: the keycard, the package.',
    outputs = { 'yes', 'no' },
    branch = true,
    props = {
        { key = 'item', kind = 'item', label = 'Item', required = true },
        { key = 'count', kind = 'number', label = 'At least', default = 1, min = 1, max = 1000 },
        { key = 'who', kind = 'select', label = 'Who', options = WHO_HAS, default = WHO_HAS[1],
          optionLabels = { [WHO_HAS[2]] = 'anyone in the scenario', [WHO_HAS[3]] = 'everyone in the scenario' } },
    },
    run = function(ctx)
        local item = ctx:prop('item')
        local count = math.max(1, math.floor(tonumber(ctx:prop('count')) or 1))
        local who = ctx:prop('who')
        if who == 'this player' then
            local s = Director.playerOf(ctx)
            return (s and Director.carried(s, item, ctx.run) >= count) and 'yes' or 'no'
        end
        local list = ctx:players()
        local first, all = nil, #list > 0
        for _, s in ipairs(list) do
            if Director.carried(s, item, ctx.run) >= count then first = first or s else all = false end
        end
        if who == 'everyone in the run' then return all and 'yes' or 'no' end
        if first then return 'yes', { source = first } end
        return 'no'
    end,
})

local WHERE_MONEY = { 'cash or bank', 'cash', 'bank' }
local bankBalance = DirectorEffects.bankBalance

define({
    type = 'player.hasMoney', v = 1, category = 'flow', title = 'Player Has Money?', giveUp = 15,
    desc = 'Goes Yes when the player has the money: cash on them, in their bank, or either one. Otherwise No.',
    outputs = { 'yes', 'no', 'timeout' },
    branch = true, latent = true, yields = true,
    pinWhen = { timeout = { key = 'where', isnt = 'cash' } },   -- (cash alone is read at once: nothing to wait for)
    props = {
        { key = 'amount', kind = 'number', label = 'At least ($)', default = 100, min = 1, max = 10000000 },
        { key = 'where', kind = 'select', label = 'In', options = WHERE_MONEY, default = WHERE_MONEY[1] },
    },
    run = function(ctx)
        local src = Director.playerOf(ctx)
        if not src then return 'no' end
        local amount = math.floor(tonumber(ctx:prop('amount')) or 0)
        local where = ctx:prop('where') or WHERE_MONEY[1]
        local data = { source = src }
        if where ~= 'bank' and Director.carried(src, 'cash', ctx.run) >= amount then return 'yes', data end
        if where == 'cash' then return 'no', data end
        ctx:call(function()
            local balance = bankBalance(src)
            if balance == nil then return 'no', data end
            return balance >= amount and 'yes' or 'no', data
        end)        return nil
    end,
})

-- ============================================
-- Charge Player
-- ============================================

define({
    type = 'player.charge', v = 1, category = 'player', title = 'Charge Player', giveUp = 15,
    haggle = { key = 'amount', toPlayer = false, unit = 'money' },   -- (a Haggle can agree its amount: nodes_talk.lua)
    desc = 'Takes money from the player (cash, bank, or cash if they carry enough). Could not pay: they have not got it. A test only says what it would take.',
    outputs = { 'paid', 'short', 'timeout' },
    labels = { paid = 'Paid', short = 'Could not pay' },
    latent = true, yields = true,
    props = {
        { key = 'amount', kind = 'number', label = 'Amount ($)', default = 100, min = 1, max = 1000000 },
        { key = 'method', kind = 'select', label = 'How', options = { 'auto', 'cash', 'bank' }, default = 'auto' },
        { key = 'reason', kind = 'text', label = 'What it is for', maxLength = 120, default = 'Payment' },
    },
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'short' end
        local amount = math.floor(tonumber(ctx:prop('amount')) or 0)
        local method, reason = ctx:prop('method') or 'auto', ctx:prop('reason')
        local data = { source = src }
        local charged = nil   -- the receipt, once taken
        ctx:call(function()
            -- (The run's way: a test charges nothing, but whether they could pay decides the way on: effects.lua.)
            local receipt, why = DirectorEffects.charge(run, ctx.node.id, src, amount, { method = method, reason = reason })
            if not receipt then
                if not run.test then ctx:log('charge %s %s: %s', tostring(src), money(amount), tostring(why)) end
                return 'short', data
            end
            charged = receipt
            return 'paid', data
        end, {
            -- Paid after the card gave up (a slow bank write past the 15 s): the run went on as Took Too Long, so the
            -- money goes back, never paid for nothing.
            late = DirectorEffects.lateCharge(run, amount, function() return charged end),
        })        return nil
    end,
})

-- ============================================
-- Player has died
-- ============================================

define({
    type = 'player.downed', v = 1, category = 'events', title = 'Player has died',
    desc = 'Triggered upon a player dying.',
    outputs = { 'out' },
    props = { DirectorNodes.anyAllField('Who') },
    event = {
        -- Once, as every event card is: a listener that never ends would keep a finished run waiting.
        name = 'player.died', once = true,
        -- whip's own record that they are down, not the event's word alone (any resource can fire it).
        filter = function(ctx, p)
            if type(p) ~= 'table' or not ctx:isPlayer(p.source) then return nil end
            local me = Players[p.source]
            if not (me and me.isDead) then return nil end
            if DirectorNodes.wantsAll(ctx) then
                for _, s in ipairs(ctx:players()) do
                    local o = Players[s]
                    if not (o and o.isDead) then return nil end
                end
            end
            Director.event(ctx.run, ctx.node.id, 'went down', p.source)
            return 'out', { source = p.source }
        end,
    },
})

-- ============================================
-- Random Chance
-- ============================================

define({
    type = 'flow.random', v = 1, category = 'flow', title = 'Random Chance',
    desc = 'Goes Yes some of the time (the chance), otherwise No: a guard who only sometimes has the key.',
    outputs = { 'yes', 'no' },
    branch = true,
    props = { { key = 'chance', kind = 'number', label = 'Chance of Yes (%)', default = 50, min = 1, max = 99 } },
    run = function(ctx)
        local chance = math.max(1, math.min(99, math.floor(tonumber(ctx:prop('chance')) or 50)))
        return math.random(100) <= chance and 'yes' or 'no'
    end,
})

-- ============================================
-- Countdown
-- ============================================

local serial = 0

define({
    type = 'flow.countdown', v = 1, category = 'flow', title = 'Countdown',
    desc = 'A clock on screen ("Time left · 9:59") that goes on when it reaches zero. Wire into Stop to call it off (a pulse into Start again starts it over).',
    inputs = { 'start', 'stop' },
    outputs = { 'done', 'stopped' },
    labels = { start = 'Start', stop = 'Stop', done = 'Time\'s up', stopped = 'Stopped' },
    latent = true,
    -- Nothing wired into Stop: it is never stopped.
    unusedPin = function(_, pin, wiredIn) return pin == 'stopped' and not (wiredIn and wiredIn.stop) end,
    props = {
        { key = 'seconds', kind = 'duration', label = 'How long (seconds)', default = 300, min = 1, max = 86400 },
        { key = 'label', kind = 'text', label = 'Says', default = 'Time left', maxLength = 60 },
        { key = 'show', kind = 'bool', label = 'Show it on screen', default = true },
        { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' },
    },
    run = function(ctx)
        local run = ctx.run
        local s = ctx:state()
        if ctx.pin == 'stop' then
            -- (The runtime has already ended the running clock: a pulse restarts a waiting card.)
            if not s.running then return nil end
            s.running = false
            Director.event(run, ctx.node.id, 'stopped the countdown')
            return 'stopped'
        end
        local seconds = math.max(1, math.min(86400, tonumber(ctx:prop('seconds')) or 300))
        serial = serial + 1
        local key = ('countdown:%s:%d'):format(ctx.node.id, serial)
        local shown = ctx:prop('show') ~= false
        local who = shown and playersFor(ctx, ctx:prop('who')) or {}
        local label = ctx:prop('label') or 'Time left'
        for _, src in ipairs(who) do DirectorBand.clock(run, src, key, seconds, label) end
        s.running = true
        ctx:after(seconds * 1000, 'done')
        -- Everyone's clock is the crew's as it is: one a script puts in sees what is left of it.
        if shown and ctx:prop('who') == 'everyone in the run' then
            local endsAt = GetGameTimer() + math.floor(seconds * 1000)
            Director.followCrew(run, key, function(players)
                local had = {}
                for _, src in ipairs(who) do had[src] = true end
                local left = (endsAt - GetGameTimer()) / 1000.0
                for _, src in ipairs(players) do
                    if not had[src] and left > 0 then DirectorBand.clock(run, src, key, left, label) end
                end
                who = {}
                for i, src in ipairs(players) do who[i] = src end
            end)
        end
        ctx:onEnd(function(_, why)
            Director.followCrew(run, key, nil)
            for _, src in ipairs(who) do DirectorBand.stopClock(run, src, key) end
            -- Restarted (Start again, or Stop): the pulse that did it decides.
            if why ~= 'restarted' then s.running = false end
        end)
        return nil
    end,
})

-- ============================================
-- Remove
-- ============================================

--- What a run made for a placed thing (its handle `h`), taken away there and then: its NPCs, its car, its prop out of its
--- set (the rest of a group shown with it staying: nodes_props.lua), its item on the ground, its container. The run
--- forgets it first. Remove's work, and a test rewound to before it was made (hub.lua testRewind). It may wait.
function DirectorNodes.removeMade(ctx, worldId, h)
    ctx:remember(worldId, nil)
    for _, id in ipairs(DirectorNodes.npcIds(h)) do Npcs.despawn(CORE, id) end
    if h.vehicleId and Vehicles.getDef(h.vehicleId) then Vehicles.despawnByRef(h.vehicleId) end
    if h.propSet or h.physProp then DirectorNodes.takeRunProp(ctx, worldId, h) end
    if h.groundId and GroundItems.getById(h.groundId) then GroundItems.deleteItem(h.groundId) end
    if h.containerId then Containers.delete(h.containerId) end
    Director.event(ctx.run, ctx.node.id, 'removed', nil, tostring(worldId))
end

--- Check: a door or a spot has nothing a run made to take away. (Those picked one by one: a group's are passed over.)
local function removable(v, doc)
    local picked = {}
    for _, x in ipairs(type(v) == 'table' and v or { v }) do
        if not DirectorNodes.groupName(x) then picked[x] = true end
    end
    for _, w in ipairs(type(doc) == 'table' and type(doc.world) == 'table' and doc.world or {}) do
        if type(w) == 'table' and picked[w.id] then
            if w.kind == 'door' then return 'a door is not removed: Lock / Unlock it' end
            if w.kind == 'spot' then return 'a spot is only a place: nothing there to remove' end
            if w.layer == 'standing' then
                return ('"%s" is Always present (shared by everyone): Remove takes away only what the scenario made'):format(tostring(w.label or w.id))
            end
        end
    end
    return nil
end

define({
    type = 'world.remove', v = 2, category = 'world', title = 'Remove', giveUp = 15,
    desc = 'Takes away what the scenario made for the placed things (or groups) picked, there and then: their NPCs, cars, props, items on the ground and containers.',
    outputs = { 'out', 'timeout' },
    labels = { out = 'Done' },
    latent = true, yields = true,
    upgrade = function(props) return DirectorNodes.toList(props, 'what') end,
    props = { DirectorNodes.thingsField('what', nil, 'What (placed things or groups)', { check = removable }) },
    run = function(ctx)
        local made = {}
        for _, worldId in ipairs(DirectorNodes.things(ctx, 'what')) do
            local h = ctx:handle(worldId)
            if type(h) ~= 'table' then
                ctx:log('%s: this run has made nothing for it', tostring(worldId))
            elseif h.claimed then
                -- A claimed car is the player's own now: never taken away.
                ctx:log('%s is the player\'s car now: it stays', tostring(worldId))
            else
                made[#made + 1] = { worldId, h }
            end
        end
        if #made == 0 then return 'out' end
        ctx:call(function()
            -- Forgotten here, when the taking starts, not before: a call a second pulse stopped before
            -- it began leaves the handle for that pulse to take away.
            for _, m in ipairs(made) do DirectorNodes.removeMade(ctx, m[1], m[2]) end
            return 'out'
        end)        return nil
    end,
})

-- ============================================
-- Car Destroyed / Car Damaged
-- ============================================
--
-- The server reads what a player's game last sent of the car, and answers 0 until one has (FiveM: no
-- health node yet), so a reading counts only while a player's game owns the car, and a few in a row
-- (as Car Delivered's "blown up").

-- (The run's car, gone or not, and how damaged it reads: DirectorNodes.runCar and carDamage, nodes.lua.)

define({
    type = 'vehicle.destroyed', v = 2, category = 'world', title = 'Car Destroyed',
    once = false,   -- (the run waits here for what happens to the car: never Only Once, nodes.lua)
    desc = 'Waits until one of the cars picked is blown up, sunk, or gone from the world.',
    outputs = { 'destroyed' },
    labels = { destroyed = 'Destroyed or gone' },
    latent = true,
    upgrade = function(props) return DirectorNodes.toList(props, 'car') end,
    props = { DirectorNodes.thingsField('car', 'vehicle', 'Cars') },
    run = function(ctx)
        local looks = {}
        for _, carW in ipairs(DirectorNodes.things(ctx, 'car')) do looks[#looks + 1] = DirectorNodes.carLook(ctx, carW) end
        ctx:poll(1000, function()
            for _, look in ipairs(looks) do
                local _, lost = look()
                if lost then
                    Director.event(ctx.run, ctx.node.id, 'car destroyed')
                    return 'destroyed'
                end
            end
            return nil
        end)
        return nil
    end,
})

define({
    type = 'vehicle.damaged', v = 2, category = 'world', title = 'Car Damaged',
    once = false,   -- (the run waits here for what happens to the car: never Only Once, nodes.lua)
    desc = 'When one of the cars picked takes more damage than set, from when this card starts. Destroyed or gone counts too.',
    outputs = { 'damaged' },
    labels = { damaged = 'Damaged' },
    latent = true,
    upgrade = function(props) return DirectorNodes.toList(props, 'car') end,
    props = {
        DirectorNodes.thingsField('car', 'vehicle', 'Cars'),
        { key = 'percent', kind = 'number', label = 'More than (% damage)', default = 5, min = 1, max = 100 },
    },
    run = function(ctx)
        local cars = DirectorNodes.things(ctx, 'car')
        local limit = math.max(1, math.min(100, tonumber(ctx:prop('percent')) or 5))
        local base, reads = {}, {}   -- each car on its own: [car] = its first reading, its readings over in a row
        local seen = {}              -- [car] = made, seen by this card
        ctx:poll(1000, function()
            for _, carW in ipairs(cars) do
                local ent, gone, made = DirectorNodes.runCar(ctx, carW)
                seen[carW] = seen[carW] or made
                if not ent then
                    -- (Not made yet: nothing to damage, it waits. Gone once seen: destroyed or gone counts.)
                    if gone and seen[carW] then return 'damaged' end
                else
                    local d = DirectorNodes.carDamage(ent)
                    if d ~= nil and base[carW] == nil then
                        -- The first real reading is where it starts. A new owner's game has not sent the car's
                        -- health for a moment (it reads 0, "wrecked"): not that.
                        if GetEntityHealth(ent) > 0 then base[carW] = d end
                    elseif d ~= nil then
                        if d - base[carW] > limit then reads[carW] = (reads[carW] or 0) + 1 else reads[carW] = 0 end
                        if reads[carW] >= 2 then
                            Director.event(ctx.run, ctx.node.id, 'car damaged', nil, ('%d%%'):format(math.floor(d - base[carW])))
                            return 'damaged'
                        end
                    end
                end
            end
            return nil
        end)
        return nil
    end,
})
