-- ============================================
-- Director — talk: the conversations a run's cards have with its players (DirectorTalk)
-- ============================================
--
-- THE ONE CONVERSATION PATH for every card that talks (def.talks: Dialog Line, Sell to NPC, Haggle, Pick Team). A card
-- says what it has to say through DirectorTalk.speak: it carries on the conversation the player is having with this
-- run, or opens one from the press that started the card, or, with neither, puts a Talk point on the NPC (with its
-- talk mark over the head) and opens the conversation when it is pressed. The capsule is server/conversations.lua's;
-- its answers come back to the runs as 'conversation.choice' and 'conversation.ended'.
--
-- An answer wired straight to another talking card for the same NPC carries the conversation on (continuesTo);
-- anything else closes it, the NPC saying its parting line over its head (leave), unless the outcome goes straight to
-- a line of its own above the NPC (a card with saysAbove: NPC /me).

DirectorTalk = {}

local CORE = GetCurrentResourceName()
local R = DirectorRuntime

local convs = {}     -- [convId] = { runId, nodeId }: which card a conversation is answering now

--- Open (or carry on) a conversation for a talking card. Answers the convId, or nil and why.
---@param ctx table   the card's ctx
---@param src number
---@param useId number|nil  a fresh press, when there is no conversation yet
---@param spec table  { npcId, netId, speaker, line, options, next, layout }
function DirectorTalk.converse(ctx, src, useId, spec)
    local run = ctx.run
    run.convs = run.convs or {}
    local open = run.convs[src]
    if open and Conversations.get(open) then
        local ok, why = Conversations.update(CORE, open, { line = spec.line, options = spec.options, next = spec.next,
                                                           speaker = spec.speaker, canChoose = spec.canChoose or false,
                                                           team = spec.team, haggle = spec.haggle })
        if not ok then return nil, why end
        convs[open] = { runId = run.id, nodeId = ctx.node.id }
        return open
    end
    if not useId then return nil, 'no press' end
    -- Declared first: the onEnd below needs the id, and a local is not in scope inside its own
    -- declaration (it would read a global convId, which is nil).
    local convId, why
    convId, why = Conversations.start(CORE, src, {
        fromUse = useId, npcId = spec.npcId, netId = spec.npcId == nil and spec.netId or nil,
        speaker = spec.speaker, line = spec.line, options = spec.options, next = spec.next, layout = spec.layout,
        tag = run.tag, canChoose = spec.canChoose, team = spec.team, haggle = spec.haggle,
        onChoose = function(s, optionId, cid, amount)
            local c = convs[cid]
            if c then R.emit('conversation.choice', { runId = c.runId, nodeId = c.nodeId, convId = cid, source = s, option = optionId,
                                                      amount = amount }) end
        end,
        onEnd = function(s, endWhy)
            local c = convs[convId]
            convs[convId --[[@as number]]] = nil   -- (start has answered by the time it ends)
            if run.convs and run.convs[s] == convId then run.convs[s] = nil end
            if c then R.emit('conversation.ended', { runId = c.runId, nodeId = c.nodeId, convId = convId, source = s, why = endWhy }) end
        end,
    })
    if not convId then return nil, why end
    run.convs[src] = convId
    convs[convId] = { runId = run.id, nodeId = ctx.node.id }
    return convId
end

--- The card an outcome carries the conversation on to, when it does: the ONE talking card for the same NPC among
--- its wires (other wires beside it, a /me or a variable, do not stop it; two talking cards do: which speaks is
--- not known).
---@return table|nil node
function DirectorTalk.continuesTo(graph, node, pin)
    local byPin = graph.out[node.id]
    local found
    for _, tg in ipairs(byPin and byPin[pin] or {}) do
        local t = graph.nodes[tg.node]
        if t and t.def and t.def.talks and t.id ~= node.id and t.props.npc == node.props.npc then
            if found then return nil end
            found = t
        end
    end
    return found
end

