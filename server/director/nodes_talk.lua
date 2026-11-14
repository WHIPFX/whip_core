-- ============================================
-- Director — the talking cards: Sell to NPC, Haggle, and player flags
-- ============================================
--
-- SELL TO NPC and HAGGLE speak in the dialog capsule as a Dialog Line does (DirectorTalk.speak: talk.lua): they
-- carry on the conversation the player is in with this NPC, or open one from the press that started
-- this, or put a Talk point on the NPC. An answer of a Dialog Line wired straight to one of them for
-- the same NPC carries the conversation on into it. When they are done, an outcome wired to another
-- speaking card for the NPC carries on; any other outcome closes it, and the NPC says a parting line
-- over its head ("Pleasure doing business.": DirectorTalk.leave).
--
-- PLAYER FLAGS (server/player_flags.lua) are what a character has done, kept for good: Set Player
-- Flag writes one, If Player Flag asks one, and a Dialog Line answer can be offered only if one is
-- (or is not) set. A test leaves no flag behind: what it sets stays on the test run.

local CORE = GetCurrentResourceName()

local define = DirectorKit.define

local money, itemName = DirectorKit.money, DirectorKit.itemName

--- `{count}`, `{item}`, `{total}`, `{price}`, `{offer}` in a line, filled in.
local function fill(line, vals)
    return (tostring(line or ''):gsub('{(%w+)}', function(k)
        local v = vals[k]
        if v == nil then return '{' .. k .. '}' end
        return tostring(v)
    end))
end

--- The NPC a speaking card is for, in the world; nil (and the card logs why) when it is not.
local function speakerOf(ctx)
    local npcW = ctx.node.props.npc
    local h = Director.handleOf(ctx.run, npcW)
    if type(h) ~= 'table' or not h.netId then
        ctx:log('%s is not in the world: nobody to speak', tostring(npcW))
        return nil
    end
    return h, npcW
end

-- ============================================
-- Sell to NPC
-- ============================================
--
-- The NPC offers to buy what the player carries of an item, at a price each (a field, or a variable:
-- a price a Haggle agreed). The player says yes or no in the capsule; yes takes the items and pays them,
-- both on the record. Asked with nothing to sell, it goes out of Had none at once. A test buys nothing
-- and pays nothing: it says what it would have done.

