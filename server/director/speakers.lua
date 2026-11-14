-- ============================================
-- Director — speakers: Play on Speakers and Stop Speakers
-- ============================================
--
-- A SPEAKER is any prop placed on the World tab (a speaker model, a boombox, a radio on a shelf). Play on Speakers plays
-- a song (a Fivemanage link) from every speaker it names at once, in step: a gang's hideout full of speakers on the
-- walls, a stage's stacks. It is ONE sound, heard from each speaker by each player's own distance to it, through walls
-- and doorways as a voice is (whip_voice world voices: one voice, several places). The voice bot fetches and plays the
-- song; players never download it.
--
-- How it sounds is the card's: its volume, how far it carries, and how much of a speaker it sounds like (Speaker sound:
-- from perfectly clear to a cheap, tinny one), with Tone for its bass, mids and treble. A speaker plays one song at a
-- time: a new one on any of its speakers stops the one playing there. Stop Speakers stops them, faded out or at once,
-- and every song a run plays stops when the run ends.
--
-- Needs whip_voice and its voice bot (1.5.0 or newer for songs over two minutes, loops and stopping).

DirectorSpeakers = {}

local VOICE = 'whip_voice'
local MAX_SPEAKERS = 32

local function say(fmt, ...) print(('[whip_core:director] speakers: ' .. fmt):format(...)) end

-- Songs playing: [runId] = { [n] = { key = world voice (nil while it is being made), things = { [worldId] = true },
-- wait = the promise a card waits on to its end (Wait until it has played) } }
local plays = {}
local playN = 0

