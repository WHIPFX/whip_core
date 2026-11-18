-- ============================================
-- Systems — the core whip cards, on the server
-- ============================================
--
-- whip's own systems as cards. Each calls whip_core's INTERNAL function, never its export, with the
-- system as the owner where the module takes one (Money: 'system:<short id>', so a
-- system refunds only its own payments and the activity log says which system). Rules every card here
-- keeps (shared/systems/walk.lua's header):
--   * act on a player only through ctx:source(p): it fails closed on an old session or a Test
--   * money and items TAKEN go through ctx:receipt: the walker settles or refunds them exactly once
--   * anything that can wait (the bank, a save) runs in ctx:call, with a timeout
--   * Fine and Take act on the pulse's OWN player only: never on someone wired in
--
-- Triggers come from core's own hooks (server/systems/main.lua), never public events.

local C = SystemCards

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

local METHODS = { 'auto', 'cash', 'bank' }
local SEATS = { 'driver', 'any seat' }

--- Where a payment or an item is logged from: "Speeding · Speed Camera (system speedcam r3)".
local function reasonFor(ctx, reason)
    local m = ctx:meta()
    local label = ('%s (system %s r%s)'):format(tostring(m.name or 'a system'), tostring(m.shortId or '?'), tostring(m.rev or '?'))
    reason = type(reason) == 'string' and reason ~= '' and reason:sub(1, 80) or 'Payment'
    return reason, ('%s · %s'):format(reason, label)
end

local function ownerOf(ctx) return ctx:meta().owner or 'system:unknown' end

local function playerName(src)
    local p = Players[src]
    return p and p.fullName or ''
end

-- ============================================
-- Triggers
-- ============================================

define({
    type = 'when.playerJoined', category = 'when', kind = 'trigger', title = 'When a Player Comes In',
    desc = 'A player has loaded their character.',
    trigger = { name = 'player.joined', match = function(_, p)
        if type(p) ~= 'table' or not p.player then return nil end
        return { player = p.player, name = p.name }, { player = p.player }
    end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'name', type = 'text', label = 'Name' } } },
})

define({
    type = 'when.playerLeft', category = 'when', kind = 'trigger', title = 'When a Player Leaves',
    desc = 'A player logged out or left the server. They are gone: nothing can be done TO them now, only noted.',
    trigger = { name = 'player.left', match = function(_, p)
        if type(p) ~= 'table' or not p.player then return nil end
        return { player = p.player, why = p.why }, { player = p.player }
    end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'why', type = 'text', label = 'Why' } } },
})

local function seatMatch(ctx, p)
    if type(p) ~= 'table' or not p.player then return nil end
    if ctx:prop('seat') == 'driver' and p.seat ~= -1 then return nil end
    return { player = p.player, car = p.vehicle, seat = p.seat }, { player = p.player, vehicle = p.vehicle }
end

do
    local m = seatMatch
    define({
        type = 'when.gotInCar', category = 'when', kind = 'trigger', title = 'When a Player Gets in a Car',
        desc = 'A player sits in a car whip looks after (the server\'s own seat record).',
        props = { { key = 'seat', kind = 'select', label = 'Seat', options = SEATS, default = 'driver' } },
        trigger = { name = 'vehicle.entered', match = m },
        values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' },
                               { key = 'seat', type = 'number', label = 'Seat (-1 driver)' } } },
    })
    define({
        type = 'when.gotOutOfCar', category = 'when', kind = 'trigger', title = 'When a Player Gets out of a Car',
        desc = 'A player leaves a seat of a car whip looks after.',
        props = { { key = 'seat', kind = 'select', label = 'Seat', options = SEATS, default = 'driver' } },
        trigger = { name = 'vehicle.exited', match = m },
        values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' },
                               { key = 'seat', type = 'number', label = 'Seat (-1 driver)' } } },
    })
end

local function areaMatch(ctx, p)
    if type(p) ~= 'table' or not p.player then return nil end
    if p.key ~= ctx:prop('area') then return nil end
    return { player = p.player }, { player = p.player }
end

define({
    type = 'when.areaEntered', category = 'when', kind = 'trigger', title = 'When a Player Enters an Area',
    desc = 'A player walks or drives into a zone (by its key). The zone must be one the server tracks (trackPlayers): it checks once a second, so a fast car can pass a small zone between checks: use Crosses a Line for that.',
    props = { { key = 'area', kind = 'text', label = 'Zone key', required = true, maxLength = 64 } },
    trigger = { name = 'area.entered', match = areaMatch },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' } } },
})

define({
    type = 'when.areaLeft', category = 'when', kind = 'trigger', title = 'When a Player Leaves an Area',
    desc = 'A player leaves a zone (by its key), or left the server while inside it.',
    props = { { key = 'area', kind = 'text', label = 'Zone key', required = true, maxLength = 64 } },
    trigger = { name = 'area.left', match = areaMatch },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' } } },
})

--- Do segments p1-p2 and q1-q2 cross (on the ground: x and y)?
local function crosses(p1, p2, q1, q2)
    local function orient(a, b, c) return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) end
    local d1, d2 = orient(q1, q2, p1), orient(q1, q2, p2)
    local d3, d4 = orient(p1, p2, q1), orient(p1, p2, q2)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end
C.segmentsCross = crosses

