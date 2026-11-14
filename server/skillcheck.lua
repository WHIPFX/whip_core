-- ============================================
-- Server-driven skill check
-- ============================================
--
-- The client export's result is a client CLAIM ("did you pass?"), fine when the outcome is cosmetic
-- and useless when a real reward hangs on it. This one is run by the server.
--
-- What it defends, three things:
--
--   1. A one-shot TOKEN. A client cannot announce that it passed a check nobody asked it to
--      take, and cannot answer the same challenge twice.
--   2. A MINIMUM ELAPSED TIME. A client cannot answer faster than the minigame can physically
--      be played, so "reply instantly with success" stops working.
--   3. A TIMEOUT. A client that never answers resolves to a failure rather than leaking a
--      coroutine that waits forever.
--
-- What it does NOT defend: a cheater who waits the honest amount of time and then lies. No
-- client-side minigame can. Cheating costs the same wall-clock time as playing, which removes the
-- profit from automating it. If an outcome must be uncheatable, do not gate it on a minigame.

local Skill = {}

--- token -> { source, startTime, minMs, promise, done }
local _pending = {}
local _nextToken = 0

-- ============================================
-- Skill check games from other resources
-- ============================================
--
-- The ring is whip_core's own skill check. A resource may add GAMES of its own (whip_phone's, played on the
-- phone), and anything that runs a skill check asks for one by its id: SkillCheck(source, 'hard', { game =
-- 'phone.reroute' }), or the Director's Skill Check card's Game field. Everything else is the same check: the
-- token, the floor, the timeout, the run's tag, the answer.
--
-- A game is registered on both sides, with Whip.skillCheckGame (lib/satellite.lua):
--   server  { label, desc?, levels = { easy = { minMs, timeoutMs }, ... }, canStart = fn(source) -> true | false, words }
--   client  { run = fn(difficulty) -> passed, why }   (in a thread of its own: it may wait)
-- canStart is what a player must have to play it at all (the phone's games: a phone). Someone who has not is told
-- the words, nothing starts, and the check answers false, 'not started': never a fail.
--
-- whip_core holds the game as data and ONE function of the owner's, its entry: entry('canStart', { source })
-- runs canStart inside a pcall on the owner's side and answers { ok, words } or { err } (a function from another
-- resource throws with no message when it fails here).

local GAME_ID = '^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$'
local LEVEL = '^[a-z][a-z0-9_]*$'

local _gameListeners = {}

local function gamesChanged()
    for _, fn in ipairs(_gameListeners) do
        local ok, err = pcall(fn)
        if not ok then print(('[whip_core] a skill check game listener failed: %s'):format(tostring(err))) end
    end
end

local Games = Registry.new('skillCheckGame', {
    label = 'skill check game',
    same = false,   -- every registration carries a fresh entry function
    onAdd = function() gamesChanged() end,
    onRemove = function(key)
        -- Its checks under way end with it: their players' screens are told, and their callers hear 'cancelled'.
        for token, entry in pairs(_pending) do
            if not entry.done and entry.game == key then
                entry.done = true
                _pending[token] = nil
                entry.promise:resolve({ false, 'cancelled' })
                TriggerClientEvent('whip_core:client:serverSkillCheckCancel', entry.source, token)
            end
        end
        gamesChanged()
    end,
})

--- A function, or one from another resource (a callable table: never index it).
local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

