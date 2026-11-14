-- Cards from other resources. A resource adds cards to the Director's palette with Whip.card, which calls
-- __RegisterDirectorCard here with the card as data and one function, its entry: entry(op, payload) runs the author's
-- run / event filter / check / onEnd on the resource's own side inside a pcall and answers a plain table. whip_core
-- never holds the author's functions (one from another resource throws when indexed), so a failure comes back as data.
-- Three kinds of card:
--   * Thread (the default): runs in its own thread outside the scheduler's pass and may wait. It answers an outcome,
--     or nothing, then Whip.answerCard(card.callId, pin, data) answers later. Every thread card has Took Too Long
--     (its "Give up after" field, 30 s) and Didn't Work (resource stopped, code threw, unknown pin); an unwired
--     Didn't Work faults the run. onEnd(callId, why) tells the resource it ended without its answer. Pulsed again
--     while it runs, the pulse is dropped.
--   * Instant (instant = true): answered at once inside the pass. A helper that waits (card:give, card:pay,
--     card:charge) is refused before it acts; anything else that waits faults the run.
--   * Event (event = { name, match, once, filter }): no inputs; goes on when the resource sends its event
--     (SendDirectorEvent). match: 'player' (one of the run's players, the default), 'run' (opts.runId), 'any'.
-- The card a resource's code is handed is a copy with methods; each is an export call back here (__DirectorCardDo),
-- refused for any other resource and once the activation is over.
-- In a test another resource's card does not run unless it says test = 'run': the tester is told what it would do and
-- it goes on from the outcome picked on the test strip, or its first after 15 seconds.

local R = DirectorRuntime
local CORE = GetCurrentResourceName()

local RESERVED_PINS = { timeout = true, didntWork = true }
local RESERVED_PROPS = { giveUpAfter = true }
local COLORS = { blue = true, teal = true, green = true, amber = true, red = true, violet = true, slate = true }
local MATCH = { player = true, run = true, any = true }
local NAME = '^[%a][%w_]*$'
local TEST_PICK_MS = 15000
local MAX_RECORDS = 50        -- card:record rows a card may write in one run
-- A card's size. Every builder's editor is sent each card when it opens: these only stop a resource gone wrong
-- (a loop making thousands) from making that slow, far above what any real card needs.
local MAX_FIELDS = 40
local MAX_OPTIONS = 200
local MAX_GIVE = 100
local MAX_MONEY = 1000000

local function say(fmt, ...) print(('[whip_core:director] ' .. fmt):format(...)) end

-- (A function, or one from another resource: a callable table, never indexed. Text at a character's edge.)
local callable, text, finite = DirectorKit.callable, DirectorKit.text, DirectorKit.number

--- A small copy of plain data: 4 deep, 50 keys a table, text cut at 500.
local function small(v) return DirectorKit.plain(v, { depth = 4, keys = 50, text = 500, clean = true }) end

-- ============================================
-- What a resource registers: its card, as data, made into a card type
-- ============================================

local threadRun, instantRun, eventFilter, failFilter, cardCheck

--- One field of another resource's card, as the Director keeps it, or nil and why.
local function fieldOf(t, i, f, keys)
    if type(f) ~= 'table' or callable(f) then return nil, ('%s: field %d is not a field'):format(t, i) end
    if type(f.key) ~= 'string' or not f.key:match(NAME) or #f.key > 24 then return nil, ('%s: field %d needs a key (one word)'):format(t, i) end
    if RESERVED_PROPS[f.key] then return nil, ('%s: "%s" is whip_core\'s own field'):format(t, f.key) end
    if keys[f.key] then return nil, ('%s: field "%s" twice'):format(t, f.key) end
    keys[f.key] = true
    -- (The kinds another resource's card may have: server/director/fields.lua's satCard.)
    if not DirectorFields.usable(f.kind, 'satCard') then
        return nil, ('%s: field %s: kind is one of %s'):format(t, f.key, DirectorFields.namesFor('satCard'))
    end
    -- `group`: the head the editor shows over it and the fields after it (a long card splits into parts). `showIf`: the
    -- key of one of the card's switches (a bool field): shown, and counted, only while it is on (its `when`, as
    -- whip_core's own cards say it: server/director/fields.lua; the switch checked once every field is read).
    local out = { key = f.key, kind = f.kind, label = text(f.label, 40) or f.key, required = f.required == true or nil,
                  hint = text(f.hint, 160), unit = text(f.unit, 12), group = text(f.group, 30) }
    if f.showIf ~= nil then
        if type(f.showIf) ~= 'string' or not f.showIf:match(NAME) then return nil, ('%s: field %s: showIf is the key of a bool field'):format(t, f.key) end
        out.when = { key = f.showIf, is = true }
    end
    local k, d = f.kind, f.default
    if k == 'number' or k == 'duration' then
        out.min, out.max = finite(f.min), finite(f.max)
        if (f.min ~= nil and out.min == nil) or (f.max ~= nil and out.max == nil) then return nil, ('%s: field %s: min and max are numbers'):format(t, f.key) end
        if out.min and out.max and out.min > out.max then return nil, ('%s: field %s: min is above max'):format(t, f.key) end
        if d ~= nil then
            out.default = finite(d)
            if out.default == nil or (out.min and out.default < out.min) or (out.max and out.default > out.max) then
                return nil, ('%s: field %s: its default is not a number between min and max'):format(t, f.key)
            end
        end
    elseif k == 'text' then
        out.maxLength = math.min(500, math.max(1, math.tointeger(f.maxLength) or 200))
        if d ~= nil then
            out.default = text(d, out.maxLength)
            if out.default == nil then return nil, ('%s: field %s: its default is text'):format(t, f.key) end
        end
        -- A box of several lines in the editor (a dispatch message).
        local lines = math.tointeger(f.lines)
        if f.lines ~= nil and (not lines or lines < 1 or lines > 6) then return nil, ('%s: field %s: lines is 1 to 6'):format(t, f.key) end
        out.lines = lines and lines > 1 and lines or nil
    elseif k == 'job' then
        if d ~= nil then
            if type(d) ~= 'string' or d == '' or #d > 64 then return nil, ('%s: field %s: its default is a job\'s key'):format(t, f.key) end
            out.default = d
        end
    elseif k == 'lore' then
        -- No default of its own: empty is the scenario's lore character (server/director/lore.lua).
        if d ~= nil then return nil, ('%s: field %s: a lore field has no default (empty is the scenario\'s own)'):format(t, f.key) end
    elseif k == 'players' then
        d = d == nil and DirectorNodes.PLAYERS[1] or d
        local ok = false
        for _, o in ipairs(DirectorNodes.PLAYERS) do if o == d then ok = true end end
        if not ok then return nil, ('%s: field %s: its default is "this player", "everyone in the run" or "the starter"'):format(t, f.key) end
        out.default = d
    elseif k == 'bool' then
        if d ~= nil and type(d) ~= 'boolean' then return nil, ('%s: field %s: its default is true or false'):format(t, f.key) end
        out.default = d
    elseif k == 'select' then
        if type(f.options) ~= 'table' or callable(f.options) or #f.options == 0 or #f.options > MAX_OPTIONS then
            return nil, ('%s: field %s: a choice has 1 to %d options'):format(t, f.key, MAX_OPTIONS)
        end
        -- Each option is its value as text, or { value, label } (the editor shows the label; "10-90 Alarm"
        -- saves as 10-90).
        out.options = {}
        local seen, labels = {}, nil
        for j, o in ipairs(f.options) do
            local s, l
            if type(o) == 'table' and not callable(o) then s, l = text(o.value, 40), text(o.label, 60) else s = text(o, 40) end
            if not s or s == '' or seen[s] then return nil, ('%s: field %s: option %d is not a new piece of text'):format(t, f.key, j) end
            seen[s] = true
            out.options[j] = s
            if l and l ~= '' and l ~= s then labels = labels or {} labels[s] = l end
        end
        out.optionLabels = labels
        if d ~= nil then
            if type(d) ~= 'string' or not seen[d] then return nil, ('%s: field %s: its default is not one of its options'):format(t, f.key) end
            out.default = d
        end
    elseif k == 'world' then
        if f.worldKind ~= nil then
            out.worldKind = type(f.worldKind) == 'string' and f.worldKind:match(NAME) and f.worldKind or nil
            if not out.worldKind then return nil, ('%s: field %s: worldKind is a kind of placed thing (spot, npc, vehicle...)'):format(t, f.key) end
        end
    elseif k == 'item' then
        if d ~= nil then
            if type(d) ~= 'string' or d == '' or #d > 60 then return nil, ('%s: field %s: its default is an item\'s key'):format(t, f.key) end
            out.default = d
        end
    elseif k == 'entries' then
        -- A list your own Director button fills (Whip.directorButton with kinds { 'card' }, client/director_buttons.lua):
        -- each entry plain data whose `text` the editor shows on its row. The button adds one (its `add` words) or
        -- changes one; x takes one out. Your run gets the list.
        if type(f.button) ~= 'string' or #f.button > 64 or not f.button:match('^[%a][%w_]*%.[%a][%w_]*$') then
            return nil, ('%s: field %s: button is one of your Director buttons\' id (Whip.directorButton)'):format(t, f.key)
        end
        out.button = f.button
        out.add = text(f.add, 30)
        local max = f.max == nil and 8 or math.tointeger(f.max)
        if not max or max < 1 or max > 12 then return nil, ('%s: field %s: max is 1 to 12 entries'):format(t, f.key) end
        out.max = max
        if d ~= nil then return nil, ('%s: field %s: a list has no default (it starts empty)'):format(t, f.key) end
    end
    return out
end

--- A resource's card (Whip.card's data) as a Director card type, or nil and why.
local function buildDef(owner, t, spec, entry)
    local HELPER = 'use Whip.card (@whip_core/lib/satellite.lua)'
    if type(spec) ~= 'table' or callable(spec) or spec.__whipCard == nil or not callable(entry) then return nil, HELPER end
    if type(t) ~= 'string' or #t > 64 or not t:match('^[%a][%w_]*%.[%a][%w_]*$') then
        return nil, 'a card type is "<your namespace>.<name>", like police.notify'
    end
    local ns = t:match('^([^.]+)')
    local title = text(spec.title, 40)
    if not title or title:match('^%s*$') then return nil, t .. ': it needs a title' end
    if spec.test ~= nil and spec.test ~= 'run' then return nil, t .. ": test is 'run', or left out" end
    local category = (type(spec.category) == 'string' and #spec.category <= 24 and spec.category:match(NAME)) and spec.category or ns
    local def = {
        type = t, v = math.tointeger(spec.v) or 1, owner = owner, entry = entry, satellite = true, heavy = true,
        category = category, categoryTitle = text(spec.categoryTitle, 24), title = title,
        desc = text(spec.desc, 200), help = text(spec.help, 600),
        color = COLORS[spec.color] and spec.color or nil,
        icon = (type(spec.icon) == 'string' and #spec.icon <= 24 and spec.icon:match('^[%w_%-]+$')) and spec.icon or nil,
        testSays = text(spec.testSays, 200), runInTest = spec.test == 'run',
        hasCheck = spec.hasCheck == true, hasOnEnd = spec.hasOnEnd == true,
    }
    if def.v < 1 then return nil, t .. ': v is a whole number of 1 or more' end
    -- Who may add or change it in a scenario: a permission (RegisterPermission's), checked on
    -- every save, copy, restore and Test (Director.gatedChange).
    if spec.permission ~= nil then
        -- (The name rule is server/permissions.lua's: one it would refuse locks the card for everyone.)
        if type(spec.permission) ~= 'string' or #spec.permission < 3 or #spec.permission > 64 or not spec.permission:match('^[%w_%.%-]+$') then
            return nil, t .. ': permission is a permission\'s name (RegisterPermission: 3-64 letters, digits, ".", "_" and "-"), like police.director'
        end
        def.permission = spec.permission
    end

    -- A FAIL CONDITION (spec.fail): no wires and no outcomes; it fails the run (or takes the player out) when its event
    -- comes. Read below, after its fields.
    local fail = spec.fail
    if fail ~= nil then
        if type(fail) ~= 'table' or callable(fail) then return nil, t .. ': fail is { event, match?, ends?, reason?, filter? }' end
        if spec.outputs ~= nil or spec.event ~= nil or spec.instant ~= nil then
            return nil, t .. ': a fail condition has no outputs, event or instant: it fails the run when its fail.event comes'
        end
    end

    -- Its outcomes, as it names them (whip_core adds Took Too Long and Didn't Work to a thread card).
    local outs = fail and {} or spec.outputs
    if not fail and (type(outs) ~= 'table' or callable(outs) or #outs == 0 or #outs > 8) then return nil, t .. ': outputs is a list of 1 to 8 outcomes' end
    local outputs, labels, seen = {}, {}, {}
    for i, p in ipairs(outs) do
        if type(p) ~= 'string' or #p > 24 or not p:match(NAME) then return nil, ('%s: outcome %d is one word'):format(t, i) end
        if RESERVED_PINS[p] then
            return nil, ('%s: "%s" is whip_core\'s own outcome (every card has Took Too Long and Didn\'t Work)'):format(t, p)
        end
        if seen[p] then return nil, ('%s: outcome "%s" twice'):format(t, p) end
        seen[p] = true
        outputs[#outputs + 1] = p
        local l = type(spec.labels) == 'table' and not callable(spec.labels) and text(spec.labels[p], 30) or nil
        if l and not l:match('^%s*$') then labels[p] = l end
    end
    if spec.bad ~= nil then
        if type(spec.bad) ~= 'table' or callable(spec.bad) then return nil, t .. ': bad is a list of its outcomes' end
        def.bad = {}
        for _, p in ipairs(spec.bad) do
            if not seen[p] then return nil, ('%s: bad names "%s", which is not one of its outcomes'):format(t, tostring(p)) end
            def.bad[#def.bad + 1] = p
        end
    end

    -- What it was called before: a scenario still naming the old card, or an old outcome, is
    -- read as this one (nodes.lua's applyRenames). Only its own namespace's.
    if spec.renamed ~= nil then
        if type(spec.renamed) ~= 'table' or callable(spec.renamed) then
            return nil, t .. ': renamed is { ["<old type>"] = { pins = { oldOutcome = newOutcome } } }'
        end
        def.renamed = {}
        local n = 0
        for old, r in pairs(spec.renamed) do
            n = n + 1
            if n > 8 then return nil, t .. ': 8 renames at most' end
            if type(old) ~= 'string' or old == t or #old > 64 or not old:match('^' .. ns .. '%.[%a][%w_]*$') then
                return nil, ('%s: a card it was called before is in its own namespace (%s.something)'):format(t, ns)
            end
            local pins
            if r ~= nil then
                if type(r) ~= 'table' or callable(r) or (r.pins ~= nil and (type(r.pins) ~= 'table' or callable(r.pins))) then
                    return nil, ('%s: renamed %s is { pins = { oldOutcome = newOutcome } }'):format(t, old)
                end
                for a, b in pairs(r.pins or {}) do
                    if type(a) ~= 'string' or not a:match(NAME) or type(b) ~= 'string' or not seen[b] then
                        return nil, ('%s: renamed %s: pins = { oldOutcome = newOutcome }, the new one this card\'s'):format(t, old)
                    end
                    pins = pins or {}
                    pins[a] = b
                end
            end
            def.renamed[old] = { pins = pins }
        end
    end

    -- Its fields.
    if spec.props ~= nil and (type(spec.props) ~= 'table' or callable(spec.props)) then return nil, t .. ': props is a list of fields' end
    local list = spec.props or {}
    if #list > MAX_FIELDS then return nil, ('%s: %d fields at most'):format(t, MAX_FIELDS) end
    local props, keys = {}, {}
    for i, f in ipairs(list) do
        local nf, why = fieldOf(t, i, f, keys)
        if not nf then return nil, why end
        props[#props + 1] = nf
    end
    -- showIf: shown only while a switch of the same card is on (the switch is a bool field of its).
    for _, nf in ipairs(props) do
        if nf.when ~= nil then
            local sw
            for _, o in ipairs(props) do if o.key == nf.when.key then sw = o end end
            if not sw or sw.kind ~= 'bool' or sw == nf then
                return nil, ('%s: field %s: showIf names one of its own yes/no (bool) fields'):format(t, nf.key)
            end
        end
    end

    if fail then
        -- A fail condition: the event it hears is the resource's own (SendDirectorEvent); whip_core adds its When it is
        -- broken (a rule about one player: the whole run, or only them) and Why, as its own Fail Conditions have.
        if type(fail.event) ~= 'string' or #fail.event > 64 or not fail.event:match('^' .. ns .. '%.[%a][%w_.]*$') then
            return nil, ('%s: fail.event is your event (SendDirectorEvent), named in your own namespace: %s.something'):format(t, ns)
        end
        local match = fail.match == nil and 'player' or fail.match
        if not MATCH[match] then return nil, t .. ": fail.match is 'player', 'run' or 'any'" end
        if fail.ends ~= nil and fail.ends ~= 'everyone' and fail.ends ~= 'them' then return nil, t .. ": fail.ends is 'everyone' or 'them'" end
        if keys.ends or keys.reason then return nil, t .. ': "ends" and "reason" are a fail condition\'s own fields (whip_core adds them)' end
        if #props + 2 > MAX_FIELDS then return nil, ('%s: %d fields at most, with the two a fail condition gets'):format(t, MAX_FIELDS) end
        if match == 'player' then
            props[#props + 1] = { key = 'ends', kind = 'select', label = 'When it is broken', options = { 'everyone', 'them' },
                                  optionLabels = { everyone = 'Fail the run for everyone', them = 'Take only that player out' },
                                  default = fail.ends or 'everyone' }
        end
        props[#props + 1] = { key = 'reason', kind = 'text', label = 'Why (said to the player)', maxLength = 120,
                              default = text(fail.reason, 120) or 'A rule of the job was broken' }
        -- With whip_core's own Fail Conditions, unless it names a group of its own.
        if spec.category == nil then def.category = 'fail' end
        def.condition = true
        def.inputs = {}
        def.satEvent = { name = fail.event, match = match, hasFilter = fail.hasFilter == true }
        def.event = { name = 'script.event', once = false, filter = function(ctx, p) return failFilter(ctx, p) end }
    elseif spec.event ~= nil then
        local ev = spec.event
        if type(ev) ~= 'table' or callable(ev) then return nil, t .. ': event is { name, match?, once? }' end
        if type(ev.name) ~= 'string' or #ev.name > 64 or not ev.name:match('^' .. ns .. '%.[%a][%w_.]*$') then
            return nil, ('%s: its event is named in its own namespace: %s.something'):format(t, ns)
        end
        if ev.match ~= nil and not MATCH[ev.match] then return nil, t .. ": event.match is 'player', 'run' or 'any'" end
        def.inputs = {}
        def.satEvent = { name = ev.name, match = ev.match or 'player', hasFilter = ev.hasFilter == true }
        def.event = { name = 'script.event', once = ev.once ~= false, filter = function(ctx, p) return eventFilter(ctx, p) end }
    elseif spec.instant == true then
        def.instant = true
        outputs[#outputs + 1] = 'didntWork'
        labels.didntWork = 'Didn\'t work'
        def.quietPins = { didntWork = true }
        def.run = function(ctx) return instantRun(ctx) end
    else
        local giveUp = math.tointeger(spec.timeout) or 30
        if giveUp < 1 or giveUp > 3600 then return nil, t .. ': timeout is 1 to 3600 seconds' end
        props[#props + 1] = { key = 'giveUpAfter', kind = 'duration', label = 'Give up after (seconds)', default = giveUp, min = 1, max = 3600 }
        outputs[#outputs + 1] = 'didntWork'
        outputs[#outputs + 1] = 'timeout'
        labels.didntWork, labels.timeout = 'Didn\'t work', 'Took too long'
        def.latent, def.yields = true, true
        def.quietPins = { didntWork = true }
        def.run = function(ctx) return threadRun(ctx) end
    end
    -- Only Once (nodes.lua): `once = false` on a card the run waits at for a player (it never offers it);
    -- `onceOut` the outcome a skipped one goes on through (else its first).
    if spec.once ~= nil then
        if type(spec.once) ~= 'boolean' then return nil, t .. ': once is true or false' end
        def.once = spec.once
    end
    if spec.onceOut ~= nil then
        if not seen[spec.onceOut] then return nil, ('%s: onceOut names "%s", which is not one of its outcomes'):format(t, tostring(spec.onceOut)) end
        def.onceOut = spec.onceOut
    end
    def.outputs, def.labels, def.props = outputs, labels, props
    if def.hasCheck then def.check = function(p, doc) return cardCheck(def, p, doc) end end
    return def
end

-- ============================================
-- Calling a resource's own code
-- ============================================

--- Run the resource's entry for `op`: its answer (a table), or nil and why. Through Actions.call, so
--- what it saves through whip ties to the right action. The NEWEST entry for the type: a resource
--- that restarted has registered a new one, and its scenarios' compiled cards keep working.
local function invoke(def, op, payload)
    local owner = def.owner
    if not Registry.alive(owner) then return nil, owner .. ' is not running' end
    local live = DirectorNodes.get(def.type)
    if not live or live.owner ~= owner then return nil, ('%s is not %s\'s card now'):format(def.type, owner) end
    local ok, res = Actions.call(owner, live.entry, op, payload)
    if not ok then
        local msg = res ~= nil and tostring(res) or ''
        if msg == '' then msg = 'its code threw an error (no message comes across from another resource)' end
        return nil, text(msg, 300)
    end
    if type(res) ~= 'table' or callable(res) then return nil, 'its answer was not readable (make the card with Whip.card)' end
    if res.err ~= nil then return nil, text(tostring(res.err), 300) or 'its code failed' end
    return res
end

--- A card's check, run so that one that waits cannot hold whoever is checking: its message (and
--- 'warning'), or nil.
cardCheck = function(def, props, doc)
    -- What the scenario holds, as the card is shown it: made once per Check (DirectorGraph.checking),
    -- not once per card.
    local cur = DirectorGraph.checking
    local view = cur and cur.doc == doc and cur.view or nil
    if not view then
        view = { vars = {}, world = {} }
        for _, v in ipairs(type(doc) == 'table' and type(doc.vars) == 'table' and doc.vars or {}) do
            if type(v) == 'table' then view.vars[#view.vars + 1] = { id = v.id, type = v.type } end
        end
        for _, w in ipairs(type(doc) == 'table' and type(doc.world) == 'table' and doc.world or {}) do
            if type(w) == 'table' then
                -- (Its model, as text; a random vehicle's every model: models.)
                local d = type(w.def) == 'table' and w.def or {}
                local models
                if w.kind == 'vehicle' and d.random == true and type(d.models) == 'table' then
                    models = {}
                    for _, m in ipairs(d.models) do
                        if type(m) == 'table' and type(m.model) == 'string' and m.model ~= '' then models[#models + 1] = m.model end
                    end
                end
                view.world[#view.world + 1] = { id = w.id, kind = w.kind, label = w.label,
                                                model = type(d.model) == 'string' and d.model ~= '' and d.model or nil, models = models }
            end
        end
        if cur and cur.doc == doc then cur.view = view end
    end
    -- And what the card's own resource keeps on each thing (its buttons' saves), as doc.data[worldId]: its own only.
    local data
    for _, w in ipairs(type(doc) == 'table' and type(doc.world) == 'table' and doc.world or {}) do
        local ext = type(w) == 'table' and type(w.def) == 'table' and type(w.def.ext) == 'table' and w.def.ext[def.owner] or nil
        if ext ~= nil and type(w.id) == 'string' then
            data = data or {}
            data[w.id] = small(ext)
        end
    end
    if data then view = { vars = view.vars, world = view.world, data = data } end
    local co = coroutine.create(function() return invoke(def, 'check', { type = def.type, props = small(props) or {}, doc = view }) end)
    local ok, res, why = coroutine.resume(co)
    if coroutine.status(co) ~= 'dead' then
        pcall(coroutine.close, co)
        return 'its check waited (a card\'s check must answer at once)'
    end
    if not ok then return 'it could not be checked: ' .. tostring(res) end
    if not res then
        -- A resource that is not running has no cards: Check says the type is unknown. Anything else is its own fault.
        if not Registry.alive(def.owner) then return nil end
        return 'it could not be checked: ' .. tostring(why)
    end
    local msg = text(res.msg, 200)
    if not msg or msg == '' then return nil end
    return msg, res.severity == 'warning' and 'warning' or nil
end

-- ============================================
-- One card at work: its call record
-- ============================================

local calls = {}   -- [callId] = rec: a card of another resource at work (until its activation ends)
local seq = 0

local function newCallId()
    seq = seq + 1
    return ('%08x%04x%05x'):format(math.random(0, 0x7fffffff), seq % 0x10000, GetGameTimer() % 0x100000)
end

-- What each card of another resource has done since the server started (/director cards), so an owner
-- can see what a downloaded card does. Real runs only (a Test hands out nothing that stays); Tests counted.
-- By owner and type: a resource that takes the namespace later starts its own counts.
local stats = {}   -- [owner .. '\0' .. type] = { atWork, failed, gave, paid, took, tests }

local function statOf(owner, t)
    local k = tostring(owner) .. '\0' .. tostring(t)
    local s = stats[k]
    if not s then
        s = { atWork = 0, failed = 0, gave = 0, paid = 0, took = 0, tests = 0 }
        stats[k] = s
    end
    return s
end

--- It went to work (a thread or instant card ran; an event card's event was heard).
local function counted(run, def)
    local s = statOf(def.owner, def.type)
    if run.test then s.tests = s.tests + 1 else s.atWork = s.atWork + 1 end
end

--- It did not work, in a real run.
local function countFailed(run, def)
    if not run.test then local s = statOf(def.owner, def.type) s.failed = s.failed + 1 end
end

-- TestDirectorCard's runs (below), by their scenario's id (`cardtest:<n>`), kept from BEFORE the run
-- starts: { owner, type, data }.
local cardTests = {}

--- Is this run a TestDirectorCard's (not a builder's Test)? /director send leaves those alone.
function Director.isCardTest(run) return type(run) == 'table' and cardTests[run.scenarioId] ~= nil end

--- A run ended (Director.runEnded, as it starts): a TestDirectorCard waiting on it goes on.
function Director.cardTestEnded(run)
    local t = type(run) == 'table' and cardTests[run.scenarioId]
    if t and t.over and t.over.state == 0 then t.over:resolve(true) end
end

--- A Test's stand-in for this card (it says what it would do), not its code: in a builder's Test,
--- unless it runs itself there (test = 'run'), or it is the card a TestDirectorCard run is testing.
local function standsIn(run, def)
    if not run.test or def.runInTest then return false end
    local t = cardTests[run.scenarioId]
    return not (t and t.type == def.type and t.owner == def.owner)
end

--- The card a TestDirectorCard run tests went on: what it answered with is kept for the answer.
local function caught(run, pin, trigger)
    local t = run and cardTests[run.scenarioId]
    if t and t.data == nil and type(trigger) == 'table' then t.data = trigger.data end
    return pin, trigger
end

local function open(ctx, def, instant)
    local rec = { id = newCallId(), owner = def.owner, type = def.type, def = def, run = ctx.run, nodeId = ctx.node.id,
                  instant = instant == true, player = Director.playerOf(ctx), ctx = ctx }
    calls[rec.id] = rec
    return rec
end

local function close(rec)
    rec.done = true
    calls[rec.id] = nil
end

--- What a placed thing is, for the resource: { id, kind, label, coords, heading }, at THIS run's place
--- when it was started with its own (opts.places).
local function placeOf(run, worldId)
    local w = type(worldId) == 'string' and run.graph.world[worldId] or nil
    if not w then return nil end
    local d = type(w.def) == 'table' and w.def or {}
    local c = (run.places and run.places[worldId]) or (type(d.coords) == 'table' and d.coords) or nil
    return { id = worldId, kind = w.kind, label = text(w.label, 60),
             coords = c and { x = tonumber(c.x), y = tonumber(c.y), z = tonumber(c.z) } or nil, heading = c and tonumber(c.heading) or nil }
end

--- The card a resource's code is handed: plain data (Whip.card puts the methods on it).
local function cardData(ctx, rec)
    local run, def = ctx.run, rec.def
    local props = {}
    for _, f in ipairs(def.props) do
        if f.key ~= 'giveUpAfter' then
            local v = ctx:prop(f.key)
            if f.kind == 'world' then
                v = placeOf(run, v)
            elseif f.kind == 'lore' then
                -- The lore character it picks (the scenario's own when empty), or nil when there is none.
                local c = DirectorLore and DirectorLore.isLive(v) and DirectorLore.get(v) or nil
                v = c and { key = c.key, name = c.name, payName = c.payName, model = c.model } or nil
            elseif f.kind == 'players' then
                -- Who it acts on, as server ids of the run's players (as whip_core's own cards read theirs).
                v = DirectorFields.playersOf(ctx, v, rec.player)
            end
            props[f.key] = small(v)
        end
    end
    return { callId = rec.id, type = def.type, runId = run.id, cardId = ctx.node.id, scenario = run.scenarioId,
             name = run.scenario and run.scenario.name or run.scenarioId, rev = run.rev, test = run.test == true, tag = run.tag,
             player = rec.player, starter = run.starter, players = ctx:players(), trigger = small(ctx.trigger), props = props }
end

--- What follows a card's answer acts for: a run player its data names, else the player the card was for.
local function triggerOf(rec, data)
    local d = small(data)
    local named = type(d) == 'table' and math.tointeger(tonumber(d.source)) or nil
    local who = named and rec.run.players[named] and named or nil
    return { source = who, from = (not who and rec.player) and { source = rec.player } or nil, data = d, card = rec.type }
end

--- Didn't Work: on from that pin when it is wired, otherwise the run faults with why.
local function didntWork(rec, why)
    if rec.done then return false end
    local run = rec.run
    countFailed(run, rec.def)
    say('%s (%s) failed: %s', rec.type, rec.owner, tostring(why))
    Director.event(run, rec.nodeId, 'didn\'t work', nil, text(tostring(why), 120))
    if R.wired(run, rec.nodeId, 'didntWork') then return R.answer(rec.holdId, 'didntWork', triggerOf(rec, nil)) end
    R.fault(run, rec.nodeId, ('%s (%s): %s'):format(rec.def.title, rec.owner, tostring(why)))
    return false
end

--- The card's own answer: one of its outcomes (never whip_core's two). Another is Didn't Work.
local function answer(rec, pin, data)
    if rec.done then return false, 'that card is no longer waiting' end
    if type(pin) ~= 'string' or RESERVED_PINS[pin] or not rec.def._outputs[pin] then
        didntWork(rec, ('it answered "%s", which this card does not have'):format(tostring(pin)))
        return false, ('"%s" is not one of this card\'s outcomes'):format(tostring(pin))
    end
    rec.answered = true
    if not R.answer(rec.holdId, caught(rec.run, pin, triggerOf(rec, data))) then return false, 'that card is no longer waiting' end
    return true
end

--- What a Test says the card would do: its testSays with {field} filled in, or its title and fields.
local function testWords(def, data)
    local function shown(v)
        if type(v) == 'table' then return tostring(v.label or v.name or v.id or '...') end
        if type(v) == 'boolean' then return v and 'yes' or 'no' end
        if v == nil then return '(empty)' end
        return tostring(v)
    end
    if def.testSays then
        return (def.testSays:gsub('{([%w_]+)}', function(k) return shown(data.props[k]) end))
    end
    local parts = {}
    for _, f in ipairs(def.props) do
        if f.key ~= 'giveUpAfter' and #parts < 3 then parts[#parts + 1] = ('%s %s'):format(f.label, shown(data.props[f.key])) end
    end
    return #parts > 0 and ('%s: %s'):format(def.title, table.concat(parts, ', ')) or def.title
end

--- A Test's stand-in for the card: the tester is told, and the test map offers its outcomes.
local function testStand(ctx, rec, data)
    local run, def = ctx.run, rec.def
    local says = testWords(def, data)
    rec.testPick = true
    Director.event(run, rec.nodeId, 'test', nil, text(says, 120))
    local own = {}
    for _, p in ipairs(def.outputs) do if not RESERVED_PINS[p] then own[#own + 1] = { pin = p, label = def.labels[p] or p } end end
    if run.starter then
        NotifyPlayer(run.starter, ('Test: %s (%s)'):format(says, def.owner), 'info')
        TriggerClientEvent('whip_core:client:directorTestCard', run.starter,
            { runId = run.id, callId = rec.id, node = rec.nodeId, title = def.title, owner = def.owner, says = says, outcomes = own,
              seconds = TEST_PICK_MS // 1000 })
    end
    ctx:after(TEST_PICK_MS, own[1].pin)
end

--- The objective and clock a card put up (card:objective, card:clock: METHODS below), taken down.
local function takeDown(rec)
    local run = rec.run
    if not run then return end
    for _, what in ipairs({ 'objective', 'clock' }) do
        local key = ('card:%s:%s'):format(rec.nodeId, what)
        if rec.shown and rec.shown[what] then
            for s in pairs(run.players) do
                if what == 'objective' then DirectorBand.clearObjective(run, s, key) else DirectorBand.stopClock(run, s, key) end
            end
            Director.followCrew(run, key, nil)
        end
    end
end

--- The activation ended (answered, out of time, pulsed again, the run ended): the record goes, and the
--- resource hears of an end that was not its own answer (onEnd), outside the pass.
local function ended(rec, pin, why)
    local own = rec.answered and why == 'answered' and pin ~= 'timeout' and pin ~= 'didntWork'
    local starter = rec.run and rec.run.starter
    -- Not its own answer: what it showed goes with it, since its methods are refused from now on and it could not
    -- take them down itself. (One that answers decides for itself: card:clearObjective first.)
    if not own then takeDown(rec) end
    close(rec)
    -- A call into a resource that stopped while it worked never comes back, and its thread holds this
    -- record for good: not the run as well.
    rec.run = nil
    -- A Test's stand-in went on (picked, its first by itself, the run ended): the strip drops its outcomes.
    if rec.testPick and starter then TriggerClientEvent('whip_core:client:directorTestCardDone', starter, rec.id) end
    if own or rec.testPick or not rec.started or not rec.def.hasOnEnd then return end
    local reason = (pin == 'timeout' and 'timeout') or (pin == 'didntWork' and 'didntWork') or (why == 'run ended' and 'run ended')
        or (why == 'restarted' and 'restarted') or tostring(why)
    SetTimeout(0, function()
        local res, err = invoke(rec.def, 'onEnd', { type = rec.type, callId = rec.id, why = reason })
        if not res and Registry.alive(rec.owner) then say('%s (%s): its onEnd failed: %s', rec.type, rec.owner, tostring(err)) end
    end)
end

threadRun = function(ctx)
    local def, run = ctx.node.def, ctx.run
    local rec = open(ctx, def, false)
    rec.holdId = ctx:hold()
    if not rec.holdId then close(rec) return nil end
    counted(run, def)
    ctx:onEnd(function(pin, why) ended(rec, pin, why) end)
    local data = cardData(ctx, rec)
    if standsIn(run, def) then
        testStand(ctx, rec, data)
        return nil
    end
    ctx:after(math.max(1, tonumber(ctx:prop('giveUpAfter')) or 30) * 1000.0, 'timeout')
    rec.started = true
    -- In a thread of its own, after this pass: the resource's code never runs inside it.
    CreateThread(function()
        if rec.done then return end
        local res, why = invoke(def, 'run', { type = def.type, card = data })
        if rec.done then return end
        if not res then didntWork(rec, why) return end
        if res.pin ~= nil then answer(rec, res.pin, res.data) end
        -- Nothing: Whip.answerCard answers it later (or its time runs out).
    end)
    return nil
end

instantRun = function(ctx)
    local def, run = ctx.node.def, ctx.run
    local rec = open(ctx, def, true)
    counted(run, def)
    local data = cardData(ctx, rec)
    if standsIn(run, def) then
        close(rec)
        local says = testWords(def, data)
        Director.event(run, rec.nodeId, 'test', nil, text(says, 120))
        if run.starter then NotifyPlayer(run.starter, ('Test: %s (%s)'):format(says, def.owner), 'info') end
        return def.outputs[1], triggerOf(rec, nil)
    end
    local res, why = invoke(def, 'run', { type = def.type, card = data })
    close(rec)
    local pin = res and res.pin
    if res and pin ~= nil and (type(pin) ~= 'string' or RESERVED_PINS[pin] or not def._outputs[pin]) then
        res, why = nil, ('it answered "%s", which this card does not have'):format(tostring(pin))
    end
    if not res then
        countFailed(run, def)
        say('%s (%s) failed: %s', def.type, def.owner, tostring(why))
        Director.event(run, rec.nodeId, 'didn\'t work', nil, text(tostring(why), 120))
        if R.wired(run, rec.nodeId, 'didntWork') then return 'didntWork', triggerOf(rec, nil) end
        error(('%s (%s): %s'):format(def.title, def.owner, tostring(why)), 0)
    end
    if pin == nil then return nil end
    return caught(run, pin, triggerOf(rec, res.data))
end

eventFilter = function(ctx, p)
    local def, run = ctx.node.def, ctx.run
    local ev = def.satEvent
    if type(p) ~= 'table' or p.event ~= ev.name then return nil end
    if (p.test == true) ~= (run.test == true) then return nil end   -- a Test hears only /director send
    -- Only the card's own resource's event: another that took its namespace after it
    -- stopped sends the same name, and is not it. (A Test's comes from /director send.)
    if not p.test and p.sender ~= def.owner then return nil end
    local player = p.source ~= nil and ctx:isPlayer(p.source) and p.source or nil
    if ev.match == 'player' and not player then return nil end
    if ev.match == 'run' and p.runId ~= run.id then return nil end
    if not ev.hasFilter or standsIn(run, def) then
        counted(run, def)
        return caught(run, def.outputs[1], { source = player, event = p.event, sender = p.sender, data = p.data, card = def.type })
    end
    -- Its own filter, at once (an event's dispatch must not wait).
    local rec = open(ctx, def, true)
    rec.player = player or rec.player
    local res, why = invoke(def, 'filter', { type = def.type, card = cardData(ctx, rec), event = small(p) })
    close(rec)
    if not res then
        countFailed(run, def)
        error(('%s (%s): its event filter failed: %s'):format(def.title, def.owner, tostring(why)), 0)
    end
    if res.pin == nil then return nil end
    if type(res.pin) ~= 'string' or not def._outputs[res.pin] then
        countFailed(run, def)
        error(('%s (%s): its filter answered "%s", which this card does not have'):format(def.title, def.owner, tostring(res.pin)), 0)
    end
    counted(run, def)
    return caught(run, res.pin, { source = player, event = p.event, sender = p.sender, data = small(res.data) or p.data, card = def.type })
end

--- A resource's FAIL CONDITION (Whip.card's fail) hears its event: about one of the run's players (or for the run, or
--- for any run), and, when it has one, its own filter does not say otherwise: the run fails for everyone, or (a rule
--- about one player, When it is broken: Take only that player out) that player is out of it (ctx:broken, as whip_core's
--- own Fail Conditions: runtime.lua). Its filter may give the words they are told. It never answers an outcome.
failFilter = function(ctx, p)
    local def, run = ctx.node.def, ctx.run
    local ev = def.satEvent
    if type(p) ~= 'table' or p.event ~= ev.name then return nil end
    if (p.test == true) ~= (run.test == true) then return nil end   -- a Test hears only /director send
    if not p.test and p.sender ~= def.owner then return nil end
    local player = p.source ~= nil and ctx:isPlayer(p.source) and p.source or nil
    if ev.match == 'player' and not player then return nil end
    if ev.match == 'run' and p.runId ~= run.id then return nil end
    local reason = ctx:prop('reason')
    -- (In a builder's Test its code does not run unless it says test = 'run': the event alone breaks the rule.)
    if ev.hasFilter and not standsIn(run, def) then
        local rec = open(ctx, def, true)
        rec.player = player or rec.player
        local res, why = invoke(def, 'filter', { type = def.type, card = cardData(ctx, rec), event = small(p) })
        close(rec)
        if not res then
            countFailed(run, def)
            error(('%s (%s): its fail filter failed: %s'):format(def.title, def.owner, tostring(why)), 0)
        end
        if res.pin == nil then return nil end   -- not a broken rule
        local said = type(res.data) == 'table' and text(res.data.reason, 120) or nil
        if said and not said:match('^%s*$') then reason = said end
    end
    counted(run, def)
    caught(run, nil, { source = player, event = p.event, sender = p.sender, data = p.data, card = def.type })
    ctx:broken(player, player ~= nil and ctx:prop('ends') == 'them', reason)
    return nil
end

-- ============================================
-- The card's methods (__DirectorCardDo)
-- ============================================

local function runPlayer(rec, src)
    src = math.tointeger(tonumber(src))
    return src ~= nil and rec.run.players[src] == true and src or nil
end


--- The card's own memory for the run (CTX:state: a test rewound to before it forgets it).
local function cardState(rec) return rec.ctx:state() end

local function waits(rec, name)
    if rec.instant then return ('card:%s waits: this card is instant'):format(name) end
    return nil
end

--- Everyone in the run's band key for this card's objective and clock.
local function bandKey(rec, what) return ('card:%s:%s'):format(rec.nodeId, what) end

local METHODS = {}

function METHODS.var(rec, name)
    if type(name) ~= 'string' or not rec.run.graph.vars[name] then return false, ('"%s" is not one of this scenario\'s variables'):format(tostring(name)) end
    return true, rec.run.vars[name]
end

function METHODS.setVar(rec, name, value)
    local ok, v = Director.checkVar(rec.run.graph, name, value)
    if not ok then return false, v end
    R.setVar(rec.run, name, v)
    return true
end

function METHODS.state(rec)
    return true, small(cardState(rec).card) or {}
end

function METHODS.setState(rec, t)
    if type(t) ~= 'table' then return false, 'a card\'s state is a table' end
    cardState(rec).card = small(t)
    return true
end

function METHODS.place(rec, worldId)
    local p = placeOf(rec.run, worldId)
    if not p then return false, ('"%s" is not one of its placed things'):format(tostring(worldId)) end
    return true, p
end

function METHODS.made(rec, worldId)
    if type(worldId) ~= 'string' or not rec.run.graph.world[worldId] then return false, ('"%s" is not one of its placed things'):format(tostring(worldId)) end
    local h = rec.run.world[worldId]
    if type(h) ~= 'table' then return false, 'the run has not made it (yet)' end
    -- data: what the card's resource keeps on the thing (its buttons' saves: satellite_api.lua). model: a car's, as
    -- made (a random vehicle's is one of its models).
    local car = h.vehicleId and Vehicles.getDef(h.vehicleId) or nil
    return true, { kind = rec.run.graph.world[worldId].kind, netId = h.netId, npcId = h.npcId, vehicleId = h.vehicleId,
                   containerId = h.containerId, groundId = h.groundId, doorId = h.doorId, model = car and car.model or nil,
                   data = Director.thingData(rec.run.graph, worldId, rec.owner) }
end

function METHODS.record(rec, kind, opts)
    kind = text(kind, 30)
    if not kind or kind:match('^%s*$') then return false, 'record says what happened in a few words' end
    local s = cardState(rec)
    s.records = (s.records or 0) + 1
    if s.records > MAX_RECORDS then return false, ('a card writes %d rows a run at most'):format(MAX_RECORDS) end
    opts = type(opts) == 'table' and opts or {}
    local src = opts.source ~= nil and runPlayer(rec, opts.source) or nil
    if opts.source ~= nil and not src then return false, 'source is one of the run\'s players' end
    Director.event(rec.run, rec.nodeId, kind, src, text(opts.detail, 120))
    return true
end

function METHODS.objective(rec, words, opts)
    words = text(words, 200)
    if not words or words:match('^%s*$') then return false, 'an objective is some text' end
    local run, key = rec.run, bandKey(rec, 'objective')
    -- (Taken down by itself if the card ends without its own answer: takeDown.)
    rec.shown = rec.shown or {}
    rec.shown.objective = true
    local who = type(opts) == 'table' and opts.who or nil
    if who ~= nil then
        local s = runPlayer(rec, who)
        if not s then return false, 'who is one of the run\'s players' end
        DirectorBand.objective(run, s, words, key)
        return true
    end
    local has = {}
    for s in pairs(run.players) do DirectorBand.objective(run, s, words, key) has[s] = true end
    -- Everyone's objective is the crew's as it is: one a script puts in sees it too.
    Director.followCrew(run, key, function(players)
        local now = {}
        for _, s in ipairs(players) do
            now[s] = true
            if not has[s] then DirectorBand.objective(run, s, words, key) end
        end
        has = now
    end)
    return true
end

function METHODS.clearObjective(rec)
    local run, key = rec.run, bandKey(rec, 'objective')
    for s in pairs(run.players) do DirectorBand.clearObjective(run, s, key) end
    Director.followCrew(run, key, nil)
    return true
end

function METHODS.clock(rec, seconds, label)
    local run, key = rec.run, bandKey(rec, 'clock')
    seconds = finite(tonumber(seconds))
    if seconds == nil or seconds < 0 or seconds > 86400 then return false, 'a clock is 0 (none) to 86400 seconds' end
    label = text(label, 60) or 'Time left'
    if seconds == 0 then
        for s in pairs(run.players) do DirectorBand.stopClock(run, s, key) end
        Director.followCrew(run, key, nil)
        return true
    end
    rec.shown = rec.shown or {}
    rec.shown.clock = true
    local had = {}
    for s in pairs(run.players) do DirectorBand.clock(run, s, key, seconds, label) had[s] = true end
    local endsAt = GetGameTimer() + math.floor(seconds * 1000)
    Director.followCrew(run, key, function(players)
        local left = (endsAt - GetGameTimer()) / 1000.0
        if left <= 0 then return false end
        local now = {}
        for _, s in ipairs(players) do
            now[s] = true
            if not had[s] then DirectorBand.clock(run, s, key, left, label) end
        end
        had = now
    end)
    return true
end

--- Exactly what the Give Item card does (server/director/nodes_basics.lua): real in a live run, theirs to keep;
--- stamped and taken back when a Test ends. `opts` is no longer read (its `keep` went: a live run's items are always
--- kept). WAITS.
function METHODS.give(rec, src, item, count, metadata)
    local w = waits(rec, 'give')
    if w then return false, w end
    local run = rec.run
    src = runPlayer(rec, src)
    if not src then return false, 'give to one of the run\'s players' end
    if type(item) ~= 'string' or not (Config.Items and Config.Items[item]) then return false, ('%s is not an item on this server'):format(tostring(item)) end
    count = math.tointeger(tonumber(count))
    if not count or count < 1 or count > MAX_GIVE then return false, ('count is a whole number from 1 to %d'):format(MAX_GIVE) end
    if metadata ~= nil and type(metadata) ~= 'table' then return false, 'metadata is a table, or nothing' end
    -- (The run's way: real in a live run, stamped and taken back in a test: effects.lua.)
    local n, why = DirectorEffects.give(run, rec.nodeId, src, item, count, { metadata = small(metadata) })
    if n == 0 then return false, why end
    if not run.test then local s = statOf(rec.owner, rec.type) s.gave = s.gave + n end
    return true, n
end

local function amountOf(v)
    local n = math.tointeger(tonumber(v))
    if not n or n < 1 or n > MAX_MONEY then return nil end
    return n
end

--- Exactly what the Pay card does: a Test only says. WAITS.
function METHODS.pay(rec, src, amount, opts)
    local w = waits(rec, 'pay')
    if w then return false, w end
    local run = rec.run
    src = runPlayer(rec, src)
    if not src then return false, 'pay one of the run\'s players' end
    amount = amountOf(amount)
    if not amount then return false, ('amount is a whole number of dollars from 1 to %d'):format(MAX_MONEY) end
    opts = type(opts) == 'table' and opts or {}
    local method = (opts.method == 'cash' or opts.method == 'bank') and opts.method or 'auto'
    local ok, why = DirectorEffects.pay(run, rec.nodeId, src, amount, { method = method, reason = text(opts.reason, 120) or rec.def.title })
    if not ok then return false, why end
    if not run.test then local s = statOf(rec.owner, rec.type) s.paid = s.paid + amount end
    return true
end

--- Exactly what the Charge Player card does: a Test charges nothing, but says whether they could pay. WAITS.
function METHODS.charge(rec, src, amount, opts)
    local w = waits(rec, 'charge')
    if w then return false, w end
    local run = rec.run
    src = runPlayer(rec, src)
    if not src then return false, 'charge one of the run\'s players' end
    amount = amountOf(amount)
    if not amount then return false, ('amount is a whole number of dollars from 1 to %d'):format(MAX_MONEY) end
    opts = type(opts) == 'table' and opts or {}
    local method = (opts.method == 'cash' or opts.method == 'bank') and opts.method or 'auto'
    local receipt, why = DirectorEffects.charge(run, rec.nodeId, src, amount, { method = method, reason = text(opts.reason, 120) or rec.def.title })
    if not receipt then return false, why end
    if not run.test then local s = statOf(rec.owner, rec.type) s.took = s.took + amount end
    return true
end

function METHODS.finish(rec, outcome, reason)
    if outcome ~= 'succeeded' and outcome ~= 'failed' and outcome ~= 'calledOff' then
        return false, "outcome is 'succeeded', 'failed' or 'calledOff'"
    end
    reason = text(reason, 120)
    Director.event(rec.run, rec.nodeId, 'ended', nil, ('ended by %s: %s'):format(rec.def.title, outcome))
    if not R.finishRun(rec.run.id, outcome, reason or ('ended by ' .. rec.def.title)) then return false, 'that run is not going' end
    return true
end

function METHODS.log(rec, msg)
    say('run %d card %s (%s): %s', rec.run.id, rec.nodeId, rec.owner, text(tostring(msg), 300))
    return true
end

-- ============================================
-- Whose cards a scenario runs, and their resources coming and going
-- ============================================
--
--   * WHOSE. When a person switches a scenario on (or an admin accepts its pack), which resource provides
--     each of its other-resource cards is recorded (DirectorStore.setCardProviders). The SERVER bringing
--     it back by itself (a boot, its cards returning) does so only from those same resources: if
--     police.notify now comes from police_v2, it stays off until a person switches it on again. So no
--     resource can put its own code inside a scenario somebody approved.
--   * GONE. A card's resource stops: its scenarios start no new runs ("it needs whip_police"), runs going
--     now carry on (one that reaches the card takes Didn't Work), and a Test holding it is ended, with why.
--   * BACK. Brought back by the server and refused because a card it needs is not here yet (a resource
--     that starts after whip_core): it WAITS for them and comes back on by itself once they are ALL here.
--     A switched-on scenario whose cards came back CHANGED is checked and compiled again for its next
--     runs (runs going now finish on the graph they began with); one that no longer passes starts none,
--     with the problem as the reason, until a later change fits again.

--- Every variant's cards (one, with none: graph.lua variantsOf), as saved and as they are called now:
--- { { saved = nodes, named = nodes } }.
local function variantNodes(doc)
    local out = {}
    if type(doc) ~= 'table' then return out end
    for _, v in ipairs(DirectorGraph.variantsOf(doc)) do
        local named = DirectorNodes.applyRenames(v.doc)
        out[#out + 1] = { saved = type(v.doc.nodes) == 'table' and v.doc.nodes or {},
                          named = type(named) == 'table' and type(named.nodes) == 'table' and named.nodes or {} }
    end
    return out
end

--- The variants a switched-on scenario was built with ({ { doc, graph } }; one, from before them).
local function builtVariants(sc)
    return sc.variants or { { doc = sc.doc, graph = sc.graph } }
end

--- The other resources' cards a document uses: { [type] = owner } of those registered now, and the types
--- registered by nobody.
local function cardsOf(doc)
    local have, missing = {}, {}
    for _, v in ipairs(variantNodes(doc)) do
        for _, n in ipairs(v.named) do
            local t = type(n) == 'table' and n.type or nil
            if type(t) == 'string' then
                local owner = DirectorNodes.ownerOf(t)
                if owner == nil then missing[t] = true
                elseif owner ~= CORE then have[t] = owner end
            end
        end
    end
    return have, missing
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Each card of the document as it is saved and as it is called now (another resource may have renamed
--- it), with whoever provides it now: { { saved, now, owner } } for other resources' cards.
local function providedCards(doc)
    local out = {}
    for _, v in ipairs(variantNodes(doc)) do
        for i, n in ipairs(v.saved) do
            local m = v.named[i]
            local saved = type(n) == 'table' and n.type or nil
            local now = type(m) == 'table' and m.type or saved
            local owner = type(now) == 'string' and DirectorNodes.ownerOf(now) or nil
            if type(saved) == 'string' and owner ~= nil and owner ~= CORE then out[#out + 1] = { saved = saved, now = now, owner = owner } end
        end
    end
    return out
end

--- The server bringing it back (a script switching it, a refit): does a card now come from a resource a
--- person did not accept? Why it stays off, or nil. Asked under the card's saved name and the name it is
--- called by now, so a rename (renamed = ...) cannot hide a card changing hands.
function Director.cardsChangedHands(key, doc)
    local stamp = DirectorStore.cardProviders(key)
    if not stamp then return nil end
    for _, c in ipairs(providedCards(doc)) do
        for _, name in ipairs({ c.saved, c.now }) do
            local was = stamp[name]
            if was ~= nil and was ~= c.owner then
                return ('%s now comes from %s (was %s): switch it on again to accept'):format(name, c.owner, tostring(was))
            end
        end
    end
    return nil
end

--- Switched on: who provides its cards now is recorded (under their saved names and their names now),
--- by a person always, by the server only the first time (a scenario switched on before this was kept).
--- WAITS (it writes the store).
function Director.stampCards(key, doc, by)
    if by == nil and DirectorStore.cardProviders(key) ~= nil then return end
    local map = {}
    for _, c in ipairs(providedCards(doc)) do map[c.saved] = c.owner map[c.now] = c.owner end
    local ok, why = DirectorStore.setCardProviders(key, map)
    if not ok then say('^3scenario %s: who provides its cards could not be saved: %s^0', key, tostring(why)) end
end

local waiting = {}    -- [key] = { [type] = true }: brought back by the server, refused for these missing cards
                      -- (and 'weapon:<NAME>' for weapons, below)
local retrying = {}   -- [key] = true while a retry is under way

--- The weapons its NPCs and Fixed Weapons name that this server has not got now, into `into` as 'weapon:<NAME>': at a
--- boot, one another resource adds (shared/weapon_catalog.lua: whip_gunny's) may come after its scenario is brought back.
local function weaponsMissing(doc, into)
    if type(doc) ~= 'table' then return end
    for _, v in ipairs(DirectorGraph.variantsOf(doc)) do
        for _, w in ipairs(type(v.doc.world) == 'table' and v.doc.world or {}) do
            local def = type(w) == 'table' and type(w.def) == 'table' and w.def or nil
            local wpn = def and (type(def.weapon) == 'table' and def.weapon.name or def.weapon)
            if type(wpn) == 'string' and wpn ~= '' and (w.kind == 'npc' or w.kind == 'prop') then
                local have = w.kind == 'npc' and WeaponCatalog.get(wpn) or WeaponCatalog.modelOf(wpn)
                if not have then into['weapon:' .. wpn:upper()] = true end
            end
        end
    end
end

--- Is it here now: a card type, or 'weapon:<NAME>'.
local function arrived(t)
    local gun = t:match('^weapon:(.+)$')
    if gun then return WeaponCatalog.get(gun) ~= nil end
    return DirectorNodes.get(t) ~= nil
end

--- Brought back by the server and refused: when it was for cards nobody provides yet, or weapons nobody adds yet, it
--- waits for them.
function Director.waitForCards(key, doc)
    local _, missing = cardsOf(doc)
    weaponsMissing(doc, missing)
    if next(missing) == nil then waiting[key] = nil return end
    waiting[key] = missing
    say('scenario %s waits for %s: it comes back on by itself when they are here', key, table.concat(sortedKeys(missing), ', '))
end

--- Uses one of another resource's cards (compiled).
local function usesOthers(graph, owner)
    for _, node in pairs(graph.nodes) do
        local d = node.def
        if d and d.satellite and (owner == nil or d.owner == owner) then return true end
    end
    return false
end

--- A card it was compiled with that is not here now (its resource stopped, or took it away): why, or nil.
--- Each card read under the name it has now (a card renamed since is not gone).
local function cardGone(sc)
    for _, v in ipairs(builtVariants(sc)) do
        local names = {}
        if type(v.doc) == 'table' then
            local named = DirectorNodes.applyRenames(v.doc)
            for _, n in ipairs(type(named) == 'table' and type(named.nodes) == 'table' and named.nodes or {}) do
                if type(n) == 'table' and n.id ~= nil then names[n.id] = n.type end
            end
        end
        for id, node in pairs(v.graph.nodes) do
            local d = node.def
            if d == nil then return ('it needs the card %s, which nothing provides'):format(tostring(node.type)) end
            if d.satellite then
                local t = type(names[id]) == 'string' and names[id] or d.type
                local live = DirectorNodes.get(t)
                if not live and Registry.alive(d.owner) then
                    return ('it needs the card %s, which %s no longer adds'):format(t, d.owner)
                elseif not live or live.owner ~= d.owner then
                    return ('it needs %s, which is not running'):format(d.owner)
                end
            end
        end
    end
    return nil
end

--- A run of it now: refused while a card it needs is not here, or came back not fitting. Why, or nil.
function Director.cardsMissing(sc)
    local why = sc.cardProblem or cardGone(sc)
    return why and 'This is not available right now: ' .. why or nil
end

--- A switched-on scenario using other resources' cards, compiled again from its document for its next
--- runs (they may have changed), or kept from starting any while it does not fit.
local function refit(key, sc)
    -- Never onto another resource's code: a card that changed hands since the scenario
    -- was switched on (its resource stopped, another took the namespace) keeps it from new runs until a
    -- person switches it on again; the one it was switched on with coming back puts it right.
    local moved = Director.cardsChangedHands(key, sc.doc)
    for _, v in ipairs(moved and {} or builtVariants(sc)) do
        local named = DirectorNodes.applyRenames(v.doc)
        for _, n in ipairs(type(named) == 'table' and type(named.nodes) == 'table' and named.nodes or {}) do
            local was = type(n) == 'table' and v.graph.nodes[n.id] or nil
            local d = was and was.def
            local owner = d and d.satellite and type(n.type) == 'string' and DirectorNodes.ownerOf(n.type) or nil
            if d and owner ~= nil and owner ~= d.owner then
                moved = ('%s now comes from %s (was %s): switch it on again to accept'):format(n.type, owner, d.owner)
                break
            end
        end
        if moved then break end
    end
    if moved then
        if sc.cardProblem ~= moved then say('^3scenario %s starts no new runs: %s^0', key, moved) end
        sc.cardProblem = moved
        return
    end
    local ok, probs = DirectorGraph.check(sc.doc)
    if ok then
        -- Each variant again; Variant 1's is the scenario's.
        if sc.variants then
            for _, v in ipairs(sc.variants) do v.graph = DirectorGraph.compile(v.doc) end
            sc.graph = sc.variants[1].graph
        else
            sc.graph = DirectorGraph.compile(sc.doc)
        end
        if sc.cardProblem then say('scenario %s starts runs again: its cards fit', key) end
        sc.cardProblem = nil
        return
    end
    -- A card taken away (its resource still running) is said as that, not as Check's "unknown card type".
    local msg = cardGone(sc)
    for _, p in ipairs(msg == nil and probs or {}) do if p.severity == 'error' then msg = tostring(p.message) break end end
    msg = msg or 'it no longer passes Check'
    if sc.cardProblem ~= msg then say('^3scenario %s starts no new runs: %s^0', key, msg) end
    sc.cardProblem = msg
end

local queued = false
local pushedRev = -1

--- The editors open now are told the card list moved (hub.lua), once per change of it.
local function catalogueChanged()
    if DirectorNodes.rev == pushedRev then return end
    pushedRev = DirectorNodes.rev
    Director.cardsCatalogueChanged(DirectorNodes.rev)
end

--- Cards were added or changed (a tick's worth at once).
local function cardsArrived()
    queued = false
    catalogueChanged()
    -- Shipped scenarios that wait for their own resource's cards are checked again (packs.lua). Waits.
    CreateThread(function()
        local ok, err = pcall(DirectorPacks.recheck)
        if not ok then say('^1checking shipped scenarios again failed: %s^0', tostring(err)) end
    end)
    for _, key in ipairs(sortedKeys(waiting)) do
        local all = true
        for t in pairs(waiting[key]) do if not arrived(t) then all = false break end end
        local row = all and DirectorStore.get(key) or nil
        if all and not retrying[key] then
            waiting[key] = nil
            -- Still meant to be on, and not on already (a person may have switched it since).
            if row and row.status == 'active' and not Director.active[key] then
                retrying[key] = true
                CreateThread(function()
                    local ok, res = Director.activateStored(key, nil, nil, { onlyIfOff = true })
                    retrying[key] = nil
                    if ok then say('scenario %s is back on: the cards it needs are here', key)
                    elseif not waiting[key] then
                        say('^3scenario %s did not come back on: %s^0', key, Director.whyNotOn(res))
                    end
                end)
            end
        end
    end
    for _, key in ipairs(sortedKeys(Director.active)) do
        local sc = Director.active[key]
        local uses = false
        for _, v in ipairs(sc and builtVariants(sc) or {}) do uses = uses or usesOthers(v.graph) end
        if uses then refit(key, sc) end
    end
end

local function cardsChanged()
    if queued then return end
    queued = true
    SetTimeout(0, cardsArrived)
end

--- The editor's catalogue moved some other way (another resource's tasks: tasks.lua; weapons added or gone: main.lua;
--- skill games: nodes_heist.lua): the same push, after this tick (core.lua's Director.catalogueChanged).
Director.onCatalogueChanged(cardsChanged)

-- ============================================
-- Gated cards
-- ============================================
--
-- A card may name a permission (`permission = 'police.director'`). Someone without it cannot ADD one to
-- a scenario or CHANGE one's fields, but edits the rest of a scenario that has one: a card of that type
-- they lack the right for must be there, the same type and the same fields, in the revision they began
-- from. So a copy, or an example, cannot carry one in, and a Restore is held to the draft it replaces.
-- Asked on every save, copy, restore and Test (hub.lua): where every edit passes. Switching a scenario
-- on stays a builder's, so this guards editing and testing, not running.

--- Why `src` may not save `doc` over `base` (a gated card added or changed), or nil when they may.
---@param src number
---@param doc table
---@param base table|nil  the revision they began from (nil: nothing, a new scenario)
---@return string|nil why
function Director.gatedChange(src, doc, base)
    -- Both as their cards are called now (a gated card under a name it had before would otherwise
    -- get past a check by the saved name), in every variant: one could not carry a gated card in through
    -- Variant 2. A card passes when ANY variant they began from has it as it is (the same id, type and
    -- fields): a new variant is a copy of one, its ids kept.
    local before = {}
    for _, v in ipairs(variantNodes(base)) do
        for _, n in ipairs(v.named) do
            if type(n) == 'table' and type(n.id) == 'string' then
                local list = before[n.id] or {}
                before[n.id] = list
                list[#list + 1] = n
            end
        end
    end
    for _, v in ipairs(variantNodes(doc)) do
        for _, n in ipairs(v.named) do
            local t = type(n) == 'table' and n.type or nil
            local def = type(t) == 'string' and DirectorNodes.get(t) or nil
            local perm = def and def.permission
            -- A card nothing provides now (its resource stopped) cannot be told apart from a gated one: kept
            -- as it was, never added or changed, until it is back.
            if def == nil or (perm and not Permissions.has(src, perm)) then
                local same = false
                for _, b in ipairs(type(n) == 'table' and before[n.id] or {}) do
                    if b.type == t and Registry.deepEquals(b.props or {}, n.props or {}) then same = true break end
                end
                if not same then
                    if def == nil then
                        return ('the card %s is not on this server now (the resource that adds it may be stopped): it cannot be added or changed until it is back')
                            :format(tostring(t))
                    end
                    return ('%s needs the permission %s: without it you cannot add it or change its fields (the rest is yours to edit)')
                        :format(def.title, perm)
                end
            end
        end
    end
    return nil
end

-- ============================================
-- Exports
-- ============================================

--- __RegisterDirectorCard(cardType, card, entry) -> true | false, why. Through Whip.card only: it sends
--- the card as data and the one function that runs its code.
exports('__RegisterDirectorCard', function(cardType, card, entry)
    local owner = Registry.caller()
    if owner == CORE then return false, 'whip_core\'s own cards are defined in its files' end
    local def, why = buildDef(owner, cardType, card, entry)
    if not def then return false, why end
    local ok, err = DirectorNodes.claimSpace(owner, cardType:match('^([^.]+)'))
    if not ok then return false, err end
    ok, err = DirectorNodes.defineFor(owner, def)
    if not ok then return false, err end
    cardsChanged()
    return true
end)

--- __RemoveDirectorCard(cardType) -> true | false, why. Only your own.
exports('__RemoveDirectorCard', function(cardType)
    local owner = Registry.caller()
    if type(cardType) ~= 'string' then return false, 'cardType is the card\'s type' end
    local ok, why = DirectorNodes.remove(owner, cardType)
    if ok then cardsChanged() end   -- (open editors' palettes, and what uses it)
    return ok, why
end)

--- __AnswerDirectorCard(callId, outcome, data?) -> true | false, why. A thread card's answer, later: the
--- run goes on from `outcome` (one of the card's own), `data.source` (one of its players) acting for.
exports('__AnswerDirectorCard', function(callId, outcome, data)
    local by = Registry.caller()
    local rec = type(callId) == 'string' and calls[callId] or nil
    if not rec or rec.done or rec.owner ~= by or rec.instant or rec.testPick or not R.holding(rec.holdId) then
        return false, 'that card is no longer waiting'
    end
    if data ~= nil and type(data) ~= 'table' then return false, 'data is a table, or nothing' end
    return answer(rec, outcome, data)
end)

--- __DirectorCardDo(callId, method, ...) -> what the method answers. The card's methods (Whip.card's).
exports('__DirectorCardDo', function(callId, method, ...)
    local by = Registry.caller()
    local rec = type(callId) == 'string' and calls[callId] or nil
    -- (The same answer for someone else's card: a handle another resource holds or guesses tells it nothing.)
    if not rec or rec.done or rec.owner ~= by or rec.run.status ~= 'running' then return false, 'that card is no longer running' end
    local fn = type(method) == 'string' and METHODS[method] or nil
    if not fn then return false, ('a card has no method "%s"'):format(tostring(method)) end
    return fn(rec, ...)
end)

-- ============================================
-- TestDirectorCard: one of your cards, run once without a builder
-- ============================================
--
-- For a card's author: the card in a scenario of its own (Scenario Enabled -> the card -> each outcome
-- ends it), played as a builder's Test is, by the player named. ITS REAL CODE RUNS, as `test = 'run'`
-- would, but only ever in a Test: Give hands out what the run's end takes back, Pay only says, Charge
-- charges nothing, and no script hears of the run.

local CARD_TEST_MAX_S = 120
local CARD_TESTS_AT_ONCE = 2   -- a resource's own, at a time
local cardTestSerial = 0

--- A place field given as a place, as a spot of the test's own (its id), or nil and why.
local function placeArg(f, v)
    local tv = type(v)
    if tv ~= 'table' and tv ~= 'vector3' and tv ~= 'vector4' then return nil end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not (finite(x) and finite(y) and finite(z)) then return nil, ('%s is a place: { x, y, z }'):format(f.key) end
    if f.worldKind and f.worldKind ~= 'spot' then
        return nil, ('%s takes a placed %s: TestDirectorCard places only spots'):format(f.key, f.worldKind)
    end
    -- (A vector has no `heading`: only a table's is read.)
    local h = (tv == 'vector4' and v.w) or (tv == 'table' and v.heading) or nil
    return { id = 'place_' .. f.key, kind = 'spot', layer = 'run', label = f.label,
             def = { coords = { x = x, y = y, z = z, heading = finite(tonumber(h)) or 0.0 } } }
end

--- TestDirectorCard(cardType, props?, opts) -> { outcome, data } | false, why   WAITS (until it answers)
---   cardType  one of YOUR cards ('police.notify'): another resource's is its author's to test
---   props     its fields, as the editor sets them; a place field (kind 'world') takes { x, y, z, heading? }
---   opts      { player = <server id>: the run is theirs (required, as a builder's Test is the tester's);
---               seconds = 1 to 120, how long to wait (default: its Give up after, and 5 more);
---               event = { ... }: an event card's payload, as SendDirectorEvent's (source: the player) }
--- outcome is the one it took ('timeout' when its time ran out); data what it answered with. Refused:
--- Check's first problem; it failed (Didn't work's reason); it had not answered in time.
--- YOUR CODE RUNS, with card.test true: keep what it does to card.player then (no real dispatch to the
--- police, no messages to everyone). A Give up after longer than the wait is shortened to fit in it.
exports('TestDirectorCard', function(cardType, props, opts)
    local by = Registry.caller()
    if Director.off then return false, 'The Director is off: ' .. Director.off end
    local def = type(cardType) == 'string' and DirectorNodes.get(cardType) or nil
    if not def then return false, ('there is no card %s'):format(tostring(cardType)) end
    if not def.satellite or def.owner ~= by then return false, ('%s is %s\'s card: test your own'):format(cardType, tostring(def.owner or CORE)) end
    if props ~= nil and type(props) ~= 'table' then return false, 'props is a table of its fields' end
    opts = type(opts) == 'table' and opts or {}
    if opts.event ~= nil and type(opts.event) ~= 'table' then return false, 'opts.event is a table (the payload)' end
    local src = math.tointeger(tonumber(opts.player))
    local p = src and Players[src]
    if not (p and p.charId) then return false, 'opts.player is a player on a character: the test run is theirs' end
    if Director.hasTest(src) then return false, 'that player is testing in the editor: stop it first' end
    local mine = 0
    for _, ct in pairs(cardTests) do if ct.owner == by then mine = mine + 1 end end
    if mine >= CARD_TESTS_AT_ONCE then return false, ('%d tests of your cards at a time'):format(CARD_TESTS_AT_ONCE) end

    -- Its fields, a place made a spot of the test's own.
    local fields, world = {}, {}
    for k, v in pairs(props or {}) do if type(k) == 'string' then fields[k] = v end end
    local giveUp = math.tointeger(tonumber(fields.giveUpAfter))
    for _, f in ipairs(def.props) do
        if f.kind == 'world' then
            local w, why = placeArg(f, fields[f.key])
            if why then return false, why end
            if w then
                world[#world + 1] = w
                fields[f.key] = w.id
            end
        elseif f.key == 'giveUpAfter' and giveUp == nil then
            giveUp = math.tointeger(f.default)   -- (its own timeout: Whip.card's `timeout`)
        end
    end
    giveUp = giveUp or 0
    local seconds = math.tointeger(tonumber(opts.seconds)) or math.min(CARD_TEST_MAX_S, giveUp + 5)
    if seconds < 1 or seconds > CARD_TEST_MAX_S then return false, ('opts.seconds is 1 to %d'):format(CARD_TEST_MAX_S) end
    -- A thread card's Took too long comes inside the wait, so it can be the answer (300 s fits as 115 s).
    if def.latent and seconds > 5 and giveUp > seconds - 5 then fields.giveUpAfter = seconds - 5 end

    -- Scenario Enabled -> the card -> each of its outcomes ends the run, saying which (Didn't work is
    -- left unwired: the run fails with its reason).
    local nodes = { { id = 'start', type = 'scenario.started', v = 1, x = 0, y = 0, props = {} },
                    { id = 'card', type = cardType, v = def.v or 1, x = 280, y = 0, props = fields } }
    local links = {}
    if not def.event then links[1] = { id = 'l0', from = { node = 'start', pin = 'out' }, to = { node = 'card', pin = 'in' } } end
    for i, pin in ipairs(def.outputs) do
        if pin ~= 'didntWork' then
            nodes[#nodes + 1] = { id = 'end' .. i, type = 'scenario.succeed', v = 1, x = 560, y = (i - 1) * 140, props = { reason = pin } }
            links[#links + 1] = { id = 'l' .. i, from = { node = 'card', pin = pin }, to = { node = 'end' .. i, pin = 'in' } }
        end
    end
    cardTestSerial = cardTestSerial + 1
    local key = ('cardtest:%d'):format(cardTestSerial)   -- (a colon: never a stored scenario's key)
    local doc = { format = DirectorDoc.FORMAT, name = 'Test of ' .. cardType, vars = {}, world = world, nodes = nodes, links = links,
                  settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, maxRunSec = seconds + 10 } }
    local ok, probs = DirectorGraph.check(doc)
    if not ok then
        for _, pr in ipairs(probs or {}) do if pr.severity == 'error' then return false, 'Check: ' .. tostring(pr.message) end end
        return false, 'it does not pass Check'
    end
    local sc, bwhy = Director.build(key, doc, { prefix = 'test' })
    if not sc then return false, bwhy end
    -- Known by its scenario's id BEFORE it starts: its card is never a Test's stand-in, whenever it runs.
    local ct = { owner = by, type = cardType }
    cardTests[key] = ct
    local run, rwhy = Director.startRun(sc, src, { source = src }, { test = true })
    if not run then
        cardTests[key] = nil
        Registry.releaseTag(CORE, sc.tag)
        return false, rwhy
    end
    say('%s tests its card %s (run %d, for player %d)', by, cardType, run.id, src)
    if def.event then
        local payload = small(opts.event) or {}
        if payload.source == nil then payload.source = src end
        Director.sendEvent(def.satEvent.name, payload, { runId = run.id }, by, true)
    end
    -- Until the run ends (Director.cardTestEnded, before its tidying), or the time is up.
    if run.status == 'running' then
        ct.over = promise.new()
        SetTimeout(seconds * 1000, function() if ct.over.state == 0 then ct.over:resolve(false) end end)
        Citizen.Await(ct.over)
    end
    -- AFTER THE WAIT: still going, it is ended here (its run's end takes back what it gave).
    local late = run.status == 'running'
    if late then R.abort(run.id, 'TestDirectorCard: it had not answered') end
    cardTests[key] = nil
    Registry.releaseTag(CORE, sc.tag)
    if late then return false, ('it had not answered after %d seconds'):format(seconds) end
    local outcome, reason = run.status, run.reason
    -- Ended by one of its outcomes' Succeed (its reason is the outcome), not by its own card:finish.
    if outcome == 'succeeded' and type(reason) == 'string' and def._outputs[reason] then return { outcome = reason, data = ct.data } end
    if outcome == 'faulted' then return false, tostring(reason) end
    return false, ('its test run was %s: %s'):format(tostring(outcome), tostring(reason))
end)

--- `/director cards` (main.lua): every card of another resource, what it has done since the server
--- started, and the switched-on scenarios using it with the resource each was switched on with.
function Director.cardsReport()
    local lines, list = {}, {}
    for _, w in ipairs(DirectorNodes.wire()) do
        local c = DirectorNodes.get(w.type)
        if c and c.satellite then list[#list + 1] = c end
    end
    table.sort(list, function(a, b) return a.type < b.type end)
    for _, c in ipairs(list) do
        local s = statOf(c.owner, c.type)
        local kind = c.event and 'event' or (c.instant and 'instant' or 'thread')
        lines[#lines + 1] = ('%s "%s" (%s, %s card%s): at work %d, didn\'t work %d, tested %d; handed out %d items, paid $%d, took $%d')
            :format(c.type, c.title, c.owner, kind, c.permission and (', needs ' .. c.permission) or '', s.atWork, s.failed, s.tests,
                    s.gave, s.paid, s.took)
        for _, key in ipairs(sortedKeys(Director.active)) do
            local sc = Director.active[key]
            for _, node in pairs(sc.graph.nodes) do
                if node.def and node.def.type == c.type then
                    local stamp = DirectorStore.cardProviders and DirectorStore.cardProviders(key) or nil
                    local by = stamp and stamp[c.type]
                    lines[#lines + 1] = (by and ('    used by %s (switched on with %s\'s card)'):format(key, tostring(by)))
                        or (not DirectorStore.get(key) and ('    used by %s (loaded from a file: /director load)'):format(key))
                        or ('    used by %s (switched on before cards were stamped)'):format(key)
                    break
                end
            end
        end
    end
    if #lines == 0 then lines[1] = 'no other resource adds cards' end
    return lines
end

-- The tester picks the outcome a card of another resource takes in a Test (the test strip).
SecureEvent('whip_core:server:directorTestPick', {
    whileDead = true, rateLimit = 300, burst = 4,
    params = { { 'callId', 'string', 40 }, { 'pin', 'string', 24 } },
}, function(source, _, callId, pin)
    local rec = calls[callId]
    if not rec or not rec.testPick or rec.done or not rec.run.test or rec.run.starter ~= source then return false, 'That card is not waiting' end
    if RESERVED_PINS[pin] or not rec.def._outputs[pin] then return false, 'That is not one of its outcomes' end
    rec.answered = true
    R.answer(rec.holdId, pin, triggerOf(rec, nil))
end)

-- A resource that stops while one of its cards is at work: that card Didn't Work (nothing else would
-- ever answer it). Its card types go with it (the registry's sweep).
AddEventHandler('onResourceStop', function(res)
    if res == CORE then return end
    local mine = {}
    for _, rec in pairs(calls) do
        if rec.owner == res and not rec.instant and not rec.testPick then mine[#mine + 1] = rec end
    end
    table.sort(mine, function(a, b) return a.id < b.id end)
    for _, rec in ipairs(mine) do didntWork(rec, res .. ' stopped') end
    -- A builder's Test holding one of its cards ends, saying so (Reset checks it again first).
    for _, run in ipairs(R.list()) do
        if run.test and run.status == 'running' and usesOthers(run.graph, res) then
            R.abort(run.id, ('%s stopped: its cards are gone'):format(res))
        end
    end
    -- Its cards leave the open editors' palettes (after the registry's sweep of them).
    SetTimeout(0, catalogueChanged)
end)


-- A run's end: whatever is left of its cards' records goes (an instant card that waited, say).
Director.onLife('run:ended', function(p)
    local id = type(p) == 'table' and type(p.run) == 'table' and p.run.id or nil
    if not id then return end
    for _, rec in pairs(calls) do if rec.run.id == id then close(rec) end end
end)