define({
    type = 'when.lineCrossed', category = 'when', kind = 'trigger', title = 'When a Car Crosses a Line',
    desc = 'A car driven by a player crosses the line between two places (a speed camera across a road), with its speed then. Checked 4 times a second, so even a fast car is seen.',
    props = { { key = 'a', kind = 'place', label = 'One end', required = true },
              { key = 'b', kind = 'place', label = 'Other end', required = true } },
    trigger = { name = 'car.moved',
        -- Heard 4 times a second for every driver: the line is tested here, before anything else, and
        -- the car looked up only when it crossed.
        test = function(props, p)
            return type(p) == 'table' and type(p.from) == 'table' and type(p.to) == 'table'
                and type(props.a) == 'table' and type(props.b) == 'table' and crosses(p.from, p.to, props.a, props.b)
        end,
        match = function(_, p)
            if not p.player then return nil end
            local car = p.ent and Vehicles.getEntityVehicleId(p.ent) or nil
            return { player = p.player, car = car, speed = p.kmh, mph = p.kmh and p.kmh / 1.609344 or nil },
                   { player = p.player, vehicle = car }
        end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Driver' }, { key = 'car', type = 'vehicle', label = 'Car' },
                           { key = 'speed', type = 'number', label = 'Speed (km/h)' }, { key = 'mph', type = 'number', label = 'Speed (mph)' } } },
})

define({
    type = 'when.everyPlayer', category = 'when', kind = 'trigger', title = 'Every Few Seconds, for Each Player',
    desc = 'Again and again, once for every player who is in: each one their own (per-player variables work here).',
    props = { { key = 'seconds', kind = 'duration', label = 'Every (seconds)', default = 10, min = 1, max = 3600 } },
    timer = function(props) return (tonumber(props.seconds) or 10) * 1000 end,
    perPlayer = true,
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' } } },
})

-- A POINT: a prompt in the world (E to use) for as long as the system is on, made under its tag
-- (server/systems/main.lua makeStanding), so switching it off takes it away. Pressed, the server has
-- checked the distance and the press itself (server/runtime_points.lua), and the presser starts a
-- pulse. A Test's point is the tester's alone.
define({
    type = 'when.pointUsed', category = 'when', kind = 'trigger', title = 'When a Point Is Used', api = 'AddPoint',
    desc = 'A prompt in the world, there while the system is on (a fuel pump, a car wash, a lockpick spot). Whoever presses E on it starts the pulse.',
    props = { { key = 'at', kind = 'place', label = 'Where', required = true },
              { key = 'label', kind = 'text', label = 'Prompt', default = 'Use', maxLength = 40 },
              { key = 'reach', kind = 'number', label = 'Reach (m)', default = 2, min = 0.5, max = 10 } },
    standing = function(api)
        local at = C.coerce('vector', api.props.at)
        if not at then return 'it has no place yet: set Where' end
        local label = type(api.props.label) == 'string' and api.props.label ~= '' and api.props.label:sub(1, 40) or 'Use'
        local id, why = RuntimePoints.add(GetCurrentResourceName(), {
            at = { coords = vector3(at.x, at.y, at.z) },
            -- A tester sees both copies' prompts on one spot: the test's says it is the test's.
            label = api.test and ('Test: ' .. label) or label,
            reach = tonumber(api.props.reach) or 2,
            audience = api.test and { people = { api.tester } } or nil,
            tag = api.tag,
            onUse = function(source)
                -- The live copy leaves its tester be: said, rather than a press that does nothing.
                if not api.test and api.isTesting(source) then
                    NotifyPlayer(source, 'You are testing a draft of this system: use its "Test:" prompt', 'info')
                    return
                end
                local pv = Systems.playerValue(source)
                if pv then api.emit('point.used', { player = pv }) end
            end,
        })
        if not id then error(tostring(why), 0) end
    end,
    trigger = { name = 'point.used', match = function(ctx, p)
        -- Only this instance's own card's point (another system's, or the live copy's, is not ours).
        if type(p) ~= 'table' or p.inst ~= ctx:instanceId() or p.node ~= ctx:nodeId() or not p.player then return nil end
        return { player = p.player }, { player = p.player }
    end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' } } },
})

-- ============================================
-- Values (worked out when something reads them)
-- ============================================

--- The server's entity for a player's ped, or nil.
local function pedOf(ctx, p)
    local src = ctx:source(p)
    if not src then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return src, ped
end

define({
    type = 'player.car', category = 'players', kind = 'value', title = 'Their Car', api = 'GetPlayerVehicle',
    desc = 'The car a player is in, if whip looks after it. Found says if there was one; Driving if they drive it.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'car', type = 'vehicle', label = 'Car' }, { key = 'found', type = 'bool', label = 'Found' },
                           { key = 'driving', type = 'bool', label = 'Driving' } } },
    value = function(ctx)
        local _, ped = pedOf(ctx, ctx:need('player'))
        if not ped then return { found = false, driving = false } end
        local ent = GetVehiclePedIsIn(ped, false)
        if not ent or ent == 0 then return { found = false, driving = false } end
        local id = Vehicles.getEntityVehicleId(ent)
        return { car = id, found = id ~= nil, driving = GetPedInVehicleSeat(ent, -1) == ped }
    end,
})