--- The game as whip_core keeps it, or nil and why.
local function gameOf(id, spec, entry)
    if type(id) ~= 'string' or #id > 48 or not id:match(GAME_ID) then
        return nil, 'a skill check game id is "<yours>.<name>" in lowercase letters, digits and _ (48 at most)'
    end
    if type(spec) ~= 'table' or callable(spec) then return nil, id .. ': the game is a table' end
    if type(spec.label) ~= 'string' or spec.label == '' or #spec.label > 40 then
        return nil, id .. ': label is its name, up to 40 characters'
    end
    if spec.desc ~= nil and (type(spec.desc) ~= 'string' or #spec.desc > 200) then
        return nil, id .. ': desc is a line of text, up to 200 characters'
    end
    if type(spec.levels) ~= 'table' or callable(spec.levels) then
        return nil, id .. ': levels is { easy = { minMs, timeoutMs }, ... }'
    end
    local levels, names = {}, {}
    for name, lv in pairs(spec.levels) do
        if type(name) ~= 'string' or not name:match(LEVEL) or #name > 24 then
            return nil, ('%s: level "%s" must be a lowercase word'):format(id, tostring(name))
        end
        if type(lv) ~= 'table' or callable(lv) then return nil, ('%s: level %s is { minMs, timeoutMs }'):format(id, name) end
        local minMs, timeoutMs = tonumber(lv.minMs), tonumber(lv.timeoutMs)
        if not minMs or not (minMs >= 0) or minMs == math.huge then
            return nil, ('%s: level %s needs minMs, how fast it can honestly be played (0 or more)'):format(id, name)
        end
        if not timeoutMs or not (timeoutMs >= 1000) or timeoutMs > 120000 then
            return nil, ('%s: level %s needs timeoutMs, 1000 to 120000'):format(id, name)
        end
        if minMs >= timeoutMs then
            return nil, ('%s: level %s: minMs must be shorter than timeoutMs'):format(id, name)
        end
        levels[name] = { minMs = math.floor(minMs), timeoutMs = math.floor(timeoutMs) }
        names[#names + 1] = name
    end
    if #names == 0 then return nil, id .. ': it needs at least one level' end
    if #names > 8 then return nil, id .. ': 8 levels at most' end
    SortSkillLevels(names)
    if spec.canStart ~= nil and spec.canStart ~= true then
        return nil, id .. ': canStart goes through Whip.skillCheckGame (lib/satellite.lua)'
    end
    if spec.canStart == true and not callable(entry) then
        return nil, id .. ': a game with canStart needs its entry (use Whip.skillCheckGame)'
    end
    return {
        id = id, label = spec.label, desc = spec.desc, levels = levels, levelNames = names,
        needs = spec.canStart == true, entry = spec.canStart == true and entry or nil,
    }
end

--- The skill check games on this server: whip_core's other games (never the ring).
SkillGames = {}

--- One game, or nil.
---@param id string
---@return table|nil game  { id, label, desc, levels = { [name] = { minMs, timeoutMs } }, levelNames, needs, owner }
function SkillGames.get(id)
    local g = type(id) == 'string' and Games:get(id) or nil
    if g then g.owner = Games:ownerOf(id) end
    return g
end

--- Every game, by label: { { id, label, desc, levels = { names... }, needs, owner }, ... }.
---@return table
function SkillGames.list()
    local out = {}
    for id, g in pairs(Games.entries) do
        out[#out + 1] = { id = id, label = g.label, desc = g.desc, levels = g.levelNames, needs = g.needs, owner = Games:ownerOf(id) }
    end
    table.sort(out, function(a, b) return a.label < b.label or (a.label == b.label and a.id < b.id) end)
    return out
end

--- Hear games come and go (the Director's Skill Check card lists them). Called after each change, never yields.
---@param fn function
function SkillGames.onChange(fn) _gameListeners[#_gameListeners + 1] = fn end

--- May this player start this game? true, or false and the words they are told. A game with no canStart: true.
--- May wait (the owner's canStart asks its own server state).
local function mayStart(g, source)
    if not g.needs then return true end
    local ok, res = pcall(g.entry, 'canStart', { source = source })
    if not ok or type(res) ~= 'table' then
        print(('[whip_core] skill check game %s: its canStart could not be asked (%s)'):format(g.id, tostring(ok and 'no answer' or res)))
        return false, "That can't be done right now"
    end
    if res.err then
        print(('[whip_core] skill check game %s: canStart failed: %s'):format(g.id, tostring(res.err)))
        return false, "That can't be done right now"
    end
    if res.ok == true then return true end
    return false, type(res.words) == 'string' and res.words ~= '' and res.words:sub(1, 120) or "You can't do that right now"
end

--- RegisterSkillCheckGame(id, spec, entry) -> true | false, why. Use Whip.skillCheckGame, which builds both.
exports('RegisterSkillCheckGame', function(id, spec, entry)
    local owner = Registry.caller()
    local g, why = gameOf(id, spec, entry)
    if not g then return false, why end
    return Games:add(owner, id, g)
end)

--- RemoveSkillCheckGame(id) -> true | false, why. Only your own (they go by themselves when your resource stops).
exports('RemoveSkillCheckGame', function(id)
    local owner = Registry.caller()
    return Games:remove(owner, id)
end)

--- ListSkillCheckGames() -> { { id, label, desc, levels, needs, owner }, ... }: every game but the ring.
exports('ListSkillCheckGames', function() return SkillGames.list() end)

--- How fast can this check honestly be answered?
---
--- Every round's lit part has to fill under the dot, and filling takes holdMs whatever the hand
--- does — so the rounds times holdMs is a floor no honest player can beat. Deliberately just that,
--- with nothing added for moving the dot or the flash between rounds: this is a floor, not an
--- estimate. Setting it too high rejects honest players on a bad frame, which is a far worse
--- failure than letting a patient cheat land.
local function minimumMs(level)
    return math.max(300, math.floor(#level.rounds * level.holdMs))
end

--- Run a skill check on a player's screen and get a result the server can act on.
---
--- Blocks the calling coroutine until the client answers, the answer is rejected, or the check
--- times out. Safe to call from inside a SecureEvent/SecureCallback handler.
---
--- `difficulty` is a name from Config.SkillCheckDifficulty ('easy', 'medium' or 'hard'), as the
--- client export takes it, or `{ level = { ... } }`: the ring with the caller's own numbers
--- (shared/skillcheck.lua), timed from them.
---
--- Answers `true`, or `false, why` in the client export's words: 'failed', 'busy' (another bar or
--- dialog was up), 'cancelled', 'timeout', plus 'too fast' (answered quicker than it can be played),
--- 'dead' (passed while dead) and 'Player not loaded'. A bad argument (a difficulty that is not in
--- the config, a minMs that does not fit inside the timeout) answers a sentence naming it.
---
--- A `tag` (opts.tag, the caller's run tag) ties the check to a run: ReleaseTag(tag) ends it at once,
--- answering 'cancelled' and taking it off their screen (the Director's Reset, a run's end). A tag
--- already released is refused ('run ended'). A player who is down is not shown one ('dead').
---
--- `opts.game` plays another resource's game instead of the ring (see "Skill check games" above): the
--- difficulty is then one of that game's levels, and its minMs and timeoutMs are the defaults. A player
--- the game cannot start for (whip_phone's: no phone) is told why, and the answer is false, 'not
--- started', with nothing shown (`opts.quiet`: not told). 'unavailable': their game has no such game.
---@param source number|string|nil
---@param difficulty string|table|nil  'easy' | 'medium' | 'hard' (default 'medium') — as the client export
---@param opts table|nil    { timeoutMs?: number, minMs?: number, tag?: string, game?: string, quiet?: boolean }
---@param owner string|nil  the resource asking (Registry.caller() in the export); default whip_core
---@return boolean passed
---@return string|nil why  only with false
function Skill.run(source, difficulty, opts, owner)
    source = tonumber(source)
    local who = source and Players[source]
    if not who then return false, 'Player not loaded' end
    -- Not for a session on its way out, as Progress (see timed_action.lua).
    if who.closing then return false, 'Player not loaded' end
    -- Not for someone who is down: a pass from the floor counts for nothing ('dead', below), and the
    -- ring would hold every control of a downed player for its clock.
    if who.isDead then return false, 'dead' end
    owner = owner or GetCurrentResourceName()
    local tag = type(opts) == 'table' and opts.tag or nil
    if tag ~= nil and (type(tag) ~= 'string' or tag == '') then return false, 'opts.tag is the run tag, a string' end
    if tag ~= nil and not Registry.claimTag(owner, tag) then return false, 'run ended' end

    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts must be a table' end
    opts = opts or {}

    -- Another resource's game, or the ring. A difficulty the ring (or the game) cannot be played at is
    -- refused here, with the reason, so the caller never hears 'failed' for the developer's mistake: the
    -- ring by the same reading the client draws from (shared/skillcheck.lua).
    local game = nil
    local level, bad
    if opts.game ~= nil and opts.game ~= 'ring' then
        game = SkillGames.get(opts.game)
        if not game then
            return false, ("no skill check game called '%s' (is the resource that adds it running?)"):format(tostring(opts.game))
        end
        local name = type(difficulty) == 'table' and difficulty.difficulty or difficulty
        if name == nil then name = 'medium' end
        local lv = type(name) == 'string' and game.levels[name] or nil
        if not lv then
            return false, ("%s has no '%s' level (it has %s)"):format(game.label, tostring(name), table.concat(game.levelNames, ', '))
        end
        level = { name = name, minMs = lv.minMs, timeLimitMs = lv.timeoutMs }
    else
        level, bad = SkillCheckLevel(difficulty)
        if not level then return false, bad end
    end

    -- One at a time, as bars are: the honest client answers 'busy' to a second check, a modified one
    -- would play several at once.
    for _, entry in pairs(_pending) do
        if entry.source == source and not entry.done then return false, 'busy' end
    end

    -- WHAT THE GAME NEEDS TO START (Josh, 31 Oct 2026: the phone's games need a phone): someone without it
    -- is told, and nothing starts. Not a fail: pressing the button again with a phone works.
    if game then
        local may, words = mayStart(game, source)
        if not may then
            if not opts.quiet and Players[source] then NotifyPlayer(source, words, 'error') end
            return false, 'not started'
        end
        -- (canStart may have waited: the player may have gone down, or left, meanwhile.)
        who = Players[source]
        if not who or who.closing then return false, 'Player not loaded' end
        if who.isDead then return false, 'dead' end
        for _, entry in pairs(_pending) do
            if entry.source == source and not entry.done then return false, 'busy' end
        end
    end

    _nextToken = _nextToken + 1
    local token = _nextToken

    -- Finite and not negative, as Progress holds its duration (a NaN or negative minimum would remove
    -- the anti-cheat floor). 0 is allowed: a caller may mean "no floor". A game says its own floor.
    local minMs = tonumber(opts.minMs)
    if not minMs or not (minMs >= 0) or minMs == math.huge then minMs = level.minMs or minimumMs(level) end

    -- The default follows the ring's own clock: the ring fails itself when its clock runs out
    -- (msPerPart times the parts, per difficulty: shared/skillcheck.lua), so the server waits that
    -- long plus two seconds (the miss shown before the answer, and the round trip).
    --
    -- Run checks from a SecureEvent, not a SecureCallback: whip_core's client-side Callback gives up
    -- after CALLBACK_TIMEOUT, 10 seconds (client/callback.lua), and the ring's hard (9.2 s) and medium
    -- (7.2 s) don't leave room. The player would see the action fail while the server commits it.
    --
    -- The floor above is what stops cheating; the timeout is only about not stranding a caller. A
    -- caller's own timeout is held to 1-60 seconds (NaN or infinity would never come due).
    --
    -- A game says its own timeout (its clock, the phone coming out, the round trip), up to two minutes.
    local maxTimeout = game and 120000 or 60000
    local timeoutMs = tonumber(opts.timeoutMs)
    if timeoutMs and (timeoutMs > 0) and timeoutMs ~= math.huge then
        timeoutMs = math.max(1000, math.min(maxTimeout, timeoutMs))
    elseif game then
        timeoutMs = level.timeLimitMs
    else
        timeoutMs = math.min(60000, math.floor(level.timeLimitMs) + 2000)
    end

    -- A floor the check can clear: a minMs at or past the timeout could never be passed. Refused with
    -- the reason, never lowered (lowering it could make the floor 0).
    if minMs >= timeoutMs then
        return false, ('minMs (%s) must be shorter than timeoutMs (%s) — pass a longer opts.timeoutMs')
            :format(tostring(minMs), tostring(timeoutMs))
    end

    local p = promise.new()
    _pending[token] = {
        source    = source,
        startTime = GetGameTimer(),
        minMs     = minMs,
        promise   = p,
        done      = false,
        session   = who.session,   -- the character it was asked of
        owner     = owner,
        tag       = tag,           -- ReleaseTag(tag) ends it (see the release below)
        game      = game and game.id or nil,   -- another resource's game (its stop ends the check)
    }

    -- The NAME goes, not the level: the client reads the same config (shared/skillcheck.lua). A caller's
    -- own numbers go as they are, read again there the same way. A game's id goes with it: the player's
    -- game plays it (the owner's client half).
    TriggerClientEvent('whip_core:client:serverSkillCheck', source, token, level.own and { level = level.own } or level.name,
        game and game.id or nil)

    -- The timeout is what makes this safe to await. Without it, a client that closes the game
    -- mid-check leaves the calling handler suspended and, if that handler took a lock, holding it.
    SetTimeout(timeoutMs, function()
        local entry = _pending[token]
        if entry and not entry.done then
            entry.done = true
            _pending[token] = nil
            entry.promise:resolve({ false, 'timeout' })
            -- And the player's screen is told, or the minigame stays up with the keyboard held.
            TriggerClientEvent('whip_core:client:serverSkillCheckCancel', entry.source, token)
        end
    end)

    -- Resolved with { passed, why } — a promise carries one value.
    local result = Citizen.Await(p)
    _pending[token] = nil
    if type(result) == 'table' and result[1] == true then return true end
    return false, (type(result) == 'table' and result[2]) or 'failed'
end

--- The client's answer.
---
--- Declared through SecureEvent so the token and the flag are bounds-checked before this handler
--- ever runs, and so the rate limit is one line rather than a hand-written guard.
SecureEvent('whip_core:server:skillCheckResult', {
    rateLimit = 250,
    -- A player who dies mid-check still answers, or the caller (and any lock it holds) waits out the
    -- timeout. A PASS from a dead player is still a failure (below, the same rule as the server bar's).
    whileDead = true,
    params = {
        {'token', 'id'},   -- names one pending check: rejected when malformed, never clamped to 1
        {'success', 'bool'},
        -- Why it did not pass, in the client export's words. Only the words the UI library uses
        -- get through; anything else reads as a plain failure. 'unavailable': a game their game
        -- does not have (its resource is not running there).
        {'why', 'enum', { 'failed', 'busy', 'cancelled', 'timeout', 'unavailable', '' }, ''},
    },
}, function(source, player, token, success, why)
    local entry = _pending[token]

    -- No such challenge, already answered, or answered by someone the challenge was not sent to.
    -- All three are the same thing from here: this reply is not evidence of anything.
    if not entry or entry.done or entry.source ~= source then
        RecordEventRejection('whip_core:server:skillCheckResult', source,
            'reply did not match an open challenge')
        return
    end
    -- The same character, not only the same source (as a bar's answer).
    if entry.session ~= nil and (not player or player.session ~= entry.session) then
        RecordEventRejection('whip_core:server:skillCheckResult', source, 'reply came from a different character session')
        return
    end

    entry.done = true
    _pending[token] = nil

    -- A failure is taken as said, whenever it comes: nobody cheats their way to a fail. That also
    -- keeps an honest instant 'busy' (another screen was up) from being logged as 'too fast'.
    if success ~= true then
        entry.promise:resolve({ false, (why ~= nil and why ~= '') and why or 'failed' })
        return
    end

    -- Dead players pass nothing (as the bar): the server's own death record.
    if player and player.isDead then
        entry.promise:resolve({ false, 'dead' })
        return
    end

    local elapsed = GetGameTimer() - entry.startTime
    if elapsed < entry.minMs then
        -- Too fast to have been played. Resolved as a FAILURE rather than ignored: ignoring it
        -- would leave the caller waiting for the timeout, which turns a cheat attempt into a
        -- fifteen-second stall for everyone in the same handler.
        entry.promise:resolve({ false, 'too fast' })
        RecordEventRejection('whip_core:server:skillCheckResult', source,
            ('answered in %dms, minimum is %dms'):format(elapsed, entry.minMs))
        return
    end

    entry.promise:resolve({ true })
end)

--- Drop anything owed to a player who left, so their promises resolve instead of hanging.
---
--- The timeout above would eventually do this anyway; doing it on disconnect means a handler
--- waiting on someone who alt-F4'd is freed now rather than fifteen seconds from now.
local function dropPendingFor(src)
    for token, entry in pairs(_pending) do
        if entry.source == src and not entry.done then
            entry.done = true
            _pending[token] = nil
            entry.promise:resolve({ false, 'Player not loaded' })
            -- Their screen too, on a logout (a dropped player's client is gone, and hears nothing).
            TriggerClientEvent('whip_core:client:serverSkillCheckCancel', src, token)
        end
    end
end

AddEventHandler('playerDropped', function()
    dropPendingFor(source)
end)

--- And on a logout, as timed actions end then (timed_action.lua), so a check can't answer for the
--- character who left.
---
--- WhipPlayer:logout calls this directly, BEFORE it waits for the player's running handlers: a
--- handler waiting on a check is one of them. (Not an event handler: any resource could fire that.)
---@param src number
function EndSkillChecksFor(src)
    dropPendingFor(src)
end

--- A run's end takes its check down: a check asked with a tag ends when that tag is released
--- (ReleaseTag: the Director's Reset, abort or end), answering 'cancelled', and the ring comes off
--- that player's screen. Never waits.
Registry.onRelease('skillCheck', 5, function(owner, tag)
    local n = 0
    for token, entry in pairs(_pending) do
        if not entry.done and entry.owner == owner and entry.tag == tag then
            entry.done = true
            _pending[token] = nil
            entry.promise:resolve({ false, 'cancelled' })
            TriggerClientEvent('whip_core:client:serverSkillCheckCancel', entry.source, token)
            n = n + 1
        end
    end
    return n
end, function(owner, tag)
    local out = {}
    for token, entry in pairs(_pending) do
        if not entry.done and entry.owner == owner and entry.tag == tag then out[#out + 1] = { key = token } end
    end
    return out
end)

--- Run a skill check on a player's screen, server-side.
---
--- The result is verified — see the notes at the top of this file for exactly what that means
--- and what it does not. Blocks until the client answers or the check times out.
---
--- ```lua
--- local passed, why = exports.whip_core:SkillCheck(source, 'medium')
--- if passed then
---     -- safe to hand over the reward here
--- end
--- ```
--- Another resource's game instead of the ring (ListSkillCheckGames names them):
---
--- ```lua
--- local passed, why = exports.whip_core:SkillCheck(source, 'hard', { game = 'phone.reroute' })
--- if why == 'not started' then return end   -- they had no phone: told so, and nothing happened
--- ```
---@param source number
---@param difficulty string|table|nil  'easy' | 'medium' | 'hard' (Config.SkillCheckDifficulty, or the game's levels; default 'medium')
---@param opts table|nil { timeoutMs?, minMs?, tag?, game?, quiet? }
---@return boolean passed
---@return string|nil why  'failed' | 'busy' | 'cancelled' | 'timeout' | 'too fast' | 'dead' | 'run ended' | 'Player not loaded'
---                        | 'not started' (a game they could not start: told why) | 'unavailable' (their game lacks it)
---
--- From another resource, `Whip.call('SkillCheck', source, ...)` is the safer spelling: if whip_core
--- restarts mid-check, the wait here dies with it and the export never answers.
exports('SkillCheck', function(source, difficulty, opts)
    local caller = Registry.caller()   -- first, before anything can yield: the owner of opts.tag
    return Skill.run(source, difficulty, opts, caller)
end)

-- `_ENV.`, not `Skill =` (the local above would assign itself), as timed_action.lua.
_ENV.Skill = Skill

--- The skill check whip's own lockpicks (cars, doors) and ignition hack play: Config.LockpickGame, 'ring' (whip's)
--- or a game another resource adds (RegisterSkillCheckGame). One that is not running when a lock is picked is said
--- once in the console, and the ring is played: a stopped resource must not leave every lock unpickable. Judged
--- like any check, with a one-second floor (an honest quick pass is about 1.5 s).
local lockpickGameMissingSaid = nil
---@param source number
---@param difficulty 'medium'|'hard'
---@return boolean passed
---@return string|nil why
function LockpickSkill(source, difficulty)
    local opts = { minMs = 1000 }
    local game = Config.LockpickGame
    if type(game) == 'string' and game ~= '' and game ~= 'ring' then
        if SkillGames.get(game) then
            opts.game = game
        elseif lockpickGameMissingSaid ~= game then
            lockpickGameMissingSaid = game
            print(("^3[whip_core] Config.LockpickGame is '%s', and no skill check game of that name is running: lockpicks play the ring^7"):format(game))
        end
    end
    return Skill.run(source, difficulty, opts)
end