--- The stacks of an item a player may sell: every one they carry, and how many.
local function sellable(src, item)
    local out, n = {}, 0
    for _, f in ipairs(Inventory.findAll(src, item) or {}) do
        out[#out + 1] = f
        n = n + (tonumber(f.amount) or 0)
    end
    return out, n
end

--- The sale itself (it waits: the stores, the bank). Answers the outcome and its data.
local function sell(ctx, src, item, want, price, method)
    local run = ctx.run
    local data = { source = src }
    -- Not while a bank payment holds their pockets: what is in them may not be paid for yet. The hold
    -- lasts a moment, so the sale waits for it.
    local holdUntil = GetGameTimer() + 5000
    while Inventory.pocketsFrozen(src) do
        if GetGameTimer() > holdUntil then
            NotifyPlayer(src, 'Paying for something — try again in a moment', 'error')
            return 'cancelled', data
        end
        Wait(100)
    end
    local stacks, have = sellable(src, item)
    local n = math.min(have, want)
    if n <= 0 then return 'nothing', data end
    local reason = Director.reason(run) .. (' (sold %s)'):format(item)
    if run.test then
        NotifyPlayer(src, ('Test: they would buy %d %s for %s'):format(n, itemName(item), money(n * price)), 'info')
        Director.event(run, ctx.node.id, 'sold (test)', src, ('%s x%d for %s'):format(item, n, money(n * price)))
        data.count, data.total = n, n * price
        return 'sold', data
    end
    -- Take first, pay after; a payment refused gives back what was taken (with its own data).
    local taken, left = {}, n
    for _, f in ipairs(stacks) do
        if left <= 0 then break end
        local take = math.min(left, tonumber(f.amount) or 0)
        if take > 0 and Stores.takeAt(f.addr, take, { reason = reason }) then
            taken[#taken + 1] = { amount = take, metadata = f.metadata }
            left = left - take
        end
    end
    local count = n - left
    if count <= 0 then return 'nothing', data end
    local total = count * price
    local ok, res = Money.pay(src, total, { method = method, reason = ('Sold %d %s'):format(count, itemName(item)) }, CORE, reason)
    if not ok then
        -- (As it was taken, its own data and all; its reason in the log, as every give has it: { reason }.)
        for _, t in ipairs(taken) do
            Inventory.give(src, item, t.amount, t.metadata, { reason = reason .. ': the payment failed, given back' })
        end
        ctx:log('paying %s %s for %d %s failed: %s', tostring(src), money(total), count, item, tostring(res))
        NotifyPlayer(src, 'They could not pay you: ' .. tostring(res), 'error')
        return 'cancelled', data
    end
    run.payout = (run.payout or 0) + total
    Director.event(run, ctx.node.id, 'sold', src, ('%s x%d for %s'):format(item, count, money(total)))
    data.count, data.total = count, total
    return 'sold', data
end

define({
    type = 'npc.sell', v = 1, category = 'dialog', title = 'Sell to NPC',
    haggle = { key = 'price', toPlayer = true, unit = 'money' },   -- (a Haggle can agree its price each: below)
    once = false,   -- (the run waits here for a player's answer: never Only Once, nodes.lua)
    desc = 'An NPC offers to buy an item the player carries, at a price each: they say yes or no in the conversation.',
    outputs = { 'sold', 'nothing', 'cancelled', 'timeout' },
    labels = { sold = 'Sold', nothing = 'Had none', cancelled = 'Said no', timeout = 'No answer' },
    latent = true, yields = true, talks = true,
    props = {
        { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who buys', required = true },
        { key = 'item', kind = 'item', label = 'What they buy', required = true },
        { key = 'price', kind = 'number', label = 'Price each ($)', default = 100, min = 0, max = 1000000 },
        { key = 'most', kind = 'number', label = 'At most (empty: all they carry)', min = 1, max = 1000 },
        { key = 'line', kind = 'text', label = 'What they say', maxLength = 220,
          default = 'I\'ll give you {total} for {count} {item}.' },
        { key = 'yes', kind = 'text', label = 'Yes', maxLength = 60, default = 'Deal' },
        { key = 'no', kind = 'text', label = 'No', maxLength = 60, default = 'No thanks' },
        { key = 'method', kind = 'select', label = 'Paid as', options = { 'auto', 'cash', 'bank' }, default = 'auto' },
        { key = 'soldVar', kind = 'var', label = 'Put how many were sold in' },
        { key = 'paidVar', kind = 'var', label = 'Put the money paid in' },
        DirectorNodes.nameShownField(),
        DirectorNodes.speakerField(),
        { key = 'talk', kind = 'text', label = 'Talk prompt', default = 'Talk', maxLength = 40 },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds)', default = 120, min = 5, max = 3600 },
    },
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local src = Director.playerOf(ctx)
        if not src then return 'cancelled' end
        local item = ctx:prop('item')
        if not (type(Config) == 'table' and Config.Items and Config.Items[item]) then
            ctx:log('%s is not an item on this server', tostring(item))
            return 'nothing'
        end
        local h, npcW = speakerOf(ctx)
        if not h then return 'cancelled' end
        local price = math.max(0, math.floor(tonumber(ctx:prop('price')) or 0))
        local most = tonumber(ctx:prop('most'))
        local want = most and math.max(1, math.floor(most)) or math.huge
        local _, have = sellable(src, item)
        local n = math.min(have, want)
        if n <= 0 then
            DirectorTalk.leave(ctx, src, 'nothing', 'You don\'t have any.')
            return 'nothing', { source = src }
        end
        local method = ctx:prop('method') or 'auto'
        local function done(pin, data)
            if pin == 'sold' and data and data.count then
                if node.props.soldVar then ctx:setVar(node.props.soldVar, data.count) end
                if node.props.paidVar then ctx:setVar(node.props.paidVar, data.total) end
            end
            return pin, data
        end

        local selling = false
        ctx:on('conversation.choice', function(p)
            if p.runId ~= run.id or p.nodeId ~= node.id or p.source ~= src or selling then return nil end
            if p.option ~= 'yes' then
                Director.event(run, node.id, 'said no', src, item)
                return 'cancelled', { source = src }
            end
            -- Yes: the sale waits (the stores, the bank), so it runs in a call; walking off meanwhile
            -- does not undo it.
            selling = true
            ctx:call(function() return done(sell(ctx, src, item, want, price, method)) end, {
                -- Sold after the card had already gone on (its time ran out mid-sale): the sale stands
                -- (the items are taken, the money paid), so its numbers are kept and it is said.
                late = function(pin, data)
                    if pin == 'sold' and type(data) == 'table' then
                        if node.props.soldVar then DirectorRuntime.setVar(run, node.props.soldVar, data.count) end
                        if node.props.paidVar then DirectorRuntime.setVar(run, node.props.paidVar, data.total) end
                        ctx:log('a sale finished after the card had gone on: %s x%s for %s', tostring(item), tostring(data.count), tostring(data.total))
                    end
                end,
            })
            return nil
        end)
        ctx:on('conversation.ended', function(p)
            if p.runId == run.id and p.nodeId == node.id and p.source == src and p.why ~= 'chose' and not selling then
                return 'cancelled', { source = src }
            end
        end)
        DirectorTalk.noAnswerAfter(ctx, h, tonumber(ctx:prop('seconds')) or 120)

        local line = fill(ctx:prop('line'), { count = n, item = itemName(item), total = money(n * price), price = money(price) })
        DirectorTalk.speak(ctx, src, npcW, h, {
            speaker = DirectorNodes.shownName(ctx, npcW), line = line,
            options = { { id = 'yes', label = ctx:prop('yes') or 'Deal' }, { id = 'no', label = ctx:prop('no') or 'No thanks' } },
        }, ctx:prop('talk'))
        ctx:onEnd(function(pin, why)
            if why ~= 'answered' then return end
            local parting = ({ sold = 'Pleasure doing business.', cancelled = 'Suit yourself.', nothing = 'You don\'t have any.' })[pin]
            DirectorTalk.leave(ctx, src, pin, parting)
        end)
        return nil
    end,
})

-- ============================================
-- Haggle
-- ============================================
--
-- Agreeing a price, in the capsule, as HOT AND COLD. The NPC has a limit the player cannot see: Ceiling, the most it
-- pays (THEY BUY: it pays the player), or Floor, the least it takes (THEY SELL: the player pays it). Its opening
-- offer (Base) is a yes. The player has Asks, each a price of their own, moved along the capsule's ruler or typed
-- (client/conversations.lua):
--   within its limit: a YES, coloured by how close it came (cold far off, hot right by it). The best yes is what
--     Settle takes; the player may stop there or push on.
--   past it, within REACH of it: a NO, one patience gone.
--   further past: an INSULT, two gone, its best offer drops to the worst (Floor when it pays, Ceiling when it
--     sells) and its limit comes halfway down with it.
-- Patience run out: Angry. Asks run out: settle or leave. The ruler shows every ask, and where its limit can still be.
-- Deal: settled at a price at least as good as its opening one for the player; Bad deal: worse (after an insult).
-- Both put the price in the variable and carry it as `price`.
--
-- HAGGLING FOR A CARD (Haggling for): the price agreed is what that card pays, charges or gives when the run reaches
-- it (Pay, Send Money, Charge Player, Give Item's how many, Sell to NPC's price each: their def.haggle; runtime.lua
-- CTX:prop puts it in). Which way it goes is that card's: it pays the player or charges them. Without one, They says
-- which, and the price only goes in its variable.

local PATIENCE = { short = 1, normal = 2, long = 3 }   -- the noes it takes before it is Angry (an insult is two)
local REACH = 0.5    -- how far past its limit an ask is a plain No, as a share of the room it had; further is an insult
local SIDES = { 'they buy from the player', 'they sell to the player' }
local HAGGLE_FOR = DirectorNodes.HAGGLED   -- (every card with a `haggle`: filled as they are defined)

define({
    type = 'npc.haggle', v = 1, category = 'dialog', title = 'Haggle',
    once = false,   -- (the run waits here for a player's answer: never Only Once, nodes.lua)
    desc = 'The player and an NPC agree a price. A Pay, Charge or Give Item card after it can use the price.',
    outputs = { 'deal', 'bad', 'walked', 'angry', 'timeout' },
    labels = { deal = 'Deal', bad = 'Bad deal', walked = 'Walked away', angry = 'Angry', timeout = 'No answer' },
    latent = true, talks = true,
    props = {
        { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who', required = true },
        { key = 'forCard', kind = 'card', label = 'Haggling for', options = HAGGLE_FOR,
          hint = 'The price agreed is what that card pays, charges or gives when the scenario gets to it.' },
        -- (Haggling for a card, which way it goes is that card's: it pays the player, or charges them.)
        { key = 'side', kind = 'select', label = 'They', options = SIDES, default = SIDES[1], when = { key = 'forCard', set = false } },
        { key = 'base', kind = 'number', label = 'Opening offer', default = 1000, min = 0, max = 100000000 },
        { key = 'floor', kind = 'number', label = 'Floor: the least it pays, or the lowest it sells for', default = 700, min = 0, max = 100000000 },
        { key = 'ceiling', kind = 'number', label = 'Ceiling: the most it pays, or the most it asks', default = 1500, min = 0, max = 100000000 },
        { key = 'rounds', kind = 'number', label = 'Asks the player gets', default = 3, min = 1, max = 5 },
        { key = 'patience', kind = 'select', label = 'Patience', options = { 'short', 'normal', 'long' }, default = 'normal' },
        { key = 'priceVar', kind = 'var', label = 'Put the price agreed in' },
        { key = 'what', kind = 'text', label = 'What it is for (in its lines)', maxLength = 40, default = 'it' },
        DirectorNodes.nameShownField(),
        DirectorNodes.speakerField(),
        { key = 'talk', kind = 'text', label = 'Talk prompt', default = 'Talk', maxLength = 40 },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds)', default = 180, min = 10, max = 3600 },
        -- What the NPC says over its head as the talk ends on each outcome (an outcome wired to an NPC /me for it says
        -- that instead: DirectorTalk.leave).
        { key = 'byeDeal', kind = 'text', label = 'As it ends: Deal', maxLength = 120, default = 'Pleasure doing business.',
          group = 'Its last words' },
        { key = 'byeBad', kind = 'text', label = 'As it ends: Bad deal', maxLength = 120, default = 'Fine. Your loss.' },
        { key = 'byeWalked', kind = 'text', label = 'As it ends: Walked away', maxLength = 120, default = 'Your loss.' },
        { key = 'byeAngry', kind = 'text', label = 'As it ends: Angry', maxLength = 120, default = 'Get out of my sight.' },
    },
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local src = Director.playerOf(ctx)
        if not src then return 'walked' end
        local h, npcW = speakerOf(ctx)
        if not h then return 'walked' end

        -- What it is for: a card (its way, its unit, its own field's bounds), or its own They.
        local target = ctx:prop('forCard')
        local tnode = type(target) == 'string' and run.graph.nodes[target] or nil
        local th = tnode and tnode.def and tnode.def.haggle or nil
        local buys, unit, bounds = (ctx:prop('side') or SIDES[1]) == SIDES[1], 'money', nil
        if tnode and th then
            buys, unit = th.toPlayer == true, th.unit == 'count' and 'count' or 'money'
            bounds = tnode.def._fields[th.key]
        end
        local function fmt(n) return unit == 'count' and ('%d'):format(n) or money(n) end
        local function within(n)
            if bounds and bounds.min then n = math.max(bounds.min, n) end
            if bounds and bounds.max then n = math.min(bounds.max, n) end
            return math.max(0, n)
        end

        local base = within(math.floor(tonumber(ctx:prop('base')) or 0))
        local lo = within(math.floor(tonumber(ctx:prop('floor')) or base))
        local hi = within(math.floor(tonumber(ctx:prop('ceiling')) or base))
        if lo > hi then lo, hi = hi, lo end
        if base < lo or base > hi then
            ctx:log('the opening offer %d is outside floor %d and ceiling %d: held to them', base, lo, hi)
            base = math.min(math.max(base, lo), hi)
        end
        -- In the player's terms: `limit` is the best the NPC will go to, `worst` where an insult sends it.
        local limit, worst = buys and hi or lo, buys and lo or hi
        local function better(a, b) if buys then return a > b end return a < b end
        local room = math.max(math.abs(limit - base), math.abs(base) * 0.1, 1)
        local patMax = PATIENCE[ctx:prop('patience') or 'normal'] or 2
        local rounds = math.max(1, math.min(5, math.floor(tonumber(ctx:prop('rounds')) or 3)))
        local what = ctx:prop('what') or 'it'

        -- The ruler: from its worst to as far past its limit again as its limit is from its opening offer, so its
        -- limit is never at an end.
        local span = math.max(math.abs(limit - base), math.abs(limit - worst), 1)
        local rlo, rhi
        if buys then rlo, rhi = math.min(worst, base), limit + span else rlo, rhi = limit - span, math.max(worst, base) end
        rlo, rhi = within(math.floor(rlo)), within(math.ceil(rhi))
        if rhi <= rlo then rhi = rlo + 1 end

        -- best: what Settle takes; yes / no: the nearest yes and no so far (its limit is between them).
        local st = { best = base, limit = limit, left = rounds, pat = patMax, asks = {}, yes = base, no = nil }

        local function ruler()
            local a, b
            if buys then a, b = st.yes or rlo, st.no or rhi else a, b = st.no or rlo, st.yes or rhi end
            return { buys = buys, lo = rlo, hi = rhi, unit = unit, asks = st.asks, best = st.best, a = a, b = b,
                     left = st.left, pat = st.pat, patMax = patMax }
        end
        local function options()
            local list = {}
            if st.left > 0 then
                list[#list + 1] = { id = 'ask', label = buys and 'Ask for more' or 'Offer less',
                                    input = { min = 0, max = rhi, prefix = unit == 'count' and '×' or '$' } }
            end
            list[#list + 1] = { id = 'take', label = ('Settle: %s'):format(fmt(st.best)) }
            list[#list + 1] = { id = 'leave', label = 'Forget it' }
            return list
        end
        local function speak(line)
            st.line = line
            return { speaker = DirectorNodes.shownName(ctx, npcW), line = line, options = options(), haggle = ruler() }
        end
        local opening
        if unit == 'count' then
            opening = buys and ('I can give you %d.'):format(base) or ('I want %d.'):format(base)
        else
            opening = buys and ('I can give you %s for %s.'):format(money(base), what)
                or ('I\'ll let %s go for %s.'):format(what, money(base))
        end

        local function finished(price)
            if node.props.priceVar then ctx:setVar(node.props.priceVar, price) end
            -- What it is for pays, charges or gives this when the run reaches it (runtime.lua CTX:prop).
            if tnode then
                run.haggled = run.haggled or {}
                run.haggled[target] = price
            end
            local good = not better(base, price)   -- at least as good for the player as its opening
            Director.event(run, node.id, good and 'agreed' or 'agreed (a bad deal)', src, fmt(price))
            return good and 'deal' or 'bad', { source = src, price = price }
        end

        ctx:on('conversation.choice', function(p)
            if p.runId ~= run.id or p.nodeId ~= node.id or p.source ~= src then return nil end
            if p.option == 'take' then return finished(st.best) end
            if p.option == 'leave' then
                Director.event(run, node.id, 'walked away', src, fmt(st.best))
                return 'walked', { source = src }
            end
            local asked = math.tointeger(tonumber(p.amount))
            if p.option ~= 'ask' or not asked or st.left <= 0 then
                -- Not an answer it offers now (a screen behind ours): what it offers, again.
                DirectorTalk.converse(ctx, src, nil, speak(st.line))
                return nil
            end
            asked = within(asked)
            st.left = st.left - 1
            local line
            if not better(asked, st.limit) then
                -- Within its limit: a yes, as hot as it came close.
                local heat = better(asked, base)
                    and math.max(0, math.min(1, math.abs(asked - base) / math.max(1, math.abs(st.limit - base)))) or 0
                st.asks[#st.asks + 1] = { p = asked, r = 'yes', h = heat }
                if better(asked, st.best) then st.best = asked end
                if st.yes == nil or better(asked, st.yes) then st.yes = asked end
                line = heat >= 0.85 and ('%s... fine. Just.'):format(fmt(asked))
                    or heat >= 0.5 and ('%s? I could do that.'):format(fmt(asked))
                    or ('%s? Easy.'):format(fmt(asked))
            else
                if st.no == nil or better(st.no, asked) then st.no = asked end
                if math.abs(asked - st.limit) / room <= REACH then
                    st.asks[#st.asks + 1] = { p = asked, r = 'no' }
                    st.pat = st.pat - 1
                    line = buys and ('%s? No. Too much.'):format(fmt(asked)) or ('%s? No. Too low.'):format(fmt(asked))
                else
                    -- Insulted: its best offer drops to the worst, and its limit comes halfway down with it (else
                    -- asking its old limit next would be a yes). What it said yes to before is off the table.
                    st.asks[#st.asks + 1] = { p = asked, r = 'insult' }
                    st.pat = st.pat - 2
                    st.best, st.yes = worst, nil
                    local mid = (worst + st.limit) / 2
                    st.limit = buys and math.floor(mid) or math.ceil(mid)
                    line = ('Don\'t insult me. %s now.'):format(fmt(st.best))
                end
                if st.pat <= 0 then
                    Director.event(run, node.id, 'angered', src, fmt(asked))
                    return 'angry', { source = src }
                end
            end
            if st.left <= 0 then line = line .. (' That\'s it: %s, take it or leave it.'):format(fmt(st.best)) end
            local ok, why = DirectorTalk.converse(ctx, src, nil, speak(line))
            if not ok then ctx:log('the haggle could not go on: %s', tostring(why)) end
            return nil
        end)
        ctx:on('conversation.ended', function(p)
            if p.runId == run.id and p.nodeId == node.id and p.source == src and p.why ~= 'chose' then
                return 'walked', { source = src }
            end
        end)
        DirectorTalk.noAnswerAfter(ctx, h, tonumber(ctx:prop('seconds')) or 180)

        DirectorTalk.speak(ctx, src, npcW, h, speak(opening), ctx:prop('talk'))
        ctx:onEnd(function(pin, why)
            if why ~= 'answered' then return end
            local key = ({ deal = 'byeDeal', bad = 'byeBad', walked = 'byeWalked', angry = 'byeAngry' })[pin]
            DirectorTalk.leave(ctx, src, pin, key and ctx:prop(key) or nil)
        end)
        return nil
    end,
})

-- ============================================
-- Pick Team
-- ============================================
--
-- The team page ("Who are you doing this with?"): the last of the talk before a job. In the capsule,
-- the player who is talking sees a slot for each place in the team (the scenario's Team size, them
-- included: Director.teamSize) and a list: the players near them, nearest first, by character name;
-- "Enter a character ID…" for one who is not near; and Let's go.
--
--   * Each one picked is asked first: on their own screen, Accept or Decline (server/ask.lua, 30 s).
--     Picked again while asked, the ask is taken back; picked once in, they are taken off the team.
--   * One who accepts takes a slot, and joins the run at Let's go (Director.addPlayer: the crew's rights
--     and what it was given, from then on). Asks still out are taken back then.
--   * Who can be picked: on a character, up, not in the character screen, not on this job already nor in
--     another run of it. One asked or in who stops being so (goes down, leaves) is off the list.
--   * A test is played alone: the page shows, and picking anyone says so.
-- The page is looked at again each second and sent only when something on it changed: who is listed,
-- how far each one is, asked or in.

local TEAM_INVITE_MS = 30000
local TEAM_ROWS = 10   -- the most players listed: with "Enter a character ID…" and Let's go, the capsule's 12

-- What the starter is told when one they asked is not coming (server/ask.lua's answers).
local ASK_WHY = { busy = 'is busy right now', timeout = 'did not answer', dead = 'is down', ['player left'] = 'left the city' }

-- Once an invite ends without them in (taken back, declined, unanswered), the same starter waits before
-- asking the same person again (the rule bank invites and job offers follow in whip_phone): an invite
-- rings the phone through Do Not Disturb, and anyone online can be picked by character ID, so asking
-- again and again would be a grief. Kept out here, by the two characters, so a new card (talking to the
-- NPC again) does not start it afresh.
local INVITE_AGAIN_MS = 10000
local inviteEnded = {}   -- ['<starter charId>:<invitee charId>'] = GetGameTimer() when it ended

local function inviteKey(from, to)
    local a, b = Players[from], Players[to]
    if not (a and a.charId and b and b.charId) then return nil end
    return a.charId .. ':' .. b.charId
end

--- An invite from `from` to `to` ended without them in: the wait starts. Old marks go as new ones come.
local function noteInviteEnded(from, to)
    local k = inviteKey(from, to)
    if not k then return end
    local now = GetGameTimer()
    for key, at in pairs(inviteEnded) do
        if now - at >= INVITE_AGAIN_MS then inviteEnded[key] = nil end
    end
    inviteEnded[k] = now
end

--- Is it too soon for `from` to ask `to` again?
local function inviteTooSoon(from, to)
    local k = inviteKey(from, to)
    local at = k and inviteEnded[k]
    return at ~= nil and GetGameTimer() - at < INVITE_AGAIN_MS
end

local function nameOf(src)
    local p = Players[src]
    return p and p.fullName or ('Player ' .. tostring(src))
end

--- A player's name as `viewer` may see it (whip's name rule, MayKnowName: Config.ShowPlayerNames),
--- else the character ID they are known by. nameOf stays for the run's event log (builders).
local function nameFor(viewer, s)
    if MayKnowName(viewer, s) then return nameOf(s) end
    local p = Players[s]
    return p and p.charId and ('#' .. p.charId) or 'Someone'
end

--- Could `src` join this run now? Not in it already, and whoever may be in a run of it
--- (Director.eligible: the start's own rule). `busy`: Director.inRunSet, worked out once for a list.
---@return boolean ok
---@return string|nil why  (said of them: "They are ...")
local function canJoin(run, src, busy)
    if run.players[src] then return false, 'They are already on this job' end
    local ok, why = Director.eligible(run.scenario, src, { they = true, busy = busy })
    if not ok then return false, why end
    -- Cooling down from it, in a job that has begun (Director.addPlayer refuses them at Let's go too)
    if not run.pre then
        local cooling = Director.coolingDown(run.scenario, { players = { [src] = true }, starter = run.starter })
        if cooling then return false, ('They can do this job again in %d min'):format(cooling[1].mins) end
    end
    return true
end

--- Where a player is, or nil when they have no ped.
local function posOf(s)
    local ped = GetPlayerPed(s)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

--- Metres between a spot and a player, or nil when either is not there.
local function apart(at, s)
    if not at then return nil end
    local c = posOf(s)
    if not c then return nil end
    local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

define({
    type = 'dialog.team', v = 1, category = 'dialog', title = 'Pick Team',
    once = false,   -- (the run waits here for a player's answer: never Only Once, nodes.lua)
    desc = 'The player picks who joins them, up to the Team size. Each one is asked, and those who accept join.',
    outputs = { 'ready', 'left', 'timeout' },
    labels = { ready = 'Ready', left = 'Walked away', timeout = 'No answer' },
    latent = true, yields = true, talks = true,
    props = {
        { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who speaks', required = true },
        DirectorNodes.nameShownField(),
        DirectorNodes.speakerField(),
        { key = 'line', kind = 'text', label = 'What they say', maxLength = 220, default = 'Who are you doing this with?' },
        { key = 'radius', kind = 'number', label = 'Lists players within (metres)', default = 15, min = 2, max = 100 },
        { key = 'byId', kind = 'bool', label = 'By character ID too', default = true },
        { key = 'talk', kind = 'text', label = 'Talk prompt', default = 'Talk', maxLength = 40 },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds)', default = 300, min = 30, max = 3600 },
    },
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local src = Director.playerOf(ctx)
        if not src then return 'left' end
        local h, npcW = speakerOf(ctx)
        if not h then return 'left' end
        local cap = Director.teamSize(run.scenario)
        local function onJob()
            local n = 0
            for _ in pairs(run.players) do n = n + 1 end
            return n
        end
        -- A team of one, or full already: nobody to pick.
        if onJob() >= cap then
            DirectorTalk.leave(ctx, src, 'ready')
            return 'ready', { source = src }
        end

        local radius = math.max(2, math.min(100, tonumber(ctx:prop('radius')) or 15))
        local allowId = ctx:prop('byId') ~= false
        local starter = nameOf(src)   -- the event log's; a player is shown starterFor
        local function starterFor(s) return nameFor(s, src) end
        local job = run.scenario and run.scenario.name or 'a job'
        local live, going = true, false
        local order, state, token = {}, {}, {}   -- picked, in order; [src] = 'waiting' | 'in'; [src] = its ask

        local function taken()
            local n = onJob()
            for _, st in pairs(state) do if st then n = n + 1 end end
            return n
        end

        local function drop(s, tell)
            local was = state[s]
            state[s] = nil
            if was then noteInviteEnded(src, s) end   -- taken back: asking them again waits
            if token[s] then Ask.cancel(token[s], 'cancelled') token[s] = nil end
            if was == 'in' and tell then NotifyPlayer(s, ('You were taken off %s\'s team'):format(starterFor(s)), 'info') end
        end

        --- Who is listed: those asked or in first (in the order picked), then the nearest.
        ---
        --- A second's look, so kept cheap: who is in a run of this scenario is worked
        --- out once (not once per player), the starter's place once, and a player's distance comes before
        --- the rest of the rule, so one across the map costs a position read and nothing more.
        local function rows()
            local busy = run.scenario and Director.inRunSet(run.scenario) or nil
            for s, st in pairs(state) do
                if st and not canJoin(run, s, busy) then drop(s, false) end
            end
            local here = posOf(src)
            local out, seen = {}, {}
            for _, s in ipairs(order) do
                if state[s] and #out < TEAM_ROWS then
                    out[#out + 1] = { s = s, d = apart(here, s) }
                    seen[s] = true
                end
            end
            -- Only those whose name the starter may see (MayKnowName): the list names them. Anyone else is
            -- picked by character ID.
            local near = {}
            for s in pairs(Players) do
                if s ~= src and not seen[s] then
                    local d = apart(here, s)
                    if d and d <= radius and canJoin(run, s, busy) and MayKnowName(src, s) then near[#near + 1] = { s = s, d = d } end
                end
            end
            table.sort(near, function(a, b) return a.d < b.d or (a.d == b.d and a.s < b.s) end)
            for _, e in ipairs(near) do
                if #out >= TEAM_ROWS then break end
                out[#out + 1] = e
            end
            return out
        end

        local function build()
            local options = {}
            for _, e in ipairs(rows()) do
                local where = (e.d and e.d <= radius) and ('%d m'):format(math.floor(e.d + 0.5)) or 'not near'
                local st = state[e.s]
                local tail = st == 'in' and ' · in' or st == 'waiting' and ' · asked…' or ''
                options[#options + 1] = { id = 'p' .. e.s, label = ('%s · %s%s'):format(nameFor(src, e.s), where, tail) }
            end
            if allowId and taken() < cap then
                options[#options + 1] = { id = 'byid', label = 'Enter a character ID…', input = { min = 1, max = 999999999, prefix = '#' } }
            end
            local slots, ready = { { name = 'You', state = 'you' } }, onJob()
            for _, s in ipairs(ctx:players()) do
                if s ~= src then slots[#slots + 1] = { name = nameFor(src, s), state = 'in' } end
            end
            for _, s in ipairs(order) do
                if state[s] and #slots < cap then
                    slots[#slots + 1] = { name = nameFor(src, s), state = state[s] }
                    if state[s] == 'in' then ready = ready + 1 end
                end
            end
            options[#options + 1] = { id = 'go', label = ('Let\'s go (%d of %d)'):format(ready, cap) }
            return { speaker = DirectorNodes.shownName(ctx, npcW), line = ctx:prop('line') or 'Who are you doing this with?',
                     options = options, team = { max = cap, slots = slots } }
        end

        -- What is on the page now, so it is sent again only when it changed.
        local shown
        local function sig(spec)
            local parts = {}
            for _, o in ipairs(spec.options) do parts[#parts + 1] = o.id .. '=' .. o.label end
            for _, s in ipairs(spec.team.slots) do parts[#parts + 1] = s.state .. ':' .. s.name end
            return table.concat(parts, '|')
        end
        local function refresh(force)
            if not live or going or not (run.convs and run.convs[src]) then return end
            local spec = build()
            local s = sig(spec)
            if not force and s == shown then return end
            shown = s
            DirectorTalk.converse(ctx, src, nil, spec)
        end

        local function invite(s)
            if run.test then
                NotifyPlayer(src, 'Test: a test is played alone, so nobody is asked', 'info')
                return
            end
            if inviteTooSoon(src, s) then NotifyPlayer(src, 'Wait a few seconds before inviting them again', 'error') return end
            if taken() >= cap then NotifyPlayer(src, 'The team is full', 'error') return end
            if not canJoin(run, s) then NotifyPlayer(src, ('%s cannot join now'):format(nameFor(src, s)), 'error') return end
            state[s] = 'waiting'
            local listed = false
            for _, x in ipairs(order) do if x == s then listed = true end end
            if not listed then order[#order + 1] = s end
            Director.event(run, node.id, 'asked', src, nameOf(s))
            CreateThread(function()
                -- On their PHONE like an incoming call when whip_phone runs and they carry one;
                -- on screen otherwise (server/ask.lua, via).
                local answered, yes = Ask.run(s, {
                    kind = 'confirm', title = 'Job invite',
                    message = ('%s wants you on a job: %s. You join when they are ready to go.'):format(starterFor(s), job),
                    yes = 'Accept', no = 'Decline',
                }, { timeoutMs = TEAM_INVITE_MS, tag = run.tag, via = 'phone', onOpen = function(t) token[s] = t end }, CORE)
                token[s] = nil
                if not live or going or state[s] ~= 'waiting' then return end   -- taken back, or the card went on
                if answered and yes == true and canJoin(run, s) then
                    state[s] = 'in'
                    NotifyPlayer(src, ('%s is in'):format(nameFor(src, s)), 'success')
                    NotifyPlayer(s, ('You\'re on %s\'s team: you join when they go'):format(starterFor(s)), 'info')
                else
                    state[s] = nil
                    -- Declined or unanswered: asking them again waits. Busy or gone is no ring.
                    if answered or yes == 'timeout' then noteInviteEnded(src, s) end
                    local why = answered and 'said no' or (ASK_WHY[yes] or 'cannot come')
                    NotifyPlayer(src, ('%s %s'):format(nameFor(src, s), why), 'info')
                end
                refresh(true)
            end)
        end

        --- The player with this character ID, if they can be asked; nil and why not.
        local function byCharId(n)
            n = math.tointeger(tonumber(n))
            if not n then return nil, 'Type a character ID' end
            local found = nil
            for s, p in pairs(Players) do
                if p.charId == n then found = s break end
            end
            if not found then return nil, ('Nobody with ID %d is in the city'):format(n) end
            if found == src then return nil, 'That is you' end
            if state[found] then return nil, ('%s is on the list already'):format(nameFor(src, found)) end
            if run.players[found] then return nil, ('%s is on the job already'):format(nameFor(src, found)) end
            if Players[found].isDead then return nil, ('%s is down'):format(nameFor(src, found)) end
            if not canJoin(run, found) then return nil, ('%s cannot join now'):format(nameFor(src, found)) end
            return found
        end

        --- Let's go: asks still out are taken back, and those who accepted join the run.
        local function letsGo()
            local joined = {}
            for _, s in ipairs(order) do
                if state[s] == 'waiting' then drop(s, false) end
            end
            for _, s in ipairs(order) do
                if state[s] == 'in' then
                    local ok, why = Director.addPlayer(run, s, starter)
                    if ok then joined[#joined + 1] = s
                    else NotifyPlayer(src, ('%s could not join: %s'):format(nameFor(src, s), tostring(why)), 'error') end
                    state[s] = nil
                end
            end
            Director.event(run, node.id, 'team ready', src, ('%d joined'):format(#joined))
            return 'ready', { source = src, team = joined }
        end

        ctx:on('conversation.choice', function(p)
            if p.runId ~= run.id or p.nodeId ~= node.id or p.source ~= src or going then return nil end
            if p.option == 'go' then
                going = true
                ctx:call(letsGo)
                return nil
            end
            if p.option == 'byid' then
                local s, why = byCharId(p.amount)
                if s then invite(s) else NotifyPlayer(src, why, 'error') end
            else
                local s = tonumber(tostring(p.option):match('^p(%d+)$'))
                if s then
                    if state[s] then drop(s, true) else invite(s) end
                end
            end
            refresh(true)   -- the page again (the capsule waits on it after every pick)
            return nil
        end)
        ctx:on('conversation.ended', function(p)
            if p.runId == run.id and p.nodeId == node.id and p.source == src and p.why ~= 'chose' and not going then
                return 'left', { source = src }
            end
        end)
        DirectorTalk.noAnswerAfter(ctx, h, tonumber(ctx:prop('seconds')) or 300)
        ctx:poll(1000, function() refresh(false) return nil end)

        DirectorTalk.speak(ctx, src, npcW, h, function()
            local spec = build()
            shown = sig(spec)
            return spec
        end, ctx:prop('talk'))
        ctx:onEnd(function(pin, why)
            live = false
            -- Not going after all: whoever was asked or in is let go, and told.
            for s, st in pairs(state) do
                drop(s, false)
                if st == 'in' then NotifyPlayer(s, ('%s is not going ahead with the job'):format(starterFor(s)), 'info') end
            end
            if why == 'answered' and pin == 'ready' then DirectorTalk.leave(ctx, src, 'ready') end
        end)
        return nil
    end,
})

-- ============================================
-- Player flags
-- ============================================

local function flagName(v)
    if not PlayerFlags.validName(v) then
        return 'a flag name is letters, digits and _ . - : (at most 64), starting with a letter'
    end
    return nil
end

--- A flag's value as a card writes it: true, a number, or text.
local function readValue(text)
    if text == nil or text == '' or text == 'true' or text == 'yes' then return true end
    local n = tonumber(text)
    if n then return n end
    return tostring(text)
end

local SET_TO = { 'on', 'off', 'to a value', 'add a number' }

define({
    type = 'flag.set', v = 1, category = 'player', title = 'Set Player Flag',
    desc = 'Remembers something about the player for good, across runs and restarts ("met the fence", "jobs done: 3").',
    outputs = { 'out' },
    props = {
        { key = 'flag', kind = 'text', label = 'Flag', required = true, maxLength = 64, check = flagName },
        { key = 'to', kind = 'select', label = 'Set it', options = SET_TO, default = 'on' },
        { key = 'value', kind = 'text', label = 'Value (to a value: text or a number; add: a number)', maxLength = 100 },
        { key = 'who', kind = 'players', label = 'For', default = 'this player' },
    },
    run = function(ctx)
        local run = ctx.run
        local name, to, value = ctx:prop('flag'), ctx:prop('to') or 'on', ctx:prop('value')
        local people = DirectorFields.playersOf(ctx, ctx:prop('who'))
        for _, s in ipairs(people) do
            local v
            if to == 'on' then v = true
            elseif to == 'off' then v = nil
            elseif to == 'to a value' then v = readValue(value)
            else
                local had = tonumber(Director.flag(run, s, name)) or 0
                v = had + (tonumber(value) or 1)
            end
            local ok, why = Director.setFlag(run, s, name, v)
            if not ok then ctx:log('flag %s for %s: %s', tostring(name), tostring(s), tostring(why)) end
        end
        return 'out'
    end,
})

local IF_OPS = { 'is set', 'is not set', 'is', 'at least', 'less than' }

define({
    type = 'flag.if', v = 1, category = 'flow', title = 'If Player Flag',
    desc = 'Goes one way or the other by a flag the player has (set by Set Player Flag, in this scenario or another).',
    outputs = { 'yes', 'no' },
    branch = true,
    props = {
        { key = 'flag', kind = 'text', label = 'Flag', required = true, maxLength = 64, check = flagName },
        { key = 'op', kind = 'select', label = 'It', options = IF_OPS, default = 'is set' },
        { key = 'value', kind = 'text', label = 'Value', maxLength = 100 },
    },
    run = function(ctx)
        local s = Director.playerOf(ctx)
        if not s then return 'no' end
        local have = Director.flag(ctx.run, s, ctx:prop('flag'))
        local op, want = ctx:prop('op') or 'is set', ctx:prop('value')
        local yes
        if op == 'is set' then yes = have ~= nil
        elseif op == 'is not set' then yes = have == nil
        elseif op == 'is' then
            if type(have) == 'number' then yes = tonumber(want) == have
            elseif have == true then yes = want == nil or want == '' or want == 'true' or want == 'yes'
            else yes = have ~= nil and tostring(have) == want end
        else
            local a, b = tonumber(have), tonumber(want)
            if not a or not b then yes = false
            elseif op == 'at least' then yes = a >= b
            else yes = a < b end
        end
        return yes and 'yes' or 'no'
    end,
})