--- THE TALK MARK (client/director_talk.lua): over the head of an NPC a card waits for this player to talk to, one
--- with each Talk point: 'new' ("!" and the talk sign in turn: talk to them to go on) or 'resume' (the talk sign:
--- they walked off mid-conversation). Sent to that player as their marks are now; it goes with its point.
local function sendTalkMarks(run, src)
    local list = {}
    for _, m in pairs(run.talkMarks or {}) do
        if m.src == src and m.netId then list[#list + 1] = { netId = m.netId, state = m.state } end
    end
    TriggerClientEvent('whip_core:client:directorTalkMarks', src, run.id, list)
end

local function setTalkMark(run, pointId, src, netId, state)
    run.talkMarks = run.talkMarks or {}
    local was = run.talkMarks[pointId]
    run.talkMarks[pointId] = src and { src = src, netId = netId, state = state } or nil
    local who = src or (was and was.src)
    if who then sendTalkMarks(run, who) end
end

--- Say `spec` to `src` for a talking card: carry on the conversation they are in with this run, or
--- open one from the press that started this, or, with neither, put a Talk point on the NPC for that
--- player (and its talk mark over the NPC's head) and open it when they press it. The point goes when
--- the card ends; a card that gives up (timeout) closes the conversation.
---
--- The point is the player's while they are in the run: it is addressed to a server id, which
--- outlives being in the run (Swap Character, RemovePlayerFromScenarioRun). Leaving the run takes it
--- down with their conversation (DirectorTalk.drop, from main.lua's leaveRun), and a press from anyone not in the
--- run is refused.
---@param h table   the NPC's handle (npcId, netId)
---@param spec table|function  { speaker, line, options, next, layout, canChoose }, or a function that
---                 makes it: asked again when the Talk point is pressed, which can be minutes later
---                 (what an answer needs may have changed)
---@param again boolean|nil  they talked and walked off: its mark is the talk sign alone ('resume'), not "!" ('new')
function DirectorTalk.speak(ctx, src, npcW, h, spec, talkLabel, again)
    local function now()
        local s = (type(spec) == 'function' and spec() or spec) --[[@as table]]
        s.npcId, s.netId = h.npcId, h.netId
        return s
    end
    local run = ctx.run
    local t = type(ctx.trigger) == 'table' and ctx.trigger or {}
    local from = type(t.from) == 'table' and t.from or t
    -- (Not again: they just walked off, and the press that started this is still fresh for a few seconds,
    -- so it would open the conversation again while they are still walking away.)
    local useId = (not again and from.world == npcW) and from.useId or nil
    local pointId
    local function takeDown()
        if not pointId then return end
        RuntimePoints.remove(CORE, pointId)
        if run.talkPoints then run.talkPoints[pointId] = nil end
        setTalkMark(run, pointId, nil)
        pointId = nil
    end
    -- (Nothing they may say yet, a Dialog Line whose every answer's rules say no: their Talk waits, and pressed, says so.)
    local function sayable(s) return type(s.options) == 'table' and #s.options > 0 end
    local first = now()
    local convId = sayable(first) and DirectorTalk.converse(ctx, src, useId, first) or nil
    if not convId then
        local why
        pointId, why = RuntimePoints.add(CORE, {
            at = { netId = h.netId, offset = vector3(0.0, 0.0, 0.3) }, label = talkLabel or 'Talk',
            reach = 2.5, tag = ctx:tag(), audience = { people = { src } }, talk = true,
            onUse = function(source, use)
                if source ~= src or not ctx:isPlayer(source) then return false, 'You are not on this job' end
                local s = now()
                if not sayable(s) then return false, 'You have nothing to say to them yet' end
                local cid, cwhy = DirectorTalk.converse(ctx, source, use.useId, s)
                if not cid then return false, cwhy end
                takeDown()
            end,
        })
        if pointId then
            run.talkPoints = run.talkPoints or {}
            run.talkPoints[pointId] = src
            setTalkMark(run, pointId, src, h.netId, again and 'resume' or 'new')
        else
            ctx:log('could not offer a Talk point: %s', tostring(why))
        end
    end
    ctx:onEnd(function(pin)
        takeDown()
        if pin == 'timeout' then
            local open = run.convs and run.convs[src]
            if open then Conversations.finish(CORE, open) end
        end
    end)
end

--- A player out of the run (leaveRun: logging out, Swap Character, a drop, RemovePlayerFromScenarioRun):
--- the Talk points it offered them go, and so does a conversation they are having with it. A card
--- waiting on them hears the conversation end, as when they log out mid-sentence.
---@param run table
---@param src number
function DirectorTalk.drop(run, src)
    for id, s in pairs(run.talkPoints or {}) do
        if s == src then
            RuntimePoints.remove(CORE, id)
            run.talkPoints[id] = nil
            setTalkMark(run, id, nil)
        end
    end
    local open = run.convs and run.convs[src]
    if open then Conversations.finish(CORE, open) end
end

--- A run over (main.lua runEnded): which card its conversations were answering is forgotten.
function DirectorTalk.runEnded(run)
    for cid, c in pairs(convs) do
        if c.runId == run.id then convs[cid] = nil end
    end
end

--- Is an outcome wired straight to a line above the same NPC (a card with saysAbove: NPC /me)? That line is said
--- instead of the card's own.
local function saysOwnLine(run, node, pin)
    for _, tg in ipairs(pin and (run.graph.out[node.id] or {})[pin] or {}) do
        local t = run.graph.nodes[tg.node]
        -- (Its NPCs: one or several, groups' members too.)
        if t and t.def and t.def.saysAbove then
            for _, id in ipairs(DirectorNodes.expandThings(run.graph.world, t.props.npc, 'npc')) do
                if id == node.props.npc then return true end
            end
        end
    end
    return false
end

--- A talking card went on from `pin` while the conversation was open and waiting on it: if that
--- outcome carries it on to another talking card for the NPC, that card speaks next; if not, it
--- closes, and the NPC says `parting` as a bubble over its head (a /me's, for everyone near: it
--- outlives the run, which often ends on this very outcome and takes its conversation with it).
function DirectorTalk.leave(ctx, src, pin, parting)
    local run = ctx.run
    local open = run.convs and run.convs[src]
    local conv = open and Conversations.get(open)
    if not conv then return end
    if pin and DirectorTalk.continuesTo(run.graph, ctx.node, pin) then return end
    Conversations.finish(CORE, open)
    if saysOwnLine(run, ctx.node, pin) then return end
    if type(parting) == 'string' and parting ~= '' and conv.netId and Bubbles then
        Bubbles.show({ netId = conv.netId }, parting)
    end
end

--- A talking card's No answer (Dialog Line, Sell to NPC, Haggle, Pick Team): it goes out of 'timeout' after
--- `seconds`, and the NPC says so over its head as a /me (Config.Conversations): half way there, and as it gives
--- up. Not the last when No answer goes on to more talk with the NPC, or to a line of its own above it. No
--- seconds: no time limit, and neither line.
function DirectorTalk.noAnswerAfter(ctx, h, seconds)
    seconds = tonumber(seconds)
    if not seconds then return end
    ctx:after(seconds * 1000, 'timeout')
    local cfg = Config.Conversations or {}
    local half, last = cfg.noAnswerHalfText, cfg.noAnswerText
    local netId = type(h) == 'table' and h.netId or nil
    if not (netId and Bubbles) then return end
    if type(half) == 'string' and half ~= '' then
        ---@type integer|nil
        local at = GetGameTimer() + math.floor(seconds * 500)
        ctx:poll(1000, function()
            if at and GetGameTimer() >= at then
                at = nil
                Bubbles.show({ netId = netId }, half)
            end
            return nil
        end)
    end
    if type(last) == 'string' and last ~= '' then
        ctx:onEnd(function(pin)
            if pin ~= 'timeout' then return end
            local run, node = ctx.run, ctx.node
            if DirectorTalk.continuesTo(run.graph, node, 'timeout') or saysOwnLine(run, node, 'timeout') then return end
            Bubbles.show({ netId = netId }, last)
        end)
    end
end
