-- ============================================
-- Director — the vault cards: a press, a skill check, a bar, a door, a container, an area
-- ============================================
--
-- As in nodes_world.lua, each card calls the module function a resource would through its export, and
-- what it makes carries the run's tag, so the run's end (ReleaseTag) takes it all back:
--   Wait for Press    a prompt at a placed thing, for the run's players (RuntimePoints)
--   Interaction Menu  a prompt with a menu, on a placed thing, an NPC, a car, a pile or a container
--   Skill Check       the ring, run by the server (Skill.run), on the player who pressed
--   Progress          a bar the server times (TimedAction.progress): a drill, a hack
--   Lock / Unlock     the run holds a door (Doors.hold: memory only, saved door or a temporary one)
--   Create Container  a container that is never saved, with what it holds (Containers, persist = false)
--   Container Opened  when one of the run's players opens it
--   Player Entered / Left Area   around a placed thing, read on the server once a second
-- A Skill Check or a bar still on a player's screen when the run ends or is reset is taken down: they
-- are asked with the run's tag (skillcheck.lua / timed_action.lua join ReleaseTag).

local CORE = GetCurrentResourceName()

local define = DirectorKit.define
local vec = DirectorKit.vec3

--- Where a placed thing is: its World tab spot (a door's, a container's, a spot's).
local function spotOf(ctx, worldId)
    local w = ctx:place(worldId)
    return vec(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
end

local playerPos = DirectorKit.playerPos

-- ============================================
-- Wait for Press
-- ============================================

define({
    type = 'point.press', v = 1, category = 'world', title = 'Wait for Press',
    ui = { page = 'pressPreview' },   -- (its page shows the prompt as it looks: panels.js cardTry)
    prompt = { at = 'at' },           -- (its prompt: at the spot `at` names, whatever it is: spotOf)
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'Puts a prompt at a placed thing (a keypad, a safe) for the scenario\'s players, and goes on when one of them presses it.',
    outputs = { 'used', 'timeout' },
    labels = { used = 'Pressed', timeout = 'Too late' },
    latent = true,
    pinWhen = DirectorFields.TIMES_OUT,
    props = {
        { key = 'at', kind = 'world', label = 'Where (a placed thing)', required = true },
        { key = 'label', kind = 'text', label = 'Prompt', default = 'Use', maxLength = 40 },
        -- The prompt's disc: one of whip's glyphs (html/js/glyphs.js); none picked, the key (E).
        { key = 'icon', kind = 'glyph', label = 'Icon' },
        { key = 'reach', kind = 'number', label = 'From (metres)', default = 2, min = 1, max = 5 },
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 5, max = 86400 },
    },
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local at = spotOf(ctx, node.props.at)
        if not at then
            ctx:log('%s has no spot for the prompt', tostring(node.props.at))
            return nil
        end
        ctx:on('point.used', function(p)
            if p.runId == run.id and p.nodeId == node.id and ctx:isPlayer(p.source) then
                Director.event(run, node.id, 'pressed', p.source, ctx:prop('label'))
                return 'used', { source = p.source, useId = p.useId, from = { source = p.source, useId = p.useId, world = node.props.at } }
            end
        end)
        local icon = ctx:prop('icon')
        -- (Nobody in the run yet, switched on When it's switched on: anyone may press it, and the first to joins:
        -- main.lua Director.claim. The crew's from then, below.)
        local audience = nil
        if not run.open then audience = { people = ctx:players() } end
        local pointId, why = RuntimePoints.add(CORE, {
            at = { coords = at }, label = ctx:prop('label') or 'Use', reach = tonumber(ctx:prop('reach')) or 2,
            icon = type(icon) == 'string' and icon ~= '' and icon or nil,
            tag = ctx:tag(), audience = audience,
            onUse = function(source, use)
                if run.open then
                    local ok, cwhy = Director.claim(run, source)
                    if not ok then return false, cwhy end
                end
                DirectorRuntime.emit('point.used', { runId = run.id, nodeId = node.id, source = source, useId = use.useId })
            end,
        })
        if not pointId then ctx:log('could not put the prompt there: %s', tostring(why)) end
        -- The prompt is the crew's: one put in later sees it, one taken out does not.
        local crewKey = 'point:' .. tostring(pointId)
        if pointId then
            Director.followCrew(run, crewKey, function(players)
                return (RuntimePoints.update(CORE, pointId, { audience = { people = players } }))
            end)
        end
        ctx:onEnd(function()
            Director.followCrew(run, crewKey, nil)
            if pointId then RuntimePoints.remove(CORE, pointId) pointId = false end
        end)
        local seconds = tonumber(ctx:prop('seconds'))
        if seconds then ctx:after(seconds * 1000, 'timeout') end
        return nil
    end,
})

-- ============================================
-- Interaction Menu
-- ============================================
--
-- A prompt with a menu: up to eight choices, each at the top or under another (three deep at most,
-- six to a level). A choice with choices under it opens them; one with none is an outcome. It goes on
-- whatever the "On what" thing is: an NPC or a car rides along, a ground pile or a container gets it
-- just above, anything else at its spot (RuntimePoints' `at`, server/runtime_points.lua).

local MENU_ITEMS = 8
local UNDER = { 'top' }
for i = 1, MENU_ITEMS do UNDER[#UNDER + 1] = tostring(i) end

--- Is a choice there (text, or a variable's)?
local function hasText(v)
    return (type(v) == 'string' and v ~= '') or (type(v) == 'table' and v.var ~= nil)
end

--- What each choice is under: [i] = the index of the one above it, or 0 for the top. Only choices
--- with text.
local function parentsOf(props)
    local up = {}
    for i = 1, MENU_ITEMS do
        if hasText(props['item' .. i]) then
            local u = props['item' .. i .. 'Under']
            up[i] = (u == nil or u == 'top') and 0 or (tonumber(u) or -1)
        end
    end
    return up
end

--- Does a choice have choices under it (so it opens them, and is no outcome)?
local function opensMenu(props, i)
    for j, u in pairs(parentsOf(props)) do
        if u == i and j ~= i then return true end
    end
    return false
end

--- The menu's shape is one Check can stand behind: a message, or nil.
local function menuProblem(props)
    local up = parentsOf(props)
    local perLevel = {}
    for i, u in pairs(up) do
        if u ~= 0 then
            if u < 1 or u > MENU_ITEMS then return ('Choice %d is under something that is not a choice'):format(i) end
            if u == i then return ('Choice %d is under itself'):format(i) end
            if not up[u] then return ('Choice %d is under Choice %d, which is empty'):format(i, u) end
        end
        -- Up the chain: never round in a ring, never more than three deep.
        local depth, at, seen = 1, u, { [i] = true }
        while at ~= 0 do
            if seen[at] then return ('Choices %d and %d are under each other'):format(i, at) end
            seen[at] = true
            depth = depth + 1
            if depth > 3 then return ('Choice %d is more than three deep'):format(i) end
            at = up[at] or 0
        end
        perLevel[u] = (perLevel[u] or 0) + 1
        if perLevel[u] > 6 then
            return u == 0 and 'More than six choices at the top' or ('More than six choices under Choice %d'):format(u)
        end
    end
    return nil
end

-- How far above what it is on a menu's prompt sits: an NPC's middle 0.6 up, and RuntimePoints' own lift over a car, a
-- pile and a container. Its card's `prompt` says so to the editor, whose world builder shows it there.
local MENU_LIFT = { npc = 0.6, vehicle = RuntimePoints.LIFT.vehicle, groundItem = RuntimePoints.LIFT.ground,
                    container = RuntimePoints.LIFT.container }

--- Where a menu goes, as RuntimePoints reads `at`: on what the run made, else the placed spot.
local function menuAt(ctx, worldId)
    local w = ctx:place(worldId)
    local h = Director.handleOf(ctx.run, worldId)
    local kind = type(w) == 'table' and w.kind or nil
    if type(h) == 'table' then
        if kind == 'npc' and h.netId then return { netId = h.netId, offset = vector3(0.0, 0.0, MENU_LIFT.npc) } end
        if kind == 'vehicle' and h.vehicleId then return { vehicle = h.vehicleId } end
        if kind == 'groundItem' and h.groundId then return { ground = h.groundId } end
        if kind == 'container' and h.containerId then return { container = h.containerId } end
    end
    local c = spotOf(ctx, worldId)
    if not c then return nil end
    if kind == 'npc' or kind == 'vehicle' or kind == 'groundItem' or kind == 'container' then
        ctx:log('%s is not in the world: the menu is at its spot', tostring(worldId))
    end
    return { coords = c }
end

define({
    type = 'point.menu', v = 1, category = 'world', title = 'Interaction Menu',
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'A prompt with a menu on a placed thing, an NPC, a car or a container. Each choice is an output; choices can nest three deep.',
    outputs = { 'item1', 'item2', 'item3', 'item4', 'item5', 'item6', 'item7', 'item8', 'timeout' },
    labels = { item1 = 'Choice 1', item2 = 'Choice 2', item3 = 'Choice 3', item4 = 'Choice 4', item5 = 'Choice 5',
               item6 = 'Choice 6', item7 = 'Choice 7', item8 = 'Choice 8', timeout = 'Too late' },
    latent = true,
    ui = { face = 'menu' },   -- (its card's face: on what, the prompt, how many choices: html/js/director/canvas.js)
    -- (Its prompt, on what `at` names: riding an NPC or a car, over a pile or a container, else at the spot.)
    prompt = { at = 'at', menu = true, lift = MENU_LIFT, rides = { npc = true, vehicle = true } },
    pinWhen = DirectorFields.TIMES_OUT,
    pinText = (function()   -- (each choice's outcome is called by its words)
        local t = {}
        for i = 1, MENU_ITEMS do t['item' .. i] = { key = 'item' .. i, empty = '(empty choice)' } end
        return t
    end)(),
    -- An empty choice is not offered, and one that opens a menu is never chosen itself (the editor's pinsOf says the
    -- same: html/js/director/canvas.js).
    unusedPin = function(props, pin)
        local i = tonumber(pin:match('^item(%d)$'))
        if not i then return false end
        return not hasText(props[pin]) or opensMenu(props, i)
    end,
    pinName = function(props, pin)
        local v = props[pin]
        if pin:match('^item%d$') and type(v) == 'string' and v ~= '' then return ('the choice "%s"'):format(v) end
    end,
    check = function(props) return menuProblem(props) end,
    props = (function()
        -- `group`: the editor's head over that field and the ones after it.
        local list = {
            { key = 'at', kind = 'world', label = 'On what', required = true, group = 'The prompt' },
            { key = 'label', kind = 'text', label = 'Prompt', default = 'Use', maxLength = 40 },
        }
        for i = 1, MENU_ITEMS do
            list[#list + 1] = { key = 'item' .. i, kind = 'text', label = 'Choice ' .. i, required = i == 1, maxLength = 40,
                                group = i == 1 and 'Choices' or nil }
            list[#list + 1] = { key = 'item' .. i .. 'Under', kind = 'select', label = 'Under', options = UNDER, default = 'top',
                                ui = 'menuUnder' }   -- (picked from the choices above it: panels.js menuUnderField)
        end
        list[#list + 1] = { key = 'reach', kind = 'number', label = 'From (metres)', default = 2, min = 1, max = 5, group = 'Reach and time' }
        list[#list + 1] = { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 5, max = 86400 }
        return list
    end)(),
    run = function(ctx)
        local run, node = ctx.run, ctx.node
        local at = menuAt(ctx, node.props.at)
        if not at then
            ctx:log('%s has no spot for the menu', tostring(node.props.at))
            return nil
        end
        -- The menu, built from the choices: ids c1..c8, so a press names its path ('c2/c5').
        local up = parentsOf(node.props)
        local labels, byId = {}, {}
        for i in pairs(up) do
            local text = ctx:prop('item' .. i)
            labels[i] = text ~= nil and DirectorKit.cut(tostring(text), 40) or ('Choice ' .. i)
        end
        -- (Check refuses a ring and a fourth level; the depth stops one here all the same.)
        local function level(parent, depth)
            local out = {}
            if depth > 3 then return out end
            for i = 1, MENU_ITEMS do
                if up[i] == parent then
                    local kids = level(i, depth + 1)
                    out[#out + 1] = { id = 'c' .. i, label = labels[i], options = #kids > 0 and kids or nil }
                    if #kids == 0 then byId['c' .. i] = i end
                end
            end
            return out
        end
        local options = level(0, 1)
        if #options == 0 then
            ctx:log('the menu has no choices')
            return nil
        end
        ctx:on('point.used', function(p)
            if p.runId == run.id and p.nodeId == node.id and ctx:isPlayer(p.source) then
                local i = byId[type(p.path) == 'string' and p.path:match('([^/]+)$') or '']
                if not i then return nil end
                Director.event(run, node.id, 'chose', p.source, labels[i])
                return 'item' .. i, { source = p.source, useId = p.useId, from = { source = p.source, useId = p.useId, world = node.props.at } }
            end
        end)
        -- (Nobody in the run yet: anyone's, the first to choose joins, as Wait for Press.)
        local audience = nil
        if not run.open then audience = { people = ctx:players() } end
        local pointId, why = RuntimePoints.add(CORE, {
            at = at, label = ctx:prop('label') or 'Use', reach = tonumber(ctx:prop('reach')) or 2,
            tag = ctx:tag(), audience = audience, options = options,
            onUse = function(source, use)
                if run.open then
                    local ok, cwhy = Director.claim(run, source)
                    if not ok then return false, cwhy end
                end
                DirectorRuntime.emit('point.used', { runId = run.id, nodeId = node.id, source = source, useId = use.useId, path = use.path })
            end,
        })
        if not pointId then ctx:log('could not put the menu there: %s', tostring(why)) end
        -- The menu is the crew's (Wait for Press's rule).
        local crewKey = 'point:' .. tostring(pointId)
        if pointId then
            Director.followCrew(run, crewKey, function(players)
                return (RuntimePoints.update(CORE, pointId, { audience = { people = players } }))
            end)
        end
        ctx:onEnd(function()
            Director.followCrew(run, crewKey, nil)
            if pointId then RuntimePoints.remove(CORE, pointId) pointId = false end
        end)
        local seconds = tonumber(ctx:prop('seconds'))
        if seconds then ctx:after(seconds * 1000, 'timeout') end
        return nil
    end,
})

-- ============================================
-- Skill Check and Progress
-- ============================================

--- The difficulties the ring has (Config.SkillCheckDifficulty), easiest first (shared/skillcheck.lua SortSkillLevels).
local function difficulties()
    local out = {}
    for k in pairs(type(Config) == 'table' and Config.SkillCheckDifficulty or {}) do out[#out + 1] = k end
    SortSkillLevels(out)
    if #out == 0 then out = { 'easy', 'medium', 'hard' } end
    return out
end

--- THE GAMES (server/skillcheck.lua): the ring, and every game another resource adds (whip_phone's, on the
--- phone). One live list the Game field reads: the editor, Check and the run all read it as it is now, and it
--- changes as resources start and stop.
local GAME_OPTIONS = { 'ring' }
local GAME_LABELS = { ring = 'The ring' }
-- How hard: the ring's difficulties, then every game's own level names (a game's levels are its own: Check says when the
-- one picked is not the picked game's). One live list, as the games'.
local DIFF_OPTIONS = difficulties()

local function gamesChanged()
    for i = #GAME_OPTIONS, 2, -1 do GAME_OPTIONS[i] = nil end
    for k in pairs(GAME_LABELS) do if k ~= 'ring' then GAME_LABELS[k] = nil end end
    for i = #DIFF_OPTIONS, 1, -1 do DIFF_OPTIONS[i] = nil end
    local seen = {}
    for _, d in ipairs(difficulties()) do DIFF_OPTIONS[#DIFF_OPTIONS + 1] = d seen[d] = true end
    for _, g in ipairs(SkillGames.list()) do
        GAME_OPTIONS[#GAME_OPTIONS + 1] = g.id
        GAME_LABELS[g.id] = g.label
        for _, d in ipairs(g.levels or {}) do
            if type(d) == 'string' and not seen[d] then DIFF_OPTIONS[#DIFF_OPTIONS + 1] = d seen[d] = true end
        end
    end
    -- Open editors ask for the cards again (the field's choices moved).
    DirectorNodes.rev = DirectorNodes.rev + 1
    Director.catalogueChanged()
end
SkillGames.onChange(gamesChanged)

--- The game a card names: 'ring', or another resource's id (nil: the ring).
local function gameOf(props)
    local g = type(props) == 'table' and props.game or nil
    return (type(g) == 'string' and g ~= '') and g or 'ring'
end

define({
    type = 'player.skillCheck', v = 1, category = 'player', title = 'Skill Check',
    ui = { page = 'skillTry' },   -- (its page has Play skill check)
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'A skill check for the player who pressed: the ring, or a game on their phone. Running out of time is a miss.',
    help = 'Couldn\'t start: a phone game, and they have no phone.',
    outputs = { 'passed', 'failed', 'timeout', 'notStarted' },
    labels = { failed = 'Missed', timeout = 'No answer', notStarted = 'Couldn\'t start' },
    -- No answer: never now (Josh, 10 Nov 2026: "how do you no answer a skill check?"). A player's own clock running
    -- out is a miss already (the ring's, a phone game's); a game that never answers the server (it froze, or lost
    -- it) is a miss too, below. Kept only for the wires already drawn from it: they show, and Check says they can
    -- never happen. Couldn't start: only for another resource's game (the ring always starts), red as Missed is.
    pinWhen = { timeout = false, notStarted = { key = 'game', isnt = 'ring' } },
    bad = { 'notStarted' },
    latent = true, yields = true, retrigger = 'ignore',
    -- The ring always starts, and so does a game that needs nothing: no Couldn't start to wire.
    unusedPin = function(props, pin)
        if pin ~= 'notStarted' then return false end
        local g = gameOf(props)
        if g == 'ring' then return true end
        local game = SkillGames.get(g)
        return game ~= nil and not game.needs
    end,
    props = {
        -- (loose: a saved game whose resource has not started yet is kept, with a warning from check below.)
        { key = 'game', kind = 'select', label = 'Game', options = GAME_OPTIONS, optionLabels = GAME_LABELS, default = 'ring', loose = true },
        -- (loose: the choices move with the games, and Check, below, says when one does not fit the game picked.)
        { key = 'difficulty', kind = 'select', label = 'How hard', options = DIFF_OPTIONS, default = 'hard', loose = true },
        { key = 'at', kind = 'world', label = 'Must stay near (optional)' },
        { key = 'range', kind = 'number', label = 'Within (metres)', default = 3, min = 1, max = 25 },
    },
    -- A game's levels are its own: the one picked must be one of them.
    check = function(props)
        local g = gameOf(props)
        if g == 'ring' then
            local diff = type(props.difficulty) == 'string' and props.difficulty or 'hard'
            local ring = type(Config) == 'table' and type(Config.SkillCheckDifficulty) == 'table' and Config.SkillCheckDifficulty or {}
            if next(ring) and not ring[diff] then
                return ('the ring has no "%s" level (it has %s)'):format(diff, table.concat(difficulties(), ', '))
            end
            return nil
        end
        local game = SkillGames.get(g)
        if not game then
            return ('the skill check game "%s" is not on the server now (is the resource that adds it running?): '
                .. 'until it is, this card goes on from Couldn\'t start'):format(g), 'warning'
        end
        local diff = type(props.difficulty) == 'string' and props.difficulty or 'hard'
        if not game.levels[diff] then
            return ('%s has no "%s" level (it has %s)'):format(game.label, diff, table.concat(game.levelNames, ', '))
        end
        return nil
    end,
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'failed' end
        local diff = ctx:prop('difficulty') or 'hard'
        local at = ctx.node.props.at and spotOf(ctx, ctx.node.props.at) or nil
        local range = tonumber(ctx:prop('range')) or 3
        local data = { source = src }
        -- The game as saved: one whose resource is not running now is never quietly swapped for the ring.
        local game = gameOf(ctx.node.props)
        if game ~= 'ring' and not SkillGames.get(game) then
            ctx:log('skill check game %s is not on the server (is the resource that adds it running?)', game)
            return 'notStarted', data
        end
        ctx:call(function()
            -- Its own clock is its timeout (Skill.run always answers); with the run's tag, the run's end
            -- or a Reset takes it off their screen.
            local ok, why = Skill.run(src, diff, { tag = ctx:tag(), game = game ~= 'ring' and game or nil }, CORE)
            if not ctx:isPlayer(src) then return 'failed', data end   -- they left the run meanwhile
            -- Nothing started (the phone's games and no phone: they were told). Not a fail.
            if why == 'not started' or why == 'unavailable' then
                ctx:log('%s could not start %s (%s)', tostring(src), game, tostring(why))
                return 'notStarted', data
            end
            if ok and at and not IsPlayerNear(src, at.x, at.y, at.z, range) then
                ctx:log('%s passed, but walked away from it', tostring(src))
                return 'failed', data
            end
            if ok then
                Director.event(run, ctx.node.id, 'passed a skill check', src, diff)
                return 'passed', data
            end
            -- (Their game never answered: a miss, as their clock running out is. No answer is never taken: pinWhen.)
            if why == 'timeout' then ctx:log('%s\'s game never answered the skill check: a miss', tostring(src)) end
            Director.event(run, ctx.node.id, 'missed a skill check', src, tostring(why))
            return 'failed', data
        end)
        return nil
    end,
})

--- An emote's animation for a bar: { dict, clip } or { scenario }, or nil (nodes.lua).
local emoteAnim = DirectorNodes.emoteAnim

define({
    type = 'player.progress', v = 1, category = 'player', title = 'Progress',
    ui = { page = 'progressTry' },   -- (its page has Simulate)
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'A bar on the player\'s screen that the server times (a drill, a hack): done only if it really ran its length.',
    outputs = { 'done', 'stopped', 'timeout' },
    labels = { stopped = 'Stopped', timeout = 'No answer' },
    latent = true, yields = true, retrigger = 'ignore',
    props = {
        { key = 'label', kind = 'text', label = 'Says', default = 'Working...', maxLength = 60 },
        { key = 'seconds', kind = 'duration', label = 'How long (seconds)', default = 8, min = 1, max = 120 },
        { key = 'at', kind = 'world', label = 'Must stay near (optional)' },
        { key = 'range', kind = 'number', label = 'Within (metres)', default = 3, min = 1, max = 25 },
        { key = 'emote', kind = 'emote', label = 'Emote while it runs (/e name)', maxLength = 40,
          check = function(v)
              if v == '' or emoteAnim(v) then return nil end
              return ('"%s" is not an emote with an animation (see /e)'):format(tostring(v))
          end },
        { key = 'canCancel', kind = 'bool', label = 'They may stop it (X)', default = true },
    },
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'stopped' end
        local seconds = math.max(1, math.min(120, tonumber(ctx:prop('seconds')) or 8))
        local opts = { label = ctx:prop('label') or 'Working...', duration = math.floor(seconds * 1000),
                       canCancel = ctx:prop('canCancel') ~= false, anim = emoteAnim(ctx:prop('emote')), tag = ctx:tag() }
        local at = ctx.node.props.at and spotOf(ctx, ctx.node.props.at) or nil
        if at then opts.near = { coords = at, range = tonumber(ctx:prop('range')) or 3 } end
        local data = { source = src }
        ctx:call(function()
            -- The bar's own clock is its timeout (duration + 15 s at the most); the run's tag takes it
            -- off their screen when the run ends or is reset.
            local done, why = TimedAction.progress(src, opts, CORE)
            if not ctx:isPlayer(src) then return 'stopped', data end
            if done then
                Director.event(run, ctx.node.id, 'finished', src, opts.label)
                return 'done', data
            end
            if why == 'timeout' then return 'timeout', data end
            return 'stopped', data
        end)
        return nil
    end,
})

-- ============================================
-- Doors
-- ============================================

local DOOR_ACTION = { 'unlock', 'lock' }
local DOOR_WHO = { 'nobody (only the cards)', 'the run\'s players' }

define({
    type = 'door.set', v = 2, category = 'world', title = 'Lock / Unlock Door',
    ui = { page = 'doorLook' },   -- (its page has Look at the door)
    desc = 'Locks or unlocks the doors picked from the World tab for the scenario. Each goes back to how it was when the scenario ends.',
    outputs = { 'out', 'failed' },
    labels = { out = 'Done' },
    upgrade = function(props) return DirectorNodes.toList(props, 'door') end,
    props = {
        DirectorNodes.thingsField('door', 'door', 'Doors'),
        { key = 'action', kind = 'select', label = 'Do', options = DOOR_ACTION, default = 'unlock' },
        { key = 'who', kind = 'select', label = 'Who may press them from now on', options = DOOR_WHO, default = DOOR_WHO[1],
          optionLabels = { [DOOR_WHO[2]] = 'the scenario\'s players' } },
    },
    run = function(ctx)
        local run = ctx.run
        local lock = ctx:prop('action') == 'lock'
        local players = ctx:prop('who') == DOOR_WHO[2]
        -- Each door: held for the run (its end gives it back as it was), then locked or unlocked. Failed: none could be.
        local done = 0
        for _, worldId in ipairs(DirectorNodes.things(ctx, 'door')) do
            local h = ctx:handle(worldId)
            local doorId = type(h) == 'table' and h.doorId or nil
            if not doorId then
                local w = ctx:place(worldId)
                local def = type(w) == 'table' and type(w.def) == 'table' and w.def or {}
                local at = vec(def.coords)
                if not at or def.model == nil then
                    ctx:log('%s has no door picked yet', tostring(worldId))
                else
                    local id, how = Doors.hold(CORE, { model = def.model, x = at.x, y = at.y, z = at.z,
                        heading = tonumber(def.coords.heading) or 0.0, label = w.label }, { tag = ctx:tag() })
                    if not id then
                        ctx:log('%s: %s', tostring(worldId), tostring(how))
                    else
                        doorId = id
                        ctx:remember(worldId, { doorId = id, made = how == 'made' })
                    end
                end
            end
            if doorId then
                local ok, why = Doors.setLocked(doorId, lock, { cause = 'run' })
                if not ok then
                    ctx:log('%s: %s', tostring(worldId), tostring(why))
                else
                    done = done + 1
                    Doors.setHoldAccess(CORE, doorId, players and { charIds = Director.charIdsOf(run) } or nil)
                    -- "The run's players" is the crew as it is: one put in later may press it, one taken out may not.
                    local held = doorId
                    Director.followCrew(run, 'door:' .. tostring(held), players and function(_, charIds)
                        return (Doors.setHoldAccess(CORE, held, { charIds = charIds }))
                    end or nil)
                    Director.event(run, ctx.node.id, lock and 'locked' or 'unlocked', nil, ctx:place(worldId).label)
                end
            end
        end
        return done > 0 and 'out' or 'failed'
    end,
})

-- ============================================
-- Containers
-- ============================================

--- What a container's slots hold this time (Create Container's loot, laid out on its page): each slot rolls once,
--- one of what may be in it by its chance, or nothing with what is left of 100%. Answers { { slot, item, amount } }.
--- A slot past the container's own is passed over (`log` says so); an amount is kept to what one slot holds.
local function rollLoot(loot, slots, log)
    local bySlot, order = {}, {}
    for _, e in ipairs(type(loot) == 'table' and loot or {}) do
        local s = type(e) == 'table' and math.tointeger(tonumber(e.slot))
        if s then
            if not bySlot[s] then bySlot[s] = {}; order[#order + 1] = s end
            bySlot[s][#bySlot[s] + 1] = e
        end
    end
    table.sort(order)
    local out = {}
    for _, s in ipairs(order) do
        if s > slots then
            log(('slot %d is past its %d slots: left out'):format(s, slots))
        else
            local r, upTo = math.random(1, 100), 0
            for _, e in ipairs(bySlot[s]) do
                upTo = upTo + (tonumber(e.chance) or 100)
                if r <= upTo then
                    local idef = Config.Items and Config.Items[e.item]
                    if idef then
                        local mn = math.max(1, math.tointeger(tonumber(e.min or 1)) or 1)
                        local mx = math.max(mn, math.tointeger(tonumber(e.max or mn)) or mn)
                        local perSlot = (idef.stack and idef.maxStack) and idef.maxStack or 1
                        out[#out + 1] = { slot = s, item = e.item, amount = math.min(math.random(mn, mx), perSlot) }
                    else
                        log(('slot %d: %s is not an item on this server'):format(s, tostring(e.item)))
                    end
                    break
                end
            end
        end
    end
    return out
end

define({
    type = 'container.create', v = 1, category = 'world', title = 'Create Container', givesItems = true, giveUp = 15,
    ui = { page = 'loot' },   -- (its page is its slots, each with their chances: panels.js lootEditor)
    desc = 'Makes the container from the World tab with what it holds. Gone when the scenario ends; what players take is theirs.',
    outputs = { 'made', 'failed', 'timeout' },
    latent = true, yields = true, heavy = true,
    props = {
        { key = 'container', kind = 'world', worldKind = 'container', label = 'Container', required = true },
        -- What its slots may hold, each with its chance, laid out on the card's page (panels.js lootEditor).
        { key = 'loot', kind = 'loot', label = 'What it holds' },
    },
    run = function(ctx)
        local run, worldId = ctx.run, ctx.node.props.container
        if ctx:handle(worldId) then
            ctx:log('%s: this run already made it', tostring(worldId))
            return 'failed'
        end
        local w = ctx:place(worldId)
        local def = type(w) == 'table' and type(w.def) == 'table' and w.def or {}
        local at = vec(def.coords)
        if not at then
            ctx:log('%s is not placed', tostring(worldId))
            return 'failed'
        end
        local slotCount = math.max(1, math.min(100, math.floor(tonumber(def.slots) or 10)))
        local loot = ctx.node.props.loot
        local items
        if type(loot) == 'table' and #loot > 0 then
            -- Its slots, rolled: each as a real run's (theirs once taken, tagged only when the run's own cards look for
            -- it), or a test's (stamped, so its end takes it back from whoever has it). A marked one with the item's own
            -- data, as Drop Item gives it (effects.lua).
            items = {}
            for _, got in ipairs(rollLoot(loot, slotCount, function(t) ctx:log('%s', t) end)) do
                local md = nil
                if DirectorEffects.markField(run, got.item) then
                    md = DirectorEffects.stamper(run, got.item, { dworld = worldId })(DirectorEffects.fresh(got.item))
                end
                items[#items + 1] = { item = got.item, amount = got.amount, slot = got.slot, metadata = md }
            end
        end
        local made
        ctx:call(function()
            local c, why = Containers.create({
                persist = false, tag = ctx:tag(), name = (type(w.label) == 'string' and w.label ~= '') and w.label or 'Container',
                x = at.x, y = at.y, z = at.z, heading = tonumber(def.coords.heading) or 0.0,
                slots = math.max(1, math.min(100, math.floor(tonumber(def.slots) or 10))),
                maxWeight = math.max(1, tonumber(def.maxWeight) or 100.0),
                prop = (type(def.prop) == 'string' and def.prop ~= '') and def.prop or false,
                interior = def.interior == true,   -- placed inside an MLO: its prop waits for it
                items = items, requirements = { charIds = Director.charIdsOf(run) },
                reason = Director.reason(run),
            }, CORE)
            if not c then
                ctx:log('%s could not be made: %s', tostring(worldId), tostring(why))
                return 'failed'
            end
            made = c.containerId
            ctx:remember(worldId, { containerId = c.containerId })
            -- For the crew as it is: one put in later opens it, one taken out cannot (the vault's cash).
            local cid = c.containerId
            Director.followCrew(run, 'container:' .. tostring(cid), function(_, charIds)
                return (Containers.update(cid, { requirements = { charIds = charIds } }))
            end)
            Director.event(run, ctx.node.id, 'made', nil, w.label)
            return 'made'
        end, {
            late = function() if made then Containers.delete(made) end end,
        })        return nil
    end,
})

define({
    type = 'container.opened', v = 2, category = 'events', title = 'Container Opened',
    desc = 'When a player in the scenario opens one of the containers picked.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'container') end,
    props = {
        DirectorNodes.thingsField('container', 'container', 'Containers'),
    },
    event = {
        name = 'container.opened', once = true,
        filter = function(ctx, p)
            if type(p) ~= 'table' or not ctx:isPlayer(p.source) then return nil end
            local mine = false
            for _, wid in ipairs(DirectorNodes.things(ctx, 'container')) do
                local h = ctx:handle(wid)
                if type(h) == 'table' and h.containerId == p.containerId then mine = true break end
            end
            if not mine then return nil end
            -- The server's own word that they have it open now (any resource could fire the event).
            if not Stores.isViewer(p.source, 'container:' .. tostring(p.containerId)) then return nil end
            Director.event(ctx.run, ctx.node.id, 'opened', p.source)
            return 'out', { source = p.source }
        end,
    },
})

-- ============================================
-- Areas
-- ============================================

define({
    type = 'area.entered', v = 1, category = 'world', title = 'Player Arrives',
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'Waits until a player in the scenario (or every player in it) gets within a distance of a placed thing.',
    outputs = { 'entered', 'timeout' },
    labels = { timeout = 'Too late' },
    latent = true,
    pinWhen = DirectorFields.TIMES_OUT,
    props = {
        { key = 'at', kind = 'world', label = 'Around (a placed thing)', required = true },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 15, min = 1, max = 500, bySpot = 'at' },
        DirectorNodes.anyAllField('Who', nil, { bySpot = 'at' }),
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 5, max = 86400 },
    },
    run = function(ctx)
        local at = spotOf(ctx, ctx.node.props.at)
        if not at then
            ctx:log('%s has no spot', tostring(ctx.node.props.at))
            return nil
        end
        local radius = tonumber(ctx:prop('radius')) or 15
        local all = DirectorNodes.wantsAll(ctx)
        -- (A spot with a marker says how near and who: server/director/spots.lua.)
        local spot = DirectorSpots.watch(ctx, ctx:place(ctx.node.props.at))
        local told = {}   -- (one who may not join is told why once)
        ctx:poll(1000, function()
            -- Nobody in the run yet (switched on, When it's switched on): the first player to come near joins it
            -- (main.lua Director.claim), nearest first; with a marker, its shape and its car rule (Before a run there is no
            -- crew: All of them is One of them, as an area start reads it).
            if ctx.run.open then
                local everyone = Director.eligibleNow()
                local list = spot and DirectorSpots.startersIn(spot, everyone) or Director.playersNear(at, radius, everyone)
                for _, e in ipairs(list) do
                    local ok, why = Director.claim(ctx.run, e.src)
                    if ok then
                        Director.event(ctx.run, ctx.node.id, 'arrived', e.src)
                        return 'entered', { source = e.src }
                    end
                    if not told[e.src] then
                        told[e.src] = true
                        NotifyPlayer(e.src, why or 'You cannot do this now', 'info')
                    end
                end
                return nil
            end
            local ok, src = DirectorSpots.arrived(ctx, spot, at, radius, all)
            if not ok then return nil end
            Director.event(ctx.run, ctx.node.id, 'arrived', src)
            return 'entered', { source = src }
        end)
        local seconds = tonumber(ctx:prop('seconds'))
        if seconds then ctx:after(seconds * 1000, 'timeout') end
        return nil
    end,
})

define({
    type = 'area.left', v = 1, category = 'world', title = 'Player Leaves',
    once = false,   -- (the run waits here for a player: never Only Once, nodes.lua)
    desc = 'When a player who was near a placed thing goes further than the distance (or every player has).',
    outputs = { 'left', 'timeout' },
    labels = { timeout = 'Too late' },
    latent = true,
    pinWhen = DirectorFields.TIMES_OUT,
    props = {
        { key = 'at', kind = 'world', label = 'Around (a placed thing)', required = true },
        { key = 'radius', kind = 'number', label = 'Within (metres)', default = 25, min = 1, max = 500, bySpot = 'at' },
        DirectorNodes.anyAllField('Who'),
        { key = 'seconds', kind = 'duration', label = 'Gives up after (seconds; empty: never)', min = 5, max = 86400 },
    },
    run = function(ctx)
        local at = spotOf(ctx, ctx.node.props.at)
        if not at then
            ctx:log('%s has no spot', tostring(ctx.node.props.at))
            return nil
        end
        local radius = tonumber(ctx:prop('radius')) or 25
        local all = DirectorNodes.wantsAll(ctx)
        -- (A marker's shape: out of it is gone. Who is still this card's.)
        local spot = DirectorSpots.watch(ctx, ctx:place(ctx.node.props.at))
        local wasIn = {}
        local function look()
            local outside, last, seen = 0, nil, 0
            for _, s in ipairs(ctx:players()) do
                local p = playerPos(s)
                if p then
                    if DirectorSpots.near(spot, p, at, radius) then
                        wasIn[s] = true
                    elseif wasIn[s] then
                        outside = outside + 1
                        last = s
                    end
                end
                if wasIn[s] then seen = seen + 1 end
            end
            if outside == 0 then return nil end
            -- All of them: everyone who was ever inside is out, and nobody is still in.
            if all and outside < seen then return nil end
            Director.event(ctx.run, ctx.node.id, 'got away', last)
            return 'left', { source = last }
        end
        look()   -- who is inside as it starts
        ctx:poll(1000, look)
        local seconds = tonumber(ctx:prop('seconds'))
        if seconds then ctx:after(seconds * 1000, 'timeout') end
        return nil
    end,
})
