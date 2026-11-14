-- ============================================
-- Systems — cards for a player's screen and map
-- ============================================
--
-- What a system puts in front of a player: the skill ring and a progress bar (both timed by the
-- server: a pass or a full bar is one they really played), the objective band, a marker on the map,
-- their waypoint. Everything shown is made under the system's tag, so switching the system off takes
-- it away (the bar and the ring come off their screen; the band and the markers go). In a Test, what
-- would be shown to everyone is shown to the tester alone.

local C = SystemCards
local CORE = 'whip_core'

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

--- At most this many map markers per system at once (server load, not money).
local MAX_MARKERS = 64

--- A value as words for the screen (Notify's rule): a number as digits, a yes/no as yes or no.
local function words(t)
    if type(t) == 'number' then return (math.floor(t) == t) and ('%d'):format(t) or ('%.2f'):format(t) end
    if type(t) == 'boolean' then return t and 'yes' or 'no' end
    if type(t) ~= 'string' then return '' end
    return t
end

--- The wired-in player and their server id, or nil (never this pulse's player in their place).
local function whoOf(ctx)
    local who = ctx:input('player')
    if not who then return nil end
    return who, ctx:source(who)
end

--- THIS pulse's own player and their server id, or nil. The ring and the bar hold a player's
--- controls for their length, so without a power they are only ever this pulse's player's (wired to
--- Players in Area, a bar would freeze everyone in a zone).
local function ownOf(ctx)
    local me = ctx:player()
    if not me then return nil end
    return me, ctx:source(me)
end

-- ============================================
-- The ring and the bar (server-timed)
-- ============================================

local function difficulties()
    local out = {}
    for k in pairs(type(Config) == 'table' and Config.SkillCheckDifficulty or {}) do out[#out + 1] = k end
    table.sort(out)
    if #out == 0 then out = { 'easy', 'hard', 'medium' } end
    return out
end

define({
    type = 'screen.skill', category = 'players', kind = 'wait', title = 'Skill Check', api = 'SkillCheck',
    desc = 'The ring on THIS pulse\'s player\'s screen (a lock, a hack), timed by the server: Passed only if they really played it. No Answer if they were busy with another screen, down, or left.',
    props = { { key = 'difficulty', kind = 'select', label = 'How hard', options = difficulties(), default = 'medium' } },
    outputs = { 'passed', 'failed', 'noAnswer' },
    labels = { passed = 'Passed', failed = 'Missed', noAnswer = 'No answer' },
    values = { outputs = { { key = 'why', type = 'text', label = 'Why no answer' } } },
    run = function(ctx)
        local who, src = ownOf(ctx)
        if not src then return 'noAnswer', { why = 'not here' } end
        local diff, tag = ctx:prop('difficulty'), ctx:tag()
        ctx:call(function()
            if not ctx:source(who) then return 'noAnswer', { why = 'not here' } end
            -- Its own clock is its timeout (60 s at the most); the system's tag takes the ring down.
            local ok, why = Skill.run(src, diff, { tag = tag }, CORE)
            if ok then return 'passed' end
            if why == 'failed' or why == 'too fast' then return 'failed' end
            return 'noAnswer', { why = tostring(why) }
        end)
        ctx:after(65000, 'noAnswer')
        return nil
    end,
})

--- An emote's animation for a bar: { dict, clip } or { scenario }, or nil (the Director's rule).
local function emoteAnim(cmd)
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
C.emoteAnim = emoteAnim

define({
    type = 'screen.progress', category = 'players', kind = 'wait', title = 'Progress Bar', api = 'Progress',
    desc = 'A bar on THIS pulse\'s player\'s screen that the server times (a drill, a wash): Done only if it really ran its length. With a place, they must stay near it. Stopped if they cancelled or walked off.',
    props = { { key = 'label', kind = 'text', label = 'Says', default = 'Working...', maxLength = 60 },
              { key = 'seconds', kind = 'number', label = 'How long (seconds)', default = 8, min = 1, max = 120 },
              { key = 'canCancel', kind = 'bool', label = 'They may stop it (X)', default = true },
              { key = 'emote', kind = 'text', label = 'Emote while it runs (/e name)', maxLength = 40 } },
    outputs = { 'done', 'stopped', 'noAnswer' },
    labels = { done = 'Done', stopped = 'Stopped', noAnswer = 'No answer' },
    values = { inputs = { { key = 'near', type = 'vector', label = 'Stay near (optional)', optional = true },
                          { key = 'range', type = 'number', label = 'Within (m)', default = 3 } },
               outputs = { { key = 'why', type = 'text', label = 'Why not done' } } },
    run = function(ctx)
        local who, src = ownOf(ctx)
        if not src then return 'noAnswer', { why = 'not here' } end
        local seconds = math.max(1, math.min(120, tonumber(ctx:prop('seconds')) or 8))
        local opts = { label = ctx:prop('label') or 'Working...', duration = math.floor(seconds * 1000),
                       canCancel = ctx:prop('canCancel') ~= false, anim = emoteAnim(ctx:prop('emote')), tag = ctx:tag() }
        local near = ctx:input('near')
        if near then opts.near = { coords = near, range = math.max(1, math.min(25, ctx:need('range'))) } end
        ctx:call(function()
            if not ctx:source(who) then return 'noAnswer', { why = 'not here' } end
            local done, why = TimedAction.progress(src, opts, CORE)
            if done then return 'done' end
            if why == 'cancelled' or why == 'too far' or why == 'too fast' then return 'stopped', { why = tostring(why) } end
            return 'noAnswer', { why = tostring(why) }
        end)
        -- The bar's own clock answers (its length and 15 s at the most); this only frees a stuck pulse.
        ctx:after(opts.duration + 20000, 'noAnswer')
        return nil
    end,
})

-- ============================================
-- The objective band
-- ============================================

define({
    type = 'screen.text', category = 'players', kind = 'action', title = 'Show Objective', api = 'ShowPlayerText',
    desc = 'The band across a player\'s screen ("Drive to the car wash"), until it is hidden or something else takes its place. With seconds, a countdown runs in it.',
    props = { { key = 'position', kind = 'select', label = 'Where', options = { 'bottom', 'top' }, default = 'bottom' },
              { key = 'seconds', kind = 'number', label = 'Countdown (seconds, 0: none)', default = 0, min = 0, max = 3600 } },
    outputs = { 'out', 'gone' },
    labels = { gone = 'Not here' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'text', type = 'any', label = 'Text' } } },
    run = function(ctx)
        local _, src = whoOf(ctx)
        if not src then return 'gone' end
        local secs = tonumber(ctx:prop('seconds')) or 0
        local ok, why = PlayerText.show(CORE, src, words(ctx:need('text')):sub(1, 200),
            { position = ctx:prop('position'), countdown = secs > 0 and math.min(3600, secs) or nil, tag = ctx:tag() })
        if not ok then ctx:log('the objective could not be shown: %s', tostring(why)) return 'gone' end
        return 'out'
    end,
})

