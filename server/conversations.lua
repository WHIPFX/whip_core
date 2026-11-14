-- ============================================
-- Conversations — an NPC talks, a player answers (server)
-- ============================================
--
-- A conversation is between ONE player and ONE speaker (an NPC Creator NPC, or any networked
-- entity), shown in the dialog capsule that orbits the speaker (client/conversations.lua): the
-- speaker's line and up to four answers, chosen with the scroll wheel and E. Named "conversation"
-- because "dialog" already means Input/Confirm in whip; a conversation is not a UI and holds no
-- NUI focus.
--
--   * It opens only from an interaction: `fromUse` is the useId a runtime point's
--     onUse was handed (AddPoint, server/runtime_points.lua), by this player, in the last few
--     seconds, on this speaker when the point rides one.
--   * The server holds what it offered: an answer is accepted only if it is one of the options on
--     screen now, from the player it was offered to, near the speaker. Text is cleaned with the /me
--     rule (BubbleText.clean).
--   * No wait when it can be helped: a layer may carry `next`, the reply to each answer, so the
--     player's game shows it at once on E; the server moves to it when the answer arrives, then
--     tells the owner (onChoose), who may change it (UpdateConversation) or end it.
--   * IT ENDS when the owner ends it, an answer that `ends` is chosen, the player walks away or a
--     screen takes their prompts, goes down, logs out or leaves, the speaker dies, goes or turns on
--     them, an answer is left unanswered for 15 s, the owner's run tag is released, or the owner
--     stops. onEnd(source, why) says which.
--
--   exports.whip_core:StartConversation(source, {
--       fromUse = use.useId, npcId = npcId,          -- or netId = n
--       speaker = 'Fence', line = 'Got the goods?',
--       options = { { id = 'yes', label = 'Here.' }, { id = 'bye', label = 'Leave', ends = true } },
--       next    = { yes = { line = 'Let me see.', options = { { id = 'ok', label = 'OK' } } } },
--       onChoose = function(source, optionId, convId, amount) end,
--       onEnd    = function(source, why) end,
--       tag = 'run:42',
--   })
--
-- Two kinds of answer ask more of the player:
--   * `input = { min, max, prefix }`: a TYPED AMOUNT. Choosing it turns the answer into a field (the
--     interaction system's typing: digits, E to give it, Backspace on an empty field to step back);
--     onChoose is handed the whole number typed, checked here against min and max. A haggle.
--   * `cost = { amount, currency, method, reason }`: the answer COSTS something, taken here when it
--     is chosen and before onChoose hears of it (Money.charge: dollars, cash or bank as `method`
--     says; or `currency` = an item key for that many of an item, taken stack by stack and given
--     back exactly). One they cannot pay is refused with the reason, and the same answers stay on
--     screen. Their game is not sent what follows a costed or typed answer ahead: it waits.
--
-- `canChoose(source, optionId, convId) -> false, why` (optional, on the spec or an update) is asked
-- before an answer is taken or paid: what it needs can change after it was offered.
--
-- A team page (the Director's Pick Team, "Who are you doing this with?"): a line
-- with `team = { max, slots = { { name, state = 'you'|'in'|'waiting' } } }` is drawn as the capsule's
-- team page, its slots above the answers (free ones to `max`), and may have up to TEAM_OPTIONS answers,
-- scrolled four at a time. Its owner changes it as people come and go; those watching are not shown
-- each pick, nor the same line again.
--
-- A haggle (the Director's Haggle): a line with `haggle = { lo, hi, asks, ... }` (readHaggle) is drawn with a
-- ruler between the line and the answers: the prices asked so far, how close each came, where the other side's
-- limit can still be. Its answer that takes an amount moves along the ruler (client/conversations.lua).

Conversations = {}

local MAX_OPTIONS = 4
local TEAM_OPTIONS = 12   -- a team page's list: who is near, by character ID, Let's go
local TEAM_STATES = { you = true, ['in'] = true, waiting = true }
local LINE_MAX    = 440   -- (a Dialog Line's; the capsule makes a long one smaller to fit: dialog.html fitLines)
local LABEL_MAX   = 60
local NAME_MAX    = 40
local START_MS    = 10000    -- how old the press that opens it may be
local ANSWER_MS   = 15000    -- an answer with nothing sent ahead waits this long for the owner
local TICK_MS     = 1000

local convs    = {}   -- [convId] = record
local bySource = {}   -- [source] = convId
local talkers  = {}   -- [speaker netId] = { [source] = convId }: who each speaker is talking to now
local nextId   = 0

local CFG = Config.Conversations or {}

local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

local function clean(text, max)
    local t = BubbleText.clean(text, max)
    return t
end

-- ============================================
-- What is said
-- ============================================

local INPUT_MAX = 999999999   -- nine digits: the most the typing field takes

--- An answer's typed amount: { min, max, prefix }, or nil and why.
local function readInput(raw, id)
    if type(raw) ~= 'table' or callable(raw) then return nil, ('answer "%s": input is { min, max, prefix }'):format(id) end
    local min = raw.min == nil and 0 or Sanitize.id(raw.min, 0, INPUT_MAX)
    local max = raw.max == nil and INPUT_MAX or Sanitize.id(raw.max, 0, INPUT_MAX)
    if not min or not max or max < min then
        return nil, ('answer "%s": input min and max are whole numbers from 0 to %d, min no more than max'):format(id, INPUT_MAX)
    end
    if raw.prefix ~= nil and (type(raw.prefix) ~= 'string' or #raw.prefix > 8) then
        return nil, ('answer "%s": input prefix is text of at most 8 characters ("$")'):format(id)
    end
    return { min = min, max = max, prefix = raw.prefix or '' }
end

--- An answer's cost: { amount, currency, method, reason }, or nil and why.
local function readCost(raw, id)
    if type(raw) ~= 'table' or callable(raw) then return nil, ('answer "%s": cost is { amount, currency, method }'):format(id) end
    local amount = Sanitize.id(raw.amount, 1)
    if not amount then return nil, ('answer "%s": cost amount is a whole number of 1 or more'):format(id) end
    local currency = raw.currency or 'cash'
    if type(currency) ~= 'string' or not (Config.Items and Config.Items[currency]) then
        return nil, ('answer "%s": cost currency "%s" is not an item'):format(id, tostring(currency))
    end
    local method = raw.method or 'auto'
    if method ~= 'auto' and method ~= 'cash' and method ~= 'bank' then
        return nil, ('answer "%s": cost method is auto, cash or bank'):format(id)
    end
    if currency ~= 'cash' then method = 'cash' end   -- an item is paid from the pockets
    if raw.reason ~= nil and type(raw.reason) ~= 'string' then return nil, ('answer "%s": cost reason is text'):format(id) end
    return { amount = amount, currency = currency, method = method, reason = raw.reason and raw.reason:sub(1, 120) or nil }
end

--- A team page's slots: { max, slots = { { name, state } } }, or nil and why.
local function readTeam(raw)
    if type(raw) ~= 'table' or callable(raw) then return nil, 'team is { max, slots }' end
    local max = Sanitize.id(raw.max, 1, 16)
    if not max then return nil, 'team.max is how many in all: a whole number from 1 to 16' end
    if type(raw.slots) ~= 'table' or callable(raw.slots) or #raw.slots > max then
        return nil, 'team.slots is a list of { name, state }, no longer than max'
    end
    local slots = {}
    for i, s in ipairs(raw.slots) do
        if type(s) ~= 'table' or callable(s) or not TEAM_STATES[s.state] then
            return nil, ("team slot %d is { name, state = 'you', 'in' or 'waiting' }"):format(i)
        end
        slots[i] = { name = clean(type(s.name) == 'string' and s.name or '', NAME_MAX), state = s.state }
    end
    return { max = max, slots = slots }
end

--- A haggle's ruler (the Director's Haggle: hot and cold), drawn over its answers: { buys, lo, hi, unit = 'money' |
--- 'count', asks = { { p = price, r = 'yes' | 'no' | 'insult', h = 0..1 how close a yes came } }, best, a, b (where
--- their limit can still be), left (asks left), pat, patMax (patience) }, or nil and why. Numbers only: the player's
--- game draws it.
local HAGGLE_SAYS = { yes = true, no = true, insult = true }
local function readHaggle(raw)
    if type(raw) ~= 'table' or callable(raw) then return nil, 'haggle is { lo, hi, asks, ... }' end
    local function num(v)
        v = tonumber(v)
        return v and v == v and v ~= math.huge and v ~= -math.huge and v or nil
    end
    local function int(v, lo, hi)
        v = num(v)
        return v and math.max(lo, math.min(hi, math.floor(v))) or lo
    end
    local lo, hi = num(raw.lo), num(raw.hi)
    if not lo or not hi or hi <= lo then return nil, 'haggle.lo and haggle.hi are the ruler\'s ends, lo below hi' end
    local asks = {}
    if type(raw.asks) == 'table' and not callable(raw.asks) then
        for _, a in ipairs(raw.asks) do
            if #asks >= 8 then break end
            if type(a) == 'table' and num(a.p) and HAGGLE_SAYS[a.r] then
                asks[#asks + 1] = { p = num(a.p), r = a.r, h = math.max(0, math.min(1, num(a.h) or 0)) }
            end
        end
    end
    return { buys = raw.buys == true, lo = lo, hi = hi, unit = raw.unit == 'count' and 'count' or 'money', asks = asks,
             best = num(raw.best), a = num(raw.a), b = num(raw.b), left = int(raw.left, 0, 8), pat = int(raw.pat, 0, 8),
             patMax = int(raw.patMax, 0, 8) }
end

--- A layer: { line, options = { { id, label, ends, input?, cost? } }, next = { [optionId] = layer },
--- team?, haggle? }. `next` goes one deep (the reply to each answer); a reply's own replies come with the
--- owner's update.
local function readLayer(raw, deep)
    if type(raw) ~= 'table' or callable(raw) then return false, 'a line is { line, options }' end
    if type(raw.line) ~= 'string' then return false, 'line is text: what the speaker says' end
    local line = clean(raw.line, LINE_MAX)
    if line == '' then return false, 'line is empty' end
    if type(raw.options) ~= 'table' or callable(raw.options) or #raw.options == 0 then
        return false, 'options is a list of { id, label }: at least one answer'
    end
    local team = nil
    if raw.team ~= nil then
        local t, twhy = readTeam(raw.team)
        if not t then return false, twhy end
        team = t
    end
    local haggle = nil
    if raw.haggle ~= nil then
        if team then return false, 'a line is a team page or a haggle, not both' end
        local hg, hwhy = readHaggle(raw.haggle)
        if not hg then return false, hwhy end
        haggle = hg
    end
    local most = team and TEAM_OPTIONS or MAX_OPTIONS
    if #raw.options > most then return false, ('at most %d answers'):format(most) end
    local options, seen = {}, {}
    for i, o in ipairs(raw.options) do
        if type(o) ~= 'table' or callable(o) then return false, ('answer %d is { id, label }'):format(i) end
        local id = type(o.id) == 'number' and tostring(o.id) or o.id
        if type(id) ~= 'string' or #id > 40 or not id:match('^[%w_%-]+$') then
            return false, ('answer %d needs an id: letters, digits, _ and - (at most 40)'):format(i)
        end
        if seen[id] then return false, ('two answers have the id "%s"'):format(id) end
        seen[id] = true
        if type(o.label) ~= 'string' or clean(o.label, LABEL_MAX) == '' then
            return false, ('answer "%s" needs a label'):format(id)
        end
        local opt = { id = id, label = clean(o.label, LABEL_MAX), ends = o.ends == true }
        if o.input ~= nil then
            local input, iwhy = readInput(o.input, id)
            if not input then return false, iwhy end
            opt.input = input
        end
        if o.cost ~= nil then
            if opt.input then return false, ('answer "%s": a typed amount has no fixed cost'):format(id) end
            local cost, cwhy = readCost(o.cost, id)
            if not cost then return false, cwhy end
            opt.cost = cost
        end
        options[i] = opt
    end
    local out = { line = line, options = options, team = team, haggle = haggle }
    if raw.next ~= nil and deep then
        if type(raw.next) ~= 'table' or callable(raw.next) then return false, 'next is { [answerId] = { line, options } }' end
        out.next = {}
        for id, n in pairs(raw.next) do
            if not seen[id] then return false, ('next.%s: there is no answer "%s"'):format(tostring(id), tostring(id)) end
            local l, why = readLayer(n, false)
            if not l then return false, ('next.%s: %s'):format(id, why) end
            out.next[id] = l
        end
    end
    return out
end

--- The answers as the player's game gets them: no costs (the server's business), and a costed answer
--- never ends the conversation over there — it waits for the payment, and the server ends it or not.
local function wireOptions(list)
    local out = {}
    for i, o in ipairs(list) do
        out[i] = { id = o.id, label = o.label, ends = o.ends and not o.cost, input = o.input }
    end
    return out
end

local function wireLayer(l)
    local out = { line = l.line, options = wireOptions(l.options), team = l.team, haggle = l.haggle }
    if l.next then
        out.next = {}
        local held = {}
        for _, o in ipairs(l.options) do if o.cost or o.input then held[o.id] = true end end
        for id, n in pairs(l.next) do
            -- What follows a payment is not shown before it is paid, nor what follows a typed amount
            -- before it is checked: the server sends either once the answer counts.
            if not held[id] then out.next[id] = { line = n.line, options = wireOptions(n.options), team = n.team, haggle = n.haggle } end
        end
    end
    return out
end

local function sendView(rec)
    local v = wireLayer(rec.layer)
    v.netId, v.speaker, v.layout = rec.netId, rec.speaker, rec.layer.team and 'team' or rec.layer.haggle and 'haggle' or rec.layout
    TriggerClientEvent('whip_core:client:conversation', rec.source, rec.convId, v)
end

-- ============================================
-- Who is talking, and those watching
-- ============================================
--
-- While a speaker is talking to someone, its Talk points say so to everyone else (server/
-- runtime_points.lua, "A Talk that cannot be talked to"): every start and end here tells them.
--
-- Those standing nearby see it as /me bubbles (server/bubbles.lua): the speaker's line above the
-- speaker, then the answer chosen above the player who chose it, then the reply above the speaker
-- again, a moment after the answer. Not for the player talking: they have the capsule. Bubbles last
-- as a /me does (5 seconds). Config.Conversations.watcherBubbles = false turns it off.

local REPLY_MS = 900    -- a reply shows this long after the answer it is to, for those watching
local SAME_MS  = 5000   -- the same line again within this is said once (sent ahead, then confirmed)

--- The players a speaker is talking to now, { [source] = convId } (nil: nobody). Read only.
function Conversations.talkers(netId) return talkers[netId] end

local function talking(rec, on)
    local t = talkers[rec.netId]
    if on then
        if not t then t = {}; talkers[rec.netId] = t end
        t[rec.source] = rec.convId
    elseif t and t[rec.source] == rec.convId then
        t[rec.source] = nil
        if next(t) == nil then talkers[rec.netId] = nil end
    end
    if RuntimePoints and RuntimePoints.entityTalking then RuntimePoints.entityTalking(rec.netId) end
end

-- A conversation that ended as it was meant to (an answer that ends it, the owner finishing it)
-- still shows its last reply. One cut short (they walked off, were downed) does not.
local SAY_AFTER_END = { chose = true, ended = true }

--- The speaker says `line`, for those watching: once (a reply sent ahead and then confirmed by the
--- owner's update is the same line), after the answer it follows, and in the order said.
local function sayToWatchers(rec, line)
    if CFG.watcherBubbles == false or not Bubbles or type(line) ~= 'string' or line == '' then return end
    local now = GetGameTimer()
    if rec.said and rec.said.line == line and now - rec.said.at < SAME_MS then return end
    rec.said = { line = line, at = now }
    local job = { prev = rec.reply }
    function job.emit()
        if job.done then return end
        job.done = true
        if job.prev then job.prev.emit() end   -- one said before it goes first
        job.prev = nil
        if rec.reply == job then rec.reply = nil end
        if rec.gone and not SAY_AFTER_END[rec.endWhy] then return end
        Bubbles.show({ netId = rec.netId }, line, { except = rec.source, lines = CFG.npcLines or 4 })
    end
    local wait = (rec.answeredAt or -REPLY_MS) + REPLY_MS - now
    if wait > 0 then
        rec.reply = job
        SetTimeout(wait, job.emit)
    else
        job.emit()
    end
end

--- The player said `label` (the answer they chose), for those watching.
local function answerToWatchers(rec, label)
    if CFG.watcherBubbles == false or not Bubbles then return end
    -- A reply still waiting is to the answer before this one: it shows now, so the two come in order.
    if rec.reply then rec.reply.emit() end
    rec.answeredAt = GetGameTimer()
    Bubbles.show({ source = rec.source }, label, { except = rec.source })
end

-- ============================================
-- Ending
-- ============================================

local function retire(rec, why)
    if rec.gone then return end
    rec.gone = true
    convs[rec.convId] = nil
    if bySource[rec.source] == rec.convId then bySource[rec.source] = nil end
    talking(rec, false)
    TriggerClientEvent('whip_core:client:conversation', rec.source, rec.convId, false)
    local onEnd, owner, source, reason = rec.onEnd, rec.owner, rec.source, rec.endWhy or why
    if onEnd ~= nil then
        -- In its own thread: a registry removal must not wait, and the owner's code may.
        CreateThread(function()
            local ok, err = Actions.call(owner, onEnd, source, reason)
            if not ok then print(('[whip_core:conversations] %s\'s onEnd threw: %s'):format(tostring(owner), tostring(err))) end
        end)
    end
end

local reg = Registry.new('conversation', {
    label = 'conversation',
    scoped = true,
    releaseOrder = 10,   -- with the points: before the NPCs it is with
    same = false,
    onRemove = function(_, rec, _, why) retire(rec, why) end,
})

--- End a conversation for this reason (the registry entry goes; onEnd hears `why`). While an answer is
--- being paid for, it ends once the payment is in (the choice handler), so what was paid counts and
--- nothing needs giving back. The owner's end and a run's (the registry) do not wait.
local function endWith(rec, why)
    if rec.gone then return end
    if rec.paying then
        rec.endAfterPay = rec.endAfterPay or why
        return
    end
    rec.endWhy = rec.endWhy or why
    reg:remove(rec.owner, rec.convId)
end

-- ============================================
-- The speaker
-- ============================================

--- The speaker's entity and netId, or nil and why. An NPC Creator NPC must be alive.
local function speakerOf(rec)
    if rec.npcId then
        local info = Npcs.get(rec.npcId)
        if not info then return nil, 'gone' end
        if not info.alive then return nil, 'killed' end
    end
    local ent = NetworkGetEntityFromNetworkId(rec.netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil, 'gone' end
    return ent
end

--- Metres from the speaker: further, and it is over. The client's own range (Config.Conversations)
--- ends it first; this is the server's word, with slack for a moving NPC and the ping. Read at each
--- check, so a change in /whip → Settings reaches it.
local function near(source, ent)
    local c = GetEntityCoords(ent)
    return IsPlayerNear(source, c.x, c.y, c.z, ((Config.Conversations or {}).range or 6.0) + 2.0)
end

-- ============================================
-- Starting, changing, ending
-- ============================================

--- Open a conversation. Answers the convId, or false and why. Never waits.
---@param owner string   Registry.caller(), read before anything else
---@param source number
---@param spec table
function Conversations.start(owner, source, spec)
    if type(spec) ~= 'table' or callable(spec) then return false, 'a conversation is a table: { fromUse, npcId, line, options }' end
    local src = Sanitize.id(source)
    local player = src and Players[src]
    if not src or not player or not player.charId then return false, 'no such player' end
    if player.isDead then return false, 'they are down' end

    local useId = Sanitize.id(spec.fromUse)
    local use = useId and RuntimePoints.recentUse(src, useId, START_MS)
    if not use then return false, 'not from an interaction: open it from a point\'s onUse, with fromUse = use.useId' end

    local npcId, netId = nil, nil
    if spec.npcId ~= nil then
        npcId = Sanitize.id(spec.npcId)
        local info = npcId and Npcs.get(npcId)
        if not info then return false, 'no such NPC' end
        if not info.alive then return false, 'that NPC is dead' end
        netId = info.netId
    elseif spec.netId ~= nil then
        netId = Sanitize.id(spec.netId, 1, 65535)
        if not netId then return false, 'netId is a network id' end
    else
        return false, 'a conversation needs its speaker: npcId or netId'
    end
    if use.netId and use.netId ~= netId then return false, 'not the one they spoke to' end

    local layer, why = readLayer(spec, true)
    if not layer then return false, why end
    if spec.speaker ~= nil and type(spec.speaker) ~= 'string' then return false, 'speaker is text: a name' end
    if spec.layout ~= nil and spec.layout ~= 'grid' and spec.layout ~= 'stack' then return false, "layout is 'grid' or 'stack'" end
    if spec.onChoose ~= nil and not callable(spec.onChoose) then return false, 'onChoose is a function(source, optionId, convId)' end
    if spec.onEnd ~= nil and not callable(spec.onEnd) then return false, 'onEnd is a function(source, why)' end
    if spec.canChoose ~= nil and not callable(spec.canChoose) then
        return false, 'canChoose is a function(source, optionId, convId) -> false, why to refuse'
    end

    -- Before anything is registered: a start that is refused never had an end to tell anyone about.
    local ent = speakerOf({ npcId = npcId, netId = netId })
    if not ent then return false, 'the speaker is not there' end
    if not near(src, ent) then return false, 'they are too far from the speaker' end

    nextId = nextId + 1
    local id = nextId
    local rec = {
        convId = id, owner = owner, tag = spec.tag, source = src, npcId = npcId, netId = netId,
        speaker = clean(spec.speaker or '', NAME_MAX), layout = spec.layout or 'grid', layer = layer,
        onChoose = spec.onChoose, onEnd = spec.onEnd, canChoose = spec.canChoose,
    }
    local ok, err = reg:add(owner, id, rec, spec.tag ~= nil and { tag = spec.tag } or nil)
    if not ok then return false, err end

    -- One at a time: a new one replaces theirs.
    local old = bySource[src] and convs[bySource[src]]
    if old then endWith(old, 'replaced') end

    convs[id] = rec
    bySource[src] = id
    sendView(rec)
    talking(rec, true)
    sayToWatchers(rec, rec.layer.line)
    return id
end

--- Change what is said: patch = { line, options, next, speaker } (line and options together).
---@return boolean ok
---@return string|nil why
function Conversations.update(owner, convId, patch)
    local id = Sanitize.id(convId)
    local rec = id and convs[id]
    if not rec or rec.owner ~= owner then return false, 'no such conversation of yours' end
    if type(patch) ~= 'table' or callable(patch) then return false, 'a change is { line, options, next }' end
    local layer, why = readLayer(patch, true)
    if not layer then return false, why end
    if patch.speaker ~= nil then
        if type(patch.speaker) ~= 'string' then return false, 'speaker is text: a name' end
        rec.speaker = clean(patch.speaker, NAME_MAX)
    end
    -- canChoose: replaced with the new answers (false takes it off).
    if patch.canChoose ~= nil then
        if patch.canChoose == false then rec.canChoose = nil
        elseif callable(patch.canChoose) then rec.canChoose = patch.canChoose
        else return false, 'canChoose is a function(source, optionId, convId), or false' end
    end
    -- A team page changing as people come and go says nothing new: its line is said once.
    local again = layer.team ~= nil and rec.layer.team ~= nil and rec.layer.line == layer.line
    rec.layer, rec.pending = layer, nil
    sendView(rec)
    if not again then sayToWatchers(rec, layer.line) end
    return true
end

---@return boolean ok
---@return string|nil why
function Conversations.finish(owner, convId)
    local id = Sanitize.id(convId)
    local rec = id and convs[id]
    if not id or not rec or rec.owner ~= owner then return false, 'no such conversation of yours' end
    rec.endWhy = rec.endWhy or 'ended'
    return reg:remove(owner, id)
end

--- A copy, for whoever asks: who, with whom, and what is on screen now.
function Conversations.get(convId)
    local id = Sanitize.id(convId)
    local rec = id and convs[id]
    if not rec then return nil end
    local opts = {}
    for _, o in ipairs(rec.layer.options) do opts[#opts + 1] = { id = o.id, label = o.label, ends = o.ends } end
    return { convId = rec.convId, owner = rec.owner, tag = rec.tag, source = rec.source, npcId = rec.npcId,
             netId = rec.netId, speaker = rec.speaker, line = rec.layer.line, options = opts,
             waiting = rec.pending ~= nil }
end

-- ============================================
-- From the player's game
-- ============================================

--- A typed amount as the answer takes it: a whole number from its min to its max, or nil.
local function typedAmount(input, value)
    if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
    if value < input.min or value > input.max then return nil end
    return math.tointeger(value)
end

-- ---- what an answer costs ----
--
-- MONEY goes through Money.charge (cash, else the bank) and back through Money.refund. AN ITEM is
-- taken here, stack by stack, each kept with its own data, so giving it back gives back exactly what
-- was taken.

local function itemName(key)
    local def = Config.Items and Config.Items[key]
    return def and def.name or key
end

local function giveBackItems(src, item, taken, reason)
    for _, t in ipairs(taken) do
        Inventory.give(src, item, t.amount, t.metadata, reason .. ' (given back)')
    end
end

--- Take `amount` of an item from the player's pockets. Answers the stacks taken, or nil and why.
local function takeItems(src, item, amount, reason)
    -- Not while a bank payment holds the pockets (Inventory.pocketsFrozen): not paid for yet.
    if Inventory.pocketsFrozen(src) then return nil, 'Paying — wait a moment' end
    local found = Inventory.findAll(src, item) or {}
    local have = 0
    for _, f in ipairs(found) do have = have + (tonumber(f.amount) or 0) end
    if have < amount then return nil, ('You need %d %s (you have %d)'):format(amount, itemName(item), have) end
    local taken, left = {}, amount
    for _, f in ipairs(found) do
        if left <= 0 then break end
        local n = math.min(left, tonumber(f.amount) or 0)
        if n > 0 and Stores.takeAt(f.addr, n, { reason = reason }) then
            taken[#taken + 1] = { amount = n, metadata = f.metadata }
            left = left - n
        end
    end
    if left > 0 then
        giveBackItems(src, item, taken, reason)
        return nil, ('Could not take the %s'):format(itemName(item))
    end
    return taken
end

--- Pay an answer's cost. Answers a way to give it back (a function), or nil and why.
local function pay(rec, source, c)
    local reason = c.reason or 'Conversation'
    if c.currency ~= 'cash' then
        local taken, why = takeItems(source, c.currency, c.amount, reason)
        if not taken then return nil, why end
        return function() giveBackItems(source, c.currency, taken, reason) end
    end
    local receipt, err = Money.charge(source, c.amount, { method = c.method, currency = 'cash', reason = reason }, rec.owner, c.reason)
    if not receipt then return nil, err or 'You cannot pay that' end
    return function() Money.refund(receipt, nil, rec.owner) end
end

SecureEvent('whip_core:server:conversationChoice', {
    rateLimit = 250, burst = 4,
    -- value: the amount typed, for an answer that takes one (checked against it below).
    params = { {'convId', 'id'}, {'optionId', 'string', 40}, {'value', 'any'} },
}, function(source, _, convId, optionId, value)
    local rec = convs[convId]
    if not rec or rec.source ~= source then return false, 'That conversation is over' end
    if rec.pending or rec.paying then return false, 'Wait for an answer' end
    -- The answers this was chosen from: an update while a payment is out must not change which reply
    -- follows it.
    local layer = rec.layer
    local opt
    for _, o in ipairs(layer.options) do
        if o.id == optionId then opt = o break end
    end
    if not opt then
        sendView(rec)   -- their screen and ours disagree: show them ours
        return false, 'That is not an answer now'
    end
    local amount
    if opt.input then
        amount = typedAmount(opt.input, value)
        if not amount then
            sendView(rec)
            return false, ('Type an amount from %s%d to %s%d'):format(opt.input.prefix, opt.input.min, opt.input.prefix, opt.input.max)
        end
    end
    local ent, gone = speakerOf(rec)
    if not ent then endWith(rec, gone) return end
    if not near(source, ent) then endWith(rec, 'left') return end

    -- The owner may still say no (canChoose): what an answer needs can change after it was offered
    -- (they gave the keycard away while the line was up). Asked before anything is taken.
    if rec.canChoose ~= nil then
        local called, allowed, why = Actions.call(rec.owner, rec.canChoose, source, opt.id, convId)
        if not called or allowed == false then
            if not called then print(('[whip_core:conversations] %s\'s canChoose threw: %s'):format(tostring(rec.owner), tostring(allowed))) end
            if not rec.gone then sendView(rec) end
            return false, (called and type(why) == 'string' and why) or 'You cannot choose that now'
        end
        if rec.gone then return end
    end

    -- A COSTED ANSWER IS PAID BEFORE IT COUNTS: refused, the same answers stay up and they are told
    -- why. The payment waits (the bank, the save), so nothing else is taken meanwhile (`paying`), and
    -- the player walking off meanwhile ends it only once it is paid (endWith waits for it). Ended
    -- under it all the same (the run's end), what was taken goes back.
    if opt.cost then
        rec.paying = true
        local giveBack, why = pay(rec, source, opt.cost)
        rec.paying = nil
        if rec.gone then
            if giveBack then giveBack() end
            return
        end
        if not giveBack then
            local after = rec.endAfterPay
            rec.endAfterPay = nil
            if after then endWith(rec, after) return false, why end
            sendView(rec)
            return false, why
        end
    end

    -- The reply sent ahead becomes what is on screen (their game shows it already); with none, the
    -- capsule waits for the owner. Those watching see the answer, then the reply (above). A costed or
    -- typed answer's reply was not sent ahead (wireLayer), so it is sent now.
    -- (A team page's picks are names and IDs: not said over the player's head.)
    if not layer.team then answerToWatchers(rec, amount and ('%s%d'):format(opt.input.prefix, amount) or opt.label) end
    local nxt = rec.layer == layer and layer.next and layer.next[opt.id] or nil
    if nxt then
        rec.layer = { line = nxt.line, options = nxt.options }
        rec.canChoose = nil   -- it was asked about the answers just left; the owner's update brings the next
        sayToWatchers(rec, nxt.line)
        if opt.cost or opt.input then sendView(rec) end
    elseif not opt.ends and rec.layer == layer then
        rec.pending = GetGameTimer()
    end
    if rec.onChoose ~= nil then
        local ok, err = Actions.call(rec.owner, rec.onChoose, source, opt.id, convId, amount)
        if not ok then print(('[whip_core:conversations] %s\'s onChoose threw: %s'):format(tostring(rec.owner), tostring(err))) end
    end
    -- Walked off (or the like) while it was being paid: it counted, and now it is over.
    local after = rec.endAfterPay
    rec.endAfterPay = nil
    if after and not rec.gone then endWith(rec, after) return end
    if opt.ends and not rec.gone then endWith(rec, 'chose') end
end)

SecureEvent('whip_core:server:conversationLeft', {
    whileDead = true, rateLimit = 250, burst = 4,
    params = { {'convId', 'id'}, {'why', 'enum', { 'left', 'blocked', 'gone', 'replaced' }, 'left'} },
}, function(source, _, convId, why)
    local rec = convs[convId]
    if not rec or rec.source ~= source then return end
    endWith(rec, why)
end)

-- ============================================
-- Watching: the player, the speaker, the owner's answer
-- ============================================

Every('conversations', TICK_MS, function()
    if next(convs) == nil then return TICK_MS end
    local now = GetGameTimer()
    local list = {}
    for _, rec in pairs(convs) do list[#list + 1] = rec end
    for _, rec in ipairs(list) do
        if not rec.gone then
            local player = Players[rec.source]
            local ent, gone = speakerOf(rec)
            if not player or not player.charId then endWith(rec, 'left')
            elseif player.isDead then endWith(rec, 'downed')
            elseif not ent then endWith(rec, gone)
            elseif not near(rec.source, ent) then endWith(rec, 'left')
            elseif rec.pending and now - rec.pending >= ANSWER_MS then endWith(rec, 'no answer')
            elseif rec.npcId then
                -- Turned on them: no more talking.
                local info = Npcs.get(rec.npcId)
                for _, s in ipairs(info and info.targets or {}) do
                    if s == rec.source then endWith(rec, 'hostile') break end
                end
            end
        end
    end
    return TICK_MS
end)

local function endFor(src, why)
    local rec = bySource[src] and convs[bySource[src]]
    if rec then endWith(rec, why) end
end

Character.onLife('logout', function(e) if e and e.source then endFor(e.source, 'logout') end end)
AddEventHandler('playerDropped', function() endFor(source, 'left') end)

Npcs.onLife('killed', function(p)
    for _, rec in pairs(convs) do
        if rec.npcId == p.npcId then endWith(rec, 'killed') end
    end
end)
Npcs.onLife('despawned', function(p)
    for _, rec in pairs(convs) do
        if rec.npcId == p.npcId then endWith(rec, 'gone') end
    end
end)

-- ============================================
-- Exports
-- ============================================

--- Open a conversation from a point's onUse: StartConversation(source, spec) -> convId | false, why.
exports('StartConversation', function(source, spec)
    local owner = Registry.caller()
    return Conversations.start(owner, source, spec)
end)

--- Say something else: UpdateConversation(convId, { line, options, next, speaker }) -> true | false, why.
exports('UpdateConversation', function(convId, patch)
    local owner = Registry.caller()
    return Conversations.update(owner, convId, patch)
end)

--- End one of yours: EndConversation(convId) -> true | false, why. onEnd hears 'ended'.
exports('EndConversation', function(convId)
    local owner = Registry.caller()
    return Conversations.finish(owner, convId)
end)

--- A conversation, as a copy: GetConversation(convId) -> table | nil.
exports('GetConversation', function(convId) return Conversations.get(convId) end)
