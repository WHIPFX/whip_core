-- ============================================
-- Server-timed actions: a progress bar the server can believe
-- ============================================
--
-- A progress bar runs on the player's machine, so "the bar finished" is a client CLAIM (the same
-- problem skillcheck.lua describes for "I passed"). This remembers when the use started and refuses
-- a finish that comes back sooner than the bar could have filled.
--
-- How to use it: two calls, both on the server:
--
--   1. When the action STARTS. Usually the item's use handler, which already runs on the server and
--      is handed the item's address:
--
--        exports.whip_core:StartTimedAction(source, 'drink', 5000, addr)
--
--   2. When the client says it FINISHED, before handing anything over:
--
--        local addr = exports.whip_core:FinishTimedAction(source, 'drink')
--        if not addr then return end
--        -- addr is what step 1 was given: the drink the use STARTED from
--
-- The duration is the SAME number the client's progress bar uses. The last argument of the start is
-- optional, and whatever is in it comes back from the finish — so the client never has to say which
-- slot it used, and cannot say a different one. Passing a table to the finish as well still works,
-- and then it must match exactly. Names only need to be unique within your own resource.
--
-- If the action starts on the CLIENT instead (an aim-target, an interaction prompt), give it a small
-- "starting" SecureCallback that checks what it can, calls StartTimedAction, and answers before the
-- bar is shown. Or use Progress (below), where the server shows the bar itself.
--
-- What it defends, the same three things Skill.run does:
--
--   1. A finish nobody started is refused, and every start can be finished once.
--   2. A finish that arrives sooner than the bar could have filled is refused.
--   3. A start that is never finished expires, rather than waiting forever to be collected.
--
-- What it does NOT defend: a cheater who waits the full time and only skips the animation. That
-- costs them exactly what it costs an honest player, which is the point.

local TimedAction = {}

local RESOURCE = GetCurrentResourceName()

--- How much earlier than the full duration a finish may arrive and still count.
---
--- The server's clock starts when IT decides the action started, and an honest finish only
--- arrives after the bar has run AND the message has crossed the network — so it is normally LATER
--- than the duration, not earlier. The slack covers the one exception: an action the client
--- starts, where the start and the finish each make one trip and the first can be delayed more
--- than the second. 10% (4.5s for a 5s bar).
local SLACK = 0.9

--- How long after the duration a finish is still accepted.
---
--- Covers a client that loads an animation and a prop before its bar starts (whip_drunk_example waits up
--- to four seconds for both) plus a slow connection. Past this, the start is stale.
local GRACE_MS = 15000

--- [source] = { ['<resource>:<name>'] = { at, minMs, expiresAt, match, owner } }
local _active = {}

local function keyFor(owner, name)
    return owner .. ':' .. name
end