define({
    type = 'screen.hideText', category = 'players', kind = 'action', title = 'Hide Objective', api = 'HidePlayerText',
    desc = 'Takes this system\'s objective band off a player\'s screen. One something else put up is left alone.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } } },
    run = function(ctx)
        local _, src = whoOf(ctx)
        local cur = src and PlayerText.get(src)
        -- Ours by its tag: every system (and the Director) shows the band as whip_core.
        if cur and cur.owner == CORE and cur.tag == ctx:tag() then PlayerText.hide(CORE, src) end
        return 'out'
    end,
})

-- ============================================
-- The map
-- ============================================

--- A marker's id: the system's own name for it (C.nameFor: `s_<short id>_<name>`, a Test's its own),
--- per player when it is one player's (by character). Nothing can name another system's marker, or
--- the Director's, and a Test's never moves or takes down the live system's.
local function markerId(ctx, src)
    local id = C.nameFor(ctx, ctx:prop('name') or 'marker')
    if src then
        local p = Players[src]
        id = id .. '_' .. tostring(p and p.charId or src)
    end
    return id
end

define({
    type = 'map.blip', category = 'world', kind = 'action', title = 'Show Map Marker', api = 'ShowBlip', makes = 'blip',
    desc = 'A marker on the map at a place: for one player (wire them in) or, left empty, for everyone. The same name again moves it. Switching the system off takes its markers away.',
    props = { { key = 'name', kind = 'text', label = 'Name (this system\'s own)', default = 'marker', maxLength = 24 },
              { key = 'label', kind = 'text', label = 'On the map', default = 'Here', maxLength = 40 },
              { key = 'sprite', kind = 'number', label = 'Icon (GTA blip number)', default = 1, min = 0, max = 1000 },
              { key = 'color', kind = 'number', label = 'Colour (GTA blip colour)', default = 5, min = 0, max = 85 },
              { key = 'radius', kind = 'number', label = 'Area radius (m, 0: a point)', default = 0, min = 0, max = 5000 },
              { key = 'route', kind = 'bool', label = 'GPS route to it', default = false },
              { key = 'shortRange', kind = 'bool', label = 'Only on the radar when near', default = false } },
    outputs = { 'out', 'failed' },
    labels = { failed = 'Could not' },
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' },
                          { key = 'player', type = 'player', label = 'For (everyone if empty)', optional = true } } },
    run = function(ctx)
        local at = ctx:need('place')
        local who, src = ctx:input('player'), nil
        if who then
            src = ctx:source(who)
            if not src then return 'failed' end
        end
        -- In a Test, "everyone" is the tester.
        ---@type string|table
        local audience = 'everyone'
        if src then
            local p = Players[src]
            audience = { people = { { charId = p and p.charId } } }
        elseif ctx:tester() then
            audience = { people = { ctx:tester() } }
        end
        local tag = ctx:tag()
        local id = markerId(ctx, src)
        -- One player's marker goes with that player (their sub-tag, released at their logout). The cap
        -- is for the markers everyone sees; one player's are one per name, per player online.
        local markTag = src and Systems.tagFor(tag, src) or tag
        local moving = false
        for _, b in ipairs(Blips.list(CORE)) do if b.id == id then moving = true break end end
        if not src and not moving and C.liveUnder(tag, 'blip') >= MAX_MARKERS then
            ctx:log('this system shows %d markers already, the most it may', MAX_MARKERS)
            return 'failed'
        end
        local radius = tonumber(ctx:prop('radius')) or 0
        local ok, why = Blips.show(CORE, audience, id, {
            coords = at, label = ctx:prop('label'), sprite = ctx:prop('sprite'), color = ctx:prop('color'),
            radius = radius >= 1 and radius or nil, route = ctx:prop('route') == true,
            shortRange = ctx:prop('shortRange') == true, tag = markTag })
        if not ok then ctx:log('the marker could not be shown: %s', tostring(why)) return 'failed' end
        return 'out'
    end,
})

define({
    type = 'map.unblip', category = 'world', kind = 'action', title = 'Remove Map Marker', api = 'HideBlip',
    desc = 'Takes one of this system\'s map markers away, by its name (and its player, for one player\'s).',
    props = { { key = 'name', kind = 'text', label = 'Name', default = 'marker', maxLength = 24 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'For (empty: everyone\'s)', optional = true } } },
    run = function(ctx)
        local who, src = ctx:input('player'), nil
        if who then
            src = ctx:source(who)
            if not src then return 'out' end
        end
        Blips.remove(CORE, markerId(ctx, src))
        return 'out'
    end,
})

define({
    type = 'map.waypoint', category = 'world', kind = 'action', title = 'Set Their Waypoint', api = 'SetPlayerWaypoint',
    desc = 'Puts the waypoint on a player\'s map at a place (the purple one they could set themselves).',
    outputs = { 'out', 'gone' },
    labels = { gone = 'Not here' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'place', type = 'vector', label = 'Place' } } },
    run = function(ctx)
        local _, src = whoOf(ctx)
        if not src then return 'gone' end
        local ok = Blips.waypoint(src, ctx:need('place'))
        return ok and 'out' or 'gone'
    end,
})