define({
    type = 'car.speed', category = 'cars', kind = 'value', title = 'Car Speed',
    desc = 'How fast a car is going now, as the server last heard it from the driver\'s game.',
    props = { { key = 'unit', kind = 'select', label = 'In', options = { 'km/h', 'mph' }, default = 'km/h' } },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'speed', type = 'number', label = 'Speed' } } },
    value = function(ctx)
        local ent = Vehicles.getEntity(ctx:need('car'))
        if not ent or ent == 0 or not DoesEntityExist(ent) then return nil, 'that car is not out' end
        local ms = GetEntitySpeed(ent) or 0
        return { speed = ctx:prop('unit') == 'mph' and ms * 2.236936 or ms * 3.6 }
    end,
})

define({
    type = 'player.name', category = 'players', kind = 'value', title = 'Character Name', api = 'GetPlayerFullName',
    desc = 'A player\'s character name, first and last.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'name', type = 'text', label = 'Name' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        return { name = src and playerName(src) or '' }
    end,
})

define({
    type = 'player.position', category = 'players', kind = 'value', title = 'Where They Are', api = 'GetPlayerCoords',
    desc = 'Where a player is standing (or driving) now.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'place', type = 'vector', label = 'Place' } } },
    value = function(ctx)
        local _, ped = pedOf(ctx, ctx:need('player'))
        if not ped then return nil, 'that player is not here' end
        local c = GetEntityCoords(ped)
        return { place = { x = c.x, y = c.y, z = c.z } }
    end,
})

define({
    type = 'item.has', category = 'items', kind = 'value', title = 'Has Item?', api = { 'HasItem', 'GetItemCount' },
    desc = 'Yes or no: does the player carry at least this many of an item (anywhere on them).',
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'amount', type = 'number', label = 'How many', default = 1 } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' }, { key = 'count', type = 'number', label = 'They have' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        if not p or not p.inventory then return { result = false, count = 0 } end
        local n = Inventory.getItemCountAcrossContainers(p.inventory, ctx:prop('item')) or 0
        return { result = n >= math.max(1, math.floor(ctx:need('amount'))), count = n }
    end,
})

-- ============================================
-- Actions
-- ============================================

define({
    type = 'player.notify', category = 'players', kind = 'action', title = 'Notify', api = 'NotifyPlayer',
    desc = 'A message in the corner of a player\'s screen.',
    props = { { key = 'kind', kind = 'select', label = 'Style', options = { 'info', 'success', 'warning', 'error' }, default = 'info' } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'text', type = 'any', label = 'Text' } } },
    outputs = { 'out', 'gone' },
    labels = { gone = 'Not here' },
    run = function(ctx)
        local src = ctx:source(ctx:need('player'))
        if not src then return 'gone' end
        local t = ctx:need('text')
        if type(t) == 'number' then t = (math.floor(t) == t) and ('%d'):format(t) or ('%.2f'):format(t) end
        if type(t) == 'boolean' then t = t and 'yes' or 'no' end
        if type(t) ~= 'string' then t = '' end
        NotifyPlayer(src, t:sub(1, 300), ctx:prop('kind'))
        return 'out'
    end,
})

-- ============================================
-- Asking a player (server/ask.lua: the token bridge the skill check uses)
-- ============================================
--
-- The question goes to their screen and the pulse waits for the answer. What they answer is what
-- THEY say: a typed number is a claim, so a card that pays or charges must never take its amount from
-- one without checking it. Asked under the system's tag: switching the system off takes the dialog
-- down. One question at a time per player: a second answers No Answer ('busy').

local ASK_SECONDS_MIN, ASK_SECONDS_MAX = 5, 120
local ASK_FIELDS = 3
local FIELD_TYPES = { 'text', 'number', 'yes/no', 'pick one' }
local FIELD_PIN = { text = 'text', number = 'number', ['yes/no'] = 'bool', ['pick one'] = 'text' }

local function askSeconds(ctx)
    local s = tonumber(ctx:prop('seconds')) or 30
    if s ~= s then s = 30 end
    return math.floor(math.max(ASK_SECONDS_MIN, math.min(ASK_SECONDS_MAX, s)))
end

