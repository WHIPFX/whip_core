-- The Director's world cards (talk, place, pick up, take, pay, say). Each calls the same module function a resource
-- would through the export (Conversations, RuntimePoints, Npcs, PlayerText, Money, the ground, the stores). What a card
-- makes carries the run's tag, so the run's end takes it away. A card that waits on the database does it in ctx:call
-- and has a Timeout outcome.
-- Dialog Line speaks for one NPC to the player the trigger carries: it carries on that player's conversation with this
-- run, or opens one from the press that started it, or puts a Talk point on the NPC. Up to four answers, each an
-- outcome pin; an answer wired to another Dialog Line for the same NPC carries the conversation on, any other closes
-- it. Walking away is the Left outcome; no answer in time is Timeout.
-- Each answer has rules: Only if (an item, cash, a player flag set or not, a run variable; not met = not offered),
-- Costs (an item or money, taken when chosen; one they cannot pay is refused), Offered (every time, once a run, once
-- ever), Works (empty = always, 1-99 % a server-rolled chance; a miss leaves by "Answer N failed").
-- A test changes nothing that lasts: costs are only said, flags it sets stay on the test run.

local CORE = GetCurrentResourceName()

local define = DirectorKit.define
local vec = DirectorKit.vec3

-- ============================================
-- Dialog Line
-- ============================================

local OPTS = { 'opt1', 'opt2', 'opt3', 'opt4' }

--- A card's text prop as written (a variable read is the runtime's job; sent-ahead lines use the text).
local function text(node, key)
    local v = node.props[key]
    return type(v) == 'string' and v or nil
end

-- ---- an answer's rules (props optNRule, kind 'rule') ----

local RULE_ONLY  = { 'always', 'has an item', 'carries cash', 'a flag is set', 'a flag is not set', 'a variable is' }
local RULE_COST  = { 'nothing', 'an item', 'money' }
local RULE_OFFER = { 'every time', 'once a run', 'once ever' }
local MONEY_MAX  = 10000000

local function inList(list, x)
    for _, v in ipairs(list) do if v == x then return true end end
    return false
end

local function whole(v, lo, hi) return type(v) == 'number' and v % 1 == 0 and v >= lo and v <= hi end

local itemName = DirectorKit.itemName

--- Check's reading of one answer's rules: a message, or nil when they are fine.
local function checkRule(r, doc)
    if type(r) ~= 'table' then return 'the answer\'s rules are not readable' end
    local only = r.only or 'always'
    if not inList(RULE_ONLY, only) then return ('Only if: "%s" is not one of the choices'):format(tostring(only)) end
    if only == 'has an item' then
        if type(r.item) ~= 'string' or r.item == '' then return 'Only if: pick the item they must have' end
        if not DirectorFields.isItem(r.item) then return ('Only if: "%s" is not an item on this server'):format(r.item) end
        if r.count ~= nil and not whole(r.count, 1, 1000) then return 'Only if: how many is a whole number from 1 to 1000' end
    elseif only == 'carries cash' then
        if not whole(r.cash, 1, MONEY_MAX) then return 'Only if: how much cash, from $1' end
    elseif only == 'a flag is set' or only == 'a flag is not set' then
        if not PlayerFlags.validName(r.flag) then return 'Only if: the flag needs a name (letters, digits and _ . - :, starting with a letter)' end
    elseif only == 'a variable is' then
        local found = false
        for _, v in ipairs(type(doc) == 'table' and type(doc.vars) == 'table' and doc.vars or {}) do
            if type(v) == 'table' and v.id == r.onlyVar then found = true end
        end
        if not found then return 'Only if: pick the variable' end
        if r.value ~= nil and type(r.value) ~= 'string' then return 'Only if: the value is text' end
    end
    local cost = r.cost or 'nothing'
    if not inList(RULE_COST, cost) then return ('Costs: "%s" is not one of the choices'):format(tostring(cost)) end
    if cost == 'an item' then
        if type(r.costItem) ~= 'string' or r.costItem == '' then return 'Costs: pick the item it takes' end
        if not DirectorFields.isItem(r.costItem) then return ('Costs: "%s" is not an item on this server'):format(r.costItem) end
        if r.costCount ~= nil and not whole(r.costCount, 1, 1000) then return 'Costs: how many is a whole number from 1 to 1000' end
    elseif cost == 'money' then
        if not whole(r.costCash, 1, MONEY_MAX) then return 'Costs: how much, from $1' end
    end
    if r.offer ~= nil and not inList(RULE_OFFER, r.offer) then return ('Offered: "%s" is not one of the choices'):format(tostring(r.offer)) end
    if r.chance ~= nil and not whole(r.chance, 1, 99) then return 'Works: a chance is a whole number from 1 to 99 (empty: it always works)' end
    return nil
end

local function ruleOf(node, pin)
    local r = node.props[pin .. 'Rule']
    return type(r) == 'table' and r or nil
end

local function chanceOf(r)
    local c = r and tonumber(r.chance)
    if c and c >= 1 and c <= 99 then return math.floor(c) end
    return nil
end

--- The hidden flag a "once ever" answer leaves on the character: whip's own name (_), short enough
--- for any scenario key and card id.
local function onceFlag(run, node, pin)
    return ('_once:%s:%08x'):format(tostring(run.scenarioId):sub(1, 40), GetHashKey(node.id .. '.' .. pin) % 4294967296)
end

--- A run variable against the text a rule holds, read as the variable's own type.
local function sameValue(have, want)
    if type(have) == 'number' then return tonumber(want) == have end
    if type(have) == 'boolean' then return have == (want == 'true' or want == 'yes') end
    if have == nil then return want == nil or want == '' end
    return tostring(have) == want
end

local function costText(r)
    if r.cost == 'money' then return DirectorKit.money(r.costCash) end
    if r.cost == 'an item' then return ('%d× %s'):format(math.floor(tonumber(r.costCount) or 1), itemName(r.costItem)) end
    return nil
end

--- Is this answer offered to `src` now, by its rules?
local function offered(run, node, pin, src)
    local r = ruleOf(node, pin)
    if not r then return true end
    local only = r.only or 'always'
    if only == 'has an item' then
        if Director.carried(src, r.item, run) < (tonumber(r.count) or 1) then return false end
    elseif only == 'carries cash' then
        if Director.carried(src, 'cash', run) < (tonumber(r.cash) or 0) then return false end
    elseif only == 'a flag is set' then
        if Director.flag(run, src, r.flag) == nil then return false end
    elseif only == 'a flag is not set' then
        if Director.flag(run, src, r.flag) ~= nil then return false end
    elseif only == 'a variable is' then
        if not sameValue(run.vars[r.onlyVar], r.value) then return false end
    end
    if r.cost == 'an item' and Director.carried(src, r.costItem, run) < (tonumber(r.costCount) or 1) then return false end
    local offer = r.offer or 'every time'
    if offer == 'once a run' then
        local s = run.state[node.id]
        if s and s.chosen and s.chosen[src] and s.chosen[src][pin] then return false end
    elseif offer == 'once ever' then
        if Director.flag(run, src, onceFlag(run, node, pin)) ~= nil then return false end
    end
    return true
end

local LABEL_MAX = 60   -- what the capsule shows of an answer (server/conversations.lua)

--- What the answer says on screen: its text, with its cost and its odds when it has them. The cost
--- always shows whole: a long answer's own text is cut to make room, so nobody pays a price they
--- never saw.
local function labelOf(node, pin)
    local label = text(node, pin) or ''
    local r = ruleOf(node, pin)
    if not r then return label end
    local extra = {}
    local c = costText(r)
    if c then extra[#extra + 1] = c end
    local chance = chanceOf(r)
    if chance then extra[#extra + 1] = chance .. '%' end
    if #extra == 0 then return label end
    local suffix = (' [%s]'):format(table.concat(extra, ', '))
    if #label + #suffix > LABEL_MAX then label = DirectorKit.cut(label, LABEL_MAX - #suffix - 3) .. '…' end
    return label .. suffix
end

--- The conversation module's cost for an answer (it charges before the choice counts); none in a test.
local function costOf(run, node, pin)
    local r = ruleOf(node, pin)
    if run.test or not r then return nil end
    local reason = DirectorKit.cut(('%s: %s'):format(tostring(run.scenarioId), text(node, pin) or pin), 120)
    if r.cost == 'money' and tonumber(r.costCash) then
        return { amount = math.floor(r.costCash), method = 'auto', reason = reason }
    elseif r.cost == 'an item' and type(r.costItem) == 'string' then
        return { amount = math.floor(tonumber(r.costCount) or 1), currency = r.costItem, reason = reason }
    end
    return nil
end

--- What a Dialog Line says to `src` now: { line, options = { { id, label, ends, cost } } }, only the
--- answers its rules offer them. An answer with a chance never ends the conversation by itself: what
--- it leads to is known only once rolled (the card closes it after: DirectorTalk.leave).
local function layerFor(run, node, src)
    local options = {}
    for _, pin in ipairs(OPTS) do
        local label = text(node, pin)
        if label and label ~= '' and offered(run, node, pin, src) then
            local chance = chanceOf(ruleOf(node, pin))
            options[#options + 1] = { id = pin, label = labelOf(node, pin),
                                      ends = chance == nil and DirectorTalk.continuesTo(run.graph, node, pin) == nil,
                                      cost = costOf(run, node, pin) }
        end
    end
    return { line = text(node, 'line') or '', options = options }
end

local function ruleProp(i)
    return { key = 'opt' .. i .. 'Rule', kind = 'rule', label = 'Answer ' .. i .. ' rules', check = checkRule }
end

--- The name over what an NPC says (Dialog Line, Sell to NPC, Haggle, Pick Team): Show name 'yes' (the default) is the
--- NPC's own (its lore character's as it is now, else its name), 'no' none, 'other' the Name shown typed.
function DirectorNodes.nameShownField()
    return { key = 'nameShown', kind = 'select', label = 'Show name', options = { 'yes', 'no', 'other' },
             optionLabels = { yes = 'Yes', no = 'No', other = 'Alternative name' }, default = 'yes' }
end
--- A Dialog Line's "If they walk away": 'wait' (the default: their Talk is back on the NPC, and the card waits for
--- them) or 'out' (it goes on from Walked away).
function DirectorNodes.walkAway(props)
    return props.away == 'out' and 'out' or 'wait'