--- A run that is over (runtime.lua's endRun): no song starts for it (a card still waiting as it ended), and one being
--- made as it ended is let go.
local function ended(run) return run.status ~= 'running' end

-- ============================================
-- How it sounds
-- ============================================

--- The sound recipe for a song on speakers (whip_voice's sound blocks), from a card's settings:
---   sound   0 (perfectly clear) .. 100 (a cheap, tinny speaker)
---   tone    true: bass, mid, treble (-12 .. 12 dB) as set
---   volume  0 .. 200 (%)
--- A cheaper speaker loses its lows and highs, honks around its cone's band, is pushed into a little grit, and squashes
--- its loud parts. Empty for a clear one at full volume with no tone.
function DirectorSpeakers.recipe(o)
    local r = {}
    local q = math.max(0, math.min(100, tonumber(o.sound) or 0)) / 100
    if q > 0 then
        r[#r + 1] = { 'highpass', hz = 30 + 370 * q * q, q = 0.7 }       -- small cones: the lows go first
        r[#r + 1] = { 'lowpass', hz = 20000 * 0.25 ^ q, q = 0.7 }        -- ...then the top
        r[#r + 1] = { 'peak', hz = 1800, q = 1.0, db = 6 * q }           -- the cone's own honk
        if q >= 0.3 then r[#r + 1] = { 'drive', k = 1 + 4 * (q - 0.3) } end   -- pushed hard
        r[#r + 1] = { 'compress', threshold = -10 - 14 * q, ratio = 1 + 3 * q, knee = 6, attack = 0.005, release = 0.15 }
    end
    if o.tone == true then
        local function db(v) return math.max(-12, math.min(12, tonumber(v) or 0)) end
        if db(o.bass) ~= 0 then r[#r + 1] = { 'lowshelf', hz = 120, db = db(o.bass) } end
        if db(o.mid) ~= 0 then r[#r + 1] = { 'peak', hz = 1000, q = 0.8, db = db(o.mid) } end
        if db(o.treble) ~= 0 then r[#r + 1] = { 'highshelf', hz = 6000, db = db(o.treble) } end
    end
    local vol = math.max(0, math.min(200, tonumber(o.volume) or 100)) / 100
    if vol ~= 1 then r[#r + 1] = { 'gain', db = vol > 0.001 and 20 * math.log(vol, 10) or -60 } end
    return r
end

-- ============================================
-- Where it plays from
-- ============================================

--- A speaker as whip_voice takes a place: the networked object a prop with physics on is ({ netId }), what an attached
--- one is attached to (it moves with it), else its fixed spot and model (each player's game finds its own copy of the
--- prop there, for its walls and room). nil and why.
local function placeOf(run, worldId)
    local w = type(run.graph) == 'table' and type(run.graph.world) == 'table' and run.graph.world[worldId] or nil
    if type(w) ~= 'table' or w.kind ~= 'prop' then return nil, ('%s is not a placed prop'):format(tostring(worldId)) end
    local h = Director.handleOf(run, worldId)
    if type(h) == 'table' and h.netId then return { netId = h.netId } end
    local piece = Director.propPiece(w.def)
    if not piece then return nil, ('%s has no model or no position'):format(tostring(worldId)) end
    if piece.attachTo then
        local t = Director.handleOf(run, piece.attachTo)
        if type(t) == 'table' and t.netId then
            -- Its spot on what it rides, worked out as nodes_props.lua attaches it (from where that was placed, by its
            -- heading), so the song comes out of the speaker on the car, not the car's middle. Too far from it for a
            -- world voice's place (10 m): from what it rides.
            local pw = run.graph.world[piece.attachTo]
            local pc = type(pw) == 'table' and type(pw.def) == 'table' and pw.def.coords or nil
            if type(pc) == 'table' then
                local ph = math.rad(-(tonumber(pc.heading) or 0.0))
                local dx = piece.coords.x - (tonumber(pc.x) or 0.0)
                local dy = piece.coords.y - (tonumber(pc.y) or 0.0)
                local dz = piece.coords.z - (tonumber(pc.z) or 0.0)
                local ox, oy = dx * math.cos(ph) - dy * math.sin(ph), dx * math.sin(ph) + dy * math.cos(ph)
                if math.sqrt(ox * ox + oy * oy + dz * dz) <= 10.0 then
                    return { netId = t.netId, offset = vector3(ox, oy, dz + 0.0), model = piece.model }
                end
            end
            return { netId = t.netId }
        end
    end
    return { coords = vector3(piece.coords.x + 0.0, piece.coords.y + 0.0, piece.coords.z + 0.0), model = piece.model }
end

-- ============================================
-- Playing and stopping
-- ============================================

--- Let a song go: its world voice leaves (no fade: it is over).
local function release(runId, n)
    local list = plays[runId]
    local p = list and list[n]
    if not p then return end
    list[n] = nil
    if next(list) == nil then plays[runId] = nil end
    -- (One still being made has no voice yet: play() sees its entry gone and lets its voice go itself.)
    if p.key and GetResourceState(VOICE) == 'started' then
        local key = p.key
        CreateThread(function() pcall(function() exports[VOICE]:RemoveWorldVoice(key) end) end)
    end
end

--- Stop the songs of this run playing on any of these speakers (`things`: [worldId] = true, or nil for all), faded
--- out over fadeMs, then let go of. WAITS (it asks the voice bot). The number stopped.
local function stopOn(run, things, fadeMs)
    local stopped = 0
    -- (The songs as they are now, picked first: a fade waits on the voice bot, and meanwhile a song can start, or the
    -- last one go and its run's table with it, which a walk of the table itself would skip past.)
    local hits = {}
    for n, p in pairs(plays[run.id] or {}) do
        local hit = things == nil
        if not hit then for id in pairs(p.things) do if things[id] then hit = true break end end end
        if hit then hits[#hits + 1] = { n = n, p = p } end
    end
    table.sort(hits, function(a, b) return a.n < b.n end)
    for _, h in ipairs(hits) do
        local n, p = h.n, h.p
        if plays[run.id] and plays[run.id][n] == p then
            stopped = stopped + 1
            local ok, done = false, false
            if p.key and fadeMs > 0 and GetResourceState(VOICE) == 'started' then
                ok, done = pcall(function() return exports[VOICE]:StopWorldVoice(p.key, fadeMs) end)
            end
            if ok and done then
                -- Its onDone ('stopped', once the fade is over) lets it go; in case it never comes, so does this.
                local runId = run.id
                SetTimeout(fadeMs + 5000, function() release(runId, n) end)
            else
                release(run.id, n)
            end
        end
    end
    return stopped
end

--- A song on these speakers: their world voice made, its sound and reach set, the song started. WAITS. true and the
--- song's length (ms), or false and why. `opts.wait`: answers once a song that does not loop has played to its end.
function DirectorSpeakers.play(run, worldIds, url, o)
    if GetResourceState(VOICE) ~= 'started' then return false, 'whip_voice is not running' end
    if ended(run) then return false, 'the scenario has ended' end
    local places, things = {}, {}
    for _, id in ipairs(worldIds) do
        local p, why = placeOf(run, id)
        if not p then return false, why end
        places[#places + 1] = p
        things[id] = true
        if #places >= MAX_SPEAKERS then break end
    end
    if #places == 0 then return false, 'no speakers to play on' end
    -- One song at a time on a speaker: one already playing on any of these stops at once.
    stopOn(run, things, 0)
    local range = math.max(5, math.min(300, tonumber(o.range) or 40))
    -- ITS ENTRY FIRST, THEN ITS VOICE: making the voice waits (up to 5 s with its retries), and a run that ended in
    -- that time found nothing of it to stop, then got a song that looped on after it (WLVF's review). Ended meanwhile, or
    -- stopped by a song after it on the same speakers, the entry is gone, and the voice just made is let go.
    playN = playN + 1
    local n = playN
    plays[run.id] = plays[run.id] or {}
    local entry = { key = nil, things = things }
    plays[run.id][n] = entry
    local okC, key, cwhy = pcall(function()
        -- (music: heard as from far off, late by its distance, so the Doppler effect on a moving one: whip_voice.)
        return exports[VOICE]:CreateWorldVoice({ name = 'Speakers', at = places, range = range, bucket = run.bucket or 0,
                                                 music = true })
    end)
    if not okC or not key then
        release(run.id, n)
        return false, tostring(okC and cwhy or key)
    end
    if ended(run) or not (plays[run.id] and plays[run.id][n] == entry) then
        CreateThread(function() pcall(function() exports[VOICE]:RemoveWorldVoice(key) end) end)
        if ended(run) then return false, 'the scenario has ended' end
        if GetResourceState(VOICE) ~= 'started' then return false, 'whip_voice stopped' end
        return false, 'another song took these speakers'
    end
    entry.key = key
    local full = math.max(0, math.min(range, tonumber(o.full) or 0))
    pcall(function() exports[VOICE]:SetWorldVoiceRange(key, range, full > 0 and full or nil) end)
    local recipe = DirectorSpeakers.recipe(o)
    local okS, sset, swhy = pcall(function() return exports[VOICE]:SetWorldVoiceSound(key, #recipe > 0 and recipe or false) end)
    if not (okS and sset) then say('its sound could not be set: %s', tostring(okS and swhy or sset)) end
    local p = o.wait and promise.new() or nil
    -- (Kept with it, so whip_voice stopping answers it: its song's end never would, onResourceStop below.)
    entry.wait = p
    local runId = run.id
    local okP, d, pwhy = pcall(function()
        return exports[VOICE]:PlayWorldVoice(key, url, function(_, how)
            if how ~= 'cut' then release(runId, n) end
            if p and p.state == 0 then p:resolve(how) end
        end, { loop = o.loop == true, music = true, fadeIn = math.floor((tonumber(o.fadeIn) or 0) * 1000) })
    end)
    if not (okP and d) then
        release(run.id, n)
        return false, tostring(okP and pwhy or d)
    end
    if p then
        local how = Citizen.Await(p)
        return how == 'done', how ~= 'done' and how or nil
    end
    return true, d
end

--- Every song a run plays stops with it (main.lua's runEnded).
function DirectorSpeakers.runEnded(run)
    local ns = {}
    for n in pairs(plays[run.id] or {}) do ns[#ns + 1] = n end
    for _, n in ipairs(ns) do release(run.id, n) end
    plays[run.id] = nil
end

-- whip_voice going: its world voices went with it, and no song's end will come. A card waiting for one is answered
-- (Could not: whip_voice stopped), not left to Took too long.
AddEventHandler('onResourceStop', function(res)
    if res ~= VOICE then return end
    local was = plays
    plays = {}
    for _, list in pairs(was) do
        for _, e in pairs(list) do
            if e.wait and e.wait.state == 0 then e.wait:resolve('whip_voice stopped') end
        end
    end
end)

-- ============================================
-- The cards
-- ============================================

--- Check: a link a song may have (the voice bot's sites, as for a lore character's lines).
local function linkCheck(v)
    if type(v) ~= 'string' or v:match('^%s*(.-)%s*$') == '' then return nil end   -- (empty: the field's required says so)
    return DirectorLore.audioProblem and DirectorLore.audioProblem(v:match('^%s*(.-)%s*$')) or nil
end

local function slider(key, label, min, max, default, unit, hint, when)
    return { key = key, kind = 'number', label = label, min = min, max = max, default = default, unit = unit,
             slider = true, hint = hint, when = when }
end

local TONE = { key = 'tone', is = true }

local ok, why = DirectorNodes.define({
    type = 'speakers.play', v = 1, category = 'world', title = 'Play on Speakers',
    desc = 'Speakers play a song, from every one of them at once, in step.',
    help = 'A speaker is any prop placed on the World tab: pick the ones that play, or a group of them.',
    outputs = { 'done', 'failed', 'timeout' },
    labels = { done = 'Done', failed = 'Could not', timeout = 'Took too long' },
    latent = true, yields = true,
    props = {
        DirectorNodes.thingsField('speakers', 'prop', 'Speakers', { max = MAX_SPEAKERS }),
        -- (A link the editor plays beside it, and shows on the card by its file's name: its ui.)
        { key = 'url', kind = 'text', label = 'Song link', required = true, maxLength = 255, check = linkCheck, ui = 'hearLink' },
        { key = 'loop', kind = 'bool', label = 'Loop', default = true, hint = 'Plays over and over until a Stop Speakers card or the run\'s end' },
        slider('volume', 'Volume', 0, 200, 100, ' %'),
        slider('range', 'Heard up to', 5, 300, 40, ' m', 'How far from each speaker it carries'),
        slider('full', 'Full volume within', 0, 100, 4, ' m', 'Up to this close to a speaker, it is at full volume'),
        slider('sound', 'Speaker sound', 0, 100, 35, ' %', '0: perfectly clear. 100: a cheap, tinny speaker'),
        { key = 'tone', kind = 'bool', label = 'Tone (bass, mids, treble)', default = false },
        slider('bass', 'Bass', -12, 12, 0, ' dB', nil, TONE),
        slider('mid', 'Mids', -12, 12, 0, ' dB', nil, TONE),
        slider('treble', 'Treble', -12, 12, 0, ' dB', nil, TONE),
        slider('fadeIn', 'Fade in', 0, 30, 0, ' s'),
        { key = 'wait', kind = 'bool', label = 'Wait until it has played', default = false,
          when = { key = 'loop', is = false }, hint = 'Goes on once the song ends (else as it starts)' },
    },
    run = function(ctx)
        local ids = DirectorNodes.things(ctx, 'speakers')
        if #ids == 0 then
            ctx:log('Play on Speakers: no speakers (pick placed props, or a group of them)')
            return 'failed'
        end
        local url = (ctx:prop('url') or ''):match('^%s*(.-)%s*$')
        local bad = DirectorLore.audioProblem and DirectorLore.audioProblem(url) or nil
        if bad then
            ctx:log('Play on Speakers: %s', bad)
            return 'failed'
        end
        local loop = ctx:prop('loop') ~= false
        local o = { loop = loop, volume = ctx:prop('volume'), range = ctx:prop('range'), full = ctx:prop('full'),
                    sound = ctx:prop('sound'), tone = ctx:prop('tone') == true, bass = ctx:prop('bass'),
                    mid = ctx:prop('mid'), treble = ctx:prop('treble'), fadeIn = ctx:prop('fadeIn'),
                    wait = not loop and ctx:prop('wait') == true }
        local run = ctx.run
        ctx:call(function()
            local played, w = DirectorSpeakers.play(run, ids, url, o)
            if not played then
                ctx:log('Play on Speakers: %s', tostring(w))
                return 'failed'
            end
            return 'done'
        end)
        -- Fetching a song takes a while; one waited to its end, up to the voice bot's longest song and a minute more.
        ctx:after(o.wait and 21 * 60000 or 60000, 'timeout')
        return nil
    end,
})
if not ok then print('^1[whip_core:director] card type refused: ' .. tostring(why) .. '^0') end

ok, why = DirectorNodes.define({
    type = 'speakers.stop', v = 1, category = 'world', title = 'Stop Speakers',
    desc = 'Speakers stop the song they are playing.',
    help = 'A song plays on until this card or the run\'s end, unless it was set to play once.',
    outputs = { 'done', 'timeout' },
    labels = { done = 'Stopped', timeout = 'Took too long' },
    latent = true, yields = true,
    props = {
        DirectorNodes.thingsField('speakers', 'prop', 'Speakers', { max = MAX_SPEAKERS }),
        slider('fadeOut', 'Fade out', 0, 30, 2, ' s'),
    },
    run = function(ctx)
        local things = {}
        for _, id in ipairs(DirectorNodes.things(ctx, 'speakers')) do things[id] = true end
        local fadeMs = math.floor((tonumber(ctx:prop('fadeOut')) or 0) * 1000)
        local run = ctx.run
        ctx:call(function()
            local n = stopOn(run, things, fadeMs)
            if n == 0 then ctx:log('Stop Speakers: nothing was playing on them') end
            return 'done'
        end)
        ctx:after(30000, 'timeout')
        return nil
    end,
})
if not ok then print('^1[whip_core:director] card type refused: ' .. tostring(why) .. '^0') end