--- Keep only plain values — numbers, strings, booleans — and tables of them, COPIED. A table can
--- cross an export boundary and come back as a different table, so what is kept is compared by
--- value (sameMatch).
---
--- Nested tables come back too (a 'slot' param's `{ addr = { kind, id, sub, slot } }`), three levels
--- deep at most. Vectors too, kept as plain { x, y, z, w } tables (a vector3 is not a 'table' to
--- type()).
local VECTOR_TYPES = { vector2 = true, vector3 = true, vector4 = true }

local function copyMatch(match, depth)
    depth = depth or 0
    if type(match) ~= 'table' or depth > 3 then return {} end
    local out = {}
    for k, v in pairs(match) do
        local t = type(v)
        if t == 'number' or t == 'string' or t == 'boolean' then
            out[k] = v
        elseif VECTOR_TYPES[t] then
            out[k] = { x = v.x, y = v.y, z = t ~= 'vector2' and v.z or nil, w = t == 'vector4' and v.w or nil }
        elseif t == 'table' and rawget(v, '__cfx_functionReference') == nil then
            out[k] = copyMatch(v, depth + 1)
        end
    end
    return out
end

local function sameMatch(a, b)
    for k, v in pairs(a) do
        if type(v) == 'table' then
            if type(b[k]) ~= 'table' or not sameMatch(v, b[k]) then return false end
        elseif b[k] ~= v then
            return false
        end
    end
    for k, v in pairs(b) do
        if a[k] == nil and v ~= nil then return false end
    end
    return true
end

--- Start timing an action for a player. Starting the same action again restarts its clock.
---@param source number|string|nil
---@param name string        unique within the calling resource
---@param durationMs number|string|nil  the progress bar's length, the same number the client uses
---@param match table|nil    plain values the finish must repeat exactly
---@param owner string|nil   the resource the action belongs to (the exports fill this in)
---@return boolean started
---@return string|nil reason  why not
function TimedAction.start(source, name, durationMs, match, owner)
    source = tonumber(source)
    if not source or not Players[source] then return false, 'no loaded player on that source' end
    if type(name) ~= 'string' or name == '' then return false, 'a timed action needs a name' end

    durationMs = tonumber(durationMs)
    -- Written as `not (x > 0)` so NaN is refused too: every comparison with NaN is false.
    if not durationMs or not (durationMs > 0) or durationMs == math.huge then
        return false, 'durationMs must be a number of milliseconds above 0'
    end

    owner = owner or RESOURCE
    local now  = GetGameTimer()
    local mine = _active[source]
    if not mine then
        mine = {}
        _active[source] = mine
    end

    mine[keyFor(owner, name)] = {
        at        = now,
        minMs     = math.floor(durationMs * SLACK),
        expiresAt = now + durationMs + GRACE_MS,
        match     = copyMatch(match),
        owner     = owner,
    }
    return true
end

--- The client says the action finished. Only if it was started, long enough ago and recently
--- enough — and, when `match` is passed, with the same match values. Refusals are recorded in the
--- Event Monitor.
---
--- The answer is what the start was given: the match table, always a table, so it is truthy. That is
--- how a finish learns WHICH item the use started from without the client naming it: pass no match,
--- get the start's back.
---@param source number|string|nil
---@param name string
---@param match table|nil  omit to take the start's values as they are
---@param owner string|nil
---@return table|false started  the start's match values
---@return string|nil reason  why it was refused
function TimedAction.finish(source, name, match, owner)
    source = tonumber(source)
    if not source then return false, 'no player' end

    local key   = keyFor(owner or RESOURCE, tostring(name))
    local mine  = _active[source]
    local entry = mine and mine[key]

    -- One-shot, whatever happens next: a refused finish must not leave its start behind for a second
    -- attempt.
    if mine then mine[key] = nil end

    local reason
    if not entry then
        reason = 'finished without being started'
    else
        local now = GetGameTimer()
        local elapsed = now - entry.at
        if elapsed < entry.minMs then
            reason = ('finished in %dms, minimum is %dms'):format(elapsed, entry.minMs)
        elseif now > entry.expiresAt then
            reason = ('finished %dms after it started, which is too late'):format(elapsed)
        elseif match ~= nil and not sameMatch(entry.match, copyMatch(match)) then
            reason = 'finished a different action from the one that was started'
        end
    end

    if reason then
        RecordEventRejection(key, source, reason)
        return false, reason
    end
    -- A copy of what the start was given (see above); plain values only, so a table as an answer.
    local started = {}
    for k, v in pairs(entry.match) do started[k] = v end
    return started
end

-- ============================================
-- A bar the server shows and waits for
-- ============================================
--
-- The same promise as Start/Finish in ONE call: the server shows the bar and waits for the answer,
-- the way Skill.run waits for a skill check (a one-shot token, a minimum time, a timeout):
--
--     if exports.whip_core:Progress(source, { label = 'Drinking...', duration = 5000,
--             anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' } }) then
--         -- the bar really ran; hand over whatever it was for
--     end
--
-- It BLOCKS the calling handler for the length of the bar, which is what makes it one call. Safe in
-- a use handler or a SecureEvent handler; not in a SecureCallback longer than the client's
-- 10-second patience (see skillcheck.lua).

--- [token] = { source, at, minMs, promise, done }
local _bars = {}
local _barToken = 0
--- [source] = that player's latest bar entry; running while `not entry.done`
local _barOf = {}

--- Only plain data goes to the client, and only the options the bar understands.
local function barOpts(opts, duration)
    local function plain(t)
        if type(t) ~= 'table' then return nil end
        local out = {}
        for k, v in pairs(t) do
            local tv = type(v)
            if tv == 'string' or tv == 'number' or tv == 'boolean' then out[k] = v
            elseif tv == 'table' then out[k] = plain(v) end
        end
        return out
    end
    -- What the bar is done with: an item's key, or a slot's data { item, metadata }. Its picture is the disc's.
    local item = opts.item
    if type(item) == 'table' then
        item = type(item.item) == 'string' and { item = item.item, metadata = plain(item.metadata), amount = tonumber(item.amount) } or nil
    elseif type(item) ~= 'string' then
        item = nil
    end
    return {
        label         = type(opts.label) == 'string' and opts.label or nil,
        -- The disc of the capsule the bar is drawn in: a glyph's name (html/js/glyphs.js).
        icon          = type(opts.icon) == 'string' and opts.icon or nil,
        item          = item,
        duration      = duration,
        canCancel     = opts.canCancel == true,
        anim          = plain(opts.anim),
        -- (No prop: the server puts it in the hand itself — see TimedAction.progress.)
        disable       = plain(opts.disable),
        cancelOnDeath = opts.cancelOnDeath ~= false,
        cancelOnExit  = opts.cancelOnExit == true,
        -- Read again there (BodyState.readList): checked here before it was sent.
        notWhile      = plain(opts.notWhile),
    }
end

--- A finite number, or nil. NaN and the infinities are not places.
local function finite(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

--- `opts.near`, checked: { vehicleId, range } or { x, y, z, range }. nil for none, or nil and why.
---
--- A leash on the bar: a SecureEvent's `near` is checked once, when the event arrives; `near` here is
--- asked again when the bar says it finished.
---
--- The SecureEvent spelling works here too: `at` = a vector3 / { x, y, z } is `coords`, and
--- `at = 'vehicle'` with a `vehicle` is the car.
local function nearOf(n)
    if type(n) ~= 'table' then return nil, 'near must be a table: { coords = vector3, range = 3.0 } or { vehicle = vehicleId, range = 3.0 }' end
    local range = finite(n.range)
    if not range or range <= 0 then return nil, 'near.range must be a positive number of metres' end
    if n.at == 'vehicle' and n.vehicle == nil then
        return nil, "near.at = 'vehicle' needs near.vehicle (the vehicleId) — a bar has no event params to take it from"
    end
    if n.vehicle ~= nil then
        local vehicleId, err = Vehicles.idFromRef(n.vehicle)
        if not vehicleId then return nil, err end
        return { vehicleId = vehicleId, range = range }
    end
    local c = n.coords
    if c == nil then
        local t = type(n.at)
        if t == 'table' or t == 'vector3' or t == 'vector4' then c = n.at
        elseif n.at ~= nil then
            return nil, 'near.at here is a place (a vector3) — a function is the SecureEvent form, and a bar reads a place once'
        end
    end
    local x, y, z = c and finite(c.x), c and finite(c.y), c and finite(c.z)
    if not (x and y and z) then return nil, 'near needs coords (a vector3) or a vehicle' end
    return { x = x, y = y, z = z, range = range }
end

local function stillNear(source, near)
    if near.vehicleId then return IsPlayerNearVehicle(source, near.vehicleId, near.range) end
    return IsPlayerNear(source, near.x, near.y, near.z, near.range)
end

--- Show a progress bar on a player's screen and wait for it.
---
--- A `tag` (opts.tag, the owner's run tag) ties the bar to a run: ReleaseTag(tag) ends it at once,
--- answering 'cancelled' and taking it off their screen (the Director's Reset, a run's end). A tag
--- already released is refused ('run ended'). A player who is down is not shown one ('dead'),
--- unless cancelOnDeath = false says the bar is for the downed.
---
--- `cancelOnExit`: work done from a seat (a nitrous install). The player must be in a vehicle to start it ('not in a vehicle'); their game ends the bar as
--- they get out, and an answer of "done" from someone no longer in that vehicle is not one ('left the vehicle').
---
--- `notWhile` = { 'swimming', 'underwater', 'falling' }: the player's game does not start the bar in any of them
--- ('refused'), and ends it as one begins ('cancelled'), saying why on the capsule either way. The server cannot see the
--- body, so this is their game's check (shared/body_state.lua).
---@param source number|string|nil
---@param opts table  { label, duration, canCancel, anim, prop, disable, cancelOnDeath, cancelOnExit, notWhile, icon, item, near, tag } — the client Progress's options, plus `near` and `tag`
---@param owner string|nil  the resource asking
---@return boolean completed
---@return string|nil why  'busy' | 'cancelled' | 'refused' | 'timeout' | 'too fast' | 'too far' | 'dead' | 'not in a vehicle' | 'left the vehicle' | 'player left' | 'run ended' | a refusal
function TimedAction.progress(source, opts, owner)
    source = tonumber(source)
    local who = source and Players[source]
    if not source or not who then return false, 'Player not loaded' end
    -- Not for a session on its way out: logout ends every bar before it drains, and a new one asked
    -- for inside the drain would outlive the character.
    if who.closing then return false, 'player left' end
    if type(opts) ~= 'table' then return false, 'Progress needs an options table' end
    -- Not for someone who is down: the bar would only be cancelled by their death watch.
    if who.isDead and opts.cancelOnDeath ~= false then return false, 'dead' end
    owner = owner or RESOURCE
    local tag = opts.tag
    if tag ~= nil and (type(tag) ~= 'string' or tag == '') then return false, 'opts.tag is the run tag, a string' end
    if tag ~= nil and not Registry.claimTag(owner, tag) then return false, 'run ended' end
    local duration = tonumber(opts.duration)
    if not duration or not (duration > 0) or duration == math.huge then
        return false, 'duration must be a positive number of milliseconds'
    end
    local notWhileOk, notWhileErr = BodyState.readList(opts.notWhile)
    if not notWhileOk then return false, notWhileErr end
    local near = nil
    if opts.near ~= nil then
        local nerr
        near, nerr = nearOf(opts.near)
        if not near then return false, nerr end
        if not stillNear(source, near) then return false, 'too far' end
    end
    -- The vehicle the work is being done from (cancelOnExit), as the server sees it.
    local vehicle = nil
    if opts.cancelOnExit == true then
        local ped = GetPlayerPed(source)
        vehicle = (ped and ped ~= 0) and GetVehiclePedIsIn(ped, false) or 0
        if vehicle == 0 then return false, 'not in a vehicle' end
    end

    -- One bar at a time, held here: the honest client already answers 'busy' to a second bar, a
    -- modified one would run both.
    local running = _barOf[source]
    if running and not running.done then return false, 'busy' end

    _barToken = _barToken + 1
    local token = _barToken
    local p = promise.new()
    -- `session`: the character session the bar belongs to, asked again when it is answered.
    local entry = { source = source, at = GetGameTimer(), minMs = math.floor(duration * SLACK), promise = p, done = false,
                    cancelOnDeath = opts.cancelOnDeath ~= false, near = near, session = who.session,
                    owner = owner, tag = tag, vehicle = vehicle }
    _bars[token] = entry
    _barOf[source] = entry

    TriggerClientEvent('whip_core:client:serverProgress', source, token, barOpts(opts, duration), owner)

    -- The bar's prop, made and removed by the server (server/held_props.lua) rather than by the
    -- client the bar is timing. Vouched for, too, so the client Progress may ask for the same model.
    if type(opts.prop) == 'table' and opts.prop.model ~= nil then
        HeldProps.allowModel(opts.prop.model)
        HeldProps.give(source, { opts.prop }, 'bar')
    end

    -- A client that never answers (it crashed, it lies by silence) is a timeout, not a coroutine
    -- waiting forever — with whatever the caller was holding still held.
    SetTimeout(math.floor(duration + GRACE_MS), function()
        if not entry.done then
            entry.done = true
            _bars[token] = nil
            p:resolve({ false, 'timeout' })
        end
    end)

    local r = Citizen.Await(p)
    HeldProps.drop(source, 'bar')
    return r[1] == true, r[2]
end

--- The client's answer to a bar the server showed.
SecureEvent('whip_core:server:progressResult', {
    rateLimit = 100,
    burst     = 3,
    whileDead = true,   -- a bar cancelled by dying answers from a dead player; refusing it would stall the caller
    params = {
        { 'token',     'id' },
        { 'completed', 'bool' },
        -- The client's own words, but only its words: callers branch on the reason, so a client must
        -- not claim 'dead' or 'player left'. The honest client only sends these (as skillCheckResult).
        -- 'refused': the bar never started (notWhile), so no time of it counts.
        { 'why',       'enum', { 'busy', 'cancelled', 'refused', 'timeout', '' }, '' },
    },
}, function(source, player, token, completed, why)
    local entry = _bars[token]
    if not entry or entry.done or entry.source ~= source then
        RecordEventRejection('whip_core:server:progressResult', source, 'answer did not match a bar that is running')
        return
    end
    -- The same CHARACTER, not only the same source: a token must not be answered for the character
    -- picked next.
    if entry.session ~= nil and (not player or player.session ~= entry.session) then
        RecordEventRejection('whip_core:server:progressResult', source, 'answer came from a different character session')
        return
    end
    entry.done = true
    _bars[token] = nil

    if not completed then
        entry.promise:resolve({ false, why ~= '' and why or 'cancelled' })
        return
    end

    -- Dead players do not finish bars: this event is whileDead only so a bar cancelled by dying can
    -- say so. The server's own death record is asked, unless the bar said dying does not stop it.
    if entry.cancelOnDeath and player and player.isDead then
        entry.promise:resolve({ false, 'dead' })
        return
    end

    -- Sooner than the bar could have filled: not a completion, whatever it says.
    local elapsed = GetGameTimer() - entry.at
    if elapsed < entry.minMs then
        RecordEventRejection('whip_core:server:progressResult', source,
            ('finished in %dms, minimum is %dms'):format(elapsed, entry.minMs))
        entry.promise:resolve({ false, 'too fast' })
        return
    end

    -- Walked (or drove) away while the bar ran: not a completion (`near` above).
    if entry.near and not stillNear(source, entry.near) then
        RecordEventRejection('whip_core:server:progressResult', source, 'too far from where the bar started')
        entry.promise:resolve({ false, 'too far' })
        return
    end

    -- Got out of the vehicle the work was being done from (cancelOnExit): their game ends the bar as they do,
    -- so a "done" from outside it is not one.
    if entry.vehicle then
        local ped = GetPlayerPed(source)
        if not ped or ped == 0 or GetVehiclePedIsIn(ped, false) ~= entry.vehicle then
            RecordEventRejection('whip_core:server:progressResult', source, 'not in the vehicle the bar started in')
            entry.promise:resolve({ false, 'left the vehicle' })
            return
        end
    end
    entry.promise:resolve({ true })
end)

-- ---- cleanup ----
--
-- Starts belong to a player's session and to the resource that made them. None of them should
-- outlive either.

--- A bar waiting on a player who left answers now, rather than at its timeout.
local function endBarsOf(src)
    _barOf[src] = nil
    for token, entry in pairs(_bars) do
        if entry.source == src and not entry.done then
            entry.done = true
            _bars[token] = nil
            entry.promise:resolve({ false, 'player left' })
        end
    end
end

AddEventHandler('playerDropped', function()
    _active[source] = nil
    endBarsOf(source)
end)

--- A logout ends the bar too, so it can't be answered by the next character's session. The client's
--- bar is closed by its own logout handling (client/ui.lua); an answer it still sends matches no bar.
---
--- WhipPlayer:logout calls this directly, BEFORE it waits for the player's running handlers: a
--- handler waiting on a bar is one of them. (Not an event handler: any resource could fire that.)
---@param src number
function EndTimedActionsFor(src)
    _active[src] = nil
    endBarsOf(src)
end

--- A run's end takes its bar down: a bar shown with a tag ends when that tag is released (ReleaseTag:
--- the Director's Reset, abort or end), answering 'cancelled', and comes off that player's screen
--- (only that bar: the client checks the token). Never waits.
Registry.onRelease('serverBar', 5, function(owner, tag)
    local n = 0
    for token, entry in pairs(_bars) do
        if not entry.done and entry.owner == owner and entry.tag == tag then
            entry.done = true
            _bars[token] = nil
            entry.promise:resolve({ false, 'cancelled' })
            TriggerClientEvent('whip_core:client:serverProgressCancel', entry.source, token)
            n = n + 1
        end
    end
    return n
end, function(owner, tag)
    local out = {}
    for token, entry in pairs(_bars) do
        if not entry.done and entry.owner == owner and entry.tag == tag then out[#out + 1] = { key = token } end
    end
    return out
end)

AddEventHandler('onResourceStop', function(res)
    for _, mine in pairs(_active) do
        for key, entry in pairs(mine) do
            if entry.owner == res then mine[key] = nil end
        end
    end
end)

-- ---- exports ----

--- Start timing an action. Call it where the action begins — usually the item's use handler.
---
--- ```lua
--- exports.whip_core:StartTimedAction(source, 'drink', 5000, addr)   -- addr: the item's address
--- ```
---@param source number
---@param name string
---@param durationMs number
---@param match table|nil  plain values (an address is fine); FinishTimedAction hands them back
---@return boolean started
---@return string|nil reason
exports('StartTimedAction', function(source, name, durationMs, match)
    return TimedAction.start(source, name, durationMs, match, GetInvokingResource())
end)

--- Check the client's "finished" against the server's own clock. Hand nothing over unless it
--- answers — and what it answers is what StartTimedAction was given.
---
--- ```lua
--- local addr = exports.whip_core:FinishTimedAction(source, 'drink')
--- if not addr then return end
--- ```
---@param source number
---@param name string
---@param match table|nil  optional; when given it must equal the start's
---@return table|false started  the start's values
---@return string|nil reason
exports('FinishTimedAction', function(source, name, match)
    return TimedAction.finish(source, name, match, GetInvokingResource())
end)

--- Show a progress bar on a player's screen and WAIT for it — true only if the bar really ran its
--- length. Blocks the calling handler for the bar. The same options as the client's Progress:
---
--- ```lua
--- local done, why = exports.whip_core:Progress(source, {
---     label = 'Drinking...', duration = 5000,
---     anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
---     prop = { model = 'prop_amb_beer_bottle' },
---     disable = { move = false },   -- they may walk while they drink
--- })
--- if not done then return end   -- why: 'cancelled', 'refused', 'busy', 'timeout', 'too fast', 'too far', 'dead', 'player left'
--- ```
---
--- `near = { coords = vector3, range }` or `{ vehicle = vehicleId, range }` keeps them there: asked
--- when the bar starts and again when it finishes. `notWhile = { 'swimming', 'underwater', 'falling' }`
--- refuses the bar in those, as TimedAction.progress says.
---
--- From another resource, `Whip.call('Progress', source, opts)` is the safer spelling: if whip_core
--- restarts mid-bar, the wait here dies with it and the export never answers.
---@param source number
---@param opts table
---@return boolean completed
---@return string|nil why
exports('Progress', function(source, opts)
    -- The owner, first: it is also who a `tag` in opts belongs to (ReleaseTag).
    return TimedAction.progress(source, opts, Registry.caller())
end)

-- Other files call TimedAction.progress (item uses, revive, doors). `_ENV.`, not `TimedAction =`:
-- the local above is in scope, so the plain form would assign it to itself and export nothing.
-- (`_ENV.` rather than `_G.`: the spelling whip_core uses for this.)
_ENV.TimedAction = TimedAction