--- The fields a form card asks, from its props (`get(key)` reads one): { { i, label, kind, choices } }
--- for each one with a question. The same rule pinsFor draws the answer pins by (and
--- html/js/systems/pins.js copies).
local function formFields(get)
    local out = {}
    for i = 1, ASK_FIELDS do
        local label = get('label' .. i)
        if type(label) == 'string' and label:match('%S') then
            local kind = get('type' .. i)
            if not FIELD_PIN[kind] then kind = 'text' end
            local choices = get('choices' .. i)
            out[#out + 1] = { i = i, label = label:sub(1, 60), kind = kind, choices = type(choices) == 'string' and choices or '' }
        end
    end
    return out
end

--- One form field as server/ask.lua takes it, or nil and why (a pick with no choices, a range that
--- does not read).
local function askField(f)
    if f.kind == 'yes/no' then return { type = 'checkbox', label = f.label, placeholder = f.label } end
    if f.kind == 'pick one' then
        local opts = {}
        for c in f.choices:gmatch('[^,]+') do
            c = c:match('^%s*(.-)%s*$')
            if c ~= '' then opts[#opts + 1] = c:sub(1, 60) end
        end
        if #opts == 0 then return nil, ('"%s" is pick one: write its choices, comma separated (red, green, blue)'):format(f.label) end
        if #opts > 20 then return nil, ('"%s" has more than 20 choices'):format(f.label) end
        return { type = 'select', label = f.label, options = opts }
    end
    if f.kind == 'number' then
        local field = { type = 'number', label = f.label }
        if f.choices:match('%S') then
            local lo, hi = f.choices:match('^%s*(%-?%d+%.?%d*)%s*%-%s*(%-?%d+%.?%d*)%s*$')
            lo, hi = tonumber(lo), tonumber(hi)
            if not lo or not hi or lo > hi then return nil, ('"%s": a number\'s range reads lowest-highest (1-100)'):format(f.label) end
            field.min, field.max = lo, hi
        end
        return field
    end
    return { type = 'text', label = f.label, maxLen = 100 }
end

--- Who is asked: the Player wired in, as Notify's. Never this pulse's player in its place: a wired
--- player who has gone must not turn into asking someone else.
local function askWho(ctx)
    local who = ctx:input('player')
    if not who then return nil, nil, 'no player wired in, or they have gone' end
    return who, ctx:source(who)
end

--- Asks, in the card's own thread, and answers what Ask.run answered; the question is called off if
--- the card stops waiting first (its backstop, or the pulse ending).
local function askAndWait(ctx, who, src, spec, seconds, answer)
    local token
    ctx:onEnd(function() if token then Ask.cancel(token) end end)
    local tag = ctx:tag()
    ctx:call(function()
        if not ctx:source(who) then return 'noAnswer', { why = 'not here' } end
        local ok, v = Ask.run(src, spec, { timeoutMs = seconds * 1000, tag = tag, onOpen = function(t) token = t end })
        if not ok then return 'noAnswer', { why = tostring(v) } end
        return answer(v)
    end)
    -- The question's own clock answers first ('timeout'); this only stops a stuck one holding the pulse.
    ctx:after((seconds + 5) * 1000, 'noAnswer')
end

define({
    type = 'ask.yesNo', category = 'players', kind = 'wait', title = 'Ask Yes/No',
    desc = 'Puts a question on a player\'s screen with two buttons, and waits for the answer. Escape is No. No Answer if they did not answer in time, were busy with another screen, or left.',
    props = { { key = 'yes', kind = 'text', label = 'Yes button', default = 'Yes', maxLength = 24 },
              { key = 'no', kind = 'text', label = 'No button', default = 'No', maxLength = 24 },
              { key = 'seconds', kind = 'number', label = 'Seconds to answer', default = 30, min = ASK_SECONDS_MIN, max = ASK_SECONDS_MAX } },
    outputs = { 'yes', 'no', 'noAnswer' },
    labels = { yes = 'Yes', no = 'No', noAnswer = 'No answer' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' },
                          { key = 'title', type = 'text', label = 'Title', default = 'Question' },
                          { key = 'question', type = 'text', label = 'Question' } },
               outputs = { { key = 'why', type = 'text', label = 'Why no answer' } } },
    run = function(ctx)
        local who, src, why = askWho(ctx)
        if not src then ctx:log('no one to ask: %s', tostring(why)) return 'noAnswer', { why = 'not here' } end
        local spec = { kind = 'confirm', title = ctx:input('title'), message = ctx:need('question'),
                       yes = ctx:prop('yes'), no = ctx:prop('no') }
        askAndWait(ctx, who, src, spec, askSeconds(ctx), function(v) return v == true and 'yes' or 'no' end)
        return nil
    end,
})

define({
    type = 'ask.form', category = 'players', kind = 'wait', title = 'Ask With a Form',
    desc = 'Puts a small form on a player\'s screen (up to 3 questions: text, a number, yes/no, or pick one) and waits. Each question becomes an answer pin. What they type is what THEY say: check a number before money depends on it.',
    props = (function()
        local p = {}
        for i = 1, ASK_FIELDS do
            p[#p + 1] = { key = 'label' .. i, kind = 'text', label = ('Question %d'):format(i), maxLength = 60, default = i == 1 and 'Your answer' or nil }
            p[#p + 1] = { key = 'type' .. i, kind = 'select', label = ('Question %d is'):format(i), options = FIELD_TYPES, default = 'text' }
            p[#p + 1] = { key = 'choices' .. i, kind = 'text', label = ('Question %d choices'):format(i), maxLength = 200,
                          hint = 'pick one: red, green, blue · a number: lowest-highest, 1-100' }
        end
        p[#p + 1] = { key = 'seconds', kind = 'number', label = 'Seconds to answer', default = 60, min = ASK_SECONDS_MIN, max = ASK_SECONDS_MAX }
        return p
    end)(),
    outputs = { 'answered', 'noAnswer' },
    labels = { answered = 'Answered', noAnswer = 'No answer' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' },
                          { key = 'title', type = 'text', label = 'Title', default = 'Question' } },
               outputs = { { key = 'why', type = 'text', label = 'Why no answer' } } },
    pinsFor = function(props)
        local outs = {}
        for _, f in ipairs(formFields(function(k) return props[k] end)) do
            -- What they typed is what THEY say: a claim (compile.lua holds it from amounts and prices).
            outs[#outs + 1] = { key = 'answer' .. f.i, type = FIELD_PIN[f.kind], label = f.label, claim = true }
        end
        return { inputs = {}, outputs = outs }
    end,
    run = function(ctx)
        local fields = {}
        for _, f in ipairs(formFields(function(k) return ctx:prop(k) end)) do
            local af, bad = askField(f)
            if not af then ctx:log('%s', bad) return 'noAnswer', { why = 'the form does not read' } end
            af.slot = f.i
            fields[#fields + 1] = af
        end
        if #fields == 0 then ctx:log('the form has no questions') return 'noAnswer', { why = 'no questions' } end
        local who, src, why = askWho(ctx)
        if not src then ctx:log('no one to ask: %s', tostring(why)) return 'noAnswer', { why = 'not here' } end
        local spec = { kind = 'form', title = ctx:input('title'), fields = fields }
        askAndWait(ctx, who, src, spec, askSeconds(ctx), function(v)
            local outs = {}
            for n, f in ipairs(fields) do outs['answer' .. f.slot] = v[n] end
            return 'answered', outs
        end)
        return nil
    end,
})

define({
    type = 'car.clean', category = 'cars', kind = 'action', title = 'Clean Car',
    desc = 'Washes a car: no dirt, no mud. It is done by the game that has the car (its driver\'s, usually); a car not out in the world cannot be.',
    outputs = { 'out', 'notOut' },
    labels = { notOut = 'Not out' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local ent = Vehicles.getEntity(ctx:need('car'))
        if not ent or ent == 0 or not DoesEntityExist(ent) then return 'notOut' end
        -- Dirt is the owning game's to change (client/systems_editor.lua cleans it there).
        local owner = NetworkGetEntityOwner(ent)
        if not owner or owner <= 0 then return 'notOut' end
        TriggerClientEvent('whip_core:client:systemsCleanCar', owner, NetworkGetNetworkIdFromEntity(ent))
        return 'out'
    end,
})

local CALL_TIMEOUT_S = 15

-- In a test no money moves (walk.lua runs `dryRun` there instead of `run`): each card with a power
-- says, in the test's log and on the tester's screen, what it WOULD have done, and answers as if it
-- had. Items are real but go back: a Test's Give Item, Sell and Drop Item hand out the real item, stamped with
-- the Test, and its end takes them back (test_items.lua).
local function tested(ctx, src, fmt, ...)
    local text = fmt:format(...)
    ctx:log('test: %s (nothing really moved)', text)
    if src then NotifyPlayer(src, ('Test: %s (nothing really moved)'):format(text), 'info') end
end

local function itemName(item)
    local def = Config.Items and Config.Items[item]
    return def and def.name or tostring(item)
end

--- A Test's give: the real item, stamped with the Test (taken back when it ends), in the card's own
--- call. Answers through `pin` (its delivered pin) or 'failed'.
local function testGive(ctx, who, src, item, amount, pin, opts)
    local meta = SystemsTestItems.stamp(ctx:tag(), item)
    ctx:call(function()
        if not ctx:source(who) then return 'failed' end
        local where, err = Inventory.give(src, item, amount, meta,
            { reason = 'systems test (taken back when it ends)', noDrop = opts and opts.noDrop or nil })
        if not where then ctx:log('give refused: %s', tostring(err)) return 'failed' end
        ctx:log('test: %dx %s handed over (taken back when the test ends)', amount, itemName(item))
        return pin
    end, { late = function() SystemsTestItems.late(meta.systest, src, item) end })
    ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
end

-- FINE and CHARGE are one card under two names: money taken from the pulse's own player, with a
-- receipt the walker refunds if the pulse is called off before it delivers (a Charge for a car wash,
-- then Clean Car). Only the words differ, so a builder picks the one that reads right.
local function takeMoney(cardType, title, verb, defaultReason, desc)
    define({
        type = cardType, category = 'money', kind = 'wait', title = title, api = 'ChargePlayer',
        desc = desc,
        power = 'money', cost = 3,
        outputs = { 'paid', 'cantPay', 'timeout' },
        labels = { paid = 'Paid', cantPay = 'Can\'t pay', timeout = 'Took too long' },
        props = { { key = 'method', kind = 'select', label = 'From', options = METHODS, default = 'auto' } },
        values = { inputs = { { key = 'amount', type = 'number', label = 'Amount ($)' }, { key = 'reason', type = 'text', label = 'What for', default = defaultReason } },
                   outputs = { { key = 'receipt', type = 'receipt', label = 'Receipt' } } },
        run = function(ctx)
            local amount = math.floor(ctx:need('amount'))
            if amount < 0 then return 'cantPay' end
            local src, why = ctx:source(ctx:player())
            if not src then ctx:log('no one to %s: %s', verb, tostring(why)) return 'cantPay' end
            local reason, logWhy = reasonFor(ctx, ctx:input('reason'))
            local owner, method = ownerOf(ctx), ctx:prop('method')
            local me = ctx:player()
            ctx:call(function()
                -- Asked again right before the money moves: a logout can fall between the step and here.
                if not ctx:source(me) then return 'cantPay' end
                local rec, err = Money.charge(src, amount, { method = method, reason = reason }, owner, logWhy)
                if not rec then
                    ctx:log('%s refused: %s', title, tostring(err))
                    return 'cantPay'
                end
                local id = rec.id
                -- A refund that fails is said (the walker logs its error), never lost in silence.
                local r = ctx:receipt(function()
                    local ok, rwhy = Money.refund(id, nil, owner)
                    if not ok then error(('the $%d could not be given back: %s'):format(amount, tostring(rwhy)), 0) end
                end)
                return 'paid', { receipt = r }
            end)
            ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
            return nil
        end,
        dryRun = function(ctx)
            local amount = math.floor(ctx:need('amount'))
            if amount < 0 then return 'cantPay' end
            local src, why = ctx:source(ctx:player())
            if not src then ctx:log('no one to %s: %s', verb, tostring(why)) return 'cantPay' end
            tested(ctx, src, '%s $%d for "%s"', verb == 'fine' and 'fined' or 'charged', amount, tostring(ctx:input('reason') or defaultReason))
            return 'paid', { receipt = ctx:receipt(function() end) }
        end,
    })
end

takeMoney('money.fine', 'Fine', 'fine', 'Fine',
    'Takes money from THIS pulse\'s player (cash or bank) as a fine. Paid gives back a receipt; Can\'t Pay if they have not enough. If the pulse is called off before it ends, they get it back.')
takeMoney('money.charge', 'Charge', 'charge', 'Payment',
    'Takes payment from THIS pulse\'s player (cash or bank) for something (a car wash, a ticket). Can\'t Pay if they have not enough. If the pulse is called off before what they paid for is done, they get it back.')

define({
    type = 'money.pay', category = 'money', kind = 'wait', title = 'Pay', api = 'PayPlayer',
    desc = 'Gives a player money (cash in their pocket, or into their bank). Paying counts as delivering what a pulse was paid for: a fine or charge before it is kept for good.',
    power = 'money', cost = 3, settles = { 'paid' },
    outputs = { 'paid', 'failed', 'timeout' },
    labels = { paid = 'Paid', failed = 'Could not', timeout = 'Took too long' },
    props = { { key = 'method', kind = 'select', label = 'Into', options = METHODS, default = 'auto' } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'amount', type = 'number', label = 'Amount ($)' },
                          { key = 'reason', type = 'text', label = 'What for', default = 'Payment' } } },
    run = function(ctx)
        local who = ctx:need('player')
        local src = ctx:source(who)
        if not src then return 'failed' end
        local amount = math.floor(ctx:need('amount'))
        if amount < 0 then return 'failed' end
        local reason, logWhy = reasonFor(ctx, ctx:input('reason'))
        local owner, method = ownerOf(ctx), ctx:prop('method')
        ctx:call(function()
            if not ctx:source(who) then return 'failed' end
            local ok, res = Money.pay(src, amount, { method = method, reason = reason }, owner, logWhy)
            if not ok then ctx:log('pay refused: %s', tostring(res)) return 'failed' end
            return 'paid'
        end, { late = function(pin) if pin == 'paid' then ctx:log('$%d was paid after this card gave up waiting', amount) end end })
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local src = ctx:source(ctx:need('player'))
        if not src then return 'failed' end
        local amount = math.floor(ctx:need('amount'))
        if amount < 0 then return 'failed' end
        tested(ctx, src, 'paid $%d for "%s"', amount, tostring(ctx:input('reason') or 'Payment'))
        return 'paid'
    end,
})

define({
    type = 'item.give', category = 'items', kind = 'wait', title = 'Give Item', api = 'AddItem',
    desc = 'Puts an item in a player\'s pockets (at their feet if they are full). Giving counts as delivering: a payment before it is kept for good.',
    power = 'items', cost = 3, settles = { 'given' },
    outputs = { 'given', 'failed', 'timeout' },
    labels = { given = 'Given', failed = 'Could not', timeout = 'Took too long' },
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'amount', type = 'number', label = 'How many', default = 1 } } },
    run = function(ctx)
        local who = ctx:need('player')
        local src = ctx:source(who)
        if not src then return 'failed' end
        local item = ctx:prop('item')
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        local amount = math.max(1, math.floor(ctx:need('amount')))
        local _, logWhy = reasonFor(ctx, 'Given')
        ctx:call(function()
            if not ctx:source(who) then return 'failed' end
            local where, err = Inventory.give(src, item, amount, nil, { reason = logWhy })
            if not where then ctx:log('give refused: %s', tostring(err)) return 'failed' end
            return 'given'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    -- A Test's: the real item, stamped, taken back when the test ends (test_items.lua).
    dryRun = function(ctx)
        local who = ctx:need('player')
        local src = ctx:source(who)
        if not src then return 'failed' end
        local item = ctx:prop('item')
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        testGive(ctx, who, src, item, math.max(1, math.floor(ctx:need('amount'))), 'given')
        return nil
    end,
})

define({
    type = 'item.take', category = 'items', kind = 'wait', title = 'Take Item', api = 'RemoveItem',
    desc = 'Takes items from THIS pulse\'s player. If the pulse is called off before what it pays for is done, they get them back.',
    power = 'items', cost = 3,
    outputs = { 'taken', 'notEnough', 'timeout' },
    labels = { taken = 'Taken', notEnough = 'Not enough', timeout = 'Took too long' },
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { inputs = { { key = 'amount', type = 'number', label = 'How many', default = 1 } } },
    run = function(ctx)
        local me = ctx:player()
        local src, why = ctx:source(me)
        if not src then ctx:log('no one to take from: %s', tostring(why)) return 'notEnough' end
        local session = me.session
        local item = ctx:prop('item')
        local amount = math.max(1, math.floor(ctx:need('amount')))
        local _, logWhy = reasonFor(ctx, 'Taken')
        ctx:call(function()
            if not ctx:source(me) then return 'notEnough' end
            -- Only plain items: what it gives back on a cancel is a fresh one, so an item that carries its
            -- own data (a used tool, a serial, a weapon) is not taken by a system yet.
            -- Whip's own `uid` stamp (Log.ensureUid) is not the item's data; any other key is.
            for _, found in ipairs(Inventory.findAll(src, item) or {}) do
                if type(found.metadata) == 'table' then
                    for k in pairs(found.metadata) do
                        if k ~= 'uid' then
                            ctx:log('%s carries its own data, and Take Item takes only plain items for now', tostring(item))
                            return 'notEnough'
                        end
                    end
                end
            end
            local ok = Inventory.take(src, item, amount, logWhy)
            if not ok then return 'notEnough' end
            local _, backWhy = reasonFor(ctx, 'Given back')
            ctx:receipt(function()
                -- Back to them only while it is still THEIR session: the same server id after a relog
                -- is another character. A player who left cannot be handed items (pockets are online
                -- only), so it is said loudly for an admin to put right.
                local p = Players[src]
                if p and p.session == session then
                    Inventory.give(src, item, amount, nil, { reason = backWhy })
                else
                    print(('^3[whip_core:systems] %s: %dx %s taken from server id %s could not be given back (they left)^0')
                        :format(tostring(backWhy), amount, tostring(item), tostring(src)))
                end
            end)
            return 'taken'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    -- Asks what they really carry, so Not Enough is tried as it would be; takes nothing.
    dryRun = function(ctx)
        local src, why = ctx:source(ctx:player())
        if not src then ctx:log('no one to take from: %s', tostring(why)) return 'notEnough' end
        local item = ctx:prop('item')
        local amount = math.max(1, math.floor(ctx:need('amount')))
        local p = Players[src]
        local have = p and p.inventory and Inventory.getItemCountAcrossContainers(p.inventory, item) or 0
        if have < amount then
            tested(ctx, src, 'would take %dx %s, but they carry %d', amount, itemName(item), have)
            return 'notEnough'
        end
        tested(ctx, src, 'taken %dx %s', amount, itemName(item))
        return 'taken'
    end,
})

-- REFUND: a payment this pulse holds, given back now (a Charge or Fine's receipt). Only this pulse's
-- own receipts, still open: the walker says (ctx:ownReceipt). It WAITS for the refund (the bank, a
-- save) and answers from it: Refunded only once the money is back.
define({
    type = 'money.refund', category = 'money', kind = 'wait', title = 'Refund', api = 'RefundPlayer',
    desc = 'Gives back, in full, a payment this pulse took (wire in a Charge or Fine\'s Receipt), and says once it has. One already kept for good (after a Pay or Give Item) cannot be.',
    power = 'money', cost = 3,
    outputs = { 'refunded', 'no', 'timeout' },
    labels = { no = 'Could not', timeout = 'Took too long' },
    values = { inputs = { { key = 'receipt', type = 'receipt', label = 'Receipt' } } },
    run = function(ctx)
        local r = ctx:input('receipt')
        if not ctx:ownReceipt(r) then ctx:log('refund: that is not a payment this pulse is holding') return 'no' end
        ctx:call(function()
            local ok, why = ctx:refundNow(r)
            if not ok then ctx:log('refund: %s', tostring(why)) return 'no' end
            return 'refunded'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    -- A test's receipts give back nothing (nothing was taken): the same answer, said as a test.
    dryRun = function(ctx)
        local ok, why = ctx:undoReceipt(ctx:input('receipt'))
        if not ok then ctx:log('refund: %s', tostring(why)) return 'no' end
        tested(ctx, ctx:source(ctx:player()), 'the payment given back')
        return 'refunded'
    end,
})

--- Why this player could not pay `price` by `method` now, or nil when they look able to. Money.charge decides;
--- this is a look first, so a sale they cannot afford never hands the item over only to take it back. Waits (a
--- bank read) when the cash will not do.
local function cannotPay(src, player, price, method)
    if price <= 0 then return nil end
    local cash = Money.spendableCash(src, player)
    if method == 'cash' then return cash < price and ('not enough cash (have $%d)'):format(cash) or nil end
    if method == 'auto' and cash >= price then return nil end
    local acct, readErr = Bank.GetDefaultAccount(player.charId)
    if not acct then return readErr and 'the bank could not be reached' or 'no bank account' end
    if (tonumber(acct.balance) or 0) < price then return 'not enough in the bank' end
    return nil
end

-- Sell: payment and the item, as one. The item is handed over first and the payment written with it
-- (the pump's way): the item goes into the pockets (in memory), and the charge writes the pockets in
-- the same transaction as the debit, so both
-- land or neither does; the pockets hold still while the debit is out (Money.charge). A charge refused after
-- all takes the item back. Sold, the payment is kept for good. A Charge then a Give Item does the same in two
-- cards, but this cannot be left half done.
define({
    type = 'money.sell', category = 'money', kind = 'wait', title = 'Sell', api = { 'ChargePlayer', 'AddItem' },
    desc = 'Sells THIS pulse\'s player an item: hands it over and takes the price (cash or bank), saved together. If it cannot be handed over (their pockets are full), it is Could Not and nothing is taken.',
    power = { 'money', 'items' }, cost = 4, settles = { 'sold' },
    outputs = { 'sold', 'cantPay', 'failed', 'timeout' },
    labels = { sold = 'Sold', cantPay = 'Can\'t pay', failed = 'Could not', timeout = 'Took too long' },
    props = { { key = 'item', kind = 'item', label = 'Item', required = true },
              { key = 'method', kind = 'select', label = 'From', options = METHODS, default = 'auto' } },
    values = { inputs = { { key = 'price', type = 'number', label = 'Price ($)' }, { key = 'amount', type = 'number', label = 'How many', default = 1 },
                          { key = 'reason', type = 'text', label = 'What for', default = 'Purchase' } } },
    run = function(ctx)
        local me = ctx:player()
        local src, why = ctx:source(me)
        if not src then ctx:log('no one to sell to: %s', tostring(why)) return 'cantPay' end
        local item = ctx:prop('item')
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        local price = math.floor(ctx:need('price'))
        local amount = math.max(1, math.floor(ctx:need('amount')))
        if price < 0 then return 'failed' end
        local reason, logWhy = reasonFor(ctx, ctx:input('reason'))
        local owner, method = ownerOf(ctx), ctx:prop('method')
        ctx:call(function()
            local player = ctx:source(me) and Players[src]
            if not player or not player.inventory then return 'cantPay' end
            local short = cannotPay(src, player, price, method)
            if short then ctx:log('Sell refused: %s', short) return 'cantPay' end
            if not ctx:source(me) or Players[src] ~= player then return 'cantPay' end   -- the bank read waited
            -- Never dropped at their feet (noDrop): that drop writes a ground row and waits. Full
            -- pockets are Could Not, and nothing was taken.
            local where, gerr = Inventory.give(src, item, amount, nil, { reason = logWhy, noDrop = true })
            if not where then
                ctx:log('Sell: %s could not be handed over (%s): nothing was taken', tostring(item), tostring(gerr))
                return 'failed'
            end
            --- Not paid after all: the item comes back out.
            local function takeBack(what)
                -- evenFrozen: a take-back, whatever else holds the pockets (Inventory.take)
                if Inventory.take(src, item, amount, logWhy .. ' (' .. what .. ': taken back)', nil, true) then return end
                -- Moved on in the moment the payment was out: said, and on their record.
                print(('[whip_core:systems] a Sell card could not take back %dx %s from charId %s (%s)')
                    :format(amount, tostring(item), tostring(player.charId), what))
                Log.write(player.charId, 'payment_unpaid', {
                    itemKey = item, amount = amount,
                    detail = ('Sell card by %s: %s, and the item could not be taken back'):format(tostring(owner), what),
                })
            end
            local pockets = Stores.player(src, 'player')
            -- A bank payment waits on the database: the pockets hold still meanwhile (Stores.freeze, as the ATM),
            -- so the item cannot be carried off in the wait and kept if the debit fails. Decided as Money.charge
            -- decides 'auto' (nothing waits between here and there), and never for cash, which it would refuse.
            local useBank = price > 0 and (method == 'bank'
                or (method == 'auto' and Money.spendableCash(src, player) < price))
            local hold = useBank and pockets and pockets.unit and Stores.freeze(pockets.unit) or nil
            local called, rec, err = pcall(Money.charge, src, price, { method = method, reason = reason }, owner, logWhy,
                pockets and { pockets } or nil)
            if hold then Stores.unfreeze(hold) end
            -- A throw: whether the debit landed is not known, so the item stays (never money gone with nothing).
            if not called then error(rec, 0) end
            if not rec then
                ctx:log('Sell refused: %s', tostring(err))
                takeBack('not paid')
                return 'cantPay'
            end
            local id = rec.id
            -- Held by the walker: given back if this card already stopped waiting (then the item comes back
            -- out too), or if the pulse is called off before it ends. Nothing between here and the answer
            -- waits, so a sold item's payment is settled with it.
            local r = ctx:receipt(function()
                local ok, rwhy = Money.refund(id, nil, owner)
                if not ok then error(('the $%d could not be given back: %s'):format(price, tostring(rwhy)), 0) end
            end)
            if not r then takeBack('the card had stopped waiting') return 'failed' end
            return 'sold'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    -- A Test's: no money taken (said), the real item handed over, stamped, taken back when it ends.
    dryRun = function(ctx)
        local me = ctx:player()
        local src, why = ctx:source(me)
        if not src then ctx:log('no one to sell to: %s', tostring(why)) return 'cantPay' end
        local item = ctx:prop('item')
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        local amount = math.max(1, math.floor(ctx:need('amount')))
        local text = ('$%d not taken for %dx %s (the item is real, taken back when the test ends)')
            :format(math.floor(ctx:need('price')), amount, itemName(item))
        ctx:log('test: %s', text)
        NotifyPlayer(src, 'Test: ' .. text, 'info')
        testGive(ctx, me, src, item, amount, 'sold', { noDrop = true })
        return nil
    end,
})
