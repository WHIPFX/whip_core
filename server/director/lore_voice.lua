-- Lore characters' voice lines: a recording (an .mp3 link set in Director > Lore characters > Voice lines) played
-- through whip_voice as a player's voice is heard: by players in range, from the NPC's head, mouth moving, at each
-- player's own Voice volume. The voice bot fetches the recording; players never download it.
-- Lines: Hello and Goodbye (said when a player walks up and away), React positive and negative (for a Lore Says card
-- or a script), and five reactions a player's game reports (bumped into, hit by a car, gun aimed at it, gunfire
-- nearby, its car stolen). Each line has any number of variants, taken in turn; one may have a subtitle.
-- Every Director NPC that is a lore character speaks (NPCs keep the lore character they were spawned as).
-- Its voice stays in the voice room while a player is near (PREJOIN_M) and goes RELEASE_MS after nobody is.
-- One line at a time per NPC: a line asked for while it talks is skipped, said after, or cuts in, per its If talking setting.
-- Needs whip_voice and its voice bot; without them there are no lines (said once in the console, never an error).
--
--   exports.whip_core:LoreSay(key, line, opts)   -> true | false, why       (waits: the recording is fetched)
--       line: 'hello' | 'goodbye' | 'positive' | 'negative' | 'bumped' | 'hitByCar' | 'aimedAt' | 'gunfire' | 'carStolen'
--       opts.npcId: which of its NPCs (else the nearest to opts.near, a server id, else the first alive)
--       opts.wait: answer only once the line has been said
--       opts.busy: 'skip' | 'queue' | 'cut' while it is already talking (else the line's own If talking setting)
--       opts.bonus: metres (0-250) it is heard at full volume, and its subtitle seen, further than usual

local LoreVoice = {}   -- this file's own; other files reach it through DirectorLore.cleanVoice / voiceInfo and LoreSay

local VOICE = 'whip_voice'
local PREJOIN_M = 40.0          -- a player this near: its voice joins the room, ready
local RELEASE_MS = 30000        -- nobody this near for this long: its voice leaves
local TICK_MS = 500
local GREET_GAP_MS = 2500       -- the least time between two lines it says by itself (a crowd walking up)
local REPORT_RANGE_M = 60.0     -- a player reporting a reaction must be this near it
local MAX_VARIANTS, MAX_TOTAL, MAX_TEXT = 50, 200, 160

local LINES = {
    { key = 'hello',     label = 'Hello',           group = 'Generic',   help = 'A player walks up to it.' },
    { key = 'goodbye',   label = 'Goodbye',         group = 'Generic',   help = 'A player it said hello to walks away.' },
    { key = 'positive',  label = 'React positive',  group = 'Generic',   help = 'Said when a Lore Says card or a script asks: something went its way.' },
    { key = 'negative',  label = 'React negative',  group = 'Generic',   help = 'Said when a Lore Says card or a script asks: something did not.' },
    { key = 'bumped',    label = 'Bumped into',     group = 'Reactions', help = 'A player walks or runs into it.' },
    { key = 'hitByCar',  label = 'Hit by a car',    group = 'Reactions', help = 'A player drives into it.' },
    { key = 'aimedAt',   label = 'Gun aimed at it', group = 'Reactions', help = 'A player points a weapon at it.' },
    { key = 'gunfire',   label = 'Gunfire nearby',  group = 'Reactions', help = 'A player shoots near it.' },
    { key = 'carStolen', label = 'Its car stolen',  group = 'Reactions', help = 'A player takes the driver\'s seat of the car it was in.' },
}
local BY_KEY, BY_LABEL, LABELS = {}, {}, {}
for _, l in ipairs(LINES) do BY_KEY[l.key] = l; BY_LABEL[l.label] = l.key; LABELS[#LABELS + 1] = l.label end
local REACTIONS = { 'bumped', 'hitByCar', 'aimedAt', 'gunfire', 'carStolen' }
LoreVoice.LINES, LoreVoice.REACTIONS = LINES, REACTIONS

local function say(fmt, ...) print(('[whip_core:director] lore voices: ' .. fmt):format(...)) end
local trim = DirectorKit.trim

--- Config.LoreVoice, with its gaps filled.
local function cfg()
    local c = type(Config.LoreVoice) == 'table' and Config.LoreVoice or {}
    local function n(v, lo, hi, d) v = tonumber(v); if not v then return d end return math.max(lo, math.min(hi, v)) end
    return {
        enabled = c.Enabled ~= false,
        gestures = c.Gestures ~= false,   -- hands while talking (client/lore_reactions.lua)
        range = n(c.Range, 2, 50, 15),
        greet = n(c.GreetRange, 1, 15, 4),
        bye = n(c.ByeRange, 2, 50, 10),
        greetAgainMs = n(c.GreetAgainMinutes, 0, 120, 3) * 60000,
        reactAgainMs = n(c.ReactAgainSeconds, 1, 600, 6) * 1000,
    }
end

-- ============================================
-- The lines, as a lore character keeps them
-- ============================================

--- The link starts a recording may have (Config.LoreVoice.Links), each 'https://' + a site + '/'.
function LoreVoice.links()
    local out = {}
    local list = type(Config.LoreVoice) == 'table' and Config.LoreVoice.Links or nil
    for _, start in ipairs(type(list) == 'table' and list or {}) do
        if type(start) == 'string' and start:match('^https://[%w%-]+%.[%w%-%.]+/[%w%-%._/]*$') then out[#out + 1] = start end
    end
    return out
end

--- Why a recording's link is refused, or nil: one of the accepted starts, a plain address, an mp3, ogg or wav.
function LoreVoice.audioProblem(url)
    if #url > 255 then return 'a link is at most 255 characters' end
    local starts = LoreVoice.links()
    if #starts == 0 then return 'voice lines are switched off (Config: Voice line links accepted)' end
    for _, start in ipairs(starts) do
        if url:sub(1, #start) == start then
            local rest = url:sub(#start + 1)
            if rest == '' or not rest:match('^[%w%-%._/]+$') or rest:find('..', 1, true) then return 'that link is not a recording\'s address' end
            local ext = (rest:match('%.(%w+)$') or ''):lower()
            if ext ~= 'mp3' and ext ~= 'ogg' and ext ~= 'wav' then return 'a recording is an .mp3, .ogg or .wav link' end
            return nil
        end
    end
    return ('only links starting with %s are accepted'):format(table.concat(starts, ' or '))
end

--- A character's voice lines as whip keeps them: { [line] = { { url, text? }, ... } } (lines with none left out).
--- From the Lore form (JSON text) or a table. nil and why for something it will not keep.
function DirectorLore.cleanVoice(v)
    if type(v) == 'string' then
        local ok, t = pcall(json.decode, v)
        if not ok or type(t) ~= 'table' then return nil, 'The voice lines could not be read' end
        v = t
    end
    if type(v) ~= 'table' then return nil, 'The voice lines could not be read' end
    local out, total = {}, 0
    for _, def in ipairs(LINES) do
        local list = v[def.key]
        if type(list) == 'table' then
            local clean = {}
            for i, var in ipairs(list) do
                if type(var) == 'table' then
                    local url, text = trim(var.url), trim(var.text)
                    if url ~= '' then
                        local bad = LoreVoice.audioProblem(url)
                        if bad then return nil, ('%s, variant %d: %s'):format(def.label, i, bad) end
                        if #text > MAX_TEXT then return nil, ('%s, variant %d: a subtitle is at most %d characters'):format(def.label, i, MAX_TEXT) end
                        clean[#clean + 1] = { url = url, text = text ~= '' and text or nil }
                    end
                end
            end
            if #clean > MAX_VARIANTS then return nil, ('%s: at most %d variants'):format(def.label, MAX_VARIANTS) end
            total = total + #clean
            if #clean > 0 then out[def.key] = clean end
        end
    end
    if total > MAX_TOTAL then return nil, ('At most %d voice line variants in all'):format(MAX_TOTAL) end
    -- What each line does when it is asked while the character is already talking (LoreVoice.sayFrom): 'queue' (said
    -- after) or 'cut' (cuts in); left out it is skipped.
    if type(v.busy) == 'table' then
        local busy = {}
        for _, def in ipairs(LINES) do
            local m = v.busy[def.key]
            if m == 'queue' or m == 'cut' then busy[def.key] = m end
        end
        if next(busy) then out.busy = busy end
    end
    return out
end

--- What the Lore form needs to show the lines (the hub's 'lore' answer carries it).
function DirectorLore.voiceInfo()
    local lines = {}
    for i, l in ipairs(LINES) do lines[i] = { key = l.key, label = l.label, group = l.group, help = l.help } end
    return { lines = lines, links = LoreVoice.links(), on = cfg().enabled == true,
             maxVariants = MAX_VARIANTS, maxText = MAX_TEXT }
end

-- ============================================
-- Which NPCs are lore characters, now
-- ============================================

local npcs = {}        -- [npcId] = { key, netId }
local voices = {}      -- [npcId] = { key = world voice key | nil, making = bool, near = ms }
local speaking = {}    -- [npcId] = true while a line plays
local queued = {}      -- [npcId] = { { line, at, p }, ... }: said in turn once the line it is saying ends (sayFrom)
local playing = {}     -- [npcId] = the promise a caller waits on while its line plays (playFrom, opts.wait)
local lastLine = {}    -- [npcId] = ms its last line started
local greeted = {}     -- [npcId] = { [src] = { at = ms, bye = bool } }
local reacted = {}     -- [npcId] = { [reaction] = ms }
local rotation = {}    -- [loreKey .. ':' .. line] = the variant said last
local voiceOff = nil   -- why whip_voice cannot speak for them (said once), and until when not to ask again
local voiceOffUntil = 0

local reactorsDirty = false

-- NPCs with a look of their own from the character editor (not a lore character's: server/npcs.lua def.look, a
-- Director NPC's made on its page), dressed by every game near them as a lore look is: [npcId] = netId. Until it goes
-- (its body too keeps the look: a game it streams in to again puts it on).
local dressed = {}

--- The lines a character has (true per line with a variant), or nil.
local function linesOf(key)
    local c = DirectorLore.get(key)
    if not c or c.retired or type(c.voice) ~= 'table' or next(c.voice) == nil then return nil end
    return c.voice, c
end

local function forget(npcId)
    if not npcs[npcId] then return end
    npcs[npcId] = nil
    greeted[npcId], reacted[npcId], speaking[npcId], lastLine[npcId] = nil, nil, nil, nil
    -- Lines waiting for it go unsaid (a card waiting on one hears why), and the one it says (its voice goes with it,
    -- and with it the line's end)
    for _, item in ipairs(queued[npcId] or {}) do if item.p then item.p:resolve('its NPC went') end end
    queued[npcId] = nil
    local p = playing[npcId]
    playing[npcId] = nil
    if p and p.state == 0 then p:resolve('its NPC went') end
    local v = voices[npcId]
    voices[npcId] = nil
    if v and v.key and GetResourceState(VOICE) == 'started' then
        local key = v.key
        CreateThread(function() pcall(function() exports[VOICE]:RemoveWorldVoice(key) end) end)
    end
    reactorsDirty = true
end

-- (Hooks: must not wait.)
Npcs.onLife('spawned', function(p)
    if type(p) == 'table' and type(p.lore) == 'string' and p.npcId and p.netId then
        npcs[p.npcId] = { key = p.lore, netId = p.netId }
        reactorsDirty = true
    end
    if type(p) == 'table' and p.look and p.npcId and p.netId then
        dressed[p.npcId] = p.netId
        reactorsDirty = true
    end
end)
Npcs.onLife('despawned', function(p)
    if type(p) ~= 'table' then return end
    forget(p.npcId)
    if dressed[p.npcId] then
        dressed[p.npcId] = nil
        reactorsDirty = true
    end
end)
Npcs.onLife('killed', function(p) if type(p) == 'table' then forget(p.npcId) end end)
-- Up again (its tasks' Revive): a lore character talks again, as when it was made.
Npcs.onLife('revived', function(p)
    if type(p) == 'table' and type(p.lore) == 'string' and p.npcId and p.netId and not npcs[p.npcId] then
        npcs[p.npcId] = { key = p.lore, netId = p.netId }
        reactorsDirty = true
    end
end)

--- Its NPC's entity, where it is now, and its routing bucket, or nil (gone, or not in the server's view).
local function placeOf(n)
    local ent = NetworkGetEntityFromNetworkId(n.netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent, GetEntityCoords(ent), GetEntityRoutingBucket(ent)
end

local dist = DirectorKit.dist

-- ============================================
-- Its voice in the voice room
-- ============================================

--- The world voice an NPC speaks with: made now if it has none (WAITS). nil and why.
local function voiceOf(npcId)
    local n = npcs[npcId]
    if not n then return nil, 'that NPC is not a lore character in the world now' end
    if GetResourceState(VOICE) ~= 'started' then return nil, 'whip_voice is not running' end
    local v = voices[npcId]
    if v and v.key then return v.key end
    if v and v.making then
        local deadline = GetGameTimer() + 8000
        while v.making and GetGameTimer() < deadline do Wait(50) end
        if v.key then return v.key end
        return nil, v.why or 'its voice could not join'
    end
    if GetGameTimer() < voiceOffUntil then return nil, voiceOff end
    v = { making = true, near = GetGameTimer() }
    voices[npcId] = v
    local c = DirectorLore.get(n.key)
    local ok, key, why = pcall(function()
        return exports[VOICE]:CreateWorldVoice({ name = c and c.name or n.key, at = { netId = n.netId }, range = cfg().range })
    end)
    v.making = false
    if not ok or not key then
        v.why = ok and why or tostring(key)
        voices[npcId] = nil
        -- whip_voice not set up for it (not running, or no voice bot): said once a minute at most.
        if v.why ~= voiceOff then say('^3%s cannot speak: %s^0', c and c.name or n.key, tostring(v.why)) end
        voiceOff, voiceOffUntil = v.why, GetGameTimer() + 60000
        return nil, v.why
    end
    if voices[npcId] ~= v then   -- it went while joining
        pcall(function() exports[VOICE]:RemoveWorldVoice(key) end)
        return nil, 'that NPC went'
    end
    v.key = key
    voiceOff, voiceOffUntil = nil, 0
    return key
end

-- A line's BONUS RANGE (its card's slider, 0 to MAX_BONUS m): the voice carries that much further for the line and
-- is at full volume that much further out too (whip_voice SetWorldVoiceRange), and its subtitle is seen as far
-- (Bubbles.show `far`). Back to the usual when the line ends. Josh, 2 Nov: a line said from a car he could not catch.
local MAX_BONUS = 250
local WIDEN_MS = 1000   -- a line whose voice just widened waits this long: those now in reach are connected first

--- Its voice's reach for the next line: `bonus` metres more than the usual (0: the usual). Answers true when it just
--- grew. An older whip_voice without SetWorldVoiceRange: the usual, said nowhere (the line still plays).
local function reach(npcId, key, bonus)
    local v = voices[npcId]
    bonus = math.max(0, math.min(MAX_BONUS, tonumber(bonus) or 0))
    if not (v and v.key == key) or (v.bonus or 0) == bonus then return false end
    local base = cfg().range
    local ok, done = pcall(function()
        return exports[VOICE]:SetWorldVoiceRange(key, base + bonus, bonus > 0 and bonus + 1.0 or nil)
    end)
    if not (ok and done) then return false end
    local grew = bonus > (v.bonus or 0)
    v.bonus = bonus
    return grew
end
LoreVoice.MAX_BONUS = MAX_BONUS

--- The next variant of a line (in turn), or nil.
local function pick(loreKey, voice, line)
    local list = voice[line]
    if type(list) ~= 'table' or #list == 0 then return nil end
    local k = loreKey .. ':' .. line
    local i = (rotation[k] or 0) % #list + 1
    rotation[k] = i
    return list[i]
end

-- ============================================
-- One line at a time (Josh, 27 Oct)
-- ============================================
--
-- A line asked for while the character is still saying one is, by its setting (Lore characters > Audio > If
-- talking, the voice lines' `busy`):
--   skip   (the default) ignored
--   queue  said once the line it is saying ends (at most QUEUE_MAX waiting; one waiting too long is dropped)
--   cut    cuts the line off and is said now
local BUSY = { skip = true, queue = true, cut = true }
local QUEUE_MAX, QUEUE_STALE_MS = 3, 20000

--- What a line does when the character is already talking: its setting, else skip.
local function busyOf(voice, line)
    local m = voice and type(voice.busy) == 'table' and voice.busy[line] or nil
    return BUSY[m] and m or 'skip'
end
LoreVoice.busyOf = busyOf

--- The next line waiting for this NPC, said now (one that waited too long is dropped). From a thread. An item is one
--- of its lines (`line`) or a recording of a card's own (`v`: Play Custom Voice Line).
local function nextQueued(npcId)
    local q = queued[npcId]
    while q and #q > 0 do
        local item = table.remove(q, 1)
        if GetGameTimer() - item.at <= QUEUE_STALE_MS then
            CreateThread(function()
                local ok, why
                if item.v then ok, why = LoreVoice.playFrom(npcId, item.v, { wait = item.p ~= nil, bonus = item.bonus })
                else ok, why = LoreVoice.sayFrom(npcId, item.line, { busy = 'cut', wait = item.p ~= nil, bonus = item.bonus }) end
                if item.p then item.p:resolve(ok and 'done' or (why or 'failed')) end
            end)
            return
        end
        if item.p then item.p:resolve('it waited too long') end
    end
    queued[npcId] = nil
end

--- Behind the line it is saying: `item` ({ line } or { v }) waits its turn (nextQueued). true, 'queued' when not
--- waiting; with `wait`, once it has been said. false and why when too many wait already.
local function queueBehind(npcId, item, wait)
    local q = queued[npcId] or {}
    if #q >= QUEUE_MAX then return false, 'already talking, with lines waiting' end
    queued[npcId] = q
    item.at, item.p = GetGameTimer(), wait and promise.new() or nil
    q[#q + 1] = item
    if not item.p then return true, 'queued' end
    local how = Citizen.Await(item.p)
    return how == 'done', how ~= 'done' and how or nil
end

--- An NPC says a line (WAITS while its recording is fetched). opts.wait: until it has been said. opts.busy: 'skip',
--- 'queue' or 'cut' instead of the line's own setting. opts.bonus: its Bonus range (metres). true (or true,
--- 'queued'), or false and why.
function LoreVoice.sayFrom(npcId, line, opts)
    opts = type(opts) == 'table' and opts or {}
    if not cfg().enabled then return false, 'lore voice lines are switched off (Config.LoreVoice.Enabled)' end
    local n = npcs[npcId]
    if not n then return false, 'that NPC is not a lore character in the world now' end
    if not BY_KEY[line] then return false, ('no line "%s"'):format(tostring(line)) end
    local voice, c = linesOf(n.key)
    if not (voice and type(voice[line]) == 'table' and #voice[line] > 0) then
        return false, ('%s has no %s line'):format(c and c.name or n.key, BY_KEY[line].label)
    end
    local mode = BUSY[opts.busy] and opts.busy or busyOf(voice, line)
    if speaking[npcId] and mode ~= 'cut' then
        if mode == 'skip' then return false, 'already talking (this line is set to skip then)' end
        return queueBehind(npcId, { line = line, bonus = opts.bonus }, opts.wait)
    end
    return LoreVoice.playFrom(npcId, pick(n.key, voice, line), { wait = opts.wait, line = line, bonus = opts.bonus })
end

--- An NPC says a recording of a card's own, { url, text? } (Play Custom Voice Line), as a line is said: while it
--- talks, skipped, said after or cutting in (opts.busy, default 'queue'). WAITS while it is fetched; opts.wait: until
--- it has been said. true (or true, 'queued'), or false and why.
function LoreVoice.sayRecording(npcId, v, opts)
    opts = type(opts) == 'table' and opts or {}
    if not cfg().enabled then return false, 'lore voice lines are switched off (Config.LoreVoice.Enabled)' end
    if not npcs[npcId] then return false, 'that NPC is not a lore character in the world now' end
    local mode = BUSY[opts.busy] and opts.busy or 'queue'
    if speaking[npcId] and mode ~= 'cut' then
        if mode == 'skip' then return false, 'already talking (this card is set to skip then)' end
        return queueBehind(npcId, { v = v, bonus = opts.bonus }, opts.wait)
    end
    return LoreVoice.playFrom(npcId, v, { wait = opts.wait, bonus = opts.bonus })
end

--- An NPC says one recording, { url, text? } (its subtitle over its head). WAITS while it is fetched; opts.wait:
--- until it has been said; opts.line: which line it is (the gesture it starts with); opts.bonus: its Bonus range
--- (metres: heard and its subtitle seen that much further). true, or false and why.
function LoreVoice.playFrom(npcId, v, opts)
    opts = type(opts) == 'table' and opts or {}
    local n = npcs[npcId]
    if not n then return false, 'that NPC is not a lore character in the world now' end
    local p = opts.wait and promise.new() or nil
    local bonus = math.max(0, math.min(MAX_BONUS, tonumber(opts.bonus) or 0))
    local ok, d, pwhy
    for _ = 1, 2 do
        local key, why = voiceOf(npcId)
        if not key then return false, why end
        speaking[npcId], lastLine[npcId] = true, GetGameTimer()
        -- This line's reach (its Bonus range, or the usual again): those it now reaches are connected before it plays.
        if reach(npcId, key, bonus) then Wait(WIDEN_MS) end
        ok, d, pwhy = pcall(function()
            return exports[VOICE]:PlayWorldVoice(key, v.url, function(_, how)
                -- Ended (not cut by a line that has the voice now): its usual reach again, and the next line waiting.
                if how ~= 'cut' then
                    speaking[npcId] = nil
                    if bonus > 0 then reach(npcId, key, 0) end
                    nextQueued(npcId)
                end
                if p then
                    if playing[npcId] == p then playing[npcId] = nil end
                    if p.state == 0 then p:resolve(how) end
                end
            end)
        end)
        if ok and d then break end
        speaking[npcId] = nil
        -- Its voice went from under it (whip_voice restarted, the service dropped it): a new one, once.
        local gone = ok and type(pwhy) == 'string' and pwhy:find('no such', 1, true)
        if not gone then break end
        if voices[npcId] and voices[npcId].key == key then voices[npcId] = nil end
    end
    if not ok or not d then
        nextQueued(npcId)   -- (it is not talking: lines waiting are not left waiting on this one)
        return false, ok and pwhy or tostring(d)
    end
    -- (`voice`: each game shows it as the line is heard there, not as it is asked for: client/bubbles.lua.)
    if v.text and Bubbles then Bubbles.show({ netId = n.netId }, v.text, { far = bonus, voice = true }) end
    -- Its hands while it talks: the game that owns it plays GTA's gestures for the line's length.
    if cfg().gestures then
        local ent = NetworkGetEntityFromNetworkId(n.netId)
        local owner = ent and ent ~= 0 and NetworkGetEntityOwner(ent) or nil
        if owner and owner > 0 then
            TriggerClientEvent('whip_core:client:loreTalk', owner, n.netId, type(opts.line) == 'string' and opts.line or nil, d)
        end
    end
    if p then
        -- Kept, so whip_voice stopping answers it (its line's end never would: onResourceStop below)
        if p.state == 0 then playing[npcId] = p end
        local how = Citizen.Await(p)
        return how == 'done', how ~= 'done' and how or nil
    end
    return true
end

--- A lore character's NPC in the world: opts.npcId; else the nearest to opts.near (a server id); else the first.
function LoreVoice.npcOf(loreKey, opts)
    opts = type(opts) == 'table' and opts or {}
    if opts.npcId and npcs[opts.npcId] and npcs[opts.npcId].key == loreKey then return opts.npcId end
    local best, bestD
    local from = opts.near and GetPlayerPed(opts.near)
    local at = from and from ~= 0 and GetEntityCoords(from) or nil
    for id, n in pairs(npcs) do
        if n.key == loreKey then
            local _, c = placeOf(n)
            if c then
                local d = at and dist(at, c) or 0
                if not best or d < bestD then best, bestD = id, d end
            end
        end
    end
    return best
end

-- ============================================
-- By itself: ready when someone is near, hello and goodbye
-- ============================================

-- NPCs made before this file was read (none, normally: whip_core reads it at start). Npcs' own list, in memory.
for _, v in ipairs(Npcs.list()) do
    if v.lore and v.alive and v.netId then npcs[v.npcId] = { key = v.lore, netId = v.netId } end
    if v.look and v.netId then dressed[v.npcId] = v.netId end
end
reactorsDirty = true
Every('lore-voices', TICK_MS, function() LoreVoice.tick() end)

function LoreVoice.tick()
    if reactorsDirty then reactorsDirty = false; LoreVoice.sendReactors(-1) end
    local now = GetGameTimer()
    if LoreVoice.expireTests then LoreVoice.expireTests(now) end
    local c = cfg()
    if not c.enabled or not next(npcs) or GetResourceState(VOICE) ~= 'started' then return end
    local players = {}
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        local ped = src and GetPlayerPed(src)
        if src and ped and ped ~= 0 then players[#players + 1] = { src = src, at = GetEntityCoords(ped), bucket = GetPlayerRoutingBucket(src) } end
    end
    for npcId, n in pairs(npcs) do
        local voice = linesOf(n.key)
        local _, at, bucket = placeOf(n)
        if voice and at then
            local nearest = math.huge
            local g = greeted[npcId] or {}
            greeted[npcId] = g
            for _, p in ipairs(players) do
                if p.bucket == bucket then
                    local d = dist(p.at, at)
                    if d < nearest then nearest = d end
                    local was = g[p.src]
                    -- Met again only once GreetAgainMinutes have passed and they are away from it.
                    if was and now - was.at > c.greetAgainMs and d > c.bye then g[p.src] = nil; was = nil end
                    if not was then
                        if d <= c.greet then
                            if not voice.hello then
                                g[p.src] = { at = now, bye = false }   -- met (no Hello line): Goodbye still follows
                            elseif speaking[npcId] then
                                -- Walking up while it talks: its Hello's If talking setting (skip: no hello).
                                g[p.src] = { at = now, bye = false }
                                if busyOf(voice, 'hello') ~= 'skip' then CreateThread(function() LoreVoice.sayFrom(npcId, 'hello') end) end
                            elseif now - (lastLine[npcId] or -1e9) > GREET_GAP_MS then
                                -- Hello: walking up (a crowd walking up: one hello, then the next after a gap).
                                g[p.src] = { at = now, bye = false }
                                CreateThread(function() LoreVoice.sayFrom(npcId, 'hello') end)
                            end
                        end
                    elseif not was.bye and d >= c.bye and voice.goodbye then
                        -- Goodbye: one it met walking away (while it talks: its If talking setting).
                        was.bye = true
                        if not speaking[npcId] or busyOf(voice, 'goodbye') ~= 'skip' then
                            CreateThread(function() LoreVoice.sayFrom(npcId, 'goodbye') end)
                        end
                    end
                end
            end
            for src in pairs(g) do if not GetPlayerPed(src) or GetPlayerPed(src) == 0 then g[src] = nil end end
            -- Its voice: in the room while someone is near, so a line plays at once; out after nobody is.
            local v = voices[npcId]
            if nearest <= PREJOIN_M then
                if not v and now >= voiceOffUntil then CreateThread(function() voiceOf(npcId) end)
                elseif v then v.near = now end
            elseif v and v.key and not speaking[npcId] and now - v.near > RELEASE_MS then
                voices[npcId] = nil
                local key = v.key
                CreateThread(function() pcall(function() exports[VOICE]:RemoveWorldVoice(key) end) end)
            end
        end
    end
end

-- ============================================
-- Reactions: a player's game sees it happen, the server says the line
-- ============================================

--- The NPCs that react, for the players' games: { [netId] = { bumped = true, ... } } (only lines it has).
function LoreVoice.reactors()
    local out = {}
    if not cfg().enabled then return out end
    for _, n in pairs(npcs) do
        local voice = linesOf(n.key)
        if voice then
            local set
            for _, r in ipairs(REACTIONS) do
                if voice[r] then set = set or {}; set[r] = true end
            end
            if set then out[n.netId] = set end
        end
    end
    return out
end

--- How the lore NPCs look, for the games near them to put on: { [netId] = { look = key, v } } for one made in the
--- character editor (every game near puts it on, asking for it by key), else { props = { { anchor, drawable,
--- texture }, ... } } for a GTA ped's hat (director/lore.lua props: the owning game puts it on). Only NPCs with one.
--- And any other NPC with a look of its own: { npc = npcId, v = npcId } (asked for by its id: whip_core:npcLook; an
--- NPC's look never changes, so its id is its version).
function LoreVoice.looks()
    local out = {}
    for _, n in pairs(npcs) do
        local c = DirectorLore.get(n.key)
        if c and c.hasLook then out[n.netId] = { look = n.key, v = c.lookV }
        elseif c and type(c.props) == 'table' and #c.props > 0 then out[n.netId] = { props = c.props } end
    end
    for npcId, netId in pairs(dressed) do
        if not out[netId] then out[netId] = { npc = npcId, v = npcId } end
    end
    return out
end

-- The games' two lists, sent together whenever a lore NPC comes or goes or a character changes: how they look
-- (client/lore_reactions.lua dresses them), and which react.
function LoreVoice.sendReactors(to)
    TriggerClientEvent('whip_core:client:loreLooks', to, LoreVoice.looks())
    TriggerClientEvent('whip_core:client:loreReactors', to, LoreVoice.reactors())
end

-- A character's lines changed (the Lore form saved): the games learn which NPCs react now.
AddEventHandler('whip_core:lore:changed', function() reactorsDirty = true end)

-- whip_voice stopping takes every world voice with it: none of ours is there any more. Its lines' ends never come
-- now, so whoever waits on one (a Lore Says card, LoreSay with wait) is answered, and the lines waiting go unsaid.
AddEventHandler('onResourceStop', function(res)
    if res ~= VOICE then return end
    for _, p in pairs(playing) do if p.state == 0 then p:resolve('whip_voice stopped') end end
    for _, q in pairs(queued) do
        for _, item in ipairs(q) do if item.p and item.p.state == 0 then item.p:resolve('whip_voice stopped') end end
    end
    voices, speaking, queued, playing = {}, {}, {}, {}
end)

SecureEvent('whip_core:server:loreReactorsAsk', { rateLimit = 2000, whileDead = true, params = {} }, function(source)
    LoreVoice.sendReactors(source)
end)

SecureEvent('whip_core:server:loreReact', {
    rateLimit = 300, burst = 5,
    params = { { 'netId', 'id', 1, 4294967295 }, { 'kind', 'enum', REACTIONS } },
}, function(source, _, netId, kind)
    if not cfg().enabled then return end
    local npcId = Npcs.by('netId', netId)
    local n = npcId and npcs[npcId]
    if not npcId or not n then return end
    local voice = linesOf(n.key)
    if not (voice and voice[kind]) then return end
    -- The reporter must be near it (a game reporting from across the map is not believed).
    local _, at = placeOf(n)
    local ped = GetPlayerPed(source)
    if not at or not ped or ped == 0 or dist(GetEntityCoords(ped), at) > REPORT_RANGE_M then return end
    -- The same reaction again only after a while (every game near sees the same bump).
    local r = reacted[npcId] or {}
    reacted[npcId] = r
    local now = GetGameTimer()
    if now - (r[kind] or -1e9) < cfg().reactAgainMs then return end
    -- While it talks, the reaction's If talking setting: skip (ignored, and free to happen again once it is
    -- quiet), queue (said after), cut (said now).
    if speaking[npcId] and busyOf(voice, kind) == 'skip' then return end
    r[kind] = now
    CreateThread(function() LoreVoice.sayFrom(npcId, kind) end)
end)

-- ============================================
-- The Lore form's play button: a link heard as the character would say it, from the builder
-- ============================================

SecureCallback('whip_core:director:loreVoiceTest', {
    permission = 'director.build', whileDead = true, rateLimit = 1500, burst = 2,
    params = { { 'key', 'key', 64 }, { 'url', 'string', 255 } },
}, function(source, _, key, url)
    url = trim(url)
    local bad = LoreVoice.audioProblem(url)
    if bad then return false, bad end
    if GetResourceState(VOICE) ~= 'started' then return false, 'whip_voice is not running' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'you are not in the world' end
    local c = DirectorLore.get(key)
    local ok, vkey, why = pcall(function()
        return exports[VOICE]:CreateWorldVoice({ name = c and c.name or 'Test', at = { netId = NetworkGetNetworkIdFromEntity(ped) }, range = 6 })
    end)
    if not ok or not vkey then return false, ok and why or tostring(vkey) end
    local pok, d, pwhy = pcall(function()
        return exports[VOICE]:PlayWorldVoice(vkey, url, function(k) exports[VOICE]:RemoveWorldVoice(k) end)
    end)
    if not pok or not d then
        pcall(function() exports[VOICE]:RemoveWorldVoice(vkey) end)
        return false, pok and pwhy or tostring(d)
    end
    return { duration = d }
end)

-- ============================================
-- Test mode (the Lore page's Audio tab): the character's NPC in front of a builder, for a while
-- ============================================
--
-- Spawn to test makes the character's NPC (its ped, as a scenario's would be, so it greets and reacts by itself
-- with its SAVED lines) in front of the builder, in their world, unhurtable. Say plays a variant from it, saved or
-- not. One per builder; it goes after TEST_MS, on Remove, when they spawn another, or when they leave.

local CORE = GetCurrentResourceName()
local TEST_MS = 10 * 60000
local tests = {}   -- [src] = { npcId, key, untilMs }

local function endTest(src)
    local t = tests[src]
    if not t then return end
    tests[src] = nil
    Npcs.despawn(CORE, t.npcId)
end

--- The builder whose test NPC this is, or nil.
local function testerOf(npcId)
    for src, t in pairs(tests) do
        if t.npcId == npcId then return src end
    end
    return nil
end

-- (Hooks: must not wait.) Gone some other way: no longer a test. Killed (it should not be): taken away.
Npcs.onLife('despawned', function(p)
    local src = type(p) == 'table' and testerOf(p.npcId)
    if src then tests[src] = nil end
end)
Npcs.onLife('killed', function(p)
    local src = type(p) == 'table' and testerOf(p.npcId)
    if src then CreateThread(function() endTest(src) end) end
end)
AddEventHandler('playerDropped', function()
    local src = source
    endTest(src)
end)

--- Tests past their time go (from the tick).
function LoreVoice.expireTests(now)
    for src, t in pairs(tests) do
        if now >= t.untilMs and not t.ending then
            t.ending = true
            CreateThread(function() endTest(src) end)
        end
    end
end

local function testState(src)
    local t = tests[src]
    if not t then return { on = false } end
    return { on = true, key = t.key, left = math.max(0, (t.untilMs - GetGameTimer()) // 1000) }
end

-- mode: 'ask' (is one out, and whose), 'on' (spawn this one, replacing any), 'off' (take it away).
SecureCallback('whip_core:director:loreTest', {
    permission = 'director.build', whileDead = true, rateLimit = 1000, burst = 3,
    params = { { 'key', 'key', 64 }, { 'mode', 'enum', { 'ask', 'on', 'off' } } },
}, function(source, _, key, mode)
    if mode == 'ask' then return testState(source) end
    if mode == 'off' then endTest(source) return testState(source) end
    local c = DirectorLore.get(key)
    if not c then return false, 'No lore character called ' .. key end
    if c.retired then return false, 'They are retired: Bring back first' end
    if not c.model then return false, 'Give them a ped first (Details), and save' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'you are not in the world' end
    endTest(source)
    -- 2.5 m in front of the builder, facing them; on the ground (a ped's coords are its middle).
    local at, h = GetEntityCoords(ped), GetEntityHeading(ped)
    local r = math.rad(h)
    local npcId, netId = Npcs.spawn(CORE, {
        model = c.model, lore = key, conditions = { invincible = true },
        coords = { x = at.x - math.sin(r) * 2.5, y = at.y + math.cos(r) * 2.5, z = at.z - 1.0, heading = (h + 180.0) % 360.0 },
    }, { bucket = GetPlayerRoutingBucket(source), fightBack = false })
    if not npcId then return false, netId end
    tests[source] = { npcId = npcId, key = key, untilMs = GetGameTimer() + TEST_MS }
    return testState(source)
end)

-- A recording said by the builder's test NPC: a line's variant as the page has it (saved or not yet).
SecureCallback('whip_core:director:loreTestSay', {
    permission = 'director.build', whileDead = true, rateLimit = 400, burst = 4,
    params = { { 'url', 'string', 255 }, { 'text', 'string', MAX_TEXT, '' } },
}, function(source, _, url, text)
    local t = tests[source]
    if not t or not npcs[t.npcId] then return false, 'Your test NPC has gone: Spawn to test again' end
    if not cfg().enabled then return false, 'lore voice lines are switched off (Config.LoreVoice.Enabled)' end
    url = trim(url)
    local bad = LoreVoice.audioProblem(url)
    if bad then return false, bad end
    text = trim(text)
    local ok, why = LoreVoice.playFrom(t.npcId, { url = url, text = text ~= '' and text or nil })
    if not ok then return false, why end
    return true
end)

-- ============================================
-- The cards
-- ============================================

--- Both cards' Bonus range (reach, above): a slider on the card's page (panels.js `slider`). A new one for each card.
local function bonusProp()
    return { key = 'bonus', kind = 'number', label = 'Bonus range', min = 0, max = MAX_BONUS, default = 0, unit = ' m',
             slider = true, hint = 'Heard at full volume, and its subtitle seen (bigger), this much further than usual' }
end

--- A lore character's NPC for a card: its NPC in this run's world, else the nearest of its NPCs to the player the card
--- acts for. nil when it has none in the world.
local function npcFor(ctx, key)
    local run = ctx.run
    for wid, w in pairs(type(run.graph) == 'table' and run.graph.world or {}) do
        if type(w) == 'table' and w.kind == 'npc' and type(w.def) == 'table' and w.def.lore == key then
            local h = Director.handleOf(run, w.id or wid)
            if type(h) == 'table' and h.npcId and npcs[h.npcId] then return h.npcId end
        end
    end
    return LoreVoice.npcOf(key, { near = Director.playerOf(ctx) })
end

local ok, why = DirectorNodes.define({
    type = 'lore.say', v = 1, category = 'lore', title = 'Lore Says',
    desc = 'A lore character says one of its voice lines out loud, from its NPC.',
    help = 'Its lines are set in Director > Lore characters > Voice lines.',
    outputs = { 'done', 'failed', 'timeout' },
    latent = true, yields = true,
    props = {
        { key = 'lore', kind = 'lore', label = 'Who' },
        { key = 'line', kind = 'select', label = 'Line', options = LABELS, default = LABELS[1] },
        { key = 'wait', kind = 'bool', label = 'Wait until it has been said', default = true },
        bonusProp(),
    },
    run = function(ctx)
        local key = ctx:prop('lore')
        local line = BY_LABEL[ctx:prop('line')]
        if not DirectorLore.isLive(key) then
            ctx:log('Lore Says: no lore character (pick one, or make the NPC that starts the scenario one)')
            return 'failed'
        end
        local npcId = npcFor(ctx, key)
        if not npcId then
            ctx:log('Lore Says: %s has no NPC in the world now', key)
            return 'failed'
        end
        local waitIt = ctx:prop('wait') ~= false
        local bonus = tonumber(ctx:prop('bonus')) or 0
        ctx:call(function()
            local said, w = LoreVoice.sayFrom(npcId, line, { wait = waitIt, bonus = bonus })
            if not said then
                ctx:log('Lore Says %s %s: %s', key, tostring(line), tostring(w))
                return 'failed'
            end
            return 'done'
        end)
        -- A recording that never finishes (the voice bot gone quiet) gives up: Took too long.
        ctx:after(60000, 'timeout')
        return nil
    end,
})
if not ok then print('^1[whip_core:director] card type refused: ' .. tostring(why) .. '^0') end

-- Play Custom Voice Line: a recording of the card's own (its link pasted in, as a line's variant is in the Lore form),
-- said the same way. While the character is already talking it waits its turn, unless set to cut in or be skipped.
local IF_TALKING = { 'say it after', 'cut in', 'skip it' }
local IF_MODE = { ['say it after'] = 'queue', ['cut in'] = 'cut', ['skip it'] = 'skip' }

--- Check: a link a voice line may have (Config.LoreVoice.Links; an mp3, ogg or wav).
local function linkCheck(v)
    if type(v) ~= 'string' or trim(v) == '' then return nil end   -- (empty: the field's required says so)
    return LoreVoice.audioProblem(trim(v))
end

ok, why = DirectorNodes.define({
    type = 'lore.voiceLine', v = 1, category = 'lore', title = 'Play Custom Voice Line',
    desc = 'A lore character plays a recording out loud, from its NPC.',
    help = 'Paste the recording\'s link.',
    outputs = { 'done', 'failed', 'timeout' },
    labels = { done = 'Said', failed = 'Could not', timeout = 'Took too long' },
    latent = true, yields = true,
    props = {
        { key = 'lore', kind = 'lore', label = 'Who' },
        -- (A link the editor plays beside it, and shows on the card by its file's name: its ui.)
        { key = 'url', kind = 'text', label = 'Recording link', required = true, maxLength = 255, check = linkCheck, ui = 'hearLink' },
        { key = 'text', kind = 'text', label = 'Subtitle', maxLength = MAX_TEXT, hint = 'Over its head while it talks (empty: none)' },
        { key = 'busy', kind = 'select', label = 'If it is already talking', options = IF_TALKING, default = IF_TALKING[1] },
        { key = 'wait', kind = 'bool', label = 'Wait until it has been said', default = true },
        bonusProp(),
    },
    run = function(ctx)
        local key = ctx:prop('lore')
        if not DirectorLore.isLive(key) then
            ctx:log('Play Custom Voice Line: no lore character (pick one, or make the NPC that starts the scenario one)')
            return 'failed'
        end
        local url = trim(ctx:prop('url'))
        local bad = LoreVoice.audioProblem(url)
        if bad then
            ctx:log('Play Custom Voice Line: %s', bad)
            return 'failed'
        end
        local npcId = npcFor(ctx, key)
        if not npcId then
            ctx:log('Play Custom Voice Line: %s has no NPC in the world now', key)
            return 'failed'
        end
        local text = trim(ctx:prop('text'))
        local v = { url = url, text = text ~= '' and DirectorKit.cut(text, MAX_TEXT) or nil }
        local waitIt = ctx:prop('wait') ~= false
        local mode = IF_MODE[ctx:prop('busy')] or 'queue'
        local bonus = tonumber(ctx:prop('bonus')) or 0
        ctx:call(function()
            local said, w = LoreVoice.sayRecording(npcId, v, { wait = waitIt, busy = mode, bonus = bonus })
            if not said then
                ctx:log('Play Custom Voice Line %s: %s', key, tostring(w))
                return 'failed'
            end
            return 'done'
        end)
        -- A recording that never finishes (the voice bot gone quiet) gives up: Took too long.
        ctx:after(60000, 'timeout')
        return nil
    end,
})
if not ok then print('^1[whip_core:director] card type refused: ' .. tostring(why) .. '^0') end

-- ============================================
-- Export
-- ============================================

--- A lore character says one of its voice lines, from its NPC in the world.
---
---     exports.whip_core:LoreSay('irwin', 'positive', { near = source })
---
--- `true`, or `false, why`. WAITS (the recording is fetched; with opts.wait, until it has been said).
exports('LoreSay', function(key, line, opts)
    opts = type(opts) == 'table' and opts or {}
    if not DirectorLore.isLive(key) then return false, 'No lore character called ' .. tostring(key) end
    local npcId = LoreVoice.npcOf(key, { npcId = tonumber(opts.npcId), near = tonumber(opts.near) })
    if not npcId then return false, 'it has no NPC in the world now' end
    return LoreVoice.sayFrom(npcId, line, { wait = opts.wait == true, busy = opts.busy, bonus = tonumber(opts.bonus) })
end)