end

--- A talking card's Name shown, the words of its Alternative name: shown only while Show name says so.
function DirectorNodes.speakerField()
    return { key = 'speaker', kind = 'text', label = 'Name shown', maxLength = 40, when = { key = 'nameShown', is = 'other' } }
end

-- A Dialog Line's outcomes, each one only some of the time (its pinWhen): an answer once written, its failure once it
-- has a chance, Walked away when it does not wait for them, No answer with a time limit.
local ANSWER_PINS = { left = { key = 'away', is = 'out' }, timeout = { key = 'seconds', set = true } }
local ANSWER_TEXT = {}   -- (its pinText: an answer's outcome called by its words)
for i = 1, 4 do
    ANSWER_PINS['opt' .. i] = { key = 'opt' .. i, set = true }
    ANSWER_PINS['fail' .. i] = { all = { { key = 'opt' .. i, set = true }, { key = 'opt' .. i .. 'Rule.chance', set = true } } }
    ANSWER_TEXT['opt' .. i] = { key = 'opt' .. i, empty = '(empty answer)' }
    ANSWER_TEXT['fail' .. i] = { key = 'opt' .. i, after = ' (failed)' }
end

function DirectorNodes.shownName(ctx, npcW)
    local props = ctx.node.props
    local typed = ctx:prop('speaker')
    local mode = props.nameShown
    if mode ~= 'no' and mode ~= 'other' then mode = 'yes' end
    if mode == 'no' then return nil end
    if mode == 'other' then return typed end
    local w = ctx.run.graph.world[npcW]
    if type(w) ~= 'table' then return nil end
    local lore = type(w.def) == 'table' and w.def.lore and DirectorLore and DirectorLore.get(w.def.lore) or nil
    return (lore and lore.name) or w.label or nil
end

define({
    type = 'dialog.line', v = 1, category = 'dialog', title = 'Dialog Line',
    once = false,   -- (the run waits here for a player's answer: never Only Once, nodes.lua)
    desc = 'An NPC says a line, with up to four answers: each answer is an output. Answers can have rules: only if, a cost, once, a chance.',
    outputs = { 'opt1', 'opt2', 'opt3', 'opt4', 'fail1', 'fail2', 'fail3', 'fail4', 'left', 'timeout' },
    labels = { left = 'Walked away', timeout = 'No answer',
               fail1 = 'Answer 1 failed', fail2 = 'Answer 2 failed', fail3 = 'Answer 3 failed', fail4 = 'Answer 4 failed' },
    -- An answer with no text is not offered, so it is no outcome at all; nor is the failure of one
    -- with no chance; nor Walked away while it waits for them to come back, nor No answer with no time limit.
    pinWhen = ANSWER_PINS,
    -- (The editor shows the answers written, one at least, and Add an answer for the next; each answer's outcome is
    -- called by its words, a failed one red; the card is wide, its face who speaks and what they say.)
    repeats = { { keys = { 'opt%d', 'opt%dRule' }, from = 1, to = 4, min = 1, add = 'Add an answer' } },
    pinText = ANSWER_TEXT,
    bad = { 'fail1', 'fail2', 'fail3', 'fail4' },
    ui = { face = 'quote', wide = true },
    pinName = function(props, pin)
        if pin:match('^opt%d$') and type(props[pin]) == 'string' and props[pin] ~= '' then
            return ('the answer "%s"'):format(props[pin])
        end
        local i = pin:match('^fail(%d)$')
        if i and type(props['opt' .. i]) == 'string' then return ('the answer "%s" failing'):format(props['opt' .. i]) end
        if pin == 'left' then return 'Walked away' end
    end,
    latent = true, talks = true,
    -- `group`: the editor's head over that field and the ones after it.
    props = {
        { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who speaks', required = true, group = 'Speaker' },
        DirectorNodes.nameShownField(),
        DirectorNodes.speakerField(),
        { key = 'line', kind = 'text', label = 'What they say', required = true, maxLength = 440 },
        -- (ui answer: its number, then its box: panels.js answerField.)
        { key = 'opt1', kind = 'text', label = 'Answer 1', required = true, maxLength = 60, group = 'Answers', ui = 'answer' }, ruleProp(1),
        { key = 'opt2', kind = 'text', label = 'Answer 2', maxLength = 60, ui = 'answer' }, ruleProp(2),
        { key = 'opt3', kind = 'text', label = 'Answer 3', maxLength = 60, ui = 'answer' }, ruleProp(3),
        { key = 'opt4', kind = 'text', label = 'Answer 4', maxLength = 60, ui = 'answer' }, ruleProp(4),
        { key = 'talk', kind = 'text', label = 'Talk prompt', default = 'Talk', maxLength = 40, group = 'While it waits' },
        -- Walking off (to fetch what was asked for) does not end it by default: their Talk is offered again, and the
        -- scenario's own time limit ends a run nobody comes back to.
        { key = 'away', kind = 'select', label = 'If the player walks away', options = { 'wait', 'out' }, default = 'wait',
          optionLabels = { wait = 'Wait for the player to come back', out = 'Go on from Walked away' } },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 5, max = 3600 },
        -- Its own objective while it waits ("Talk to Lester"), so a goal and its talk are one card (nodes_goals.lua
        -- talkGoal): on the run's screens, with Gives up after as its clock, and a mark on the map that follows them.
        { key = 'goal', kind = 'text', label = 'Objective (on screen; empty: none)', maxLength = 120, group = 'As a goal' },
        { key = 'goalMark', kind = 'bool', label = 'Mark the NPC on the map', default = true },
    },
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local npcW = node.props.npc
        local h = Director.handleOf(run, npcW)
        if type(h) ~= 'table' or not h.netId then
            ctx:log('%s is not in the world: nobody to speak', tostring(npcW))
            return 'left'
        end
        local src = Director.playerOf(ctx)
        -- (Nobody in the run yet: switched on, When it's switched on. Its Talk is anyone's, and the first to press it
        -- joins and is spoken to: main.lua Director.waitForAnyone.)
        if not src then return Director.waitForAnyone(ctx, npcW, h, ctx:prop('talk'), 'left') end

        -- What is said is worked out when it is said: now, and again if a Talk point is pressed later
        -- (which can be minutes on). The answers' rules are asked once more when one is chosen
        -- (canChoose): they may have given the keycard away since it was offered.
        local endsBy = {}
        local canChoose
        local function build()
            local layer = layerFor(run, node, src)
            layer.line = ctx:prop('line') or layer.line   -- the line itself may read a variable
            local nextLayers = {}
            endsBy = {}
            for _, o in ipairs(layer.options) do
                endsBy[o.id] = o.ends
                -- Sent ahead: the Dialog Line an answer carries on to (one with no chance: known now).
                local t = chanceOf(ruleOf(node, o.id)) == nil and DirectorTalk.continuesTo(run.graph, node, o.id) or nil
                if t and t.type == 'dialog.line' then
                    local l = layerFor(run, t, src)
                    if #l.options > 0 then nextLayers[o.id] = l end
                end
            end
            return { speaker = DirectorNodes.shownName(ctx, npcW), line = layer.line, options = layer.options,
                     next = next(nextLayers) and nextLayers or nil, canChoose = canChoose,
                     -- The grid; more than four answers would stack.
                     layout = #layer.options > 4 and 'stack' or 'grid' }
        end
        canChoose = function(s, pin)
            if s ~= src or offered(run, node, pin, s) then return true end
            -- No longer theirs to choose: the line again, with what they may.
            local fresh = build()
            if #fresh.options > 0 then DirectorTalk.converse(ctx, src, nil, fresh) end
            return false, 'You cannot choose that now'
        end
        local spec = build()
        local waitsAway = DirectorNodes.walkAway(node.props) == 'wait'
        if #spec.options == 0 then
            -- Every answer's rules said no (they lack the item, it was once): nothing to say to them. Waiting for them
            -- (the item left in the car), their Talk stays, and says so until they have it; else Walked away.
            ctx:log('no answer can be offered to %s: every one\'s rules say no', tostring(src))
            if not waitsAway then
                DirectorTalk.leave(ctx, src, 'left')
                return 'left'
            end
            -- (Closed: it goes on from nowhere yet, so nothing it leads to may keep it open.)
            DirectorTalk.leave(ctx, src, nil)
            NotifyPlayer(src, 'You have nothing to say to them yet: come back when you do', 'info')
        end

        -- The answer, leaving, or nobody answering: the first wins.
        ctx:on('conversation.choice', function(p)
            if p.runId == run.id and p.nodeId == node.id and p.source == src then
                local pin = p.option
                local r = ruleOf(node, pin)
                if r and r.offer == 'once a run' then
                    local s = ctx:state()
                    s.chosen = s.chosen or {}
                    s.chosen[src] = s.chosen[src] or {}
                    s.chosen[src][pin] = true
                elseif r and r.offer == 'once ever' then
                    local ok, why = Director.setFlag(run, src, onceFlag(run, node, pin), true, true)
                    if not ok then ctx:log('could not note "%s" as chosen: %s', pin, tostring(why)) end
                end
                if run.test and r and costText(r) then NotifyPlayer(src, ('Test: this answer would cost %s'):format(costText(r)), 'info') end
                -- A chance, rolled here: a miss goes out of the answer's "failed" outcome.
                local out = pin
                local chance = chanceOf(r)
                local i = pin:match('^opt(%d)$')
                if chance and i and math.random(100) > chance then out = 'fail' .. i end
                Director.event(run, node.id, out == pin and 'chose' or 'chose (it failed)', p.source, text(node, pin))
                return out, { source = p.source, convId = p.convId }
            end
        end)
        -- Walked off without answering: Walked away when set so; else their Talk is back on the NPC, and the card
        -- waits for them (the line is said again when they press it).
        local function offer()
            DirectorTalk.speak(ctx, src, npcW, h, build, ctx:prop('talk'), true)
        end
        ctx:on('conversation.ended', function(p)
            if p.runId == run.id and p.nodeId == node.id and p.source == src and p.why ~= 'chose' then
                if not waitsAway then return 'left', { source = p.source } end
                if ctx:isPlayer(src) then
                    Director.event(run, node.id, 'walked away (it waits)', src)
                    offer()
                end
                return nil
            end
        end)
        -- No time limit: it waits (the scenario's own limit still ends the run).
        local seconds = tonumber(ctx:prop('seconds'))
        DirectorTalk.noAnswerAfter(ctx, h, seconds)
        -- As a goal: its objective while it waits, its clock that time limit, the map's mark on them.
        local objective = ctx:prop('goal')
        if type(objective) == 'string' and objective ~= '' then
            DirectorNodes.talkGoal(ctx, npcW, objective, seconds, ctx:prop('goalMark') ~= false)
        end

        local first = spec
        DirectorTalk.speak(ctx, src, npcW, h, function()
            local s = first or build()
            first = nil
            return s
        end, ctx:prop('talk'))
        -- An answer that did not end the conversation itself (one with a chance): what it led to says
        -- whether it carries on.
        ctx:onEnd(function(pin, why)
            if why ~= 'answered' or not pin then return end
            local i = pin:match('^opt(%d)$') or pin:match('^fail(%d)$')
            if i and endsBy['opt' .. i] == false then DirectorTalk.leave(ctx, src, pin) end
        end)
        return nil
    end,
})

-- (NPC /me lives in nodes_npcs.lua.)

-- ============================================
-- NPCs
-- ============================================

--- What a run made for a placed thing, ADDED TO: a second Spawn NPC for the same thing (reinforcements) joins the first wave's group, so All Killed waits for both waves.
--- The handle's npcId/netId (who a Dialog Line speaks for) stay the first's.
local function addToHandle(ctx, worldId, ids, firstId, firstNet)
    local h = ctx:handle(worldId)
    if type(h) == 'table' and type(h.group) == 'table' then
        for _, id in ipairs(ids) do h.group[#h.group + 1] = id end
        return
    end
    local group = {}
    for _, id in ipairs(ids) do group[#group + 1] = id end
    ctx:remember(worldId, { npcId = firstId, netId = firstNet, group = group })
end

--- How long a run's NPC bodies stay: until the run ends, when its tag takes them
--- with the rest of the run. 0 is the NPC Creator's "until removed". A run that is always on never
--- ends, so its bodies keep the NPC Creator's own time (nil) rather than piling up for good.
local function bodyMs(ctx)
    if ctx.run.always then return nil end
    return 0
end

--- An NPC that fights "the run's players" fights the crew as it is: one put in later is a target, one
--- taken out no longer (the Director API's crew; main.lua Director.followCrew). `hostile` false: it
--- stops following (calmed down). `outsiders`: it fights everyone BUT the crew (NPC Attacks' players not in
--- the run), so one put in later is no longer a target. `because`: the card that made it fight (Npcs.explain).
local function followsCrew(run, ids, hostile, outsiders, because)
    for _, id in ipairs(ids) do
        Director.followCrew(run, 'npc:' .. tostring(id), hostile and function(players)
            return (Npcs.setState(CORE, id, { hostileTo = outsiders and { except = players } or { people = players } }, because))
        end or nil)
    end
end

--- A 'worlds' field's things (a list of placed things' ids), each once.
local function worldsList(list)
    local out, seen = {}, {}
    for _, v in ipairs(type(list) == 'table' and list or {}) do
        if type(v) == 'string' and v ~= '' and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
    return out
end

--- The NPCs a Spawn NPC card makes, each a placed NPC of its own.
local function spawnList(props) return worldsList(props.npcs) end

local MAX_SPAWN = 24

define({
    type = 'npc.spawn', v = 1, category = 'world', title = 'Spawn NPC',
    desc = 'Makes NPCs from the World tab where they were placed, and starts their tasks. Working together, they defend each other.',
    outputs = { 'out', 'failed' },
    heavy = true,
    -- What it makes, and that it starts their tasks itself (Check, Start Tasks: nodes.lua `makes`).
    makes = function(props) return DirectorKit.idSet(spawnList(props)) end,
    startsTasks = function(props) return props.tasks ~= false end,
    props = {
        { key = 'npcs', kind = 'worlds', worldKind = 'npc', label = 'NPCs', max = MAX_SPAWN },
        { key = 'together', kind = 'bool', label = 'They work together', default = true,
          hint = 'One hurt, the others fight back too; NPC Attacks, NPC Hurt and All Killed take them all' },
        { key = 'hostile', kind = 'bool', label = 'Fights the scenario\'s players', default = false },
        { key = 'range', kind = 'number', label = 'Goes for players within (metres of its spot; empty: anywhere)', min = 1, max = 500 },
        { key = 'tasks', kind = 'bool', label = 'Start their tasks', default = true,
          hint = 'Each with a list on its page (Tasks) starts it as it is made: no Start Tasks card needed' },
    },
    check = function(props)
        local n = #spawnList(props)
        if n == 0 then return 'Pick its NPC (or NPCs)' end
        if n > MAX_SPAWN then return ('%d NPCs at most on one card'):format(MAX_SPAWN) end
        return nil
    end,
    run = function(ctx)
        local list = spawnList(ctx.node.props)
        if #list == 0 then
            ctx:log('it has no NPC to make')
            return 'failed'
        end
        local together = ctx:prop('together') ~= false and #list > 1
        local opts = { tag = ctx:tag(), range = tonumber(ctx:prop('range')), corpseMs = bodyMs(ctx),
                       bucket = ctx.run.bucket }   -- an isolated tester's world (main.lua startRun)
        -- Working together: one group (they defend each other: server/npcs.lua), and every one's crew the card's whole set.
        if together then opts.group = ctx:tag() .. ':card:' .. tostring(ctx.node.id) end
        if ctx:prop('hostile') then
            opts.hostileTo = { people = ctx:players() }
            opts.because = 'Spawn NPC: fights the run\'s players'
        end
        -- Their crew: every one the card makes (one alone too: a wave for an NPC already in a crew joins it).
        local made, crew = 0, ctx:prop('together') ~= false and {} or nil
        -- Reinforcements (a placed NPC this run made before in a crew of its own): that crew is this one's too, so All
        -- Killed, NPC Hurt and NPC Attacks take every wave. Its members first; every handle that held it holds this.
        local merged = {}
        if crew then
            for _, wid in ipairs(list) do
                local h = ctx:handle(wid)
                local old = type(h) == 'table' and type(h.crew) == 'table' and h.crew or nil
                if old and not merged[old] then
                    merged[old] = true
                    for _, id in ipairs(old) do crew[#crew + 1] = id end
                end
            end
            for _, h in pairs(ctx.run.world) do
                if type(h) == 'table' and merged[h.crew] then h.crew = crew end
            end
        end
        for _, wid in ipairs(list) do
            local w = ctx:place(wid)
            local def = DirectorRoutes.npcDef(type(w) == 'table' and w.def or {})
            def.coords = vec(def.coords) and { x = def.coords.x, y = def.coords.y, z = def.coords.z, heading = def.coords.heading } or nil
            local npcId, netId = Npcs.spawn(CORE, def, opts)
            if not npcId then
                ctx:log('%s could not be made: %s', tostring(wid), tostring(netId))
            else
                made = made + 1
                addToHandle(ctx, wid, { npcId }, npcId, netId)
                if crew then
                    crew[#crew + 1] = npcId
                    ctx:handle(wid).crew = crew   -- (one table for all of them: each sees the others as they come)
                end
                if opts.hostileTo then followsCrew(ctx.run, { npcId }, true, false, opts.because) end
                DirectorGuards.arm(ctx, wid, { npcId })
                if ctx:prop('tasks') ~= false then DirectorTasks.startFor(ctx, wid) end
            end
        end
        if made == 0 then return 'failed' end
        return 'out'
    end,
})

--- The NPCs a card made for a placed thing: every one of a group, or the one (the standing one's
--- included: reading them is fine).
local function npcsOf(ctx, worldId) return DirectorNodes.npcIds(Director.handleOf(ctx.run, worldId)) end

--- Only those THIS run made: a card that changes an NPC must never change the
--- scenario's standing one, which every run shares and no run's end puts back.
local function runNpcsOf(ctx, worldId) return DirectorNodes.npcIds(ctx:handle(worldId)) end

--- Its crew (a fresh list): the others a Spawn NPC card made to work together, with every NPC made for the thing
--- itself (a later wave that does not work together reinforces it too).
local function withCrew(h, own)
    if not (type(h) == 'table' and type(h.crew) == 'table') then return own end
    local out, seen = {}, {}
    for _, list in ipairs({ h.crew, own }) do
        for _, id in ipairs(list) do
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    return out
end

--- A card that names one NPC of a Spawn NPC card whose NPCs work together takes them all (its crew: npc.spawn);
--- else as npcsOf. NPC Killed is the one alone, not this.
local function crewOf(ctx, worldId)
    return withCrew(Director.handleOf(ctx.run, worldId), npcsOf(ctx, worldId))
end

--- As crewOf, of those this run made (as runNpcsOf).
local function runCrewOf(ctx, worldId)
    return withCrew(ctx:handle(worldId), runNpcsOf(ctx, worldId))
end

--- Check: a card that changes an NPC is given a standing one (picked one by one: a group's standing ones are passed
--- over, as the card only changes what a run made).
local function notStanding(v, doc)
    local named = {}
    for _, x in ipairs(type(v) == 'table' and v or { v }) do
        if not DirectorNodes.groupName(x) then named[x] = true end
    end
    for _, w in ipairs(type(doc) == 'table' and doc.world or {}) do
        if named[w.id] and w.layer == 'standing' then
            return ('"%s" is Always present (shared by everyone): this card changes only NPCs the scenario makes (Spawn NPC)')
                :format(tostring(w.label or w.id))
        end
    end
    return nil
end

-- Who or what NPC Attacks sends it at. Players not in the run: round its spot only (OUTSIDERS_RANGE when the card
-- says no range), never the whole server. A director entity: anything placed on the World tab but a route, attacked
-- while nobody fights it: an NPC it fights, anything else it shoots at.
local ATTACKS = { 'the run\'s players', 'players not in the run', 'a director entity' }
local OUTSIDERS_RANGE = 60

--- Check: the director entity it attacks is picked, is one place (a route is many), and is not the NPC itself.
local function attackCheck(props, doc)
    if props.hostile == false or props.target ~= ATTACKS[3] then return nil end
    if props.thing == nil or props.thing == '' then return 'Pick the director entity it attacks' end
    for _, id in ipairs(DirectorNodes.expandThings(type(doc) == 'table' and doc.world or {}, props.npc, 'npc')) do
        if props.thing == id then return 'An NPC cannot attack itself: pick another director entity' end
    end
    for _, w in ipairs(type(doc) == 'table' and doc.world or {}) do
        if w.id == props.thing and w.kind == 'route' then
            return ('"%s" is a route: it has no one place to attack'):format(tostring(w.label or w.id))
        end
    end
    return nil
end

--- Its fields, then how it fights while Attacks is on: the task system's Shoot At's own (DirectorSteps.SHOOTING), a
--- copy of each.
local function withShooting(props)
    for _, f in ipairs(DirectorSteps.SHOOTING) do
        local c = {}
        for k, v in pairs(f) do c[k] = v end
        c.when = { key = 'hostile', is = true }
        props[#props + 1] = c
    end
    return props
end

--- What the director entity it attacks is now: an NPC (the first of its group still alive) or the run's car by its
--- netId, else where the thing stands (a prop is each game's own copy; a spot, an item spot, a container, a door is a
--- place). nil when there is none yet.
local function attackOf(ctx, wid)
    local w = ctx:place(wid)
    if type(w) ~= 'table' then return nil end
    if w.kind == 'npc' then
        for _, id in ipairs(npcsOf(ctx, wid)) do
            local info = Npcs.get(id)
            if info and info.alive and info.netId then return { net = info.netId } end
        end
        return nil
    end
    local h = Director.handleOf(ctx.run, wid)
    if w.kind == 'vehicle' then
        local ent = type(h) == 'table' and h.vehicleId and Vehicles.getEntity(h.vehicleId)
        return ent and { net = NetworkGetNetworkIdFromEntity(ent) } or nil
    end
    local c = type(w.def) == 'table' and vec(w.def.coords)
    return c and { at = { x = c.x, y = c.y, z = c.z + 0.5 } } or nil
end

define({
    type = 'npc.hostile', v = 3, category = 'world', title = 'NPC Attacks',
    desc = 'Makes the NPCs (or groups) picked attack the scenario\'s players, other players, or anything placed in the World tab. Set Attacks to No to calm them.',
    outputs = { 'out' },
    -- Version 2: "a car or a prop" became "a director entity" (any placed thing). Version 3: one NPC became NPCs and groups.
    upgrade = function(props, fromV)
        if fromV < 2 and props.target == 'a car or a prop' then props.target = ATTACKS[3] end
        if fromV < 3 then DirectorNodes.toList(props, 'npc') end
        return props
    end,
    check = attackCheck,
    props = withShooting({
        DirectorNodes.thingsField('npc', 'npc', 'NPCs (ones this scenario made)', { check = notStanding }),
        { key = 'hostile', kind = 'bool', label = 'Attacks', default = true, hint = 'No: it calms down' },
        { key = 'target', kind = 'select', label = 'Who or what', options = ATTACKS, default = ATTACKS[1],
          optionLabels = { [ATTACKS[1]] = 'the scenario\'s players', [ATTACKS[2]] = 'players not in the scenario' } },
        { key = 'thing', kind = 'world', label = 'The director entity', when = { key = 'target', is = ATTACKS[3] },
          hint = 'Anything placed but a route. An NPC it fights; anything else it shoots at with its weapon (its page), or walks up to with none' },
        { key = 'range', kind = 'number', label = 'Goes for players within (metres of its spot; empty: as it was)', min = 1, max = 500,
          hint = 'Players not in the scenario: within 60 when empty' },
    }),
    run = function(ctx)
        -- (Each of them and the others its Spawn NPC card made to work together, once.)
        local ids, seen = {}, {}
        for _, wid in ipairs(DirectorNodes.things(ctx, 'npc')) do
            for _, id in ipairs(runCrewOf(ctx, wid)) do
                if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
            end
        end
        if #ids == 0 then ctx:log('%s: this run made none of them', table.concat(DirectorNodes.things(ctx, 'npc'), ', ')) end
        local what = ctx:prop('target') or ATTACKS[1]
        local range = tonumber(ctx:prop('range'))
        local patch
        if not ctx:prop('hostile') then
            patch = { hostileTo = false, attack = false }
        elseif what == ATTACKS[3] then
            local a = attackOf(ctx, ctx.node.props.thing)
            if not a then
                ctx:log('%s is not in the world (a car or an NPC: spawn it first; an NPC: one still alive)', tostring(ctx.node.props.thing))
                return 'out'
            end
            -- What it attacks, and no player: one who hits it is fought back as ever (its fightBack).
            patch = { hostileTo = false, attack = a }
        elseif what == ATTACKS[2] then
            patch = { hostileTo = { except = ctx:players() }, attack = false, range = range or OUTSIDERS_RANGE }
        else
            patch = { hostileTo = { people = ctx:players() }, attack = false }
        end
        if range and not patch.range then patch.range = range end
        -- How it fights, the whole fight long (client/npcs.lua shooting); calmed down, as whip's NPCs fight.
        patch.style = ctx:prop('hostile') and { accuracy = ctx:prop('accuracy'), rate = ctx:prop('rate'),
                                                pattern = ctx:prop('pattern'), skill = ctx:prop('skill') } or false
        local because = ('%s: %s'):format(ctx.node.def.title, what)
        for _, id in ipairs(ids) do
            local ok, why = Npcs.setState(CORE, id, patch, because)
            if not ok then ctx:log('NPC %s: %s', tostring(id), tostring(why)) end
        end
        followsCrew(ctx.run, ids, patch.hostileTo ~= false, what == ATTACKS[2], because)
        -- Calmed: a guard among them fights again when it next spots one of the players.
        if not ctx:prop('hostile') then DirectorGuards.calmed(ctx.run, ids) end
        return 'out'
    end,
})

--- The NPCs this run made for the placed things (and groups) card field `key` names, each once: as npcsOf, or with
--- `crew` as crewOf (the others a Spawn NPC card made to work together).
local function npcsOfAll(ctx, key, crew)
    local out, seen = {}, {}
    for _, wid in ipairs(DirectorNodes.things(ctx, key)) do
        for _, id in ipairs(crew and crewOf(ctx, wid) or npcsOf(ctx, wid)) do
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    return out
end

define({
    type = 'npc.killed', v = 2, category = 'events', title = 'NPC Killed',
    desc = 'When one of the NPCs (or groups) picked dies.',
    outputs = { 'out' },
    -- Version 2: one NPC became NPCs and groups.
    upgrade = function(props) return DirectorNodes.toList(props, 'npc') end,
    props = { DirectorNodes.thingsField('npc', 'npc', 'NPCs (or groups)') },
    event = {
        name = 'npc.killed', once = true,
        -- The server's record of the kill (Npcs), not the event's word alone.
        filter = function(ctx, p)
            if type(p) ~= 'table' then return nil end
            local mine = false
            for _, id in ipairs(npcsOfAll(ctx, 'npc')) do if id == p.npcId then mine = true end end
            if not mine then return nil end
            local info = Npcs.get(p.npcId)
            if info and info.alive then return nil end
            -- npcId: which of them it was, so a Give Car Key after it drops the key where they fell.
            return 'out', { source = info and info.killer or p.killer, npcId = p.npcId }
        end,
    },
})

define({
    type = 'npc.allKilled', v = 2, category = 'events', title = 'All Killed',
    desc = 'When all NPCs or group selected in this card have been killed.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'npc') end,
    props = { DirectorNodes.thingsField('npc', 'npc', 'NPCs (or groups)') },
    event = {
        -- 'npc.down': killed, or gone without dying (lost, removed): the last one leaving counts too.
        name = 'npc.down', once = true,
        filter = function(ctx, p)
            if type(p) ~= 'table' then return nil end
            local ids = npcsOfAll(ctx, 'npc', true)
            local mine = false
            for _, id in ipairs(ids) do if id == p.npcId then mine = true end end
            if not mine then return nil end
            for _, id in ipairs(ids) do
                local info = Npcs.get(id)
                if info and info.alive then return nil end   -- gone (despawned) counts as down
            end
            local info = Npcs.get(p.npcId)
            return 'out', { source = info and info.killer or p.killer, npcId = p.npcId }
        end,
    },
})

define({
    type = 'npc.damaged', v = 2, category = 'events', title = 'NPC Hurt',
    desc = 'When an NPC receives damage from a player.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'npc') end,
    props = {
        DirectorNodes.thingsField('npc', 'npc', 'NPCs (or groups)'),
        -- Health and armour lost to players, added up for each NPC of it: one that has lost this much sets it off.
        { key = 'damage', kind = 'number', label = 'After this much damage', min = 1, max = 2000,
          hint = 'Health and armour together (a ped has about 200; a pistol hit takes about 25). Empty: the first hit.' },
    },
    -- A test rewound: the hits after that step are forgotten (the filter below keeps each with its step).
    rewind = function(s, seq)
        for id, hits in pairs(s.hurt or {}) do
            local kept = {}
            for _, hit in ipairs(hits) do if hit.at <= seq then kept[#kept + 1] = hit end end
            s.hurt[id] = kept
        end
    end,
    event = {
        name = 'npc.damaged', once = true,
        filter = function(ctx, p)
            if type(p) ~= 'table' or not p.attacker then return nil end
            for _, id in ipairs(npcsOfAll(ctx, 'npc', true)) do
                if id == p.npcId then
                    local need = tonumber(ctx:prop('damage'))
                    if not need or need <= 1 then return 'out', { source = p.attacker } end
                    -- Each hit with the step it came at (its own memory: a test rewound to before a hit forgets it).
                    local st = ctx:state()
                    st.hurt = st.hurt or {}
                    local hits = st.hurt[id] or {}
                    st.hurt[id] = hits
                    hits[#hits + 1] = { n = math.max(0, tonumber(p.amount) or 0), at = ctx.run.trace.n }
                    local total = 0
                    for _, hit in ipairs(hits) do total = total + hit.n end
                    if total >= need then return 'out', { source = p.attacker } end
                    return nil
                end
            end
            return nil
        end,
    },
})

-- ============================================
-- Items
-- ============================================

--- The stacks a player carries that this run placed for this world thing (its mark: DirectorEffects.isRunItem).
local function stamped(run, worldId, src, item)
    local out = {}
    for _, f in ipairs(Inventory.findAll(src, item) or {}) do
        local md = f.metadata
        if DirectorEffects.isRunItem(run, md) and md.dworld == worldId then out[#out + 1] = f end
    end
    return out
end

define({
    type = 'item.place', v = 2, category = 'world', title = 'Place Item', giveUp = 15,
    desc = 'Puts the items on the ground at their spots from the World tab.',
    outputs = { 'placed', 'failed', 'timeout' },
    latent = true, yields = true, heavy = true,
    upgrade = function(props) return DirectorNodes.toList(props, 'item') end,
    props = { DirectorNodes.thingsField('item', 'groundItem', 'Items (placed spots)') },
    run = function(ctx)
        local run = ctx.run
        -- Each spot with an item and a place (one without is said and passed over). Failed: none could be placed.
        local spots = {}
        for _, worldId in ipairs(DirectorNodes.things(ctx, 'item')) do
            local w = ctx:place(worldId)
            local def = type(w) == 'table' and w.def or {}
            local at = vec(def.coords)
            if not at or type(def.item) ~= 'string' then
                ctx:log('%s has no item or no spot', tostring(worldId))
            else
                spots[#spots + 1] = { id = worldId, def = def, at = at }
            end
        end
        if #spots == 0 then return 'failed' end
        local placed = {}
        ctx:call(function()
            for _, s in ipairs(spots) do
                -- Marked as the run's (a test's stamp, a live run's plain tag): Item Picked Up and Take Item find it by it.
                -- The run's own pile: its end clears it.
                local g, err = DirectorEffects.placePile(ctx, {
                    item = s.def.item, amount = tonumber(s.def.amount) or 1, coords = s.at, heading = tonumber(s.def.coords.heading),
                    metadata = { [DirectorEffects.ownField(run)] = run.id, dworld = s.id }, reason = Director.reason(run),
                })
                if not g then
                    ctx:log('could not place %s: %s', s.def.item, tostring(err))
                else
                    placed[#placed + 1] = g.id
                    ctx:remember(s.id, { groundId = g.id })
                end
            end
            return #placed > 0 and 'placed' or 'failed'
        end, {
            -- Placed after the card gave up: take them back.
            late = function() for _, id in ipairs(placed) do GroundItems.deleteItem(id) end end,
        })        return nil
    end,
})

define({
    type = 'item.picked', v = 2, category = 'events', title = 'Item Picked Up',
    desc = 'When a player in the scenario picks up an item placed in this scenario.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'item') end,
    props = { DirectorNodes.thingsField('item', 'groundItem', 'Items (placed spots)') },
    event = {
        name = 'item.added', once = true,
        -- Checked in their pockets: the run's own stamp on the stack, not the event's word alone. Any of the spots.
        filter = function(ctx, p)
            if type(p) ~= 'table' or not ctx:isPlayer(p.source) then return nil end
            for _, worldId in ipairs(DirectorNodes.things(ctx, 'item')) do
                local w = ctx:place(worldId)
                local key = type(w) == 'table' and type(w.def) == 'table' and w.def.item or nil
                if key and p.item == key and #stamped(ctx.run, worldId, p.source, key) > 0 then
                    Director.event(ctx.run, ctx.node.id, 'picked up', p.source, key)
                    return 'out', { source = p.source }
                end
            end
            return nil
        end,
    },
})

define({
    type = 'item.take', v = 2, category = 'player', title = 'Take Item', giveUp = 15,
    desc = 'Takes the items this scenario placed back off the player. Taken: they had at least one of them.',
    outputs = { 'taken', 'missing', 'timeout' },
    latent = true, yields = true,
    upgrade = function(props) return DirectorNodes.toList(props, 'item') end,
    props = { DirectorNodes.thingsField('item', 'groundItem', 'Items (the ones this scenario placed)') },
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'missing' end
        local spots = {}
        for _, worldId in ipairs(DirectorNodes.things(ctx, 'item')) do
            local w = ctx:place(worldId)
            local key = type(w) == 'table' and type(w.def) == 'table' and w.def.item or nil
            if key then spots[#spots + 1] = { id = worldId, key = key } end
        end
        if #spots == 0 then return 'missing' end
        local data = { source = src }
        ctx:call(function()
            local any = false
            for _, s in ipairs(spots) do
                -- What this spot's pile was (stamped), all of it, through the pockets' own take (refused while a bank
                -- payment holds them: Inventory.pocketsFrozen). One refused is missing, and said.
                local n = 0
                for _, f in ipairs(stamped(run, s.id, src, s.key)) do n = n + f.amount end
                if n > 0 then
                    local only = Inventory.onlyStamped({ [DirectorEffects.ownField(run)] = run.id, dworld = s.id })
                    local ok, why = Inventory.take(src, s.key, n, Director.reason(run) .. ' (handed over)', only)
                    if ok then
                        any = true
                        Director.event(run, ctx.node.id, 'handed over', src, ('%s x%d'):format(s.key, n))
                    else
                        ctx:log('could not take %s from %s: %s', s.key, tostring(src), tostring(why))
                    end
                end
            end
            return any and 'taken' or 'missing', data
        end)        return nil
    end,
})

-- ============================================
-- Cars ("steal the car")
-- ============================================
--
-- A run's car is a temporary car (SpawnTempVehicle) under the run's tag, so it goes when the run
-- ends. Made `secure` (its page's Only its key opens it, off unless set), it cannot be lockpicked or hotwired: the
-- way in is its key, which is the player's from the start, in the ignition, or nobody's until a Give Car Key card
-- gives it (to a player, or on the ground: a guard dropping it where they fell). Its model, plate, lock and spot are the
-- World tab's; there are no standing cars (Check says so).

-- ITS KEY is the car's own setting (its page: Key settings, w.def.key = { exists, where, spot }): none, given to the
-- player, in the ignition, in the glovebox or the boot, or on the ground at a key spot of its own (a ground item
-- thing, def.keyOf = the car).
-- (`card`: Given by a card. Spawn Car makes the car without it; Give Car Key gives it, below.)
local KEY_WHERE = { world = true, ignition = true, glovebox = true, trunk = true, player = true, card = true }

local function keyOf(def)
    if type(def.key) ~= 'table' then return nil end
    return (def.key.exists == true and KEY_WHERE[def.key.where]) and def.key or nil
end

--- The car this run made for a placed thing: its vehicleId, while whip still has it.
local runCar = DirectorNodes.runCarId

--- Where a placed thing is NOW, for a card that puts something there (an NPC where it stands or fell, the guard who
--- just died: the trigger's): nodes.lua.
local whereNow = DirectorNodes.whereNow


--- GTA's own street life: a car or a passer-by the game made by itself (population types 1-5), never one a script
--- made (this scenario's, another job's, another resource's: "mission", 7).
local function streetLife(ent)
    local t = GetEntityPopulationType(ent)
    return t ~= nil and t >= 1 and t <= 5
end

--- Take away what stands where a run's car is about to be made and is nobody's: a street car within the spot's
--- radius (one whip never took in, no player in it) with whoever rides in it, and a passer-by within 2.5 m. What a
--- script made stays (this scenario's NPCs and cars, another job's, a player's own car), and so do players.
---@return number gone
local function clearSpot(at, bucket)
    local radius = Config.GarageSpotRadius or 3.5
    local gone = 0
    for _, veh in ipairs(GetAllVehicles() --[[@as integer[] ]]) do   -- the server native: a list
        if DoesEntityExist(veh) and GetEntityRoutingBucket(veh) == bucket and streetLife(veh)
           and not Vehicles.getEntityVehicleId(veh) and #(GetEntityCoords(veh) - at) < radius then
            local riders, player = {}, false
            for seat = -1, 14 do
                local p = GetPedInVehicleSeat(veh, seat)
                if p and p ~= 0 then
                    if IsPedAPlayer(p) then player = true break end
                    riders[#riders + 1] = p
                end
            end
            if not player then
                for _, p in ipairs(riders) do if streetLife(p) then DeleteEntity(p) end end
                DeleteEntity(veh)
                gone = gone + 1
            end
        end
    end
    for _, ped in ipairs(GetAllPeds()) do
        if DoesEntityExist(ped) and not IsPedAPlayer(ped) and GetEntityRoutingBucket(ped) == bucket and streetLife(ped)
           and #(GetEntityCoords(ped) - at) < 2.5 then
            DeleteEntity(ped)
            gone = gone + 1
        end
    end
    return gone
end

--- The cars a Spawn Car card makes, each a placed car of its own.
local function carList(props) return worldsList(props.cars) end

local MAX_CARS = 12
local CAR_MS = 15000       -- one car's time to be made (and its key put where it goes)
local NEXT_CAR_MS = 5000   -- each car after the first

--- One of a Spawn Car card's cars made where it was placed, its key where its Key settings say, its trailer with it
--- (its page's Tows), its tasks started. In the card's call (it waits). Its id, or nil (said in the run's log). `made`:
--- the card's list of what it made so far; `byW`: [world id] = what this card made for it (a trailer made with its truck
--- is not made twice, nor said to be "made already", when it is on the card's list too); `asTrailer`: made as one.
local function spawnOne(ctx, worldId, made, byW, asTrailer)
    byW = byW or {}
    if byW[worldId] then return byW[worldId] end
    local w = ctx:place(worldId)
    local def = type(w) == 'table' and type(w.def) == 'table' and w.def or {}
    local model = DirectorGraph.carModel(def)   -- (a random vehicle's: one of its models)
    local at = DirectorNodes.carAt(def, model)
    if not at or type(model) ~= 'string' or model == '' then
        ctx:log('%s has no model or no spot', tostring(worldId))
        return nil
    end
    if runCar(ctx, worldId) then
        ctx:log('%s: this run already made it', tostring(worldId))
        return nil
    end
    local key = keyOf(def)
    local where = key and key.where or nil
    local src = where == 'player' and Director.playerOf(ctx) or nil
    if where == 'player' and not src then
        ctx:log('%s: its key is for the player who set the card off, and no player did', tostring(worldId))
        return nil
    end
    -- On the ground: at its key spot, which must be placed.
    local spotAt, spotDef
    if key and where == 'world' then
        local s = type(key.spot) == 'string' and ctx:place(key.spot) or nil
        spotDef = type(s) == 'table' and type(s.def) == 'table' and s.def or {}
        spotAt = vec(spotDef.coords)
        if not spotAt then
            ctx:log('%s: its key spot is not placed', tostring(worldId))
            return nil
        end
    end
    -- With its key inside it (the ignition, the glovebox, the boot) it stands unlocked, unless its page locks it even
    -- then (lockedIn: a setting of its own).
    local inside = where == 'ignition' or where == 'glovebox' or where == 'trunk'
    local opts = {
        plate = type(def.plate) == 'string' and def.plate ~= '' and def.plate or nil,
        locked = (inside and def.lockedIn == true) or (not inside and def.locked ~= false),
        secure = def.secure == true,
        keyInIgnition = where == 'ignition' or nil,
        forSource = src,
        idleDespawn = false,   -- the run decides when it goes
        tag = ctx:tag(),
        bucket = ctx.run.bucket,   -- an isolated tester's world (main.lua startRun)
    }
    -- In its way: street life is taken away; what is still there (a player, a car someone owns, this scenario's own NPC
    -- or car) does not stop it: made there anyway. Only a car that cannot be made at all fails.
    local bucket = opts.bucket or 0
    local gone = clearSpot(at, bucket)
    if gone > 0 then
        ctx:log('%s: took %d street car(s) or passer(s)-by out of its way', tostring(worldId), gone)
        Wait(250)
        if not ctx:alive() then return nil end   -- (asked again after the wait)
    end
    local still = Vehicles.spotBlocked(at.x, at.y, at.z, { exceptSource = src, bucket = bucket })
    if still then
        ctx:log('%s: %s, made there anyway', tostring(worldId), still:lower())
        opts.force = true
    end
    local id, err = Vehicles.spawnTempFor(model, vector4(at.x, at.y, at.z, tonumber(def.coords.heading) or 0.0), opts, CORE)
    if not id then
        ctx:log('%s could not be made: %s', tostring(worldId), tostring(err))
        return nil
    end
    made[#made + 1] = id
    local ent = Vehicles.getEntity(id)
    ctx:remember(worldId, { vehicleId = id, netId = ent and NetworkGetNetworkIdFromEntity(ent) or nil })
    -- Its key on the ground at its spot, or in its glovebox or boot: whip's own key, marked as the run's (a key never
    -- stacks, so the mark costs nothing): a test's is taken back from whoever holds it, a live run's is theirs to keep.
    -- One still on the ground goes when the run ends.
    if key and (where == 'world' or where == 'glovebox' or where == 'trunk') then
        local run = ctx.run
        local md = Vehicles.keyMetadata(id, { [DirectorEffects.ownField(run)] = run.id, dworld = where == 'world' and key.spot or worldId })
        if run.test then DirectorEffects.handsOut(run, 'vehicle_key') end   -- (listed before it goes: effects.lua)
        local ok, why
        if where == 'world' then
            -- (The run's own pile: its end clears it.)
            local g, gerr = DirectorEffects.placePile(ctx, { item = 'vehicle_key', amount = 1, coords = spotAt,
                                                     heading = tonumber(spotDef.coords.heading), metadata = md, reason = Director.reason(run) })
            if g then
                ctx:remember(key.spot, { groundId = g.id })
                ok = true
            else
                why = gerr
            end
        else
            ok, why = Stores.giveAt({ kind = 'vehicle', id = id, sub = where }, 'vehicle_key', 1, md,
                                    { reason = Director.reason(run) })
        end
        if not ok then
            ctx:log('%s: its key could not be put there: %s', tostring(worldId), tostring(why))
            Vehicles.despawnByRef(id)
            made[#made] = nil
            return nil
        end
    end
    byW[worldId] = id
    -- Its trailer (its page's Tows): made too, where it is placed, unless the run has it; hitched by the game that owns
    -- this one (server/actors.lua setTow), so place it behind. (A trailer's own trailer is its own card's.)
    local towW = not asTrailer and type(def.tow) == 'string' and def.tow ~= '' and def.tow ~= worldId and def.tow or nil
    if towW then
        local tid = byW[towW] or runCar(ctx, towW) or spawnOne(ctx, towW, made, byW, true)
        local tent = tid and Vehicles.getEntity(tid)
        if tent and ent then
            local ok, twhy = Actors.setTow(CORE, ent, tent, { tag = ctx:tag() })
            if not ok then ctx:log('%s: its trailer %s: %s', tostring(worldId), towW, tostring(twhy)) end
        else
            ctx:log('%s: its trailer %s could not be made', tostring(worldId), towW)
        end
    end
    if ctx:prop('tasks') ~= false then DirectorTasks.startFor(ctx, worldId) end
    return id
end

define({
    type = 'vehicle.spawn', v = 1, category = 'world', title = 'Spawn Car',
    desc = 'Makes cars from the World tab where they were placed. They are the scenario\'s, and go when it ends.',
    outputs = { 'out', 'failed', 'timeout' },
    labels = { out = 'Made' },
    latent = true, yields = true, heavy = true,
    -- What it makes, and that it starts their tasks itself (Check, Start Tasks: nodes.lua `makes`).
    makes = function(props) return DirectorKit.idSet(carList(props)) end,
    startsTasks = function(props) return props.tasks ~= false end,
    props = {
        { key = 'cars', kind = 'worlds', worldKind = 'vehicle', label = 'Cars', max = MAX_CARS },
        -- (Its key is the car's own setting: its page, Key settings. keyOf above.)
        { key = 'tasks', kind = 'bool', label = 'Start their tasks', default = true, hint = 'Each with a list on its page (Tasks)' },
    },
    check = function(props)
        local n = #carList(props)
        if n == 0 then return 'Pick its car (or cars)' end
        if n > MAX_CARS then return ('%d cars at most on one card'):format(MAX_CARS) end
        return nil
    end,
    run = function(ctx)
        local list = carList(ctx.node.props)
        if #list == 0 then
            ctx:log('it has no car to make')
            return 'failed'
        end
        -- One after another, each in its own spot: Made once one is, Could not when not one could be.
        local made, byW = {}, {}
        ctx:call(function()
            local any = false
            for _, worldId in ipairs(list) do
                -- (Gave up, rewound, or the run ended meanwhile: no more cars, and no street cleared for one.)
                if not ctx:alive() then break end
                if spawnOne(ctx, worldId, made, byW) then any = true end
            end
            return any and 'out' or 'failed'
        end, {
            -- Made after the card gave up: take them away.
            late = function() for _, id in ipairs(made) do Vehicles.despawnByRef(id) end end,
        })
        ctx:after(CAR_MS + NEXT_CAR_MS * (#list - 1), 'timeout')
        return nil
    end,
})

-- Give Car Key (once Drop Key: the type, its outcomes and a card from before stay as they were, on the ground): the key
-- of the car the run made, for a car whose Key settings say Given by a card (Spawn Car makes it without its key), or
-- another key of one that has its own.
local GIVE_TO = { 'on the ground', 'the player who set it off', 'everyone in the run' }

define({
    type = 'vehicle.dropKey', v = 1, category = 'world', title = 'Give Car Key', giveUp = 15, handsOut = true,
    desc = 'Gives the scenario\'s car key to a player or everyone in the scenario, or drops it where an NPC fell or at a placed thing.',
    outputs = { 'placed', 'failed', 'timeout' },
    labels = { placed = 'Given', failed = 'Could not' },
    latent = true, yields = true, heavy = true,
    props = {
        { key = 'car', kind = 'world', worldKind = 'vehicle', label = 'Car', required = true },
        { key = 'to', kind = 'select', label = 'To', options = GIVE_TO, default = GIVE_TO[1],
          optionLabels = { [GIVE_TO[3]] = 'everyone in the scenario' } },
        { key = 'at', kind = 'world', label = 'Where, on the ground (an NPC, or any placed thing)' },
    },
    check = function(props)
        if (props.to == nil or props.to == GIVE_TO[1]) and (props.at == nil or props.at == '') then
            return 'Where, on the ground: pick an NPC or a placed thing'
        end
        return nil
    end,
    run = function(ctx)
        local run, carW = ctx.run, ctx.node.props.car
        local id = runCar(ctx, carW)
        if not id then
            ctx:log('%s: this run has made no such car (Spawn Car first)', tostring(carW))
            return 'failed'
        end
        -- The key whip's own keys are (Vehicles.keyMetadata), marked as the run's: in a test its end takes it back from
        -- whoever holds it (handedOut: DirectorEffects.takeBack); in a live run it is theirs to keep. One on the ground
        -- goes when the run ends.
        local function md() return Vehicles.keyMetadata(id, { [DirectorEffects.ownField(run)] = run.id, dworld = carW }) end
        local to = ctx:prop('to') or GIVE_TO[1]
        if to ~= GIVE_TO[1] then
            local list = {}
            if to == GIVE_TO[2] then
                local s = Director.playerOf(ctx)
                if s then list[1] = s end
            else
                list = ctx:players()
            end
            if #list == 0 then
                ctx:log('nobody to give the key to')
                return 'failed'
            end
            ctx:call(function()
                -- The run's way (effects.lua: a test's listed before the first goes, each given in its history).
                local gave = 0
                for _, s in ipairs(list) do
                    if run.status ~= 'running' then break end
                    if ctx:isPlayer(s) then
                        local n, why = DirectorEffects.give(run, ctx.node.id, s, 'vehicle_key', 1, { metadata = md() })
                        if n > 0 then gave = gave + 1 else ctx:log('could not give %s the key: %s', tostring(s), tostring(why)) end
                    end
                end
                return gave > 0 and 'placed' or 'failed'
            end)            return nil
        end
        local at = whereNow(ctx, ctx.node.props.at)
        if not at then
            ctx:log('%s has no spot to drop the key on', tostring(ctx.node.props.at))
            return 'failed'
        end
        local placed
        ctx:call(function()
            if run.test then DirectorEffects.handsOut(run, 'vehicle_key') end   -- (listed before it goes: effects.lua)
            -- (The run's own pile: its end clears it, a start of whip one it stopped under.)
            local g, err = DirectorEffects.placePile(ctx, { item = 'vehicle_key', amount = 1, coords = at, metadata = md(), reason = Director.reason(run) })
            if not g then
                ctx:log('could not drop the key: %s', tostring(err))
                return 'failed'
            end
            placed = g.id
            return 'placed'
        end, {
            late = function() if placed then GroundItems.deleteItem(placed) end end,
        })        return nil
    end,
})

define({
    type = 'vehicle.entered', v = 2, category = 'events', title = 'Car Entered',
    desc = 'When a player within the scenario has entered the selected vehicle(s).',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'car') end,
    props = {
        DirectorNodes.thingsField('car', 'vehicle', 'Cars'),
        { key = 'driver', kind = 'bool', label = 'Only the driver\'s seat', default = true },
    },
    event = {
        name = 'vehicle.entered', once = true,
        filter = function(ctx, p)
            if type(p) ~= 'table' or not ctx:isPlayer(p.source) then return nil end
            local mine = false
            for _, carW in ipairs(DirectorNodes.things(ctx, 'car')) do
                local id = runCar(ctx, carW)
                if id and p.vehicleId == id then mine = true break end
            end
            if not mine then return nil end
            if ctx:prop('driver') ~= false and p.seat ~= -1 then return nil end
            Director.event(ctx.run, ctx.node.id, 'got in', p.source, p.plate)
            return 'out', { source = p.source }
        end,
    },
})

define({
    type = 'vehicle.reached', v = 1, category = 'world', title = 'Car Delivered',
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'Waits until a player in the scenario drives the scenario\'s car to a placed thing (a drop-off spot). Car lost: it is gone, blown up or sunk.',
    outputs = { 'reached', 'lost', 'timeout' },
    labels = { lost = 'Car lost', timeout = 'Too late' },
    latent = true,
    pinWhen = DirectorFields.TIMES_OUT,   -- (with no time limit there is no Too late)
    props = {
        { key = 'car', kind = 'world', worldKind = 'vehicle', label = 'Car', required = true },
        { key = 'at', kind = 'world', label = 'Where (a placed thing)', required = true },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 8, min = 1, max = 100, bySpot = 'at' },
        { key = 'driven', kind = 'bool', label = 'Driven by a player in the scenario', default = true },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 10, max = 86400 },
    },
    run = function(ctx)
        local carW, atW = ctx.node.props.car, ctx.node.props.at
        local w = ctx:place(atW)
        local at = vec(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
        if not at then
            ctx:log('%s has no spot', tostring(atW))
            return 'lost'
        end
        local radius = tonumber(ctx:prop('radius')) or 8
        local driven = ctx:prop('driven') ~= false
        -- (A marker's shape only: its car is this card's.)
        local spot = DirectorSpots.watch(ctx, w)
        -- (Being claimed is not lost: Claim Car's record goes a moment before the owned one is out, and the run's
        -- handle follows it then, main.lua.)
        local look = DirectorNodes.carLook(ctx, carW)
        ctx:poll(1000, function()
            local ent, lost = look()
            if not ent then return lost and 'lost' or nil end
            local ok, src = DirectorSpots.delivered(ctx, spot, ent, at, radius, driven)
            if not ok then return nil end
            if not src then return 'reached' end
            Director.event(ctx.run, ctx.node.id, 'delivered', src)
            return 'reached', { source = src }
        end)
        local seconds = tonumber(ctx:prop('seconds'))
        if seconds then ctx:after(seconds * 1000, 'timeout') end
        return nil
    end,
})

-- ============================================
-- Drop Item: any item, anywhere
-- ============================================
--
-- Nothing drops unless a card says so: an NPC never leaves its gun (client/npcs.lua), and what a run
-- puts down is a whip ITEM like any other — a gunny pistol, whip_autos' nitro, whip_voice's radio —
-- with the item's own default data (its serial...: RegisterItemDefaultMeta), as AddItem gives it.
-- In a live run it is real: a pile outlives the run, still on the ground when it ends, an ordinary
-- item anyone can pick up (ground items never expire, so one nobody takes lies there). A test's is
-- stamped with the run and goes with it, on the ground or in a pocket: a test keeps nothing.

local MAX_PILES = 10   -- a thing that does not stack is one ground item each: this many at most

define({
    type = 'item.drop', v = 1, category = 'world', title = 'Drop Item', givesItems = true, giveUp = 15,
    desc = 'Puts any item on the ground: where an NPC is (after NPC Killed: where that one fell), or at any placed thing.',
    outputs = { 'placed', 'failed', 'timeout' },
    latent = true, yields = true, heavy = true,
    props = {
        { key = 'item', kind = 'item', label = 'Item', required = true },
        { key = 'amount', kind = 'number', label = 'How many', default = 1, min = 1, max = 100 },
        { key = 'at', kind = 'world', label = 'Where (an NPC, or any placed thing)', required = true },
    },
    run = function(ctx)
        local run, atW = ctx.run, ctx.node.props.at
        local item = ctx:prop('item')
        local def = type(item) == 'string' and type(Config) == 'table' and Config.Items and Config.Items[item] or nil
        if not def then
            ctx:log('%s is not an item on this server', tostring(item))
            return 'failed'
        end
        local at = whereNow(ctx, atW)
        if not at then
            ctx:log('%s has no spot to drop it on', tostring(atW))
            return 'failed'
        end
        local amount = math.max(1, math.min(100, math.floor(tonumber(ctx:prop('amount')) or 1)))
        local perPile = (def.stack and tonumber(def.maxStack)) and math.max(1, math.floor(def.maxStack)) or 1
        local piles, left = {}, amount
        while left > 0 and #piles < MAX_PILES do
            piles[#piles + 1] = math.min(left, perPile)
            left = left - piles[#piles]
        end
        if left > 0 then ctx:log('only %d of %d dropped: %s does not stack, and %d piles is the most', amount - left, amount, item, MAX_PILES) end
        local made = {}
        ctx:call(function()
            -- (The run's way: a test's listed before the first pile and each stamped as the run's; a live run's real,
            -- marked only for its own cards to find: effects.lua.)
            local stamp = DirectorEffects.stamper(run, item, { dworld = atW })
            for _, n in ipairs(piles) do
                -- The run ended meanwhile (its end has swept): no more piles.
                if run.status ~= 'running' then break end
                -- The item's own data, one a pile (a serial is per thing), then the run's stamp.
                local g, err = GroundItems.createItem({ item = item, amount = n, coords = at, metadata = stamp(DirectorEffects.fresh(item)),
                                                        reason = Director.reason(run) })
                if not g then
                    ctx:log('could not drop %s: %s', item, tostring(err))
                    if #made == 0 then return 'failed' end
                    break
                end
                made[#made + 1] = g.id
                -- A test's, still on the ground when it ends, is cleared with the run's own (its ledger). A live
                -- run's stays there for whoever picks it up.
                if run.test then DirectorEffects.ownGround(ctx, g.id) end
            end
            Director.event(run, ctx.node.id, 'dropped', nil, ('%s x%d'):format(item, amount - left))
            return 'placed'
        end, {
            -- Dropped after the card gave up: the run went another way, so they go.
            late = function() for _, gid in ipairs(made) do GroundItems.deleteItem(gid) end end,
        })        return nil
    end,
})

-- ============================================
-- The player
-- ============================================

define({
    type = 'player.pay', v = 1, category = 'player', title = 'Pay', giveUp = 15, handsOut = true,
    haggle = { key = 'amount', toPlayer = true, unit = 'money' },   -- (a Haggle can agree its amount: nodes_talk.lua)
    desc = 'Pays the player: cash into their pocket, or into their bank (How).',
    outputs = { 'paid', 'failed', 'timeout' },
    latent = true, yields = true,
    props = {
        { key = 'amount', kind = 'number', label = 'Amount ($)', default = 100, min = 0, max = 1000000 },
        { key = 'method', kind = 'select', label = 'How', options = { 'auto', 'cash', 'bank' }, default = 'auto' },
        { key = 'reason', kind = 'text', label = 'What it is for', maxLength = 120, default = 'Job done' },
    },
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'failed' end
        local amount = math.floor(tonumber(ctx:prop('amount')) or 0)
        local method, reason = ctx:prop('method'), ctx:prop('reason')
        local data = { source = src }
        ctx:call(function()
            -- (The run's way: a test pays nothing, it says what it would: effects.lua.)
            local ok, why = DirectorEffects.pay(run, ctx.node.id, src, amount, { method = method, reason = reason })
            if not ok then
                ctx:log('pay %s $%d: %s', tostring(src), amount, tostring(why))
                return 'failed', data
            end
            return 'paid', data
        end, { late = DirectorEffects.latePay(run, ctx.node.id, src, amount, 'Pay') })        return nil
    end,
})

--- Who a player card is for (its `who`, a `players` field: server/director/fields.lua).
local function audienceOf(ctx) return DirectorFields.playersOf(ctx, ctx:prop('who')) end

define({
    type = 'player.objective', v = 1, category = 'player', title = 'Show Objective',
    ui = { page = 'objectivePreview' },   -- (its page shows the objective as it looks)
    desc = 'Shows what to do next, on screen until it is cleared.',
    outputs = { 'out' },
    props = {
        { key = 'text', kind = 'text', label = 'Objective', required = true, maxLength = 200 },
        { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' },
        -- The line under it: the scenario's name, none, or words of its own (Subtext text, shown for those only:
        -- html/js/director/panels.js).
        { key = 'subShown', kind = 'select', label = 'Subtext', options = { 'name', 'none', 'other' },
          optionLabels = { name = 'The scenario\'s name', none = 'None', other = 'My own words' }, default = 'name' },
        { key = 'sub', kind = 'text', label = 'Subtext words', maxLength = 60, when = { key = 'subShown', is = 'other' } },
        -- The card's disc: one of whip's glyphs (html/js/glyphs.js), the flag when none is picked.
        { key = 'icon', kind = 'glyph', label = 'Icon', default = 'objective' },
    },
    run = function(ctx)
        -- On the run's band (server/director/band.lua), so a Countdown running beside it stays.
        local run, msg = ctx.run, ctx:prop('text')
        local icon = ctx:prop('icon')
        icon = type(icon) == 'string' and icon ~= '' and icon or nil
        -- Its subtext: nil the scenario's name, false none, else its own words (none when none are typed).
        local sub, mode = nil, ctx:prop('subShown')
        if mode == 'none' then
            sub = false
        elseif mode == 'other' then
            local words = ctx:prop('sub')
            words = type(words) == 'string' and words:match('^%s*(.-)%s*$') or ''
            sub = words ~= '' and words or false
        end
        local list = audienceOf(ctx)
        for _, s in ipairs(list) do DirectorBand.objective(run, s, msg, 'objective', icon, sub) end
        -- Everyone's objective is the crew's as it is: one a script puts in sees it too, until Clear
        -- Objective (for everyone) takes it down.
        if ctx:prop('who') ~= 'this player' then
            local has = {}
            for _, s in ipairs(list) do has[s] = true end
            Director.followCrew(run, 'objective', function(players)
                local now = {}
                for _, s in ipairs(players) do
                    now[s] = true
                    if not has[s] then DirectorBand.objective(run, s, msg, 'objective', icon, sub) end
                end
                has = now   -- one taken out lost their band: back in, they are given it again
            end)
        end
        return 'out'
    end,
})

define({
    type = 'player.clearObjective', v = 1, category = 'player', title = 'Clear Objective',
    desc = 'Takes down the objective Show Objective put up (a Goal\'s own, and a Countdown, stay while they run).',
    outputs = { 'out' },
    props = { { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' } },
    run = function(ctx)
        for _, s in ipairs(audienceOf(ctx)) do DirectorBand.clearObjective(ctx.run, s, 'objective') end
        if ctx:prop('who') ~= 'this player' then Director.followCrew(ctx.run, 'objective', nil) end
        return 'out'
    end,
})

define({
    type = 'player.message', v = 1, category = 'player', title = 'Message',
    desc = 'A notification in the corner of the screen.',
    outputs = { 'out' },
    props = {
        { key = 'text', kind = 'text', label = 'Message', required = true, maxLength = 200 },
        { key = 'kind', kind = 'select', label = 'Style', options = { 'info', 'success', 'warning', 'error' }, default = 'info' },
        { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' },
    },
    run = function(ctx)
        local msg, kind = ctx:prop('text'), ctx:prop('kind')
        for _, s in ipairs(audienceOf(ctx)) do NotifyPlayer(s, msg, kind) end
        return 'out'
    end,
})

-- ============================================
-- The map: blips and the waypoint (server/blips.lua)
-- ============================================
--
-- A blip marks a placed thing's spot (World tab) for the run's players, by CHARACTER, so somebody who
-- logs out and back in as someone else does not see it. It is the run's: it goes when the run ends.
-- Only GTA's blip colours whose numbers are certain are offered.

local COLORS = { yellow = 5, red = 1, green = 2, blue = 3, white = 0 }
local COLOR_NAMES = { 'yellow', 'red', 'green', 'blue', 'white' }

local charsOf = DirectorNodes.peopleOf

local function blipId(ctx, worldId) return ctx:tag() .. ':blip:' .. tostring(worldId) end

define({
    type = 'map.blip', v = 2, category = 'player', title = 'Show Blip',
    desc = 'Marks the placed things (or groups) picked on the map (and the GPS route) for the scenario\'s players, until removed or the scenario ends.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'at') end,
    props = {
        DirectorNodes.thingsField('at', nil, 'Where (placed things or groups)'),
        { key = 'label', kind = 'text', label = 'Name on the map', maxLength = 40 },
        { key = 'color', kind = 'select', label = 'Colour', options = COLOR_NAMES, default = 'yellow' },
        { key = 'route', kind = 'bool', label = 'GPS route to it', default = true },
        { key = 'radius', kind = 'number', label = 'As an area (metres; empty: a point)', min = 1, max = 5000 },
        { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' },
    },
    run = function(ctx)
        local people = charsOf(audienceOf(ctx))
        -- A blip on each of them, each with its own name unless the card gives one.
        for _, at in ipairs(DirectorNodes.things(ctx, 'at')) do
            local w = ctx:place(at)
            local c = type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil
            local spec = { coords = vec(c), label = ctx:prop('label') or (type(w) == 'table' and w.label) or nil,
                           color = COLORS[ctx:prop('color') or 'yellow'] or 5, route = ctx:prop('route') == true,
                           radius = tonumber(ctx:prop('radius')), tag = ctx:tag() }
            if not spec.coords then
                ctx:log('%s has no spot for a blip', tostring(at))
            else
                local id = blipId(ctx, at)
                local ok, why = Blips.show(CORE, { people = people }, id, spec)
                if not ok then ctx:log('blip on %s: %s', tostring(at), tostring(why)) end
                -- Kept, so a player leaving the run is taken off it (main.lua's leave). `all`: for everyone in
                -- the run, so one put in later gets it too (one player's mark stays theirs).
                if ok and ctx.run.blips then
                    ctx.run.blips[id] = { spec = spec, people = people, all = ctx:prop('who') == 'everyone in the run' }
                end
            end
        end
        return 'out'
    end,
})

define({
    type = 'map.blipRemove', v = 2, category = 'player', title = 'Remove Blip',
    desc = 'Takes the blips a Show Blip card put on the placed things (or groups) picked off the map.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'at') end,
    props = { DirectorNodes.thingsField('at', nil, 'Which (their placed things or groups)') },
    run = function(ctx)
        for _, at in ipairs(DirectorNodes.things(ctx, 'at')) do
            local id = blipId(ctx, at)
            Blips.remove(CORE, id)
            if ctx.run.blips then ctx.run.blips[id] = nil end
        end
        return 'out'
    end,
})

define({
    type = 'map.waypoint', v = 1, category = 'player', title = 'Set Waypoint',
    desc = 'Sets GTA\'s own waypoint (the one a player can set on the map) on a placed thing.',
    outputs = { 'out' },
    props = {
        { key = 'at', kind = 'world', label = 'Where (a placed thing)', required = true },
        { key = 'who', kind = 'players', label = 'For', default = 'everyone in the run' },
    },
    run = function(ctx)
        local w = ctx:place(ctx.node.props.at)
        local c = type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil
        if not vec(c) then return 'out' end
        for _, s in ipairs(audienceOf(ctx)) do Blips.waypoint(s, c) end
        return 'out'
    end,
})
